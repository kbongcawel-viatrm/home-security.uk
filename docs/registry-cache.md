# Registry Cache

This stack can warm Docker images through Harbor proxy cache projects before it starts services.

## What It Does

The helper script at [`scripts/prewarm-registry-cache.py`](../scripts/prewarm-registry-cache.py) does five things:

1. Optionally prunes unused Docker images and builder cache.
2. Prunes unused Docker system resources before warmup when `DOCKER_CACHE_PRUNE_BEFORE_PULL=true`.
3. Pulls the images referenced by `security-stack.compose.yml` plus `The Shield/scanner/targets.txt`.
4. Pulls through Harbor proxy cache projects when Harbor cache variables are configured, then retags the image locally under the original name.
5. Skips local build outputs and builder-stage images such as `hq-sec/caddy-crowdsec` from [The Hands/FQDN proxy - Caddy/Dockerfile](../The%20Hands/FQDN%20proxy%20-%20Caddy/Dockerfile), `hq-sec-stack-nmap-scanner`, `hq-sec-stack-wireshark-scanner` from the repo-local scanner Dockerfiles, and `caddy:builder-alpine`.

The workflows use `--pull never` after prewarming so Docker does not go back to the upstream registries during startup. The Compose file avoids BuildKit-only cache export fields so its local Dockerfile builds also work through Podman's `podman-compose` provider.

## Harbor Setup

Harbor proxy cache is configured per upstream registry. For this repository, the likely projects are:

1. A Docker Hub proxy cache project for images like `caddy`, `python`, `osquery`, `velociraptor`, `vault`, `graylog`, and `mongo`.
2. A GHCR proxy cache project for Shuffle images.
3. A Greenbone registry proxy cache project for the Community Greenbone images.

You will need Harbor admin or project-admin access to create the proxy cache projects and registry endpoints. I also need the project names you want to use, or admin credentials if you want me to wire the exact settings in the repo.

### Suggested Upstream Endpoints

Use these upstream registry URLs when you create the Harbor `Registries -> New Endpoint` entries:

| Registry | Endpoint URL |
| --- | --- |
| Docker Hub | `https://registry-1.docker.io` |
| GitHub Container Registry | `https://ghcr.io` |
| Greenbone Community Registry | `https://registry.community.greenbone.net` |

The cache helper maps `docker.io` image references to `HARBOR_CACHE_PROJECT_DOCKERIO` first, then `HARBOR_CACHE_PROJECT_DOCKERHUB`, `ghcr.io` to the GHCR proxy project, and `registry.community.greenbone.net` to the Greenbone proxy project. The Greenbone Redis service now pulls from the Docker Hub mirror `greenbone/redis-server:latest`, and the SCAP data container uses the Docker Hub mirror `vulnvision/greenbone-scap-data:latest` to avoid the flaky community registry pull path during warmup.

The GitHub Actions workflows export the `HARBOR_CACHE_*` variables when they are configured in repo settings. That lets the prewarm step login to Harbor and pull through your proxy cache projects before falling back to public registries.

## Required Environment Variables

Set these in `.env` or in GitHub Actions variables/secrets as appropriate:

- `HARBOR_CACHE_HOST`
- `HARBOR_CACHE_USERNAME`
- `HARBOR_CACHE_PASSWORD`
- `HARBOR_CACHE_PROJECT_DOCKERIO`
- `HARBOR_CACHE_PROJECT_DOCKERHUB`
- `HARBOR_CACHE_PROJECT_GHCR`
- `HARBOR_CACHE_PROJECT_GREENBONE`
- `HARBOR_CACHE_PROJECT_DEFAULT`
- `DOCKER_CACHE_PRUNE_BEFORE_PULL=true`

## Notes

Proxy cache projects are not push targets. They are pull-through caches. To use them, pull from the Harbor project path and then retag the image locally under the original image name.
