#!/usr/bin/env sh
# Prepare, publish, start, and check the simplified MVP stack.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
COMPOSE_FILE="$ROOT/simplified.compose.yml"
REGISTRY=demo.goharbor.io
PROJECT=home-security-uk-registry
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-900}"
FIREWALL_ZONE="${FIREWALL_ZONE:-}"
log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
cd "$ROOT"

if [ ! -f .env ]; then
  [ -f .env.example ] || fail ".env.example is missing"
  cp .env.example .env
  log "Created .env from .env.example; review passwords and bind addresses before continuing."
fi
for cmd in podman podman-compose python3 curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
done
compose() { podman-compose -f "$COMPOSE_FILE" "$@"; }
env_value() {
  value="$(sed -n "s/^$1=//p" .env | tail -n 1)"
  case "$value" in
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
  esac
  printf '%s' "$value"
}

log "Validating Compose configuration"
compose --profile mvp config > /tmp/home-security-mvp-compose.yml \
  || fail "podman-compose config failed"

log "Whitelisting published ports from simplified.compose.yml"
if command -v firewall-cmd >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
  if [ -z "$FIREWALL_ZONE" ]; then FIREWALL_ZONE="$(sudo firewall-cmd --get-default-zone)"; fi
  python3 -c 'import yaml; d=yaml.safe_load(open("/tmp/home-security-mvp-compose.yml")); out=set();
for s in d.get("services",{}).values():
 for p in s.get("ports",[]):
  if isinstance(p,dict) and p.get("published"): out.add(str(p["published"])+"/"+p.get("protocol","tcp"))
  elif isinstance(p,str):
   parts=p.rsplit(":",2)
   if len(parts)==3: out.add(parts[1]+"/"+parts[2].split("/",1)[-1] if "/" in parts[2] else parts[1]+"/tcp")
print("\n".join(sorted(out)))' |
  while IFS= read -r port; do
    sudo firewall-cmd --permanent --zone="$FIREWALL_ZONE" --add-port="$port" >/dev/null
    log "Allowed $port in $FIREWALL_ZONE"
  done
  sudo firewall-cmd --reload >/dev/null
else
  log "WARNING: firewall-cmd/sudo unavailable; skipping firewalld port configuration (MVP ports default to loopback)."
fi

log "Creating persistent volumes (Compose will mount the declared volumes at startup)"
project_name="$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' .env | tail -n 1 | tr -d '"\047')"
project_name="${project_name:-home-security-uk}"
for volume in fluent-bit-state uptime-kuma-data wazuh-indexer-data wazuh-manager-data wazuh-manager-logs wazuh-manager-queue graylog-mongo-data graylog-datanode-data graylog-data; do
  name="${project_name}_${volume}"
  podman volume exists "$name" || podman volume create "$name" >/dev/null
done

HARBOR_CACHE_HOST="${HARBOR_CACHE_HOST:-$(env_value HARBOR_CACHE_HOST)}"
HARBOR_CACHE_HOST="${HARBOR_CACHE_HOST:-$REGISTRY}"
HARBOR_CACHE_USERNAME="${HARBOR_CACHE_USERNAME:-$(env_value HARBOR_CACHE_USERNAME)}"
HARBOR_CACHE_PASSWORD="${HARBOR_CACHE_PASSWORD:-$(env_value HARBOR_CACHE_PASSWORD)}"
ROBOT_HARBOR_USERNAME="${ROBOT_HARBOR_USERNAME:-$(env_value ROBOT_HARBOR_USERNAME)}"
ROBOT_HARBOR_PASSWORD="${ROBOT_HARBOR_PASSWORD:-$(env_value ROBOT_HARBOR_PASSWORD)}"
[ -n "$HARBOR_CACHE_USERNAME" ] || fail "HARBOR_CACHE_USERNAME is missing from .env"
[ -n "$HARBOR_CACHE_PASSWORD" ] || fail "HARBOR_CACHE_PASSWORD is missing from .env"
[ -n "$ROBOT_HARBOR_USERNAME" ] || fail "ROBOT_HARBOR_USERNAME is missing from .env"
[ -n "$ROBOT_HARBOR_PASSWORD" ] || fail "ROBOT_HARBOR_PASSWORD is missing from .env"

log "Configuring Harbor cache registry access"
printf '%s\n' "$HARBOR_CACHE_PASSWORD" | podman login "$HARBOR_CACHE_HOST" \
  --username "$HARBOR_CACHE_USERNAME" --password-stdin

log "Configuring Harbor push registry access"
printf '%s\n' "$ROBOT_HARBOR_PASSWORD" | podman login "$REGISTRY" \
  --username "$ROBOT_HARBOR_USERNAME" --password-stdin

HARBOR_API="https://$REGISTRY/api/v2.0"
HARBOR_LABEL_NAME="home-security-uk"
HARBOR_PROJECT_ID="$(curl -fsS -u "$ROBOT_HARBOR_USERNAME:$ROBOT_HARBOR_PASSWORD" \
  "$HARBOR_API/projects?name=$PROJECT" | jq -er '.[0].project_id')" \
  || fail "Unable to resolve Harbor project $PROJECT"
HARBOR_LABEL_ID="$(curl -fsS -u "$ROBOT_HARBOR_USERNAME:$ROBOT_HARBOR_PASSWORD" \
  "$HARBOR_API/labels?scope=p&project_id=$HARBOR_PROJECT_ID" | \
  jq -er --arg label "$HARBOR_LABEL_NAME" '.[] | select(.name == $label) | .id' | head -n 1)" \
  || fail "Unable to resolve Harbor project label $HARBOR_LABEL_NAME"

label_harbor_artifact() {
  image_repo="$1"
  image_reference="$2"
  encoded_repo="$(printf '%s' "$image_repo" | jq -sRr '@uri')"
  label_status="$(curl -sS -o /dev/null -w '%{http_code}' \
    -u "$ROBOT_HARBOR_USERNAME:$ROBOT_HARBOR_PASSWORD" \
    -H 'Content-Type: application/json' \
    -X POST \
    -d "{\"id\":$HARBOR_LABEL_ID}" \
    "$HARBOR_API/projects/$PROJECT/repositories/$encoded_repo/artifacts/$image_reference/labels")" \
    || fail "Unable to contact Harbor while applying label $HARBOR_LABEL_NAME to $image_repo@$image_reference"
  case "$label_status" in
    2??)
      log "Applied Harbor label $HARBOR_LABEL_NAME to $image_repo@$image_reference"
      ;;
    4??)
      log "WARNING: Harbor returned HTTP $label_status while applying label $HARBOR_LABEL_NAME to $image_repo@$image_reference; continuing"
      ;;
    *)
      fail "Harbor returned HTTP $label_status while applying label $HARBOR_LABEL_NAME to $image_repo@$image_reference"
      ;;
  esac
}

log "Pruning local container images before pulling current images"
podman image prune --all --force

WAZUH_VERSION="${WAZUH_VERSION:-$(env_value WAZUH_VERSION)}"
WAZUH_VERSION="${WAZUH_VERSION:-4.14.4}"

# Docker Hub source to Harbor repository used in simplified.compose.yml.
while IFS=' ' read -r repo source; do
  [ -n "$repo" ] || continue
  case "$repo" in
    wazuh-indexer|wazuh-manager|wazuh-dashboard)
      source="docker.io/wazuh/$repo:$WAZUH_VERSION"
      ;;
  esac
  target="$REGISTRY/$PROJECT/$repo:latest"
  log "Pulling current image $source"
  podman pull "$source"
  podman tag "$source" "$target"
  podman push "$target"
  label_harbor_artifact "$repo" latest
done <<'IMAGES'
secdns docker.io/coredns/coredns:latest
caddy docker.io/library/caddy:latest
wazuh-indexer versioned
wazuh-manager versioned
wazuh-dashboard versioned
graylog-mongo docker.io/library/mongo:latest
graylog-datanode docker.io/graylog/graylog-datanode:latest
graylog docker.io/graylog/graylog:latest
log-forwarder docker.io/fluent/fluent-bit:latest
uptime-kuma docker.io/louislam/uptime-kuma:latest
uptime-kuma-sync docker.io/library/python:3.12-alpine
IMAGES

log "Validating image references and starting profile mvp"
compose --profile mvp config >/dev/null
compose --profile mvp up --detach

log "Waiting for all MVP containers and health checks (timeout ${HEALTH_TIMEOUT_SECONDS}s)"
containers="secdns caddy wazuh-indexer wazuh-manager wazuh-dashboard graylog-mongo graylog-datanode graylog fluent-bit uptime-kuma uptime-kuma-sync"
deadline=$(( $(date +%s) + HEALTH_TIMEOUT_SECONDS ))
while :; do
  ready=true
  for container in $containers; do
    status="$(podman inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || true)"
    case "$status" in 'running healthy'|'running none') ;; *) ready=false; break ;; esac
  done
  [ "$ready" = true ] && break
  [ "$(date +%s)" -lt "$deadline" ] || fail "Container readiness timed out; inspect with podman-compose -f simplified.compose.yml --profile mvp ps"
  sleep 10
done

log "Checking Graylog GELF ingestion"
GRAYLOG_PORT="${GRAYLOG_GELF_UDP_PORT:-$(env_value GRAYLOG_GELF_UDP_PORT)}"
GRAYLOG_PORT="${GRAYLOG_PORT:-12201}"
HTTP_PORT="${GRAYLOG_HTTP_PORT:-$(env_value GRAYLOG_HTTP_PORT)}"
HTTP_PORT="${HTTP_PORT:-9000}"
GRAYLOG_ROOT_USERNAME="${GRAYLOG_ROOT_USERNAME:-$(env_value GRAYLOG_ROOT_USERNAME)}"
GRAYLOG_ROOT_USERNAME="${GRAYLOG_ROOT_USERNAME:-admin}"
GRAYLOG_ROOT_PASSWORD="${GRAYLOG_ROOT_PASSWORD:-$(env_value GRAYLOG_ROOT_PASSWORD)}"
GRAYLOG_ROOT_PASSWORD="${GRAYLOG_ROOT_PASSWORD:-admin}"
log "Creating Graylog GELF and syslog inputs"
GRAYLOG_API_URL="http://127.0.0.1:${HTTP_PORT}/api" \
  GRAYLOG_ROOT_USERNAME="$GRAYLOG_ROOT_USERNAME" \
  GRAYLOG_ROOT_PASSWORD="$GRAYLOG_ROOT_PASSWORD" \
  GRAYLOG_GELF_UDP_PORT="$GRAYLOG_PORT" \
  sh "The Eyes/Graylog/scripts/bootstrap-inputs.sh"
INGEST_MARKER="mvp-startup-check-$(date +%s)"
python3 -c 'import json,socket,sys; p=json.dumps({"version":"1.1","host":"mvp-startup-validation","short_message":sys.argv[1],"facility":"mvp-startup"}).encode(); s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.sendto(p,("127.0.0.1",int(sys.argv[2])))' "$INGEST_MARKER" "$GRAYLOG_PORT"
found=false
deadline=$(( $(date +%s) + 120 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if result="$(curl -fsS -u "$GRAYLOG_ROOT_USERNAME:$GRAYLOG_ROOT_PASSWORD" -H 'X-Requested-By: start.sh' --get --data-urlencode "query=message:$INGEST_MARKER" --data-urlencode range=300 "http://127.0.0.1:$HTTP_PORT/api/search/universal/relative" 2>/dev/null)"; then
    printf '%s' "$result" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("total_results",0)>0 else 1)' 2>/dev/null && { found=true; break; }
  fi
  sleep 5
done
[ "$found" = true ] || fail "Graylog did not index the GELF test event; check GELF input and credentials"
log "Graylog GELF event is indexed"

log "Checking Uptime Kuma"
UPTIME_KUMA_PORT="${UPTIME_KUMA_PORT:-3002}"
curl -fsS "http://127.0.0.1:$UPTIME_KUMA_PORT/" >/dev/null || fail "Uptime Kuma did not respond"
UPTIME_KUMA_PASSWORD="${UPTIME_KUMA_PASSWORD:-$(env_value UPTIME_KUMA_PASSWORD)}"
if [ -z "$UPTIME_KUMA_PASSWORD" ]; then
  fail "Uptime Kuma is running, but no account password is configured. Finish first-time setup, set UPTIME_KUMA_USERNAME and UPTIME_KUMA_PASSWORD in .env, then rerun scripts/start.sh to provision MVP monitors."
fi

log "Waiting for the Uptime Kuma sync helper to provision MVP monitors"
monitor_names="Caddy health|CoreDNS UDP|Uptime Kuma|Graylog web/API|Graylog GELF UDP|Graylog syslog TCP|Graylog MongoDB|Graylog Data Node|Wazuh dashboard|Wazuh manager API|Wazuh indexer|Wazuh agent events UDP|Wazuh enrollment TCP"
deadline=$(( $(date +%s) + HEALTH_TIMEOUT_SECONDS ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  monitor_log="$(podman logs uptime-kuma-sync 2>&1 || true)"
  monitors_ready=true
  old_ifs="$IFS"
  IFS='|'
  for monitor in $monitor_names; do
    printf '%s\n' "$monitor_log" | grep -F "$monitor" >/dev/null || { monitors_ready=false; break; }
  done
  IFS="$old_ifs"
  [ "$monitors_ready" = true ] && break
  sleep 5
done
[ "$monitors_ready" = true ] || fail "Uptime Kuma did not report all MVP monitors as added or updated; check podman logs uptime-kuma-sync and the Kuma credentials"
log "Uptime Kuma reports all MVP service monitors provisioned"
log "MVP startup checks completed"
