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
for cmd in podman podman-compose python3 curl firewall-cmd sudo; do
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

log "Creating persistent volumes (Compose will mount the declared volumes at startup)"
project_name="$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' .env | tail -n 1 | tr -d '"\047')"
project_name="${project_name:-home-security-uk}"
for volume in fluent-bit-state uptime-kuma-data wazuh-indexer-data wazuh-manager-data wazuh-manager-logs wazuh-manager-queue graylog-mongo-data graylog-datanode-data graylog-data; do
  name="${project_name}_${volume}"
  podman volume exists "$name" || podman volume create "$name" >/dev/null
done

log "Configuring Harbor registry access"
podman login "$REGISTRY"

# Docker Hub source to Harbor repository used in simplified.compose.yml.
while IFS=' ' read -r repo source; do
  [ -n "$repo" ] || continue
  target="$REGISTRY/$PROJECT/$repo:latest"
  if ! podman image exists "$source"; then
    log "Pulling $source"
    podman pull "$source"
  fi
  podman tag "$source" "$target"
  podman push "$target"
done <<'IMAGES'
secdns docker.io/coredns/coredns:latest
caddy docker.io/library/caddy:latest
wazuh-indexer docker.io/wazuh/wazuh-indexer:latest
wazuh-manager docker.io/wazuh/wazuh-manager:latest
wazuh-dashboard docker.io/wazuh/wazuh-dashboard:latest
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
monitor_names="MVP CoreDNS UDP|MVP Caddy HTTP|MVP Wazuh Indexer|MVP Wazuh Manager Events|MVP Wazuh Enrollment|MVP Wazuh Dashboard|MVP Graylog API|MVP Graylog GELF UDP|MVP Fluent Bit Health|MVP Graylog Data Node|MVP MongoDB|MVP Uptime Kuma"
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
