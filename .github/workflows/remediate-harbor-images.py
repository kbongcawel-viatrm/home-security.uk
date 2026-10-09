#!/usr/bin/env python3
"""Build, validate, and publish fixed Harbor images in separate workflow stages."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys


PACKAGE_TOKEN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.+:_~-]*$")
IMAGE_TAG = re.compile(r"^(v)?([0-9]+)\.([0-9]+)$")
USER_TOKEN = re.compile(r"^[A-Za-z0-9_.:-]+$")


def run(command, *, capture=False):
    display = " ".join(str(part) for part in command)
    print("+ " + display, flush=True)
    return subprocess.run(
        [str(part) for part in command],
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def next_tag(source_tag):
    match = IMAGE_TAG.fullmatch(source_tag)
    if not match:
        raise ValueError(
            f"Automatic tag increment requires a numeric major.minor tag, got {source_tag!r}."
        )
    prefix, major, minor = match.groups()
    return f"{prefix or ''}{major}.{int(minor) + 1}"


def make_plan(report_path, repositories_path, source_tag):
    allowed_repositories = {
        line.strip()
        for line in repositories_path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }
    report = json.loads(report_path.read_text(encoding="utf-8"))
    grouped = {}
    unresolved = []

    for finding in report.get("findings", []):
        severity = str(finding.get("severity", "")).upper()
        if severity not in ("CRITICAL", "HIGH"):
            continue
        repository = str(finding.get("repository", ""))
        package = str(finding.get("package", "")).strip()
        fixed_in = str(finding.get("fixed_in", "")).strip()
        if repository not in allowed_repositories:
            raise ValueError(f"Finding references unlisted Harbor repository {repository!r}.")
        if not package or not fixed_in:
            unresolved.append(
                f"{repository} {finding.get('cve', '')}: missing package or Fixed In version"
            )
            continue
        if not PACKAGE_TOKEN.fullmatch(package) or not PACKAGE_TOKEN.fullmatch(fixed_in):
            unresolved.append(
                f"{repository} {finding.get('cve', '')}: unsupported package/version "
                f"{package!r}={fixed_in!r}"
            )
            continue
        packages = grouped.setdefault(repository, {})
        previous = packages.get(package)
        if previous and previous != fixed_in:
            unresolved.append(
                f"{repository} {package}: conflicting Fixed In versions "
                f"{previous!r} and {fixed_in!r}"
            )
        else:
            packages[package] = fixed_in

    if unresolved:
        raise ValueError(
            "Cannot safely rebuild all High/Critical findings:\n- "
            + "\n- ".join(unresolved)
        )

    return [
        {
            "repository": repository,
            "service": repository,
            "packages": [
                {"name": package, "version": version}
                for package, version in sorted(packages.items())
            ],
        }
        for repository, packages in sorted(grouped.items())
    ]


def dockerfile_for(base_image, packages, original_user):
    apt_args = " ".join(f"{item['name']}={item['version']}" for item in packages)
    rpm_args = " ".join(f"{item['name']}-{item['version']}" for item in packages)
    install = (
        "if command -v apt-get >/dev/null 2>&1; then "
        "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "
        "--no-install-recommends --only-upgrade " + apt_args + " && "
        "rm -rf /var/lib/apt/lists/*; "
        "elif command -v apk >/dev/null 2>&1; then "
        "apk add --no-cache " + apt_args + "; "
        "elif command -v dnf >/dev/null 2>&1; then "
        "dnf install -y " + rpm_args + " && dnf clean all; "
        "elif command -v microdnf >/dev/null 2>&1; then "
        "microdnf install -y " + rpm_args + " && microdnf clean all; "
        "elif command -v yum >/dev/null 2>&1; then "
        "yum install -y " + rpm_args + " && yum clean all; "
        "else echo 'No supported OS package manager found' >&2; exit 1; fi"
    )
    lines = [f"FROM {base_image}", "USER 0", f"RUN set -eux; {install}"]
    if original_user:
        lines.append(f"USER {original_user}")
    return "\n".join(lines) + "\n"


def dockerfile_build(args):
    candidates = make_plan(args.report, args.repositories_file, args.source_tag)
    candidate_tag = f"candidate-{args.run_id}"
    args.bundle_dir.mkdir(parents=True, exist_ok=True)
    compose_result = run(
        [
            "docker", "compose", "--env-file", args.compose_env_file,
            "-f", args.compose_file, "config", "--format", "json",
        ],
        capture=True,
    )
    compose_services = json.loads(compose_result.stdout).get("services", {})
    override = {"services": {}}
    service_names = []
    candidate_images = []
    manifest_repositories = []

    for item in candidates:
        repository = item["repository"]
        service = item["service"]
        if service not in compose_services:
            raise ValueError(
                f"No Compose service named {service!r}; cannot validate its rebuilt image."
            )
        source_image = f"{args.registry}/{args.project}/{repository}:{args.source_tag}"
        candidate_image = f"{args.registry}/{args.project}/{repository}:{candidate_tag}"
        run(["docker", "pull", source_image])
        inspected = run(["docker", "image", "inspect", source_image], capture=True)
        config = json.loads(inspected.stdout)[0].get("Config") or {}
        original_user = str(config.get("User") or "")
        if original_user and not USER_TOKEN.fullmatch(original_user):
            raise ValueError(f"Unsupported image user {original_user!r} in {source_image}.")

        context = args.bundle_dir / "contexts" / repository.replace("/", "_")
        context.mkdir(parents=True, exist_ok=True)
        (context / "Dockerfile").write_text(
            dockerfile_for(source_image, item["packages"], original_user),
            encoding="utf-8",
        )
        override["services"][service] = {
            "image": candidate_image,
            "build": {"context": str(context), "dockerfile": "Dockerfile"},
        }
        service_names.append(service)
        candidate_images.append(candidate_image)
        manifest_repositories.append({
            **item,
            "source_image": source_image,
            "candidate_image": candidate_image,
        })

    override_path = args.bundle_dir / "compose-candidate-override.yml"
    override_path.write_text(json.dumps(override, indent=2) + "\n", encoding="utf-8")
    manifest = {
        "source_tag": args.source_tag,
        "candidate_tag": candidate_tag,
        "repositories": manifest_repositories,
        "compose_services": service_names,
        "candidate_images": candidate_images,
    }
    manifest_path = args.bundle_dir / "candidate-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    if service_names:
        compose = [
            "docker", "compose", "--env-file", args.compose_env_file,
            "-f", args.compose_file, "-f", override_path,
        ]
        run(compose + ["config", "--quiet"])
        print("Building candidate images through Docker Compose.")
        run(compose + ["build", "--pull"] + service_names)
        run(["docker", "save", "--output", args.bundle_dir / "candidate-images.tar"] + candidate_images)
    else:
        print("No High/Critical findings; no candidate images need rebuilding.")


def make_compose_override(manifest):
    return {
        "services": {
            item["service"]: {"image": item["candidate_image"]}
            for item in manifest["repositories"]
        }
    }


def validate_candidate(args):
    manifest_path = args.bundle_dir / "candidate-manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not manifest["repositories"]:
        (args.bundle_dir / "validation.json").write_text(
            json.dumps({"status": "no-op", "validated_images": []}, indent=2) + "\n",
            encoding="utf-8",
        )
        print("No candidate images; validation stage has nothing to run.")
        return

    run(["docker", "load", "--input", args.bundle_dir / "candidate-images.tar"])
    override_path = args.bundle_dir / "compose-validation-override.yml"
    override_path.write_text(json.dumps(make_compose_override(manifest), indent=2) + "\n", encoding="utf-8")
    compose = [
        "docker", "compose", "--env-file", args.compose_env_file,
        "-f", args.compose_file, "-f", override_path,
    ]
    rendered = run(compose + ["config", "--format", "json"], capture=True)
    configured_services = json.loads(rendered.stdout).get("services", {})

    check_script = r'''set -eu
if command -v dpkg-query >/dev/null 2>&1; then
  installed=$(dpkg-query -W -f='${Version}' "$PACKAGE")
elif command -v apk >/dev/null 2>&1; then
  installed=$(apk info -v "$PACKAGE")
  case "$installed" in
    "$PACKAGE"-*) installed=${installed#"$PACKAGE"-} ;;
    *) echo "Unexpected apk package result: $installed" >&2; exit 1 ;;
  esac
elif command -v rpm >/dev/null 2>&1; then
  installed=$(rpm -q --qf '%{VERSION}-%{RELEASE}' "$PACKAGE")
else
  echo "No supported package query tool found" >&2
  exit 1
fi
if [ "$installed" != "$EXPECTED" ]; then
  echo "$PACKAGE: expected $EXPECTED, found $installed" >&2
  exit 1
fi
'''
    validated_images = []
    test_compose_path = args.bundle_dir / "compose-package-tests.yml"
    test_compose = {"services": {}}
    for item in manifest["repositories"]:
        test_compose["services"][item["service"]] = {"image": item["candidate_image"]}
    test_compose_path.write_text(json.dumps(test_compose, indent=2) + "\n", encoding="utf-8")
    test_prefix = ["docker", "compose", "-f", test_compose_path]
    run(test_prefix + ["config", "--quiet"])

    for item in manifest["repositories"]:
        image = item["candidate_image"]
        configured_image = configured_services.get(item["service"], {}).get("image")
        if configured_image != image:
            raise ValueError(
                f"Compose maps {item['service']} to {configured_image!r}, expected {image!r}."
            )
        run(["docker", "image", "inspect", image], capture=True)
        for package in item["packages"]:
            run([
                *test_prefix, "run", "--rm", "--no-deps",
                "--entrypoint", "/bin/sh",
                "--env", f"PACKAGE={package['name']}",
                "--env", f"EXPECTED={package['version']}",
                item["service"], "-ec", check_script,
            ])
        validated_images.append(image)

    (args.bundle_dir / "validation.json").write_text(
        json.dumps({"status": "passed", "validated_images": validated_images}, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Compose and package validation passed for {len(validated_images)} candidate images.")


def publish_candidate(args):
    manifest = json.loads((args.bundle_dir / "candidate-manifest.json").read_text(encoding="utf-8"))
    validation = json.loads((args.bundle_dir / "validation.json").read_text(encoding="utf-8"))
    if validation.get("status") not in ("passed", "no-op"):
        raise ValueError("Candidate image validation did not pass.")

    target_tag = next_tag(manifest["source_tag"]) if manifest["repositories"] else ""
    published_images = []
    if manifest["repositories"]:
        run(["docker", "load", "--input", args.bundle_dir / "candidate-images.tar"])
        for item in manifest["repositories"]:
            target_image = (
                f"{args.registry}/{args.project}/{item['repository']}:{target_tag}"
            )
            run(["docker", "tag", item["candidate_image"], target_image])
            run(["docker", "push", target_image])
            published_images.append(target_image)

    published_manifest = {
        "source_tag": manifest["source_tag"],
        "published_tag": target_tag,
        "repositories": [item["repository"] for item in manifest["repositories"]],
        "images": published_images,
    }
    out = args.output_dir / "published-manifest.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(published_manifest, indent=2) + "\n", encoding="utf-8")
    if published_images:
        print(f"Published {len(published_images)} images with tag {target_tag}.")
    else:
        print("No images required publishing.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="phase", required=True)

    build = subparsers.add_parser("build")
    build.add_argument("--report", required=True, type=Path)
    build.add_argument("--repositories-file", required=True, type=Path)
    build.add_argument("--compose-file", required=True, type=Path)
    build.add_argument("--compose-env-file", required=True, type=Path)
    build.add_argument("--project", required=True)
    build.add_argument("--registry", required=True)
    build.add_argument("--source-tag", required=True)
    build.add_argument("--run-id", required=True)
    build.add_argument("--bundle-dir", required=True, type=Path)
    build.set_defaults(func=dockerfile_build)

    validate = subparsers.add_parser("validate")
    validate.add_argument("--compose-file", required=True, type=Path)
    validate.add_argument("--compose-env-file", required=True, type=Path)
    validate.add_argument("--bundle-dir", required=True, type=Path)
    validate.set_defaults(func=validate_candidate)

    publish = subparsers.add_parser("publish")
    publish.add_argument("--project", required=True)
    publish.add_argument("--registry", required=True)
    publish.add_argument("--bundle-dir", required=True, type=Path)
    publish.add_argument("--output-dir", required=True, type=Path)
    publish.set_defaults(func=publish_candidate)

    args = parser.parse_args()
    try:
        args.func(args)
    except (OSError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"Remediation {args.phase} failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
