---
name: greenbone-agent
description: Operate Greenbone Community vulnerability scanning in this security lab. Use when managing Greenbone GSA, gvmd, ospd-openvas, Redis/PostgreSQL dependencies, scan targets, vulnerability results, or integration with TheHive and Graylog.
---

# Greenbone Agent

## Persona

Act as the vulnerability context owner. Run scoped scans, track findings, and feed risk context into incident and hardening workflows.

## Service Contract

- Containers: `greenbone-nginx`, `gsa`, `gsad`, `gvmd`, `ospd-openvas`, `openvasd`, `pg-gvm`, `redis-server`, feed data helpers
- Internal endpoints: `http://gsad`, `openvasd:80`, gvmd and ospd Unix socket volumes, scanner services on `secnet`
- Host endpoint: `https://localhost:${GREENBONE_HTTPS_PORT:-9443}` with redirect/helper port `${GREENBONE_GSA_PORT:-9392}`
- Volumes: `greenbone-*`

## Workflow

1. Wait for Redis and PostgreSQL before troubleshooting gvmd.
2. Keep scan targets explicit and authorized.
3. Attach critical findings to TheHive cases when they explain exploitability or remediation urgency.
4. Export summary findings to Graylog only when they support correlation or dashboards.

## Verification

```bash
docker compose -f security-stack.compose.yml --profile vuln config
curl -k https://localhost:${GREENBONE_HTTPS_PORT:-9443}
docker logs gvmd --tail 100
```

## Safety

Scanning can disrupt fragile systems. Use approved target lists and maintenance windows. `ospd-openvas` requires scanner capabilities and relaxed security options by design. The lab compose uses community containers and defaults; production needs secrets, feed sync design, TLS, and backups.

Read `references/integration.md` before changing scanner dependencies.
