#!/bin/sh
set -eu

image_ref=${1:?Usage: test-image-reference.sh IMAGE_REFERENCE}
docker image inspect "$image_ref" >/dev/null
printf 'Candidate image is present locally: %s\n' "$image_ref"
