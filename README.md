
[![Prewarm Docker Image Artifacts](https://github.com/kbongcawel-viatrm/hq-sec-stack/actions/workflows/image-sync.yml/badge.svg?branch=dev&event=deployment_status)](https://github.com/kbongcawel-viatrm/hq-sec-stack/actions/workflows/image-sync.yml)<br>
<img align=center width="750" height="210" alt="glowing_aura_banner_1900x700_10mb" src="https://github.com/user-attachments/assets/5b8ceadd-6fc3-48f7-a1db-8b7c8b131332" />

> *"The soul behind the body parts. Pulling the strings. Making everyone better."*

# HQ Security Stack

A comprehensive home security stack aimed at implementing file integrity monitoring, alerting, intrusion prevention/detection systems, log assessment and forensics, log aggregation visualization, and response mitigation.

## Quick Start

```bash
cp .env.example .env
sh scripts/start-stack.sh
```

To gracefully stop everything:
```bash
sh scripts/killswitch.sh
```

The scripts use Docker Compose when Docker is installed, and fall back to Podman when Docker is unavailable. For Podman, install `podman` and a Compose provider supported by `podman compose` (such as `podman-compose`). Select it explicitly with `CONTAINER_ENGINE=podman sh scripts/start-stack.sh`; the same setting works with `scripts/killswitch.sh`. Commands below use Docker syntax; replace `docker` with `podman` when operating a Podman stack.

Some services that control other containers (including Portainer, Shuffle, and the container health exporter) connect to `/var/run/docker.sock`. They need a Docker-compatible API socket and may not work with a default Podman setup. Podman also differs in host networking, device/capability handling, and rootless port binding; review those services and host requirements before enabling their profiles.

## Available Profiles

You can run specific components by passing profiles to the startup script:
```bash
SECSTACK_PROFILES="dns secrets brain" sh scripts/start-stack.sh
```

- `all`: Full lab stack
- `ghost`: The Ghost — LLM reasoning engine governing all pillars (Local/Cloud)
- `brain`: SIEM and log analysis (Wazuh, Graylog)
- `network`: Network detection (Suricata, Zeek, Nmap, Wireshark)
- `ir`: Incident response (TheHive, Shuffle, Velociraptor)
- `vuln`: Vulnerability and hardening (Greenbone, osquery)
- `dns`: Local FQDN routing (CoreDNS, Caddy)
- `secrets`: Secrets storage and rotation (Vault)
- `ops`: Backups and container vulnerability scanning
- `llm`: Alias for `ghost` — starts the Ghost engine and assessor only

For GitHub Actions deployment settings and required repository secrets/variables, see [docs/github-actions.md](docs/github-actions.md).

## Key Endpoints

| Service | Host Endpoint |
| --- | --- |
| **The Ghost** (LLM engine) | `The Ghost/Core/scripts/analyze_stack.py` |
| Wazuh rules and FIM | `The Brain/Wazuh/rules/local_rules.xml`, `The Brain/Wazuh/agent/ossec.conf` |
| PowerShell logging | `The Sword/Windows/powershell/Install-PowerShellLoggingTask.ps1`, `The Sword/Windows/powershell/Collect-PowerShellActivity.ps1` |
| Sysmon | `The Sword/Windows/sysmon/sysmon-hq-sec.xml` |
| Suricata IDS | `The Sword/Suricata/suricata.yaml`, `The Sword/Suricata/rules/local.rules` |
| Suricata community definitions | `The Sword/Suricata/update/*`, `docs/suricata-rulesets.md` |
| Graylog filters | `The Eyes/Graylog/queries/security-filters.md` |
| TheHive flow | `The Eyes/thehive/alert-flow.md` |
| Velociraptor hunts | `The Shield/velociraptor/hunt-plan.md` |
| Ansible response | `The Sword/Ansible/playbooks/windows-contain-malicious.yml`, `The Sword/Ansible/playbooks/windows-isolate.yml`, `The Sword/Ansible/playbooks/windows-applocker-containment.yml`, `The Sword/Ansible/playbooks/windows-collect-artifacts.yml` |

See [docs/windows-endpoint-detection.md](docs/windows-endpoint-detection.md) for the full telemetry and response flow.

## Backup And Recovery

All stateful services use named Docker volumes. That data persists across normal container restarts, reboots, and `docker compose up/down` as long as volumes are not removed.

The `volume-backup` service creates compressed archives for persistent named volumes:

```bash
docker compose -f security-stack.compose.yml --profile backup up -d
docker logs volume-backup --tail 100
ls "The Hands/backups/"
```

Defaults:

- Runs once on startup: `BACKUP_RUN_ON_STARTUP=true`
- Runs every 24 hours: `BACKUP_INTERVAL_SECONDS=86400`
- Prunes backups older than 30 days: `BACKUP_RETENTION_DAYS=30`
- Writes archives and `SHA256SUMS` under `./The Hands/backups/<timestamp>/`

Transient socket volumes are intentionally excluded because they are runtime IPC, not recoverable data.

For the most consistent database backups, stop the affected profile before a manual snapshot:

```bash
docker compose -f security-stack.compose.yml --profile brain stop
docker compose -f security-stack.compose.yml --profile backup run --rm -e BACKUP_ONCE=true volume-backup
docker compose -f security-stack.compose.yml --profile brain start
```

Restore pattern:

```bash
docker run --rm \
  -v hq-sec-stack_graylog-data:/restore \
  -v "./The Hands/backups:/backups:ro" \
  -v "./The Hands/backup/scripts:/backup/scripts:ro" \
  alpine:3.20 \
  sh /backup/scripts/restore-volume.sh graylog-data /backups/<timestamp>/graylog-data.tar.gz
```

## Container Vulnerability Scanning

`container-vuln-scanner` uses Trivy to scan the image targets listed in `The Shield/scanner/targets.txt` and writes reports under `./The Hands/reports/data/container-vulnerabilities`.

```bash
docker compose -f security-stack.compose.yml --profile scanner up -d
docker logs container-vuln-scanner --tail 100
ls "The Hands/reports/data/container-vulnerabilities/latest"
```

Defaults:

- Scanner image: `aquasec/trivy:0.70.0`
- Runs once on startup: `TRIVY_RUN_ON_STARTUP=true`
- Runs every 24 hours: `TRIVY_SCAN_INTERVAL_SECONDS=86400`
- Flags `HIGH,CRITICAL` findings by default
- Produces JSON and table reports plus a Markdown summary

Keep `The Shield/scanner/targets.txt` aligned with image changes in `security-stack.compose.yml`. Trivy `v0.70.0` is pinned because Aqua Security disclosed a 2026 supply-chain incident affecting parts of the `0.69.x` ecosystem. Avoid floating the scanner image without reviewing current advisories.

## Uptime Monitoring

The stack uses [Uptime Kuma](https://hub.docker.com/r/louislam/uptime-kuma) as the open-source uptime dashboard. It is available at:

```text
http://uptime.hq-sec.local
http://localhost:3002
```

Create monitors for the FQDNs and internal endpoints listed in the services table. Use HTTP monitors for dashboards/APIs and TCP/UDP checks where applicable.

The desired monitor inventory is tracked in `The Eyes/Uptime-Kuma/monitors.yml` and reconciled by `uptime-kuma-sync` when `UPTIME_KUMA_PASSWORD` is set in `.env`. See [docs/uptime-dashboard.md](docs/uptime-dashboard.md).

Repository rule: every new service, container, FQDN, host port, or internal endpoint must be added to `The Eyes/Uptime-Kuma/monitors.yml` in the same change.

## Service Categories

Services are documented by category in [docs/service-categories.md](docs/service-categories.md):

## Security & Privacy Features

- **Private Binding**: All services are bound to `127.0.0.1` by default to prevent external network exposure.
- **DNS over TLS**: Internal DNS resolution via CoreDNS uses encrypted DoT to Quad9 (`dns.quad9.net`) to prevent ISP tracking.
- **Active IPS**: CrowdSec monitors Wazuh, Suricata, and Caddy logs, and actively blocks malicious IPs using the Caddy bouncer plugin.

## Important Safety Notes

This is a lab stack. Replace all default passwords and secrets in your `.env` before using it beyond a private test environment. 

Some containers require privileged access:
- Suricata, Zeek, and Wireshark require host networking and packet-capture capabilities.
- Portainer and Shuffle mount `/var/run/docker.sock` to manage the environment.
- Greenbone scanner requires network scanning capabilities.

**Do not run vulnerability scans, containment playbooks, or endpoint collection against systems without authorization.**
