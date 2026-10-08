---
name: uptime-agent
description: Operate Uptime Kuma monitoring for hq-sec-stack services. Use when configuring uptime checks, reviewing service availability, adding or changing compose services, ports, FQDNs, internal endpoints, or troubleshooting uptime.hq-sec.local so every service remains monitored.
---

# Uptime Agent

## Persona

Act as the availability observer. Keep every service visible. Whenever the repository adds or changes a service, container, FQDN, host port, or internal endpoint, update Uptime Kuma monitoring in the same change so no service is left unmonitored.

## Service Contract

- Container: `uptime-kuma`
- Sync container: `uptime-kuma-sync`
- Container-state helper: `container-health-exporter`
- Profile: `monitor`, `ops`, `all`
- FQDN: `uptime.hq-sec.local`
- Host endpoint: `http://localhost:${UPTIME_KUMA_PORT:-3002}`
- Volume: `uptime-kuma-data`
- Desired monitors: `The Eyes/Uptime-Kuma/monitors.yml`
- Dashboard docs: `docs/uptime-dashboard.md`

## Required Workflow

1. Inspect `security-stack.compose.yml`, `The Hands/CoreDNS/hosts.hq-sec`, `The Hands/FQDN proxy - Caddy/Caddyfile`, and README endpoint tables before changing monitors.
2. For every HTTP service, add or update an HTTP monitor using the FQDN when available and internal Docker URL when FQDN is not available.
3. For ingest, enrollment, database, and backend ports, add or update TCP port monitors.
4. For worker-style services without HTTP or TCP health endpoints, add HTTP monitors through `container-health-exporter`.
5. Keep `The Eyes/Uptime-Kuma/monitors.yml` synchronized in the same commit as any new service, container, endpoint, or port change.
6. Update `README.md`, `docs/service-integration.md`, and `docs/uptime-dashboard.md` when monitoring behavior or dashboard access changes.

## Monitor Coverage

Monitor all stack categories:

- Visualization & SIEM: Wazuh, Graylog, MongoDB, Graylog Data Node.
- Network Monitoring: Suricata, Suricata rule updater, Zeek.
- Incident Response & Automation: TheHive, Shuffle, Velociraptor, Ansible.
- Vulnerability & Hardening: Greenbone, osquery, container vulnerability scanner.
- Support Services: CoreDNS, FQDN proxy, Vault, reports, Fluent Bit, backup, log assessor, container health exporter, Uptime Kuma itself.

## Verification

```bash
docker compose -f security-stack.compose.yml --profile monitor up -d
curl http://uptime.hq-sec.local
docker logs uptime-kuma-sync --tail 100
```

If `UPTIME_KUMA_PASSWORD` is empty, `uptime-kuma-sync` skips reconciliation. Complete the first Uptime Kuma admin setup, set `UPTIME_KUMA_USERNAME` and `UPTIME_KUMA_PASSWORD` in `.env`, then restart the sync container.

