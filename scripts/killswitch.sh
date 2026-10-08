#!/usr/bin/env sh
set -eu

COMPOSE_FILE="${COMPOSE_FILE:-security-stack.compose.yml}"
PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PROFILES="${SECSTACK_PROFILES:-all}"
TIMEOUT_SECONDS="${KILLSWITCH_TIMEOUT_SECONDS:-60}"
MODE="${1:-stop}"
CONTAINER_ENGINE="${CONTAINER_ENGINE:-}"

log() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

compose() {
  "${CONTAINER_ENGINE}" compose -f "${COMPOSE_FILE}" "$@"
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
  log "killswitch mode=${MODE} profiles=${PROFILES}"

  case "${MODE}" in
    stop)
      compose $(profile_args) stop -t "${TIMEOUT_SECONDS}"
      ;;
    down)
      compose $(profile_args) down --remove-orphans --timeout "${TIMEOUT_SECONDS}"
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
