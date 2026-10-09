#!/usr/bin/env python3
"""Combine Harbor vulnerability reports and sort findings by severity."""

import argparse
from collections import Counter
from datetime import datetime, timezone
from html.parser import HTMLParser
import json
from pathlib import Path


SEVERITY_ORDER = {
    "CRITICAL": 0,
    "HIGH": 1,
    "MEDIUM": 2,
    "LOW": 3,
    "NEGLIGIBLE": 4,
    "UNKNOWN": 5,
}


class ReportTableParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.rows = []
        self.row = None
        self.cell = None

    def handle_starttag(self, tag, attrs):
        if tag == "tr":
            self.row = []
        elif tag in ("th", "td") and self.row is not None:
            self.cell = []

    def handle_data(self, data):
        if self.cell is not None:
            self.cell.append(data)

    def handle_endtag(self, tag):
        if tag in ("th", "td") and self.cell is not None:
            self.row.append(" ".join(" ".join(self.cell).split()))
            self.cell = None
        elif tag == "tr" and self.row is not None:
            self.rows.append(self.row)
            self.row = None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reports-dir", required=True, type=Path)
    parser.add_argument("--repositories-file", required=True, type=Path)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--remediation-output", required=True, type=Path)
    args = parser.parse_args()

    repositories = [
        line.strip()
        for line in args.repositories_file.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    missing = []
    findings = []

    for repository in repositories:
        artifact_name = repository.replace("/", "_")
        report_path = args.reports_dir / f"{artifact_name}.html"
        if not report_path.is_file():
            missing.append(repository)
            continue

        parser = ReportTableParser()
        parser.feed(report_path.read_text(encoding="utf-8"))
        rows = parser.rows[1:]
        for row in rows:
            if not row or row[0] == "No vulnerabilities reported":
                continue
            row.extend([""] * (6 - len(row)))
            cve, raw_severity, package, installed, fixed_in, description = row[:6]
            severity = raw_severity.upper() or "UNKNOWN"
            findings.append({
                "repository": repository,
                "image_tag": args.tag,
                "cve": cve,
                "severity": severity,
                "package": package,
                "installed_version": installed,
                "fixed_in": fixed_in,
                "description": description,
            })

    if missing:
        raise SystemExit("Missing per-image vulnerability reports: " + ", ".join(missing))

    findings.sort(key=lambda item: (
        SEVERITY_ORDER.get(item["severity"], SEVERITY_ORDER["UNKNOWN"]),
        item["repository"].casefold(),
        item["cve"].casefold(),
        item["package"].casefold(),
    ))
    counts = Counter(item["severity"] for item in findings)
    ordered_counts = {
        severity: counts[severity]
        for severity in SEVERITY_ORDER
        if counts[severity]
    }
    ordered_counts.update({
        severity: count
        for severity, count in sorted(counts.items())
        if severity not in SEVERITY_ORDER
    })

    result = {
        "schema_version": 1,
        "image_tag": args.tag,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "image_count": len(repositories),
            "finding_count": len(findings),
            "by_severity": ordered_counts,
        },
        "findings": findings,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    remediation = {
        "schema_version": 1,
        "image_tag": args.tag,
        "severity_threshold": ["CRITICAL", "HIGH"],
        "findings": [
            finding
            for finding in findings
            if finding["severity"] in ("CRITICAL", "HIGH")
        ],
    }
    args.remediation_output.parent.mkdir(parents=True, exist_ok=True)
    args.remediation_output.write_text(
        json.dumps(remediation, indent=2) + "\n", encoding="utf-8"
    )
    print(f"Consolidated {len(findings)} findings from {len(repositories)} images.")
    print("Severity counts: " + json.dumps(ordered_counts, sort_keys=False))


if __name__ == "__main__":
    main()
