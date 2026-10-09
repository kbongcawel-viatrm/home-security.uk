#!/usr/bin/env python3
"""Scan Harbor images in parallel and render their vulnerability reports."""

import argparse
import base64
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--api-base", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--repositories-file", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--parallel", type=int, default=5)
    args = parser.parse_args()

    username = os.environ["HARBOR_USERNAME"]
    password = os.environ["HARBOR_PASSWORD"]
    token = base64.b64encode(f"{username}:{password}".encode()).decode()
    authorization = f"Basic {token}"
    api_base = args.api_base.rstrip("/")
    args.output_dir.mkdir(parents=True, exist_ok=True)

    repositories = [
        line.strip()
        for line in args.repositories_file.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    serial_names = {"ghost", "ghost-model-pull"}
    parallel_repositories = [repo for repo in repositories if repo not in serial_names]
    serial_repositories = [repo for repo in repositories if repo in serial_names]

    def request(url, method="GET", headers=None, accepted=(200,)):
        request_headers = {"Authorization": authorization}
        if headers:
            request_headers.update(headers)
        request = Request(url, headers=request_headers, method=method)
        try:
            with urlopen(request, timeout=60) as response:
                status, payload = response.status, response.read()
        except HTTPError as error:
            status, payload = error.code, error.read()
        except URLError as error:
            raise RuntimeError(f"Harbor request failed: {error}") from error
        if status not in accepted:
            detail = payload.decode(errors="replace")[:1000]
            if status in (401, 403):
                raise RuntimeError(
                    "Harbor denied the request. Confirm the Actions account has "
                    f"Read Artifact and Create Scan permissions on {args.project}. "
                    f"HTTP {status}: {detail}"
                )
            raise RuntimeError(f"Harbor API returned HTTP {status}: {detail}")
        return status, payload

    def encoded(value):
        return quote(value, safe="")

    def overview_url(artifact):
        return f"{artifact}?with_scan_overview=true"

    def vulnerability_summary(overview):
        for mime_type, summary in (overview.get("scan_overview") or {}).items():
            if "vulnerability" in mime_type.lower():
                return summary
        return {}

    def scan_repository(repository):
        base = (
            f"{api_base}/projects/{encoded(args.project)}"
            f"/repositories/{encoded(repository)}/artifacts"
        )
        _, artifact_payload = request(f"{base}/{encoded(args.tag)}")
        digest = json.loads(artifact_payload).get("digest")
        if not isinstance(digest, str) or not digest:
            raise RuntimeError(f"Harbor returned no digest for {repository}:{args.tag}")
        artifact = f"{base}/{encoded(digest)}"

        _, before_payload = request(overview_url(artifact))
        before_summary = vulnerability_summary(json.loads(before_payload))
        previous_time = before_summary.get("end_time") or before_summary.get("complete_time", "")

        print(f"Resolved {repository}:{args.tag} to {digest}", flush=True)
        request(f"{artifact}/scan", method="POST", accepted=(200, 202, 409))

        for attempt in range(1, 61):
            try:
                _, status_payload = request(overview_url(artifact))
                summary = vulnerability_summary(json.loads(status_payload))
                state = str(summary.get("scan_status", "")).lower()
                completion_time = str(summary.get("end_time") or summary.get("complete_time", ""))
            except (RuntimeError, json.JSONDecodeError) as error:
                print(f"{repository}: status query failed ({attempt}/60): {error}", flush=True)
                time.sleep(10)
                continue

            if state in ("error", "stopped", "failed"):
                raise RuntimeError(f"Harbor scan failed for {repository}@{digest}: {state}")
            if state in ("success", "completed") and (
                not previous_time or (completion_time and completion_time != previous_time)
            ):
                break
            print(f"{repository}: status={state or 'pending'} ({attempt}/60)", flush=True)
            time.sleep(10)
        else:
            raise TimeoutError(f"Timed out scanning {repository}@{digest}")

        artifact_name = repository.replace("/", "_")
        report_path = args.output_dir / f"{artifact_name}.json"
        _, report = request(
            f"{artifact}/additions/vulnerabilities",
            headers={
                "Accept": "application/json",
                "X-Accept-Vulnerabilities":
                    "application/vnd.security.vulnerability.report; version=1.1",
            },
        )
        report_path.write_bytes(report)
        subprocess.run(
            [
                sys.executable,
                "scripts/harbor-report.py",
                "--repository", repository,
                "--tag", args.tag,
                "--input", str(report_path),
                "--output-dir", str(args.output_dir),
            ],
            check=True,
        )
        print(f"Report generated for {repository}@{digest}", flush=True)

    failures = []
    with ThreadPoolExecutor(max_workers=args.parallel) as executor:
        futures = {executor.submit(scan_repository, repo): repo for repo in parallel_repositories}
        for future in as_completed(futures):
            repository = futures[future]
            try:
                future.result()
            except Exception as error:  # Collect every worker failure before stopping.
                failures.append((repository, error))

    for repository in serial_repositories:
        try:
            scan_repository(repository)
        except Exception as error:
            failures.append((repository, error))

    if failures:
        for repository, error in failures:
            print(f"{repository}: {error}", file=sys.stderr)
        raise SystemExit(f"{len(failures)} Harbor image scan(s) failed.")

    print(f"Completed scans for {len(repositories)} repositories.")


if __name__ == "__main__":
    main()
