#!/usr/bin/env sh
set -eu

FIREWALL_ZONE="${FIREWALL_ZONE:-}"

if ! command -v firewall-cmd >/dev/null 2>&1; then
  echo "Missing required command: firewall-cmd (install or enable firewalld)" >&2
  exit 127
fi

if [ -z "${FIREWALL_ZONE}" ]; then
  FIREWALL_ZONE="$(sudo firewall-cmd --get-default-zone)"
fi

# Keep this list aligned with the default host port mappings in
# security-stack.compose.yml and .env.example. If .env overrides a host port,
# update the corresponding entry here before applying the firewall rules.
for port in \
  1053/tcp 1053/udp \
  8080/tcp 8081/tcp 8443/tcp \
  8000/tcp 3001/tcp 3002/tcp 8889/tcp \
  9000/tcp 9001/tcp 9002/tcp 9443/tcp 9444/tcp 9392/tcp \
  8200/tcp 9200/tcp 5601/tcp 1515/tcp 55000/tcp \
  1514/udp 1516/udp 12201/udp 12202/udp 12203/udp \
  5514/tcp 5514/udp 11434/tcp
do
  sudo firewall-cmd --permanent --zone="${FIREWALL_ZONE}" --add-port="${port}"
done

sudo firewall-cmd --reload
sudo firewall-cmd --zone="${FIREWALL_ZONE}" --list-ports
