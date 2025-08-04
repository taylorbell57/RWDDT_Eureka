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

TEMPLATE_FILE="docker-compose.template.yml"
OUTPUT_FILE="docker-compose.yml"

# Check if the template file exists
if [ ! -f "$TEMPLATE_FILE" ]; then
  echo "Error: $TEMPLATE_FILE not found in current directory."
  exit 1
fi

# Create analyst-specific folders with 2700 permissions (owner-only access, setgid)
ANALYSIS_DIR="$ROOTDIR/$PLANET/$VISIT/$ANALYST"
NOTEBOOKS_DIR="$ANALYSIS_DIR/notebooks"

mkdir -p "$ANALYSIS_DIR" "$NOTEBOOKS_DIR"
chmod -v 2700 "$ANALYSIS_DIR" "$NOTEBOOKS_DIR"

# Find an available port for the host to map to container port 8888
find_free_port() {
  local port
  while true; do
    port=$((10240 + RANDOM % 50000))
    if ! lsof -iTCP -sTCP:LISTEN -Pn | grep -q ":$port "; then
      echo "$port"
      return
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
  "$OUTPUT_FILE"

# Clean up backup
rm -f "$OUTPUT_FILE.bak"

echo "Generated $OUTPUT_FILE with:"
echo "  rootdir  = \"$ROOTDIR\""
echo "  planet   = \"$PLANET\""
echo "  visit    = \"$VISIT\""
echo "  analyst  = \"$ANALYST\""
echo "  hostport = \"$HOST_PORT\""
echo
echo "Created analyst-specific directories with restrictive permissions (2700 = drwx--S---):"
echo "  $ANALYSIS_DIR"
echo "  $NOTEBOOKS_DIR"
echo
echo "Once your analysis is fully complete, you may run:"
echo "  chmod 2750 \"$ANALYSIS_DIR\" \"$NOTEBOOKS_DIR\""
echo "to change to drwxr-s--- and allow group-level read access."
