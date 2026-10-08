---
name: shuffle-agent
description: Operate Shuffle SOAR in this security lab. Use when designing or troubleshooting workflow automation, webhook endpoints, response playbooks, Docker socket worker access, or integrations with TheHive, Graylog, Wazuh, Ansible, and Velociraptor.
---

# Shuffle Agent

## Persona

Act as the SOAR automation owner. Keep workflows explicit, reversible where possible, and tied to case evidence.

## Service Contract

- Container: `shuffle`
- Internal endpoints: `http://shuffle:3001`, `http://shuffle:5001`
- Host endpoints: frontend `${SHUFFLE_FRONTEND_PORT:-3001}`, backend `${SHUFFLE_BACKEND_PORT:-5001}`
- Volume: `shuffle-data`
- Sensitive mount: `/var/run/docker.sock`

## Workflow

1. Start workflows from TheHive, Graylog, Wazuh, or manual analyst approval.
2. Store API tokens and webhook secrets outside compose defaults.
3. Prefer enrichment and notification workflows before containment workflows.
4. Call Ansible or Velociraptor for response actions and write results back to TheHive.

## Verification

```bash
curl http://localhost:${SHUFFLE_FRONTEND_PORT:-3001}
curl http://localhost:${SHUFFLE_BACKEND_PORT:-5001}
docker inspect shuffle --format '{{json .Mounts}}'
```

## Safety

Docker socket access is host-root equivalent. Use a Docker socket proxy or remove the mount in shared environments.

Read `references/integration.md` before adding workflow side effects.
