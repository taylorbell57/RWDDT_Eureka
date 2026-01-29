FROM condaforge/mambaforge:24.9.2-0

# Create a non-root user named rwddt with overrideable UID/GID
ARG NB_UID=1000
ARG NB_GID=1000
RUN groupadd -g ${NB_GID} rwddt || true && \
    useradd -m -u ${NB_UID} -g ${NB_GID} -s /bin/bash rwddt

# Set working directory
WORKDIR /home/rwddt

# Build args for reproducibility and optional notebooks
ARG DEBIAN_FRONTEND=noninteractive
ARG EUREKA_REF=b686b21
ARG NOTEBOOKS_REPO=https://github.com/taylorbell57/rocky-worlds-notebooks.git
ARG NOTEBOOKS_REF=3c97fa5
ARG INCLUDE_NOTEBOOKS=true

# Make Python stdout/stderr unbuffered for real-time logs
ENV PYTHONUNBUFFERED=1

# Use bash as default shell for consistent conda behavior
SHELL ["/bin/bash", "-c"]

# Install base tools in one layer
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential git curl ca-certificates libnss-wrapper htop tmux && \
    rm -rf /var/lib/apt/lists/*

# Friendly prompt for interactive shells
RUN printf '%s\n' \
  'if [ -n "$PS1" ]; then' \
  '  export PS1="[\[\e[32m\]\u\[\e[0m\]@\[\e[34m\]\h\[\e[0m\] \[\e[33m\]\W\[\e[0m\]]$ "' \
  'fi' \
  > /etc/profile.d/99-ps1.sh
RUN printf "%s\n" \
'export PROMPT_DIRTRIM=2' \
'export PS1="[\[\e[32m\]\u\[\e[0m\]@\[\e[34m\]\h\[\e[0m\] \[\e[33m\]\W\[\e[0m\]]$ "' \
>> /home/rwddt/.bashrc && \
    chown rwddt:rwddt /home/rwddt/.bashrc

# Pre-create user dirs and make them writable for any runtime UID/GID
RUN mkdir -p /home/rwddt/.jupyter/lab/workspaces \
             /home/rwddt/.jupyter/lab/settings \
             /home/rwddt/.local/share/jupyter \
             /home/rwddt/.config && \
    chmod -R 0777 /home/rwddt/.jupyter /home/rwddt/.local /home/rwddt/.config

# Jupyter Server 2.x config, placed in a global location
RUN mkdir -p /etc/jupyter && \
    python - <<'PY'
from pathlib import Path
p = Path("/etc/jupyter/jupyter_server_config.py")
p.write_text("\n".join([
    "c = get_config()",
    "# Keep server and kernels alive indefinitely",
    "c.ServerApp.shutdown_no_activity_timeout = 0",
    "c.MappingKernelManager.cull_idle_timeout = 0",
    "c.MappingKernelManager.cull_interval = 0",
    "c.MappingKernelManager.cull_connected = False",
    "c.MappingKernelManager.cull_busy = False",
    "",
    "# High IOPub limits (new location in Jupyter Server 2.x)",
    "c.ZMQChannelsWebsocketConnection.iopub_msg_rate_limit = 1.0e12",
    "c.ZMQChannelsWebsocketConnection.rate_limit_window = 1.0",
    "",
    "# WebSocket keepalives: silence timeout>interval warning",
    "c.ServerApp.websocket_ping_interval = 30000   # ms",
    "c.ServerApp.websocket_ping_timeout  = 30000   # ms",
    "c.ZMQChannelsWebsocketConnection.websocket_ping_interval = 30000",
    "c.ZMQChannelsWebsocketConnection.websocket_ping_timeout  = 30000",
    "c.TerminalsWebsocketConnection.websocket_ping_interval = 30000",
    "c.TerminalsWebsocketConnection.websocket_ping_timeout  = 30000",
    "",
    "# Token is provided via env; entrypoint exports JUPYTER_TOKEN",
    "import os",
    "c.IdentityProvider.token = os.environ.get('JUPYTER_TOKEN', '')",
]))
print("Wrote", p)
PY

# JupyterLab default settings: autosave every 60 seconds
# JupyterLab reads this file as a system-wide default (applies to all users)
RUN mkdir -p /opt/conda/share/jupyter/lab/settings && \
    printf '{\n  "@jupyterlab/docmanager-extension:plugin": {\n    "autosaveInterval": 60000\n  }\n}\n' \
      > /opt/conda/share/jupyter/lab/settings/overrides.json

# Install Python and Eureka
RUN mamba install -y -c conda-forge python=3.13 && \
    pip install "eureka-bang[rwddt]@git+https://github.com/kevin218/Eureka.git@${EUREKA_REF}"

# Optional example notebooks via sparse checkout
RUN if [ "${INCLUDE_NOTEBOOKS}" = "true" ]; then \
      mkdir -p /opt/default_notebooks && \
      git clone --filter=blob:none "${NOTEBOOKS_REPO}" notebooks-tmp && \
      cd notebooks-tmp && \
      git checkout "${NOTEBOOKS_REF}" && \
      git sparse-checkout init --cone && \
      git sparse-checkout set notebooks/JWST_Data_Processing && \
      mv notebooks/JWST_Data_Processing/* /opt/default_notebooks && \
      cd .. && rm -rf notebooks-tmp && \
      chmod -R go-w /opt/default_notebooks && \
      chown -R rwddt:rwddt /opt/default_notebooks; \
    else \
      mkdir -p /opt/default_notebooks && \
      chmod -R go-w /opt/default_notebooks && \
      chown -R rwddt:rwddt /opt/default_notebooks; \
    fi

# Fix TLS loading issue for batman by preloading OpenMP library
ENV LD_PRELOAD=/opt/conda/lib/libgomp.so.1
ENV PATH="/home/rwddt/.local/bin:${PATH}"
ENV HOME=/home/rwddt
ENV SHELL=/bin/bash
ENV CONDA_ENV=base

# Make sure /home/rwddt is accessible by the external user's UID/GID
RUN chmod 1777 /home/rwddt

# Ports and volumes
EXPOSE 8888
# CRDS can be either:
#   /grp/crds (STScI split layout with /grp/crds/cache/jwst -> /grp/crds/jwst), or
#   /crds     (community single-dir layout, often $HOME/crds_cache)
VOLUME ["/mnt/rwddt", "/crds", "/grp/crds"]

# Copy entrypoint
COPY --chown=rwddt:rwddt entrypoint.sh /home/rwddt/entrypoint.sh
RUN chmod 0755 /home/rwddt/entrypoint.sh

ENTRYPOINT ["/home/rwddt/entrypoint.sh"]

# Image metadata
LABEL org.opencontainers.image.title="RW-DDT Eureka! Container" \
      org.opencontainers.image.description="A Jupyter-based Docker environment for RW-DDT data analysis using Eureka!" \
      org.opencontainers.image.authors="Taylor James Bell <taylorbell57>" \
      org.opencontainers.image.source="https://github.com/taylorbell57/RWDDT_Eureka" \
      org.opencontainers.image.documentation="https://github.com/taylorbell57/RWDDT_Eureka/blob/main/README.md" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.licenses-url="https://github.com/taylorbell57/RWDDT_Eureka/blob/main/LICENSE"

