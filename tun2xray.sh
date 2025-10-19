#!/bin/bash
set -e

TUN_DEVICE="tun0"
TUN_IP="10.0.0.1/24"
STATE_DIR="/run/tun2xray"
PID_FILE="$STATE_DIR/tun2socks.pid"
IP_STORE="$STATE_DIR/ipstore"


XRAY_INBOUND_TAG="socks"
XRAY_OUTBOUND_TAG="proxy"


check_dependencies() {
    local missing_deps=0
    for cmd in jq dig ip tun2socks pgrep ps; do
        if ! command -v "$cmd" &> /dev/null; then
            echo "Error: Command '$cmd' not found." >&2
            missing_deps=1
        fi
    done
    if [ $missing_deps -eq 1 ]; then
        exit 1
    fi
}

get_xray_config() {
    local xray_pid
    xray_pid=$(pgrep -x "xray")
    if [ -z "$xray_pid" ] || [ "$(echo "$xray_pid" | wc -l)" -ne 1 ]; then
        echo "Error: Couldn't find single xray process." >&2
        exit 1
    fi

    local xray_config_path
    xray_config_path=$(ps -p "$xray_pid" -o args= | grep -oP '\-c\s+\K[^\s]+')
    if [ -z "$xray_config_path" ] || [ ! -f "$xray_config_path" ]; then
        echo "Error: Couldn't find xray config path." >&2
        exit 1
    fi

    PROXY_ADDRESS=$(jq -r --arg tag "$XRAY_OUTBOUND_TAG" '.outbounds[] | select(.tag == $tag) | .settings.vnext[0].address' "$xray_config_path")
    SOCKS_PORT=$(jq -r --arg tag "$XRAY_INBOUND_TAG" '.inbounds[] | select(.tag == $tag) | .port' "$xray_config_path")

    if [ -z "$PROXY_ADDRESS" ] || [ "$PROXY_ADDRESS" == "null" ]; then
        echo "Error: Couldn't find proxy address with tag '$XRAY_OUTBOUND_TAG'." >&2
        exit 1
    fi
    if [ -z "$SOCKS_PORT" ] || [ "$SOCKS_PORT" == "null" ]; then
        echo "Error: Couldn't find SOCKS port with tag '$XRAY_INBOUND_TAG'." >&2
        exit 1
    fi
}

start() {
    echo "Starting..."
    mkdir -p "$STATE_DIR"
    get_xray_config

    local proxy_ip
    local ip_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'

    if [[ $PROXY_ADDRESS =~ $ip_regex ]]; then
        echo "Proxy IP found: $PROXY_ADDRESS"
        proxy_ip="$PROXY_ADDRESS"
    else
        echo "Proxy address found: $PROXY_ADDRESS. Running DNS request..."
        proxy_ip=$(dig +short "$PROXY_ADDRESS" | head -n1)
    fi

    if [ -z "$proxy_ip" ]; then
        echo "Error: Couldn't resolve IP for '$PROXY_ADDRESS'." >&2
        exit 1
    fi

    local gateway_ip
    gateway_ip=$(ip r show default | awk '/default/ {print $3}')
    if [ -z "$gateway_ip" ]; then
        echo "Error: Couldn't find default gateway." >&2
        exit 1
    fi

    echo "PROXY_IP=$proxy_ip" > "$IP_STORE"
    echo "GATEWAY_IP=$gateway_ip" >> "$IP_STORE"

    tun2socks -device "$TUN_DEVICE" -proxy "socks5://127.0.0.1:$SOCKS_PORT" &
    echo $! > "$PID_FILE"

    local count=0
    while ! ip link show "$TUN_DEVICE" >/dev/null 2>&1; do
        sleep 0.1
        ((count++))
        if [ "$count" -gt 50 ]; then
            echo "Error: Creating $TUN_DEVICE timed out." >&2
            stop
            exit 1
        fi
    done

    ip link set "$TUN_DEVICE" up
    ip addr add "$TUN_IP" dev "$TUN_DEVICE"
    ip route add "$proxy_ip" via "$gateway_ip"
    ip route del default
    ip route add default via "$TUN_IP"

    echo "Tun2socks started."
}

stop() {
    echo "Stopping..."
    if [ -f "$IP_STORE" ]; then
        source "$IP_STORE"
        ip route del default 2>/dev/null || true
        ip route add default via "$GATEWAY_IP" 2>/dev/null || true
        ip route del "$PROXY_IP" via "$GATEWAY_IP" 2>/dev/null || true
    else
        echo "Warning: $IP_STORE file not found. IP routes can be broken."
    fi

    if [ -f "$PID_FILE" ]; then
        kill "$(cat "$PID_FILE")"
        rm -f "$PID_FILE"
    else
        killall tun2socks 2>/dev/null || true
    fi

    if ip link show "$TUN_DEVICE" &> /dev/null; then
        ip link del "$TUN_DEVICE"
    fi

    rm -f "$IP_STORE"
    echo "Tun2socks stopped."
}

check_dependencies

case "$1" in
    up|start)
        start
        ;;
    down|stop)
        stop
        ;;
    *)
        echo "Usage: $0 {start|stop}"
        exit 1
        ;;
esac
