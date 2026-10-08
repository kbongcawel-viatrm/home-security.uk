# Velociraptor Integration Reference

Velociraptor provides endpoint evidence. Preferred flow: TheHive case -> approved collection or hunt -> Velociraptor results -> TheHive observable/task update -> Graylog/Wazuh query links if correlated.

Repo-local operations content lives in:

```text
The Shield/velociraptor/
```

Use these custom artifact packs first:

- `HQSec.Windows.EndpointVisibility`
- `HQSec.Windows.PowerShellTriage`
- `HQSec.Windows.PersistenceAndTamper`

Use these playbooks to choose collection scope:

- `collections/endpoint-visibility.md`
- `collections/digital-forensics.md`
- `collections/threat-hunting.md`

Record the Velociraptor client ID, collection ID, artifact names, time range, and result summary back into TheHive.
