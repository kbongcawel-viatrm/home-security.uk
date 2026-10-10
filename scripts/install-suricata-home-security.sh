#!/usr/bin/env bash
# Install repository-managed Suricata settings/rules into the native host service.
# Safe to run repeatedly. Backs up existing files and rolls back on failure.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${SURICATA_CONFIG_PATH:-/etc/suricata/suricata.yaml}"
CONFIG_FRAGMENT="/etc/suricata/home-security.yaml"
RULE_DIR="/etc/suricata/rules"
RULE_FILE="${RULE_DIR}/home-security.rules"
SOURCE_CONFIG="${REPO_ROOT}/suricata/home-security.yaml"
SOURCE_RULES="${REPO_ROOT}/suricata/home-security.rules"

[[ $EUID -eq 0 ]] || { echo "Run this installer as root." >&2; exit 1; }
[[ -f "$CONFIG" ]] || { echo "Missing active Suricata config: $CONFIG" >&2; exit 1; }
[[ -f "$SOURCE_CONFIG" && -f "$SOURCE_RULES" ]] || {
  echo "Repository Suricata config/rules files are missing." >&2; exit 1;
}
command -v suricata >/dev/null
command -v systemctl >/dev/null

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup="/var/backups/suricata-home-security-$stamp"
install -d -m 0700 "$backup"
cp -a "$CONFIG" "$backup/suricata.yaml"
[[ ! -e "$CONFIG_FRAGMENT" ]] || cp -a "$CONFIG_FRAGMENT" "$backup/home-security.yaml"
[[ ! -e "$RULE_FILE" ]] || cp -a "$RULE_FILE" "$backup/home-security.rules"
printf '%s\n' "$CONFIG" > "$backup/config-path"

rollback() {
  rc=$?
  if (( rc != 0 )); then
    echo "Deployment failed; restoring previous Suricata configuration." >&2
    cp -a "$backup/suricata.yaml" "$CONFIG"
    if [[ -e "$backup/home-security.yaml" ]]; then
      cp -a "$backup/home-security.yaml" "$CONFIG_FRAGMENT"
    else
      rm -f "$CONFIG_FRAGMENT"
    fi
    if [[ -e "$backup/home-security.rules" ]]; then
      cp -a "$backup/home-security.rules" "$RULE_FILE"
    else
      rm -f "$RULE_FILE"
    fi
    echo "Backup retained at $backup" >&2
  fi
  exit "$rc"
}
trap rollback EXIT

install -d -m 0755 "$(dirname "$CONFIG_FRAGMENT")" "$RULE_DIR"
install -o root -g root -m 0644 "$SOURCE_CONFIG" "$CONFIG_FRAGMENT"
install -o root -g root -m 0644 "$SOURCE_RULES" "$RULE_FILE"

python3 - "$CONFIG" "$CONFIG_FRAGMENT" "$RULE_FILE" <<'PY'
import re
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
fragment = sys.argv[2]
rule_path = sys.argv[3]
text = config_path.read_text()
lines = text.splitlines(keepends=True)

# Add a nested include beneath vars.address-groups so the packaged host config
# and unrelated variables remain intact. Replace HOME_NET/EXTERNAL_NET entries
# in that mapping with the include, rather than defining duplicate YAML keys.
address_idx = next(
    (i for i, line in enumerate(lines)
     if re.match(r"^\s*address-groups:\s*(?:#.*)?$", line.rstrip("\n"))),
    None,
)
if address_idx is None:
    raise SystemExit("Could not find vars.address-groups in active Suricata config.")

address_indent = len(lines[address_idx]) - len(lines[address_idx].lstrip())
block_end = len(lines)
for i in range(address_idx + 1, len(lines)):
    stripped = lines[i].strip()
    if not stripped or stripped.startswith("#"):
        continue
    indent = len(lines[i]) - len(lines[i].lstrip())
    if indent <= address_indent:
        block_end = i
        break

block = lines[address_idx + 1:block_end]
include_line = f"{' ' * (address_indent + 4)}include: {fragment}\n"
if not any(re.search(r"^\s*include:\s*" + re.escape(fragment) + r"\s*(?:#.*)?$", x.rstrip("\n")) for x in block):
    key_indices = [
        i for i, line in enumerate(block)
        if re.match(r"^\s*(?:HOME_NET|EXTERNAL_NET):", line)
    ]
    if not key_indices:
        # Insert include in the address-groups map; other address groups remain.
        block.insert(0, include_line)
    else:
        first = min(key_indices)
        block = [line for line in block
                 if not re.match(r"^\s*(?:HOME_NET|EXTERNAL_NET):", line)]
        block.insert(min(first, len(block)), include_line)
    lines[address_idx + 1:block_end] = block

# Add the custom rules file to the existing rule-files sequence, retaining
# whatever packaged/suricata-update rule files are already configured.
text = "".join(lines)
if rule_path not in text:
    lines = text.splitlines(keepends=True)
    rule_idx = next(
        (i for i, line in enumerate(lines)
         if re.match(r"^\s*rule-files:\s*(?:#.*)?$", line.rstrip("\n"))),
        None,
    )
    if rule_idx is None:
        raise SystemExit("Could not find rule-files in active Suricata config.")
    header_indent = len(lines[rule_idx]) - len(lines[rule_idx].lstrip())
    item_indent = header_indent + 2
    for i in range(rule_idx + 1, len(lines)):
        line = lines[i]
        if re.match(r"^\s*#", line) or not line.strip():
            continue
        match = re.match(r"^(\s*)-\s+", line)
        if match:
            item_indent = len(match.group(1))
            break
        indent = len(line) - len(line.lstrip())
        if indent <= header_indent and re.match(r"^[A-Za-z0-9_-]+\s*:", line):
            break
    lines.insert(rule_idx + 1, f"{' ' * item_indent}- {rule_path}\n")
    text = "".join(lines)

config_path.write_text(text)
PY

echo "Validating Suricata configuration..."
suricata -T -c "$CONFIG"
echo "Restarting native Suricata service..."
systemctl restart suricata
systemctl is-active --quiet suricata
trap - EXIT
echo "Suricata config and rules installed. Backup: $backup"
