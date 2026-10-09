#!/usr/bin/env python3
"""Build, validate, and publish fixed Harbor images in separate workflow stages."""

import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys


PACKAGE_TOKEN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.+:_~-]*$")
IMAGE_TAG = re.compile(r"^(v)?([0-9]+)\.([0-9]+)$")
USER_TOKEN = re.compile(r"^[A-Za-z0-9_.:-]+$")


def latest_image_ref(image):
    """Return the same registry/repository with a latest tag when available.

    Harbor images are not guaranteed to have a :latest tag, so we prefer it when it
    exists and otherwise fall back to the original image reference.
    """
    image = str(image).strip()
    if not image or "@" in image:
        raise ValueError(f"Cannot derive a latest tag from Compose image {image!r}.")

    base = image.rsplit(":", 1)[0] if ":" in image.rsplit("/", 1)[-1] else image
    latest_ref = base + ":latest"

    # Prefer :latest only if it exists; otherwise, use the original tag.
    try:
        result = subprocess.run(
            ["docker", "manifest", "inspect", latest_ref],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0:
            return latest_ref
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass

    return image


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


def compose_backend(args):
    """Prefer podman-compose, while retaining an explicit Docker fallback."""
    backend = args.compose_backend
    if backend == "auto":
        backend = "podman-compose" if shutil.which("podman-compose") else "docker"
    if backend == "podman-compose" and not shutil.which("podman-compose"):
        raise ValueError("podman-compose was selected but is not installed.")
    if backend == "docker" and not shutil.which("docker"):
        raise ValueError("Docker Compose was selected but docker is not installed.")
    return backend


def engine_command(args):
    return ["podman"] if compose_backend(args) == "podman-compose" else ["docker"]


def compose_prefix(args, *, profiles=(), files=()):
    backend = compose_backend(args)
    command = ["podman-compose"] if backend == "podman-compose" else ["docker", "compose"]
    if backend == "docker":
        command += ["--profile", "*"]
    else:
        for profile in profiles:
            command += ["--profile", profile]
    if getattr(args, "compose_env_file", None):
        command += ["--env-file", args.compose_env_file]
    for compose_file in files:
        command += ["-f", compose_file]
    return command


def compose_model(args, files):
    """Render the Compose model, enabling each profile for podman-compose."""
    if compose_backend(args) == "docker":
        rendered = run(
            compose_prefix(args, files=files) + ["config", "--format", "json"],
            capture=True,
        )
        return json.loads(rendered.stdout)

    try:
        import yaml
    except ImportError as error:
        raise ValueError("PyYAML is required when using podman-compose.") from error

    source = yaml.safe_load(Path(files[0]).read_text(encoding="utf-8")) or {}
    profiles = sorted({
        profile
        for service in source.get("services", {}).values()
        for profile in service.get("profiles", [])
    })
    services = {}
    for profile in profiles or [None]:
        selected = (profile,) if profile else ()
        rendered = run(
            compose_prefix(args, profiles=selected, files=files) + ["config"],
            capture=True,
        )
        model = yaml.safe_load(rendered.stdout) or {}
        services.update(model.get("services", {}))
    return {"services": services}


def service_profiles(compose_file, service_names):
    try:
        import yaml
    except ImportError:
        return []
    model = yaml.safe_load(Path(compose_file).read_text(encoding="utf-8")) or {}
    profiles = set()
    for name in service_names:
        profiles.update((model.get("services", {}).get(name) or {}).get("profiles", []))
    return sorted(profiles)


def next_tag(source_tag):
    match = IMAGE_TAG.fullmatch(source_tag)
    if not match:
        raise ValueError(
            f"Automatic tag increment requires a numeric major.minor tag, got {source_tag!r}."
        )
    prefix, major, minor = match.groups()
    return f"{prefix or ''}{major}.{int(minor) + 1}"


def make_plan(
    report_path, repositories_path, source_tag, compose_service=None,
    refresh_base_image=False,
):
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
        # A latest-base refresh is verified by the workflow's post-build scan.
        if refresh_base_image:
            grouped.setdefault(repository, {})
            continue
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
            "service": compose_service or repository,
            "base_image": None,
            "packages": [
                {"name": package, "version": version}
                for package, version in sorted(packages.items())
            ],
        }
        for repository, packages in sorted(grouped.items())
    ]


def dockerfile_for(base_image, packages, original_user):
    if not packages:
        lines = [f"FROM {base_image}"]
        if original_user:
            lines.append(f"USER {original_user}")
        return "\n".join(lines) + "\n"
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
    candidate_tag = f"candidate-{args.run_id}"
    args.bundle_dir.mkdir(parents=True, exist_ok=True)
    compose_services = compose_model(args, [args.compose_file]).get("services", {})
    candidates = make_plan(
        args.report, args.repositories_file, args.source_tag, args.compose_service,
        refresh_base_image=args.latest_base_image,
    )
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
        base_image = item["base_image"] or source_image
        if args.latest_base_image:
            configured_image = compose_services[service].get("image")
            if not configured_image:
                raise ValueError(
                    f"Compose service {service!r} has no image to refresh to latest."
                )
            base_image = latest_image_ref(configured_image)
        run(engine_command(args) + ["pull", base_image])
        inspected = run(engine_command(args) + ["image", "inspect", base_image], capture=True)
        config = json.loads(inspected.stdout)[0].get("Config") or {}
        original_user = str(config.get("User") or "")
        if original_user and not USER_TOKEN.fullmatch(original_user):
            raise ValueError(f"Unsupported image user {original_user!r} in {source_image}.")

        context = args.bundle_dir / "contexts" / repository.replace("/", "_")
        context.mkdir(parents=True, exist_ok=True)
        (context / "Dockerfile").write_text(
            dockerfile_for(base_image, item["packages"], original_user),
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
            "base_image": base_image,
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
        profiles = service_profiles(args.compose_file, service_names)
        compose = compose_prefix(
            args, profiles=profiles, files=[args.compose_file, override_path]
        )
        run(compose + ["config", "--quiet"])
        print(f"Building candidate images through {compose_backend(args)}.")
        run(compose + ["build", "--pull"] + service_names)
        run(engine_command(args) + ["save", "--output", args.bundle_dir / "candidate-images.tar"] + candidate_images)
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

    run(engine_command(args) + ["load", "--input", args.bundle_dir / "candidate-images.tar"])
    override_path = args.bundle_dir / "compose-validation-override.yml"
    override_path.write_text(json.dumps(make_compose_override(manifest), indent=2) + "\n", encoding="utf-8")
    configured_services = compose_model(
        args, [args.compose_file, override_path]
    ).get("services", {})

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
    test_prefix = compose_prefix(args, files=[test_compose_path])
    run(test_prefix + ["config", "--quiet"])

    for item in manifest["repositories"]:
        image = item["candidate_image"]
        configured_image = configured_services.get(item["service"], {}).get("image")
        if configured_image != image:
            raise ValueError(
                f"Compose maps {item['service']} to {configured_image!r}, expected {image!r}."
            )
        run(engine_command(args) + ["image", "inspect", image], capture=True)
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
        run(engine_command(args) + ["load", "--input", args.bundle_dir / "candidate-images.tar"])
        for item in manifest["repositories"]:
            target_image = (
                f"{args.registry}/{args.project}/{item['repository']}:{target_tag}"
            )
            run(engine_command(args) + ["tag", item["candidate_image"], target_image])
            run(engine_command(args) + ["push", target_image])
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
    build.add_argument(
        "--compose-backend", choices=("auto", "podman-compose", "docker"),
        default="auto",
        help="Compose implementation (auto prefers podman-compose, then Docker Compose).",
    )
    build.add_argument("--report", required=True, type=Path)
    build.add_argument("--repositories-file", required=True, type=Path)
    build.add_argument("--compose-file", required=True, type=Path)
    build.add_argument("--compose-env-file", required=True, type=Path)
    build.add_argument("--project", required=True)
    build.add_argument("--registry", required=True)
    build.add_argument("--source-tag", required=True)
    build.add_argument("--compose-service")
    build.add_argument(
        "--latest-base-image", action="store_true",
        help="Rebuild from the latest tag of the Compose service's configured image.",
    )
    build.add_argument("--run-id", required=True)
    build.add_argument("--bundle-dir", required=True, type=Path)
    build.set_defaults(func=dockerfile_build)

    validate = subparsers.add_parser("validate")
    validate.add_argument(
        "--compose-backend", choices=("auto", "podman-compose", "docker"),
        default="auto",
        help="Compose implementation (auto prefers podman-compose, then Docker Compose).",
    )
    validate.add_argument("--compose-file", required=True, type=Path)
    validate.add_argument("--compose-env-file", required=True, type=Path)
    validate.add_argument("--bundle-dir", required=True, type=Path)
    validate.set_defaults(func=validate_candidate)

    publish = subparsers.add_parser("publish")
    publish.add_argument(
        "--compose-backend", choices=("auto", "podman-compose", "docker"),
        default="auto",
        help="Container backend (auto prefers Podman when podman-compose is installed).",
    )
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
