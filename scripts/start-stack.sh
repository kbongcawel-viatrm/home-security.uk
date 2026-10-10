#!/usr/bin/env sh
# Secureblue-friendly startup helper for security-stack.compose.yml.
# Uses Podman Compose by preference and avoids tearing down running services
# before a replacement deployment has been validated.

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

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 127
  fi
}

usage() {
  cat <<'EOF'
Usage:
  sh scripts/start-stack.sh [up] [PROFILE]
  sh scripts/start-stack.sh config [PROFILE]
  sh scripts/start-stack.sh down [PROFILE]
  sh scripts/start-stack.sh ps [PROFILE]
  sh scripts/start-stack.sh logs PROFILE
  sh scripts/start-stack.sh pull PROFILE
  sh scripts/start-stack.sh build PROFILE

Profiles:
  brain network ir vuln all dns secrets ghost llm ops dashboard monitor logs
  backup scanner shield

Examples:
  sh scripts/start-stack.sh config brain
  sh scripts/start-stack.sh up brain
  sh scripts/start-stack.sh up network
  sh scripts/start-stack.sh up all
  sh scripts/start-stack.sh ps brain
  sh scripts/start-stack.sh down ir
  sh scripts/start-stack.sh down all

Environment overrides:
  CONTAINER_ENGINE=podman|docker
  COMPOSE_FILE=security-stack.compose.yml
  SECSTACK_PROFILES="brain network"
  PULL_IMAGES=true|false
  APPLY_SYSCTL=true|false
  WAIT_HEALTH=true|false
  HEALTH_TIMEOUT_SECONDS=900
  USE_VAULT_ENV=true|false
  CONTAINER_SOCKET_PATH=/run/user/UID/podman/podman.sock
EOF
}

valid_profile() {
  case "$1" in
    brain|network|ir|vuln|all|dns|secrets|ghost|llm|ops|dashboard|monitor|logs|backup|scanner|shield) return 0 ;;
    *) return 1 ;;
  esac
}

validate_profiles() {
  [ -n "${PROFILES}" ] || {
    echo "At least one profile is required." >&2
    usage >&2
    exit 2
  }
  for profile in ${PROFILES}; do
    if ! valid_profile "${profile}"; then
      echo "Invalid profile: ${profile}" >&2
      usage >&2
      exit 2
    fi
  done
}

select_container_engine() {
  if [ -n "${CONTAINER_ENGINE}" ]; then
    require_command "${CONTAINER_ENGINE}"
    if ! "${CONTAINER_ENGINE}" compose version >/dev/null 2>&1; then
      echo "${CONTAINER_ENGINE} compose is unavailable; install/configure its Compose provider" >&2
      exit 127
    fi
  elif command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
    CONTAINER_ENGINE=podman
  elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    CONTAINER_ENGINE=docker
  else
    echo "Missing container engine: install Podman with a Compose provider, or Docker Compose." >&2
    exit 127
  fi
  export CONTAINER_ENGINE
  log "using container engine: ${CONTAINER_ENGINE}"
}

prepare_workspace() {
  cd "${PROJECT_ROOT}"

  if [ ! -f "${COMPOSE_FILE}" ]; then
    echo "Compose file not found: ${COMPOSE_FILE}" >&2
    exit 2
  fi

  if [ ! -f ".env" ]; then
    if [ -f ".env.example" ]; then
      cp .env.example .env
      log "created .env from .env.example; review secrets and bind addresses before starting services"
    else
      echo ".env and .env.example are both missing; refusing to continue." >&2
      exit 2
    fi
  fi

  mkdir -p \
    "The Hands/backups" \
    "The Hands/reports/data/container-vulnerabilities" \
    "The Sword/Ansible/.ssh" \
    "The Sword/Suricata/rules"
}

# Keep the command arguments intact while supplying interpolation files.
compose() {
  if [ -f ".env" ] && [ -f ".env.vault" ]; then
    "${CONTAINER_ENGINE}" compose --env-file .env --env-file .env.vault -f "${COMPOSE_FILE}" "$@"
  elif [ -f ".env" ]; then
    "${CONTAINER_ENGINE}" compose --env-file .env -f "${COMPOSE_FILE}" "$@"
  elif [ -f ".env.vault" ]; then
    "${CONTAINER_ENGINE}" compose --env-file .env.vault -f "${COMPOSE_FILE}" "$@"
  else
    "${CONTAINER_ENGINE}" compose -f "${COMPOSE_FILE}" "$@"
  fi
}

profile_args() {
  for profile in ${PROFILES}; do
    printf '%s\n' "--profile" "${profile}"
  done
}

# Use a positional-argument-safe profile invocation. Profiles are validated
# against a fixed allowlist, so the expansion below cannot inject shell syntax.
prepare_podman_compose() {
  [ "${CONTAINER_ENGINE}" = "podman" ] || return 0

  CONTAINER_SOCKET_PATH="${CONTAINER_SOCKET_PATH:-/run/user/$(id -u)/podman/podman.sock}"
  export CONTAINER_SOCKET_PATH

  # The revised Compose file should not contain Docker GELF logging settings.
  # Do not rewrite the Compose file unless an explicit legacy GELF driver remains.
  if grep -Eq 'driver:[[:space:]]*gelf|gelf-address:' "${COMPOSE_FILE}"; then
    log "warning: legacy GELF logging settings found; Podman may not support Docker's GELF logging driver"
    log "remove the legacy GELF logging blocks or configure a separate log forwarder"
  fi

  log "using Podman socket path: ${CONTAINER_SOCKET_PATH}"
  log "ensure the user socket is active if a service requires it: systemctl --user enable --now podman.socket"
}

profile_includes() {
  wanted="$1"
  for profile in ${PROFILES}; do
    [ "${profile}" = "${wanted}" ] && return 0
  done
  return 1
}

render_vault_env() {
  [ "${USE_VAULT_ENV}" = "true" ] || {
    log "Vault rendering disabled by USE_VAULT_ENV=false"
    return 0
  }

  if [ -z "${VAULT_TOKEN:-}" ]; then
    log "Vault env render skipped: VAULT_TOKEN is unset"
    return 0
  fi

  if ! command -v vault >/dev/null 2>&1; then
    log "Vault CLI unavailable; keeping any existing .env.vault unchanged"
    return 0
  fi

  if [ ! -f "The Shield/vault/scripts/render-service-env.sh" ]; then
    echo "Vault renderer script is missing." >&2
    return 1
  fi

  log "rendering Vault environment file"
  VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:${VAULT_HTTP_PORT:-8200}}" \
    VAULT_KV_MOUNT="${VAULT_KV_MOUNT:-secret}" \
    sh "The Shield/vault/scripts/render-service-env.sh" .env.vault
}

apply_sysctl() {
  [ "${APPLY_SYSCTL}" = "true" ] || return 0

  # vm.max_map_count is relevant to the OpenSearch-based Brain stack.
  profile_includes brain || profile_includes all || return 0

  current="$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)"
  case "${current}" in
    ''|*[!0-9]*) current=0 ;;
  esac

  if [ "${current}" -ge 262144 ]; then
    log "vm.max_map_count is already ${current}"
    return 0
  fi

  if [ "$(id -u)" -eq 0 ]; then
    sysctl -w vm.max_map_count=262144
  elif command -v run0 >/dev/null 2>&1; then
    log "requesting privileged runtime change via run0"
    run0 sysctl -w vm.max_map_count=262144
  else
    echo "vm.max_map_count is ${current}; set it to 262144 on the host before starting brain/all." >&2
    echo "On Secureblue, use: run0 sysctl -w vm.max_map_count=262144" >&2
    return 1
  fi

  current="$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)"
  if [ "${current}" -lt 262144 ] 2>/dev/null; then
    echo "vm.max_map_count remains below 262144; refusing to start brain/all." >&2
    return 1
  fi
  log "vm.max_map_count is now ${current}; this runtime setting may need persistent host configuration"
}

pull_images() {
  log "pulling images for selected profiles"
  compose $(profile_args) pull
}

wait_for_health() {
  [ "${WAIT_HEALTH}" = "true" ] || {
    log "health wait disabled"
    return 0
  }

  require_command python3
  start="$(date +%s)"

  while :; do
    # Compose providers vary in their JSON shape. The parser accepts a JSON
    # array, a single JSON object, or newline-delimited JSON objects.
    ps_json="$(compose $(profile_args) ps --all --format json 2>/dev/null || true)"
    status="$(printf '%s\n' "${ps_json}" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    print("unknown")
    raise SystemExit
try:
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        data = [json.loads(line) for line in raw.splitlines() if line.strip()]
    if isinstance(data, dict):
        data = [data]
    if not isinstance(data, list):
        print("unknown")
        raise SystemExit
    pending = []
    failed = []
    for item in data:
        if not isinstance(item, dict):
            continue
        state = str(item.get("State", item.get("state", ""))).lower()
        health = str(item.get("Health", item.get("health", ""))).lower()
        status = str(item.get("Status", item.get("status", ""))).lower()
        exit_code = item.get("ExitCode", item.get("exitCode", item.get("exit_code")))
        label = item.get("Name", item.get("name", item.get("Service", item.get("service", "container"))))
        exited = state in ("dead", "exited", "failed") or status.startswith("exited") or status.startswith("dead")
        successful_exit = str(exit_code) == "0" or "exited (0)" in status
        if "unhealthy" in health or "unhealthy" in status or (exited and not successful_exit):
            failed.append(str(label))
        elif health == "starting" or state in ("created", "restarting", "paused") or "restarting" in status or "starting" in status:
            pending.append(str(label))
    if failed:
        print("failed:" + ",".join(failed))
    elif pending:
        print("pending:" + ",".join(pending))
    else:
        print("ready")
except Exception:
    print("unknown")
')"

    case "${status}" in
      ready)
        log "no unhealthy, starting, or failed states reported by Compose"
        return 0
        ;;
      failed:*)
        echo "Container failure detected: ${status#failed:}" >&2
        compose $(profile_args) ps
        return 1
        ;;
      unknown)
        log "warning: Compose provider did not return parseable JSON; showing service state instead"
        compose $(profile_args) ps
        # Do not falsely claim health. Allow the caller to inspect provider output.
        return 2
        ;;
      pending:*)
        ;;
    esac

    now="$(date +%s)"
    elapsed=$((now - start))
    if [ "${elapsed}" -ge "${HEALTH_TIMEOUT_SECONDS}" ]; then
      log "health wait timed out after ${HEALTH_TIMEOUT_SECONDS}s; pending: ${status#pending:}"
      compose $(profile_args) ps
      return 1
    fi

    log "waiting for health checks (${elapsed}s elapsed): ${status#pending:}"
    sleep 15
  done
}

start_stack() {
  render_vault_env
  apply_sysctl

  log "validating Compose configuration for profiles: ${PROFILES}"
  compose $(profile_args) config >/dev/null

  if [ "${PULL_IMAGES}" = "true" ]; then
    pull_images
  fi

  log "starting/updating services without tearing down the existing stack"
  compose $(profile_args) up -d --build
  compose $(profile_args) ps
  wait_for_health
  log "startup complete"
}

main() {
  action="${1:-up}"
  profile="${2:-}"

  case "${action}" in
    config)
      if [ -n "${profile}" ]; then
        PROFILES="${profile}"
      fi
      validate_profiles
      prepare_workspace
      select_container_engine
      prepare_podman_compose
      compose $(profile_args) config
      ;;
    up|down|ps|logs|pull|build)
      if [ -n "${profile}" ]; then
        PROFILES="${profile}"
      elif [ "${action}" != "up" ]; then
        echo "A valid profile is required for '${action}'." >&2
        usage >&2
        exit 2
      fi
      validate_profiles
      prepare_workspace
      select_container_engine
      prepare_podman_compose

      case "${action}" in
        up)
          start_stack
          ;;
        down)
          log "stopping selected profile(s): ${PROFILES}"
          compose $(profile_args) down
          ;;
        ps)
          compose $(profile_args) ps
          ;;
        logs)
          compose $(profile_args) logs -f
          ;;
        pull)
          compose $(profile_args) pull
          ;;
        build)
          compose $(profile_args) build
          ;;
      esac
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      echo "Unknown action: ${action}" >&2
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
