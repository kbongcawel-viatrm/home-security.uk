# Network Sensor Scope

The active stack does not include IPFire or host-firewall rules. Suricata detects and logs traffic; it is not a routed firewall, NAT gateway, or default-deny enforcement point.

Run the `network` profile only when `${SENSOR_INTERFACE}` sees useful traffic, such as a TAP, SPAN, mirrored switch port, or relevant host traffic. Pairing Suricata with Zeek adds protocol metadata for investigation.

Check the interface before starting the profile:

```bash
ip link show ${SENSOR_INTERFACE:-eth0}
tcpdump -i ${SENSOR_INTERFACE:-eth0} -c 20
```

If it does not see useful traffic, leave the `network` profile stopped.
