# Minimal AI Security Lab

A small Podman/Compose stack built around Wazuh Manager, native host Suricata, Fluent Bit, OpenObserve, and Ollama. A small Python worker sends selected new alerts to Ollama and stores recommendations in OpenObserve.

## Services

| Service | Purpose | Published port |
|---|---|---|
| `wazuh-manager` | Agent enrollment, endpoint event analysis, Wazuh alerts | `1514/tcp`, `1515/tcp`; API `55000/tcp` bound to localhost |
| Native `suricata.service` | Host-interface IDS sensor; emits EVE JSON | Managed by host systemd |
| `fluent-bit` | Tails Wazuh and Suricata JSON logs and forwards events | None |
| `openobserve` | Search, dashboards and log storage | `127.0.0.1:5080` |
| `ollama` | Local LLM inference | Internal network only |
| `security-ai` | Periodically analyzes new alerts and stores recommendations | None |

OpenObserve streams created by ingestion:
- `wazuh_alerts`
- `suricata_events`
- `ai_recommendations`

## Event pipeline

1. Wazuh agents send endpoint telemetry to Wazuh Manager on TCP 1514. Agent enrollment uses TCP 1515.
2. Wazuh Manager decodes events, evaluates rules, and writes alerts to `/var/ossec/logs/alerts/alerts.json`.
3. Suricata independently captures traffic on the configured host interface and writes `/var/log/suricata/eve.json`.
4. Fluent Bit tails both JSON files, tracks file offsets in its state volume, and forwards Wazuh alerts and Suricata events to separate OpenObserve streams.
5. `security-ai` reads new Wazuh alerts and Suricata `event_type=alert` records, batches a limited number of events, and submits them to Ollama.
6. The worker writes the model's structured findings and proposed rule/configuration changes to the `ai_recommendations` stream.
7. A human reviews proposed changes, tests them in a controlled environment, commits approved changes to version control, deploys them, and verifies the resulting events.

The AI worker is advisory only. It does not modify active Wazuh or Suricata configuration, reload rules, or run response actions.

## Prerequisites and important limitations

- Run from a directory containing `compose.yaml`, `.env`, `fluent-bit/fluent-bit.conf`, and `security-ai/`.
- The existing Wazuh agent version should be compatible with the manager version. The sample pins the manager to `4.14.8`; change `WAZUH_VERSION` to match your tested deployment if needed.
- Suricata is installed and managed natively on the Fedora host, not by this Compose project.
- Fluent Bit and the AI worker bind-mount `${SURICATA_LOG_DIR:-/var/log/suricata}` read-only. Verify that containers can read `eve.json` while SELinux remains enforcing. Do not blindly relabel the host log directory with `:Z`/`:z`, because that can interfere with host-service SELinux access. If access is denied, inspect `ausearch -m AVC -ts recent` and apply a narrow, tested SELinux solution rather than disabling SELinux globally.
- OpenObserve is bound to localhost by default. Access it through a local browser at `http://127.0.0.1:5080`. Do not expose it directly to the Internet.
- Ollama's API is not published on the host. Only containers on the private Compose network can access it.
- Replace the sample OpenObserve password in `.env` before first start. OpenObserve initializes root credentials on first start; changing environment variables later may not change an existing account password.
- The worker only processes new records after its saved file offsets. Initial historical logs are not backfilled into AI analysis.
- The worker stores offsets in `security_ai_state`. Fluent Bit stores independent tail offsets in `fluent_bit_state`.
- Wazuh Manager is run without its official indexer/dashboard in this simplified stack. This design uses OpenObserve for the separate log dashboard; it does not provide the full native Wazuh dashboard experience or indexed Wazuh alert search inside Wazuh itself.
- The named volumes in this standalone file are distinct from similarly named volumes in an existing Compose project unless explicitly declared as external. Do not run this alongside your existing stack without reviewing port conflicts, duplicate service names, and which volumes contain your existing data.

## Install native Suricata on Fedora Secureblue

Check whether Suricata is already installed:

```bash
rpm -q suricata
```

If it is not installed and the package is available in your configured repositories, layer it and reboot:

```bash
sudo rpm-ostree install suricata
systemctl reboot
```

After reboot, inspect the packaged unit and configuration:

```bash
rpm -ql suricata | grep -E 'systemd|suricata.yaml|rules'
systemctl cat suricata
sudo suricata --build-info
ip -brief link
```

Configure the service for the actual interface on your host (verify whether `enp1s0` exists). Validate before enabling:

```bash
sudo suricata -T -c /etc/suricata/suricata.yaml
sudo systemctl enable --now suricata
sudo systemctl status suricata
sudo journalctl -u suricata -b --no-pager
```

The exact interface setting depends on the packaged unit and configuration. Do not assume the default service captures the intended interface. Verify that `/var/log/suricata/eve.json` is updating before relying on the sensor.

## Install the Compose stack

```bash
cp .env.example .env
# Edit .env and set a long, unique OPENOBSERVE_PASSWORD.
```

Review the Compose file and confirm the host interface name:

```bash
ip -brief link
```

Validate the rendered Compose configuration:

```bash
podman-compose -f compose.yaml config
```

Start the services:

```bash
podman-compose -f compose.yaml up -d --build
```

If your installed `podman-compose` version does not support `config`, use the available Compose validation command and inspect the rendered configuration before deployment. Do not use `sudo` blindly: rootful Podman has a separate container/volume store from rootless Podman.

Pull the selected Ollama model once:

```bash
podman exec ollama ollama pull qwen2.5:3b
```

Check status and logs:

```bash
podman ps
podman logs --tail 100 wazuh-manager
podman logs --tail 100 fluent-bit
podman logs --tail 100 openobserve
podman logs --tail 100 security-ai
systemctl status suricata
sudo tail -n 5 /var/log/suricata/eve.json
```

Open `http://127.0.0.1:5080` and sign in with the credentials in `.env`.

## Verify ingestion

1. Enroll a Wazuh agent and generate a safe test event on that endpoint.
2. Confirm the event appears in the manager's alert file:
   ```bash
   podman exec wazuh-manager sh -c 'tail -n 5 /var/ossec/logs/alerts/alerts.json'
   ```
3. Confirm native Suricata is active and emitting EVE JSON:
   ```bash
   systemctl status suricata
   sudo tail -n 5 /var/log/suricata/eve.json
   ```
4. Confirm Fluent Bit can read the host log file from its container:
   ```bash
   podman exec fluent-bit sh -c 'test -r /var/log/suricata/eve.json && echo readable'
   ```
5. In OpenObserve, inspect `wazuh_alerts` and `suricata_events`.
6. Confirm the AI worker logs a submitted analysis and inspect `ai_recommendations`.

## Operations and maintenance

- Keep `.env` out of version control.
- Pin image tags or digests after testing; avoid unattended production upgrades from `latest`.
- Back up named volumes and test restores.
- Monitor disk usage; log and model volumes can grow substantially.
- Test proposed detection-rule changes before deployment. Keep a known-good revision and rollback procedure.
- Consider binding Wazuh agent ports to the LAN address rather than all host addresses, and enforce corresponding `firewalld` restrictions.

## Stop

```bash
podman-compose -f compose.yaml down
```

This leaves named volumes intact. To delete all stack data, `down -v` removes the named volumes; only do this when you intentionally want to destroy stored logs, OpenObserve data, Ollama models, and worker state.
