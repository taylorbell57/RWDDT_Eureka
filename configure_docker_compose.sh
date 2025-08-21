#!/bin/bash
set -euo pipefail

# Usage message
if [ "$#" -ne 4 ]; then
  echo "Usage: $0 <rootdir> <planet> <visit> <analyst>"
  echo "Example: $0 /rootdir TOI-1234b visit1 Analyst_A"
  exit 1
fi

ROOTDIR=$1
PLANET=$2
VISIT=$3
ANALYST=$4

case "$ROOTDIR" in
  /*) : ;;  # absolute path
  *) echo "Error: <rootdir> must be an absolute path (got '$ROOTDIR')."; exit 1 ;;
esac
if [ ! -d "$ROOTDIR" ]; then
  echo "Error: <rootdir> '$ROOTDIR' does not exist or is not a directory."
  exit 1
fi

VISIT_ROOT="${ROOTDIR%/}/JWST/${PLANET}/${VISIT}"
if [ ! -d "$(dirname "$VISIT_ROOT")" ]; then
  echo "Error: Parent directory '$(dirname "$VISIT_ROOT")' does not exist."
  echo "Create $ROOTDIR/JWST/$PLANET first, or fix your arguments."
  exit 1
fi

TEMPLATE_FILE="docker-compose.template.yml"
OUTPUT_FILE="docker-compose.yml"

# ---- Resolve IDs for correct file ownership on host ----
ANALYST_UID=$(id -u)  # current user
RWDDT_GID=$(getent group rwddt | cut -d: -f3 || true)

if [[ -z "${RWDDT_GID}" ]]; then
  echo "Error: group 'rwddt' not found on this system. Please ensure you're on the central server with the rwddt group."
  exit 1
fi

# Check if the template file exists
if [ ! -f "$TEMPLATE_FILE" ]; then
  echo "Error: $TEMPLATE_FILE not found in current directory."
  exit 1
fi

# Create project tree under the JWST namespace expected by the container
BASE_VISIT_DIR="$ROOTDIR/JWST/$PLANET/$VISIT"
ANALYSIS_DIR="$BASE_VISIT_DIR/$ANALYST"
NOTEBOOKS_DIR="$ANALYSIS_DIR/notebooks"
# Ensure ownership & group are correct; then 02700 (setgid + owner-only)
install -d -m 2700 -g "$RWDDT_GID" "$ANALYSIS_DIR" "$NOTEBOOKS_DIR"

# Find an available port for the host to map to container port 8888
find_free_port() {
  local port
  while true; do
    port=$((10240 + RANDOM % 50000))
    if command -v ss >/dev/null 2>&1; then
      if ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$port$"; then
        echo "$port"; return
      fi
    elif command -v lsof >/dev/null 2>&1; then
      if ! lsof -iTCP -sTCP:LISTEN -Pn 2>/dev/null | grep -q ":$port "; then
        echo "$port"; return
      fi
    else
      # Fallback: assume it's free
      echo "$port"; return
    fi
  done
}

HOST_PORT=$(find_free_port)

# Make a copy of the template
cp "$TEMPLATE_FILE" "$OUTPUT_FILE"

# Replace placeholders
sed -i.bak \
  -e "s|<rootdir>|$ROOTDIR|g" \
  -e "s|<planet>|$PLANET|g" \
  -e "s|<visit>|$VISIT|g" \
  -e "s|<analyst>|$ANALYST|g" \
  -e "s|<hostport>|$HOST_PORT|g" \
  -e "s|<uid>|$ANALYST_UID|g" \
  -e "s|<rwddt_gid>|$RWDDT_GID|g" \
  "$OUTPUT_FILE"

# Clean up backup
rm -f "$OUTPUT_FILE.bak"

GREEN='\033[1;32m'; NC='\033[0m'
echo "Generated $OUTPUT_FILE with:"
echo "  rootdir  = \"$ROOTDIR\""
echo "  planet   = \"$PLANET\""
echo "  visit    = \"$VISIT\""
echo "  analyst  = \"$ANALYST\""
echo "  hostport = \"$HOST_PORT\""
echo "  analyst UID = \"$ANALYST_UID\""
echo "  rwddt  GID  = \"$RWDDT_GID\""
echo
echo "Created directories (2700 = drwx--S---) under: $BASE_VISIT_DIR"
echo "  analysis  -> $ANALYSIS_DIR"
echo "  notebooks -> $NOTEBOOKS_DIR"
echo
echo -e "${GREEN}Tip: when the analysis is complete and you want to enable group read access, run:"
echo -e "  chmod 2750 \"$ANALYSIS_DIR\" \"$NOTEBOOKS_DIR\"${NC}"

