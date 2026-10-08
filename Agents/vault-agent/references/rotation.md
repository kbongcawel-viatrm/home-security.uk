# Vault Rotation Reference

`vault-rotator` runs `/The Shield/vault/scripts/monthly-rotate.sh`. It checks every `VAULT_ROTATION_CHECK_SECONDS` seconds and rotates once per month on `VAULT_ROTATION_DAY`.

Required runtime setup:

```bash
vault secrets enable -path=secret kv-v2
vault policy write secstack-rotator /The Shield/vault/policies/secstack-rotator.hcl
vault token create -policy=secstack-rotator -period=720h
```

Secret paths:

- `secret/hq-sec-stack/graylog/password-secret`
- `secret/hq-sec-stack/graylog/root-password`
- `secret/hq-sec-stack/wazuh/dashboard-password`
- `secret/hq-sec-stack/thehive/play-secret`
- `secret/hq-sec-stack/shuffle/app-secret`
- `secret/hq-sec-stack/greenbone/admin-password`
- `secret/hq-sec-stack/velociraptor/admin-password`

Rotation changes stored values only. Applying those values to services is a separate operator action because each service has different reload behavior and password format requirements.


