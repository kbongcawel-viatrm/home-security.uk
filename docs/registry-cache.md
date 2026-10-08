# Image Prewarm

`.github/workflows/image-sync.yml` runs `scripts/prewarm-registry-cache-final.py` for image batches and uploads compressed Docker image artifacts. The development and production workflows download and load those artifacts before starting containers. The helper skips local build images; `scripts/start-stack.sh` builds those from the repository.

Harbor is optional. When configured, the helper tries the matching Harbor proxy project first and falls back to the upstream registry. Without Harbor settings, it pulls directly from upstream. It retries failed pulls and reports unavailable images.

For local startup, `scripts/start-stack.sh` pulls images by default. Set `PULL_IMAGES=false` only when the required images are already local. Compose may pull a missing image during startup.

## Harbor settings

The prewarm workflow reads these GitHub Actions variables: `HARBOR_CACHE_HOST`, `HARBOR_CACHE_PROJECT_DOCKERIO`, `HARBOR_CACHE_PROJECT_DOCKERHUB`, `HARBOR_CACHE_PROJECT_GHCR`, `HARBOR_CACHE_PROJECT_GREENBONE`, and `HARBOR_CACHE_PROJECT_DEFAULT`. It reads the Harbor password from the `HARBORPW` secret and the username from the `HARBORUSER` variable.

The helper accepts the same project names and host through `HARBOR_CACHE_*` environment variables. Supported upstream registries are Docker Hub (`registry-1.docker.io`), GHCR (`ghcr.io`), and Greenbone Community (`registry.community.greenbone.net`).
