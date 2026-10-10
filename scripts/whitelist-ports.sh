#!/bin/sh
set -eu

echo "Whitelisting ports in firewalld..."
ZONE="$(run0 firewall-cmd --get-default-zone)"

for port in \
  1053/tcp 1053/udp \
  8081/tcp 8443/tcp \
  9200/tcp \
  1514/udp 1516/udp 1515/tcp 55000/tcp \
  5601/tcp \
  9000/tcp \
  12201/udp 12202/udp 12203/udp \
  5514/tcp 5514/udp \
  3002/tcp
do
  run0 firewall-cmd --permanent --zone="$ZONE" --add-port="$port"
  echo "Done for port: $port"
done

echo "Reloading firewalld..."
run0 firewall-cmd --reload
echo "Getting the whitelisted ports..."
run0 firewall-cmd --zone="$ZONE" --list-ports

