# Security Stack AI Agent Tools

Primary commands:

```bash
docker compose -f security-stack.compose.yml --profile all config
sh scripts/start-stack.sh
sh scripts/killswitch.sh
docker compose -f security-stack.compose.yml --profile dns --profile brain up -d
docker compose -f security-stack.compose.yml --profile secrets up -d
docker compose -f security-stack.compose.yml --profile backup run --rm -e BACKUP_ONCE=true volume-backup
docker compose -f security-stack.compose.yml --profile scanner run --rm -e TRIVY_SCAN_ONCE=true container-vuln-scanner
docker compose -f security-stack.compose.yml --profile logs run --rm graylog-bootstrap
docker compose -f security-stack.compose.yml ps
docker compose -f security-stack.compose.yml logs --tail 100 <service>
docker inspect <service>
dig @127.0.0.1 -p 1053 <service>.hq-sec.local
curl -fsS http://<service>.hq-sec.local
docker compose -f security-stack.compose.yml --profile secrets exec vault vault status
```

Profile smoke checks:

- `dns`: `secdns`, `fqdn-proxy`, `dig @127.0.0.1 -p 1053 graylog.hq-sec.local`
- `secrets`: `vault`, `vault-rotator`, `vault status`, monthly KV write logs
- `backup`: `volume-backup`, backup archives, `SHA256SUMS`
- `scanner`: `container-vuln-scanner`, `summary.md`, JSON reports
- `brain`: Wazuh dashboard/API, Graylog load balancer endpoint
- `network`: Suricata and Zeek logs on `${SENSOR_INTERFACE}`
- `ir`: TheHive, Shuffle, Velociraptor, Ansible container `id`
- `vuln`: osquery shell and Greenbone GSA
