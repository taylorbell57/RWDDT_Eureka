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

# Detect mapped host port for container port 8888
HOST_PORT="8888"
if [ -S /var/run/docker.sock ]; then
  HOST_PORT_DETECTED=$(curl --silent --unix-socket /var/run/docker.sock \
    http://localhost/containers/$(hostname)/json \
    | grep -oP '"8888/tcp":\[\{"HostPort":"\K[0-9]+')
  if [ -n "${HOST_PORT_DETECTED:-}" ]; then
    HOST_PORT="$HOST_PORT_DETECTED"
  fi
fi

# Get best-effort server IP
SERVER_IP=$(hostname -I | cut -d' ' -f1)

# Activate conda environment before checking token
eval "$(conda shell.bash hook)"
conda activate "${CONDA_ENV:-base}"

# Launch Jupyter in background to capture the token
echo "Starting Jupyter Lab server in background to capture token..."
jupyter lab --ip=0.0.0.0 --no-browser --notebook-dir=/home/rwddt/notebooks &
JUPYTER_PID=$!

# Wait for the server to start and emit a URL
for i in {1..30}; do
  TOKEN_URL=$(jupyter lab list 2>/dev/null | grep -o "http://.*token=[a-zA-Z0-9\-]+") || true
  if [[ -n "$TOKEN_URL" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "$TOKEN_URL" ]]; then
  echo "Warning: Unable to retrieve Jupyter token URL. Server may not have started yet."
  echo "You can run 'jupyter lab list' manually inside the container to find it."
else
  # Rewrite the token URL with external IP and mapped port
  TOKEN_URL="http://${SERVER_IP}:${HOST_PORT}${TOKEN_URL#http://127.0.0.1:8888}"
fi

GREEN='\033[1;32m'
NC='\033[0m' # No color

echo -e "${GREEN}============================================================"
echo " Jupyter Lab is starting!"
echo ""
if [[ -n "$TOKEN_URL" ]]; then
  echo " Access it at: $TOKEN_URL"
else
  echo " Access it at: http://${SERVER_IP}:${HOST_PORT}"
fi
echo -e "============================================================${NC}"
echo ""

# Wait for the background Jupyter process to take over (PID 1)
wait $JUPYTER_PID
