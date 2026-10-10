#!/usr/bin/env bash
set -Eeuo pipefail

# Safely prune resources associated with image IDs previously flagged as duplicates.
# Dry-run is the default. Use --apply to delete flagged containers/images and project networks.
# Add --volumes to delete ALL named volumes labeled for this Compose project (data loss).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
COMPOSE_FILE="${COMPOSE_FILE:-security-stack.compose.yml}"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-}"
CONTAINER_ENGINE="${CONTAINER_ENGINE:-}"
APPLY=false
REMOVE_VOLUMES=false
FORCE=false

# Image IDs from the supplied `podman images` listing where different service/repository
# names unexpectedly resolved to the same image ID. Same-repository latest/v1.1 aliases
# are intentionally not listed as separate targets.
FLAGGED_IMAGE_IDS=(
  "0b43726b41c4" # openvasd / openvas / configure-openvas
  "979e5a8a5684" # container-health-exporter / uptime-kuma-sync / ghost-assessor
  "821fd3084c79" # ghost / ghost-model-pull
  "804bca5028a2" # suricata / suricata-rules-update
  "20bce4b1fc21" # vault / vault-rotator
)

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
usage() {
  cat <<'USAGE'
Usage: scripts/prune-redundant-resources.sh [--dry-run | --apply] [--force] [--volumes] [--project NAME]

Options:
  --dry-run       Show what would be removed (default).
  --apply         Remove containers using flagged image IDs, then remove those images
                  and unused networks labeled for this Compose project.
  --force         With --apply, force-remove flagged images even if containers reference them.
                  This may disrupt containers outside this Compose project.
  --volumes       With --apply, also remove every named volume labeled for this project.
                  WARNING: this permanently deletes persisted application data.
  --project NAME  Override the Compose project name.
  -h, --help      Show this help.

Images are never pulled or rebuilt. Unflagged images are not pruned.
USAGE
}

while (($#)); do
  case "$1" in
    --dry-run) APPLY=false ;;
    --apply) APPLY=true ;;
    --volumes) REMOVE_VOLUMES=true ;;
    --force) FORCE=true ;;
    --project) (($# >= 2)) || die "--project requires a name"; PROJECT_NAME="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help)" ;;
  esac
  shift
done

cd "$PROJECT_ROOT"
[[ -f "$COMPOSE_FILE" ]] || die "Compose file not found: $PROJECT_ROOT/$COMPOSE_FILE"

select_engine() {
  if [[ -n "$CONTAINER_ENGINE" ]]; then
    command -v "$CONTAINER_ENGINE" >/dev/null 2>&1 || die "Container engine not found: $CONTAINER_ENGINE"
  elif command -v podman >/dev/null 2>&1; then
    CONTAINER_ENGINE=podman
  elif command -v docker >/dev/null 2>&1; then
    CONTAINER_ENGINE=docker
  else
    die "Install Podman or Docker first"
  fi
}

resolve_project_name() {
  if [[ -n "$PROJECT_NAME" ]]; then return; fi
  if [[ -f .env ]]; then
    PROJECT_NAME="$(sed -n 's/^COMPOSE_PROJECT_NAME[[:space:]]*=[[:space:]]*//p' .env | tail -n 1 | sed -E "s/^[\"']//; s/[\"']$//")"
  fi
  if [[ -z "$PROJECT_NAME" ]]; then
    PROJECT_NAME="$(basename "$PROJECT_ROOT" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
  fi
}

# Return resource IDs for either Docker Compose or Podman Compose labels.
resource_ids() {
  local kind="$1" label="$2" value="$3"
  "$CONTAINER_ENGINE" "$kind" -aq --filter "label=${label}=${value}" 2>/dev/null || true
}

unique_lines() { awk 'NF && !seen[$0]++'; }

select_engine
resolve_project_name
log "engine=$CONTAINER_ENGINE project=$PROJECT_NAME mode=$([[ "$APPLY" == true ]] && echo apply || echo dry-run) force=$FORCE"
if [[ "$REMOVE_VOLUMES" == true && "$APPLY" != true ]]; then
  log "NOTE: --volumes has no effect during dry-run except listing candidate volumes."
fi

# Discover only containers within this Compose project whose image ID is flagged.
mapfile -t TARGET_CONTAINERS < <(
  for image_id in "${FLAGGED_IMAGE_IDS[@]}"; do
    for label in com.docker.compose.project io.podman.compose.project; do
      while IFS= read -r id; do
        [[ -n "$id" ]] && printf '%s\n' "$id"
      done < <("$CONTAINER_ENGINE" ps -aq --filter "ancestor=$image_id" --filter "label=${label}=${PROJECT_NAME}" 2>/dev/null || true)
    done
  done | unique_lines
)

log "Flagged image IDs: ${FLAGGED_IMAGE_IDS[*]}"
if ((${#TARGET_CONTAINERS[@]})); then
  log "Containers to remove (${#TARGET_CONTAINERS[@]}):"
  for id in "${TARGET_CONTAINERS[@]}"; do
    "$CONTAINER_ENGINE" ps -a --filter "id=$id" --format '{{.ID}}  {{.Names}}  {{.Image}}  {{.Status}}' 2>/dev/null || printf '  %s\n' "$id"
  done
else
  log "No project containers found using the flagged image IDs."
fi

# Images are selected by exact image ID; unflagged images are never touched.
for image_id in "${FLAGGED_IMAGE_IDS[@]}"; do
  if "$CONTAINER_ENGINE" image inspect "$image_id" >/dev/null 2>&1; then
    log "Flagged image present: $image_id"
  else
    log "Flagged image not present locally: $image_id"
  fi
done

mapfile -t TARGET_NETWORKS < <(
  for label in com.docker.compose.project io.podman.compose.project; do
    resource_ids network "$label" "$PROJECT_NAME"
  done | unique_lines
)
mapfile -t TARGET_VOLUMES < <(
  for label in com.docker.compose.project io.podman.compose.project; do
    resource_ids volume "$label" "$PROJECT_NAME"
  done | unique_lines
)

log "Project-labeled networks that may be removed if unused: ${#TARGET_NETWORKS[@]}"
for id in "${TARGET_NETWORKS[@]}"; do printf '  %s\n' "$id"; done
if [[ "$REMOVE_VOLUMES" == true ]]; then
  log "Project-labeled volumes targeted for deletion: ${#TARGET_VOLUMES[@]}"
  for id in "${TARGET_VOLUMES[@]}"; do printf '  %s\n' "$id"; done
else
  log "Project-labeled volumes preserved: ${#TARGET_VOLUMES[@]} (use --apply --volumes to delete them)"
fi

if [[ "$APPLY" != true ]]; then
  log "DRY RUN ONLY. Review the targets, then rerun with --apply to delete flagged resources."
  exit 0
fi

if ((${#TARGET_CONTAINERS[@]})); then
  log "Removing flagged project containers..."
  "$CONTAINER_ENGINE" rm -f "${TARGET_CONTAINERS[@]}"
fi

# Remove only the listed image IDs, and only after target containers have been removed.
for image_id in "${FLAGGED_IMAGE_IDS[@]}"; do
  if "$CONTAINER_ENGINE" image inspect "$image_id" >/dev/null 2>&1; then
    remaining="$("$CONTAINER_ENGINE" ps -aq --filter "ancestor=$image_id" 2>/dev/null || true)"
    if [[ -n "$remaining" && "$FORCE" != true ]]; then
      log "Keeping image $image_id because containers still reference it. Re-run with --apply --force to override this safety check."
      continue
    fi
    if [[ -n "$remaining" && "$FORCE" == true ]]; then
      log "FORCE enabled: attempting to remove image $image_id despite container references."
    else
      log "Removing flagged image ID $image_id (all tags pointing to it may be removed)."
    fi
    if [[ "$FORCE" == true ]]; then
      if ! "$CONTAINER_ENGINE" rmi --force "$image_id"; then
        log "WARNING: could not force-remove image $image_id."
      fi
    elif ! "$CONTAINER_ENGINE" rmi "$image_id"; then
      log "WARNING: could not remove image $image_id; it may be shared, in use, or protected."
    fi
  fi
done

# Remove project networks only when unused. Never force-remove networks.
for id in "${TARGET_NETWORKS[@]}"; do
  if "$CONTAINER_ENGINE" network rm "$id" >/dev/null 2>&1; then
    log "Removed network $id"
  else
    log "Keeping network $id (it may still be in use)."
  fi
done

if [[ "$REMOVE_VOLUMES" == true ]]; then
  log "WARNING: deleting project volumes can permanently destroy databases, configuration, and other persistent data."
  for id in "${TARGET_VOLUMES[@]}"; do
    if "$CONTAINER_ENGINE" volume rm "$id" >/dev/null 2>&1; then
      log "Removed volume $id"
    else
      log "Keeping volume $id (it may still be in use)."
    fi
  done
fi

log "Prune complete. No global prune was run; unflagged images and resources were not targeted."
