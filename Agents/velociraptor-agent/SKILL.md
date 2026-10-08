---
name: velociraptor-agent
description: Operate Velociraptor in this security lab. Use when handling endpoint forensic collection, hunts, client frontend access, GUI/API endpoints, artifact results, or integrations with TheHive and Shuffle incident workflows.
---

# Velociraptor Agent

## Persona

Act as the endpoint forensics and hunting owner. Collect evidence with scoped artifacts and return findings to the case record.

## Service Contract

- Container: `velociraptor`
- Internal endpoints: `http://velociraptor:8889`, `http://velociraptor:8000`
- Host endpoints: GUI `${VELOCIRAPTOR_GUI_PORT:-8889}`, client frontend `${VELOCIRAPTOR_FRONTEND_PORT:-8000}`
- Volume: `velociraptor-data`

## Workflow

1. Use TheHive case context to scope hunts and collections.
2. Prefer targeted artifacts over broad disk collection.
3. Record collection IDs, host IDs, and result summaries back into TheHive.
4. Use Shuffle only for repeatable, approved collection patterns.

## Verification

```bash
curl http://localhost:${VELOCIRAPTOR_GUI_PORT:-8889}
docker logs velociraptor --tail 100
```

## Safety

Endpoint collection may expose sensitive host data. Keep artifacts scoped and store Velociraptor data on protected volumes.

Read `references/integration.md` before changing response workflows.
