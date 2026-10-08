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
  render_vault_env
  apply_sysctl

  log "validating compose profiles: ${PROFILES}"
  compose $(profile_args) config >/dev/null

  if [ "${PULL_IMAGES}" = "true" ]; then
    log "pulling images"
    compose $(profile_args) pull
  fi

  log "starting services"
  compose $(profile_args) up -d --build --remove-orphans
  compose $(profile_args) ps
  wait_for_health
  log "startup complete"
}

main "$@"
