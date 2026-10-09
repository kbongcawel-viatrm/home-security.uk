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

export HARBOR_USERNAME="robot_home-security-uk-registry+home-sec-bot"
export HARBOR_PASSWORD="6QMVV6eoNangro59U8XEdM2HBmOrgLhI"

: "${HARBOR_USERNAME:?Set HARBOR_USERNAME to your Harbor username or robot account}"
: "${HARBOR_PASSWORD:?Set HARBOR_PASSWORD to your Harbor password or robot secret}"

policy_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/containers"
policy_file="${CONTAINERS_POLICY_FILE:-${policy_dir}/policy.json}"
failures=0
processed=0

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

  if [ ! -e "$policy_file" ]; then
    mkdir -p "$(dirname "$policy_file")"
    if [ -r /etc/containers/policy.json ]; then
      cp /etc/containers/policy.json "$policy_file"
    else
      printf '{"default":[{"type":"insecureAcceptAnything"}]}\n' > "$policy_file"
    fi
  fi

  printf 'Trusting Harbor project %s in %s\n' "$harbor_registry/${harbor_repository%%/*}" "$policy_file"
  if ! podman image trust set --signature-policy "$policy_file" --type accept \
    "$harbor_registry/${harbor_repository%%/*}"; then
    printf 'Failed to update trust policy for %s\n' "$harbor_image" >&2
    failures=$((failures + 1))
    continue
  fi

  printf 'Logging in to %s\n' "$harbor_registry"
  if ! printf '%s' "$HARBOR_PASSWORD" | podman login "$harbor_registry" \
    --username "$HARBOR_USERNAME" --password-stdin; then
    printf 'Harbor login failed for %s\n' "$harbor_registry" >&2
    exit 1
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

  processed=$((processed + 1))
  printf 'Updated Harbor image: %s\n' "$harbor_latest"
done < "$image_list"

printf 'Processed %s image(s); %s failed.\n' "$processed" "$failures"
[ "$failures" -eq 0 ]
