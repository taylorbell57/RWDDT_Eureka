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

# Use sudo only if required (helps community users who can run docker without sudo)
DOCKER="docker"
NEED_SUDO_MSG=0
if ! docker info >/dev/null 2>&1; then
  if command -v sudo >/dev/null 2>&1; then
    DOCKER="sudo docker"
    NEED_SUDO_MSG=1
  fi
fi

# If we will be using sudo for Docker, warn before sudo authentication prompt
if [[ "$NEED_SUDO_MSG" -eq 1 ]]; then
  echo "Note: Docker requires elevated privileges on this host." >&2
  echo "      Running Docker via sudo; you may be prompted for your password." >&2
  echo "      (Depending on sudo credential caching/TTY settings, you might not be asked every time.)" >&2
fi

DC="${DOCKER} compose -p ${PROJECT_NAME} -f ${COMPOSE_FILE}"

cmd="${1:-}"; shift || true
case "$cmd" in
  up)
    $DC up -d --pull missing
    echo "Started: ${PROJECT_NAME}"
    ;;
  update)
    $DC up -d --pull always --force-recreate
    echo "Updated: ${PROJECT_NAME}"
    ;;
  down)
    $DC down --remove-orphans
    echo "Stopped: ${PROJECT_NAME}"
    ;;
  ps|status)
    $DC ps
    ;;
  logs)
    echo "Tip: if the URL/token isn't shown yet, wait ~5–15 seconds and run './rwddt-run logs' again."
    # If stdout is a terminal, follow logs. If piped/non-interactive, print a finite tail and exit.
    if [ -t 1 ]; then
      $DC logs -f --tail=200
    else
      $DC logs --tail=200
    fi
    ;;
  exec)
    $DC exec rwddt_eureka "$@"
    ;;
  url)
    echo "Project: ${PROJECT_NAME}"
    echo "Host port -> container 8888: ${HOST_PORT}"
    echo
    echo "Forward it (example):"
    echo "  ssh -L ${HOST_PORT}:localhost:${HOST_PORT} <user>@<remote-host>"
    echo "  (Keep that terminal open while you use JupyterLab; type 'exit' to close the tunnel.)"
    echo "Then open:"
    echo "  http://localhost:${HOST_PORT}/"
    ;;
  *)
    cat <<USAGE
Usage: ./rwddt-run <command>

Commands:
  up        Start container (detached), pulls if missing
  update    Pull newest image + force recreate
  logs      Follow logs (TTY) or print tail (piped)
  url       Show port-forward + URL
  ps        Status
  exec ...  Run a command inside container (e.g. ./rwddt-run exec bash)
  down      Stop/remove this dataset container
USAGE
    exit 1
    ;;
esac
