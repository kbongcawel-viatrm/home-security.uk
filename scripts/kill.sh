#!/usr/bin/env sh
# Stop containers created by scripts/start.sh and simplified.compose.yml.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
COMPOSE_FILE="$ROOT/simplified.compose.yml"
MODE="${1:-down}"
TIMEOUT_SECONDS="${KILLSWITCH_TIMEOUT_SECONDS:-60}"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-}"

log() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

if [ -t 1 ] || [ "${FORCE_COLOR:-}" = 1 ]; then
  COLOR_STOP=$(printf '\033[1;31m')
  COLOR_RESET=$(printf '\033[0m')
else
  COLOR_STOP=''
  COLOR_RESET=''
fi

log_stopping() {
  printf '%s %s%s%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$COLOR_STOP" "$*" "$COLOR_RESET"
}

progress() {
  current="$1"
  total="$2"
  label="$3"
  width=30
  filled=$(( current * width / total ))
  empty=$(( width - filled ))
  bar="$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' "$empty" '' | tr ' ' '.')"
  if [ -t 1 ] || [ "${FORCE_COLOR:-}" = 1 ]; then
    printf '\r%s %s[%s] %s/%s%s' "$COLOR_STOP" "$label " "$bar" "$current" "$total" "$COLOR_RESET"
  else
    printf '%s %s [%s] %s/%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$label" "$bar" "$current" "$total"
  fi
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: scripts/kill.sh [stop|down|status]

With no argument, the default mode is down.

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
    total="$(printf '%s\n' "$ids" | wc -l | tr -d ' ')"
    removed=0
    for id in $ids; do
      podman rm --force "$id" >/dev/null
      removed=$((removed + 1))
      progress "$removed" "$total" "Removing containers"
    done
    printf '\n'
  done
}

load_project_name
log "Mode=$MODE compose=$COMPOSE file=$COMPOSE_FILE profile=mvp"

case "$MODE" in
  status)
    compose --profile mvp ps
    ;;
  stop)
    log_stopping "Stopping MVP containers"
    compose --profile mvp stop --timeout "$TIMEOUT_SECONDS"
    log_stopping "MVP containers stopped; containers, network, volumes, and images were preserved"
    ;;
  down)
    log_stopping "Stopping MVP containers before removal"
    compose --profile mvp stop --timeout "$TIMEOUT_SECONDS" || \
      log "Compose stop reported an error; continuing with teardown"
    compose --profile mvp down --remove-orphans --timeout "$TIMEOUT_SECONDS" || \
      log "Compose down reported an error; continuing with label-based container cleanup"
    remove_stale_containers
    log "MVP containers removed; network, volumes, and images were preserved"
    ;;
esac