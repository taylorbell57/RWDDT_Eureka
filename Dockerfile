FROM condaforge/mambaforge:24.9.2-0

# Create a non-root user named rwddt with UID 1000 and home directory
RUN useradd -m -u 1000 -s /bin/bash rwddt

# Set working directory
WORKDIR /home/rwddt

# Environment variables
ARG DEBIAN_FRONTEND=noninteractive

# Use bash as default shell for consistent conda behavior
SHELL ["/bin/bash", "-c"]

# Install base tools (one layer) and clean lists in same layer
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential git curl ca-certificates libnss-wrapper && \
    rm -rf /var/lib/apt/lists/*

# Friendly prompt for interactive shells
RUN printf '%s\n' \
  '# pretty prompt only for interactive shells' \
  'if [ -n "$PS1" ]; then' \
  '  _u="$(id -un 2>/dev/null || echo rwddt)"; export PS1="(base) [${_u}@\h \W]$ "' \
  'fi' \
  > /etc/profile.d/99-ps1.sh

# Install Python and Eureka
RUN mamba install python=3.13 -y -c conda-forge && \
    pip install 'eureka-bang[rwddt]@git+https://github.com/kevin218/Eureka.git@e0f54ed'

RUN apt-get autoremove -y && apt-get clean && \
    conda clean -afy

# Clean up apt packages
RUN apt-get purge -y build-essential && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    conda clean -afy

# Prepare and copy example notebooks using sparse-checkout
RUN mkdir -p /opt/default_notebooks && \
    git clone --filter=blob:none https://github.com/taylorbell57/rocky-worlds-notebooks.git && \
    cd rocky-worlds-notebooks && \
    git checkout 2e239fb && \
    git sparse-checkout init --cone && \
    git sparse-checkout set notebooks/JWST_Data_Processing && \
    mv notebooks/JWST_Data_Processing/* /opt/default_notebooks && \
    cd .. && rm -rf rocky-worlds-notebooks && \
    chmod -R go-w /opt/default_notebooks && \
    chown -R rwddt:rwddt /opt/default_notebooks

# Fix TLS loading issue for batman by preloading OpenMP library
ENV LD_PRELOAD=/opt/conda/lib/libgomp.so.1
ENV PATH="/home/rwddt/.local/bin:${PATH}"

# Expose relevant folders and port
EXPOSE 8888
VOLUME ["/mnt/rwddt", "/grp/crds"]

# Copy entrypoint script
COPY --chown=rwddt:rwddt entrypoint.sh /home/rwddt/entrypoint.sh
RUN chmod +x /home/rwddt/entrypoint.sh

# Switch to non-root user
USER rwddt

# Set environment variables for the new user
ENV HOME=/home/rwddt
ENV SHELL=/bin/bash

RUN chmod 1777 /home/rwddt

# Metadata
LABEL org.opencontainers.image.title="RW-DDT Eureka! Container" \
      org.opencontainers.image.description="A Jupyter-based Docker environment for RW-DDT data analysis using Eureka!" \
      org.opencontainers.image.authors="Taylor James Bell <taylorbell57>" \
      org.opencontainers.image.source="https://github.com/taylorbell57/RWDDT_Eureka" \
      org.opencontainers.image.documentation="https://github.com/taylorbell57/RWDDT_Eureka/blob/main/README.md" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.licenses-url="https://github.com/taylorbell57/RWDDT_Eureka/blob/main/LICENSE"

# Start script
ENTRYPOINT ["/home/rwddt/entrypoint.sh"]
