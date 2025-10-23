#!/bin/bash
set -Eeuo pipefail
umask 0002

# Allow opting out of strict workspace requirements for community use
SIMPLE_MODE="${SIMPLE_MODE:-0}"

# --- Make the current UID/GID resolvable (fixes "I have no name!")
CUR_UID="$(id -u)"
CUR_GID="$(id -g)"
CUR_USER="${USER_NAME:-rwddt}"   # name to show in prompt
CUR_GROUP="${GROUP_NAME:-rwddt}" # group name to show

# Create a passwd entry mapping current UID so tools see a username
if ! getent passwd "${CUR_UID}" >/dev/null; then
  NSS_WRAPPER_PASSWD="$(mktemp)"
  NSS_WRAPPER_GROUP="$(mktemp)"
  echo "${CUR_GROUP}:x:${CUR_GID}:" > "${NSS_WRAPPER_GROUP}"
  echo "${CUR_USER}:x:${CUR_UID}:${CUR_GID}:container user:/home/rwddt:/bin/bash" > "${NSS_WRAPPER_PASSWD}"
  export LD_PRELOAD=libnss_wrapper.so
  export NSS_WRAPPER_PASSWD NSS_WRAPPER_GROUP
fi

# Helpers
check_folder() {
  local path="$1"
  local label="$2"
  if [ ! -d "$path" ]; then
    echo "Missing ${label}: $path"
    exit 1
  fi
}

safe_link() {
  local src="$1"
  local dst="$2"
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    rm -rf "$dst"
  fi
  ln -s "$src" "$dst"
}

die() { echo "ERROR: $*" >&2; exit 1; }

# ---------- environment ----------

PLANET="${PLANET:-}"
VISIT="${VISIT:-}"
ANALYST="${ANALYST:-}"
HOST_PORT="${HOST_PORT:-8888}"     # used for the log line only; container binds 8888
CONDA_ENV="${CONDA_ENV:-base}"

# Community-friendly defaults: if not provided, fall back to a simple workspace
if [[ -z "$PLANET" || -z "$VISIT" || -z "$ANALYST" ]]; then
  if [[ "$SIMPLE_MODE" = "1" ]]; then
    echo "SIMPLE_MODE=1 -> Using a generic workspace under /home/rwddt/work"
    mkdir -p /home/rwddt/work/notebooks
    BASE_PATH="/home/rwddt/work"
    : "${PLANET:=local}"
    : "${VISIT:=visit}"
    : "${ANALYST:=analyst}"
  else
    die "Missing PLANET/VISIT/ANALYST env vars. Set SIMPLE_MODE=1 to use a local workspace."
  fi
else
  BASE_PATH="/mnt/rwddt/JWST/${PLANET}/${VISIT}"
fi

# Ensure mount roots exist
if [[ "$SIMPLE_MODE" != "1" ]]; then
  check_folder "/mnt/rwddt" "rwddt root"
  check_folder "$BASE_PATH" "visit folder"
fi

# ---------- link the working dirs safely ----------
if [[ "$SIMPLE_MODE" = "1" ]]; then
  mkdir -p /home/rwddt/analysis /home/rwddt/notebooks /home/rwddt/MAST_Stage1 /home/rwddt/Uncalibrated
else
  safe_link "${BASE_PATH}/${ANALYST}"            /home/rwddt/analysis
  safe_link "${BASE_PATH}/${ANALYST}/notebooks"  /home/rwddt/notebooks
  safe_link "${BASE_PATH}/MAST_Stage1"           /home/rwddt/MAST_Stage1
  safe_link "${BASE_PATH}/Uncalibrated"          /home/rwddt/Uncalibrated
fi

echo "------------------------------------------------------------"
echo " Verifying required volume mounts..."
echo "------------------------------------------------------------"
echo "Running as: $(id)"
echo "PLANET=${PLANET}  VISIT=${VISIT}  ANALYST=${ANALYST}"
echo "Resolved notebooks -> $(readlink -f /home/rwddt/notebooks || true)"

check_folder /home/rwddt/notebooks    "notebooks"
check_folder /home/rwddt/analysis     "analysis"
check_folder /home/rwddt/MAST_Stage1  "MAST Stage1"
check_folder /home/rwddt/Uncalibrated "Uncalibrated"

# CRDS handling:
# - If CRDS_MODE=local, we require CRDS_PATH to exist (could be /grp/crds/cache or /crds).
# - If CRDS_MODE!=local (e.g., remote), CRDS_PATH is optional.
export CRDS_MODE="${CRDS_MODE:-local}"
if [[ "${CRDS_MODE}" = "local" ]]; then
  : "${CRDS_PATH:?CRDS_MODE=local requires CRDS_PATH to be set (e.g., /grp/crds/cache or /crds)}"
  check_folder "${CRDS_PATH}" "CRDS_PATH"
else
  if [[ -n "${CRDS_PATH:-}" && -d "${CRDS_PATH}" ]]; then
    echo "CRDS_PATH present (${CRDS_PATH}) with CRDS_MODE=${CRDS_MODE}."
  else
    echo "CRDS_MODE=${CRDS_MODE} and CRDS_PATH not mounted; proceeding without a local CRDS cache."
  fi
fi

# Export variables for CRDS-aware tools
export CRDS_PATH
# Prefer CRDS_SERVER_URL; do not set CRDS_SERVER unless you want legacy compatibility
export CRDS_SERVER_URL="${CRDS_SERVER_URL:-https://jwst-crds.stsci.edu}"

# ---------- seed default notebooks (only if empty and writable) ----------
if [ -d /opt/default_notebooks ] && [ -w /home/rwddt/notebooks ]; then
  if [ -z "$(ls -A /home/rwddt/notebooks 2>/dev/null)" ]; then
    cp -r /opt/default_notebooks/* /home/rwddt/notebooks/ || true
  fi
fi

# ---------- start Jupyter ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

# Activate conda
eval "$(conda shell.bash hook)"
export CONDA_CHANGEPS1=no
conda activate "$CONDA_ENV"

# Final prompt in terminals: [user@host cwd]$
# Use \u to respect NSS wrapper username; \W shows only the leaf dir (e.g. notebooks)
export PS1='[\u@\h \W]$ '

# Generate a secure random token and show the exact URL
TOKEN="$(python -c 'import secrets; print(secrets.token_urlsafe(24))')"
export JUPYTER_TOKEN="$TOKEN"
URL="http://localhost:${HOST_PORT}/?token=${TOKEN}"

# --------------------------------------------------------------------
# Launch JupyterLab inside a persistent tmux session
# --------------------------------------------------------------------
SESSION="jlab"
LOG_FILE="/home/rwddt/jupyter.log"

JUPYTER_CMD=(
  jupyter lab
  --ip=0.0.0.0
  --port=8888
  --no-browser
  --notebook-dir=/home/rwddt/
  --ServerApp.websocket_ping_interval=30000
  --ServerApp.websocket_ping_timeout=30000
  --ZMQChannelsWebsocketConnection.websocket_ping_interval=30000
  --ZMQChannelsWebsocketConnection.websocket_ping_timeout=30000
  --TerminalsWebsocketConnection.websocket_ping_interval=30000
  --TerminalsWebsocketConnection.websocket_ping_timeout=30000
)

mkdir -p "$(dirname "$LOG_FILE")"
: > "$LOG_FILE" || true
chmod 666 "$LOG_FILE" || true

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Reusing existing tmux session: $SESSION"
else
  tmux new-session -d -s "$SESSION" "exec ${JUPYTER_CMD[*]} 2>&1 | tee -a '$LOG_FILE'"
  sleep 2
fi

echo -e "${GREEN}====================================================================${NC}"
echo -e "${GREEN} JupyterLab is running and kernels persist even if you disconnect.${NC}"
echo -e "${GREEN} Access URL: ${URL}${NC}"
echo -e "${GREEN} If Docker is on a remote host, forward the port first, e.g.:${NC}"
echo -e "${GREEN}   ssh -L ${HOST_PORT}:localhost:${HOST_PORT} RemoteHostName${NC}"
echo -e "${GREEN}====================================================================${NC}"
echo ""
echo "To view live server logs inside the container:"
echo "  docker exec -it <container_name> tmux attach -t $SESSION"
echo "Detach from tmux with Ctrl-b then d."

# Keep PID 1 alive while tmux session exists
while tmux has-session -t "$SESSION" 2>/dev/null; do
  sleep 5
done

