#!/usr/bin/env sh
# Stop containers created by scripts/start.sh and simplified.compose.yml.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
COMPOSE_FILE="$ROOT/simplified.compose.yml"
MODE="${1:-stop}"
TIMEOUT_SECONDS="${KILLSWITCH_TIMEOUT_SECONDS:-60}"

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
    compose --profile mvp down --remove-orphans --timeout "$TIMEOUT_SECONDS"
    log "MVP containers and network removed; volumes and images were preserved"
    ;;
esac