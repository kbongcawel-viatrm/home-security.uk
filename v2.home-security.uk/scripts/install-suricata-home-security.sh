#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
config="${SURICATA_CONFIG_PATH:-/etc/suricata/suricata.yaml}"
fragment=/etc/suricata/home-security.yaml
rules=/etc/suricata/rules/home-security.rules
[[ -f "$config" && -f "$repo_root/suricata/home-security.yaml" && -f "$repo_root/suricata/home-security.rules" ]] || { echo "Missing Suricata config or repository files." >&2; exit 1; }
command -v suricata >/dev/null
backup="/var/backups/suricata-home-security-$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 0700 "$backup" /etc/suricata/rules
cp -a "$config" "$backup/suricata.yaml"
[[ ! -e "$fragment" ]] || cp -a "$fragment" "$backup/home-security.yaml"
[[ ! -e "$rules" ]] || cp -a "$rules" "$backup/home-security.rules"
rollback() {
  rc=$?
  if (( rc != 0 )); then
    cp -a "$backup/suricata.yaml" "$config"
    if [[ -e "$backup/home-security.yaml" ]]; then cp -a "$backup/home-security.yaml" "$fragment"; else rm -f "$fragment"; fi
    if [[ -e "$backup/home-security.rules" ]]; then cp -a "$backup/home-security.rules" "$rules"; else rm -f "$rules"; fi
    echo "Restored previous files; backup: $backup" >&2
  fi
  exit "$rc"
}
trap rollback EXIT
install -o root -g root -m 0644 "$repo_root/suricata/home-security.yaml" "$fragment"
install -o root -g root -m 0644 "$repo_root/suricata/home-security.rules" "$rules"
python3 - "$config" "$fragment" "$rules" <<'PY'
import re, sys
from pathlib import Path
cfg, fragment, rulefile = map(Path, sys.argv[1:])
lines = cfg.read_text().splitlines(keepends=True)
overrides = {}
for key in ("HOME_NET", "EXTERNAL_NET"):
    m = re.search(r"^" + key + r":\s*(.*?)\s*$", fragment.read_text(), re.M)
    if not m: raise SystemExit(f"Missing {key} in overlay")
    overrides[key] = m.group(1)
def indent(s): return len(s) - len(s.lstrip())
vars_i = next((i for i,x in enumerate(lines) if re.match(r"^vars:\s*(?:#.*)?$", x.rstrip())), None)
if vars_i is None: raise SystemExit("Could not find top-level vars mapping")
addr_i = next((i for i in range(vars_i+1,len(lines)) if re.match(r"^\s{2}address-groups:\s*(?:#.*)?$", lines[i].rstrip())), None)
if addr_i is None: raise SystemExit("Could not find vars.address-groups")
end = next((i for i in range(addr_i+1,len(lines)) if lines[i].strip() and not lines[i].lstrip().startswith("#") and indent(lines[i]) <= indent(lines[addr_i])), len(lines))
block = lines[addr_i+1:end]
for key,val in overrides.items():
    pat = re.compile(r"^(\s*)" + key + r"\s*:")
    found = [i for i,x in enumerate(block) if pat.match(x)]
    if found:
        m = pat.match(block[found[0]])
        block[found[0]] = f"{m.group(1)}{key}: {val}\n"
        for i in reversed(found[1:]): del block[i]
    else: block.append(f"    {key}: {val}\n")
lines[addr_i+1:end] = block
text = "".join(lines)
if str(rulefile) not in text:
    lines = text.splitlines(keepends=True)
    ri = next((i for i,x in enumerate(lines) if re.match(r"^\s*rule-files:\s*(?:#.*)?$", x.rstrip())), None)
    if ri is None: raise SystemExit("Could not find rule-files list")
    base = indent(lines[ri]); item_indent = base + 2
    for x in lines[ri+1:]:
        if x.strip() and not x.lstrip().startswith("#"):
            if indent(x) <= base: break
            m = re.match(r"^(\s*)-\s+", x)
            if m: item_indent = len(m.group(1)); break
    lines.insert(ri+1, " " * item_indent + "- " + str(rulefile) + "\n")
    text = "".join(lines)
cfg.write_text(text)
PY
suricata -T -c "$config"
systemctl enable --now suricata
systemctl is-active --quiet suricata
trap - EXIT
echo "Suricata installed and active. Backup: $backup"
