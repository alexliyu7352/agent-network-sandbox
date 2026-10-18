#!/bin/bash
set -Eeuo pipefail

# Claude Code / development "network-only session".
# The shell and every fork/exec descendant remain in the host namespace
# and host filesystem; only network traffic is classified by net_cls.
# Ubuntu 20.04 target: cgroup v1 net_cls + iptables-legacy + fwmark routing.
#
# Security model:
#   * IPv4 session traffic is policy-routed to the Docker tproxy gateway.
#   * Final IPv4 egress is fail-closed in mangle/POSTROUTING: only loopback
#     or the gateway Docker interface is allowed.
#   * IPv6 is fail-closed for this session. It is NOT sent directly to the
#     host's physical interface and is not expected to work through the
#     current IPv4-only gateway design.
#   * All IPv4 UDP/TCP destination port 53 traffic from this cgroup is DNATed
#     to 1.1.1.1:53, regardless of the original DNS server address.
#   * Custom iptables chains and routing state are uniquely named per session.
#   * A detached watchdog owns cleanup after the interactive shell exits.
#
# IMPORTANT: this does NOT attempt to hide or bypass third-party detection.
# It only provides a separate, reproducible network path for a shell session.

CGROOT=/sys/fs/cgroup/net_cls,net_prio
GATEWAY_CONTAINER=${GATEWAY_CONTAINER:-tproxy-gateway}

UID_NOW=$(id -u)
USER_NOW=$(id -un)
RUNTIME_DIR=/run/user/$UID_NOW
STATE_DIR="$RUNTIME_DIR/safe-net-session"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

need_root() { sudo -v; }

status() {
    echo "=== active session cgroups ==="
    sudo -n find "$CGROOT" -maxdepth 1 -mindepth 1 -type d -name "ccsess-${UID_NOW}-*" -print 2>/dev/null || true
    echo

    echo "=== matching IPv4 iptables rules ==="
    sudo -n iptables -w -t mangle -S OUTPUT 2>/dev/null | grep -- '-m cgroup --cgroup' || true
    sudo -n iptables -w -t mangle -S POSTROUTING 2>/dev/null | grep -- '-m cgroup --cgroup' || true
    sudo -n iptables -w -t nat -S OUTPUT 2>/dev/null | grep -- '-m cgroup --cgroup' || true
    sudo -n iptables -w -t nat -S POSTROUTING 2>/dev/null | grep -- '-m cgroup --cgroup' || true
    sudo -n iptables -w -S OUTPUT 2>/dev/null | grep -- '-m cgroup --cgroup' || true

    echo
    echo "=== matching IPv6 ip6tables rules ==="
    sudo -n ip6tables -w -S OUTPUT 2>/dev/null | grep -- '-m cgroup --cgroup' || true

    echo
    echo "=== fwmark rules ==="
    # 修复：ip rule show 输出时可能会省略 /0xffffffff，去除强匹配
    sudo -n ip rule show | grep -E 'fwmark 0x4[0-9a-f]+' || true

    echo
    echo "=== routing tables owned by this UID range ==="
    sudo -n ip route show table main >/dev/null 2>&1 || true
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    sed -n '1,45p' "$0"
    echo
    echo "  $0                 start isolated shell"
    echo "  $0 --status        show active session state"
    echo "  $0 --cleanup       remove stale sessions for this UID"
    exit 0
fi

need_root

if [[ ${1:-} == --status ]]; then
    status
    exit 0
fi

if [[ ${1:-} == --cleanup ]]; then
    echo "[*] 正在彻底扫描并清理本 UID (${UID_NOW}) 的所有残留网络会话..."
    sudo -n bash -s -- "$UID_NOW" "$CGROOT" <<'CLEANUP_STALE'
set -u
UID_NOW="$1"
CGROOT="$2"

# 1. 终止残留进程并删除现有 cgroup 目录
for cg in "$CGROOT"/ccsess-"${UID_NOW}"-*; do
    [ -d "$cg" ] || continue
    for pid in $(cat "$cg/cgroup.procs" 2>/dev/null || true); do
        kill -TERM "$pid" 2>/dev/null || true
    done
    sleep 0.5
    for pid in $(cat "$cg/cgroup.procs" 2>/dev/null || true); do
        kill -KILL "$pid" 2>/dev/null || true
    done
    rmdir "$cg" 2>/dev/null || true
done

# 2. 无论 cgroup 是否存在，直接扫描清理属于本 UID 的所有 IPv4 跳转规则
for tbl in filter mangle nat; do
    iptables -w -t $tbl -S 2>/dev/null | grep -E "CC[FMNPS]${UID_NOW}[0-9]+" | sed 's/^-A /-D /' | while read -r rule; do
        [ -n "$rule" ] && iptables -w -t $tbl $rule 2>/dev/null || true
    done
done

# 3. 清理属于本 UID 范围的 IPv6 规则
ip6tables -w -S OUTPUT 2>/dev/null | grep -E -- "-m cgroup --cgroup (0x4[0-9a-fA-F]+|[0-9]+)\b" | sed 's/^-A /-D /' | while read -r rule; do
    [ -n "$rule" ] && ip6tables -w $rule 2>/dev/null || true
done

# 4. 删除所有孤儿自定义链
for tbl in filter mangle nat; do
    for chain in $(iptables -w -t $tbl -S 2>/dev/null | sed -n "s/^-N \(CC[FMNPS]${UID_NOW}[0-9]*\)$/\1/p"); do
        iptables -w -t $tbl -F "$chain" 2>/dev/null || true
        iptables -w -t $tbl -X "$chain" 2>/dev/null || true
    done
done

# 5. 清理策略路由规则
while read -r pref rest; do
    pref="${pref%:}"
    [ -n "$pref" ] || continue
    if echo "$rest" | grep -qE "fwmark (0x4[0-9a-fA-F]+|[0-9]+)(/0xffffffff)?"; then
        table="$(sed -n 's/.*lookup \([0-9][0-9]*\).*/\1/p' <<<"$rest")"
        [ -n "$table" ] && ip rule del priority "$pref" table "$table" 2>/dev/null || true
        [ -n "$table" ] && ip route flush table "$table" 2>/dev/null || true
    fi
done < <(ip rule show)

CLEANUP_STALE
    echo "[+] 残留会话与防火墙规则清理完成。"
    exit 0
fi

for cmd in docker ip iptables ip6tables flock; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "[!] 缺少命令：$cmd"; exit 1; }
done

IPTV=$(iptables -V 2>&1)
grep -q legacy <<<"$IPTV" || {
    echo "[!] 当前不是 iptables-legacy：$IPTV"
    exit 1
}
IP6TV=$(ip6tables -V 2>&1)
grep -q legacy <<<"$IP6TV" || {
    echo "[!] 当前不是 ip6tables-legacy：$IP6TV"
    exit 1
}

[[ -d "$CGROOT" && -f "$CGROOT/net_cls.classid" ]] || {
    echo "[!] 找不到 net_cls hierarchy：$CGROOT"
    exit 1
}

# 引入强大的全局分配锁与精确的 classid 碰撞检测
ALLOC_LOCK="$RUNTIME_DIR/allocator.lock"
exec 8>"$ALLOC_LOCK"
flock 8

BASE_ID=$(( ($(date +%s) % 1000000) * 4096 + ($$ % 4096) ))
INSTANCE=""
CLASSID_DEC=""

for n in $(seq 0 1000); do
    CANDIDATE=$((BASE_ID + n))
    CANDIDATE_PATH="$CGROOT/ccsess-${UID_NOW}-${CANDIDATE}"
    [[ -e "$CANDIDATE_PATH" ]] && continue

    CANDIDATE_CLASSID=$((0x40000000 + (CANDIDATE & 0x0fffffff)))
    CLASS_IN_USE=0
    
    # 严格遍历所有活动 cgroup，防止任何形式的 net_cls 标记复用
    for cg in "$CGROOT"/ccsess-*; do
        [[ -d "$cg" ]] || continue
        existing="$(cat "$cg/net_cls.classid" 2>/dev/null || echo 0)"
        if [[ "$existing" == "$CANDIDATE_CLASSID" ]]; then
            CLASS_IN_USE=1
            break
        fi
    done
    [[ "$CLASS_IN_USE" == 0 ]] || continue

    INSTANCE="$CANDIDATE"
    CLASSID_DEC="$CANDIDATE_CLASSID"
    break
done

[[ -n "$INSTANCE" ]] || { flock -u 8; echo "[!] 无法分配唯一 session instance/classid"; exit 1; }

CGROUP_NAME="ccsess-${UID_NOW}-${INSTANCE}"
CGROUP_PATH="$CGROOT/$CGROUP_NAME"
CLASSID_HEX=$(printf '0x%08x' "$CLASSID_DEC")
MARK_HEX="$CLASSID_HEX"

RULE_PRIORITY=""
for p in $(seq 100 199); do
    if ! ip rule show | grep -qE "^[[:space:]]*${p}:"; then
        RULE_PRIORITY=$p
        break
    fi
done
[[ -n "$RULE_PRIORITY" ]] || { flock -u 8; echo "[!] 100-199 没有可用 ip rule priority"; exit 1; }
TABLE_ID=$((10000 + RULE_PRIORITY))

FCHAIN="CCF${UID_NOW}${INSTANCE}"
MCHAIN="CCM${UID_NOW}${INSTANCE}"
NCHAIN="CCN${UID_NOW}${INSTANCE}"
PCHAIN="CCP${UID_NOW}${INSTANCE}"
SCHAIN="CCS${UID_NOW}${INSTANCE}"

GATEWAY_PID=$(sudo -n docker inspect -f '{{.State.Pid}}' "$GATEWAY_CONTAINER" 2>/dev/null || true)
GATEWAY_IP=$(sudo -n docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$GATEWAY_CONTAINER" 2>/dev/null || true)
[[ -n "$GATEWAY_PID" && "$GATEWAY_PID" != 0 && -n "$GATEWAY_IP" ]] || {
    flock -u 8
    echo "[!] $GATEWAY_CONTAINER 没有运行。"
    exit 1
}

ROUTE_INFO=$(ip route get "$GATEWAY_IP" 2>/dev/null || true)
DOCKER_IF=$(awk '{for(i=1;i<=NF;i++) if($i=="dev" && i<NF){print $(i+1); exit}}' <<<"$ROUTE_INFO")
[[ -n "$DOCKER_IF" ]] || {
    flock -u 8
    echo "[!] 无法确定到 gateway 的 Docker interface"
    exit 1
}

if ! sudo -n nsenter -t "$GATEWAY_PID" -n ip link show tun0 >/dev/null 2>&1; then
    flock -u 8
    echo "[!] gateway 中不存在 tun0。"
    exit 1
fi

# IPv4 sanity check: gateway must be a non-host route through the Docker link.
GATEWAY_ROUTE_DEV=$(ip route get "$GATEWAY_IP" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev" && i<NF){print $(i+1); exit}}')
[[ "$GATEWAY_ROUTE_DEV" == "$DOCKER_IF" ]] || {
    flock -u 8
    echo "[!] gateway route does not resolve through expected interface: $GATEWAY_ROUTE_DEV != $DOCKER_IF"
    exit 1
}

# ------------------------------
# Cleanup state
# ------------------------------
CLEANED=0
cleanup_current() {
    [[ "$CLEANED" == 1 ]] && return 0
    CLEANED=1
    set +e

    # Blind delete (-D) safely ignores hex/decimal string mismatches
    iptables -w -t nat -D OUTPUT -m cgroup --cgroup "$CLASSID_HEX" -j "$NCHAIN" 2>/dev/null || true
    iptables -w -t mangle -D OUTPUT -m cgroup --cgroup "$CLASSID_HEX" -j "$MCHAIN" 2>/dev/null || true
    iptables -w -t mangle -D POSTROUTING -m cgroup --cgroup "$CLASSID_HEX" -j "$PCHAIN" 2>/dev/null || true
    iptables -w -t nat -D POSTROUTING -m cgroup --cgroup "$CLASSID_HEX" -j "$SCHAIN" 2>/dev/null || true
    iptables -w -D OUTPUT -m cgroup --cgroup "$CLASSID_HEX" -j "$FCHAIN" 2>/dev/null || true

    ip6tables -w -D OUTPUT -m cgroup --cgroup "$CLASSID_HEX" -d ::1/128 -j ACCEPT 2>/dev/null || true
    ip6tables -w -D OUTPUT -m cgroup --cgroup "$CLASSID_HEX" -j REJECT --reject-with icmp6-adm-prohibited 2>/dev/null || true

    iptables -w -t nat -F "$NCHAIN" 2>/dev/null || true
    iptables -w -t nat -X "$NCHAIN" 2>/dev/null || true
    iptables -w -t nat -F "$SCHAIN" 2>/dev/null || true
    iptables -w -t nat -X "$SCHAIN" 2>/dev/null || true
    iptables -w -t mangle -F "$MCHAIN" 2>/dev/null || true
    iptables -w -t mangle -X "$MCHAIN" 2>/dev/null || true
    iptables -w -t mangle -F "$PCHAIN" 2>/dev/null || true
    iptables -w -t mangle -X "$PCHAIN" 2>/dev/null || true
    iptables -w -F "$FCHAIN" 2>/dev/null || true
    iptables -w -X "$FCHAIN" 2>/dev/null || true

    # Delete only the policy rule carrying our exact mark/table combination.
    while sudo -n ip rule show 2>/dev/null | grep -qE "^[[:space:]]*$RULE_PRIORITY:.*fwmark $MARK_HEX(/0xffffffff)?.*lookup $TABLE_ID([[:space:]]|$)"; do
        sudo -n ip rule del priority "$RULE_PRIORITY" table "$TABLE_ID" 2>/dev/null || break
    done
    sudo -n ip route flush table "$TABLE_ID" 2>/dev/null || true

    if [[ -d "$CGROUP_PATH" ]]; then
        for pid in $(sudo -n cat "$CGROUP_PATH/cgroup.procs" 2>/dev/null || true); do
            [[ "$pid" == "$$" ]] && continue
            sudo -n kill -TERM "$pid" 2>/dev/null || true
        done
        sleep 1
        for pid in $(sudo -n cat "$CGROUP_PATH/cgroup.procs" 2>/dev/null || true); do
            [[ "$pid" == "$$" ]] && continue
            sudo -n kill -KILL "$pid" 2>/dev/null || true
        done
        sudo -n rmdir "$CGROUP_PATH" 2>/dev/null || true
    fi

    rm -f "$STATE_DIR/$INSTANCE.watchdog" "$STATE_DIR/$INSTANCE.pipe" 2>/dev/null || true
}

# During setup, any error must roll back everything created so far.
# After the detached watchdog is started, it owns cleanup of the session.
SETUP_PHASE=1
trap 'if [[ "$SETUP_PHASE" == 1 ]]; then cleanup_current; fi' EXIT

# ------------------------------
# Create cgroup and network policy
# ------------------------------
sudo -n mkdir "$CGROUP_PATH"
printf '%u\n' "$CLASSID_DEC" | sudo -n tee "$CGROUP_PATH/net_cls.classid" >/dev/null

# Custom chains; never flush system built-ins.
sudo -n iptables -w -t mangle -N "$MCHAIN"
sudo -n iptables -w -N "$FCHAIN"
sudo -n iptables -w -t nat -N "$NCHAIN"
sudo -n iptables -w -t mangle -N "$PCHAIN"
sudo -n iptables -w -t nat -N "$SCHAIN"

# cgroup -> packet mark.
sudo -n iptables -w -t mangle -A "$MCHAIN" \
    -m cgroup --cgroup "$CLASSID_HEX" \
    -j MARK --set-mark "$MARK_HEX"
sudo -n iptables -w -t mangle -A "$MCHAIN" -j RETURN
sudo -n iptables -w -t mangle -I OUTPUT 1 \
    -m cgroup --cgroup "$CLASSID_HEX" -j "$MCHAIN"

# Route: the gateway itself is reachable through Docker bridge; default goes to gateway.
sudo -n ip route add "$GATEWAY_IP/32" dev "$DOCKER_IF" scope link table "$TABLE_ID"
sudo -n ip route add default via "$GATEWAY_IP" dev "$DOCKER_IF" table "$TABLE_ID"
sudo -n ip rule add priority "$RULE_PRIORITY" fwmark "$MARK_HEX/0xffffffff" table "$TABLE_ID"

# The allocator lock is no longer needed after the rule has been installed.
flock -u 8
# [新增]: 允许源地址为 127.0.0.1 的 DNS 劫持包从 Docker 网桥发出，防止内核将其作为火星包丢弃
sudo -n sysctl -w "net.ipv4.conf.${DOCKER_IF}.route_localnet=1" >/dev/null 2>&1 || true
# Filter safety net.
# NOTE: OUTPUT's -o value is observed before mangle/OUTPUT rerouting has fully
# settled. Therefore an OUTPUT '-o DOCKER_IF' allow rule is NOT authoritative.
# The authoritative final-egress check is mangle/POSTROUTING in PCHAIN below.
sudo -n iptables -w -A "$FCHAIN" -o lo -j ACCEPT
sudo -n iptables -w -A "$FCHAIN" -o "$DOCKER_IF" -d "$GATEWAY_IP" -j ACCEPT
sudo -n iptables -w -A "$FCHAIN" \
    -d 10.0.0.0/8 -j REJECT --reject-with icmp-port-unreachable
sudo -n iptables -w -A "$FCHAIN" \
    -d 172.16.0.0/12 -j REJECT --reject-with icmp-port-unreachable
sudo -n iptables -w -A "$FCHAIN" \
    -d 192.168.0.0/16 -j REJECT --reject-with icmp-port-unreachable
sudo -n iptables -w -A "$FCHAIN" \
    -d 169.254.0.0/16 -j REJECT --reject-with icmp-port-unreachable
sudo -n iptables -w -A "$FCHAIN" \
    -d 100.64.0.0/10 -j REJECT --reject-with icmp-port-unreachable
sudo -n iptables -w -A "$FCHAIN" -j ACCEPT
sudo -n iptables -w -I OUTPUT 1 \
    -m cgroup --cgroup "$CLASSID_HEX" -j "$FCHAIN"

# 引入强制 DNS 劫持，无视目标 IP，截获所有 53 端口流量
sudo -n iptables -w -t nat -A "$NCHAIN" \
    -m cgroup --cgroup "$CLASSID_HEX" \
    -p udp --dport 53 \
    -j DNAT --to-destination 1.1.1.1:53
sudo -n iptables -w -t nat -A "$NCHAIN" \
    -m cgroup --cgroup "$CLASSID_HEX" \
    -p tcp --dport 53 \
    -j DNAT --to-destination 1.1.1.1:53
sudo -n iptables -w -t nat -A "$NCHAIN" -j RETURN
sudo -n iptables -w -t nat -I OUTPUT 1 \
    -m cgroup --cgroup "$CLASSID_HEX" -j "$NCHAIN"

# Final IPv4 egress safety net.
# This deliberately has NO ESTABLISHED,RELATED bypass: every packet from the
# cgroup must leave via loopback or the Docker interface, regardless of state.
sudo -n iptables -w -t mangle -A "$PCHAIN" -o lo -j ACCEPT
sudo -n iptables -w -t mangle -A "$PCHAIN" -o "$DOCKER_IF" -j ACCEPT
sudo -n iptables -w -t mangle -A "$PCHAIN" -j DROP
sudo -n iptables -w -t mangle -I POSTROUTING 1 \
    -m cgroup --cgroup "$CLASSID_HEX" -j "$PCHAIN"

# IPv4 source-address correction for return traffic from the Docker gateway.
# MASQUERADE makes the session look like traffic sourced from the Docker bridge,
# allowing the gateway to route replies back to this host cleanly.
sudo -n iptables -w -t nat -A "$SCHAIN" -o "$DOCKER_IF" -j MASQUERADE
sudo -n iptables -w -t nat -A "$SCHAIN" -j RETURN
sudo -n iptables -w -t nat -I POSTROUTING 1 \
    -m cgroup --cgroup "$CLASSID_HEX" -j "$SCHAIN"

# IPv6 fail-closed policy. Local IPv6 loopback is retained for local development;
# all other IPv6 traffic from this cgroup is explicitly rejected.
sudo -n ip6tables -w -I OUTPUT 1 \
    -m cgroup --cgroup "$CLASSID_HEX" -d ::1/128 -j ACCEPT
sudo -n ip6tables -w -I OUTPUT 2 \
    -m cgroup --cgroup "$CLASSID_HEX" -j REJECT --reject-with icmp6-adm-prohibited

# ------------------------------
# Start detached watchdog
# ------------------------------
WATCHDOG="$STATE_DIR/$INSTANCE.watchdog"
cat > "$WATCHDOG" <<'WATCHDOG_BODY'
#!/bin/bash
set -u
CGROUP_PATH="$1"
SESSION_PID="$2"
CLASSID_HEX="$3"
MARK_HEX="$4"
TABLE_ID="$5"
RULE_PRIORITY="$6"
FCHAIN="$7"
MCHAIN="$8"
NCHAIN="$9"
PCHAIN="${10}"
SCHAIN="${11}"
STATE_FILE="${12}"
USER_TTY="${13:-}"

cleanup() {
    set +e

    iptables -w -t nat -D OUTPUT -m cgroup --cgroup "$CLASSID_HEX" -j "$NCHAIN" 2>/dev/null || true
    iptables -w -t mangle -D OUTPUT -m cgroup --cgroup "$CLASSID_HEX" -j "$MCHAIN" 2>/dev/null || true
    iptables -w -t mangle -D POSTROUTING -m cgroup --cgroup "$CLASSID_HEX" -j "$PCHAIN" 2>/dev/null || true
    iptables -w -t nat -D POSTROUTING -m cgroup --cgroup "$CLASSID_HEX" -j "$SCHAIN" 2>/dev/null || true
    iptables -w -D OUTPUT -m cgroup --cgroup "$CLASSID_HEX" -j "$FCHAIN" 2>/dev/null || true

    ip6tables -w -D OUTPUT -m cgroup --cgroup "$CLASSID_HEX" -d ::1/128 -j ACCEPT 2>/dev/null || true
    ip6tables -w -D OUTPUT -m cgroup --cgroup "$CLASSID_HEX" -j REJECT --reject-with icmp6-adm-prohibited 2>/dev/null || true

    iptables -w -t nat -F "$NCHAIN" 2>/dev/null || true
    iptables -w -t nat -X "$NCHAIN" 2>/dev/null || true
    iptables -w -t nat -F "$SCHAIN" 2>/dev/null || true
    iptables -w -t nat -X "$SCHAIN" 2>/dev/null || true
    iptables -w -t mangle -F "$MCHAIN" 2>/dev/null || true
    iptables -w -t mangle -X "$MCHAIN" 2>/dev/null || true
    iptables -w -t mangle -F "$PCHAIN" 2>/dev/null || true
    iptables -w -t mangle -X "$PCHAIN" 2>/dev/null || true
    iptables -w -F "$FCHAIN" 2>/dev/null || true
    iptables -w -X "$FCHAIN" 2>/dev/null || true

    # 修复：移除掩码强匹配，通过优先级安全删除
    while ip rule show 2>/dev/null | grep -qE "^[[:space:]]*$RULE_PRIORITY:.*fwmark $MARK_HEX(/0xffffffff)?.*lookup $TABLE_ID([[:space:]]|$)"; do
        ip rule del priority "$RULE_PRIORITY" table "$TABLE_ID" 2>/dev/null || break
    done
    ip route flush table "$TABLE_ID" 2>/dev/null || true

    if [ -d "$CGROUP_PATH" ]; then
        for p in $(cat "$CGROUP_PATH/cgroup.procs" 2>/dev/null || true); do
            kill -TERM "$p" 2>/dev/null || true
        done
        sleep 1
        for p in $(cat "$CGROUP_PATH/cgroup.procs" 2>/dev/null || true); do
            kill -KILL "$p" 2>/dev/null || true
        done
        rmdir "$CGROUP_PATH" 2>/dev/null || true
    fi
    rm -f "$STATE_FILE"

    if [ -n "$USER_TTY" ] && [ -c "$USER_TTY" ]; then
        printf '[+] session cleanup complete\n' > "$USER_TTY" 2>/dev/null || true
    fi
}

trap cleanup EXIT INT TERM HUP

echo "$$" > "$STATE_FILE"
while kill -0 "$SESSION_PID" 2>/dev/null; do
    sleep 1
done

# The session leader is gone. Any descendants left in this cgroup are
# considered part of the session and are terminated before network cleanup.
cleanup
exit 0
WATCHDOG_BODY
chmod 700 "$WATCHDOG"

# The current script PID becomes the interactive shell PID via exec. No FIFO,
# background interactive shell, or job-control workaround is necessary.
SESSION_PID=$$
CURRENT_TTY=$(tty || echo "")

sudo -n nohup bash "$WATCHDOG" \
    "$CGROUP_PATH" "$SESSION_PID" "$CLASSID_HEX" "$MARK_HEX" \
    "$TABLE_ID" "$RULE_PRIORITY" "$FCHAIN" "$MCHAIN" "$NCHAIN" "$PCHAIN" "$SCHAIN" \
    "$WATCHDOG" "$CURRENT_TTY" >/dev/null 2>&1 &

# From this point the detached watchdog owns cleanup.
SETUP_PHASE=0
trap - EXIT

# Release the allocator FD after setup. The lock file itself is harmless and
# can be reused by future sessions.
flock -u 8 2>/dev/null || true

printf '\n[+] session started\n'
printf '    shell PID : %s\n' "$SESSION_PID"
printf '    cgroup    : %s\n' "$CGROUP_PATH"
printf '    classid   : %s\n' "$CLASSID_HEX"
printf '    fwmark    : %s\n' "$MARK_HEX"
printf '    route tbl : %s\n' "$TABLE_ID"
printf '    gateway   : %s via %s\n' "$GATEWAY_IP" "$DOCKER_IF"
printf '    IPv6      : fail-closed\n'
printf '\n'
printf '    GUI/filesystem remain native host environment.\n'
printf '    Try: xeyes ; ip route get 1.1.1.1 ; curl -4 https://ifconfig.me\n'
printf '    IPv6 test should fail: curl -6 https://ifconfig.me\n'
printf '    Exit with: exit\n\n'

# cgroup.procs includes the current process and causes bash children to remain
# in the same cgroup after exec.
echo "$SESSION_PID" | sudo -n tee "$CGROUP_PATH/cgroup.procs" >/dev/null

# Replace this process with the interactive shell. PID remains stable, so the
# watchdog continues to monitor the exact session leader.
if [ -t 0 ]; then
    exec bash -i
else
    exec bash
fi
