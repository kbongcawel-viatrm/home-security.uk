#!/usr/bin/env python3
"""Compare published-image CVEs with the initial Harbor scan baseline."""

import argparse
import json
from pathlib import Path


SEVERITY_RANK = {
    "CRITICAL": 0,
    "HIGH": 1,
    "MEDIUM": 2,
    "LOW": 3,
    "NEGLIGIBLE": 4,
    "UNKNOWN": 5,
}
HIGH_SEVERITIES = {"CRITICAL", "HIGH"}


def load_findings(path, repositories):
    report = json.loads(path.read_text(encoding="utf-8"))
    findings = {}
    for item in report.get("findings", []):
        repository = str(item.get("repository", ""))
        if repository not in repositories:
            continue
        key = (
            repository,
            str(item.get("cve", "")),
            str(item.get("package", "")),
        )
        finding = {**item, "severity": str(item.get("severity", "UNKNOWN")).upper()}
        current = findings.get(key)
        if current is None or SEVERITY_RANK.get(finding["severity"], 5) < SEVERITY_RANK.get(current["severity"], 5):
            findings[key] = finding
    return findings


def records(findings, keys):
    return [findings[key] for key in sorted(keys)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--verification", required=True, type=Path)
    parser.add_argument("--repositories-file", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--unresolved-list", required=True, type=Path)
    parser.add_argument("--registry", required=True)
    parser.add_argument("--project", required=True)
    args = parser.parse_args()

    repositories = {
        line.strip()
        for line in args.repositories_file.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }
    baseline = load_findings(args.baseline, repositories)
    verification = load_findings(args.verification, repositories)
    baseline_high = {
        key for key, item in baseline.items() if item["severity"] in HIGH_SEVERITIES
    }
    verification_high = {
        key for key, item in verification.items() if item["severity"] in HIGH_SEVERITIES
    }

    remaining = baseline_high & verification_high
    resolved = baseline_high - verification_high
    new_high = verification_high - baseline_high
    resolved_all = baseline.keys() - verification.keys()
    new_all = verification.keys() - baseline.keys()
    severity_changes = [
        {
            "repository": key[0],
            "cve": key[1],
            "package": key[2],
            "baseline_severity": baseline[key]["severity"],
            "verification_severity": verification[key]["severity"],
        }
        for key in sorted(baseline.keys() & verification.keys())
        if baseline[key]["severity"] != verification[key]["severity"]
    ]
    unresolved_repositories = sorted({key[0] for key in remaining | new_high})
    verification_report = json.loads(args.verification.read_text(encoding="utf-8"))
    verification_tag = str(verification_report.get("image_tag", ""))
    unresolved_images = [
        f"{args.registry}/{args.project}/{repository}:{verification_tag}"
        for repository in unresolved_repositories
    ]

    result = {
        "status": "passed" if not remaining and not new_high else "failed",
        "repositories": sorted(repositories),
        "summary": {
            "baseline_findings": len(baseline),
            "verification_findings": len(verification),
            "baseline_high_critical": len(baseline_high),
            "verification_high_critical": len(verification_high),
            "resolved_high_critical": len(resolved),
            "remaining_high_critical": len(remaining),
            "new_high_critical": len(new_high),
            "resolved_findings": len(resolved_all),
            "new_findings": len(new_all),
        },
        "resolved_findings": records(baseline, resolved_all),
        "new_findings": records(verification, new_all),
        "resolved_high_critical": records(baseline, resolved),
        "remaining_high_critical": records(verification, remaining),
        "new_high_critical": records(verification, new_high),
        "unresolved_images": unresolved_images,
        "severity_changes": severity_changes,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    args.unresolved_list.parent.mkdir(parents=True, exist_ok=True)
    args.unresolved_list.write_text("".join(image + "\n" for image in unresolved_images), encoding="utf-8")
    print(json.dumps(result["summary"], sort_keys=True))


if __name__ == "__main__":
    main()
