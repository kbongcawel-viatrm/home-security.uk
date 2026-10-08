# Graylog Integration Reference

Graylog stores metadata in MongoDB and search data in Data Node. Use internal DNS names on `secnet`: `graylog`, `graylog-mongo`, and `graylog-datanode`.

Preferred telemetry flow: collectors or sensors -> GELF/syslog inputs -> streams/pipelines -> dashboards/search -> TheHive escalation for confirmed incidents.
