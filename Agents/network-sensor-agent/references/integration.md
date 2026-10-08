# Network Sensor Integration Reference

Suricata and Zeek write evidence to named volumes. They do not directly publish to Graylog in this lab compose; add a collector when the forwarding pattern is chosen.

Preferred flow: packet capture -> Suricata alert/protocol records and Zeek logs -> Graylog streams -> TheHive cases for confirmed leads.
