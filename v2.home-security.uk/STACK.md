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
- Suricata is installed and managed natively on the Fedora host as `suricata.service`, not by this Compose project. The CI workflow does not install or check it; follow [Install native Suricata on Fedora Secureblue](#install-native-suricata-on-fedora-secureblue) on the host.
- Fluent Bit and the AI worker bind-mount `${SURICATA_LOG_DIR:-/var/log/suricata}` read-only. Verify that containers can read `eve.json` while SELinux remains enforcing. Do not blindly relabel the host log directory with `:Z`/`:z`, because that can interfere with host-service SELinux access. If access is denied, inspect `ausearch -m AVC -ts recent` and apply a narrow, tested SELinux solution rather than disabling SELinux globally.
- OpenObserve is bound to localhost by default. Access it through a local browser at `http://127.0.0.1:5080`. Do not expose it directly to the Internet.
- Ollama's API is not published on the host. Only containers on the private Compose network can access it.
- Set a unique OpenObserve password in the host env file `/etc/v2.home-security.uk/minimal-ai-security-lab.env` before first start. OpenObserve initializes root credentials on first start; changing environment variables later may not change an existing account password.
- The worker only processes new records after its saved file offsets. Initial historical logs are not backfilled into AI analysis.
- The worker stores offsets in `security_ai_state`. Fluent Bit stores independent tail offsets in `fluent_bit_state`.
- Wazuh Manager is run without its official indexer/dashboard in this simplified stack. This design uses OpenObserve for the separate log dashboard; it does not provide the full native Wazuh dashboard experience or indexed Wazuh alert search inside Wazuh itself.
- The named volumes in this standalone file are distinct from similarly named volumes in an existing Compose project unless explicitly declared as external. Do not run this alongside your existing stack without reviewing port conflicts, duplicate service names, and which volumes contain your existing data.

## Install native Suricata on Fedora Secureblue

This is the setup guide for the host-side Suricata sensor. Suricata runs as the host's `suricata.service`, so these steps run on the host, not inside Toolbox and not in CI. The host has no `sudo`; run privileged commands as root with `run0`.

Run these steps from a normal user session on the host, from the repository directory:

1. Check whether Suricata is installed:

   ```bash
   rpm -q suricata
   ```

2. If it is not installed, apply it live. If live application is not supported, layer it and reboot in a maintenance window:

   ```bash
   run0 rpm-ostree install --apply-live suricata
   # Fallback only if live application fails:
   run0 rpm-ostree install suricata
   run0 systemctl reboot
   ```

3. Confirm the capture interface and that the repository configuration uses it. The interface is set in `suricata/home-security.yaml`; do not assume the default service captures the intended interface.

   ```bash
   ip -brief link
   ```

4. Install, validate, enable, start, and verify the sensor with the host script. It runs `suricata -T`, installs the repository configuration, enables and starts `suricata.service`, and checks that `eve.json` contains valid JSON:

   ```bash
   run0 bash scripts/host-suricata-deploy.sh install
   ```

5. Check the sensor at any time:

   ```bash
   run0 bash scripts/host-suricata-deploy.sh verify
   ```

The script is [scripts/host-suricata-deploy.sh](scripts/host-suricata-deploy.sh). It never reboots the host. If it fails, it prints the recent `suricata.service` journal. Inspect the packaged unit and version with:

```bash
rpm -ql suricata | grep -E 'systemd|suricata.yaml|rules'
systemctl cat suricata
run0 suricata --build-info
```

Verify that `/var/log/suricata/eve.json` is updating before relying on the sensor.

## Install the Compose stack

The host-managed environment file is `/etc/v2.home-security.uk/minimal-ai-security-lab.env`. It holds secrets, so it should be owned by your user with mode `600`. Do not copy it into the repository. Set a long, unique `OPENOBSERVE_PASSWORD` in that file before first start, then copy it into the project directory for a manual run:

```bash
install -m 600 /etc/v2.home-security.uk/minimal-ai-security-lab.env .env
```

The CI workflow does the same copy automatically and deletes `.env` when the job ends.

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
run0 bash scripts/host-suricata-deploy.sh verify
run0 tail -n 5 /var/log/suricata/eve.json
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
   run0 bash scripts/host-suricata-deploy.sh verify
   run0 tail -n 5 /var/log/suricata/eve.json
   ```
4. Confirm Fluent Bit can read the host log file from its container:
   ```bash
   podman exec fluent-bit sh -c 'test -r /var/log/suricata/eve.json && echo readable'
   ```
5. In OpenObserve, inspect `wazuh_alerts` and `suricata_events`.
6. Confirm the AI worker logs a submitted analysis and inspect `ai_recommendations`.

## Operations and maintenance

- Keep `.env` out of version control, and keep the host env file in `/etc/v2.home-security.uk/` with mode `600`.
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
