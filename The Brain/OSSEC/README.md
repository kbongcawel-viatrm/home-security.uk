# OSSEC Setup Notes

This workspace contains a working OSSEC manager setup inside the hardened `CBL-Mariner` WSL 2 distro, plus helper scripts for registering the Windows host as an agent.

## Current layout

- OSSEC manager project: [D:/codex-workspace/ossec-server](D:/codex-workspace/ossec-server)
- WSL transfer helper: [D:/codex-workspace/transfer-ossec-to-wsl.cmd](D:/codex-workspace/transfer-ossec-to-wsl.cmd)
- Windows agent config helper: [D:/codex-workspace/install-configure-ossec-host.ps1](D:/codex-workspace/install-configure-ossec-host.ps1)
- Elevated Windows rekey wrapper: [D:/codex-workspace/run-ossec-host-rekey.ps1](D:/codex-workspace/run-ossec-host-rekey.ps1)
- Daily logging wrapper: [D:/codex-workspace/Run-OssecDailyLogs.ps1](D:/codex-workspace/Run-OssecDailyLogs.ps1)
- Log copy helper: [D:/codex-workspace/Copy-OssecLogs.ps1](D:/codex-workspace/Copy-OssecLogs.ps1)
- Current Windows agent installer: [D:/codex-workspace/downloads/ossec-agent-win32-3.8.0-35114.exe](D:/codex-workspace/downloads/ossec-agent-win32-3.8.0-35114.exe)

## Manager image

The WSL Compose project uses the prebuilt `atomicorp/ossec-docker:v3.6` image. It is separate from the main security stack.

## Start the OSSEC WSL

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\codex-workspace\start-ossec-wsl.ps1 -Transfer -Pull -ListAgents
```

## Restart OSSEC WSL

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\codex-workspace\start-ossec-wsl.ps1 -RestartOnly -ListAgents
```

## Start the OSSEC manager in WSL

1. Copy the project into the WSL filesystem:

```powershell
cmd /c D:\codex-workspace\transfer-ossec-to-wsl.cmd
```

2. Start or refresh the manager container:

```powershell
wsl --cd /opt/ossec-server -d CBL-Mariner -u root --exec /usr/bin/sh -c 'mkdir -p data && docker compose pull && docker compose up -d'
```

3. Check container status:

```powershell
wsl --cd /opt/ossec-server -d CBL-Mariner -u root --exec /usr/bin/sh -c 'docker ps -a'
```

4. Check manager agents:

```powershell
wsl -d CBL-Mariner -u root --exec docker exec ossec-server /bin/sh -lc "cd /var/ossec && ./bin/manage_agents -l"
```

## Current known-good manager state

The manager currently has one live agent:

- `003 / HOST-LAPTOP / any`

You can verify that with:

```powershell
wsl -d CBL-Mariner -u root --exec docker exec ossec-server /bin/sh -lc "cd /var/ossec && ./bin/manage_agents -l && echo --- && cat /var/ossec/etc/client.keys"
```

## Add a new agent on the manager

Run:

```powershell
wsl -d CBL-Mariner -u root --exec docker exec ossec-server /bin/sh -lc "cd /var/ossec && ./bin/manage_agents -a any -n HOST-LAPTOP"
```

### Add an agent with a specific IP

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\codex-workspace\ossec-main.ps1 -a -h HOST-PC -ip [IP_ADDRESS]
```

### Add an agent with any IP

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\codex-workspace\ossec-main.ps1 -a -h HOST-PC -ip any
```

Extract the key:

```powershell
wsl -d CBL-Mariner -u root --exec docker exec ossec-server /bin/sh -lc "cd /var/ossec && ./bin/manage_agents -e 003"
```

If you add a different agent ID, use that ID in the extract command.

Restart the manager after agent list changes:

```powershell
wsl --cd /opt/ossec-server -d CBL-Mariner -u root --exec /usr/bin/sh -c 'docker compose restart ossec-server'
```

## Install or rekey the Windows agent

The Windows helper script:

- stops `OssecSvc`
- imports the manager key from the OSSEC install directory
- updates `ossec.conf`
- starts `OssecSvc` again

Use the elevated wrapper:

```powershell
Start-Process PowerShell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File "D:\codex-workspace\run-ossec-host-rekey.ps1"'
```

Then accept the UAC prompt.

## Current Windows agent settings

The working manager address is:

- `172.25.219.81`

The Windows agent is currently configured for:

- server IP `172.25.219.81`
- port `1514`

Verify with:

```powershell
Get-Content 'C:\Program Files (x86)\ossec-agent\ossec.conf' | Select-String -Pattern '<server-ip>|<port>'
```

Check the Windows service:

```powershell
sc query OssecSvc
```

Check the Windows agent log:

```powershell
Get-Content 'C:\Program Files (x86)\ossec-agent\ossec.log' -Tail 120
```

The expected success signal is a line like:

```text
Connected to server 172.25.219.81, port 1514.
```

## Verify the manager sees the agent

Check agent state inside the container:

```powershell
wsl -d CBL-Mariner -u root --exec docker exec ossec-server /bin/sh -lc "ls -la /var/ossec/queue/agent-info"
```

Current healthy output includes:

- `HOST-LAPTOP-any`

## Monitoring `HOST-LAPTOP`

Community OSSEC is primarily managed from the CLI and its logs.

For day-to-day monitoring of `HOST-LAPTOP`, the useful places are:

- Windows agent log: `C:\Program Files (x86)\ossec-agent\ossec.log`
- Manager log in the container: `/var/ossec/logs/ossec.log`
- Manager alert files in the container: `/var/ossec/logs/alerts/alerts.log` and `/var/ossec/logs/alerts/alerts.json`
- Agent registration/runtime state in the container: `/var/ossec/queue/agent-info`

Useful commands:

```powershell
Get-Content 'C:\Program Files (x86)\ossec-agent\ossec.log' -Tail 120
```

```powershell
wsl -d CBL-Mariner -u root --exec docker exec ossec-server /bin/sh -lc "tail -n 120 /var/ossec/logs/ossec.log"
```

```powershell
wsl -d CBL-Mariner -u root --exec docker exec ossec-server /bin/sh -lc "tail -n 120 /var/ossec/logs/alerts/alerts.log"
```

If the image writes JSON alerts, this is better for downstream parsing:

```powershell
wsl -d CBL-Mariner -u root --exec docker exec ossec-server /bin/sh -lc "tail -n 120 /var/ossec/logs/alerts/alerts.json"
```

## Integrity checking for `HOST-LAPTOP`

OSSEC calls file integrity monitoring `syscheck`. Per the official docs, syscheck checks configured files for changes and also monitors Windows registry entries. See:

- [Syscheck docs](https://www.ossec.net/docs/manual/syscheck/index.html)
- [syscheck_control docs](https://www.ossec.net/docs/docs/programs/syscheck_control.html)

`HOST-LAPTOP` already has Windows syscheck enabled in `ossec.conf`. You can see the `<syscheck>` block and monitored Windows paths in:

- [C:/Program Files (x86)/ossec-agent/ossec.conf](C:/Program Files (x86)/ossec-agent/ossec.conf)

### What it is already doing

The current agent config is already monitoring:

- key Windows binaries and admin tools
- important registry locations
- the Windows Startup folder in realtime

### Trigger an integrity scan from the manager

The OSSEC syscheck docs say you can request a scan using `agent_control -r`.

For just `HOST-LAPTOP` (`003`):

```powershell
wsl -d CBL-Mariner -u root --exec docker exec ossec-server /bin/sh -lc "cd /var/ossec && ./bin/agent_control -r -u 003"
```

For all agents:

```powershell
wsl -d CBL-Mariner -u root --exec docker exec ossec-server /bin/sh -lc "cd /var/ossec && ./bin/agent_control -r -a"
```

### Review modified files and registry changes

The official `syscheck_control` tool can list tracked changes for an agent.

List available agents:

```powershell
wsl -d CBL-Mariner -u root --exec docker exec ossec-server /bin/sh -lc "cd /var/ossec && ./bin/syscheck_control -l"
```

Show changed files for `HOST-LAPTOP`:

```powershell
wsl -d CBL-Mariner -u root --exec docker exec ossec-server /bin/sh -lc "cd /var/ossec && ./bin/syscheck_control -i 003"
```

Show modified Windows registry entries for `HOST-LAPTOP`:

```powershell
wsl -d CBL-Mariner -u root --exec docker exec ossec-server /bin/sh -lc "cd /var/ossec && ./bin/syscheck_control -r -i 003"
```

If you want to reset the syscheck baseline for the host:

```powershell
wsl -d CBL-Mariner -u root --exec docker exec ossec-server /bin/sh -lc "cd /var/ossec && ./bin/syscheck_control -u 003"
```

or:

```powershell
wsl -d CBL-Mariner -u root --exec docker exec ossec-server /bin/sh -lc "cd /var/ossec && ./bin/syscheck_update -u 003"
```

### Practical monitoring workflow

For `HOST-LAPTOP`, a good basic workflow is:

1. Confirm the agent is connected.
2. Trigger a syscheck scan when you want an on-demand integrity pass.
3. Review `alerts.log` and `alerts.json` for file or registry alerts.
4. Use `syscheck_control -i 003` to inspect what changed.
5. If a change is expected, update the baseline or tune ignore rules.

## Daily logging automation

This workspace now includes a daily automation path for OSSEC monitoring artifacts.

### What runs every day

At `9:00 PM` local time (`GMT+8` on this laptop), the scheduled task:

- triggers an integrity scan for `HOST-LAPTOP`
- captures a tail of current OSSEC alerts
- captures current syscheck output
- copies the generated `.log` files to `D:\CBL-Mariner\ossec\`

### WSL log files

The WSL-side script writes to:

- `/var/logs/The Brain/OSSEC/integritycheck-MMDDYYYY.log`
- `/var/logs/The Brain/OSSEC/tailalerts-MMDDYYYY.log`
- `/var/logs/The Brain/OSSEC/syscheck-MMDDYYYY.log`

### Persistent Windows copy

Those files are copied to:

- `D:\CBL-Mariner\ossec\`

### Scripts

WSL-side script:

- [D:/codex-workspace/ossec-server/scripts/run-ossec-daily-logs.sh](D:/codex-workspace/ossec-server/scripts/run-ossec-daily-logs.sh)

Windows-side wrapper:

- [D:/codex-workspace/Run-OssecDailyLogs.ps1](D:/codex-workspace/Run-OssecDailyLogs.ps1)

Windows-side copy helper:

- [D:/codex-workspace/Copy-OssecLogs.ps1](D:/codex-workspace/Copy-OssecLogs.ps1)

### Scheduled task

The Windows Scheduled Task name is:

- `OSSEC-Daily-Logs`

Check it with:

```powershell
Get-ScheduledTask -TaskName 'OSSEC-Daily-Logs'
Get-ScheduledTaskInfo -TaskName 'OSSEC-Daily-Logs'
```

Run it manually:

```powershell
powershell -ExecutionPolicy Bypass -File D:\codex-workspace\Run-OssecDailyLogs.ps1
```

### Why this uses Windows scheduling instead of cron

The hardened `CBL-Mariner` WSL instance currently has no cron daemon installed and cannot directly write to `D:` because Windows drive automount is disabled.

So the practical implementation is:

- WSL script for OSSEC work and local log creation
- Windows Scheduled Task for reliable daily scheduling
- Windows-side copy step to persist logs on `D:\CBL-Mariner\ossec\`

## Web interface and dashboards

For the current community OSSEC setup, there is not a native free built-in GUI/dashboard in the same way people expect from a modern web console.

The official OSSEC pages currently position GUI/dashboard capability on the enhanced offerings:

- [OSSEC GUI and Dashboards](https://www.ossec.net/ossec-gui-dashboard/)
- [OSSEC downloads page](https://www.ossec.net/downloads.html)

Those pages explicitly describe:

- a web-based management console on the Atomic/OSSEC+ side
- ELK/OpenSearch-related capabilities on the enhanced offerings

So the practical answer is:

- Community OSSEC: CLI + logs + your own log shipping/dashboarding
- Atomic OSSEC / OSSEC+ offerings: official web-based management console and broader dashboard features

If you want a browser-based view for this lab, the usual path is to ship OSSEC alerts into a stack such as OpenSearch/ELK and build dashboards there.

## E-mail alerting for detected intrusions

The current manager is now wired for email alerting through a Docker sidecar relay:

- OSSEC `email_to`: `dummykevin08@gmail.com`
- OSSEC `smtp_server`: `postfix-relay`
- OSSEC `email_from`: `dummykevin08@gmail.com`
- OSSEC `email_alert_level`: `7`
- OSSEC `email_maxperhour`: `50`
- OSSEC immediate high-severity mail for `HOST-LAPTOP`: level `10+`

The relay container is:

- `juanluisbaptiste/postfix:latest`

It is configured from:

- [D:/codex-workspace/ossec-server/.env](D:/codex-workspace/ossec-server/.env)
- [D:/codex-workspace/ossec-server/.env.example](D:/codex-workspace/ossec-server/.env.example)

Important: upstream SMTP delivery still depends on valid provider credentials in:

- [D:/codex-workspace/ossec-server/.env](D:/codex-workspace/ossec-server/.env)

Official references:

- [Sending alerts via E-Mail](https://www.ossec.net/docs/docs/manual/output/email-output.html)
- [Alerts to a single E-Mail Address](https://www.ossec.net/docs/manual/output/standard-email-output.html)
- [Alerts FAQ](https://www.ossec.net/docs/docs/faq/alerts.html)
- [Daily E-Mail Reports](https://www.ossec.net/docs/docs/manual/output/reports-email-output.html)

### What is already configured

The manager config in WSL has already been updated with:

- a real recipient: `dummykevin08@gmail.com`
- Docker-network SMTP host: `postfix-relay`
- a higher per-hour cap: `50`
- immediate email alerts for high severity `HOST-LAPTOP` events
- daily built-in summary reports

The active manager config lives in WSL at:

- `/opt/ossec-server/data/etc/ossec.conf`

and OSSEC sees it inside the container as:

- `/var/ossec/etc/ossec.conf`

### Restart after mail config changes

```powershell
wsl --cd /opt/ossec-server -d CBL-Mariner -u root --exec /usr/bin/sh -c 'docker compose restart postfix-relay ossec-server'
```

### Recommended alerting threshold

Start with:

- `email_alert_level` = `7`

That usually catches meaningful alerts without mailing every low-level event.

If you want fewer emails:

- raise it to `10`

If you want more aggressive notification:

- lower it to `5`

### Avoid missing alerts because of rate limiting

Right now the manager is configured with:

- `email_maxperhour = 1`

That is too low for practical monitoring. Increase it to something like:

- `25`
- `50`
- or `100`

depending on how noisy you want the system to be.

### Granular e-mail alerts

OSSEC also supports more targeted email notifications, including alerts by severity, rule, group, or agent. That is useful if you only want messages for `HOST-LAPTOP`, syscheck/FIM events, or very high severity alerts.

Typical use cases:

- send all alerts above level `10` to your main inbox
- send only file integrity alerts to a security mailbox
- send only `HOST-LAPTOP` alerts to a test inbox

The official docs call this "Granular Notifications" and document it here:

- [Sending alerts via E-Mail](https://www.ossec.net/docs/docs/manual/output/email-output.html)

### Daily summary emails

If you do not want immediate per-alert messages only, OSSEC can also send daily reports.

Useful examples from the official docs:

- daily authentication summaries
- daily file integrity (`syscheck`) summaries

That is documented here:

- [Daily E-Mail Reports](https://www.ossec.net/docs/docs/manual/output/reports-email-output.html)

### Daily summary status

The manager is already configured with built-in OSSEC daily reports for:

- `syscheck` file integrity changes
- all high severity alerts at level `10+`

This uses OSSEC's native daily reporting support from `ossec.conf`.

### About the "cronjob" request

I used OSSEC's built-in daily report scheduler instead of an external cron daemon.

Why:

- this `CBL-Mariner` image currently has no cron service installed
- OSSEC already has first-class daily email report support
- using the native reports path is simpler and closer to the official OSSEC documentation

If you still want an external scheduler later, the best next step would be a Windows Scheduled Task or a separate scheduler container, not patching cron into the minimal WSL base.

### Practical monitoring plan for this setup

For `HOST-LAPTOP`, a simple good setup is:

1. Keep immediate alert emails enabled for severity `7+`.
2. Raise `email_maxperhour` so bursts are not dropped.
3. Add a daily `syscheck` report for file integrity changes.
4. Continue using `alerts.log` and `alerts.json` for detailed investigation.

### Important limitation

OSSEC itself can send mail, but whether the message reaches your inbox depends on SMTP delivery.

In practice you usually want one of these:

- a reachable SMTP relay such as your mail provider or internal mail gateway
- a Postfix relay sidecar that forwards to a real mail server

In this workspace, the Postfix sidecar is already in place. The remaining requirement is a valid upstream SMTP credential.

## Common issues

### `manage_agents: ERROR: Could not open file '/etc/client.keys'`

Cause:

- `manage_agents` was run from the wrong working directory, or the manager data tree was not initialized yet.

Fix:

- run it as `cd /var/ossec && ./bin/manage_agents ...`
- restart the container and let it initialize `data/etc`, `data/rules`, `data/logs`, `data/stats`, and `data/queue`

### `manage_agents: ERROR: Cannot unlink rids/sender`

Cause:

- stale manager runtime state in the persistent OSSEC data tree

Fix:

- inspect and repair the manager data directory before changing base images
- do not downgrade to `debian:9` just for this error

### Windows agent connects but waits forever for server reply

Cause:

- manager address was set to `127.0.0.1`, but the Windows-to-WSL UDP path did not complete over localhost

Fix:

- point the Windows agent to the WSL distro IP instead
- in this setup, the working address was `172.25.219.81`

## Notes

- The WSL IP may change after a reboot or WSL restart. If that happens, update [D:/codex-workspace/run-ossec-host-rekey.ps1](D:/codex-workspace/run-ossec-host-rekey.ps1) and rerun it elevated.
- The container still logs some non-fatal warnings from the older Atomic image, but agent registration and manager communication are working.


