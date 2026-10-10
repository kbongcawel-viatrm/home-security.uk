#!/usr/bin/env sh
# Prepare, publish, start, and check the simplified MVP stack.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
COMPOSE_FILE="$ROOT/simplified.compose.yml"
REGISTRY=demo.goharbor.io
PROJECT=home-security-uk-registry
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-900}"
STUCK_TIMEOUT_SECONDS="${STUCK_TIMEOUT_SECONDS:-180}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-10}"
INDEXER_SECURITY_INIT_TIMEOUT_SECONDS="${INDEXER_SECURITY_INIT_TIMEOUT_SECONDS:-${HEALTH_TIMEOUT_SECONDS}}"
VALIDATE_ONLY="${VALIDATE_ONLY:-false}"
REFRESH_IMAGES="${REFRESH_IMAGES:-false}"
PULL_IMAGES="${PULL_IMAGES:-true}"
IMAGE_PULL_TIMEOUT_SECONDS="${IMAGE_PULL_TIMEOUT_SECONDS:-180}"
PUBLISH_IMAGES="${PUBLISH_IMAGES:-true}"
FIREWALL_ZONE="${FIREWALL_ZONE:-}"
log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
diagnose_containers() {
  log "Container diagnostics:"
  podman ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' >&2 || true
  for container in secdns caddy wazuh-indexer graylog-mongo uptime-kuma wazuh-manager wazuh-dashboard graylog-datanode graylog fluent-bit uptime-kuma-sync; do
    health="$(podman inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || true)"
    [ -n "$health" ] || continue
    printf '  %s: %s\n' "$container" "$health" >&2
    case "$health" in
      *unhealthy*)
        podman inspect --format '    health failing streak: {{.State.Health.FailingStreak}}' "$container" >&2 || true
        podman inspect --format '{{range .State.Health.Log}}{{if .Output}}{{.Output}}{{end}}{{end}}' "$container" >&2 || true
        ;;
    esac
  done
}
fail_with_diagnostics() {
  diagnose_containers
  fail "$1"
}
if [ -t 1 ] || [ "${FORCE_COLOR:-}" = 1 ]; then
  COLOR_GREEN=$(printf '\033[0;32m')
  COLOR_RESET=$(printf '\033[0m')
else
  COLOR_GREEN=''
  COLOR_RESET=''
fi
log_starting() { printf '%s %s%s%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$COLOR_GREEN" "$*" "$COLOR_RESET"; }
progress() {
  current="$1"
  total="$2"
  label="$3"
  width=30
  filled=$(( current * width / total ))
  empty=$(( width - filled ))
  bar="$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' "$empty" '' | tr ' ' '.')"
  if [ -t 1 ] || [ "${FORCE_COLOR:-}" = 1 ]; then
    printf '\r%s %s[%s] %s/%s%s' "$COLOR_GREEN" "$label " "$bar" "$current" "$total" "$COLOR_RESET"
  else
    printf '%s %s [%s] %s/%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$label" "$bar" "$current" "$total"
  fi
}
cd "$ROOT"

if [ ! -f .env ]; then
  [ -f .env.example ] || fail ".env.example is missing"
  cp .env.example .env
  log "Created .env from .env.example; review passwords and bind addresses before continuing."
fi
for cmd in podman podman-compose python3 curl jq timeout; do
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
HARBOR_IMAGE_TAG="${HARBOR_IMAGE_TAG:-$(env_value HARBOR_IMAGE_TAG)}"
HARBOR_IMAGE_TAG="${HARBOR_IMAGE_TAG:-v1.1}"
NEEDS_REGISTRY_AUTH=false
for image_repo in secdns caddy wazuh-indexer wazuh-manager wazuh-dashboard graylog-mongo graylog-datanode graylog log-forwarder uptime-kuma uptime-kuma-sync; do
  if ! podman image exists "$REGISTRY/$PROJECT/$image_repo:$HARBOR_IMAGE_TAG"; then
    NEEDS_REGISTRY_AUTH=true
    break
  fi
done

validate_compose() {
  rendered_compose="$(mktemp "${TMPDIR:-/tmp}/home-security-mvp-compose.XXXXXX")"
  trap 'rm -f "$rendered_compose"' EXIT HUP INT TERM

  log "Validating Compose syntax and rendering"
  python3 - "$COMPOSE_FILE" <<'PY'
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("PyYAML is required to validate Compose YAML syntax", file=sys.stderr)
    raise SystemExit(1)

path = Path(sys.argv[1])
try:
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
except yaml.YAMLError as exc:
    print(f"Compose YAML syntax error: {exc}", file=sys.stderr)
    raise SystemExit(1)

if not isinstance(document, dict) or not isinstance(document.get("services"), dict):
    print("Compose file must define a services mapping", file=sys.stderr)
    raise SystemExit(1)
if "mvp" not in {profile for service in document["services"].values() for profile in service.get("profiles", [])}:
    print("Compose file does not define the mvp profile", file=sys.stderr)
    raise SystemExit(1)
PY

  compose --profile mvp config >"$rendered_compose" \
    || fail "podman-compose config failed"

  python3 - "$rendered_compose" <<'PY'
import sys
from pathlib import Path

import yaml

document = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
services = document.get("services", {})
required = {
    "coredns", "caddy", "wazuh-indexer", "wazuh-manager", "wazuh-dashboard",
    "mongodb", "graylog-datanode", "graylog", "fluent-bit", "uptime-kuma",
    "uptime-kuma-sync",
}
missing = sorted(required - services.keys())
if missing:
    raise SystemExit(f"Rendered Compose is missing required MVP services: {', '.join(missing)}")
network = document.get("networks", {}).get("secnet")
if not network or network.get("driver") != "bridge":
    raise SystemExit("Rendered Compose must define secnet as a bridge network")
for name in required:
    if "secnet" not in services[name].get("networks", {} if isinstance(services[name].get("networks"), dict) else []):
        raise SystemExit(f"Service {name} is not attached to secnet")
ports = []
for service in services.values():
    for port in service.get("ports", []):
        ports.append(str(port))
if not ports:
    raise SystemExit("Rendered Compose does not publish any host ports")
print(f"Compose sanity checks passed: {len(services)} services, {len(ports)} published ports")
PY

  FIREWALL_COMPOSE_FILE="$rendered_compose"
}

validate_compose

if [ "$VALIDATE_ONLY" = true ]; then
  log "Compose validation completed; skipping image pulls and container startup (VALIDATE_ONLY=true)"
  exit 0
fi

log "Whitelisting published ports from simplified.compose.yml"
if command -v firewall-cmd >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
  if [ -z "$FIREWALL_ZONE" ]; then FIREWALL_ZONE="$(sudo firewall-cmd --get-default-zone)"; fi
  FIREWALL_COMPOSE_FILE="$rendered_compose" python3 -c 'import os,yaml; d=yaml.safe_load(open(os.environ["FIREWALL_COMPOSE_FILE"])); out=set();
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
rm -f "$FIREWALL_COMPOSE_FILE"
trap - EXIT HUP INT TERM

log "Creating persistent volumes (Compose will mount the declared volumes at startup)"
project_name="$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' .env | tail -n 1 | tr -d '"\047')"
project_name="${project_name:-home-security-uk}"
for volume in fluent-bit-state uptime-kuma-data wazuh-indexer-data wazuh-manager-data wazuh-manager-logs wazuh-manager-queue graylog-mongo-data graylog-datanode-data graylog-data; do
  name="${project_name}_${volume}"
  podman volume exists "$name" || podman volume create "$name" >/dev/null
done

HARBOR_CACHE_HOST="${HARBOR_CACHE_HOST:-$(env_value HARBOR_CACHE_HOST)}"
HARBOR_CACHE_HOST="${HARBOR_CACHE_HOST:-$REGISTRY}"
HARBOR_CACHE_PROJECT_DOCKERIO="${HARBOR_CACHE_PROJECT_DOCKERIO:-$(env_value HARBOR_CACHE_PROJECT_DOCKERIO)}"
HARBOR_CACHE_PROJECT_DOCKERHUB="${HARBOR_CACHE_PROJECT_DOCKERHUB:-$(env_value HARBOR_CACHE_PROJECT_DOCKERHUB)}"
HARBOR_CACHE_PROJECT_DEFAULT="${HARBOR_CACHE_PROJECT_DEFAULT:-$(env_value HARBOR_CACHE_PROJECT_DEFAULT)}"
HARBOR_CACHE_USERNAME="${HARBOR_CACHE_USERNAME:-$(env_value HARBOR_CACHE_USERNAME)}"
HARBOR_CACHE_PASSWORD="${HARBOR_CACHE_PASSWORD:-$(env_value HARBOR_CACHE_PASSWORD)}"
ROBOT_HARBOR_USERNAME="${ROBOT_HARBOR_USERNAME:-$(env_value ROBOT_HARBOR_USERNAME)}"
ROBOT_HARBOR_PASSWORD="${ROBOT_HARBOR_PASSWORD:-$(env_value ROBOT_HARBOR_PASSWORD)}"
if [ "$PUBLISH_IMAGES" = true ] || [ "$NEEDS_REGISTRY_AUTH" = true ]; then
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
  HARBOR_READY=true
else
  HARBOR_READY=false
fi

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

harbor_cache_reference() {
  image="$1"
  cache_project="${HARBOR_CACHE_PROJECT_DEFAULT:-${HARBOR_CACHE_PROJECT_DOCKERIO:-${HARBOR_CACHE_PROJECT_DOCKERHUB:-}}}"
  [ -n "$cache_project" ] || return 1
  case "$image" in
    docker.io/*)
      image_path=${image#docker.io/}
      ;;
    *)
      return 1
      ;;
  esac
  printf '%s/%s/%s' "$HARBOR_CACHE_HOST" "$cache_project" "$image_path"
}

COREDNS_VERSION="${COREDNS_VERSION:-$(env_value COREDNS_VERSION)}"
COREDNS_VERSION="${COREDNS_VERSION:-1.11.3}"
CADDY_VERSION="${CADDY_VERSION:-$(env_value CADDY_VERSION)}"
CADDY_VERSION="${CADDY_VERSION:-2.8.4-alpine}"
MONGO_VERSION="${MONGO_VERSION:-$(env_value MONGO_VERSION)}"
MONGO_VERSION="${MONGO_VERSION:-7.0.29}"
WAZUH_VERSION="${WAZUH_VERSION:-$(env_value WAZUH_VERSION)}"
WAZUH_VERSION="${WAZUH_VERSION:-4.14.4}"
GRAYLOG_VERSION="${GRAYLOG_VERSION:-$(env_value GRAYLOG_VERSION)}"
GRAYLOG_VERSION="${GRAYLOG_VERSION:-7.0.13}"
FLUENT_BIT_VERSION="${FLUENT_BIT_VERSION:-$(env_value FLUENT_BIT_VERSION)}"
FLUENT_BIT_VERSION="${FLUENT_BIT_VERSION:-3.2.10}"
UPTIME_KUMA_VERSION="${UPTIME_KUMA_VERSION:-$(env_value UPTIME_KUMA_VERSION)}"
UPTIME_KUMA_VERSION="${UPTIME_KUMA_VERSION:-1.23.16}"

# Docker Hub source to Harbor repository used in simplified.compose.yml.
while IFS=' ' read -r repo source; do
  [ -n "$repo" ] || continue
  case "$repo" in
    wazuh-indexer|wazuh-manager|wazuh-dashboard)
      source="docker.io/wazuh/$repo:$WAZUH_VERSION"
      ;;
    graylog-datanode|graylog)
      source="docker.io/graylog/$repo:$GRAYLOG_VERSION"
      ;;
    graylog-mongo)
      source="docker.io/library/mongo:$MONGO_VERSION"
      ;;
    log-forwarder)
      source="docker.io/fluent/fluent-bit:$FLUENT_BIT_VERSION"
      ;;
    uptime-kuma)
      source="docker.io/louislam/uptime-kuma:$UPTIME_KUMA_VERSION"
      ;;
    uptime-kuma-sync)
      source="docker.io/library/python:3.12-alpine"
      ;;
  esac
  target_tag="$HARBOR_IMAGE_TAG"
  target="$REGISTRY/$PROJECT/$repo:$target_tag"
  if [ "$REFRESH_IMAGES" != true ] && podman image exists "$target"; then
    log "Using cached local image $target"
    continue
  fi
  [ "$PULL_IMAGES" = true ] || fail "Required local image $target is unavailable and PULL_IMAGES=false"
  if podman image exists "$source"; then
    log "Using cached local source image $source"
    podman tag "$source" "$target"
    if [ "$PUBLISH_IMAGES" = true ]; then
      timeout "$IMAGE_PULL_TIMEOUT_SECONDS" podman push "$target" \
        || fail "Unable to publish $target within ${IMAGE_PULL_TIMEOUT_SECONDS}s"
      [ "$HARBOR_READY" = true ] && label_harbor_artifact "$repo" "$target_tag"
    else
      log "Keeping image local without publishing $target (PUBLISH_IMAGES=false)"
    fi
    continue
  fi
  log "Checking registry image $target"
  if timeout "$IMAGE_PULL_TIMEOUT_SECONDS" podman pull "$target"; then
    log "Using registry image $target"
    continue
  fi
  [ "$PULL_IMAGES" = true ] || fail "Required local image $target is unavailable and PULL_IMAGES=false"
  log "Registry image unavailable; preparing source image $source"
  cache_source=
  if cache_source=$(harbor_cache_reference "$source" 2>/dev/null); then
    :
  else
    cache_source=
  fi
  if [ -n "$cache_source" ] && [ "$cache_source" != "$source" ]; then
    log "Trying Harbor cache image $cache_source"
    if podman image exists "$cache_source"; then
      log "Using cached local source image $cache_source"
      source="$cache_source"
    elif timeout "$IMAGE_PULL_TIMEOUT_SECONDS" podman pull "$cache_source"; then
      source="$cache_source"
    else
      log "WARNING: Harbor cache pull failed; falling back to origin image $source"
      timeout "$IMAGE_PULL_TIMEOUT_SECONDS" podman pull "$source" \
        || fail "Unable to pull $source within ${IMAGE_PULL_TIMEOUT_SECONDS}s"
    fi
  else
    timeout "$IMAGE_PULL_TIMEOUT_SECONDS" podman pull "$source" \
      || fail "Unable to pull $source within ${IMAGE_PULL_TIMEOUT_SECONDS}s"
  fi
  podman tag "$source" "$target"
  if [ "$PUBLISH_IMAGES" = true ]; then
    timeout "$IMAGE_PULL_TIMEOUT_SECONDS" podman push "$target" \
      || fail "Unable to publish $target within ${IMAGE_PULL_TIMEOUT_SECONDS}s"
    [ "$HARBOR_READY" = true ] && label_harbor_artifact "$repo" "$target_tag"
  else
    log "Keeping image local without publishing $target (PUBLISH_IMAGES=false)"
  fi
done <<IMAGES
secdns docker.io/coredns/coredns:${COREDNS_VERSION}
caddy docker.io/library/caddy:${CADDY_VERSION}
wazuh-indexer versioned
wazuh-manager versioned
wazuh-dashboard versioned
graylog-mongo docker.io/library/mongo:${MONGO_VERSION}
graylog-datanode versioned
graylog versioned
log-forwarder docker.io/fluent/fluent-bit:latest
uptime-kuma docker.io/louislam/uptime-kuma:latest
uptime-kuma-sync docker.io/library/python:3.12-alpine
IMAGES

wait_for_containers() {
  label="$1"
  shift
  wait_containers="$*"
  wait_deadline=$(( $(date +%s) + HEALTH_TIMEOUT_SECONDS ))
  log "Waiting for $label prerequisites: $wait_containers"
  while :; do
    wait_ready=true
    for container in $wait_containers; do
      status="$(podman inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || true)"
      case "$status" in
        'running healthy'|'running none') ;;
        *) wait_ready=false; break ;;
      esac
    done
    [ "$wait_ready" = true ] && return 0
    [ "$(date +%s)" -lt "$wait_deadline" ] || fail_with_diagnostics "$label prerequisites did not become ready: $wait_containers"
    sleep "$POLL_INTERVAL_SECONDS"
  done
}

indexer_security_status() {
  podman exec wazuh-indexer sh -c '
    curl -ksS -o /dev/null -w "%{http_code}" \
      --cacert /usr/share/wazuh-indexer/config/certs/root-ca.pem \
      --cert /usr/share/wazuh-indexer/config/certs/admin.pem \
      --key /usr/share/wazuh-indexer/config/certs/admin-key.pem \
      https://localhost:9200/.opendistro_security 2>/dev/null || true
  ' 2>/dev/null || true
}

initialize_indexer_security() {
  deadline=$(( $(date +%s) + INDEXER_SECURITY_INIT_TIMEOUT_SECONDS ))
  log "Waiting for Wazuh indexer HTTPS endpoint before checking OpenSearch Security"
  while :; do
    indexer_http_status="$(podman exec wazuh-indexer sh -c '
      curl -ksS -o /dev/null -w "%{http_code}" https://localhost:9200/ 2>/dev/null || true
    ' 2>/dev/null || true)"
    case "$indexer_http_status" in
      2??|3??|401|503) break ;;
    esac
    [ "$(date +%s)" -lt "$deadline" ] || fail_with_diagnostics "Wazuh indexer HTTPS endpoint did not become available"
    sleep "$POLL_INTERVAL_SECONDS"
  done

  indexer_security_http_status="$(indexer_security_status)"
  case "$indexer_security_http_status" in
    2??)
      log "Wazuh indexer OpenSearch Security is already initialized"
      return 0
      ;;
  esac

  log "Initializing Wazuh indexer OpenSearch Security with securityadmin.sh"
  if ! timeout "$INDEXER_SECURITY_INIT_TIMEOUT_SECONDS" podman exec --user 1000:0 wazuh-indexer bash -lc '
    export JAVA_HOME=/usr/share/wazuh-indexer/jdk
    exec /usr/share/wazuh-indexer/plugins/opensearch-security/tools/securityadmin.sh \
      -cd /usr/share/wazuh-indexer/config/opensearch-security/ \
      -nhnv \
      -icl \
      -cacert /usr/share/wazuh-indexer/config/certs/root-ca.pem \
      -cert /usr/share/wazuh-indexer/config/certs/admin.pem \
      -key /usr/share/wazuh-indexer/config/certs/admin-key.pem \
      -h 127.0.0.1 \
      -p 9200
  '; then
    fail_with_diagnostics "Wazuh indexer securityadmin.sh initialization failed"
  fi

  indexer_security_http_status="$(indexer_security_status)"
  case "$indexer_security_http_status" in
    2??) log "Wazuh indexer OpenSearch Security initialized" ;;
    *) fail_with_diagnostics "Wazuh indexer OpenSearch Security was not initialized successfully (HTTP $indexer_security_http_status)" ;;
  esac
}

log_starting "Starting MVP containers in dependency order (profile mvp)"
compose --profile mvp config >/dev/null

# Keep startup explicit even though Compose also has depends_on declarations.
# This makes the readiness boundary visible and avoids launching dependents
# while their network endpoints are still unavailable.
compose --profile mvp up --detach coredns caddy wazuh-indexer mongodb uptime-kuma
initialize_indexer_security
wait_for_containers "base services" "secdns caddy wazuh-indexer graylog-mongo uptime-kuma"

# Wazuh manager can be checked independently, but Graylog must start while the
# Data Node is still in first-run preflight. Waiting for both services here
# would deadlock the Graylog/Data Node certificate bootstrap.
compose --profile mvp up --detach wazuh-manager graylog-datanode
wait_for_containers "Wazuh manager" "wazuh-manager"

compose --profile mvp up --detach wazuh-dashboard graylog
wait_for_containers "Graylog/Data Node services" "graylog-datanode graylog"

wait_for_containers "Wazuh dashboard" "wazuh-dashboard"

compose --profile mvp up --detach fluent-bit uptime-kuma-sync

log "Waiting for all MVP containers and health checks (timeout ${HEALTH_TIMEOUT_SECONDS}s)"
containers="secdns caddy wazuh-indexer wazuh-manager wazuh-dashboard graylog-mongo graylog-datanode graylog fluent-bit uptime-kuma uptime-kuma-sync"
deadline=$(( $(date +%s) + HEALTH_TIMEOUT_SECONDS ))
container_total=0
for container in $containers; do container_total=$((container_total + 1)); done
last_signature=
stuck_since="$(date +%s)"
while :; do
  ready=true
  ready_count=0
  signature=
  for container in $containers; do
    status="$(podman inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || true)"
    signature="$signature|$container=$status"
    case "$status" in
      'running healthy'|'running none') ready_count=$((ready_count + 1)) ;;
      *) ready=false ;;
    esac
  done
  now="$(date +%s)"
  if [ "$signature" != "$last_signature" ]; then
    last_signature="$signature"
    stuck_since="$now"
  fi
  progress "$ready_count" "$container_total" "MVP readiness"
  [ "$ready" = true ] && break
  [ "$now" -lt "$deadline" ] || fail_with_diagnostics "Container readiness timed out"
  [ $((now - stuck_since)) -lt "$STUCK_TIMEOUT_SECONDS" ] || fail_with_diagnostics "Container readiness made no progress for ${STUCK_TIMEOUT_SECONDS}s"
  sleep "$POLL_INTERVAL_SECONDS"
done
printf '\n'

log "Checking Graylog GELF ingestion"
GRAYLOG_PORT="${GRAYLOG_GELF_UDP_PORT:-$(env_value GRAYLOG_GELF_UDP_PORT)}"
GRAYLOG_PORT="${GRAYLOG_PORT:-12201}"
HTTP_PORT="${GRAYLOG_HTTP_PORT:-$(env_value GRAYLOG_HTTP_PORT)}"
HTTP_PORT="${HTTP_PORT:-9000}"
GRAYLOG_ROOT_USERNAME="${GRAYLOG_ROOT_USERNAME:-$(env_value GRAYLOG_ROOT_USERNAME)}"
GRAYLOG_ROOT_PASSWORD="${GRAYLOG_ROOT_PASSWORD:-$(env_value GRAYLOG_ROOT_PASSWORD)}"
[ -n "$GRAYLOG_ROOT_USERNAME" ] || fail "GRAYLOG_ROOT_USERNAME is missing from .env or the environment"
[ -n "$GRAYLOG_ROOT_PASSWORD" ] || fail "GRAYLOG_ROOT_PASSWORD is missing from .env or the environment"
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
  sleep "$POLL_INTERVAL_SECONDS"
done
[ "$found" = true ] || fail_with_diagnostics "Graylog did not index the GELF test event; check GELF input and credentials"
log "Graylog GELF event is indexed"

log "Checking Uptime Kuma"
UPTIME_KUMA_PORT="${UPTIME_KUMA_PORT:-3002}"
curl -fsS "http://127.0.0.1:$UPTIME_KUMA_PORT/" >/dev/null || fail "Uptime Kuma did not respond"
UPTIME_KUMA_PASSWORD="${UPTIME_KUMA_PASSWORD:-$(env_value UPTIME_KUMA_PASSWORD)}"
UPTIME_KUMA_USERNAME="${UPTIME_KUMA_USERNAME:-$(env_value UPTIME_KUMA_USERNAME)}"
[ -n "$UPTIME_KUMA_USERNAME" ] || fail "UPTIME_KUMA_USERNAME is missing from .env or the environment"
if [ -z "$UPTIME_KUMA_PASSWORD" ]; then
  fail "Uptime Kuma is running, but no account password is configured. Finish first-time setup, set UPTIME_KUMA_USERNAME and UPTIME_KUMA_PASSWORD in .env, then rerun scripts/start.sh to provision MVP monitors."
fi

log "Waiting for the Uptime Kuma sync helper to provision MVP monitors"
monitor_names="Caddy health|CoreDNS UDP|Uptime Kuma|Graylog web/API|Graylog GELF UDP|Graylog syslog TCP|Graylog MongoDB|Graylog Data Node|Wazuh dashboard|Wazuh manager API|Wazuh indexer|Wazuh agent events UDP|Wazuh enrollment TCP"
deadline=$(( $(date +%s) + HEALTH_TIMEOUT_SECONDS ))
last_monitor_signature=
monitor_stuck_since="$(date +%s)"
while [ "$(date +%s)" -lt "$deadline" ]; do
  monitor_ready="$(podman inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' uptime-kuma-sync 2>/dev/null || true)"
  now="$(date +%s)"
  if [ "$monitor_ready" != "$last_monitor_signature" ]; then
    last_monitor_signature="$monitor_ready"
    monitor_stuck_since="$now"
  fi
  monitors_ready=true
  old_ifs="$IFS"
  IFS='|'
  for monitor in $monitor_names; do
    podman logs uptime-kuma-sync 2>&1 | grep -F "$monitor" >/dev/null || { monitors_ready=false; break; }
  done
  IFS="$old_ifs"
  [ "$monitors_ready" = true ] && break
  [ $((now - monitor_stuck_since)) -lt "$STUCK_TIMEOUT_SECONDS" ] || fail_with_diagnostics "Uptime Kuma monitor sync made no progress for ${STUCK_TIMEOUT_SECONDS}s"
  sleep "$POLL_INTERVAL_SECONDS"
done
[ "$monitors_ready" = true ] || fail_with_diagnostics "Uptime Kuma did not report all MVP monitors as added or updated; check podman logs uptime-kuma-sync and the Kuma credentials"
log "Uptime Kuma reports all MVP service monitors provisioned"
log "MVP startup checks completed"
