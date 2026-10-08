# Wazuh Integration Reference

Wazuh receives endpoint events on `wazuh-manager:1514/udp` and enrolls agents on `1515/tcp`. The manager publishes indexed data to `wazuh-indexer:9200`, and the dashboard reads the indexer plus the manager API.

Preferred alert flow: Wazuh rule hit -> Wazuh API or dashboard review -> TheHive case for investigation -> Shuffle or Ansible response if containment is approved.
