# Uptime Kuma Dashboard

Uptime Kuma is the active uptime dashboard for `hq-sec-stack`.

## Access

| Endpoint | Purpose |
| --- | --- |
| `http://uptime.hq-sec.local` | Local FQDN dashboard through Caddy |
| `http://localhost:3002` | Direct host port |
| `http://uptime-kuma:3001` | Internal Docker endpoint |

## Monitor Inventory

The desired monitor list is stored in `The Eyes/Uptime-Kuma/monitors.yml`. It includes:

- FQDN checks for analyst-facing services.
- Internal HTTP checks for service APIs.
- TCP port checks for ingest and backend dependencies.
- HTTP checks against `container-health-exporter` for worker-style services that do not expose their own endpoint.

When a service, container, host port, FQDN, or internal endpoint changes, update `The Eyes/Uptime-Kuma/monitors.yml` in the same change.

## Bootstrap

Start the monitor profile:

```bash
docker compose -f security-stack.compose.yml --profile monitor up -d
```

Open Uptime Kuma and create the initial admin account. Then set credentials in `.env`:

```text
UPTIME_KUMA_USERNAME=admin
UPTIME_KUMA_PASSWORD=<your-admin-password>
```

Reconcile configured monitors:

```bash
docker compose -f security-stack.compose.yml --profile monitor up -d uptime-kuma-sync
docker logs uptime-kuma-sync --tail 100
```

`uptime-kuma-sync` exits successfully without changes while `UPTIME_KUMA_PASSWORD` is empty, so the stack can bootstrap before the first admin setup.

## Dashboard Layout

Create status pages or groups matching the service categories:

1. Visualization & SIEM
2. Network Monitoring
3. Incident Response & Automation
4. Vulnerability & Hardening
5. Endpoint Protection
6. Support Services

Use the service category field in `The Eyes/Uptime-Kuma/monitors.yml` as the grouping source of truth.

## Container Health

`container-health-exporter` exposes Docker container state to Uptime Kuma as HTTP endpoints:

```text
http://container-health-exporter:8080/container/<container-name>
```

For one-shot initialization jobs that should finish successfully instead of stay running, use:

```text
http://container-health-exporter:8080/container/<container-name>?mode=completed
```

The exporter reads the Docker-compatible socket at `/var/run/docker.sock` inside its container. With Podman, `scripts/start-stack.sh` mounts the rootless Podman socket there. Treat access as privileged host access and keep the exporter internal to `secnet`.

## Validation

```bash
docker compose -f security-stack.compose.yml --profile monitor ps
curl -fsS http://uptime.hq-sec.local
docker logs uptime-kuma-sync --tail 100
```

