#!/usr/bin/env python3
"""Reconcile hq-sec-stack desired monitors into Uptime Kuma.

The script intentionally exits successfully when credentials are missing so the
monitor profile can start before the operator completes the first Kuma setup.
"""

from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path


MONITORS_PATH = Path("/uptime-kuma/monitors.yml")


def install_deps() -> None:
    subprocess.check_call(
        [sys.executable, "-m", "pip", "install", "--no-cache-dir", "uptime-kuma-api", "PyYAML"],
        stdout=sys.stdout,
        stderr=sys.stderr,
    )


def normalize_status_codes(values: object) -> list[str]:
    if not values:
        return ["200-299"]
    if isinstance(values, str):
        return [values]
    return [str(value) for value in values]


def monitor_payload(monitor: dict, defaults: dict) -> dict:
    monitor_type = monitor["type"]
    payload = {
        "type": monitor_type,
        "name": monitor["name"],
        "interval": int(monitor.get("interval", defaults.get("interval", 60))),
        "retryInterval": int(monitor.get("retry_interval", defaults.get("retry_interval", 60))),
        "maxretries": int(monitor.get("max_retries", defaults.get("max_retries", 3))),
    }

    if monitor_type == "http":
        payload["url"] = monitor["url"]
        payload["accepted_statuscodes"] = normalize_status_codes(monitor.get("accepted_statuscodes"))
        if monitor.get("ignore_tls"):
            payload["ignoreTls"] = True
    elif monitor_type == "port":
        payload["hostname"] = monitor["host"]
        payload["port"] = int(monitor["port"])
    elif monitor_type == "ping":
        payload["hostname"] = monitor["host"]
    else:
        raise ValueError(f"unsupported monitor type for {monitor['name']}: {monitor_type}")

    return payload


def sync_once() -> None:
    import yaml
    from uptime_kuma_api import UptimeKumaApi

    url = os.environ.get("UPTIME_KUMA_URL", "http://uptime-kuma:3001")
    username = os.environ.get("UPTIME_KUMA_USERNAME", "")
    password = os.environ.get("UPTIME_KUMA_PASSWORD", "")

    if not username or not password:
        print("UPTIME_KUMA_USERNAME and UPTIME_KUMA_PASSWORD must be populated; skipping monitor sync until Kuma setup is complete.")
        return

    desired = yaml.safe_load(MONITORS_PATH.read_text(encoding="utf-8"))
    defaults = desired.get("defaults", {})
    monitors = desired.get("monitors", [])

    api = UptimeKumaApi(url)
    api.login(username, password)

    existing = {monitor["name"]: monitor for monitor in api.get_monitors()}
    for monitor in monitors:
        payload = monitor_payload(monitor, defaults)
        if monitor["name"] in existing:
            monitor_id = existing[monitor["name"]]["id"]
            print(f"Updating monitor: {monitor['name']}")
            api.edit_monitor(monitor_id, **payload)
        else:
            print(f"Adding monitor: {monitor['name']}")
            api.add_monitor(**payload)

    api.disconnect()


def main() -> int:
    run_on_startup = os.environ.get("UPTIME_KUMA_SYNC_RUN_ON_STARTUP", "true").lower() == "true"
    interval = int(os.environ.get("UPTIME_KUMA_SYNC_INTERVAL_SECONDS", "21600"))

    install_deps()

    if run_on_startup:
        sync_once()

    while interval > 0:
        time.sleep(interval)
        sync_once()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
