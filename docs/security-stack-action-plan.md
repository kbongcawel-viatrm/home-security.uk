# Security Stack Action Plan

## Objective

Deliver a small, reliable, interconnected MVP in this order:

1. **Simplify the current state** by removing or deferring unnecessary components.
2. **Fix incorrect or missing parts** so the reduced stack communicates reliably.
3. **Deliver and verify the MVP** with one reproducible security-monitoring workflow.

**Completion rule:** a task is not complete because a container starts. It is complete only when the stated service-to-service behavior is tested and evidence is recorded.

## Execution standard

Every task must have:

- One owner.
- A named repository change or validation result.
- A validation command or test procedure.
- Evidence saved under `The Hands/reports/data/validation/` or linked from the work item.
- A pass/fail/block decision.

Use this sequence:

```text
Inspect -> change -> validate -> record evidence -> mark complete
```

### Assignment template

```text
Task ID:
Owner:
Start date:
Target date:
Files/configuration changed:
Validation command(s):
Evidence file:
Result: PASS / FAIL / BLOCKED
Follow-up:
```

## MVP boundary

The MVP is a single-host security monitoring lab with this verified path:

```text
Authorized test endpoint or synthetic event
  -> Wazuh
  -> Graylog ingestion and search
  -> analyst investigation
  -> Uptime Kuma monitoring
## [REMOVED]  -> backup and recovery
```

### MVP services

- CoreDNS
- Caddy/FQDN proxy
- Wazuh manager, indexer, and dashboard
- Graylog, Graylog Data Node, and MongoDB
- Fluent Bit
- Uptime Kuma
## [REMOVED] - Volume backup service

### Deferred services

Greenbone/OpenVAS, TheHive, Shuffle, Velociraptor, Ansible response execution, CrowdSec enforcement, Ghost assessment, Portainer, and broad host-network scanning remain opt-in until the MVP completion gate passes.

## Evidence directories

Create these before starting:

```sh
mkdir -p \
  "The Hands/reports/data/validation/compose" \
  "The Hands/reports/data/validation/integration" \
  "The Hands/reports/data/validation/recovery" \
  "The Hands/reports/data/validation/security" \
  "The Hands/reports/data/validation/releases"
```

---

# Priority 1 — Simplify the current state

**Goal:** reduce service count, privileges, resource use, attack surface, and unverified claims.

## S01 — Freeze the MVP scope

**Owner:** Project lead  
**Estimate:** 0.5 day  
**Dependencies:** None

- [x] Use the supported `mvp` profile in `simplified.compose.yml`.
- [x] Use `scripts/start.sh` as the local MVP startup entry point.
- [ ] Confirm one authorized test endpoint or synthetic event.
- [ ] Record supported host OS, engine, Compose provider, CPU, RAM, disk, and sensor interface.
- [ ] Define the minimum pass criteria in the release issue.

**Commands:**

```sh
podman-compose -f simplified.compose.yml --profile mvp config >/tmp/mvp-config.yml
```

**Evidence:** `compose/mvp-scope.md`, `compose/mvp-config.yml`.

**Done when:** the MVP service list and resource requirements are approved.

## S02 — Remove response automation from MVP

**Owner:** Response engineering  
**Estimate:** 0.5 day  
**Dependencies:** S01

- [ ] Remove Shuffle, Ansible execution, automatic isolation, and automatic blocking from `mvp`.
- [ ] Retain them only under explicit `ir` or opt-in profiles.
- [ ] Disable response workflows by default.
- [ ] Confirm no response service mounts an engine socket in the MVP.

**Commands:**

```sh
podman-compose -f simplified.compose.yml --profile mvp config >/tmp/mvp-config.yml
grep -nE 'shuffle|ansible|orborus|docker.sock|podman.sock' /tmp/mvp-config.yml
```

**Evidence:** `security/mvp-response-exclusion.txt`.

**Done when:** the command produces no unapproved response service or socket mount.

## S03 — Remove resource-heavy services from MVP

**Owner:** Platform  
**Estimate:** 0.5 day  
**Dependencies:** S01

- [ ] Exclude Greenbone/OpenVAS and feed containers.
- [ ] Exclude Ghost, model pull, and assessor containers.
- [ ] Exclude Portainer.
- [ ] Exclude Suricata/Zeek unless they are required for the selected MVP test.
- [ ] Keep each deferred capability available through an explicit opt-in profile.

**Commands:**

```sh
podman-compose -f simplified.compose.yml --profile mvp config >/tmp/mvp-config.yml
grep -nE 'greenbone|openvas|ghost|portainer|suricata|zeek' /tmp/mvp-config.yml
```

**Evidence:** `compose/mvp-services.txt`.

**Done when:** no deferred component appears in the MVP render.

## S04 — Defer CrowdSec enforcement

**Owner:** Platform/security  
**Estimate:** 0.5 day  
**Dependencies:** S01

- [ ] Remove the Caddy CrowdSec bouncer directive from the MVP image/config, or use a confirmed plugin-enabled image.
- [ ] Do not claim active blocking in README or docs.
- [ ] Retain CrowdSec configuration for a later detection/prevention profile.

**Evidence:** `integration/caddy-baseline.txt` and updated documentation.

**Done when:** Caddy starts without an unverified CrowdSec dependency.

## S05 — Restrict engine-socket access

**Owner:** Platform/security  
**Estimate:** 1 day  
**Dependencies:** S02

- [ ] Remove direct Docker/Podman socket mounts from MVP services.
- [ ] Keep container-health-exporter and other socket consumers opt-in.
- [ ] Document socket access as host-root-equivalent.
- [ ] Plan a restricted API proxy before re-enabling socket-dependent features.

**Commands:**

```sh
grep -nE 'docker.sock|podman.sock' /tmp/mvp-config.yml || true
```

**Evidence:** `security/mvp-socket-review.md`.

**Done when:** no unapproved MVP socket mount remains.

## S06 — Remove unsafe and unstable defaults

**Owner:** Security/platform  
**Estimate:** 1 day  
**Dependencies:** S01

- [ ] Replace default passwords and example secrets with placeholders.
- [ ] Reject `admin`, `SecretPassword`, `CHANGE_ME_*`, and known example values before startup.
- [ ] Remove `latest` and `nightly` from release-grade profiles.
- [ ] Align `.env.example` with the reduced MVP.
- [ ] Require Vault-rendered values for non-lab operation.

**Commands:**

```sh
grep -nE 'admin|SecretPassword|CHANGE_ME|latest|nightly' .env.example security-stack.compose.yml
podman-compose -f simplified.compose.yml --profile mvp config
```

**Evidence:** `security/default-secret-rejection.txt`.

**Done when:** unsafe configuration fails validation before containers start.

## S07 — Remove stale configuration and claims

**Owner:** Documentation/platform  
**Estimate:** 1 day  
**Dependencies:** S01–S06

- [ ] Remove deferred-service monitors from the MVP inventory.
- [ ] Correct service names such as `fqdn-proxy` versus `caddy`.
- [ ] Label capabilities `implemented`, `verified`, `planned`, or `deferred`.
- [ ] Update README, docs, Compose profiles, CoreDNS records, Caddy routes, and monitor inventory together.

**Evidence:** `compose-docs-inventory.md`.

**Done when:** all MVP service and endpoint lists agree.

### Priority 1 completion gate

- [ ] `mvp` contains only required services.
- [ ] Response automation is disabled.
- [ ] No unsafe default credentials are accepted.
- [ ] No unapproved engine socket is mounted.
- [ ] Deferred services are opt-in only.
- [ ] Documentation no longer claims unverified capabilities.

---

# Priority 2 — Fix incorrect or missing parts

**Goal:** make the reduced stack start, resolve, authenticate, ingest telemetry, and expose accurate health signals.

## F01 — Repair Caddy/FQDN proxy wiring

**Owner:** Platform/networking  
**Estimate:** 1 day  
**Dependencies:** S07

- [ ] Mount `The Hands/FQDN proxy - Caddy/Caddyfile` at `/etc/caddy/Caddyfile`.
- [ ] Publish the configured HTTP and HTTPS host ports.
- [ ] Assign `${FQDN_PROXY_IPV4}` to Caddy on `secnet`.
- [ ] Mount `caddy-logs` at `/var/log/caddy`.
- [ ] Add a `fqdn-proxy` network alias or rename every reference to `caddy`.
- [ ] Confirm Caddy routes to Graylog and Wazuh.

**Commands:**

```sh
podman-compose -f simplified.compose.yml --profile mvp config >/tmp/mvp-config.yml
podman-compose -f simplified.compose.yml --profile mvp up -d caddy coredns
dig @127.0.0.1 -p 1053 graylog.hq-sec.local
curl -kfsS https://graylog.hq-sec.local/
```

**Evidence:** `integration/caddy-dns.txt`.

**Done when:** DNS, Caddy health, and one proxied dashboard route pass.

## F02 — Make profiles dependency-safe

**Owner:** Platform  
**Estimate:** 1 day  
**Dependencies:** S07, F01

- [ ] Identify every `depends_on` edge crossing profile boundaries.
- [ ] Define supported bundles: `mvp`, `brain`, `logs`, `dashboard`, `network`, `ir`, `vuln`, and `all`.
- [ ] Keep `scripts/start.sh` as the only supported simplified-MVP startup path.
- [ ] Test clean startup and shutdown from an empty project state.

**Commands:**

```sh
podman-compose -f simplified.compose.yml --profile mvp down
sh scripts/start.sh
```

**Evidence:** `compose/mvp-start-stop.txt`.

**Done when:** no supported bundle starts partially or with missing dependencies.

## F03 — Implement real readiness checks

**Owner:** Platform  
**Estimate:** 1 day  
**Dependencies:** F02

- [ ] Replace process-only checks with endpoint/readiness checks.
- [ ] Add checks for CoreDNS, Caddy, Graylog API, Wazuh API/indexer, and Uptime Kuma.
- [ ] Use `service_healthy` dependencies where appropriate.
- [ ] Define startup timeout and restart expectations.

**Commands:**

```sh
podman-compose -f simplified.compose.yml --profile mvp ps
podman inspect <container> --format '{{json .State.Health}}'
```

**Evidence:** `compose/mvp-health.txt`.

**Done when:** every MVP service has a meaningful passing health check.

## F04 — Establish Graylog inputs

**Owner:** Logging/SIEM  
**Estimate:** 1 day  
**Dependencies:** F02, F03

- [ ] Make GELF and syslog input creation idempotent.
- [ ] Confirm internal and host-published ports match the documentation.
- [ ] Send one controlled GELF event and one syslog event from `secnet`.
- [ ] Record input names, ports, authentication, and failure behavior.

**Commands:**

```sh
podman logs graylog-bootstrap --tail 100
podman-compose -f simplified.compose.yml --profile mvp exec fluent-bit sh -c 'printf test | nc -u graylog 12201'
```

**Evidence:** `integration/graylog-inputs.txt`.

**Done when:** both test events are searchable in Graylog.

## F05 — Correct Fluent Bit paths and forwarding

**Owner:** Logging/SIEM  
**Estimate:** 1 day  
**Dependencies:** F04

- [ ] Verify every configured Fluent Bit path is mounted into the container.
- [ ] Enable only MVP sources: Wazuh and Caddy unless a network sensor is intentionally included.
- [ ] Fix timestamp parsing and source tags.
- [ ] Confirm Fluent Bit resolves `graylog` and sends to the correct input.
- [ ] Check for file tail errors and dropped records.

**Commands:**

```sh
podman logs log-forwarder --tail 200
grep -nE 'Path|Tag|Host|Port|Parser' 'The Eyes/Fluent Bit/fluent-bit.conf'
```

**Evidence:** `integration/fluent-bit-sources.txt`.

**Done when:** each enabled source produces a searchable Graylog event with source and event time.

## F06 — Define Graylog streams and normalized fields

**Owner:** Detection engineering  
**Estimate:** 1 day  
**Dependencies:** F05

- [ ] Create streams for Wazuh and Caddy.
- [ ] Normalize `source`, `event_type`, `severity`, `rule_id`, `endpoint`, `src_ip`, `dst_ip`, `src_port`, `dst_port`, and `event_time` where available.
- [ ] Define retention and index rotation.
- [ ] Document Wazuh as endpoint detection authority and Graylog as search/correlation layer.

**Evidence:** `integration/graylog-normalization.md` with example queries and results.

**Done when:** source-specific queries return consistent fields.

## F07 — Fix monitor inventory and validator

**Owner:** Operations  
**Estimate:** 1 day  
**Dependencies:** F01–F05

- [ ] Replace nonexistent `fqdn-proxy` service references with the chosen alias/service name.
- [ ] Make `validate-monitors.py` accept a path argument while retaining `/uptime-kuma/monitors.yml` as the container default.
- [ ] Remove deferred-service monitors from the MVP inventory.
- [ ] Validate targets from inside the monitor network.

**Commands:**

```sh
python3 'The Eyes/Uptime-Kuma/scripts/validate-monitors.py' 'The Eyes/Uptime-Kuma/monitors.yml'
podman logs uptime-kuma-sync --tail 100
```

**Evidence:** `integration/monitor-validation.txt`.

**Done when:** local and container validation pass for all MVP targets.

## F08 — Validate backup and restore

**Owner:** Operations/recovery  
**Estimate:** 1 day  
**Dependencies:** F02

- [ ] Back up every MVP volume.
- [ ] Verify checksums and archive manifests.
- [ ] Restore one service volume into a disposable project.
- [ ] Record stop/order requirements, retention, and off-host copy expectations.

**Commands:**

```sh
podman logs volume-backup --tail 100
find 'The Hands/backups' -maxdepth 3 -type f | sort
```

**Evidence:** `recovery/mvp-restore.md`.

**Done when:** persistent data is recovered without modifying the live project.

## F09 — Add configuration consistency checks

**Owner:** Platform/CI  
**Estimate:** 1 day  
**Dependencies:** F01–F07

- [ ] Compare Compose service names with monitor targets and CoreDNS records.
- [ ] Remove duplicated hard-coded proxy IP values where practical.
- [ ] Generate scanner image targets from rendered Compose.
- [ ] Add CI checks for Compose, shell syntax, image references, ports, FQDNs, and monitor targets.

**Commands:**

```sh
sh -n scripts/*.sh
podman-compose -f simplified.compose.yml --profile mvp config
```

**Evidence:** `compose/consistency-check.txt`.

**Done when:** CI detects stale service names, image references, endpoints, and monitor entries.

### Priority 2 completion gate

- [ ] The MVP starts cleanly from an empty project state.
- [ ] Internal DNS and Caddy routes work.
- [ ] Graylog receives and indexes test telemetry.
- [ ] Fluent Bit forwards only valid enabled sources.
- [ ] Health checks and monitors pass.
- [ ] Backup and disposable restore tests pass.
- [ ] CI catches configuration drift.

---

# Priority 3 — Deliver the integrated MVP

**Goal:** prove one complete security-monitoring workflow and safe day-to-day operation.

## M01 — Clean MVP deployment

**Owner:** Release/operator  
**Estimate:** 0.5 day  
**Dependencies:** Priority 1 and Priority 2 gates

- [ ] Prepare `.env` with approved non-default secrets.
- [ ] Start only `mvp` through `scripts/start.sh` using `simplified.compose.yml`.
- [ ] Record engine, Compose provider, image source, startup duration, failed containers, and restarts.
- [ ] Confirm all MVP healthchecks pass.

**Evidence:** `releases/mvp-clean-start.txt`.

## M02 — Trace one event end to end

**Owner:** Endpoint/detection  
**Estimate:** 1 day  
**Dependencies:** M01

- [ ] Enroll one authorized test endpoint or generate one controlled synthetic event.
- [ ] Confirm Wazuh receives and classifies it.
- [ ] Confirm Graylog receives the event or alert.
- [ ] Record event ID, source timestamp, Graylog timestamp, query, and result.

**Evidence:** `integration/mvp-event-trace.md`.

**Done when:** another operator can reproduce the event and find it using the documented query.

## M03 — Execute the analyst investigation

**Owner:** Detection engineering  
**Estimate:** 0.5 day  
**Dependencies:** M02

- [ ] Write a short investigation procedure.
- [ ] Identify event source, severity, affected endpoint, and evidence location.
- [ ] Document false-positive handling and known limitations.
- [ ] Have a second operator repeat the procedure.

**Evidence:** `integration/mvp-investigation.md`.

## M04 — Prove monitoring and recovery

**Owner:** Operations  
**Estimate:** 0.5 day  
**Dependencies:** M01, F07, F08

- [ ] Confirm Uptime Kuma monitors every MVP service.
- [ ] Stop one non-critical service.
- [ ] Confirm outage detection and recovery timestamps.
- [ ] Confirm backup output and disposable restore evidence are available.

**Evidence:** `recovery/mvp-monitor-recovery.md`.

## M05 — Perform security/exposure review

**Owner:** Security reviewer  
**Estimate:** 0.5 day  
**Dependencies:** M01–M04

- [ ] Review published ports and bind addresses.
- [ ] Review privileged capabilities and host networking.
- [ ] Confirm no unsafe credentials remain.
- [ ] Confirm deferred services and engine sockets are inactive.
- [ ] Record accepted lab limitations and follow-up risks.

**Evidence:** `security/mvp-review.md`.

## M06 — Release the MVP documentation

**Owner:** Documentation/release  
**Estimate:** 0.5 day  
**Dependencies:** M01–M05

- [ ] Update README and docs with the MVP start path.
- [ ] Document supported services, endpoints, resources, credentials bootstrap, and limitations.
- [ ] Link this plan from `docs/index.md`.
- [ ] Mark only tested capabilities as verified.

**Evidence:** `releases/mvp-signoff.md`.

### MVP completion gate

- [ ] The reduced stack starts successfully from a clean environment.
- [ ] Every enabled container has a working dependency and healthcheck.
- [ ] One security event travels through the documented ingestion path.
- [ ] The event is searchable and investigable.
- [ ] Uptime Kuma detects service failure and recovery.
- [ ] Backup and disposable restore tests pass.
- [ ] Secrets, ports, privileges, and limitations are reviewed.
- [ ] Documentation matches the tested implementation.

---

# Daily execution schedule

Each day must produce a reviewable artifact. Do not begin the next day’s dependent work while the current gate is failed or blocked.

## Day 1 — Freeze scope and remove response automation

**Tasks:** S01–S04  
**Output:** `compose/mvp-scope.md`, `compose/mvp-config.yml`, `security/mvp-response-exclusion.txt`  
**Gate:** only MVP services are selected; response automation is excluded.

## Day 2 — Remove privileged access and unsafe defaults

**Tasks:** S05–S07  
**Output:** socket review, default-secret rejection test, configuration inventory  
**Gate:** no unsafe defaults or unapproved socket mounts remain.

## Day 3 — Repair Caddy, DNS, and proxy naming

**Tasks:** F01  
**Output:** `integration/caddy-dns.txt`  
**Gate:** CoreDNS, Caddy health, and one proxied route pass.

## Day 4 — Repair profiles and readiness

**Tasks:** F02–F03  
**Output:** `compose/mvp-start-stop.txt`, `compose/mvp-health.txt`  
**Gate:** clean startup/shutdown and meaningful healthchecks pass.

## Day 5 — Establish Graylog inputs

**Tasks:** F04  
**Output:** `integration/graylog-inputs.txt`  
**Gate:** controlled GELF and syslog events are searchable.

## Day 6 — Forward and normalize telemetry

**Tasks:** F05–F06  
**Output:** source matrix and normalized-field queries  
**Gate:** every enabled source is searchable with useful fields.

## Day 7 — Monitoring, recovery, and CI checks

**Tasks:** F07–F09  
**Output:** monitor validation, restore evidence, consistency-check result  
**Gate:** monitors, restore, and drift checks pass.

## Day 8 — Run the end-to-end event workflow

**Tasks:** M01–M03  
**Output:** clean-start evidence, event trace, investigation runbook  
**Gate:** a second operator can reproduce the event and investigation.

## Day 9 — Recovery and security review

**Tasks:** M04–M05  
**Output:** recovery evidence and security review  
**Gate:** outage/recovery and exposure review pass.

## Day 10 — MVP release

**Tasks:** M06 and MVP completion gate  
**Output:** `releases/mvp-signoff.md`  
**Gate:** release, defer, or return specific failed tasks for correction.

---

# Post-MVP roadmap

Only start after the MVP completion gate passes.

## Phase 2 — Network visibility

- [ ] Add Suricata and Zeek as an opt-in profile.
- [ ] Validate capture scope on `${SENSOR_INTERFACE}`.
- [ ] Forward and normalize network telemetry.
- [ ] Add authorized detection test cases.

## Phase 3 — Case management

- [ ] Add one Wazuh/Graylog-to-TheHive alert path.
- [ ] Define case creation, severity mapping, deduplication, and evidence links.
- [ ] Test the analyst case workflow.

## Phase 4 — Read-only orchestration

- [ ] Connect TheHive to Shuffle.
- [ ] Add enrichment and lookup workflows.
- [ ] Add audit logging and failure handling.

## Phase 5 — Controlled response

- [ ] Test Velociraptor collection on an authorized endpoint.
- [ ] Test Ansible containment with explicit human approval.
- [ ] Add rollback and evidence-preservation checks.

## Phase 6 — Vulnerability and secrets operations

- [ ] Validate Greenbone feeds and authorized scans.
- [ ] Correlate findings with Graylog/TheHive.
- [ ] Test Vault initialization, rotation, restart, and rollback.

## Phase 7 — Prevention and advisory intelligence

- [ ] Verify CrowdSec Caddy enforcement.
- [ ] Tune Suricata rules before considering inline prevention.
- [ ] Validate Ghost reports against known evidence.
- [ ] Keep AI-generated actions advisory and human-reviewed.

## Overall definition of done

- [ ] Every advertised data flow has a reproducible test.
- [ ] Every service has an owner, healthcheck, dependency set, and recovery position.
- [ ] Every privileged capability has a stated reason and mitigation.
- [ ] Every response action has approval, audit, and rollback controls.
- [ ] Documentation distinguishes verified, planned, and deferred behavior.
- [ ] The full profile is optional and is enabled only after each extension profile passes independently.
