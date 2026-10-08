# Repository Guidelines

## Project Structure & Module Organization

This repository combines a Docker Compose home security lab with static GitHub Pages content. The main stack definition is `security-stack.compose.yml`; operational scripts are in `scripts/`, configuration and service-specific assets are grouped under `The Brain/`, `The Eyes/`, `The Ghost/`, `The Hands/`, `The Shield/`, and `The Sword/`. Shared documentation lives in `docs/`, while `index.html`, `docs/index.html`, and Markdown files provide the published site. Agent instructions and playbooks are under `skills/`. Preserve existing directory names, including spaces and capitalization.

## Build, Test, and Development Commands

- `cp .env.example .env` creates a local configuration template; review and replace secrets before starting services.
- `sh scripts/start-stack.sh` starts the full stack. Set `SECSTACK_PROFILES="dns secrets brain"` to select profiles.
- `sh scripts/killswitch.sh` gracefully stops selected profiles. `sh scripts/killswitch.sh down` also removes their containers and networks while retaining named volumes.
- `docker compose -f security-stack.compose.yml config` renders and validates the Compose configuration using the current environment.

There is no repository-wide unit-test command. For changes to scripts or Compose services, perform a targeted syntax/configuration check and describe what was checked in the pull request.

## Coding Style & Naming Conventions

Follow the style already used by the file being changed. Shell scripts use POSIX `sh`, two-space indentation, quoted variable expansions, and `set -eu` where practical. Keep YAML consistently indented and use descriptive lowercase names for scripts and configuration files. Update the relevant README or `docs/` page when changing service behavior or operator steps.

## Testing Guidelines

No central test framework or coverage threshold is configured. Validate shell edits with `sh -n path/to/script.sh` and Compose edits with the `docker compose ... config` command above when Docker Compose is available. Avoid starting privileged scanners, response playbooks, or endpoint collection except in authorized lab environments.

## Commit & Pull Request Guidelines

Recent history uses short imperative commit subjects (for example, “Disable Jekyll workflow”). Keep commits focused and use a concise action-oriented subject. Pull requests should explain the operational impact, list affected profiles or services, include validation performed, and attach screenshots for visible website changes. Update `The Eyes/Uptime-Kuma/monitors.yml` in the same change whenever a service, container, FQDN, host port, or internal endpoint is added.

## Security & Configuration

Never commit `.env`, `.env.vault`, credentials, client keys, generated backups, or scan reports. Use `.env.example` for safe configuration placeholders. Review privileged access, host networking, mounted Docker sockets, and port exposure when changing service definitions.
