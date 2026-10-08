# GitHub Actions

## Container workflows

| Workflow | Purpose |
| --- | --- |
| `image-sync.yml` | On pushes to `dev` or `main`, or manual dispatch, pulls image batches and uploads compressed artifacts. Runs on the self-hosted `laptop` runner. |
| `build-dev.yml` | After a successful image-sync run, or manual dispatch, loads the artifacts and starts the full Compose stack on GitHub-hosted Ubuntu. |
| `build-prd.yml` | On main-branch YAML changes, image-sync completion, or manual dispatch, loads artifacts, validates Compose, and starts the stack through `scripts/start-stack.sh` on the self-hosted `prd` runner. The default profile is `all`. |

The PRD workflow uses the latest successful image-sync run. It copies `.env.prd` to `.env`, or falls back to `.env.example`. Replace example credentials before using the fallback for a real deployment.

## Optional Harbor cache

The image prewarm workflow can use Harbor proxy projects. Configure these Actions variables: `HARBOR_CACHE_HOST`, `HARBORUSER`, `HARBOR_CACHE_PROJECT_DOCKERIO`, `HARBOR_CACHE_PROJECT_DOCKERHUB`, `HARBOR_CACHE_PROJECT_GHCR`, `HARBOR_CACHE_PROJECT_GREENBONE`, and `HARBOR_CACHE_PROJECT_DEFAULT`. Store the Harbor password as the `HARBORPW` secret. Without these settings, images are pulled from their upstream registries.

See [Image Prewarm](registry-cache.md) for local pull behavior and registry mapping.
