#!/usr/bin/env bash
set -euo pipefail
set +x

usage() {
  printf 'Usage: %s [IMAGE_LIST]\n' "${0##*/}" >&2
  printf 'Each non-comment line: SOURCE_IMAGE DESTINATION_IMAGE\n' >&2
  printf 'Default image list: %s/image-list.txt\n' "$(cd "$(dirname "$0")" && pwd)" >&2
}

if [ "$#" -gt 1 ]; then usage; exit 2; fi
script_dir=$(cd "$(dirname "$0")" && pwd)
image_list=${1:-"${script_dir}/image-list.txt"}
if [ ! -r "$image_list" ]; then
  printf 'Cannot read image list: %s\n' "$image_list" >&2
  exit 1
fi
if ! command -v podman >/dev/null 2>&1; then
  printf 'podman is required. Log in to source registries with podman login as needed.\n' >&2
  exit 1
fi

destination_registry=demo.goharbor.io
if [ -z "${HARBOR_USERNAME:-}" ] || [ -z "${HARBOR_PASSWORD:-}" ]; then
  printf 'Set HARBOR_USERNAME and HARBOR_PASSWORD for the Harbor destination.\n' >&2
  exit 1
fi
printf '%s' "$HARBOR_PASSWORD" | podman login "$destination_registry" \
  --username "$HARBOR_USERNAME" --password-stdin

failures=0
processed=0
while IFS= read -r line || [ -n "$line" ]; do
  line=${line%%#*}
  line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$line" ] || continue

  # Two-column entries identify the upstream image and Harbor destination.
  # A legacy Harbor-only entry maps its project/repository to Docker Hub.
  source_image=
  destination_image=
  set -- $line
  if [ "$#" -eq 2 ]; then
    source_image=$1
    destination_image=$2
  elif [ "$#" -eq 1 ]; then
    destination_image=$1
    case "$destination_image" in
      "$destination_registry"/*/*) ;;
      *) printf 'Skipping invalid destination image reference: %s\n' "$destination_image" >&2; failures=$((failures + 1)); continue ;;
    esac
    destination_path=${destination_image#"$destination_registry"/}
    destination_path=${destination_path#*/}
    source_image="docker.io/${destination_path%:*}:latest"
  else
    printf 'Skipping invalid image-list line: %s\n' "$line" >&2
    failures=$((failures + 1))
    continue
  fi

  case "$destination_image" in
    "$destination_registry"/*/*) ;;
    *) printf 'Destination must be under %s: %s\n' "$destination_registry" "$destination_image" >&2; failures=$((failures + 1)); continue ;;
  esac
  destination_latest=${destination_image%:*}:latest
  # Ensure source uses the latest tag, preserving registry and repository.
  source_base=${source_image%@*}
  source_slash=${source_base##*/}
  case "$source_slash" in *:*) source_base=${source_base%:*} ;; esac
  source_latest=${source_base}:latest

  printf 'Pulling latest upstream image %s\n' "$source_latest"
  if ! podman pull "$source_latest"; then
    printf 'Pull failed: %s\n' "$source_latest" >&2
    failures=$((failures + 1)); continue
  fi
  printf 'Tagging as %s\n' "$destination_latest"
  if ! podman tag "$source_latest" "$destination_latest"; then
    printf 'Tag failed: %s\n' "$source_latest" >&2
    failures=$((failures + 1)); continue
  fi
  printf 'Pushing %s\n' "$destination_latest"
  if ! podman push "$destination_latest"; then
    printf 'Push failed: %s\n' "$destination_latest" >&2
    failures=$((failures + 1)); continue
  fi
  processed=$((processed + 1))
  printf 'Updated Harbor image: %s\n' "$destination_latest"
done < "$image_list"

printf 'Processed %s image(s); %s failed.\n' "$processed" "$failures"
[ "$failures" -eq 0 ]
