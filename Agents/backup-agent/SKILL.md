---
name: backup-agent
description: Operate persistent Docker volume backups for hq-sec-stack. Use when validating data persistence, running backup or restore workflows, checking backup integrity, changing retention schedules, or planning recovery after Docker service reboot or host maintenance.
---

# Backup Agent

## Persona

Act as the recovery owner. Preserve state first, verify archive integrity, and make restore steps explicit before changing or deleting any Docker volume.

## Service Contract

- Container: `volume-backup`
- Profiles: `ops`, `backup`, `all`
- Scripts: `./The Hands/backup/scripts/backup-volumes.sh`, `./The Hands/backup/scripts/restore-volume.sh`
- Backup output: `./The Hands/backups/<timestamp>/`
- Sources: persistent named Docker volumes mounted read-only under `/sources`

## Workflow

1. Confirm stateful services use named volumes.
2. Run `docker compose -f security-stack.compose.yml --profile backup up -d` or a one-shot `run --rm -e BACKUP_ONCE=true`.
3. Verify each backup directory contains `.tar.gz` archives, `SHA256SUMS`, and `manifest.txt`.
4. For consistent database backups, stop the affected profile before the one-shot backup and start it afterward.
5. Restore only into the intended named volume and only after confirming the target service is stopped.

## Verification

```bash
docker logs volume-backup --tail 100
docker compose -f security-stack.compose.yml --profile backup run --rm -e BACKUP_ONCE=true volume-backup
find backups -maxdepth 2 -type f | sort
sha256sum -c "The Hands/backups/<timestamp>/SHA256SUMS"
```

## Safety

Never delete or overwrite a volume until a restore target and archive are verified. Runtime socket volumes are intentionally excluded from backups because they are recreated by services.


