#!/usr/bin/env sh
set -eu

COMPOSE_FILE="${COMPOSE_FILE:-security-stack.compose.yml}"
PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-}"
PROFILES="${SECSTACK_PROFILES:-all}"
TIMEOUT_SECONDS="${KILLSWITCH_TIMEOUT_SECONDS:-60}"
MODE="${1:-stop}"
CONTAINER_ENGINE="${CONTAINER_ENGINE:-}"

log() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

compose() {
  env_args=""
  if [ -f ".env" ]; then
    env_args="--env-file .env"
  fi
  # shellcheck disable=SC2086
  "${CONTAINER_ENGINE}" compose ${env_args} -f "${COMPOSE_FILE}" "$@"
}

load_project_name() {
  if [ -n "${PROJECT_NAME}" ]; then
    return 0
  fi
  if [ -f ".env" ]; then
    PROJECT_NAME="$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' .env | tail -n 1)"
    PROJECT_NAME="${PROJECT_NAME#\"}"
    PROJECT_NAME="${PROJECT_NAME%\"}"
    PROJECT_NAME="${PROJECT_NAME#\'}"
    PROJECT_NAME="${PROJECT_NAME%\'}"
  fi
  if [ -z "${PROJECT_NAME}" ]; then
    PROJECT_NAME="$(basename "${PROJECT_ROOT}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
  fi
}

select_container_engine() {
  if [ -n "${CONTAINER_ENGINE}" ]; then
    if ! command -v "${CONTAINER_ENGINE}" >/dev/null 2>&1; then
      echo "Missing container engine: ${CONTAINER_ENGINE}" >&2
      exit 127
    fi
    if ! "${CONTAINER_ENGINE}" compose version >/dev/null 2>&1; then
      echo "${CONTAINER_ENGINE} compose is unavailable; install/configure its Compose provider" >&2
      exit 127
    fi
  elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    CONTAINER_ENGINE=docker
  elif command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
    CONTAINER_ENGINE=podman
  else
    echo "Missing container engine: install Docker Compose or Podman with a Compose provider" >&2
    exit 127
  fi
  export CONTAINER_ENGINE
}

profile_args() {
  for profile in ${PROFILES}; do
    printf -- '--profile\n%s\n' "${profile}"
  done
}

project_container_ids() {
  label="$1"
  "${CONTAINER_ENGINE}" ps -q --filter "label=${label}=${PROJECT_NAME}"
}

stop_project_containers() {
  found=false
  for label in com.docker.compose.project io.podman.compose.project; do
    containers="$(project_container_ids "${label}")"
    if [ -n "${containers}" ]; then
      found=true
      # The output contains only container IDs, so shell word splitting is safe.
      # shellcheck disable=SC2086
      set -- ${containers}
      log "stopping ${#} running containers labeled ${label}=${PROJECT_NAME}"
      "${CONTAINER_ENGINE}" stop --time "${TIMEOUT_SECONDS}" "$@"
    fi
  done
  if [ "${found}" = false ]; then
    log "no running containers found for project ${PROJECT_NAME}"
  fi
}

remove_project_containers() {
  for label in com.docker.compose.project io.podman.compose.project; do
    containers="$("${CONTAINER_ENGINE}" ps -aq --filter "label=${label}=${PROJECT_NAME}")"
    if [ -n "${containers}" ]; then
      # The output contains only container IDs, so shell word splitting is safe.
      # shellcheck disable=SC2086
      set -- ${containers}
      log "removing ${#} containers labeled ${label}=${PROJECT_NAME}"
      "${CONTAINER_ENGINE}" rm --force "$@"
    fi
  done
}

usage() {
  cat <<'USAGE'
usage: scripts/killswitch.sh [stop|down|pause]

Modes:
  stop   Gracefully stop containers and preserve networks, volumes, backups, and reports. Default.
  down   Stop and remove containers/networks, preserving named volumes.
  pause  Pause running containers without stopping processes.

Environment:
  SECSTACK_PROFILES="all"             Profiles to target.
  KILLSWITCH_TIMEOUT_SECONDS="60"     Graceful stop timeout.
  COMPOSE_PROJECT_NAME="..."          Project label value (defaults to the repository directory name).
  COMPOSE_FILE="security-stack.compose.yml"
  CONTAINER_ENGINE="docker", "podman", or an explicit compatible engine (auto-selects Docker, then Podman).
USAGE
}

main() {
  if [ "${MODE}" = "-h" ] || [ "${MODE}" = "--help" ]; then
    usage
    exit 0
  fi

  select_container_engine
  cd "${PROJECT_ROOT}"
  load_project_name
  log "killswitch mode=${MODE} profiles=${PROFILES} project=${PROJECT_NAME}"

  case "${MODE}" in
    stop)
      stop_project_containers
      ;;
    down)
      if ! compose $(profile_args) down --remove-orphans --timeout "${TIMEOUT_SECONDS}"; then
        log "Compose down failed; removing containers by project label"
      fi
      remove_project_containers
      ;;
    pause)
      compose $(profile_args) pause || true
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac

  compose $(profile_args) ps || true
  log "killswitch complete; named volumes were not removed"
}

main "$@"
