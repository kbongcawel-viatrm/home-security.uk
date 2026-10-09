#!/usr/bin/env sh
# Stop containers created by scripts/start.sh and simplified.compose.yml.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
COMPOSE_FILE="$ROOT/simplified.compose.yml"
MODE="${1:-stop}"
TIMEOUT_SECONDS="${KILLSWITCH_TIMEOUT_SECONDS:-60}"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-}"

log() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: scripts/kill.sh [stop|down|status]

stop    Gracefully stop MVP containers and keep containers, networks, and volumes.
down    Stop and remove MVP containers and its network; keep named volumes and images.
status  Show MVP container status without changing resources.

The script always targets simplified.compose.yml and the mvp profile.
Set KILLSWITCH_TIMEOUT_SECONDS to change the graceful stop timeout.
USAGE
}

case "$MODE" in
  -h|--help)
    usage
    exit 0
    ;;
  stop|down|status)
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

case "$TIMEOUT_SECONDS" in
  ''|*[!0-9]*) fail "KILLSWITCH_TIMEOUT_SECONDS must be a non-negative integer" ;;
esac

[ -f "$COMPOSE_FILE" ] || fail "Compose file not found: $COMPOSE_FILE"
cd "$ROOT"

if command -v podman-compose >/dev/null 2>&1; then
  COMPOSE="podman-compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE="docker-compose"
else
  fail "podman-compose or docker-compose is required"
fi

compose() {
  if [ -f .env ]; then
    "$COMPOSE" --env-file .env -f "$COMPOSE_FILE" "$@"
  else
    "$COMPOSE" -f "$COMPOSE_FILE" "$@"
  fi
}

load_project_name() {
  [ -n "$PROJECT_NAME" ] && return 0
  if [ -f .env ]; then
    PROJECT_NAME="$(sed -n 's/^COMPOSE_PROJECT_NAME[[:space:]]*=[[:space:]]*//p' .env | tail -n 1)"
    PROJECT_NAME="${PROJECT_NAME#\"}"; PROJECT_NAME="${PROJECT_NAME%\"}"
    PROJECT_NAME="${PROJECT_NAME#\'}"; PROJECT_NAME="${PROJECT_NAME%\'}"
  fi
  PROJECT_NAME="${PROJECT_NAME:-home-security-uk}"
}

remove_stale_containers() {
  command -v podman >/dev/null 2>&1 || return 0
  for label in com.docker.compose.project io.podman.compose.project; do
    ids="$(podman ps -aq --filter "label=$label=$PROJECT_NAME")"
    [ -n "$ids" ] || continue
    log "Removing all containers with $label=$PROJECT_NAME"
    # shellcheck disable=SC2086
    podman rm --force $ids
  done
}

load_project_name
log "Mode=$MODE compose=$COMPOSE file=$COMPOSE_FILE profile=mvp"

case "$MODE" in
  status)
    compose --profile mvp ps
    ;;
  stop)
    compose --profile mvp stop --timeout "$TIMEOUT_SECONDS"
    log "MVP containers stopped; containers, network, volumes, and images were preserved"
    ;;
  down)
    compose --profile mvp down --remove-orphans --timeout "$TIMEOUT_SECONDS" || \
      log "Compose down reported an error; continuing with label-based container cleanup"
    remove_stale_containers
    log "MVP containers removed; network, volumes, and images were preserved"
    ;;
esac