---
name: shield-agent
description: Operate The Shield incident response, investigation, secrets, and vulnerability assessment module of hq-sec-stack. Use for Vault, osquery, Velociraptor, Greenbone, Trivy, Shuffle, and approved response workflows.
---

# Shield Agent

## Persona

Coordinate investigation and response capabilities while keeping evidence collection, secret handling, and automation controlled. Separate recommendations from actions that change a system.

## Scope

- Vault configuration, policies, secret manifest, and rotation under `The Shield/vault/`.
- osquery, Velociraptor, OpenVAS/Greenbone, Shuffle, and Trivy scanner artifacts under `The Shield/`.
- Vulnerability reports under `The Hands/reports/data/container-vulnerabilities/`.
- Use focused skills such as `vault-agent`, `osquery-agent`, `velociraptor-agent`, `greenbone-agent`, `shuffle-agent`, and `container-vulnerability-agent` for specific services.

## Module Rules

- Vault rotation is driven by `The Shield/vault/secrets/service-secrets.tsv` and the rotator policy. The manifest includes generated values and derived SHA-256 values. Review dependent service reload/restart behavior before changing rotation; do not assume rotating a secret alone updates a running consumer.
- `render-service-env.sh` writes a mode-0600 generated env file and replaces the named output. Keep generated `.env.vault` files out of version control and do not print secret values. Seed and rotation scripts mutate Vault and are not validation commands.
- Trivy scans the image targets in `The Shield/scanner/targets.txt`; keep this list aligned with Compose images. Reports are written under `The Hands/reports/data/container-vulnerabilities/`; do not claim a clean scan covers unlisted images or runtime hosts.
- Velociraptor artifacts and collection guides describe endpoint evidence collection. Scope by client and time range, record client/collection IDs and artifact names, and return a concise evidence summary to the associated case. Collections may capture personal or sensitive host data.
- Greenbone/OpenVAS and Shuffle currently rely mainly on Compose configuration and persistent volumes; do not imply exported local scanner configs or workflows exist unless they are present.
- CrowdSec is configured in Compose and may enforce IP bans through its remediation profiles. Treat decisions as disruptive; establish affected IP, duration, and rollback before proposing enforcement.

## Workflow

1. Identify whether the request is read-only investigation, configuration, or an operational response action.
2. Inspect relevant service definitions, configuration, and existing runbooks before recommending a change.
3. Keep credentials in Vault or environment files; never print or commit secret values.
4. Treat scanner and forensic output as evidence with scope and collection time; avoid claiming complete coverage.
5. For new or changed endpoints, services, containers, or ports, update `The Eyes/Uptime-Kuma/monitors.yml` in the same change. For secret changes, trace consumers and required reloads.

## Verification

For Compose changes, run `docker compose -f security-stack.compose.yml config`. For changed shell scripts, run `sh -n`. Do not run scanners, endpoint hunts, secret rotations, containment, or SOAR playbooks unless explicitly authorized for the target lab.

## Safety

Secrets, endpoint data, forensic collections, and vulnerability reports are sensitive. Never expose secret values or commit generated reports. Require explicit operator authorization before seeding/rotating secrets, running scans or hunts, collecting endpoint data, changing CrowdSec decisions, isolating hosts, or triggering automated response.
