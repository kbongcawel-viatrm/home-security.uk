#!/usr/bin/env python3
"""Add fix availability and reported exploitability to a Harbor remediation plan."""

import argparse
import json
from pathlib import Path
import re


SEVERITY_RANK = {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3, "NEGLIGIBLE": 4, "UNKNOWN": 5}
CVE_KEYS = {"cve", "cveid", "id", "vulnerabilityid"}
EXPLOIT_KEYS = {
    "exploit", "exploitable", "exploitavailable", "exploitexists",
    "knownexploited", "inkev", "kev",
}
FIXED_KEYS = {"fixedversion", "fixedin", "fixversion", "fixed_version"}


def normalized(value):
    return re.sub(r"[^a-z0-9]", "", value.casefold())


def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def vulnerability_key(item):
    key_map = {normalized(str(key)): value for key, value in item.items()}
    cve = next((key_map[key] for key in CVE_KEYS if key in key_map), None)
    package = key_map.get("packagename", key_map.get("pkgname", key_map.get("package")))
    if cve is None or package is None:
        return None
    return str(cve).upper(), str(package).casefold()


def reported_exploitability(item):
    for record in walk(item):
        for key, value in record.items():
            if normalized(str(key)) in EXPLOIT_KEYS:
                if isinstance(value, bool):
                    return "exploitable" if value else "not-reported-exploitable"
                if str(value).casefold() in ("true", "yes", "available", "known", "1"):
                    return "exploitable"
                if str(value).casefold() in ("false", "no", "none", "0"):
                    return "not-reported-exploitable"
    return "unknown"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--findings", required=True, type=Path)
    parser.add_argument("--raw-report", required=True, type=Path)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--image-ref", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    consolidated = json.loads(args.findings.read_text(encoding="utf-8"))
    raw_report = json.loads(args.raw_report.read_text(encoding="utf-8"))
    raw_vulnerabilities = {}
    for item in walk(raw_report):
        key = vulnerability_key(item)
        if key:
            raw_vulnerabilities[key] = item

    findings = []
    for finding in consolidated.get("findings", []):
        if finding.get("repository") != args.repository:
            continue
        key = (str(finding.get("cve", "")).upper(), str(finding.get("package", "")).casefold())
        raw = raw_vulnerabilities.get(key, {})
        exploitability = reported_exploitability(raw) if raw else "unknown"
        fixed_in = str(finding.get("fixed_in", "")).strip()
        finding = {
            **finding,
            "exploitability": exploitability,
            "fix_available": bool(fixed_in),
            "priority": {
                "severity_rank": SEVERITY_RANK.get(str(finding.get("severity", "UNKNOWN")).upper(), 5),
                "exploitable_reported": exploitability == "exploitable",
                "fix_available": bool(fixed_in),
            },
        }
        findings.append(finding)

    findings.sort(key=lambda item: (
        item["priority"]["severity_rank"],
        not item["priority"]["exploitable_reported"],
        not item["priority"]["fix_available"],
        str(item.get("cve", "")),
        str(item.get("package", "")),
    ))
    result = {
        "schema_version": 1,
        "image_ref": args.image_ref,
        "repository": args.repository,
        "base_image_update": {
            "proposal": "none",
            "reason": "Harbor vulnerability findings do not identify a safe parent-image replacement.",
        },
        "priority_order": ["severity", "reported exploitability", "fix availability"],
        "exploitability_note": "Exploitability is marked unknown when the Harbor Trivy report has no explicit exploit indicator.",
        "findings": findings,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(f"Created remediation review plan with {len(findings)} findings.")


if __name__ == "__main__":
    main()
