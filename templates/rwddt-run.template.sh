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
PULL_POLICY="${RWDDT_PULL_POLICY:-always}"

service_image_ref() {
  "${DC[@]}" config --images | sed -n '1p'
}

running_container_id() {
  "${DC[@]}" ps -q rwddt_eureka
}

local_image_id() {
  local image_ref="$1"
  docker_cmd image inspect --format '{{.Id}}' "$image_ref"
}

print_running_image() {
  local container_id image_ref image_id repo_digest metadata
  local rwddt_version eureka_ref notebooks_ref
  container_id="$(running_container_id)"
  if [[ -z "$container_id" ]]; then
    echo "ERROR: rwddt_eureka container is not running." >&2
    return 1
  fi

  image_ref="$(docker_cmd container inspect --format '{{.Config.Image}}' "$container_id")"
  image_id="$(docker_cmd container inspect --format '{{.Image}}' "$container_id")"
  repo_digest="$(
    docker_cmd image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$image_id" \
      | sed -n '1p'
  )"
  metadata="$(
    docker_cmd image inspect \
      --format '{{index .Config.Labels "org.opencontainers.image.version"}}|{{index .Config.Labels "io.github.taylorbell57.rwddt.eureka-ref"}}|{{index .Config.Labels "io.github.taylorbell57.rwddt.notebooks-ref"}}' \
      "$image_id"
  )"
  IFS='|' read -r rwddt_version eureka_ref notebooks_ref <<< "$metadata"

  echo "Image reference: ${image_ref}"
  # The custom ref labels distinguish current RWDDT metadata from the Ubuntu
  # version label inherited by images built before RWDDT versioning was added.
  if [[ -n "$eureka_ref" && "$eureka_ref" != "<no value>" ]]; then
    echo "RWDDT version:  ${rwddt_version}"
    echo "Eureka ref:     ${eureka_ref}"
    echo "Notebooks ref:  ${notebooks_ref}"
  else
    echo "RWDDT version:  unavailable (image predates embedded RWDDT metadata)"
  fi
  echo "Image ID:        ${image_id}"
  if [[ -n "$repo_digest" ]]; then
    echo "Repository digest: ${repo_digest}"
  else
    echo "Repository digest: unavailable (expected for some locally built images)"
  fi
}

cmd="${1:-}"; shift || true
case "$cmd" in
  up)
    case "$PULL_POLICY" in
      always|missing|never) ;;
      *)
        echo "ERROR: RWDDT_PULL_POLICY must be one of: always, missing, never (got '$PULL_POLICY')." >&2
        exit 1
        ;;
    esac
    "${DC[@]}" up -d --pull "$PULL_POLICY"
    echo "Started: ${PROJECT_NAME}"
    print_running_image
    ;;
  update)
    if [[ "${BUILD_LOCAL:-0}" -eq 1 ]]; then
      echo "Stopping: ${PROJECT_NAME}"
      "${DC[@]}" down --remove-orphans
      echo "Rebuilding local image and starting: ${PROJECT_NAME}"
      "${DC[@]}" up -d --build --pull always --force-recreate
      echo "Updated: ${PROJECT_NAME}"
      print_running_image
    else
      image_ref="$(service_image_ref)"
      if [[ -z "$image_ref" ]]; then
        echo "ERROR: Could not resolve the rwddt_eureka image from ${COMPOSE_FILE}." >&2
        exit 1
      fi

      echo "Stopping: ${PROJECT_NAME}"
      echo "Bind-mounted host files are preserved."
      "${DC[@]}" down --remove-orphans

      echo "Pulling: ${image_ref}"
      "${DC[@]}" pull rwddt_eureka
      expected_image_id="$(local_image_id "$image_ref")"
      echo "Pulled image ID: ${expected_image_id}"

      # Start the exact image just verified above. Avoid a second pull here so a
      # mutable tag cannot move between verification and container creation.
      "${DC[@]}" up -d --pull never --force-recreate

      container_id="$(running_container_id)"
      if [[ -z "$container_id" ]]; then
        echo "ERROR: Updated rwddt_eureka container is not running." >&2
        exit 1
      fi
      running_image_id="$(docker_cmd container inspect --format '{{.Image}}' "$container_id")"
      if [[ "$running_image_id" != "$expected_image_id" ]]; then
        echo "ERROR: Running image does not match the image that was pulled." >&2
        echo "  pulled:  ${expected_image_id}" >&2
        echo "  running: ${running_image_id}" >&2
        exit 1
      fi

      echo "Updated and verified: ${PROJECT_NAME}"
      print_running_image
    fi
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
  up        Start container, checking for a newer image by default
  update    Stop, pull/rebuild, relaunch, and verify the running image
  logs      Follow logs (TTY) or print tail (piped)
  url       Show port-forward + URL
  info      Show configuration summary for this run directory
  ps        Status
  exec ...  Run a command inside container (e.g. ./rwddt-run exec bash)
  down      Stop/remove this dataset container

Environment:
  RWDDT_PULL_POLICY=always|missing|never
            Image pull behavior for 'up' (default: always)
USAGE
    exit 1
    ;;
esac
