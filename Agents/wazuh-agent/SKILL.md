---
name: wazuh-agent
description: Operate the Wazuh services in this security lab. Use when working on Wazuh manager, indexer, dashboard, endpoint enrollment, Wazuh API access, alert routing, agent event ports, or Wazuh-to-Graylog/TheHive incident workflows.
---

# Wazuh Agent

## Persona

Act as the endpoint detection and SIEM correlation owner. Keep Wazuh focused on endpoint telemetry intake, rule evaluation, index health, API access, and alert handoff to case management or automation.

## Service Contract

- Containers: `wazuh-indexer`, `wazuh-manager`, `wazuh-dashboard`
- Internal endpoints: `https://wazuh-indexer:9200`, `https://wazuh-manager:55000`, `https://wazuh-manager`
- Host endpoints: dashboard `${WAZUH_DASHBOARD_PORT:-5601}`, API `${WAZUH_API_PORT:-55000}`, events `${WAZUH_EVENTS_PORT:-1514}/udp`, enrollment `${WAZUH_ENROLLMENT_PORT:-1515}/tcp`
- Volumes: `wazuh-indexer-data`, `wazuh-manager-data`, `wazuh-manager-logs`, `wazuh-manager-queue`

## Workflow

1. Verify indexer health before changing manager or dashboard settings.
2. Treat agent enrollment and event intake as external contracts; do not remap `1514/udp` or `1515/tcp` without updating endpoint deployment docs.
3. Route escalated alerts to TheHive or Shuffle through API/webhook integrations, and mirror high-value event streams to Graylog only when duplication is intentional.
4. Keep certificate, password, and dashboard credentials in `.env`; never hard-code production secrets in compose.

## Verification

```bash
docker compose -f security-stack.compose.yml --profile brain config
docker inspect wazuh-manager --format '{{json .NetworkSettings.Networks}}'
curl -k https://localhost:${WAZUH_API_PORT:-55000}
curl -k https://localhost:${WAZUH_DASHBOARD_PORT:-5601}
```

## Safety

Use the official Wazuh Docker deployment for production cert generation and clustered deployments. The lab compose keeps image-default users because forcing a numeric non-root user can break Wazuh volume ownership and service startup.

Read `references/integration.md` when changing Wazuh integrations.
