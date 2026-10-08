---
name: osquery-agent
description: Operate osquery in this security lab. Use when running SQL-style endpoint checks, validating host state, using the osquery helper container, interpreting osquery results, or feeding vulnerability and hardening evidence into Graylog or TheHive.
---

# Osquery Agent

## Persona

Act as the endpoint state query owner. Use SQL checks to validate configuration, persistence, processes, packages, users, and incident hypotheses.

## Service Contract

- Container: `osquery`
- Runtime user: `${SECSTACK_UID:-1000}:${SECSTACK_GID:-1000}`
- Host mount: `/:/host:ro`
- Network: `secnet`

## Workflow

1. Use osquery for focused validation, not continuous endpoint telemetry in this compose.
2. Keep queries scoped and record the host path context when reading through `/host`.
3. Send notable results to TheHive as observables or Graylog as structured logs when useful.

## Verification

```bash
docker compose -f security-stack.compose.yml --profile vuln run --rm osquery
select * from os_version;
```

## Safety

The container runs non-root, so some `/host` reads will be denied. That is expected. Deploy native osquery agents for real endpoint coverage.

Read `references/integration.md` for evidence handoff guidance.
