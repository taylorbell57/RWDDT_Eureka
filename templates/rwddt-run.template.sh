#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

STATE_FILE=".rwddt_state"
if [[ ! -f "$STATE_FILE" ]]; then
  echo "ERROR: $STATE_FILE not found in $HERE. Re-run configure_docker_compose.sh" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$STATE_FILE"

# -----------------------------------------------------------------------------
# Docker / Compose command selection
#  - Prefer "docker compose" (plugin)
#  - Fall back to "docker-compose" if needed
#  - Use sudo only if required
# -----------------------------------------------------------------------------
DOCKER_BIN="docker"
SUDO_BIN=""

if ! docker info >/dev/null 2>&1; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO_BIN="sudo"
  fi
fi

# Helper to run docker (optionally via sudo)
docker_cmd() {
  if [[ -n "$SUDO_BIN" ]]; then
    "$SUDO_BIN" "$DOCKER_BIN" "$@"
  else
    "$DOCKER_BIN" "$@"
  fi
}

NEED_SUDO_MSG=0
if [[ -n "$SUDO_BIN" ]]; then
  NEED_SUDO_MSG=1
fi

if [[ "$NEED_SUDO_MSG" -eq 1 ]]; then
  echo "Note: Docker requires elevated privileges on this host." >&2
  echo "      Running Docker via sudo; you may be prompted for your password." >&2
  echo "      (Depending on sudo credential caching/TTY settings, you might not be asked every time.)" >&2
fi

# Determine whether to use "docker compose" or "docker-compose"
COMPOSE_MODE="docker_compose_plugin"
if docker_cmd compose version >/dev/null 2>&1; then
  COMPOSE_MODE="docker_compose_plugin"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_MODE="docker_compose_v1"
else
  echo "ERROR: Neither 'docker compose' nor 'docker-compose' is available." >&2
  echo "       Install Docker Compose plugin or docker-compose v1." >&2
  exit 1
fi

# Build compose command as an array for safe quoting
DC=()
if [[ "$COMPOSE_MODE" == "docker_compose_plugin" ]]; then
  DC=(docker_cmd compose -p "${PROJECT_NAME}" -f "${COMPOSE_FILE}")
else
  # docker-compose v1 does not take "docker_cmd" function directly; handle sudo explicitly
  if [[ -n "$SUDO_BIN" ]]; then
    DC=(sudo docker-compose -p "${PROJECT_NAME}" -f "${COMPOSE_FILE}")
  else
    DC=(docker-compose -p "${PROJECT_NAME}" -f "${COMPOSE_FILE}")
  fi
fi

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------
cmd="${1:-}"; shift || true
case "$cmd" in
  up)
    "${DC[@]}" up -d --pull missing
    echo "Started: ${PROJECT_NAME}"
    ;;
  update)
    "${DC[@]}" up -d --pull always --force-recreate
    echo "Updated: ${PROJECT_NAME}"
    ;;
  down)
    "${DC[@]}" down --remove-orphans
    echo "Stopped: ${PROJECT_NAME}"
    ;;
  ps|status)
    "${DC[@]}" ps
    ;;
  logs)
    echo "Tip: if the URL/token isn't shown yet, wait ~5–15 seconds and run './rwddt-run logs' again."
    # If stdout is a terminal, follow logs. If piped/non-interactive, print a finite tail and exit.
    if [ -t 1 ]; then
      "${DC[@]}" logs -f --tail=200
    else
      "${DC[@]}" logs --tail=200
    fi
    ;;
  exec)
    "${DC[@]}" exec rwddt_eureka "$@"
    ;;
  info)
    echo "Run directory: ${HERE}"
    echo "Project:      ${PROJECT_NAME}"
    echo "Compose file: ${COMPOSE_FILE}"
    echo "Host port:    ${HOST_PORT}"
    echo "Mode:         ${MODE:-structured}"
    if [[ "${MODE:-structured}" == "checkpoint" ]]; then
      echo "Planet:       ${PLANET}"
      echo "Checkpoint:   ${CHECKPOINT:-}"
      echo "Max visit:    ${MAX_VISIT_NUM:-}"
      if [[ -n "${VISITS_CSV:-}" ]]; then
        echo "Mounted:      ${VISITS_CSV}"
      fi
      echo "In-container:"
      echo "  /home/rwddt/analysis  (RW checkpoint workspace)"
      echo "  /home/rwddt/notebooks"
      echo "  /home/rwddt/visits   -> /mnt/rwddt/JWST/${PLANET}"
    else
      echo "Planet:       ${PLANET:-}"
      echo "Visit:        ${VISIT:-}"
      echo "Analyst:      ${ANALYST:-}"
      echo "In-container:"
      echo "  /home/rwddt/analysis"
      echo "  /home/rwddt/notebooks"
      echo "  /home/rwddt/MAST_Stage1"
      echo "  /home/rwddt/Uncalibrated"
    fi
    ;;
  url)
    echo "Project: ${PROJECT_NAME}"
    echo "Host port -> container 8888: ${HOST_PORT}"
    if [[ "${MODE:-structured}" == "checkpoint" ]]; then
      echo
      echo "Checkpoint mode:"
      echo "  planet     = ${PLANET}"
      echo "  checkpoint = ${CHECKPOINT:-}"
      echo "  max_visit  = ${MAX_VISIT_NUM:-}"
      if [[ -n "${VISITS_CSV:-}" ]]; then
        echo "  mounted    = ${VISITS_CSV}"
      fi
    fi
    echo
    echo "Forward it (example):"
    echo "  ssh -L ${HOST_PORT}:localhost:${HOST_PORT} <user>@<remote-host>"
    echo "  (Keep that terminal open while you use JupyterLab; type 'exit' to close the tunnel.)"
    echo "Then open:"
    echo "  http://localhost:${HOST_PORT}/"
    ;;
  *)
    cat <<'USAGE'
Usage: ./rwddt-run <command>

Commands:
  up        Start container (detached), pulls if missing
  update    Pull newest image + force recreate
  logs      Follow logs (TTY) or print tail (piped)
  url       Show port-forward + URL
  info      Show configuration summary for this run directory
  ps        Status
  exec ...  Run a command inside container (e.g. ./rwddt-run exec bash)
  down      Stop/remove this dataset container
USAGE
    exit 1
    ;;
esac

