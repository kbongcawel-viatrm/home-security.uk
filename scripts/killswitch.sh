#!/usr/bin/env sh
# Remove this Compose project's containers, networks, and volumes while preserving images.
set -eu

COMPOSE_FILE="${COMPOSE_FILE:-security-stack.compose.yml}"
PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-}"
PROFILES="${SECSTACK_PROFILES:-all}"
TIMEOUT_SECONDS="${KILLSWITCH_TIMEOUT_SECONDS:-60}"
MODE="${1:-down}"
CONTAINER_ENGINE="${CONTAINER_ENGINE:-}"

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
usage: scripts/killswitch.sh [down|stop|pause|status]

Modes:
  down    Stop and remove all project containers, project networks, and project volumes.
          Images are preserved. This is the default and is destructive to project data.
  stop    Gracefully stop all running project containers; keep containers/resources.
  pause   Pause running project containers; keep containers/resources.
  status  Show project containers without changing resources.

Environment:
  COMPOSE_PROJECT_NAME          Compose project name (otherwise read from .env or directory name).
  COMPOSE_FILE                  Compose file path relative to the project root (default: security-stack.compose.yml).
  SECSTACK_PROFILES             Compose profiles for the Compose fallback (default: all).
  KILLSWITCH_TIMEOUT_SECONDS    Graceful stop timeout (default: 60).
  CONTAINER_ENGINE              docker or podman; auto-selects Podman first, then Docker.

Only resources carrying the project's Compose labels are removed. Images are never pruned.
USAGE
}

select_container_engine() {
  if [ -n "$CONTAINER_ENGINE" ]; then
    command -v "$CONTAINER_ENGINE" >/dev/null 2>&1 || die "Missing container engine: $CONTAINER_ENGINE"
    "$CONTAINER_ENGINE" compose version >/dev/null 2>&1 || die "$CONTAINER_ENGINE compose is unavailable; configure a Compose provider"
  elif command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
    CONTAINER_ENGINE=podman
  elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    CONTAINER_ENGINE=docker
  else
    die "Install Podman with a Compose provider or Docker Compose"
  fi
  export CONTAINER_ENGINE
}

load_project_name() {
  [ -n "$PROJECT_NAME" ] && return 0
  if [ -f .env ]; then
    PROJECT_NAME="$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' .env | tail -n 1)"
    PROJECT_NAME="${PROJECT_NAME#\"}"; PROJECT_NAME="${PROJECT_NAME%\"}"
    PROJECT_NAME="${PROJECT_NAME#\'}"; PROJECT_NAME="${PROJECT_NAME%\'}"
  fi
  if [ -z "$PROJECT_NAME" ]; then
    # Prefer the Compose file's top-level name default (this stack defines one).
    PROJECT_NAME="$(sed -n 's/^name:.*:-\([^}]*\)}.*/\1/p' "$COMPOSE_FILE" | head -n 1)"
  fi
  if [ -z "$PROJECT_NAME" ]; then
    PROJECT_NAME="$(basename "$PROJECT_ROOT" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
  fi
  [ -n "$PROJECT_NAME" ] || die "Could not determine Compose project name"
}

# Compose options are assembled from known, whitespace-separated profile names.
profile_args() {
  for profile in $PROFILES; do
    printf '%s\n' --profile "$profile"
  done
}

compose() {
  if [ -f .env ] && [ -f .env.vault ]; then
    "$CONTAINER_ENGINE" compose --env-file .env --env-file .env.vault -f "$COMPOSE_FILE" "$@"
  elif [ -f .env ]; then
    "$CONTAINER_ENGINE" compose --env-file .env -f "$COMPOSE_FILE" "$@"
  elif [ -f .env.vault ]; then
    "$CONTAINER_ENGINE" compose --env-file .env.vault -f "$COMPOSE_FILE" "$@"
  else
    "$CONTAINER_ENGINE" compose -f "$COMPOSE_FILE" "$@"
  fi
}

# Return IDs/names carrying either Docker Compose or Podman Compose project labels.
resource_list() {
  kind="$1"; label="$2"
  case "$kind" in
    containers) "$CONTAINER_ENGINE" ps -aq --filter "label=$label=$PROJECT_NAME" ;;
    networks)   "$CONTAINER_ENGINE" network ls -q --filter "label=$label=$PROJECT_NAME" ;;
    volumes)    "$CONTAINER_ENGINE" volume ls -q --filter "label=$label=$PROJECT_NAME" ;;
    *) return 2 ;;
  esac
}

for_each_project_resource() {
  kind="$1"; action="$2"
  for label in com.docker.compose.project io.podman.compose.project; do
    ids="$(resource_list "$kind" "$label" 2>/dev/null || true)"
    [ -n "$ids" ] || continue
    # IDs/names are returned by the engine, one per line.
    # shellcheck disable=SC2086
    set -- $ids
    case "$kind:$action" in
      containers:stop)
        running="$("$CONTAINER_ENGINE" ps -q --filter "label=$label=$PROJECT_NAME")"
        [ -n "$running" ] || continue
        # shellcheck disable=SC2086
        set -- $running
        log "Stopping project containers ($label) with timeout ${TIMEOUT_SECONDS}s"
        "$CONTAINER_ENGINE" stop --time "$TIMEOUT_SECONDS" "$@" || return 1
        ;;
      containers:remove)
        log "Removing project containers ($label)"
        "$CONTAINER_ENGINE" rm --force "$@" || return 1
        ;;
      networks:remove)
        log "Removing project networks ($label)"
        "$CONTAINER_ENGINE" network rm "$@" || log "Some project networks could not be removed (possibly still in use)"
        ;;
      volumes:remove)
        log "Removing project volumes ($label); data in these volumes will be deleted"
        "$CONTAINER_ENGINE" volume rm "$@" || die "Could not remove project volumes; check for remaining containers or external references"
        ;;
    esac
  done
}

main() {
  case "$MODE" in -h|--help) usage; exit 0;; esac
  case "$MODE" in down|stop|pause|status) ;; *) usage >&2; exit 2;; esac
  case "$TIMEOUT_SECONDS" in ''|*[!0-9]*) die "KILLSWITCH_TIMEOUT_SECONDS must be a non-negative integer";; esac

  cd "$PROJECT_ROOT"
  [ -f "$COMPOSE_FILE" ] || die "Compose file not found: $PROJECT_ROOT/$COMPOSE_FILE"
  select_container_engine
  load_project_name
  log "Mode=$MODE project=$PROJECT_NAME engine=$CONTAINER_ENGINE profiles=$PROFILES"

  case "$MODE" in
    status)
      "$CONTAINER_ENGINE" ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" || true
      "$CONTAINER_ENGINE" ps -a --filter "label=io.podman.compose.project=$PROJECT_NAME" || true
      ;;
    pause)
      # Prefer label-based targeting so services in inactive Compose profiles are included.
      for label in com.docker.compose.project io.podman.compose.project; do
        ids="$("$CONTAINER_ENGINE" ps -q --filter "label=$label=$PROJECT_NAME")"
        [ -n "$ids" ] || continue
        # shellcheck disable=SC2086
        set -- $ids
        "$CONTAINER_ENGINE" pause "$@"
      done
      ;;
    stop)
      for_each_project_resource containers stop
      ;;
    down)
      # Best-effort Compose teardown first, then label sweeps catch inactive-profile resources.
      # Do not use --rmi, image prune, or system-wide prune: images must be retained.
      # shellcheck disable=SC2046
      compose $(profile_args) down --remove-orphans --volumes --timeout "$TIMEOUT_SECONDS" || \
        log "Compose down reported an error; continuing with project-label cleanup"
      for_each_project_resource containers stop
      for_each_project_resource containers remove
      for_each_project_resource networks remove
      for_each_project_resource volumes remove
      ;;
  esac

  if [ "$MODE" = down ]; then
    log "Cleanup complete. Project containers, networks, and labeled volumes were targeted; images were preserved."
  else
    log "Killswitch complete; no resources or images were pruned."
  fi
}

main "$@"
