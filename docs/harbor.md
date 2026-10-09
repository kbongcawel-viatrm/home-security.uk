# Harbor Container Registry

Harbor at `demo.goharbor.io` stores images for the home security stack and provides proxy-cache projects for upstream images.

## Projects and image names

The writable project for stack images is `home-security-uk-registry`. Use this format for image references:

```text
demo.goharbor.io/home-security-uk-registry/<repository>:<tag>
```

For example, the `secdns` image tagged `v1.1` is:

```text
demo.goharbor.io/home-security-uk-registry/secdns:v1.1
```

The `home-security-uk` project is used for registry proxy caching. Proxy projects are for pulling upstream images and may reject pushes. Push stack images to `home-security-uk-registry`.

## Authenticate

Use a Harbor account or robot account that can pull and push images in `home-security-uk-registry`. Prefer a dedicated robot account with only the required project permissions, and never commit credentials to Git.

For Podman, provide the password through standard input:

```sh
printf '%s' "$HARBOR_PASSWORD" | podman login demo.goharbor.io \
  --username "$HARBOR_USERNAME" --password-stdin
```

For Docker:

```sh
printf '%s' "$HARBOR_PASSWORD" | docker login demo.goharbor.io \
  --username "$HARBOR_USERNAME" --password-stdin
```

Set `HARBOR_USERNAME` and `HARBOR_PASSWORD` in your shell from your approved credential store before running these commands.

## Push an image

With Podman, push a local image by its image ID to a repository and tag in Harbor:

```sh
IMAGE_ID=$(podman image inspect --format '{{.Id}}' SOURCE_IMAGE)
podman push "$IMAGE_ID" \
  demo.goharbor.io/home-security-uk-registry/REPOSITORY:TAG
```

Replace `SOURCE_IMAGE`, `REPOSITORY`, and `TAG` with the local image reference and the desired Harbor name. For example:

```sh
IMAGE_ID=$(podman image inspect --format '{{.Id}}' docker.io/library/caddy:2.8.4-alpine)
podman push "$IMAGE_ID" \
  demo.goharbor.io/home-security-uk-registry/caddy:v1.1
```

Docker can push by tagging the local image first:

```sh
docker tag SOURCE_IMAGE \
  demo.goharbor.io/home-security-uk-registry/REPOSITORY:TAG
docker push demo.goharbor.io/home-security-uk-registry/REPOSITORY:TAG
```

## Pull an image

Pull a Harbor image with Podman or Docker:

```sh
podman pull demo.goharbor.io/home-security-uk-registry/REPOSITORY:TAG
```

```sh
docker pull demo.goharbor.io/home-security-uk-registry/REPOSITORY:TAG
```

Podman enforces the user's image trust policy when pulling. If the policy rejects images from Harbor, ask the host administrator to add a narrowly scoped trust rule for this Harbor project; do not weaken the global default policy.

## Apply the project label in bulk

[`scripts/harbor-label-bulk.sh`](../scripts/harbor-label-bulk.sh) adds the existing `home-security-uk` project label to artifacts in the `home-security-uk-registry` project. It skips artifacts that already have that label and processes artifacts in pages of 100.

Requirements:

- Bash
- `curl`
- `jq`
- A Harbor robot account with permission to list project artifacts and attach the project label

Use a dedicated robot account for this operation. Do not type its secret directly into a command or commit it to Git. The script passes the credentials to `curl` using `-u` while each API request runs, so use an account with only the required project permissions.

Set the required variables in the current shell:

```sh
export HARBOR=https://demo.goharbor.io
export ROBOT_USER='your-robot-account'
read -rsp 'Harbor robot secret: ' ROBOT_SECRET
export ROBOT_SECRET
printf '\n'
```

Run the script from the repository root:

```sh
bash scripts/harbor-label-bulk.sh
```

The script currently targets Harbor project ID `7848`, project `home-security-uk-registry`, and the existing project label `home-security-uk`. If these names or the project ID change in Harbor, update the constants and label lookup in the script before running it. The script makes Harbor API changes to artifact labels; review its target project and credentials before execution.

## Proxy-cache configuration

The optional image prewarm helper uses `HARBOR_CACHE_HOST` and per-registry project variables in `.env` to pull through Harbor proxy projects. Those mappings are separate from the writable `home-security-uk-registry` project. See [Registry cache and image prewarm](registry-cache.md) for the proxy-cache workflow.
