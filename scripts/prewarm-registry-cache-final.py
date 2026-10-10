#!/usr/bin/env python3
"""Prewarm Docker image caches, optionally through Harbor proxy cache projects.

This script is optimized for low disk usage in CI runners:
- Pulls images through Harbor proxy cache when configured.
- Tags each successfully pulled image with a dynamic artifact name.
- Saves each tagged image to a .tar file.
- Compresses each .tar file to .tar.gz.
- Moves compressed artifacts into the artifact directory.
- Prunes containers, images, volumes, and build cache after artifact creation.
- Continues when an image is missing or broken.
- Lists all broken/unavailable images at the end.

Environment variables:
- DOCKER_CACHE_PRUNE_BEFORE_PULL=true
- DOCKER_CACHE_PRUNE_AFTER_PULL=true
- DOCKER_CACHE_PRUNE_AFTER_EACH_IMAGE=true
- DOCKER_CACHE_FORCE_PULL=true
- DOCKER_CACHE_IGNORE_FAILURES=true
- HARBOR_CACHE_FALLBACK_TO_ORIGIN=true
- DOCKER_ARTIFACT_TAG=v1.0
- DOCKER_ARTIFACT_DIR=artifact
"""

from __future__ import annotations

import argparse
import gzip
import os
import shutil
import subprocess
from pathlib import Path


def truthy(value: str | None, default: bool = False) -> bool:
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def run_command(cmd: list[str], *, input_text: str | None = None) -> int:
    proc = subprocess.run(
        cmd,
        input=input_text,
        text=True,
        check=False,
    )
    return proc.returncode


def run_command_checked(cmd: list[str], *, input_text: str | None = None) -> None:
    code = run_command(cmd, input_text=input_text)
    if code != 0:
        raise RuntimeError(f"command failed: {' '.join(cmd)}")


def run_command_with_retry(
    cmd: list[str],
    *,
    input_text: str | None = None,
    attempts: int = 2,
    delay_seconds: int = 5,
) -> int:
    last_code = 0
    for attempt in range(1, attempts + 1):
        last_code = run_command(cmd, input_text=input_text)
        if last_code == 0:
            return 0
        if attempt < attempts:
            print(f"Retrying {' '.join(cmd)} ({attempt}/{attempts})")
            subprocess.run(["sleep", str(delay_seconds * attempt)], check=False)
    return last_code


def capture_command(cmd: list[str]) -> str:
    proc = subprocess.run(cmd, text=True, check=False, capture_output=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or f"command failed: {' '.join(cmd)}")
    return proc.stdout


def prune_docker_space_before_pull() -> None:
    if not truthy(os.environ.get("DOCKER_CACHE_PRUNE_BEFORE_PULL"), default=False):
        return

    print("Pruning unused Docker images and build cache before pulls")
    run_command(["docker", "image", "prune", "-af"])
    run_command(["docker", "builder", "prune", "-af"])


def prune_docker_space_after_pull() -> None:
    if not truthy(os.environ.get("DOCKER_CACHE_PRUNE_AFTER_PULL"), default=False):
        return

    print("Pruning dangling Docker images and build cache after pulls")
    run_command(["docker", "image", "prune", "-f"])
    run_command(["docker", "builder", "prune", "-af"])


def cleanup_after_image() -> None:
    if not truthy(os.environ.get("DOCKER_CACHE_PRUNE_AFTER_EACH_IMAGE"), default=False):
        return

    print("Cleaning dangling Docker images and build cache after image")
    run_command(["docker", "image", "prune", "-f"])
    run_command(["docker", "builder", "prune", "-af"])


def cleanup_image_ref(image: str) -> None:
    if not image.strip():
        return
    run_command(["docker", "rmi", "-f", image])


def image_exists(image: str) -> bool:
    proc = subprocess.run(
        ["docker", "image", "inspect", image],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return proc.returncode == 0


def split_image_ref(image: str) -> tuple[str, str, str | None, str | None]:
    ref = image.strip()
    digest = None
    if "@" in ref:
        ref, digest = ref.split("@", 1)

    last_slash = ref.rfind("/")
    last_colon = ref.rfind(":")
    tag = None
    if last_colon > last_slash:
        tag = ref[last_colon + 1 :]
        ref = ref[:last_colon]

    parts = ref.split("/")
    if len(parts) > 1 and ("." in parts[0] or ":" in parts[0] or parts[0] == "localhost"):
        registry = parts[0]
        path = "/".join(parts[1:])
    else:
        registry = "docker.io"
        path = ref if "/" in ref else f"library/{ref}"

    return registry, path, tag, digest


def harbor_pull_ref(image: str) -> str | None:
    harbor_host = os.environ.get("HARBOR_CACHE_HOST", "").strip().rstrip("/")
    if not harbor_host:
        return None

    registry, path, tag, digest = split_image_ref(image)
    project_map = {
        "docker.io": os.environ.get("HARBOR_CACHE_PROJECT_DOCKERIO", "").strip()
        or os.environ.get("HARBOR_CACHE_PROJECT_DOCKERHUB", "").strip(),
        "ghcr.io": os.environ.get("HARBOR_CACHE_PROJECT_GHCR", "").strip(),
        "registry.community.greenbone.net": os.environ.get("HARBOR_CACHE_PROJECT_GREENBONE", "").strip(),
    }
    project = project_map.get(registry, "") or os.environ.get("HARBOR_CACHE_PROJECT_DEFAULT", "").strip()
    if not project:
        return None

    ref = f"{harbor_host}/{project}/{path}"
    if tag:
        ref = f"{ref}:{tag}"
    if digest:
        ref = f"{ref}@{digest}"
    return ref


def load_images(compose_file: str, profiles: list[str], targets_file: str | None) -> list[str]:
    cmd = ["docker", "compose", "-f", compose_file]
    for profile in profiles:
        cmd.extend(["--profile", profile])
    cmd.extend(["config", "--images"])
    compose_images = capture_command(cmd).splitlines()

    images: list[str] = []
    seen: set[str] = set()

    for image in compose_images:
        image = image.strip()
        if image and image not in seen:
            images.append(image)
            seen.add(image)

    if targets_file:
        for raw_line in Path(targets_file).read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            if line not in seen:
                images.append(line)
                seen.add(line)

    return images


def should_skip_image(image: str) -> bool:
    ref = image.strip()
    if not ref:
        return True
    if ref == "caddy:builder-alpine" or ref.endswith(":builder-alpine"):
        return True
    if ref.startswith("hq-sec/") or ref.startswith("hq-sec-stack-"):
        return True
    return False


def login_harbor_if_needed() -> None:
    harbor_host = os.environ.get("HARBOR_CACHE_HOST", "").strip().rstrip("/")
    harbor_user = os.environ.get("HARBOR_CACHE_USERNAME", "").strip()
    harbor_password = os.environ.get("HARBOR_CACHE_PASSWORD", "").strip()

    if not (harbor_host and harbor_user and harbor_password):
        return

    print(f"Logging in to Harbor cache host {harbor_host}")
    run_command(
        ["docker", "login", harbor_host, "-u", harbor_user, "--password-stdin"],
        input_text=f"{harbor_password}\n",
    )


def pull_image(image: str) -> str | None:
    force_pull = truthy(os.environ.get("DOCKER_CACHE_FORCE_PULL"), default=False)

    if not force_pull and image_exists(image):
        print(f"Already present locally: {image}")
        return image

    harbor_ref = harbor_pull_ref(image)
    pull_candidates: list[str] = []

    if harbor_ref:
        pull_candidates.append(harbor_ref)

        if truthy(os.environ.get("HARBOR_CACHE_FALLBACK_TO_ORIGIN"), default=True):
            pull_candidates.append(image)
    else:
        pull_candidates.append(image)

    for pull_ref in pull_candidates:
        print(f"Pulling {image} from {pull_ref}")
        code = run_command_with_retry(["docker", "pull", pull_ref], attempts=2, delay_seconds=5)

        if code == 0:
            print(f"Pulled successfully: {pull_ref}")
            cleanup_after_image()
            return pull_ref

        print(f"[WARN] Failed to pull {pull_ref}")
        cleanup_image_ref(pull_ref)

        if pull_ref != image:
            cleanup_image_ref(image)

        cleanup_after_image()

    print(f"[ERROR] Broken or unavailable image: {image}")
    return None


def sanitize_artifact_token(value: str) -> str:
    token = value.strip().lower()
    replacements = {
        "/": "-",
        "\\": "-",
        ":": "-",
        "@": "-",
        " ": "-",
        "_": "-",
    }

    for old, new in replacements.items():
        token = token.replace(old, new)

    return "-".join(part for part in token.split("-") if part)


def docker_tar_name(image: str) -> str:
    _, path, tag, digest = split_image_ref(image)

    name = path.split("/")[-1]

    if tag:
        version = tag
    elif digest:
        version = digest.replace(":", "-")
    else:
        version = "latest"

    name = sanitize_artifact_token(name)
    version = sanitize_artifact_token(version)

    if not name or not version:
        raise RuntimeError(f"Unable to infer artifact filename from image: {image}")

    return f"{name}.{version}.tar"


def compress_tar(tar_path: Path, gz_path: Path) -> None:
    with tar_path.open("rb") as source:
        with gzip.open(gz_path, "wb") as target:
            shutil.copyfileobj(source, target)


def create_docker_artifact(image: str, tag: str, out_dir: str) -> Path:
    del tag  # Kept for backward-compatible call signature.

    tar_path = Path(docker_tar_name(image))
    gz_path = Path(f"{tar_path.name}.gz")
    artifact_dir = Path(out_dir)
    artifact_path = artifact_dir / gz_path.name

    try:
        print(f"Saving Docker image artifact: {tar_path}")
        if tar_path.exists():
            tar_path.unlink()
        run_command_checked(["docker", "save", "-o", str(tar_path), image])

        print(f"Compressing Docker image artifact: {gz_path}")
        if gz_path.exists():
            gz_path.unlink()
        compress_tar(tar_path, gz_path)

        print(f"Creating artifact directory: {artifact_dir}")
        artifact_dir.mkdir(parents=True, exist_ok=True)

        print(f"Moving artifact to: {artifact_path}")
        if artifact_path.exists():
            artifact_path.unlink()
        gz_path.replace(artifact_path)

        print(f"Artifact created: {artifact_path}")
        return artifact_path

    finally:
        if tar_path.exists():
            tar_path.unlink()
        if gz_path.exists():
            gz_path.unlink()


def prune_docker_artifact_resources() -> None:
    print("Pruning Docker containers, images, volumes, and build cache")
    run_command_checked(["docker", "container", "prune", "-f"])
    run_command_checked(["docker", "image", "prune", "-af"])
    run_command_checked(["docker", "volume", "prune", "-f"])
    run_command_checked(["docker", "builder", "prune", "-af"])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact-tag", default=os.environ.get("DOCKER_ARTIFACT_TAG", "v1.0"))
    parser.add_argument("--artifact-dir", default=os.environ.get("DOCKER_ARTIFACT_DIR", "artifact"))
    parser.add_argument("--compose-file", default=os.environ.get("COMPOSE_FILE", "security-stack.compose.yml"))
    parser.add_argument("--profiles", default=os.environ.get("SECSTACK_PROFILES", "all"))
    parser.add_argument("--targets-file", default=os.environ.get("CACHE_TARGETS_FILE", "The Shield/scanner/targets.txt"))
    args = parser.parse_args()

    prune_docker_space_before_pull()
    login_harbor_if_needed()

    profiles = [profile for profile in args.profiles.split() if profile]
    targets_file = args.targets_file if Path(args.targets_file).exists() else None

    if targets_file:
        images = []
        seen: set[str] = set()

        for raw_line in Path(targets_file).read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue

            if line not in seen:
                images.append(line)
                seen.add(line)
    else:
        images = load_images(args.compose_file, profiles, None)

    failures: list[str] = []
    artifact_paths: list[Path] = []
    succeeded = 0
    skipped = 0

    for image in images:
        if should_skip_image(image):
            print(f"Skipping non-pull image {image}")
            skipped += 1
            continue

        pulled_ref = pull_image(image)
        if not pulled_ref:
            failures.append(image)
            continue

        succeeded += 1
        artifact_paths.append(create_docker_artifact(pulled_ref, args.artifact_tag, args.artifact_dir))

    prune_docker_space_after_pull()

    if artifact_paths:
        prune_docker_artifact_resources()

    print("\nImage prewarm summary:")
    print(f"- Successful images: {succeeded}")
    print(f"- Skipped images: {skipped}")
    print(f"- Broken images: {len(failures)}")
    print(f"- Artifacts created: {len(artifact_paths)}")

    if artifact_paths:
        print("\nDocker artifacts:")
        for artifact_path in artifact_paths:
            print(f"- {artifact_path}")

    if failures:
        print("\nBroken or unavailable Docker images:")
        for image in failures:
            print(f"- {image}")

        if truthy(os.environ.get("DOCKER_CACHE_IGNORE_FAILURES"), default=False):
            print("\nDOCKER_CACHE_IGNORE_FAILURES=true, so exiting successfully despite broken images.")
            return 0

        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
