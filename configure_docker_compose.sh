#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# configure_docker_compose.sh
#
# Structured mode (recommended):
#   ./configure_docker_compose.sh <rootdir> <planet> <visit_num> <analyst> [<crds_dir>] [split|single]
#
#   - <visit_num> is an integer (e.g. 12). For backward compatibility we also accept:
#       visit12, visit012
#     and normalize to: visit12 (no zero padding).
#
# Simple mode (quick tests; no required host structure; no persistence by default):
#   ./configure_docker_compose.sh --simple [<crds_dir>] [split|single]
#
# Checkpoint mode (joint Stage 5 using multiple visits' outputs):
#   ./configure_docker_compose.sh --checkpoint <rootdir> <planet> <checkpoint> <analyst> <max_visit_num> \
#       [<crds_dir>] [split|single]
#
#   - Mounts visit roots read-only for visit1..visit<max_visit_num> (skips missing with warning)
#   - Creates a new checkpoint folder (RW) at:
#       <rootdir>/JWST/<planet>/<checkpoint>/<analyst>
#
# Outputs a run directory under:
#   runs/<planet>_<visit>/                     (structured)
#   runs/simple_<timestamp>/                   (simple)
#   runs/<planet>_<checkpoint>_maxvisit<N>/    (checkpoint)
#
# containing:
#   - docker-compose.yml
#   - .rwddt_state
#   - rwddt-run                      (wrapper)
# -----------------------------------------------------------------------------

# Resolve script directory so template lookup works regardless of cwd
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNS_ROOT="${SCRIPT_DIR}/runs"

# Templates live under templates/
TEMPLATES_DIR="${SCRIPT_DIR}/templates"

STRUCT_TEMPLATE_FILE="docker-compose.template.yml"
SIMPLE_TEMPLATE_FILE="docker-compose.simple.template.yml"
CHECKPOINT_TEMPLATE_FILE="docker-compose.checkpoint.template.yml"
BANNER_TEMPLATE_FILE="generated-compose-banner.txt"
WRAPPER_TEMPLATE_FILE="rwddt-run.template.sh"

STRUCT_TEMPLATE_PATH="${TEMPLATES_DIR}/${STRUCT_TEMPLATE_FILE}"
SIMPLE_TEMPLATE_PATH="${TEMPLATES_DIR}/${SIMPLE_TEMPLATE_FILE}"
CHECKPOINT_TEMPLATE_PATH="${TEMPLATES_DIR}/${CHECKPOINT_TEMPLATE_FILE}"
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
    ./configure_docker_compose.sh <rootdir> <planet> <visit_num> <analyst> [<crds_dir>] [split|single]

    Notes:
      - <visit_num> must be an integer (e.g. 12). For backward compatibility also accepts:
          visit12, visit012
        and will normalize to: visit12 (no zero padding).

  Simple mode (quick tests; no required host structure; no persistence by default):
    ./configure_docker_compose.sh --simple [<crds_dir>] [split|single]

  Checkpoint mode (joint Stage 5 using multiple visits' outputs):
    ./configure_docker_compose.sh --checkpoint <rootdir> <planet> <checkpoint> <analyst> <max_visit_num> \
        [<crds_dir>] [split|single]

    Notes:
      - Checkpoint mode mounts visit roots read-only for visit1..visit<max_visit_num>.
      - Visit directories are expected to be named: visit1, visit2, ... (no zero padding).
      - Checkpoint work area is created read-write at:
          <rootdir>/JWST/<planet>/<checkpoint>/<analyst>

CRDS layout:
  - split  mounts CRDS read-only at /grp/crds and sets CRDS_PATH=/grp/crds/cache
  - single mounts CRDS read-write at /crds     and sets CRDS_PATH=/crds

General:
  - <rootdir> must be an absolute path.
USAGE
}

normalize_visit() {
  # Accept: "12", "visit12", "visit012" -> normalize to VISIT_NUM=12, VISIT_DIR="visit12"
  local raw="$1"
  local num=""

  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    num="$raw"
  elif [[ "$raw" =~ ^visit([0-9]+)$ ]]; then
    num="${BASH_REMATCH[1]}"
  else
    echo "Error: visit must be an integer (e.g. 12) or 'visit#' (e.g. visit12). Got '$raw'." >&2
    exit 1
  fi

  # Force base-10 parse to drop leading zeros safely
  num=$((10#$num))

  if (( num < 1 )); then
    echo "Error: visit number must be >= 1 (got '$num')." >&2
    exit 1
  fi

  VISIT_NUM="$num"
  VISIT_DIR="visit${VISIT_NUM}"
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
    -e "s|^([[:space:]]*)#[[:space:]]*(-[[:space:]]*<${key}>:)|\\1\\2|" \
    "$file"
}

ensure_templates_exist() {
  local mode="$1"
  shift || true
  local files=("$@")
  local f
  for f in "${files[@]}"; do
    if [ ! -f "$f" ]; then
      echo "Error: required template not found for mode '${mode}': $f" >&2
      exit 1
    fi
  done
}

# -------- argument parsing --------
MODE="structured"
if [[ "${1:-}" == "--simple" ]]; then
  MODE="simple"
  shift || true
elif [[ "${1:-}" == "--checkpoint" ]]; then
  MODE="checkpoint"
  shift || true
fi

CRDS_DIR_DEFAULT="${HOME}/crds_cache"
LAYOUT_DEFAULT="single"

# Initialize vars (avoid unbound errors under set -u)
ROOTDIR=""; PLANET=""; VISIT=""; ANALYST=""; CHECKPOINT=""
MAX_VISIT_NUM=""
CRDS_DIR="$CRDS_DIR_DEFAULT"
CRDS_LAYOUT="$LAYOUT_DEFAULT"

if [[ "$MODE" == "structured" ]]; then
  if [ "$#" -lt 4 ] || [ "$#" -gt 6 ]; then
    usage
    exit 1
  fi

  ROOTDIR=$1
  PLANET=$2
  RAW_VISIT=$3
  ANALYST=$4
  CRDS_DIR="${5:-$CRDS_DIR_DEFAULT}"
  CRDS_LAYOUT="${6:-$LAYOUT_DEFAULT}"

  normalize_visit "$RAW_VISIT"
  VISIT="$VISIT_DIR"  # always "visit#"

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

  ensure_templates_exist "structured" \
    "$STRUCT_TEMPLATE_PATH" "$BANNER_TEMPLATE_PATH" "$WRAPPER_TEMPLATE_PATH"

elif [[ "$MODE" == "simple" ]]; then
  if [ "$#" -gt 2 ]; then
    usage
    exit 1
  fi

  CRDS_DIR="${1:-$CRDS_DIR_DEFAULT}"
  CRDS_LAYOUT="${2:-$LAYOUT_DEFAULT}"

  ensure_templates_exist "simple" \
    "$SIMPLE_TEMPLATE_PATH" "$BANNER_TEMPLATE_PATH" "$WRAPPER_TEMPLATE_PATH"

elif [[ "$MODE" == "checkpoint" ]]; then
  # Mandatory positional args:
  #   <rootdir> <planet> <checkpoint> <analyst> <max_visit_num>
  # Optional:
  #   [<crds_dir>] [split|single]
  if [ "$#" -lt 5 ] || [ "$#" -gt 7 ]; then
    usage
    exit 1
  fi

  ROOTDIR=$1
  PLANET=$2
  CHECKPOINT=$3
  ANALYST=$4
  MAX_VISIT_RAW=$5
  CRDS_DIR="${6:-$CRDS_DIR_DEFAULT}"
  CRDS_LAYOUT="${7:-$LAYOUT_DEFAULT}"

  case "$ROOTDIR" in
    /*) : ;;
    *) echo "Error: <rootdir> must be an absolute path (got '$ROOTDIR')." >&2; exit 1 ;;
  esac
  if [ ! -d "$ROOTDIR" ]; then
    echo "Error: <rootdir> '$ROOTDIR' does not exist or is not a directory." >&2
    exit 1
  fi

  if ! [[ "$MAX_VISIT_RAW" =~ ^[0-9]+$ ]]; then
    echo "Error: <max_visit_num> must be an integer (got '$MAX_VISIT_RAW')." >&2
    exit 1
  fi
  MAX_VISIT_NUM=$((10#$MAX_VISIT_RAW))
  if (( MAX_VISIT_NUM < 1 )); then
    echo "Error: <max_visit_num> must be >= 1 (got '$MAX_VISIT_NUM')." >&2
    exit 1
  fi

  PLANET_DIR="${ROOTDIR%/}/JWST/${PLANET}"
  if [ ! -d "$PLANET_DIR" ]; then
    echo "Error: planet directory does not exist: $PLANET_DIR" >&2
    echo "Create $ROOTDIR/JWST/$PLANET first, or fix your arguments." >&2
    exit 1
  fi

  ensure_templates_exist "checkpoint" \
    "$CHECKPOINT_TEMPLATE_PATH" "$BANNER_TEMPLATE_PATH" "$WRAPPER_TEMPLATE_PATH"
else
  echo "Error: unknown MODE '$MODE'." >&2
  usage
  exit 1
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

PLANET_SAFE="$(sanitize "${PLANET:-unknown}")"

if [[ "$MODE" == "structured" ]]; then
  VISIT_SAFE="$(sanitize "$VISIT")"
  DATASET_SAFE="${PLANET_SAFE}_${VISIT_SAFE}"
  RUN_DIR="${RUNS_ROOT}/${DATASET_SAFE}"
  PROJECT_NAME="rwddt_${USER_SAFE}_${DATASET_SAFE}"

  BASE_VISIT_DIR="${ROOTDIR%/}/JWST/${PLANET}/${VISIT}"
  ANALYSIS_DIR="$BASE_VISIT_DIR/$ANALYST"
  NOTEBOOKS_DIR="$ANALYSIS_DIR/notebooks"

  MAST_STAGE1_DIR="$BASE_VISIT_DIR/MAST_Stage1"
  UNCAL_DIR="$BASE_VISIT_DIR/Uncalibrated"

  mkdir -p "$NOTEBOOKS_DIR"

  # Ensure minimum perms (add-only; never reduces existing perms)
  chmod u+rwx "$ANALYSIS_DIR" "$NOTEBOOKS_DIR" 2>/dev/null || true
  chmod g+s "$ANALYSIS_DIR" "$NOTEBOOKS_DIR" 2>/dev/null || true
  chmod o+x  "$ANALYSIS_DIR" "$NOTEBOOKS_DIR" 2>/dev/null || true

elif [[ "$MODE" == "simple" ]]; then
  TS="$(date +%Y%m%d_%H%M%S)"
  DATASET_SAFE="simple_${TS}"
  RUN_DIR="${RUNS_ROOT}/${DATASET_SAFE}"
  PROJECT_NAME="rwddt_${USER_SAFE}_${DATASET_SAFE}"

  ANALYSIS_DIR=""
  NOTEBOOKS_DIR=""
  MAST_STAGE1_DIR=""
  UNCAL_DIR=""

elif [[ "$MODE" == "checkpoint" ]]; then
  CHECKPOINT_SAFE="$(sanitize "$CHECKPOINT")"
  # Include planet + checkpoint + maxvisit so multiple checkpoints don't collide
  DATASET_SAFE="${PLANET_SAFE}_${CHECKPOINT_SAFE}_maxvisit${MAX_VISIT_NUM}"
  RUN_DIR="${RUNS_ROOT}/${DATASET_SAFE}"
  PROJECT_NAME="rwddt_${USER_SAFE}_${DATASET_SAFE}"

  CHECKPOINT_ANALYSIS_DIR="${ROOTDIR%/}/JWST/${PLANET}/${CHECKPOINT}/${ANALYST}"
  NOTEBOOKS_DIR="${CHECKPOINT_ANALYSIS_DIR}/notebooks"
  mkdir -p "$NOTEBOOKS_DIR"

  chmod u+rwx "$CHECKPOINT_ANALYSIS_DIR" "$NOTEBOOKS_DIR" 2>/dev/null || true
  chmod g+s "$CHECKPOINT_ANALYSIS_DIR" "$NOTEBOOKS_DIR" 2>/dev/null || true
  chmod o+x  "$CHECKPOINT_ANALYSIS_DIR" "$NOTEBOOKS_DIR" 2>/dev/null || true

  ANALYSIS_DIR=""       # not used
  MAST_STAGE1_DIR=""    # not used
  UNCAL_DIR=""          # not used
fi

mkdir -p "$RUN_DIR"

OUTPUT_PATH="${RUN_DIR}/${OUTPUT_FILE}"
STATE_PATH="${RUN_DIR}/${STATE_FILE}"
WRAPPER_PATH="${RUN_DIR}/${WRAPPER}"

# -----------------------------------------------------------------------------
# Generate docker-compose.yml from template (all modes)
#   - Prepend banner from templates/generated-compose-banner.txt
# -----------------------------------------------------------------------------
TEMPLATE_TO_USE="$STRUCT_TEMPLATE_PATH"
if [[ "$MODE" == "simple" ]]; then
  TEMPLATE_TO_USE="$SIMPLE_TEMPLATE_PATH"
elif [[ "$MODE" == "checkpoint" ]]; then
  TEMPLATE_TO_USE="$CHECKPOINT_TEMPLATE_PATH"
fi

# banner + template -> output
cat "$BANNER_TEMPLATE_PATH" "$TEMPLATE_TO_USE" > "$OUTPUT_PATH"

# -----------------------------------------------------------------------------
# Checkpoint mode: inject RO mounts for visit roots visit1..visitN
#   The checkpoint template must include a line:
#     # __VISIT_ROOT_MOUNTS__
# -----------------------------------------------------------------------------
MOUNTED_VISITS_CSV=""
if [[ "$MODE" == "checkpoint" ]]; then
  PLANET_DIR="${ROOTDIR%/}/JWST/${PLANET}"

  VIS_TMP="$(mktemp)"
  : > "$VIS_TMP"

  declare -a MOUNTED_VISITS=()

  for ((i=1; i<=MAX_VISIT_NUM; i++)); do
    vdir="visit${i}"
    host="${PLANET_DIR}/${vdir}"
    if [[ -d "$host" ]]; then
      # Mount visit root read-only at the same relative path inside container
      printf '      - %s:/mnt/rwddt/JWST/%s/%s:ro\n' "$host" "$PLANET" "$vdir" >> "$VIS_TMP"
      MOUNTED_VISITS+=("$vdir")
    else
      echo "Warning: missing visit directory (skipping): $host" >&2
    fi
  done

  if (( ${#MOUNTED_VISITS[@]} == 0 )); then
    echo "Error: no visit directories found from visit1..visit${MAX_VISIT_NUM} under $PLANET_DIR" >&2
    rm -f "$VIS_TMP" 2>/dev/null || true
    exit 1
  fi

  MOUNTED_VISITS_CSV="$(IFS=,; echo "${MOUNTED_VISITS[*]}")"

  # Robust insertion via awk (avoids sed newline escaping headaches)
  OUT_TMP="$(mktemp)"
  awk -v mounts_file="$VIS_TMP" '
    { print }
    /# __VISIT_ROOT_MOUNTS__/ {
      while ((getline line < mounts_file) > 0) print line
      close(mounts_file)
    }
  ' "$OUTPUT_PATH" > "$OUT_TMP"
  mv "$OUT_TMP" "$OUTPUT_PATH"

  rm -f "$VIS_TMP" 2>/dev/null || true
fi

# -----------------------------------------------------------------------------
# Fill placeholders
# -----------------------------------------------------------------------------
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
  replace_placeholder "$OUTPUT_PATH" "visit" "$VISIT"     # "visit#"
  replace_placeholder "$OUTPUT_PATH" "analyst" "$ANALYST"
fi

if [[ "$MODE" == "checkpoint" ]]; then
  replace_placeholder "$OUTPUT_PATH" "planet" "$PLANET"
  replace_placeholder "$OUTPUT_PATH" "checkpoint" "$CHECKPOINT"
  replace_placeholder "$OUTPUT_PATH" "analyst" "$ANALYST"
  replace_placeholder "$OUTPUT_PATH" "checkpoint_dir_host" "$CHECKPOINT_ANALYSIS_DIR"
fi

# Common placeholders for all modes
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

  if [[ "$MODE" == "checkpoint" ]]; then
    write_kv CHECKPOINT "$CHECKPOINT"
    write_kv MAX_VISIT_NUM "$MAX_VISIT_NUM"
    write_kv VISITS_CSV "$MOUNTED_VISITS_CSV"
  fi
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

if [[ "$MODE" == "structured" ]]; then
  echo
  echo "Structured dataset:"
  echo "  planet  = \"$PLANET\""

