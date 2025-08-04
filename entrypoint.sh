#!/bin/bash

set -eu  # Treat unset variables as an error

check_folder() {
  local path="$1"
  local name="$2"
  if [ ! -d "$path" ]; then
    echo "Error: The $path folder is missing or not a directory."
    echo "Please bind-mount your $name folder. See the README for instructions."
    exit 1
  fi
}

echo "------------------------------------------------------------"
echo " Verifying required volume mounts..."
echo "------------------------------------------------------------"

check_folder /home/rwddt/notebooks     "notebooks"
check_folder /home/rwddt/analysis      "analysis"
check_folder /home/rwddt/crds_cache    "CRDS cache"
check_folder /home/rwddt/MAST_Stage1   "MAST Stage1"
check_folder /home/rwddt/Uncalibrated  "Uncalibrated"

# Populate default notebooks if folder is empty
if [ -z "$(ls -A /home/rwddt/notebooks 2>/dev/null)" ]; then
  echo "Notebook folder is empty. Copying in default tutorial notebooks..."
  cp -r /opt/default_notebooks/* /home/rwddt/notebooks/
fi

# Use host port passed in via environment variable
HOST_PORT="${HOST_PORT:-8888}"  # Fallback if not set

# Get best-effort server IP
SERVER_IP=$(hostname -I | cut -d' ' -f1)

# Activate conda environment before checking token
eval "$(conda shell.bash hook)"
conda activate "${CONDA_ENV:-base}"

# Generate a secure random token
TOKEN=$(python -c 'import secrets; print(secrets.token_urlsafe(24))')

GREEN='\033[1;32m'
NC='\033[0m' # No color

echo -e "${GREEN}============================================================================="
echo " Jupyter Lab is starting!"
echo ""
echo " Access it at: http://localhost:${HOST_PORT}/?token=${TOKEN}"
echo -e "=============================================================================${NC}"
echo ""

# Launch Jupyter in the foreground as PID 1 so logs stream properly
exec jupyter lab \
  --ip=0.0.0.0 \
  --no-browser \
  --notebook-dir=/home/rwddt/ \
  --ServerApp.token="${TOKEN}"
