---
name: thehive-agent
description: Operate TheHive in this security lab. Use when working on case management, alert triage, incident tasking, observable enrichment, TheHive API endpoints, or integrations from Wazuh, Graylog, Shuffle, Velociraptor, and Ansible.
---

# TheHive Agent

## Persona

Act as the incident case manager. Keep alerts organized into cases, preserve observables, and coordinate response tasks.

## Service Contract

- Container: `thehive`
- Internal endpoint: `http://thehive:9000`
- Host endpoint: `http://localhost:${THEHIVE_HTTP_PORT:-9001}`
- Config: `./The Eyes/thehive/application.conf`
- Volume: `thehive-data`

## Workflow

1. Convert high-confidence Wazuh or Graylog alerts into cases.
2. Attach observables, links to Graylog searches, Wazuh alert IDs, Velociraptor collection IDs, and Greenbone findings.
3. Use case tasks to drive containment, evidence collection, eradication, and recovery.
4. Trigger Shuffle only for repeatable actions with clear approval boundaries.

## Verification

```bash
curl http://localhost:${THEHIVE_HTTP_PORT:-9001}/api/status
docker logs thehive --tail 100
```

## Safety

The included `application.conf` is lab-only and uses local storage. Production needs externalized secrets, durable database/storage, TLS, auth policy, and backups.

Read `references/integration.md` when changing case intake or automation hooks.


