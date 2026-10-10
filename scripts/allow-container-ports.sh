```bash
#!/usr/bin/env bash
set -Eeuo pipefail

ZONE="public"

TCP_PORTS=(
    11434 3002 8200 9200 8080
    1515 55000 5514 9000 3001
    8081 8443 9002 9443
)

UDP_PORTS=(
    1514 1516 5514
)

UDP_RANGES=(
    12201-12203
)

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root (Secureblue: run0 $0)"
    exit 1
fi

command -v firewall-cmd >/dev/null 2>&1 || {
    echo "ERROR: firewall-cmd not found."
    exit 1
}

firewall-cmd --state >/dev/null 2>&1 || {
    echo "ERROR: firewalld is not running."
    exit 1
}

if ! firewall-cmd --get-zones | tr ' ' '\n' | grep -Fxq "$ZONE"; then
    echo "ERROR: Zone '$ZONE' does not exist."
    exit 1
fi

# Read permanent rules once.
PERMANENT_PORTS=$(
    firewall-cmd --permanent --zone="$ZONE" --list-ports
)

has_port() {
    local target="$1"
    [[ " $PERMANENT_PORTS " == *" $target "* ]]
}

missing=0

# Check TCP ports.
for port in "${TCP_PORTS[@]}"; do
    if ! has_port "${port}/tcp"; then
        missing=1
        break
    fi
done

# Check UDP ports.
if [[ $missing -eq 0 ]]; then
    for port in "${UDP_PORTS[@]}"; do
        if ! has_port "${port}/udp"; then
            missing=1
            break
        fi
    done
fi

# Check UDP ranges.
if [[ $missing -eq 0 ]]; then
    for range in "${UDP_RANGES[@]}"; do
        if ! has_port "${range}/udp"; then
            missing=1
            break
        fi
    done
fi

if [[ $missing -eq 0 ]]; then
    echo "All requested ports are already permanently allowed in '$ZONE'."
    echo "Skipping firewall changes and reload."
    exit 0
fi

changed=0

add_port_if_missing() {
    local port="$1"

    if has_port "$port"; then
        echo "SKIP: $port already allowed"
    else
        echo "ADD:  $port"
        firewall-cmd --permanent --zone="$ZONE" --add-port="$port"
        changed=1

        # Update cached rules so subsequent checks see the addition.
        PERMANENT_PORTS="${PERMANENT_PORTS} ${port}"
    fi
}

echo "Checking and adding missing firewall rules..."

for port in "${TCP_PORTS[@]}"; do
    add_port_if_missing "${port}/tcp"
done

for port in "${UDP_PORTS[@]}"; do
    add_port_if_missing "${port}/udp"
done

for range in "${UDP_RANGES[@]}"; do
    add_port_if_missing "${range}/udp"
done

if [[ $changed -eq 1 ]]; then
    echo "Reloading firewalld..."
    firewall-cmd --reload
    echo "Firewall rules updated successfully."
else
    echo "No changes required."
fi

echo "Configured ports in zone '$ZONE':"
firewall-cmd --zone="$ZONE" --list-ports
```
