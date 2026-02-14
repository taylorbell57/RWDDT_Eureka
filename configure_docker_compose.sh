#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# configure_docker_compose.sh
#
# Structured mode (recommended):
#   ./configure_docker_compose.sh <rootdir> <planet> <visit> <analyst> [<crds_dir>] [split|single]
#
# Simple mode (quick tests; no required host structure; no persistence by default):
#   ./configure_docker_compose.sh --simple [<crds_dir>] [split|single]
#
# Outputs a run directory under:
#   runs/<planet>_<visit>/           (structured)
#   runs/simple_<timestamp>/         (simple)
# containing:
#   - docker-compose.yml
#   - .rwddt_state
#   - rwddt-run                      (wrapper)
# -----------------------------------------------------------------------------

# Resolve script directory so template lookup works regardless of cwd
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNS_ROOT="${SCRIPT_DIR}/runs"

# Templates now live under templates/
TEMPLATES_DIR="${SCRIPT_DIR}/templates"

STRUCT_TEMPLATE_FILE="docker-compose.template.yml"
SIMPLE_TEMPLATE_FILE="docker-compose.simple.template.yml"
BANNER_TEMPLATE_FILE="generated-compose-banner.txt"
WRAPPER_TEMPLATE_FILE="rwddt-run.template.sh"

STRUCT_TEMPLATE_PATH="${TEMPLATES_DIR}/${STRUCT_TEMPLATE_FILE}"
SIMPLE_TEMPLATE_PATH="${TEMPLATES_DIR}/${SIMPLE_TEMPLATE_FILE}"
BANNER_TEMPLATE_PATH="${TEMPLATES_DIR}/${BANNER_TEMPLATE_FILE}"
WRAPPER_TEMPLATE_PATH="${TEMPLATES_DIR}/${WRAPPER_TEMPLATE_FILE}"

OUTPUT_FILE="docker-compose.yml"
STATE_FILE=".rwddt_state"
WRAPPER="rwddt-run"

# -------- helpers --------
sanitize() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9_-]+/_/g; s/^[_-]+//; s/[_-]+$//'
}

usage() {
  cat <<'USAGE'
Usage:
  Structured mode (recommended):
    ./configure_docker_compose.sh <rootdir> <planet> <visit> <analyst> [<crds_dir>] [split|single]

  Simple mode (quick tests; no required host structure; no persistence by default):
    ./configure_docker_compose.sh --simple [<crds_dir>] [split|single]

Notes:
  - <rootdir> must be an absolute path.
  - split layout mounts CRDS read-only at /grp/crds and sets CRDS_PATH=/grp/crds/cache
  - single layout mounts CRDS read-write at /crds and sets CRDS_PATH=/crds
USAGE
}

escape_sed_repl() {
  # Escape characters that are special in sed replacement:
  # - '&' expands to the match
  # - '\' starts escape sequences
  # - '|' is our chosen delimiter
  printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

replace_placeholder() {
  local file="$1"
  local key="$2"
  local value="$3"
  local esc_value
  esc_value="$(escape_sed_repl "$value")"
  sed -i.bak -e "s|<${key}>|${esc_value}|g" "$file"
}

# Uncomment a commented volume line in the structured template if it exists
# Looks for:  # - <mast_stage1_host>:...
uncomment_volume_line_for_placeholder() {
  local file="$1"
  local key="$2"
  sed -i.bak -E \
    -e "s|^([[:space:]]*)#([[:space:]]*-[[:space:]]*<${key}>:)|\1\2|" \
    "$file"
}

# -------- argument parsing --------
MODE="structured"
if [[ "${1:-}" == "--simple" ]]; then
  MODE="simple"
  shift || true
fi

CRDS_DIR_DEFAULT="${HOME}/crds_cache"
LAYOUT_DEFAULT="single"

if [[ "$MODE" == "structured" ]]; then
  if [ "$#" -lt 4 ] || [ "$#" -gt 6 ]; then
    usage
    exit 1
  fi

  ROOTDIR=$1
  PLANET=$2
  VISIT=$3
  ANALYST=$4
  CRDS_DIR="${5:-$CRDS_DIR_DEFAULT}"
  CRDS_LAYOUT="${6:-$LAYOUT_DEFAULT}"

  case "$ROOTDIR" in
    /*) : ;;
    *) echo "Error: <rootdir> must be an absolute path (got '$ROOTDIR')." >&2; exit 1 ;;
  esac
  if [ ! -d "$ROOTDIR" ]; then
    echo "Error: <rootdir> '$ROOTDIR' does not exist or is not a directory." >&2
    exit 1
  fi

  VISIT_ROOT="${ROOTDIR%/}/JWST/${PLANET}/${VISIT}"
  if [ ! -d "$(dirname "$VISIT_ROOT")" ]; then
    echo "Error: Parent directory '$(dirname "$VISIT_ROOT")' does not exist." >&2
    echo "Create $ROOTDIR/JWST/$PLANET first, or fix your arguments." >&2
    exit 1
  fi

  # Ensure required templates exist
  for f in "$STRUCT_TEMPLATE_PATH" "$BANNER_TEMPLATE_PATH" "$WRAPPER_TEMPLATE_PATH"; do
    if [ ! -f "$f" ]; then
      echo "Error: required template not found: $f" >&2
      exit 1
    fi
  done
else
  if [ "$#" -gt 2 ]; then
    usage
    exit 1
  fi

  CRDS_DIR="${1:-$CRDS_DIR_DEFAULT}"
  CRDS_LAYOUT="${2:-$LAYOUT_DEFAULT}"

  # Ensure required templates exist
  for f in "$SIMPLE_TEMPLATE_PATH" "$BANNER_TEMPLATE_PATH" "$WRAPPER_TEMPLATE_PATH"; do
    if [ ! -f "$f" ]; then
      echo "Error: required template not found: $f" >&2
      exit 1
    fi
  done

  ROOTDIR=""
  PLANET=""
  VISIT=""
  ANALYST=""
fi

# -------- resolve IDs for correct file ownership on host --------
ANALYST_UID="$(id -u)"
ANALYST_GID="$(id -g)"

# Prefer rwddt group GID in split layout if it exists
if [ "$CRDS_LAYOUT" = "split" ]; then
  RWDDT_GID="$(perl -e 'my @g = getgrnam shift; print $g[2] if @g' rwddt)" || true
  if [[ -n "${RWDDT_GID}" ]]; then
    ANALYST_GID="${RWDDT_GID}"
  fi
fi

# -------- determine CRDS mount target, bind mode, and CRDS_PATH --------
case "$CRDS_LAYOUT" in
  split)
    CRDS_TARGET="/grp/crds"
    CRDS_BIND_MODE="ro"
    CRDS_PATH="/grp/crds/cache"
    ;;
  single)
    CRDS_TARGET="/crds"
    CRDS_BIND_MODE="rw"
    CRDS_PATH="/crds"
    ;;
  *)
    echo "Error: invalid layout '$CRDS_LAYOUT' (use 'split' or 'single')." >&2
    exit 1
    ;;
esac

# Ensure a local CRDS directory exists for single layout
if [ "$CRDS_LAYOUT" = "single" ]; then
  mkdir -p "${CRDS_DIR}" || true
fi

# -------- find an available host port (>=10240) --------
find_free_port() {
  perl -MIO::Socket::INET -e '
    my ($min,$max,$tries) = (10240, 60239, 2000);
    for (1..$tries) {
      my $p = $min + int(rand($max-$min+1));
      my $s = IO::Socket::INET->new(
        LocalAddr => "0.0.0.0", LocalPort => $p,
        Proto => "tcp", Listen => 1, ReuseAddr => 0
      );
      if ($s) { close $s; print $p; exit 0 }
    }
    exit 1;
  '
}
HOST_PORT="$(find_free_port)" || { echo "could not find a free port" >&2; exit 1; }

# -------- naming + run directory --------
USER_SAFE="$(sanitize "${USER:-unknown}")"

if [[ "$MODE" == "structured" ]]; then
  PLANET_SAFE="$(sanitize "$PLANET")"
  VISIT_SAFE="$(sanitize "$VISIT")"
  DATASET_SAFE="${PLANET_SAFE}_${VISIT_SAFE}"
  RUN_DIR="${RUNS_ROOT}/${DATASET_SAFE}"
  PROJECT_NAME="rwddt_${USER_SAFE}_${DATASET_SAFE}"

  BASE_VISIT_DIR="$ROOTDIR/JWST/$PLANET/$VISIT"
  ANALYSIS_DIR="$BASE_VISIT_DIR/$ANALYST"
  NOTEBOOKS_DIR="$ANALYSIS_DIR/notebooks"

  MAST_STAGE1_DIR="$BASE_VISIT_DIR/MAST_Stage1"
  UNCAL_DIR="$BASE_VISIT_DIR/Uncalibrated"

  # Create ONLY analyst tree
  if command -v install >/dev/null 2>&1; then
    install -d -m 2700 -g "$ANALYST_GID" "$ANALYSIS_DIR" "$NOTEBOOKS_DIR"
  else
    mkdir -p "$NOTEBOOKS_DIR"
    chmod 2700 "$ANALYSIS_DIR" "$NOTEBOOKS_DIR" || true
  fi
else
  TS="$(date +%Y%m%d_%H%M%S)"
  DATASET_SAFE="simple_${TS}"
  RUN_DIR="${RUNS_ROOT}/${DATASET_SAFE}"
  PROJECT_NAME="rwddt_${USER_SAFE}_${DATASET_SAFE}"

  ANALYSIS_DIR=""
  NOTEBOOKS_DIR=""
  MAST_STAGE1_DIR=""
  UNCAL_DIR=""
fi

mkdir -p "$RUN_DIR"

OUTPUT_PATH="${RUN_DIR}/${OUTPUT_FILE}"
STATE_PATH="${RUN_DIR}/${STATE_FILE}"
WRAPPER_PATH="${RUN_DIR}/${WRAPPER}"

# -----------------------------------------------------------------------------
# Generate docker-compose.yml from template (both modes)
#   - Prepend banner from templates/generated-compose-banner.txt
# -----------------------------------------------------------------------------
TEMPLATE_TO_USE="$STRUCT_TEMPLATE_PATH"
if [[ "$MODE" == "simple" ]]; then
  TEMPLATE_TO_USE="$SIMPLE_TEMPLATE_PATH"
fi

# banner + template -> output
cat "$BANNER_TEMPLATE_PATH" "$TEMPLATE_TO_USE" > "$OUTPUT_PATH"

if [[ "$MODE" == "structured" ]]; then
  # Uncomment optional mounts only if host dirs exist
  if [[ -d "$MAST_STAGE1_DIR" ]]; then
    uncomment_volume_line_for_placeholder "$OUTPUT_PATH" "mast_stage1_host"
  fi
  if [[ -d "$UNCAL_DIR" ]]; then
    uncomment_volume_line_for_placeholder "$OUTPUT_PATH" "uncalibrated_host"
  fi

  replace_placeholder "$OUTPUT_PATH" "analysis_dir_host" "$ANALYSIS_DIR"
  replace_placeholder "$OUTPUT_PATH" "mast_stage1_host" "$MAST_STAGE1_DIR"
  replace_placeholder "$OUTPUT_PATH" "uncalibrated_host" "$UNCAL_DIR"

  replace_placeholder "$OUTPUT_PATH" "planet" "$PLANET"
  replace_placeholder "$OUTPUT_PATH" "visit" "$VISIT"
  replace_placeholder "$OUTPUT_PATH" "analyst" "$ANALYST"
fi

# Common placeholders for both modes
replace_placeholder "$OUTPUT_PATH" "project_name" "$PROJECT_NAME"
replace_placeholder "$OUTPUT_PATH" "hostport" "$HOST_PORT"
replace_placeholder "$OUTPUT_PATH" "uid" "$ANALYST_UID"
replace_placeholder "$OUTPUT_PATH" "gid" "$ANALYST_GID"
replace_placeholder "$OUTPUT_PATH" "crds_bind_mode" "$CRDS_BIND_MODE"
replace_placeholder "$OUTPUT_PATH" "crds_dir" "$CRDS_DIR"
replace_placeholder "$OUTPUT_PATH" "crds_target" "$CRDS_TARGET"
replace_placeholder "$OUTPUT_PATH" "crds_path" "$CRDS_PATH"

# Remove sed backups (created by sed -i.bak)
rm -f "${OUTPUT_PATH}.bak" 2>/dev/null || true

# -----------------------------------------------------------------------------
# Write state file for wrapper (safe to source)
# -----------------------------------------------------------------------------
write_kv() {
  local k="$1" v="$2"
  # %q prints a shell-escaped representation safe for `source`
  printf '%s=%q\n' "$k" "$v"
}

{
  echo "# Auto-generated by configure_docker_compose.sh; safe to source. Do not edit."
  write_kv MODE "$MODE"
  write_kv PROJECT_NAME "$PROJECT_NAME"
  write_kv DATASET_SAFE "$DATASET_SAFE"
  write_kv PLANET "$PLANET"
  write_kv VISIT "$VISIT"
  write_kv ANALYST "$ANALYST"
  write_kv HOST_PORT "$HOST_PORT"
  write_kv COMPOSE_FILE "$OUTPUT_FILE"
} > "$STATE_PATH"

# -----------------------------------------------------------------------------
# Generate wrapper inside the run directory (copy from templates)
# -----------------------------------------------------------------------------
cp "$WRAPPER_TEMPLATE_PATH" "$WRAPPER_PATH"
chmod +x "$WRAPPER_PATH"

GREEN='\033[1;32m'; NC='\033[0m'
echo "Generated run directory: $RUN_DIR"
echo "  compose  = \"$OUTPUT_PATH\""
echo "  state    = \"$STATE_PATH\""
echo "  wrapper  = \"$WRAPPER_PATH\""
echo
echo "Project:"
echo "  project     = \"$PROJECT_NAME\""
echo "  hostport    = \"$HOST_PORT\""
echo "  CRDS dir    = \"$CRDS_DIR\""
echo "  CRDS layout = \"$CRDS_LAYOUT\""
echo "  CRDS target = \"$CRDS_TARGET\" (container)"
echo "  CRDS mode   = \"$CRDS_BIND_MODE\""
echo
echo -e "${GREEN}Next steps:${NC}"
echo "  cd \"$RUN_DIR\""
echo "  ./$WRAPPER up"
echo "  ./$WRAPPER logs   # shows Jupyter URL + token"
echo "                     # (If it looks empty at first, wait ~5–15 seconds and run it again.)"
echo "  ./$WRAPPER url    # prints ssh port-forward helper"
echo
echo "If you need to update the Docker image to a new version:"
echo "  ./$WRAPPER update # pull latest image + recreate"

