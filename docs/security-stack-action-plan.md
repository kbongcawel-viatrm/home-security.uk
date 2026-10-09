# Security Stack Action Plan

## Purpose

This is the consolidated, assignable work list for turning the repository into a verified, interconnected security-lab stack. It separates hard blockers from deferred components and converts the work into daily-sized tasks.

**Operating rule:** do not describe a capability as supported until its complete data path has been tested and the result recorded.

## Status legend

- `[ ]` Not started
- `[~]` In progress
- `[x]` Complete
- `[D]` Deferred or intentionally excluded from the MVP

## Target MVP

The first release should support one verified workflow:

```text
Test endpoint or synthetic event
  -> Wazuh or network sensor
  -> Graylog search/dashboard
  -> analyst investigation
  -> documented recovery and backup procedure
```

MVP services:

- CoreDNS
- Caddy/FQDN proxy
- Wazuh manager, indexer, and dashboard
- Graylog, Graylog Data Node, and MongoDB
- Fluent Bit
- Uptime Kuma
- Backup service

Defer Greenbone, Shuffle, automated response, CrowdSec enforcement, and Ghost automation until the MVP is repeatable.

---

# 1. Critical areas to fix

These items block reliable interconnection and should be completed before feature expansion.

## C01 — Repair Caddy/FQDN proxy wiring

**Owner:** Platform/networking  
**Estimate:** 1 day  
**Priority:** P0  
**Dependencies:** None

- [ ] Mount `The Hands/FQDN proxy - Caddy/Caddyfile` into `/etc/caddy/Caddyfile`.
- [ ] Publish the documented HTTP and HTTPS host ports.
- [ ] Assign `${FQDN_PROXY_IPV4}` to Caddy on `secnet`.
- [ ] Mount the `caddy-logs` volume at the path used by the Caddyfile.
- [ ] Add a `fqdn-proxy` network alias, or rename all references to `caddy`.
- [ ] Confirm the Caddy image contains the CrowdSec plugin or remove the plugin directive until it does.

**Acceptance criteria:** `dig` resolves `graylog.hq-sec.local` to the proxy IP; HTTP/HTTPS requests reach Caddy; `/healthz` returns 200; Graylog and Ghost routes work through the proxy.

## C02 — Make Compose profiles dependency-safe

**Owner:** Platform  
**Estimate:** 1 day  
**Priority:** P0  
**Dependencies:** C01

- [ ] Identify every `depends_on` edge crossing profile boundaries.
- [ ] Define supported bundles such as `brain`, `logs`, `dashboard`, `ir`, `vuln`, and `all`.
- [ ] Update `scripts/start-stack.sh` to expand required dependency profiles or reject unsupported combinations clearly.
- [ ] Test each supported bundle from a clean project state.

**Acceptance criteria:** No supported profile starts with missing dependencies; failure messages identify missing services instead of producing partial deployments.

## C03 — Establish Graylog ingestion and normalization

**Owner:** Logging/SIEM  
**Estimate:** 2 days  
**Priority:** P0  
**Dependencies:** C02

- [ ] Verify Graylog GELF and syslog inputs are created idempotently.
- [ ] Verify Fluent Bit can read actual Suricata, Zeek, Wazuh, Vault, OpenVAS, and Caddy paths.
- [ ] Create Graylog streams for each source.
- [ ] Add pipelines/extractors for timestamp, source, event type, severity, rule ID, source/destination IP, ports, and `community_id`.
- [ ] Add retention and index rotation settings.

**Acceptance criteria:** A synthetic event from each enabled source is searchable with correct timestamp, source, and severity fields.

## C04 — Define one authoritative alert model

**Owner:** Detection engineering  
**Estimate:** 1 day  
**Priority:** P0  
**Dependencies:** C03

- [ ] Document Wazuh as the endpoint detection authority.
- [ ] Document Graylog as the central search/correlation layer.
- [ ] Define which system creates TheHive cases.
- [ ] Define severity mapping and deduplication rules.
- [ ] Prevent duplicate independent containment triggers.

**Acceptance criteria:** A written event ownership matrix exists and a single test alert has one clear owner and lifecycle.

## C05 — Verify endpoint-to-dashboard telemetry

**Owner:** Endpoint/detection  
**Estimate:** 1 day  
**Priority:** P0  
**Dependencies:** C03, C04

- [ ] Enroll one authorized test endpoint.
- [ ] Generate one known Windows or synthetic detection event.
- [ ] Confirm receipt by Wazuh.
- [ ] Confirm visibility in Graylog or the selected dashboard.
- [ ] Record the exact event, query, timestamp, and expected result.

**Acceptance criteria:** A new operator can reproduce the test event and locate it using the documented query.

## C06 — Fix monitor inventory and validation

**Owner:** Operations  
**Estimate:** 1 day  
**Priority:** P1  
**Dependencies:** C01, C02

- [ ] Correct `fqdn-proxy` versus `caddy` monitor names.
- [ ] Make `validate-monitors.py` accept a path argument while retaining its container default.
- [ ] Remove monitors for components not in the selected MVP.
- [ ] Validate all HTTP and port targets from inside the monitor network.
- [ ] Reconcile the inventory whenever a service or endpoint changes.

**Acceptance criteria:** The validator runs successfully from the repository and from the container; all MVP monitors pass.

## C07 — Remove unsafe default credentials from startup paths

**Owner:** Security/platform  
**Estimate:** 1 day  
**Priority:** P0  
**Dependencies:** None

- [ ] Replace default passwords in deployment examples with placeholders.
- [ ] Add startup validation rejecting `admin`, `SecretPassword`, `CHANGE_ME_*`, and known example values.
- [ ] Require Vault-rendered values for non-lab deployments.
- [ ] Document restart/reload behavior after rotation.

**Acceptance criteria:** A deployment with default credentials fails before services start; a deployment with generated secrets starts successfully.

## C08 — Validate backups and restore operations

**Owner:** Operations/recovery  
**Estimate:** 1 day  
**Priority:** P1  
**Dependencies:** MVP services running

- [ ] Back up all MVP volumes.
- [ ] Verify checksums and archive manifests.
- [ ] Restore one service volume into a disposable test project.
- [ ] Record service stop/order requirements.
- [ ] Document retention and off-host-copy requirements.

**Acceptance criteria:** A documented restore test recovers a service and its expected data without overwriting the live deployment.

---

# 2. Components to remove or defer

These components should not be part of the first stable milestone unless their complete integration is required and tested.

## R01 — Defer automated containment

**Components:** Shuffle, Ansible response execution, automatic isolation, automatic blocking  
**Reason:** High blast radius; the current repository does not prove alert-to-action wiring, approval, audit, or rollback.

- [ ] Keep playbooks and workflow definitions, but mark execution disabled by default.
- [ ] Permit read-only enrichment first.
- [ ] Require explicit human approval for containment.

## R02 — Defer CrowdSec enforcement

**Components:** CrowdSec Caddy bouncer and active blocking  
**Reason:** Caddy log volume and plugin/runtime wiring are incomplete.

- [ ] Keep CrowdSec in detection-only mode.
- [ ] Remove the README claim that active blocking is operational until a block test passes.
- [ ] Re-enable enforcement only after Caddy plugin, LAPI, key provisioning, and rollback are verified.

## R03 — Defer Greenbone/OpenVAS from the MVP

**Components:** Greenbone feed/data/scanner dependency graph  
**Reason:** Resource-heavy and operationally independent from the first telemetry workflow.

- [ ] Keep the profile available but exclude it from default startup.
- [ ] Add a separate feed synchronization and authorized-target validation milestone.

## R04 — Defer Ghost as an operational dependency

**Components:** `ghost`, `ghost-model-pull`, `ghost-assessor`  
**Reason:** LLM assessment is advisory and does not replace deterministic detection; current model defaults are inconsistent.

- [ ] Default to a local model or fail clearly when a cloud key is absent.
- [ ] Keep report generation read-only.
- [ ] Do not allow Ghost output to execute response actions.

## R05 — Remove unsupported or duplicate components from default bundles

- [ ] Remove services not required by the selected MVP from the default `all`-equivalent deployment.
- [ ] Remove duplicate or stale monitor definitions.
- [ ] Remove unused legacy assessment paths if The Ghost is the maintained assessor.
- [ ] Remove `latest`/`nightly` image tags from any release-grade bundle.

## R06 — Restrict Docker/Podman socket consumers

**Components:** Portainer, Shuffle backend/Orborus, container-health-exporter  
**Reason:** Engine sockets are effectively host-root access.

- [ ] Exclude socket consumers from the default MVP unless required.
- [ ] Replace direct sockets with a restricted API proxy where feasible.
- [ ] Document the trust boundary and operational risk.

---

# 3. Areas requiring improvement

## I01 — Configuration consistency

- [ ] Generate image scan targets from rendered Compose instead of maintaining a separate manual list.
- [ ] Replace hard-coded `10.77.0.80` references with one generated/configured source.
- [ ] Align README, docs, Compose, Caddyfile, CoreDNS records, and monitors.
- [ ] Add CI checks for service names, image references, FQDNs, ports, and monitor targets.

## I02 — Health and readiness checks

- [ ] Replace process-only healthchecks with application readiness checks.
- [ ] Add healthchecks for Graylog API, Wazuh API/indexer, Vault health, Caddy routes, and Greenbone readiness.
- [ ] Ensure `depends_on` conditions use health or successful completion where appropriate.

## I03 — Observability and operations

- [ ] Define startup timeouts per profile.
- [ ] Record image source, profile, engine, failed containers, and restart counts for every validation run.
- [ ] Add disk usage and log-retention alerts.
- [ ] Define service resource limits and realistic host requirements.

## I04 — Security hardening

- [ ] Pin all release images by immutable digest where practical.
- [ ] Remove `latest` and `nightly` from production-like workflows.
- [ ] Add image provenance/signature verification.
- [ ] Review privileged capabilities and host-network services.
- [ ] Keep all management endpoints loopback-only by default.
- [ ] Document internal CA trust installation for Caddy HTTPS.

## I05 — Integration contracts

For every service-to-service integration, document:

- [ ] Source and destination.
- [ ] Protocol and port.
- [ ] Authentication mechanism.
- [ ] Payload/schema.
- [ ] Retry and idempotency behavior.
- [ ] Failure behavior.
- [ ] Audit trail.
- [ ] Rollback procedure.

Required contracts include Wazuh → Graylog, network sensors → Fluent Bit → Graylog, Graylog/Wazuh → TheHive, TheHive → Shuffle, Shuffle → Velociraptor/Ansible, Greenbone → reporting, and Vault → service restart.

## I06 — Documentation quality

- [ ] Mark every capability as `implemented`, `verified`, `planned`, or `deferred`.
- [ ] Correct stale `docker-compose` examples where the startup script is required.
- [ ] Publish MVP resource requirements and supported host assumptions.
- [ ] Add troubleshooting for DNS, Caddy certificates, Graylog startup, Wazuh enrollment, and volume restore.
- [ ] Update the docs index with this action plan.

---

# 4. Daily execution plan

Each day should produce a reviewable artifact, test result, or closed issue. Estimates assume one engineer familiar with Compose and Linux.

## Day 1 — Baseline and ownership

- [ ] Create issues for C01–C08 and assign owners.
- [ ] Choose the MVP profile and one test event.
- [ ] Record host OS, engine, Compose provider, CPU, RAM, disk, and network interface.
- [ ] Capture baseline `config`, service list, and current failure modes.

**Deliverable:** MVP boundary document and assigned issue list.

## Day 2 — Caddy and DNS

- [ ] Complete C01.
- [ ] Test CoreDNS resolution and Caddy health.
- [ ] Test one proxied backend.

**Deliverable:** passing DNS/proxy smoke-test log.

## Day 3 — Profiles and readiness

- [ ] Complete C02.
- [ ] Add or correct healthchecks.
- [ ] Test clean startup and shutdown for the MVP bundle.

**Deliverable:** supported profile matrix and startup transcript.

## Day 4 — Graylog inputs

- [ ] Complete the Graylog portion of C03.
- [ ] Verify GELF/syslog inputs with synthetic events.
- [ ] Record input IDs and ports.

**Deliverable:** Graylog input validation report.

## Day 5 — Fluent Bit and parsing

- [ ] Complete the Fluent Bit portion of C03.
- [ ] Generate or replay one event for each enabled source.
- [ ] Confirm events arrive with useful fields.

**Deliverable:** source-to-Graylog test matrix.

## Day 6 — Wazuh endpoint workflow

- [ ] Complete C04 and C05.
- [ ] Enroll or simulate one authorized test endpoint.
- [ ] Document the investigation query and expected alert.

**Deliverable:** verified endpoint telemetry walkthrough.

## Day 7 — Monitoring and credentials

- [ ] Complete C06 and C07.
- [ ] Make monitor validation runnable locally and in-container.
- [ ] Confirm startup rejects unsafe defaults.

**Deliverable:** passing monitor report and safe-secret startup test.

## Day 8 — Backup and recovery

- [ ] Complete C08.
- [ ] Execute a disposable restore test.
- [ ] Record recovery time and missing data, if any.

**Deliverable:** restore evidence and recovery runbook.

## Day 9 — Documentation and CI gates

- [ ] Complete I01, I02, and I06 for the MVP.
- [ ] Add Compose, shell, monitor, and image-reference checks to CI.
- [ ] Update README and docs to remove unverified claims.

**Deliverable:** documentation and CI consistency pass.

## Day 10 — MVP release review

- [ ] Run the full validation checklist from a clean environment.
- [ ] Review privilege, port exposure, secrets, storage, and restart behavior.
- [ ] Decide whether the MVP is releasable or requires another fix cycle.

**Deliverable:** signed MVP review with known limitations.

---

# 5. Follow-on roadmap

## Sprint 2 — Network visibility

- [ ] Validate Suricata capture scope.
- [ ] Validate Zeek logs.
- [ ] Complete sensor-to-Graylog normalization.
- [ ] Add authorized detection test cases.

## Sprint 3 — Case management

- [ ] Implement one Wazuh/Graylog-to-TheHive connector.
- [ ] Define alert-to-case mapping and deduplication.
- [ ] Test evidence links and analyst workflow.

## Sprint 4 — Read-only orchestration

- [ ] Connect TheHive to Shuffle.
- [ ] Add enrichment and lookup workflows.
- [ ] Add audit logging and failure handling.

## Sprint 5 — Controlled response

- [ ] Test Velociraptor collection on an authorized endpoint.
- [ ] Test Ansible containment with explicit approval.
- [ ] Add rollback and evidence-preservation checks.

## Sprint 6 — Vulnerability and secrets operations

- [ ] Validate Greenbone feeds and authorized scans.
- [ ] Correlate findings with Graylog/TheHive.
- [ ] Test Vault initialization, rotation, restart, and rollback.

## Sprint 7 — Prevention and advisory intelligence

- [ ] Verify CrowdSec Caddy enforcement.
- [ ] Tune Suricata rules before considering inline prevention.
- [ ] Validate Ghost reports against known evidence.
- [ ] Keep AI-generated actions advisory and human-reviewed.

## Definition of done for the overall stack

- [ ] Every advertised data flow has a reproducible test.
- [ ] Every service has an owner, healthcheck, backup/restore position, and documented dependency set.
- [ ] Every privileged capability has a stated reason and mitigation.
- [ ] Every response action has approval, audit, and rollback controls.
- [ ] Documentation distinguishes verified behavior from planned behavior.
- [ ] The full profile can be started only after the MVP and each extension profile pass independently.
