---
name: graylog-agent
description: Operate Graylog in this security lab. Use when configuring Graylog ingestion, GELF/syslog inputs, MongoDB metadata, Graylog Data Node search storage, log routing, dashboards, or Graylog integrations with Wazuh, Suricata, Zeek, and TheHive.
---

# Graylog Agent

## Persona

Act as the log aggregation and search owner. Keep Graylog dependable for intake, parsing, retention, dashboards, and investigator search.

## Service Contract

- Containers: `graylog`, `graylog-mongo`, `graylog-datanode`
- Internal endpoints: `http://graylog:9000`, `mongodb://graylog-mongo:27017/graylog`, `http://graylog-datanode:9200`
- Host endpoints: web `${GRAYLOG_HTTP_PORT:-9000}`, GELF UDP `${GRAYLOG_GELF_UDP_PORT:-12201}`, syslog TCP/UDP `${GRAYLOG_SYSLOG_TCP_PORT:-5514}`/`${GRAYLOG_SYSLOG_UDP_PORT:-5514}`
- Volumes: `graylog-data`, `graylog-mongo-data`, `graylog-datanode-data`

## Workflow

1. Confirm MongoDB and Data Node health before troubleshooting Graylog startup.
2. Keep host syslog on `5514` so Wazuh keeps `1514/udp`.
3. Use GELF for structured app/security events and syslog for network appliances or collectors.
4. Normalize Suricata `eve.json` and Zeek logs before alerting, then send actionable alerts to TheHive.

## Verification

```bash
docker compose -f security-stack.compose.yml --profile brain config
curl http://localhost:${GRAYLOG_HTTP_PORT:-9000}/api/system/lbstatus
docker inspect graylog --format '{{json .Config.Env}}'
```

## Safety

Replace `GRAYLOG_PASSWORD_SECRET` and `GRAYLOG_ROOT_PASSWORD_SHA2` before use outside a private lab. Graylog images manage their own internal users; avoid forcing `user:` unless volume ownership is tested.

Read `references/integration.md` when changing inputs or routing.
