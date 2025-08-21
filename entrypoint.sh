#!/bin/bash
set -Eeuo pipefail
umask 0002

# --- Make the current UID/GID resolvable (fixes "I have no name!")
CUR_UID="$(id -u)"
CUR_GID="$(id -g)"
CUR_USER="${USER_NAME:-rwddt}"   # name to show in prompt
CUR_GROUP="${GROUP_NAME:-rwddt}" # group name to show

if ! getent passwd "$CUR_UID" >/dev/null 2>&1 || ! getent group "$CUR_GID" >/dev/null 2>&1; then
  export NSS_WRAPPER_PASSWD="$(mktemp)"
  export NSS_WRAPPER_GROUP="$(mktemp)"

  # Start from existing files if present, else minimal stubs
  if [ -r /etc/passwd ]; then cp /etc/passwd "$NSS_WRAPPER_PASSWD"; else echo "root:x:0:0:root:/root:/bin/sh" > "$NSS_WRAPPER_PASSWD"; fi
  if [ -r /etc/group  ]; then cp /etc/group  "$NSS_WRAPPER_GROUP";  else echo "root:x:0:"                          > "$NSS_WRAPPER_GROUP";  fi

  # Append our synthetic entries if missing
  if ! grep -qE "^[^:]*:[^:]*:${CUR_UID}:" "$NSS_WRAPPER_PASSWD"; then
    echo "${CUR_USER}:x:${CUR_UID}:${CUR_GID}:${CUR_USER} user:/home/${CUR_USER}:/bin/bash" >> "$NSS_WRAPPER_PASSWD"
  fi
  if ! grep -qE "^[^:]*:[^:]*:${CUR_GID}:" "$NSS_WRAPPER_GROUP"; then
    echo "${CUR_GROUP}:x:${CUR_GID}:" >> "$NSS_WRAPPER_GROUP"
  fi

  # Activate nss-wrapper
  export LD_PRELOAD="libnss_wrapper.so:${LD_PRELOAD:-}"
fi

# ---------- helpers ----------

die() { echo "ERROR: $*" >&2; exit 1; }

check_folder() {
  local path="$1" name="$2"
  [[ -d "$path" ]] || die "The $path folder is missing or not a directory. Please bind-mount your $name folder. See the README."
}

# Create / update a symlink without ever deleting real dirs/files.
# - target must resolve under /mnt/rwddt
# - if dest is a symlink: relink it
# - if dest exists and is NOT a symlink: abort (no rm -rf!)
# - if dest does not exist: create new symlink
safe_link() {
  local target="$1" dest="$2" allowed_prefix="/mnt/rwddt"

  [[ -e "$target" ]] || die "Target does not exist: $target"

  local target_abs
  target_abs=$(readlink -f -- "$target") || die "Failed to resolve: $target"

  case "$target_abs" in
    "$allowed_prefix"/*) ;;  # OK
    *) die "Refusing to link outside $allowed_prefix -> $target_abs" ;;
  esac

  if [[ -L "$dest" ]]; then
    ln -sfnT -- "$target_abs" "$dest"
  elif [[ -e "$dest" ]]; then
    echo "ERROR: $dest already exists and is not a symlink. Please remove/rename it manually."
    ls -ld -- "$dest"
    exit 1
  else
    ln -sT -- "$target_abs" "$dest"
  fi
}

dir_is_empty() {
  local d="$1"
  [[ -z "$(find "$d" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]
}

dir_is_writable() {
  local d="$1" t
  t=$(mktemp -p "$d" .writecheck.XXXX 2>/dev/null) || return 1
  rm -f -- "$t"
  return 0
}

# ---------- environment ----------

PLANET="${PLANET:-}"
VISIT="${VISIT:-}"
ANALYST="${ANALYST:-}"
HOST_PORT="${HOST_PORT:-8888}"     # used for the log line only; container binds 8888
CONDA_ENV="${CONDA_ENV:-base}"

[[ -n "$PLANET"  ]] || die "Missing PLANET env var"
[[ -n "$VISIT"   ]] || die "Missing VISIT env var"
[[ -n "$ANALYST" ]] || die "Missing ANALYST env var"

BASE_PATH="/mnt/rwddt/JWST/${PLANET}/${VISIT}"

# Ensure mount roots exist
check_folder "/mnt/rwddt" "rwddt root"
check_folder "$BASE_PATH" "visit folder"

# ---------- link the working dirs safely ----------

safe_link "${BASE_PATH}/${ANALYST}"            /home/rwddt/analysis
safe_link "${BASE_PATH}/${ANALYST}/notebooks"  /home/rwddt/notebooks
safe_link "${BASE_PATH}/MAST_Stage1"           /home/rwddt/MAST_Stage1
safe_link "${BASE_PATH}/Uncalibrated"          /home/rwddt/Uncalibrated

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
check_folder ${CRDS_PATH}             "CRDS_PATH"

# ---------- seed default notebooks (only if empty & writable) ----------

if dir_is_empty "/home/rwddt/notebooks"; then
  if dir_is_writable "/home/rwddt/notebooks"; then
    echo "Notebook folder is empty. Copying in default tutorial notebooks..."
    cp -r /opt/default_notebooks/* /home/rwddt/notebooks/
  else
    echo "Warning: /home/rwddt/notebooks is not writable; skipping default notebook copy."
  fi
fi

# ---------- conda + Jupyter ----------

# Activate conda environment
eval "$(conda shell.bash hook)"
conda activate "$CONDA_ENV"

# Pretty prompt that doesn't depend on /etc/passwd lookup
export PS1='(base) [rwddt@\h \W]$ '

# Generate a secure random token
TOKEN="$(python -c 'import secrets; print(secrets.token_urlsafe(24))')"

GREEN='\033[1;32m'; NC='\033[0m'
echo -e "${GREEN}============================================================================="
echo " Jupyter Lab is starting!"
echo ""
echo " Access it locally at: http://localhost:${HOST_PORT}/?token=${TOKEN}"
echo ""
echo " If Docker is running on a remote host, first forward the port, e.g.:"
echo "   ssh -L ${HOST_PORT}:localhost:${HOST_PORT} RemoteHostName"
echo " Then open the same URL in your local browser."
echo -e "=============================================================================${NC}"
echo ""

# Run Jupyter in the foreground as PID 1 so logs stream
exec jupyter lab \
  --ip=0.0.0.0 \
  --port=8888 \
  --no-browser \
  --notebook-dir=/home/rwddt/ \
  --ServerApp.token="${TOKEN}"

