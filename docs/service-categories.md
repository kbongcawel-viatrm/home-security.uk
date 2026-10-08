# Service Categories

The repository is organized by SOC function. Some services have secondary roles, so their secondary category folder contains a pointer `README.md` instead of duplicated config.

## Module Agents

Module-wide operating guidance lives in the matching skill package. Load the narrower service skill as well when a task is specific to one integration.

| Module | Agent skill | Main operating focus |
| --- | --- | --- |
| The Brain | [`brain-agent`](../skills/brain-agent/SKILL.md) | Wazuh and OSSEC telemetry, rules, enrollment boundaries, and alert correlation |
| The Eyes | [`eyes-agent`](../skills/eyes-agent/SKILL.md) | Log and telemetry flow, investigation context, monitoring, and authorized capture/scanning |
| The Ghost | [`ghost-agent`](../skills/ghost-agent/SKILL.md) | Evidence-bounded cross-pillar assessment and human-reviewed directives |
| The Hands | [`hands-agent`](../skills/hands-agent/SKILL.md) | DNS, proxy, reports, backups, and recovery safety |
| The Shield | [`shield-agent`](../skills/shield-agent/SKILL.md) | Secrets, endpoint investigation, vulnerability assessment, and controlled response |
| The Sword | [`sword-agent`](../skills/sword-agent/SKILL.md) | Defensive rules, endpoint controls, and reviewed response execution |

## 1. Alert, Visualization & SIEM: The Brain

Path: `The Brain/`

| Folder | Service | Role |
| --- | --- | --- |
| `The Brain/Wazuh` | Wazuh | Alerting, endpoint event intake, dashboard/index integration |
| `The Ghost/Core` | The Ghost | Local LLM assessment, report generation, attack-pattern reasoning |
| `The Brain/OSSEC` | OSSEC | OSSEC artifacts and host intrusion detection support |

## 2. Network Monitoring: The Eyes

Path: `The Eyes/`

| Folder | Service | Role |
| --- | --- | --- |
| `The Eyes/Graylog` | Graylog | Central log search, streams, dashboards, bootstrap inputs |
| `The Eyes/Wazuh` | Wazuh pointer | Endpoint telemetry and alert evidence feeding visualization |
| `The Eyes/Fluent Bit` | Fluent Bit | Log collection and forwarding into Graylog |
| `The Eyes/sysmon` | Sysmon pointer | Windows process/event telemetry for detection |
| `The Eyes/thehive` | TheHive | Alert visibility, case intake, and investigation context |
| `The Eyes/Uptime-Kuma` | Uptime Kuma | Availability monitoring for every stack service |

## 3. Incident Response & Automation: The Shield

Path: `The Shield/`

| Folder | Service | Role |
| --- | --- | --- |
| `The Shield/vault` | Vault | Secrets control, monthly rotation, credential hardening |
| `The Shield/osquery` | osquery pointer | Live endpoint visibility and SQL-based inspection |
| `The Shield/openvas` | OpenVAS pointer | Vulnerability scanner role through Greenbone containers |
| `The Shield/shuffle` | Shuffle pointer | SOAR workflow and approved automation handoff |
| `The Shield/scanner` | Trivy scanner | Container vulnerability scanning and reports |
| `The Shield/velociraptor` | Velociraptor | Endpoint forensics, hunts, and collection planning |

## 4. Endpoint Vulnerability, Protection, And Hardening: The Sword

Path: `The Sword/`

| Folder | Service | Role |
| --- | --- | --- |
| `The Sword/Crowdstrike-Fail2Ban` | CrowdStrike / Fail2Ban placeholder | Future endpoint/host protection artifacts |
| `The Sword/Suricata` | Suricata | IDS sensor, rules, and network detection definitions |
| `The Sword/Ansible` | Ansible | Response and hardening playbooks |
| `The Sword/Windows/powershell` | PowerShell logging | Windows command/activity capture scripts |
| `The Sword/Windows/sysmon` | Sysmon | Windows Sysmon config |
| `The Sword/Windows/Applocker` | AppLocker placeholder | Future application control policies |

## 5. Support Services: The Hands

Path: `The Hands/`

| Folder | Service | Role |
| --- | --- | --- |
| `The Hands/CoreDNS` | CoreDNS | Local `hq-sec.local` DNS |
| `The Hands/FQDN proxy - Caddy` | Caddy | FQDN reverse proxy |
| `The Hands/Vault` | Vault pointer | Stack-wide secret support role |
| `The Hands/reports` | Reports | Report dashboard and generated report data |
| `The Hands/Fluent Bit` | Fluent Bit pointer | Stack-wide log forwarding support role |
| `The Hands/backup` | Backup | Persistent Docker volume backup and restore scripts |
| `The Hands/log assessor` | Legacy assessment scripts | Archived local rule summary path; The Ghost now owns LLM assessment |
