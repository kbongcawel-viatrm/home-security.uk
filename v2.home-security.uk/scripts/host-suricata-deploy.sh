#!/usr/bin/env bash
# Host-side Suricata deployment and verification for Fedora Secureblue.
# Run directly on the host as root (not inside Toolbox), e.g.:
#   sudo bash scripts/host-suricata-deploy.sh install   # install, configure, enable, start
#   sudo bash scripts/host-suricata-deploy.sh verify    # check the running sensor only
# No reboot is attempted. If rpm-ostree cannot apply Suricata live, install it in a
# maintenance window and reboot manually, then re-run "install" or "verify".
set -Eeuo pipefail

mode="${1:-install}"
[[ "$mode" == "install" || "$mode" == "verify" ]] || { echo "Usage: $0 [install|verify]" >&2; exit 2; }
[[ "$(id -u)" -eq 0 ]] || { echo "Run as root on the host, e.g. sudo bash $0 $mode" >&2; exit 1; }

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
eve_log="${SURICATA_LOG_DIR:-/var/log/suricata}/eve.json"
config=/etc/suricata/suricata.yaml

log() { printf '[host-suricata] %s\n' "$*"; }
die() { printf '[host-suricata] ERROR: %s\n' "$*" >&2; exit 1; }

on_error() {
  local rc=$?
  log "Failed with exit code $rc. Recent Suricata journal:"
  journalctl -u suricata.service -n 100 --no-pager || true
  exit "$rc"
}
trap on_error ERR

install_package() {
  if rpm -q suricata >/dev/null 2>&1; then
    log "Suricata package already installed."
    return
  fi
  log "Suricata is not installed; applying it live with rpm-ostree."
  rpm-ostree install --apply-live suricata \
    || die "Live installation failed or is unsupported. Install in a maintenance window, reboot, then rerun."
}

install_sensor() {
  install_package
  command -v suricata >/dev/null || die "suricata binary not found after installation."
  systemctl cat suricata.service >/dev/null || die "suricata.service unit is missing."
  log "Installing repository configuration and enabling the service."
  bash "$repo_root/scripts/install-suricata-home-security.sh"
}

verify_sensor() {
  command -v suricata >/dev/null || die "suricata binary not found."
  systemctl cat suricata.service >/dev/null || die "suricata.service unit is missing."
  systemctl is-enabled --quiet suricata.service || die "suricata.service is not enabled."
  systemctl is-active --quiet suricata.service || die "suricata.service is not active."
  suricata -T -c "$config" >/dev/null || die "suricata configuration test failed for $config."
  [[ -r "$eve_log" ]] || die "$eve_log is not readable."
  last_line="$(tail -n 1 "$eve_log")"
  [[ -n "$last_line" ]] || die "$eve_log is empty."
  printf '%s\n' "$last_line" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' \
    || die "Last line of $eve_log is not valid JSON."
  log "Suricata is enabled, active, configured, and writing valid EVE JSON."
  systemctl --no-pager --full status suricata.service | head -n 15
}

case "$mode" in
  install) install_sensor; verify_sensor ;;
  verify)  verify_sensor ;;
esac
