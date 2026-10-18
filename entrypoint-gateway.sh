#!/bin/sh
set -eu

PROXY_HOST_IP="$(getent hosts host.docker.internal | awk 'NR==1 {print $1}')"
[ -n "$PROXY_HOST_IP" ] || { echo "[Error] 无法解析 host.docker.internal"; exit 1; }

PROXY_PORT="${PROXY_PORT:-1083}"
PROXY_PROTOCOL="${PROXY_PROTOCOL:-socks5}"
PROXY_URL="${PROXY_PROTOCOL}://${PROXY_HOST_IP}:${PROXY_PORT}"

# Capture the container's real default gateway (this custom bridge network's
# gateway, e.g. 172.19.0.1) BEFORE it gets overwritten below with the tun0
# default route. "host.docker.internal" / host-gateway always resolves to the
# docker0 bridge IP (e.g. 172.17.0.1) regardless of which custom network this
# container is actually attached to. Routing to that address on-link (no via)
# silently black-holes, since it's not on this subnet and ARP never resolves.
ORIG_GATEWAY="$(ip route show default 2>/dev/null | awk '/^default/ {print $3; exit}')"

#sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.rp_filter=0 2>/dev/null || true
sysctl -w net.ipv4.conf.default.rp_filter=0 2>/dev/null || true
sysctl -w net.ipv4.conf.eth0.rp_filter=0 2>/dev/null || true

sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true

if ! ip link show tun0 >/dev/null 2>&1; then
    ip tuntap add dev tun0 mode tun
    ip addr add 198.18.0.1/15 dev tun0
    ip link set dev tun0 up
fi

# Proxy endpoint itself must stay on eth0 so it does not recurse into tun0.
# Route via the real gateway (not on-link) since host.docker.internal is
# usually on a different subnet (docker0) than this container's own network.
if [ -n "$ORIG_GATEWAY" ]; then
    ip route replace "${PROXY_HOST_IP}/32" via "$ORIG_GATEWAY" dev eth0
else
    echo "[警告] 无法确定原始默认网关，回退为直连路由（可能导致代理不可达）"
    ip route replace "${PROXY_HOST_IP}/32" dev eth0
fi

# Container-local connected route to the Docker bridge remains present.
ip route del default 2>/dev/null || true
ip route add default via 198.18.0.1 dev tun0 metric 1

FWD="CC_GATEWAY_FORWARD"
if iptables -S "$FWD" >/dev/null 2>&1; then iptables -F "$FWD"; else iptables -N "$FWD"; fi
while iptables -C FORWARD -j "$FWD" 2>/dev/null; do iptables -D FORWARD -j "$FWD" || true; done
iptables -A "$FWD" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A "$FWD" -i eth0 -o tun0 -j ACCEPT
iptables -A "$FWD" -i tun0 -o eth0 -j ACCEPT
iptables -A "$FWD" -j RETURN
iptables -I FORWARD 1 -j "$FWD"

OUT="CC_GATEWAY_OUTPUT"
if iptables -S "$OUT" >/dev/null 2>&1; then iptables -F "$OUT"; else iptables -N "$OUT"; fi
while iptables -C OUTPUT -j "$OUT" 2>/dev/null; do iptables -D OUTPUT -j "$OUT" || true; done
iptables -A "$OUT" -o lo -j ACCEPT
iptables -A "$OUT" -o tun0 -j ACCEPT
iptables -A "$OUT" -o eth0 -d "$PROXY_HOST_IP" -p tcp --dport "$PROXY_PORT" -j ACCEPT
iptables -A "$OUT" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A "$OUT" -j RETURN
iptables -I OUTPUT 1 -j "$OUT"

echo "[+] gateway ready: $PROXY_URL"
exec tun2socks -device tun0 -proxy "$PROXY_URL" -interface eth0 -loglevel info
