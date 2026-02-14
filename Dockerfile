FROM condaforge/mambaforge:24.9.2-0

# Create a non-root user named rwddt with overrideable UID/GID (idempotent)
ARG NB_UID=1000
ARG NB_GID=1000
RUN groupadd -g ${NB_GID} rwddt 2>/dev/null || true && \
    id -u rwddt >/dev/null 2>&1 || useradd -m -u ${NB_UID} -g ${NB_GID} -s /bin/bash rwddt

# Set working directory
WORKDIR /home/rwddt

# Build args for reproducibility and optional notebooks
ARG DEBIAN_FRONTEND=noninteractive
ARG EUREKA_REF=3a67244
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
RUN mkdir -p /etc/jupyter
COPY jupyter_server_config.py /etc/jupyter/jupyter_server_config.py

# JupyterLab default settings: autosave every 60 seconds
RUN mkdir -p /opt/conda/share/jupyter/lab/settings && \
    printf '{\n  \"@jupyterlab/docmanager-extension:plugin\": {\n    \"autosaveInterval\": 60000\n  }\n}\n' \
      > /opt/conda/share/jupyter/lab/settings/overrides.json

# Install Python and Eureka (no pip cache stored during build)
RUN mamba install -y -c conda-forge python=3.13 && \
    python -m pip install --no-cache-dir \
      "eureka-bang[rwddt]@git+https://github.com/kevin218/Eureka.git@${EUREKA_REF}"

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

# Clean caches to reduce final image size (does not remove installed packages)
RUN mamba clean -a -f -y && \
    python -m pip cache purge || true

ENV PATH="/home/rwddt/.local/bin:${PATH}"
ENV HOME=/home/rwddt
ENV SHELL=/bin/bash
ENV CONDA_ENV=base

# Make sure /home/rwddt is accessible by the external user's UID/GID
RUN chmod 1777 /home/rwddt

# Ports and volumes
EXPOSE 8888

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

