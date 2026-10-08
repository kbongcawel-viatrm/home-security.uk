# Log Dashboard Reference

Dashboard route:

```text
http://reports.hq-sec.local
```

Generated files:

```text
The Hands/reports/data/log-assessments/latest/assessment.json
The Hands/reports/data/log-assessments/latest/assessment.md
```

One-shot assessment:

```bash
docker compose -f security-stack.compose.yml --profile dashboard run --rm -e LOG_ASSESSMENT_ONCE=true log-assessor
```

Graylog input bootstrap:

```bash
docker compose -f security-stack.compose.yml --profile logs run --rm graylog-bootstrap
```

