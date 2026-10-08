# GitHub Actions Configuration

This repository uses `.github/workflows/build-prd.yml` for validation and manual deployment.
Pushes to `dev` use `.github/workflows/build-dev.yml` to run the same validation pipeline without the deploy job.
The dev workflow uses the GitHub Actions environment `dev`; the main deploy job uses `prod`.
The dev workflow also starts the compose stack and validates the Uptime Kuma target inventory against the internal Docker endpoints defined in `The Eyes/Uptime-Kuma/monitors.yml`. Its image warmup stage prunes unused Docker system resources first, skips local build outputs and builder-stage images, retries transient registry failures, attempts every remaining service pull, and fails once at the end with a consolidated list of denied or missing repositories. The FQDN proxy and scanner services stay on repo-local Dockerfiles, so their images are excluded from the pull phase because they are build outputs, not registry pulls. Both workflows can also pull through Harbor when `HARBOR_CACHE_*` variables are configured, which reduces direct dependence on the public registries.

## Required Repository Secrets

Create these in `Settings -> Secrets and variables -> Actions -> Secrets`.

| Name | Purpose |
| --- | --- |
| `DEPLOY_HOST` | SSH host for the deployment target. |
| `DEPLOY_USER` | SSH user for the deployment target. |
| `DEPLOY_SSH_KEY` | Private key used by the workflow SSH action. |
| `DEPLOY_PATH` | Absolute path to the checkout on the remote host. |
| `CADDY_CROWDSEC_API_KEY` | CrowdSec bouncer key injected into the Caddy container at deploy time. |

The workflow copies `.env.example` to `.env` and then injects `CADDY_CROWDSEC_API_KEY` from GitHub Secrets before running Compose.
Keep the example file free of GitHub expression syntax such as `${{ secrets.* }}` because Docker Compose reads `.env` as a plain environment file.

## Required Repository Variables

Create these in `Settings -> Secrets and variables -> Actions -> Variables`.

| Name | Purpose | Default |
| --- | --- | --- |
| `DEPLOY_PORT` | SSH port for the deployment host. | `22` |
| `DEV_SECSTACK_PROFILES` | Default compose profiles used by the dev validation workflow. | `all` |
| `PROD_SECSTACK_PROFILES` | Default compose profiles used by the main deploy workflow. | `dns secrets brain ops` |

## Optional Workflow Dispatch Input

The manual workflow run accepts a `profiles` input. Use it when you want to test or deploy a narrower set of compose profiles without changing repository settings.

Examples:

```text
all
brain
dns secrets brain ops
```

## Test Run

Use the workflow dispatch run first when validating repo settings:

1. Open the workflow in GitHub Actions.
2. Run it manually.
3. Optionally set `profiles` to the profile set you want to test.
4. Confirm the validate job passes before enabling deployment.

The validate job runs `docker compose config`, checks shell syntax, and prewarms the core images needed for the main stack profiles. If a repository is missing or denied, the workflow reports it after the full prewarm pass instead of failing deep in `docker compose up`. The build cache defaults to a local `.buildx-cache` directory for developer runs and switches to GitHub Actions cache in CI. Harbor proxy cache setup details live in [docs/registry-cache.md](registry-cache.md).

Harbor endpoint URLs to configure are documented there as well: Docker Hub `https://registry-1.docker.io`, GHCR `https://ghcr.io`, and Greenbone `https://registry.community.greenbone.net`. The repo accepts both `HARBOR_CACHE_PROJECT_DOCKERIO` and `HARBOR_CACHE_PROJECT_DOCKERHUB` for the Docker Hub proxy project name.
