#!/usr/bin/env bash
set -euo pipefail
set +x

usage() {
  printf 'Usage: %s [IMAGE_LIST]\n' "${0##*/}" >&2
  printf 'Default image list: %s/image-list.txt\n' "$(cd "$(dirname "$0")" && pwd)" >&2
}

if [ "$#" -gt 1 ]; then
  usage
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
image_list=${1:-"${script_dir}/image-list.txt"}
if [ ! -r "$image_list" ]; then
  printf 'Cannot read image list: %s\n' "$image_list" >&2
  exit 1
fi

if [ -n "${HARBOR_USERNAME:-}" ] && [ -n "${HARBOR_PASSWORD:-}" ]; then
  printf '%s' "$HARBOR_PASSWORD" | podman login demo.goharbor.io \
    --username "$HARBOR_USERNAME" --password "$HARBOR_PASSWORD"
else
  printf 'Set HARBOR_USERNAME and HARBOR_PASSWORD before running this script.\n' >&2
  exit 1
fi

failures=0
processed=0
logged_in_registry=

while IFS= read -r harbor_image || [ -n "$harbor_image" ]; do
  # Permit blank lines, comments, and trailing whitespace in the list.
  harbor_image=${harbor_image%%#*}
  harbor_image=$(printf '%s' "$harbor_image" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$harbor_image" ] || continue

  case "$harbor_image" in
    */*/*) ;;
    *) printf 'Skipping invalid Harbor image reference: %s\n' "$harbor_image" >&2; failures=$((failures + 1)); continue ;;
  esac

  harbor_registry=${harbor_image%%/*}
  harbor_repository=${harbor_image#*/}
  harbor_repository=${harbor_repository%:*}
  harbor_latest="${harbor_registry}/${harbor_repository}:latest"

  if [ "$logged_in_registry" != "$harbor_registry" ]; then
    printf 'Checking Harbor login for %s\n' "$harbor_registry"
    if ! podman login --get-login "$harbor_registry" >/dev/null 2>&1; then
      if [ -n "${HARBOR_USERNAME:-}" ] && [ -n "${HARBOR_PASSWORD:-}" ]; then
        if ! printf '%s' "$HARBOR_PASSWORD" | podman login "$harbor_registry" \
          --username "$HARBOR_USERNAME" --password "$HARBOR_PASSWORD"; then
          printf 'Harbor login failed for %s\n' "$harbor_registry" >&2
          exit 1
        fi
      else
        printf 'No saved Podman login for %s. Set HARBOR_USERNAME and HARBOR_PASSWORD, or run podman login first.\n' "$harbor_registry" >&2
        exit 1
      fi
    fi
    logged_in_registry=$harbor_registry
  fi

  # Skip work only when this exact source image is already local and Harbor's
  # latest tag points at the same manifest. A missing or stale copy follows the
  # normal pull/tag/push path below.
  if podman image exists "$harbor_image" 2>/dev/null; then
    if ! command -v skopeo >/dev/null 2>&1; then
      printf 'Cannot check Harbor image digests: skopeo is required\n' >&2
      exit 1
    fi

    local_digest=$(podman image inspect --format '{{.Digest}}' "$harbor_image" 2>/dev/null || true)
    remote_source_digest=$(skopeo inspect --format '{{.Digest}}' "docker://${harbor_image}" 2>/dev/null || true)
    remote_latest_digest=$(skopeo inspect --format '{{.Digest}}' "docker://${harbor_latest}" 2>/dev/null || true)

    if [ -n "$local_digest" ] && [ "$local_digest" = "$remote_source_digest" ] &&
      [ "$remote_source_digest" = "$remote_latest_digest" ]; then
      printf 'Skipping %s; already present locally and pushed to Harbor as latest\n' "$harbor_image"
      continue
    fi
  fi

  printf 'Pulling %s\n' "$harbor_image"
  if ! podman pull "$harbor_image"; then
    printf 'Pull failed: %s\n' "$harbor_image" >&2
    failures=$((failures + 1))
    continue
  fi

  printf 'Tagging as %s\n' "$harbor_latest"
  if ! podman tag "$harbor_image" "$harbor_latest"; then
    printf 'Tag failed: %s\n' "$harbor_image" >&2
    failures=$((failures + 1))
    continue
  fi

  printf 'Pushing %s\n' "$harbor_latest"
  if ! podman push "$harbor_latest"; then
    printf 'Push failed: %s\n' "$harbor_latest" >&2
    failures=$((failures + 1))
    continue
  fi

  printf 'Pruning local image references for %s\n' "$harbor_image"
  if ! podman image rm "$harbor_image" "$harbor_latest"; then
    printf 'Image update succeeded, but local image cleanup failed for %s\n' "$harbor_image" >&2
    failures=$((failures + 1))
    continue
  fi

  processed=$((processed + 1))
  printf 'Updated Harbor image: %s\n' "$harbor_latest"
done < "$image_list"

printf 'Processed %s image(s); %s failed.\n' "$processed" "$failures"
[ "$failures" -eq 0 ]
