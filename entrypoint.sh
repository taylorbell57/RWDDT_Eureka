#!/bin/bash
set -Eeuo pipefail
umask 0002

# Allow opting out of strict workspace requirements for community use
SIMPLE_MODE="${SIMPLE_MODE:-0}"

# Checkpoint mode (joint fit)
CHECKPOINT_MODE="${CHECKPOINT_MODE:-0}"   # "1" enables checkpoint behavior
CHECKPOINT="${CHECKPOINT:-}"             # required when CHECKPOINT_MODE=1
VISITS_CSV="${VISITS_CSV:-}"             # optional (for informational logging)

# --- Make the current UID/GID resolvable (fixes "I have no name!")
CUR_UID="$(id -u)"
CUR_GID="$(id -g)"
CUR_USER="${USER_NAME:-rwddt}"     # name to show in prompt
CUR_GROUP="${GROUP_NAME:-rwddt}"   # group name to show

# 1) Always try to include libgomp (if present), and preserve any existing LD_PRELOAD.
if [[ -f /opt/conda/lib/libgomp.so.1 ]]; then
  case ":${LD_PRELOAD:-}:" in
    *":/opt/conda/lib/libgomp.so.1:"*) : ;;
    *) export LD_PRELOAD="${LD_PRELOAD:+$LD_PRELOAD:}/opt/conda/lib/libgomp.so.1" ;;
  esac
fi

# Create a passwd entry mapping current UID so tools see a username
if ! getent passwd "${CUR_UID}" >/dev/null; then
  NSS_WRAPPER_PASSWD="$(mktemp)"
  NSS_WRAPPER_GROUP="$(mktemp)"
  echo "${CUR_GROUP}:x:${CUR_GID}:" > "${NSS_WRAPPER_GROUP}"
  echo "${CUR_USER}:x:${CUR_UID}:${CUR_GID}:container user:/home/rwddt:/bin/bash" > "${NSS_WRAPPER_PASSWD}"

  # Only add nss_wrapper if needed, and append without clobbering.
  case ":${LD_PRELOAD:-}:" in
    *":libnss_wrapper.so:"*) : ;;
    *) export LD_PRELOAD="libnss_wrapper.so${LD_PRELOAD:+:$LD_PRELOAD}" ;;
  esac

  export NSS_WRAPPER_PASSWD NSS_WRAPPER_GROUP
fi

# Helpers
check_folder() {
  local path="$1"
  local label="$2"
  local noexit="${3:-}" # any non-empty value means "warn only"
  if [[ ! -d "$path" ]]; then
    echo "Missing ${label}: $path" >&2
    if [[ -n "$noexit" ]]; then
      return 0
    fi
    exit 1
  fi
}

safe_link() {
  local src="$1"
  local dst="$2"
  if [[ -e "$dst" || -L "$dst" ]]; then
    rm -rf "$dst"
  fi
  ln -s "$src" "$dst"
}

die() { echo "ERROR: $*" >&2; exit 1; }

# ---------- environment ----------
PLANET="${PLANET:-}"
VISIT="${VISIT:-}"
ANALYST="${ANALYST:-}"
HOST_PORT="${HOST_PORT:-8888}"   # used for the log line only; container binds 8888
CONDA_ENV="${CONDA_ENV:-base}"

# Normalize mode relationships:
if [[ "$SIMPLE_MODE" = "1" && "$CHECKPOINT_MODE" = "1" ]]; then
  echo "Warning: SIMPLE_MODE=1 and CHECKPOINT_MODE=1 both set; SIMPLE_MODE wins." >&2
  CHECKPOINT_MODE="0"
fi

# Establish BASE_PATH:
# - structured:  /mnt/rwddt/JWST/<planet>/<visit>
# - checkpoint:  /mnt/rwddt/JWST/<planet>/<checkpoint>
if [[ -z "$PLANET" || -z "$ANALYST" ]]; then
  if [[ "$SIMPLE_MODE" = "1" ]]; then
    echo "SIMPLE_MODE=1 -> Using a generic workspace under /home/rwddt/work"
    mkdir -p /home/rwddt/work/notebooks
    BASE_PATH="/home/rwddt/work"
    : "${PLANET:=local}"
    : "${VISIT:=visit}"
    : "${ANALYST:=analyst}"
  else
    die "Missing PLANET/ANALYST env vars. Set SIMPLE_MODE=1 to use a local workspace."
  fi
else
  if [[ "$CHECKPOINT_MODE" = "1" ]]; then
    [[ -n "$CHECKPOINT" ]] || die "CHECKPOINT_MODE=1 requires CHECKPOINT env var to be set."
    BASE_PATH="/mnt/rwddt/JWST/${PLANET}/${CHECKPOINT}"
  else
    [[ -n "$VISIT" ]] || die "Structured mode requires VISIT env var (or set SIMPLE_MODE=1)."
    BASE_PATH="/mnt/rwddt/JWST/${PLANET}/${VISIT}"
  fi
fi

# Ensure mount root exists (scaffold only; harmless if already present)
mkdir -p /mnt/rwddt/JWST || true
mkdir -p /home/rwddt || true

# ---------- Canonical /home/rwddt structure ----------
# Structured mode expects:
#   /home/rwddt/analysis
#   /home/rwddt/notebooks
#   /home/rwddt/MAST_Stage1
#   /home/rwddt/Uncalibrated
#
# Checkpoint mode expects:
#   /home/rwddt/analysis
#   /home/rwddt/notebooks
#   /home/rwddt/visits
# and does NOT create MAST_Stage1/Uncalibrated.

# ---------- link the working dirs safely ----------
if [[ "$SIMPLE_MODE" = "1" ]]; then
  # Simple mode: create canonical dirs locally (keeps older assumptions happy)
  mkdir -p /home/rwddt/analysis /home/rwddt/notebooks /home/rwddt/MAST_Stage1 /home/rwddt/Uncalibrated
else
  # Non-simple: analyst dir must exist (provided by RW mount)
  mkdir -p "$BASE_PATH" || true
  check_folder "${BASE_PATH}/${ANALYST}" "analyst folder mount"

  # Link analysis + notebooks to the writable workspace
  safe_link "${BASE_PATH}/${ANALYST}" /home/rwddt/analysis
  safe_link "${BASE_PATH}/${ANALYST}/notebooks" /home/rwddt/notebooks

  if [[ "$CHECKPOINT_MODE" = "1" ]]; then
    # Provide a tidy portal to all visits under this planet:
    mkdir -p "/mnt/rwddt/JWST/${PLANET}" || true
    safe_link "/mnt/rwddt/JWST/${PLANET}" /home/rwddt/visits

    # IMPORTANT: do NOT create /home/rwddt/MAST_Stage1 or /home/rwddt/Uncalibrated in checkpoint mode.
    # Also, if they happen to exist in the image or from a prior container run, remove them to keep home tidy.
    rm -rf /home/rwddt/MAST_Stage1 /home/rwddt/Uncalibrated 2>/dev/null || true
  else
    # Structured mode: link shared inputs if present; else keep empty dirs
    if [[ -d "${BASE_PATH}/MAST_Stage1" ]]; then
      safe_link "${BASE_PATH}/MAST_Stage1" /home/rwddt/MAST_Stage1
    else
      mkdir -p /home/rwddt/MAST_Stage1
    fi

    if [[ -d "${BASE_PATH}/Uncalibrated" ]]; then
      safe_link "${BASE_PATH}/Uncalibrated" /home/rwddt/Uncalibrated
    else
      mkdir -p /home/rwddt/Uncalibrated
    fi
  fi
fi


echo "------------------------------------------------------------"
echo " Verifying required volume mounts..."
echo "------------------------------------------------------------"
echo "Running as: $(id)"
echo "SIMPLE_MODE=${SIMPLE_MODE}  CHECKPOINT_MODE=${CHECKPOINT_MODE}"
if [[ "$CHECKPOINT_MODE" = "1" && "$SIMPLE_MODE" != "1" ]]; then
  echo "PLANET=${PLANET}  CHECKPOINT=${CHECKPOINT}  ANALYST=${ANALYST}"
  if [[ -n "$VISITS_CSV" ]]; then
    echo "VISITS_CSV=${VISITS_CSV}"
  fi
else
  echo "PLANET=${PLANET}  VISIT=${VISIT:-}  ANALYST=${ANALYST}"
fi
echo "Resolved analysis  -> $(readlink -f /home/rwddt/analysis || true)"
echo "Resolved notebooks -> $(readlink -f /home/rwddt/notebooks || true)"
if [[ "$CHECKPOINT_MODE" = "1" && "$SIMPLE_MODE" != "1" ]]; then
  echo "Resolved visits    -> $(readlink -f /home/rwddt/visits || true)"
fi

check_folder /home/rwddt/notebooks "notebooks"
check_folder /home/rwddt/analysis "analysis"

# Only verify Stage1/Uncalibrated paths in structured or simple mode (NOT checkpoint).
if [[ "$CHECKPOINT_MODE" != "1" ]]; then
  check_folder /home/rwddt/MAST_Stage1 "MAST Stage1" warn
  check_folder /home/rwddt/Uncalibrated "Uncalibrated" warn
fi

if [[ "$CHECKPOINT_MODE" = "1" && "$SIMPLE_MODE" != "1" ]]; then
  check_folder /home/rwddt/visits "visits"
fi

# CRDS handling:
# - If CRDS_MODE=local, require CRDS_PATH to exist (could be /grp/crds/cache or /crds).
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

export CRDS_PATH
export CRDS_SERVER_URL="${CRDS_SERVER_URL:-https://jwst-crds.stsci.edu}"

# ---------- seed default notebooks (only if empty and writable) ----------
if [[ -d /opt/default_notebooks && -w /home/rwddt/notebooks ]]; then
  if [[ -z "$(ls -A /home/rwddt/notebooks 2>/dev/null)" ]]; then
    cp -r /opt/default_notebooks/* /home/rwddt/notebooks/ || true
  fi
fi

# ---------- start Jupyter ----------
GREEN='\033[0;32m'; NC='\033[0m'

# Activate conda
eval "$(conda shell.bash hook)"
export CONDA_CHANGEPS1=no
conda activate "${CONDA_ENV}"

# Final prompt in terminals: [user@host cwd]$
# Use \u to respect NSS wrapper username; \W shows only the leaf dir (e.g. notebooks)
export PS1='[\u@\h \W]$ '

# Generate a secure random token and show the exact URL
TOKEN="$(python -c 'import secrets; print(secrets.token_urlsafe(24))')"
export JUPYTER_TOKEN="$TOKEN"
URL="http://localhost:${HOST_PORT}/?token=${TOKEN}"

# Launch JupyterLab inside a persistent tmux session
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
echo -e "${GREEN} If Docker is on a remote host, forward the port first (run on your local machine):${NC}"
echo -e "${GREEN}   ssh -L ${HOST_PORT}:localhost:${HOST_PORT} <user>@<remote-host>${NC}"
echo -e "${GREEN}   (Keep that terminal open while you use JupyterLab; type 'exit' to close the tunnel.)${NC}"
echo -e "${GREEN}====================================================================${NC}"
echo
echo "To attach to the persistent Jupyter tmux session inside the container:"
echo "  From the host, in your run directory: ./rwddt-run exec tmux attach -t $SESSION"
echo "Detach from tmux with Ctrl-b then d."

# Keep PID 1 alive while tmux session exists
while tmux has-session -t "$SESSION" 2>/dev/null; do
  sleep 5
done

