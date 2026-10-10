#!/usr/bin/env sh
set -eu

COMPOSE_FILE="${COMPOSE_FILE:-security-stack.compose.yml}"
PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PROFILES="${SECSTACK_PROFILES:-all}"
PULL_IMAGES="${PULL_IMAGES:-true}"
APPLY_SYSCTL="${APPLY_SYSCTL:-true}"
WAIT_HEALTH="${WAIT_HEALTH:-true}"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-900}"
USE_VAULT_ENV="${USE_VAULT_ENV:-true}"
CONTAINER_ENGINE="${CONTAINER_ENGINE:-}"
PODMAN_COMPOSE_FILE=""

log() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

compose() {
  env_args=""
  if [ -f ".env" ]; then
    env_args="${env_args} --env-file .env"
  fi
  if [ -f ".env.vault" ]; then
    env_args="${env_args} --env-file .env.vault"
  fi
  # shellcheck disable=SC2086
  "${CONTAINER_ENGINE}" compose ${env_args} -f "${COMPOSE_FILE}" "$@"
}

select_container_engine() {
  if [ -n "${CONTAINER_ENGINE}" ]; then
    require_command "${CONTAINER_ENGINE}"
    if ! "${CONTAINER_ENGINE}" compose version >/dev/null 2>&1; then
      echo "${CONTAINER_ENGINE} compose is unavailable; install/configure its Compose provider" >&2
      exit 127
    fi
  elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    CONTAINER_ENGINE=docker
  elif command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
    CONTAINER_ENGINE=podman
  else
    echo "Missing container engine: install Docker Compose or Podman with a Compose provider" >&2
    exit 127
  fi
  export CONTAINER_ENGINE
  log "using container engine: ${CONTAINER_ENGINE}"
}

profile_args() {
  for profile in ${PROFILES}; do
    printf -- '--profile\n%s\n' "${profile}"
  done
}

pull_missing_images() {
  require_command python3

  missing_services="$(compose $(profile_args) config --format json | python3 -c '
import json
import subprocess
import sys

config = json.load(sys.stdin)
engine = sys.argv[1]
for service, definition in config.get("services", {}).items():
    image = definition.get("image")
    if not image:
        continue
    result = subprocess.run(
        [engine, "image", "inspect", image],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode == 0:
        print(f"{service}: image already present locally ({image})", file=sys.stderr)
    else:
        print(service)
' "${CONTAINER_ENGINE}")"

  if [ -n "${missing_services}" ]; then
    log "pulling images missing locally"
    # Service names in Compose output are whitespace-free.
    # shellcheck disable=SC2086
    compose $(profile_args) pull ${missing_services}
  else
    log "all selected images are already present locally; skipping remote pulls"
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 127
  fi
}

prepare_workspace() {
  cd "${PROJECT_ROOT}"

  if [ ! -f ".env" ]; then
    cp .env.example .env
    log "created .env from .env.example; review secrets before exposing services"
  fi

  mkdir -p "The Hands/backups" "The Hands/reports/data/container-vulnerabilities" "The Sword/Ansible/.ssh" "The Sword/Suricata/rules"
}

prepare_podman_compose() {
  if [ "${CONTAINER_ENGINE}" != "podman" ]; then
    return 0
  fi

  CONTAINER_SOCKET_PATH="${CONTAINER_SOCKET_PATH:-/run/user/$(id -u)/podman/podman.sock}"
  export CONTAINER_SOCKET_PATH

  source_compose_file="${COMPOSE_FILE}"
  case "${source_compose_file}" in
    /*) ;;
    *) source_compose_file="${PROJECT_ROOT}/${source_compose_file}" ;;
  esac
  PODMAN_COMPOSE_FILE="${PROJECT_ROOT}/.security-stack.podman.$$.yml"
  # Podman does not implement Docker's GELF logging driver. Keep the Docker
  # Compose file unchanged and use journald in a temporary Podman variant.
  sed \
    -e 's/driver: gelf/driver: journald/' \
    -e '/^[[:space:]]*options:$/d' \
    -e '/^[[:space:]]*gelf-address:/d' \
    -e '/^[[:space:]]*tag: "{{.Name}}"/d' \
    "${source_compose_file}" > "${PODMAN_COMPOSE_FILE}"
  COMPOSE_FILE="${PODMAN_COMPOSE_FILE}"
  trap 'rm -f "${PODMAN_COMPOSE_FILE}"' 0
  trap 'exit 1' HUP INT TERM
  log "using Podman socket: ${CONTAINER_SOCKET_PATH}"
  log "using journald logging for Podman"
}

render_vault_env() {
  if [ "${USE_VAULT_ENV}" != "true" ]; then
    return 0
  fi

  if [ -z "${VAULT_TOKEN:-}" ]; then
    log "Vault env render skipped; set VAULT_TOKEN or run 'The Shield/vault/scripts/render-service-env.sh' manually"
    return 0
  fi

  if command -v vault >/dev/null 2>&1; then
    VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:${VAULT_HTTP_PORT:-8200}}" \
      VAULT_KV_MOUNT="${VAULT_KV_MOUNT:-secret}" \
      sh "The Shield/vault/scripts/render-service-env.sh" .env.vault || log "Vault env render failed; continuing with existing env values"
  else
    log "Vault CLI unavailable; skipping .env.vault render"
  fi
}

apply_sysctl() {
  if [ "${APPLY_SYSCTL}" != "true" ]; then
    return 0
  fi

  current="$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)"
  if [ "${current}" -lt 262144 ] 2>/dev/null; then
    if [ "$(id -u)" -eq 0 ]; then
      sysctl -w vm.max_map_count=262144
    elif command -v sudo >/dev/null 2>&1; then
      sudo sysctl -w vm.max_map_count=262144
    else
      log "vm.max_map_count is ${current}; set it to 262144 before starting Wazuh/Graylog"
    fi
  fi
}

wait_for_health() {
  if [ "${WAIT_HEALTH}" != "true" ]; then
    return 0
  fi

  start="$(date +%s)"
  while :; do
    unhealthy="$(compose $(profile_args) ps --format json 2>/dev/null | grep -E '"Health":"(starting|unhealthy)"' || true)"
    if [ -z "${unhealthy}" ]; then
      log "no unhealthy or starting containers reported"
      return 0
    fi

    now="$(date +%s)"
    elapsed=$((now - start))
    if [ "${elapsed}" -ge "${HEALTH_TIMEOUT_SECONDS}" ]; then
      log "health wait timed out after ${HEALTH_TIMEOUT_SECONDS}s"
      compose $(profile_args) ps
      return 1
    fi

    log "waiting for health checks (${elapsed}s elapsed)"
    sleep 15
  done
}

main() {
  select_container_engine
  prepare_workspace
  prepare_podman_compose
  render_vault_env
  apply_sysctl

  log "validating compose profiles: ${PROFILES}"
  compose $(profile_args) config >/dev/null

  if [ "${PULL_IMAGES}" = "true" ]; then
    pull_missing_images
  fi

  log "starting services"
  compose $(profile_args) up -d --build --remove-orphans
  compose $(profile_args) ps
  wait_for_health
  log "startup complete"
}

main "$@"
