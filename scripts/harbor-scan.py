#!/usr/bin/env python3
"""Request Harbor-managed Trivy vulnerability and SBOM scans by immutable digest."""

import argparse
import base64
import json
import os
import sys
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen


VULNERABILITY_MIME = "application/vnd.security.vulnerability.report; version=1.1"
SBOM_MIME = "application/vnd.security.sbom.report+json; version=1.0"


class HarborClient:
    def __init__(self, api_base):
        username = os.environ["HARBOR_USERNAME"]
        password = os.environ["HARBOR_PASSWORD"]
        token = base64.b64encode(f"{username}:{password}".encode()).decode()
        self.api_base = api_base.rstrip("/")
        self.authorization = f"Basic {token}"

    def request(self, url, method="GET", body=None, headers=None, accepted=(200,)):
        request_headers = {"Authorization": self.authorization}
        if headers:
            request_headers.update(headers)
        data = None
        if body is not None:
            request_headers["Content-Type"] = "application/json"
            data = json.dumps(body).encode()
        request = Request(url, data=data, headers=request_headers, method=method)
        try:
            with urlopen(request, timeout=60) as response:
                status = response.status
                payload = response.read()
        except HTTPError as error:
            status = error.code
            payload = error.read()
        except URLError as error:
            raise RuntimeError(f"Harbor request failed: {error}") from error
        if status not in accepted:
            detail = payload.decode(errors="replace")[:1000]
            raise RuntimeError(f"Harbor API returned HTTP {status}: {detail}")
        return status, payload


def report_status(overview, kind):
    if kind == "sbom":
        summaries = (overview or {}).get("sbom_overview", {})
        if "scan_status" in summaries:
            return str(summaries["scan_status"])
        for mime_type, summary in summaries.items():
            if "sbom" in mime_type.lower():
                return str(summary.get("scan_status", "Pending"))
        return "Pending"
    entries = (overview or {}).get("scan_overview", {})
    for mime_type, summary in entries.items():
        if kind in mime_type.lower():
            return str(summary.get("scan_status", "Pending"))
    return "Pending"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--api-base", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--digest", required=True)
    parser.add_argument("--fetch-only", action="store_true")
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()

    client = HarborClient(args.api_base)
    artifact = (
        f"{client.api_base}/projects/{quote(args.project, safe='')}"
        f"/repositories/{quote(args.repository, safe='')}"
        f"/artifacts/{quote(args.digest, safe='')}"
    )

    if not args.fetch_only:
        for scan_type in ("vulnerability", "sbom"):
            status, _ = client.request(
                f"{artifact}/scan",
                method="POST",
                body={"scan_type": scan_type},
                accepted=(200, 202, 409),
            )
            if status == 409:
                print(f"Harbor already has a {scan_type} scan in progress for {args.digest}.")
            else:
                print(f"Requested Harbor {scan_type} scan for {args.repository}@{args.digest}.")

        overview_url = f"{artifact}?with_scan_overview=true&with_sbom_overview=true"
        overview_headers = {"X-Accept-Vulnerabilities": f"{VULNERABILITY_MIME}, {SBOM_MIME}"}
        deadline = time.monotonic() + 600
        while time.monotonic() < deadline:
            _, payload = client.request(overview_url, headers=overview_headers)
            try:
                overview = json.loads(payload)
            except json.JSONDecodeError:
                overview = {}

            vulnerability_status = report_status(overview, "vulnerability")
            sbom_status = report_status(overview, "sbom")
            states = {"vulnerability": vulnerability_status, "sbom": sbom_status}
            print(f"{args.repository}@{args.digest}: {states}")
            failed = [name for name, state in states.items() if state.lower() in ("error", "stopped", "failed")]
            if failed:
                raise RuntimeError(f"Harbor scan failed for {', '.join(failed)}: {states}")
            if all(state.lower() in ("success", "completed") for state in states.values()):
                break
            time.sleep(10)
        else:
            raise TimeoutError(f"Timed out waiting for Harbor scans: {args.repository}@{args.digest}")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    report_headers = {"X-Accept-Vulnerabilities": VULNERABILITY_MIME, "Accept": "application/json"}
    _, vulnerability_json = client.request(f"{artifact}/additions/vulnerabilities", headers=report_headers)
    vulnerability_path = args.output_dir / f"{args.repository}.json"
    vulnerability_path.write_bytes(vulnerability_json)

    sbom_headers = {"Accept": SBOM_MIME}
    _, sbom_json = client.request(f"{artifact}/additions/sbom", headers=sbom_headers)
    (args.output_dir / f"{args.repository}-sbom.json").write_bytes(sbom_json)

    import subprocess

    subprocess.run(
        [
            sys.executable,
            str(Path(__file__).with_name("harbor-report.py")),
            "--repository", args.repository,
            "--tag", args.tag,
            "--digest", args.digest,
            "--input", str(vulnerability_path),
            "--output-dir", str(args.output_dir),
        ],
        check=True,
    )


if __name__ == "__main__":
    main()
