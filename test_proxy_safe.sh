#!/usr/bin/env bash
set -Eeuo pipefail

# proxy_safe integration / security test harness.
#
# Safe by default. It does not stop/restart Docker and does not modify the host's
# main routing table. The optional --disruptive suite temporarily changes ONLY a
# session-specific policy table and stops/starts tproxy-gateway.
#
# Usage:
#   ./test_proxy_safe.sh [proxy_safe_script]
#   ./test_proxy_safe.sh [proxy_safe_script] --sessions 3
#   ./test_proxy_safe.sh [proxy_safe_script] --disruptive

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [[ ${1:-} == --self-test ]]; then
    exec python3 - --self-test <<'PYSELF'
import re
sample=b"[+] session started\n    shell PID : 123\n    cgroup    : /sys/fs/cgroup/net_cls,net_prio/ccsess-1000-123\n    classid   : 0x4000007b\n    fwmark    : 0x4000007b\n    route tbl : 10042\n    gateway   : 172.19.0.2 via br-test\n"
pat=re.compile(rb"\[\+\] session started.*?shell PID\s*:\s*(\d+).*?cgroup\s*:\s*(\S+).*?classid\s*:\s*(\S+).*?fwmark\s*:\s*(\S+).*?route tbl\s*:\s*(\d+).*?gateway\s*:\s*(\S+) via\s+(\S+)",re.S)
m=pat.search(sample)
assert m and m.group(1)==b"123" and m.group(5)==b"10042"
print("self-test: PASS")
PYSELF
fi
PROXY_SCRIPT="${1:-$SCRIPT_DIR/proxy_safe_final.sh}"
shift || true
SESSION_COUNT=3
DISRUPTIVE=0

while (($#)); do
    case "$1" in
        --sessions)
            [[ $# -ge 2 ]] || { echo "--sessions requires a number" >&2; exit 2; }
            SESSION_COUNT=$2
            shift 2
            ;;
        --disruptive)
            DISRUPTIVE=1
            shift
            ;;
        -h|--help)
            sed -n '1,35p' "$0"
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

echo "[*] 获取 sudo 权限以运行自动化测试套件..."
sudo -v || { echo "[!] 无法获取 sudo 权限，测试终止。" >&2; exit 1; }

exec python3 - "$PROXY_SCRIPT" "$SESSION_COUNT" "$DISRUPTIVE" <<'PY'
import base64
import http.server
import json
import os
import re
import select
import shlex
import signal
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Optional

PROXY = os.path.abspath(sys.argv[1])
SESSION_COUNT = int(sys.argv[2])
DISRUPTIVE = bool(int(sys.argv[3]))
UID = os.getuid()
CGROOT = "/sys/fs/cgroup/net_cls,net_prio"
GATEWAY_CONTAINER = os.environ.get("GATEWAY_CONTAINER", "tproxy-gateway")
STAMP = time.strftime("%Y%m%d-%H%M%S")
REPORT = Path(tempfile.gettempdir()) / f"proxy-safe-test-{STAMP}-{os.getpid()}"
REPORT.mkdir(mode=0o700)

PASS = FAIL = SKIP = WARN = 0
HOST_SERVER = None
HOST_SERVER_THREAD = None
HOST_PORT = None
SESSIONS = []

START_RE = re.compile(
    rb"\[\+\] session started.*?shell PID\s*:\s*(\d+).*?"
    rb"cgroup\s*:\s*(\S+).*?classid\s*:\s*(\S+).*?"
    rb"fwmark\s*:\s*(\S+).*?route tbl\s*:\s*(\d+).*?"
    rb"gateway\s*:\s*(\S+) via\s+(\S+)", re.S,
)
RC_RE = re.compile(rb"__PROXY_TEST_RC__:(-?\d+)\r?\n")

def log(msg: str = "") -> None:
    print(msg, flush=True)

def ok(msg: str) -> None:
    global PASS
    PASS += 1
    log(f"[PASS] {msg}")

def bad(msg: str) -> None:
    global FAIL
    FAIL += 1
    log(f"[FAIL] {msg}")

def skip(msg: str) -> None:
    global SKIP
    SKIP += 1
    log(f"[SKIP] {msg}")

def warn(msg: str) -> None:
    global WARN
    WARN += 1
    log(f"[WARN] {msg}")

def run(cmd, *, check=False, timeout=20, capture=True, input_text=None):
    return subprocess.run(
        cmd,
        check=check,
        timeout=timeout,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )

def sudo(*args, **kwargs):
    return run(["sudo", "-n", *args], **kwargs)

def cleanup_stale() -> None:
    try:
        sudo(PROXY, "--cleanup", timeout=30)
    except Exception:
        pass

def get_default_interface() -> Optional[str]:
    try:
        out = run(["ip", "route", "show", "default"], timeout=5).stdout
        m = re.search(r"^default .*? dev (\S+)", out, re.M)
        return m.group(1) if m else None
    except Exception:
        return None

def parse_start(data: bytes):
    m = START_RE.search(data)
    if not m:
        return None
    return {
        "shell_pid": int(m.group(1)),
        "cgroup": m.group(2).decode(),
        "classid": m.group(3).decode(),
        "mark": m.group(4).decode(),
        "table": int(m.group(5)),
        "gateway_ip": m.group(6).decode(),
        "docker_if": m.group(7).decode(),
    }

class SubprocessSession:
    def __init__(self, proxy: str, log_path: Path, index: int):
        self.proxy = proxy
        self.log_path = log_path
        self.index = index
        self.proc = None
        self.pid = None
        self.buf = bytearray()
        self.log_file = log_path.open("wb", buffering=0)
        self.meta = None

    def _read(self, timeout=0.25):
        if self.proc is None:
            return b""
        try:
            ready, _, _ = select.select([self.proc.stdout], [], [], timeout)
        except (OSError, ValueError):
            return b""
        if not ready:
            return b""
        try:
            data = os.read(self.proc.stdout.fileno(), 65536)
        except OSError:
            return b""
        if data:
            self.log_file.write(data)
            self.buf.extend(data)
        return data

    def _wait_regex(self, regex, timeout, start_pos=0):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            m = regex.search(self.buf, start_pos)
            if m:
                return m
            self._read(min(0.25, max(0.01, end - time.monotonic())))
        return None

    def start(self, timeout=30):
        self.proc = subprocess.Popen(
            ["bash", self.proxy],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=0
        )
        self.pid = self.proc.pid
        m = self._wait_regex(START_RE, timeout, 0)
        if not m:
            out_tail = self.buf[-1000:].decode(errors="replace")
            raise RuntimeError(f"session {self.index}: no start banner. Output tail:\n{out_tail}")
        self.meta = parse_start(bytes(self.buf))
        return self.meta

    def command(self, command: str, timeout=30):
        if self.proc is None:
            raise RuntimeError("session is closed")
        
        encoded = base64.b64encode(command.encode("utf-8")).decode("utf-8")
        payload = f"echo '{encoded}' | base64 -d | bash; rc=$?; printf '\\n__PROXY_TEST_RC__:%d\\n' \"$rc\"\n"
        
        before = len(self.buf)
        try:
            self.proc.stdin.write(payload.encode("utf-8"))
            self.proc.stdin.flush()
        except OSError:
            raise RuntimeError("failed to write command to session")
            
        m = self._wait_regex(RC_RE, timeout, start_pos=before)
        if not m:
            raise TimeoutError(f"session {self.index}: command timeout: {command}")
            
        tail = bytes(self.buf[before:m.end()])
        out = tail.decode(errors="replace")
        return int(m.group(1)), out

    def exit(self, timeout=20):
        if self.proc is None:
            return None
        try:
            self.proc.stdin.write(b"exit\n")
            self.proc.stdin.flush()
        except OSError:
            pass
        
        try:
            status = self.proc.wait(timeout)
        except subprocess.TimeoutExpired:
            self.proc.terminate()
            try:
                status = self.proc.wait(5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                status = self.proc.wait(5)
        self.close()
        return status

    def close(self):
        if self.proc is not None:
            try:
                self.proc.stdin.close()
            except Exception:
                pass
            try:
                self.proc.stdout.close()
            except Exception:
                pass
            self.proc = None
        try:
            self.log_file.close()
        except Exception:
            pass

def start_session(name: str) -> SubprocessSession:
    s = SubprocessSession(PROXY, REPORT / f"{name}.log", len(SESSIONS) + 1)
    meta = s.start()
    SESSIONS.append(s)
    (REPORT / f"{name}.json").write_text(json.dumps(meta, indent=2) + "\n")
    log(f"  session {s.index}: {meta}")
    return s

def assert_command(s: SubprocessSession, name: str, command: str, expected_rc=0, must_contain=None):
    try:
        rc, out = s.command(command)
    except Exception as exc:
        bad(f"{name}: {exc}")
        return None, ""
    if rc != expected_rc:
        bad(f"{name}: rc={rc}, expected={expected_rc}; output=\n{out.strip()[-800:]!r}")
        return rc, out
    if must_contain is not None and must_contain not in out:
        bad(f"{name}: required text not found: {must_contain!r}. Actual output:\n{out.strip()}")
        return rc, out
    ok(name)
    return rc, out

def run_capture_counter(chain: str, table="mangle"):
    r = sudo("iptables", "-w", "-t", table, "-L", chain, "-n", "-v", "--line-numbers")
    if r.returncode != 0:
        return None
    rules = []
    for line in (r.stdout or "").splitlines():
        m = re.match(r"^\s*(\d+)\s+(\d+)\s+(\d+)\s+\S+", line)
        if m:
            rules.append((int(m.group(1)), int(m.group(2)), int(m.group(3)), line))
    return rules

def session_pchain_counters(meta):
    raw = sudo("iptables", "-w", "-t", "mangle", "-S").stdout or ""
    chain = None
    marker = meta["mark"]
    marker_dec = str(int(marker, 16))
    for ln in raw.splitlines():
        if "-N CCP" in ln:
            continue
        if (f"-m cgroup --cgroup {marker}" in ln or f"-m cgroup --cgroup {marker_dec}" in ln) and "POSTROUTING" in ln:
            m = re.search(r"-j (CCP\S+)", ln)
            if m:
                chain = m.group(1)
                break
    if chain is None:
        return None
    return run_capture_counter(chain, "mangle")

def start_host_server():
    global HOST_SERVER, HOST_SERVER_THREAD, HOST_PORT
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = b"proxy-safe-host-loopback-ok\n"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def log_message(self, *args):
            pass

    HOST_SERVER = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
    HOST_SERVER.daemon_threads = True
    HOST_PORT = HOST_SERVER.server_address[1]
    HOST_SERVER_THREAD = threading.Thread(target=HOST_SERVER.serve_forever, daemon=True)
    HOST_SERVER_THREAD.start()

def stop_host_server():
    if HOST_SERVER is not None:
        HOST_SERVER.shutdown()
        HOST_SERVER.server_close()

def unprivileged_command_script():
    return r'''if sudo -n -u nobody true 2>/dev/null; then
sudo -n -u nobody python3 -c 'import socket,subprocess,os; print("UID="+str(os.getuid()));
for name,cmd in [("SUDO",["sudo","-n","true"]),("IPROUTE",["ip","route","add","blackhole","203.0.113.250/32"]),("IPRULE",["ip","rule","add","pref","199","blackhole","203.0.113.251/32"]),("IPTABLES",["iptables","-w","-S","OUTPUT"]),("IP6TABLES",["ip6tables","-w","-S","OUTPUT"]),("LINK",["ip","link","set","lo","down"]),("NSENTER",["nsenter","-t","1","-n","true"])]:
  p=subprocess.run(cmd,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); print(name+"="+str(p.returncode))
try:
 s=socket.socket(socket.AF_PACKET,socket.SOCK_RAW,socket.htons(3)); print("AF_PACKET_RAW=ALLOWED"); s.close()
except PermissionError: print("AF_PACKET_RAW=DENIED")
except Exception as e: print("AF_PACKET_RAW=ERROR:"+type(e).__name__)'
else
 echo NOBODY_SPAWN=UNAVAILABLE
fi'''

def test_unprivileged(s: SubprocessSession):
    rc, out = assert_command(s, "unprivileged escape capability probe", unprivileged_command_script(), 0)
    if rc is None:
        return
    if "NOBODY_SPAWN=UNAVAILABLE" in out:
        skip("could not run the probe as nobody")
        return
    for label in ["SUDO", "IPROUTE", "IPRULE", "IPTABLES", "IP6TABLES", "LINK", "NSENTER"]:
        m = re.search(rf"{label}=(\d+)", out)
        if m and int(m.group(1)) != 0:
            ok(f"unprivileged {label.lower()} operation is denied")
        elif m:
            bad(f"unprivileged {label.lower()} operation unexpectedly succeeded")
        else:
            bad(f"missing {label} result")
    if "AF_PACKET_RAW=ALLOWED" in out:
        bad("unprivileged AF_PACKET raw socket is available")
    elif "AF_PACKET_RAW=DENIED" in out:
        ok("unprivileged AF_PACKET raw socket is denied")
    else:
        warn("AF_PACKET raw-socket result was inconclusive")

def test_private_dest_block(s):
    # 强制访问被明确 REJECT 的局域网网段
    cmd = "python3 -c 'import socket; s=socket.socket(); s.settimeout(2); s.connect((\"192.168.254.254\",80)); print(\"CONNECTED\")'"
    try:
        rc, out = s.command(cmd, timeout=6)
    except Exception as e:
        rc, out = -1, str(e)
    if rc != 0 and "CONNECTED" not in out:
        ok("reserved private-test address is blocked instead of connected")
    else:
        bad("reserved private-test address unexpectedly connected")

def get_gateway_pid():
    r = sudo("docker", "inspect", "-f", "{{.State.Pid}}", GATEWAY_CONTAINER)
    if r.returncode == 0 and r.stdout.strip().isdigit():
        return int(r.stdout.strip())
    return None

def gateway_running():
    r = sudo("docker", "inspect", "-f", "{{.State.Running}}", GATEWAY_CONTAINER)
    return r.returncode == 0 and r.stdout.strip() == "true"

def tun0_present():
    pid = get_gateway_pid()
    if not pid:
        return False
    r = sudo("nsenter", "-t", str(pid), "-n", "ip", "link", "show", "tun0")
    return r.returncode == 0

def external_probe(s: SubprocessSession, timeout=20):
    try:
        return s.command("curl -4 -fsS -I --connect-timeout 5 --max-time 15 http://1.1.1.1/ -o /dev/null", timeout=timeout)
    except Exception as e:
        return -1, str(e)

def test_single_session_network():
    log("=== single-session network tests ===")
    start_host_server()
    s = start_session("single")

    assert_command(
        s,
        "host loopback communication",
        f"curl -fsS --connect-timeout 3 --max-time 8 http://127.0.0.1:{HOST_PORT}/",
        0,
        "proxy-safe-host-loopback-ok",
    )
    
    rc, out = external_probe(s)
    if rc == 0:
        ok("external IPv4 HTTP through gateway")
    else:
        bad(f"external IPv4 HTTP failed: {out[-500:]!r}")

    dns = (
        "python3 -c 'import socket,random,struct; "
        "q=b\"\\x12\\x34\\x01\\x00\\x00\\x01\\x00\\x00\\x00\\x00\\x00\\x00\""
        "+b\"\\x07example\\x03com\\x00\"+b\"\\x00\\x01\\x00\\x01\"; "
        "s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(5); "
        "s.sendto(q,(\"1.1.1.1\",53)); print(\"DNS_REPLY=\"+str(len(s.recvfrom(4096)[0])))'"
    )
    rc, out = s.command(dns, timeout=10)
    if rc == 0 and "DNS_REPLY=" in out:
        ok("direct UDP/53 query is handled by the session network path")
    elif rc != 0:
        warn("direct UDP/53 probe did not receive a reply (SOCKS5 may drop UDP)")

    try:
        rc, out = s.command(
            "python3 -c 'import socket; x=socket.socket(socket.AF_INET6,socket.SOCK_STREAM); x.settimeout(3); x.connect((\"2606:4700:4700::1111\",443))'",
            timeout=6,
        )
    except Exception as e:
        rc, out = -1, str(e)
    
    if rc != 0:
        ok("IPv6 connection is fail-closed")
    else:
        bad("IPv6 connection unexpectedly succeeded")

    test_private_dest_block(s)
    test_unprivileged(s)

    cgroup_name = os.path.basename(s.meta["cgroup"])
    rc, out = assert_command(
        s,
        "child process inherits session cgroup",
        "python3 -c 'x=open(\"/proc/self/cgroup\").read(); print(x)'",
        0,
        cgroup_name,
    )

    rules = session_pchain_counters(s.meta)
    if rules:
        drops = [x for x in rules if x[0] == 3]
        if drops and drops[0][1] == 0:
            ok("final POSTROUTING DROP counter stayed at zero during normal traffic")
        elif drops:
            bad(f"final POSTROUTING DROP counter increased: {drops[0][1]} packets")
    else:
        warn("could not read PCHAIN packet counters or identify session PCHAIN from classid")

    child_rc, child_out = s.command("sleep 3 & echo CHILD_PID=$!", timeout=5)
    child_pid_match = re.search(r"CHILD_PID=(\d+)", child_out)
    if child_pid_match:
        child_pid = child_pid_match.group(1)
        cp = subprocess.run(
            ["sudo", "-n", "grep", "-H", "-w", child_pid, f"{s.meta['cgroup']}/cgroup.procs"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        if cp.returncode == 0:
            ok("background child remains inside session cgroup")
        else:
            bad("background child was not observed in session cgroup")
    else:
        bad("could not obtain background child PID for cgroup inheritance test")

    s.exit()
    for _ in range(30):
        if sudo("test", "-d", s.meta["cgroup"], timeout=5).returncode != 0:
            break
        time.sleep(0.2)
    if sudo("test", "-d", s.meta["cgroup"], timeout=5).returncode != 0:
        ok("session cgroup is cleaned after shell exit")
    else:
        bad("session cgroup remains after shell exit")

def test_multi_session():
    log("")
    log(f"=== concurrent multi-session test ({SESSION_COUNT}) ===")
    sessions = []
    try:
        for i in range(SESSION_COUNT):
            sessions.append(start_session(f"multi-{i+1}"))
        cgroups = {s.meta["cgroup"] for s in sessions}
        marks = {s.meta["mark"] for s in sessions}
        tables = {s.meta["table"] for s in sessions}
        if len(cgroups) == SESSION_COUNT:
            ok("concurrent sessions have unique cgroups")
        else:
            bad(f"cgroup collision: {len(cgroups)}/{SESSION_COUNT} unique")
        if len(marks) == SESSION_COUNT:
            ok("concurrent sessions have unique marks")
        else:
            bad(f"fwmark collision: {len(marks)}/{SESSION_COUNT} unique")
        if len(tables) == SESSION_COUNT:
            ok("concurrent sessions have unique policy tables")
        else:
            bad(f"policy table collision: {len(tables)}/{SESSION_COUNT} unique")

        results = []
        for s in sessions:
            results.append(external_probe(s, timeout=20))
        if all(rc == 0 for rc, _ in results):
            ok("all concurrent sessions reach external IPv4 successfully")
        else:
            bad("one or more concurrent sessions failed external IPv4")

        if HOST_PORT is not None:
            results2 = [
                s.command(f"curl -fsS --connect-timeout 3 --max-time 8 http://127.0.0.1:{HOST_PORT}/")
                for s in sessions
            ]
            if all(rc == 0 and "proxy-safe-host-loopback-ok" in out for rc, out in results2):
                ok("all concurrent sessions retain host loopback access")
            else:
                bad("one or more concurrent sessions lost host loopback access")
    finally:
        for s in sessions:
            s.exit()
        for _ in range(30):
            leftovers = list(Path(CGROOT).glob(f"ccsess-{UID}-*")) if Path(CGROOT).exists() else []
            if not leftovers:
                break
            time.sleep(0.2)
        leftovers = list(Path(CGROOT).glob(f"ccsess-{UID}-*")) if Path(CGROOT).exists() else []
        if leftovers:
            bad(f"{len(leftovers)} current-UID cgroup(s) remain after multi-session exit")
        else:
            ok("no current-UID cgroups remain after multi-session exit")

def test_disruptive():
    if not DISRUPTIVE:
        skip("disruptive gateway/policy failure tests not requested; use --disruptive")
        return

    log("")
    log("=== disruptive failure/recovery tests ===")
    if not gateway_running():
        skip("tproxy-gateway is not running before disruptive suite")
        return

    s = start_session("route-blackhole")
    table = s.meta["table"]
    gw = s.meta["gateway_ip"]
    iface = s.meta["docker_if"]
    rc, _ = external_probe(s)
    if rc == 0:
        ok("baseline external connectivity before policy-table failure")
    else:
        bad("baseline external connectivity failed before policy-table failure")

    changed = False
    try:
        r = sudo("ip", "route", "replace", "blackhole", "default", "table", str(table))
        changed = r.returncode == 0
        if not changed:
            bad(f"could not install test blackhole route: {r.stdout}")
        else:
            rc, out = external_probe(s, timeout=10)
            if rc != 0:
                ok("session traffic fails closed when its policy route is blackholed")
            else:
                bad("session traffic still succeeded with policy table blackholed")
    finally:
        if changed:
            sudo("ip", "route", "replace", "default", "via", gw, "dev", iface, "table", str(table))
    rc, _ = external_probe(s, timeout=20)
    if rc == 0:
        ok("session traffic recovers after policy route restoration")
    else:
        bad("session traffic did not recover after policy route restoration")
    s.exit()

    before = gateway_running()
    if before:
        s2 = start_session("gateway-failure")
        rc, out = external_probe(s2, timeout=20)
        if rc == 0:
            ok("baseline connectivity for gateway failure test")
        else:
            bad("baseline connectivity failed before gateway failure test")

        stopped = sudo("docker", "stop", GATEWAY_CONTAINER, timeout=30).returncode == 0
        if not stopped:
            bad("could not stop tproxy-gateway for disruptive test")
        else:
            try:
                time.sleep(2)
                rc, out = external_probe(s2, timeout=10)
                if rc != 0:
                    ok("existing session fails when the gateway Docker container is stopped")
                else:
                    bad("existing session still has external connectivity while gateway is stopped")
            finally:
                r = sudo("docker", "start", GATEWAY_CONTAINER, timeout=30)
                if r.returncode != 0:
                    bad("failed to restart tproxy-gateway after disruptive test")
                else:
                    for _ in range(30):
                        if tun0_present():
                            break
                        time.sleep(1)
                    if tun0_present():
                        ok("tproxy-gateway tun0 returned after restart")
                        rc, out = external_probe(s2, timeout=20)
                        if rc == 0:
                            ok("existing session recovers after gateway restart")
                        else:
                            bad("existing session did not recover after gateway restart")
                    else:
                        bad("tproxy-gateway tun0 did not return after restart")
        s2.exit()

def residual_audit():
    log("")
    log("=== residual state audit ===")
    
    time.sleep(4)
    cleanup_stale()
    time.sleep(2)
    
    cgs = list(Path(CGROOT).glob(f"ccsess-{UID}-*")) if Path(CGROOT).exists() else []
    if not cgs:
        ok("no current-UID proxy cgroups remain")
    else:
        bad(f"current-UID proxy cgroups remain: {cgs}")

    leaked = False
    for cmd in [
        ["iptables", "-w", "-S"],
        ["iptables", "-w", "-t", "mangle", "-S"],
        ["iptables", "-w", "-t", "nat", "-S"],
        ["ip6tables", "-w", "-S"],
    ]:
        r = sudo(*cmd)
        text = r.stdout or ""
        if re.search(rf"CC[FMNPSC]{re.escape(str(UID))}\d+", text):
            leaked = True
            break
    if leaked:
        bad("proxy-specific iptables/ip6tables chains or jumps remain")
    else:
        ok("no proxy-specific iptables/ip6tables residue remains")

def self_test():
    sample = b"""[+] session started\n    shell PID : 123\n    cgroup    : /sys/fs/cgroup/net_cls,net_prio/ccsess-1000-123\n    classid   : 0x4000007b\n    fwmark    : 0x4000007b\n    route tbl : 10042\n    gateway   : 172.19.0.2 via br-test\n"""
    m = parse_start(sample)
    assert m and m["shell_pid"] == 123 and m["table"] == 10042 and m["docker_if"] == "br-test"
    assert bool(START_RE.search(sample))
    print("self-test: PASS")

def main():
    if PROXY == "--self-test":
        self_test()
        return 0

    log("=== proxy_safe integration/security test ===")
    log(f"proxy       : {PROXY}")
    log(f"sessions    : {SESSION_COUNT}")
    log(f"disruptive  : {DISRUPTIVE}")
    log(f"report      : {REPORT}")
    log("")

    if not os.path.isfile(PROXY):
        bad(f"proxy script not found: {PROXY}")
        return 1
    if not os.access(PROXY, os.X_OK):
        warn("proxy script is not executable; bash will still invoke it")

    required = ["bash", "python3", "sudo", "docker", "ip", "iptables", "ip6tables", "base64"]
    for c in required:
        if subprocess.run(["bash", "-lc", f"command -v {shlex.quote(c)}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            ok(f"required command present: {c}")
        else:
            bad(f"required command missing: {c}")

    if run(["bash", "-n", PROXY], timeout=10).returncode == 0:
        ok("proxy script bash syntax")
    else:
        bad("proxy script bash syntax")

    if (sudo("-v", timeout=10).returncode == 0):
        ok("sudo -n is available for host-side test control")
    else:
        bad("sudo -n is not available")
        return 1

    iptv = run(["iptables", "-V"], timeout=5).stdout or ""
    if "legacy" in iptv:
        ok("iptables-legacy")
    else:
        bad(f"iptables is not legacy: {iptv.strip()}")

    ip6tv = run(["ip6tables", "-V"], timeout=5).stdout or ""
    if "legacy" in ip6tv:
        ok("ip6tables-legacy")
    else:
        bad(f"ip6tables is not legacy: {ip6tv.strip()}")

    if Path(CGROOT).is_dir() and (Path(CGROOT) / "net_cls.classid").is_file():
        ok("net_cls hierarchy")
    else:
        bad(f"missing net_cls hierarchy: {CGROOT}")

    if gateway_running():
        ok(f"gateway container {GATEWAY_CONTAINER} is running")
    else:
        bad(f"gateway container {GATEWAY_CONTAINER} is not running")
        return 1

    default_if = get_default_interface()
    if default_if:
        log(f"host default interface: {default_if}")

    cleanup_stale()
    test_single_session_network()
    test_multi_session()
    test_disruptive()
    residual_audit()

    log("")
    log("=== TEST SUMMARY ===")
    log(f"PASS={PASS} FAIL={FAIL} SKIP={SKIP} WARN={WARN}")
    log(f"REPORT={REPORT}")
    log("")
    log("Interpretation:")
    log("  PASS = observed behavior matched the intended policy.")
    log("  SKIP = the optional/disruptive portion was not executed.")
    log("  WARN = the test could not prove the property and needs manual inspection.")
    log("  FAIL = the observed behavior contradicted the intended policy or setup failed.")
    return 1 if FAIL else 0

def cleanup():
    for s in list(SESSIONS):
        try:
            s.exit(timeout=5)
        except Exception:
            pass
    try:
        stop_host_server()
    except Exception:
        pass
    cleanup_stale()
    try:
        (REPORT / "summary.json").write_text(json.dumps({
            "pass": PASS, "fail": FAIL, "skip": SKIP, "warn": WARN,
            "proxy": PROXY, "sessions": SESSION_COUNT, "disruptive": DISRUPTIVE,
        }, indent=2) + "\n")
    except Exception:
        pass

if __name__ == "__main__":
    rc = 0
    try:
        if len(sys.argv) >= 2 and sys.argv[1] == "--self-test":
            self_test()
            rc = 0
        else:
            rc = main()
    finally:
        cleanup()
    sys.exit(rc)
PY
