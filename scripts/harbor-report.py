#!/usr/bin/env python3
"""Render Harbor vulnerability JSON as per-image Markdown and HTML reports."""

import argparse
import html
import json
from pathlib import Path


def find_vulnerabilities(report):
    if isinstance(report, list):
        return report
    if isinstance(report, dict):
        for key in ("vulnerabilities", "vulns", "results"):
            value = report.get(key)
            if isinstance(value, list):
                return value
        for value in report.values():
            if isinstance(value, dict):
                found = find_vulnerabilities(value)
                if found:
                    return found
    return []


def field(item, *names):
    for name in names:
        value = item.get(name)
        if value is not None:
            return str(value).replace("\n", " ").strip()
    return ""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()

    report = json.loads(args.input.read_text(encoding="utf-8"))
    vulnerabilities = find_vulnerabilities(report)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    title = f"{args.repository}:{args.tag}"
    rows = []
    for vuln in vulnerabilities:
        if not isinstance(vuln, dict):
            continue
        rows.append([
            field(vuln, "cve_id", "id", "vulnerability_id"),
            field(vuln, "severity"),
            field(vuln, "package", "pkg_name", "name"),
            field(vuln, "version", "installed_version"),
            field(vuln, "fixed_version", "fixedVersion", "fix_version"),
            field(vuln, "desc", "description", "title"),
        ])

    headers = ["CVE", "Severity", "Package", "Installed", "Fixed in", "Description"]
    markdown = [f"# Harbor vulnerability report: {title}", "", f"Vulnerabilities found: **{len(rows)}**", ""]
    markdown.append("| " + " | ".join(headers) + " |")
    markdown.append("| " + " | ".join(["---"] * len(headers)) + " |")
    for row in rows:
        markdown.append("| " + " | ".join(value.replace("|", "\\|") for value in row) + " |")
    if not rows:
        markdown.append("| No vulnerabilities reported | | | | | |")
    (args.output_dir / f"{args.repository}.md").write_text("\n".join(markdown) + "\n", encoding="utf-8")

    html_rows = "\n".join(
        "<tr>" + "".join(f"<td>{html.escape(value)}</td>" for value in row) + "</tr>"
        for row in rows
    ) or '<tr><td colspan="6">No vulnerabilities reported</td></tr>'
    page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Harbor vulnerability report: {html.escape(title)}</title>
<style>body{{font:16px system-ui,sans-serif;margin:2rem;color:#202124}}table{{border-collapse:collapse;width:100%}}th,td{{border:1px solid #bbb;padding:.5rem;text-align:left;vertical-align:top}}th{{background:#eee}}td:last-child{{min-width:20rem}}</style>
</head><body><h1>Harbor vulnerability report: {html.escape(title)}</h1>
<p>Vulnerabilities found: <strong>{len(rows)}</strong></p>
<table><thead><tr>{''.join(f'<th>{header}</th>' for header in headers)}</tr></thead><tbody>{html_rows}</tbody></table>
</body></html>
"""
    (args.output_dir / f"{args.repository}.html").write_text(page, encoding="utf-8")


if __name__ == "__main__":
    main()
