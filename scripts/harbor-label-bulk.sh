#!/usr/bin/env bash
set +x
set -euo pipefail

export ROBOT_USER="robot_home-security-uk-registry+home-sec-bot"
export ROBOT_SECRET="r6zrOIEeufjXZY6EZNB9Tyy84sGetCqL"
export HARBOR="https://demo.goharbor.io"

: "${ROBOT_USER:?Set ROBOT_USER first}"
: "${ROBOT_SECRET:?Set ROBOT_SECRET first}"
: "${HARBOR:?Set HARBOR first}"

PROJECT_ID=7848
PROJECT_NAME=home-security-uk-registry
PAGE_SIZE=100

# Look up the existing project label.
LABELS=$(curl -fsS -u "$ROBOT_USER:$ROBOT_SECRET" \
  "$HARBOR/api/v2.0/labels?scope=p&project_id=$PROJECT_ID")

LABEL_ID=$(jq -er \
  '.[] | select(.name == "home-security-uk") | .id' <<< "$LABELS")

echo "Using label ID $LABEL_ID"

page=1

while :; do
  artifacts=$(curl -fsS -u "$ROBOT_USER:$ROBOT_SECRET" \
    "$HARBOR/api/v2.0/projects/$PROJECT_ID/artifacts?page=$page&page_size=$PAGE_SIZE&with_label=true")

  count=$(jq 'length' <<< "$artifacts")
  [ "$count" -eq 0 ] && break

  while IFS=$'\t' read -r repository reference already_labeled; do
    if [ "$already_labeled" = true ]; then
      echo "Already labeled: $repository@$reference"
      continue
    fi

    encoded_repository=$(jq -rn --arg value "$repository" '$value | @uri | @uri')

    curl -fsS -u "$ROBOT_USER:$ROBOT_SECRET" \
      -H 'Content-Type: application/json' \
      -X POST \
      -d "{\"id\":$LABEL_ID}" \
      "$HARBOR/api/v2.0/projects/$PROJECT_NAME/repositories/$encoded_repository/artifacts/$reference/labels" \
      >/dev/null

    echo "Labeled: $repository@$reference"
  done < <(
    jq -r --arg project "$PROJECT_NAME" --argjson label "$LABEL_ID" \
      '.[] | [(.repository_name | sub("^" + $project + "/"; "")), .digest, (([.labels[]?.id] | index($label)) != null)] | @tsv' \
      <<< "$artifacts"
  )

  page=$((page + 1))
done

echo "Done"
