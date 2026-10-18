#!/bin/bash
# 运行环境：在 proxy_safe.sh 启动的沙盒 Shell 中运行（无需 sudo）

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "======================================================"
echo "    Claude Network Sandbox Security Test Suite"
echo "======================================================"

# 预设物理网卡名称（根据你的环境输出推测为 enp39s0）
PHYSICAL_IF="enp39s0"
# 本地局域网网关（用于测试内网隔离）
LAN_GATEWAY="192.168.1.1"

# 1. 基础 IPv4 连通性与 IP 验证
echo -n "[1] IPv4 Internet Access & IP Check ... "
IP4=$(curl -4 -s --connect-timeout 5 https://ifconfig.me || echo "FAILED")
if [ "$IP4" != "FAILED" ]; then
    echo -e "${GREEN}PASS${NC} (Proxied IP: $IP4)"
else
    echo -e "${RED}FAIL${NC} (Cannot reach internet)"
fi

# 2. IPv6 防泄漏测试 (Fail-Closed)
echo -n "[2] IPv6 Leak Prevention ... "
if curl -6 -s --connect-timeout 3 https://ifconfig.me >/dev/null 2>&1; then
    echo -e "${RED}FAIL${NC} (IPv6 traffic leaked!)"
else
    echo -e "${GREEN}PASS${NC} (IPv6 successfully blocked/dropped)"
fi

# 3. 局域网隔离测试 (RFC1918)
echo -n "[3] LAN Isolation (Accessing $LAN_GATEWAY) ... "
if curl -s --connect-timeout 2 "http://$LAN_GATEWAY" >/dev/null 2>&1; then
    echo -e "${RED}FAIL${NC} (Can access host LAN!)"
else
    echo -e "${GREEN}PASS${NC} (LAN access successfully rejected)"
fi

# 4. 本地回环测试 (127.0.0.1)
# 预期：Agent 可以访问本机的 Localhost 服务（沙盒共享网络命名空间）
echo -n "[4] Host Loopback Access (127.0.0.1) ... "
if ping -c 1 -W 1 127.0.0.1 >/dev/null 2>&1; then
    echo -e "${GREEN}PASS${NC} (Loopback access works)"
else
    echo -e "${RED}FAIL${NC} (Loopback access broken)"
fi

# 5. 越狱测试：强制绑定物理网卡逃逸
echo -n "[5] Jailbreak: Bind to physical NIC ($PHYSICAL_IF) ... "
if curl -4 -s --connect-timeout 3 --interface "$PHYSICAL_IF" https://ifconfig.me >/dev/null 2>&1; then
    echo -e "${RED}FAIL${NC} (Successfully bypassed sandbox via physical NIC!)"
else
    echo -e "${GREEN}PASS${NC} (Physical NIC bind dropped by PCHAIN)"
fi

# 6. 越狱测试：绕过系统 DNS (UDP 53)
# 尝试直接向外部 DNS 服务器 (如 Google 8.8.8.8) 发送原始 UDP 包
echo -n "[6] Jailbreak: Bypass local DNS stub (UDP 53) ... "
DIG_RES=$(dig +short @8.8.8.8 google.com +time=3 2>/dev/null || echo "FAILED")
if [ -n "$DIG_RES" ] && [ "$DIG_RES" != "FAILED" ]; then
    echo -e "${GREEN}PASS${NC} (External DNS works, but routed via proxy)"
else
    echo -e "${YELLOW}INFO${NC} (External DNS blocked or tun2socks UDP drop)"
fi

# 7. Agent 代理感知测试 (无 Sudo 能否发现被监控)
echo -n "[7] Sandbox Awareness (Can Agent detect isolation?) ... "
if ip rule show 2>/dev/null | grep -q "fwmark"; then
    echo -e "${RED}DETECTED${NC} (Agent can see 'ip rule' and fwmarks)"
elif cat /proc/self/cgroup 2>/dev/null | grep -q "net_cls"; then
    echo -e "${RED}DETECTED${NC} (Agent can read cgroup boundaries)"
else
    echo -e "${GREEN}HIDDEN${NC} (Agent cannot easily detect network hooks)"
fi

# ... (承接之前的 测试 1 到 7) ...

# 8. 子进程网络继承测试 (Subshell)
echo -n "[8] Child Process Inheritance (Bash subshell) ... "
# 启动一个独立的 bash 子进程去获取 IP，预期它也会通过代理，拿到和父进程一样的 IP
CHILD_IP=$(bash -c 'curl -4 -s --connect-timeout 5 https://ifconfig.me' || echo "FAILED")
if [ "$CHILD_IP" != "FAILED" ] && [ "$CHILD_IP" == "$IP4" ]; then
    echo -e "${GREEN}PASS${NC} (Child process shares proxy IP: $CHILD_IP)"
else
    echo -e "${RED}FAIL${NC} (Child IP mismatch or failed: $CHILD_IP)"
fi

# 9. 异构深度子进程测试 (Python HTTP Request)
echo -n "[9] Deep Child Process (Python execution) ... "
# 模拟 Agent 生成并执行了一段 Python 代码发起网络请求
PYTHON_RES=$(python3 -c '
import urllib.request
try:
    req = urllib.request.urlopen("https://ifconfig.me", timeout=5)
    print(req.read().decode("utf-8"))
except Exception:
    print("FAILED")
' 2>/dev/null || echo "FAILED")

if [ "$PYTHON_RES" != "FAILED" ] && [ "$PYTHON_RES" == "$IP4" ]; then
    echo -e "${GREEN}PASS${NC} (Python child routed correctly via proxy)"
else
    echo -e "${RED}FAIL${NC} (Python child failed to route or IP mismatched)"
fi

# 10. 子进程底层越狱测试 (绑定真实网卡)
echo -n "[10] Child Process Jailbreak (Bind physical NIC) ... "
# 模拟 Agent 在子进程中尝试通过 curl --interface 强行绑定物理网卡逃逸
if bash -c "curl -4 -s --connect-timeout 3 --interface $PHYSICAL_IF https://ifconfig.me >/dev/null 2>&1"; then
    echo -e "${RED}FAIL${NC} (Child process ESCAPED sandbox via physical NIC!)"
else
    echo -e "${GREEN}PASS${NC} (Child process physical NIC bind blocked by kernel)"
fi

echo "======================================================"
echo "======================================================"
