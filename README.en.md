# Agent Network Sandbox (SOCKS Edition)

[繁體中文](README.md) | [简体中文](README.zh-CN.md) | [English](README.en.md)

Route an AI agent's connections through a proxy you choose, reducing the chance of exposing your real public IP when the agent connects to services or sends usage information. When a connection follows the proxy path, the remote service sees the proxy's public IP.

This edition requires an existing SOCKS5 proxy. The scripts send the agent's connections to that proxy while keeping access to your local files, development tools, and services.

The goal is to expose fewer obvious proxy settings and TUN interfaces to routine telemetry, reducing the chance of the network being flagged as unusual. The maintainer has run Claude Code through this setup for several months and reports stable everyday operation.

## Why use this instead of a system-wide TUN or HTTP/HTTPS proxy settings?

**The two main benefits are blocking direct fallback when the proxy fails and exposing fewer obvious proxy clues.** The operating system and a Docker container handle forwarding, so the agent can connect normally without configuring or operating a proxy itself.

**Fail-closed means losing connectivity when the proxy or network fails, instead of bypassing the proxy and using the computer's real public exit IP.** Programs inside the sandbox should see failed, interrupted, or timed-out connections while the proxy is unavailable.

This is a key difference from a system-wide TUN setup without properly configured disconnection protection. Some tools restore the original routes when stopping or reconnecting, which can allow direct traffic during that interval. Automatic reconnection alone does not protect traffic during reconnection. TUN tools with correctly configured disconnection protection can also operate fail-closed; check the actual configuration.

**In this simple edition, direct-egress guards apply while the session rules remain active. Close the agent or application before exiting the shell.** See "Usage precautions and what to do" for other environment requirements and operating guidance.

The three approaches differ in what the agent can readily see:

- **HTTP/HTTPS proxy settings:** The proxy address often appears in application settings, startup arguments, or environment variables that the agent can read.
- **System-wide TUN:** A visible TUN interface and related routes usually appear on the host computer.
- **This project:** You do not need to give the agent a proxy address. The TUN interface is inside Docker, so listing the host's interfaces does not show that interface. Without the required permissions, the agent also cannot inspect the container through Docker commands or list iptables rules directly.

Applications still address their intended destinations, and the system forwards connections in the background. Their connection workflow resembles direct access, while the actual public exit remains the proxy. This design aims to reduce false positives from routine telemetry that relies on obvious clues such as proxy settings or a TUN interface.

It also suits cases where only the agent should use a proxy. For example, the agent can download files and run Python programs through the proxy while programs in your other terminals keep their usual network path.

You also spend less time configuring each tool the agent uses. Some tools read `HTTP_PROXY` or `HTTPS_PROXY`, some need their own settings, and some connect directly. Handling this group of programs at the system level reduces the chance of missing a tool.

| What matters | This project | System-wide TUN | HTTP/HTTPS proxy settings |
| --- | --- | --- | --- |
| Proxy or network failure | Active session rules block fallback through ordinary external interfaces. Close the agent or application before exiting the shell. | Without correct disconnection protection, restored routes may allow direct traffic during shutdown or reconnection; correctly protected tools can prevent this. | Proxy settings alone do not provide a system-level guard; direct retries depend on the application. |
| Visible proxy clues | No proxy variables are required; the TUN is inside the container. Inspecting container settings and firewall rules requires appropriate permissions. | A TUN interface and related routes are usually visible on the host. | The proxy address may appear in settings, startup arguments, or environment variables. |
| Which programs use the proxy | The agent started in the sandbox shell and programs it starts directly. | Usually covers the whole computer; exclusions need additional rules. | Depends on which programs read and honor the settings. |
| Does each tool need proxy support? | Usually no; the system forwards connections. | Usually no; the system forwards connections. | Each program or library needs to support the configuration. |
| Programs started by the agent | Normally inherit the restrictions. | Follow the system-wide rules. | May inherit the settings without actually using them. |
| UDP communication | Supported when the SOCKS proxy and every forwarding step support it. | Depends on the TUN software and proxy service. | Ordinary HTTP/HTTPS proxy settings do not handle UDP. |
| Effect on everyday use | Convenient when only the agent needs a different exit IP. | Browsers, downloads, and other programs may also change their network path. | Can target individual programs, but each one needs checking. |

This project also uses TUN internally; it limits forwarding to a particular group of programs. Some system-wide TUN tools support rules for individual applications, but those rules need separate setup and maintenance. If you want the whole computer to use a proxy, a system-wide TUN is more direct. If you only use one tool with reliable HTTP proxy support, configuring that tool may be simpler.

These benefits assume the agent cannot use sudo, access Docker, or administer the network. A normal account in the `docker` group may still manage containers; see [Docker's permission guidance](https://docs.docker.com/engine/install/linux-postinstall/#manage-docker-as-a-non-root-user). The goal is to reduce routine telemetry false positives. There are still limits against deliberate inspection, and different agents may reach different conclusions.

The scripts do not clear proxy environment variables you already have, so check those separately. For an example of how applications use them, see [curl's proxy environment variables](https://curl.se/libcurl/c/libcurl-env.html).

## What you need

- A Linux computer. The scripts target Ubuntu 20.04; check the requirements below before using another system.
- Docker and Docker Compose, using a conventional Docker installation.
- A normal user account with sudo access, so the scripts can configure networking when needed.
- A working SOCKS5 proxy with UDP forwarding support.

The scripts also need several system networking features. You can check them from your normal account without first learning their internals:

```bash
docker compose version
iptables -V
ip6tables -V
test -f /sys/fs/cgroup/net_cls,net_prio/net_cls.classid && echo "net_cls available"
test -c /dev/net/tun && echo "TUN available"
test -w "/run/user/$(id -u)" && echo "User runtime directory is writable"
```

Both firewall version strings must include `legacy`, and the last three commands should print their availability messages. If they do not, resolve the system requirements before starting the sandbox.

The scripts require the cgroup v1 `net_cls` feature at the exact path checked above. A system that only provides cgroup v2 cannot run this version directly. The scripts do not reconfigure your system to meet these requirements.

You also need Bash, sudo, the Docker CLI, and commands including `ip`, `iptables`, `ip6tables`, `flock`, `nsenter`, and `sysctl`. Tests additionally use curl and Python 3; the simple checks also use `dig` and `ping`.

## Additional privacy: choose your timezone and language

Before use, consider changing the computer's timezone and the language of the account that runs the agent. Even with a different public IP, an agent might report the original timezone and language, giving a remote service clues about your location.

Choose settings that suit your proxy location and intended use. For example:

- **Timezone:** UTC, or a city such as New York or Los Angeles. The United States has multiple timezones, so choose a specific city.
- **Language:** English (United States or United Kingdom), German, French, or another language. Adjust date and number formats as well.

The scripts do not change these settings automatically. The Ubuntu desktop example below uses UTC and English (United States); substitute your preferred choices. **These changes remain after you exit the sandbox. The timezone affects the whole computer; language settings mainly affect the account you are using.**

### 1. Choose and change the timezone

In Ubuntu, open **Settings → Date & Time** and turn off **Automatic Time Zone** so location-based updates do not change it back. Automatic clock synchronization can stay enabled; there is no need to move the clock forward or backward.

For example, to use UTC, run:

```bash
sudo timedatectl set-timezone UTC
timedatectl
```

For New York, replace `UTC` with `America/New_York`; for Los Angeles, use `America/Los_Angeles`. You can list other choices with `timedatectl list-timezones`.

Check that `timedatectl` reports the timezone you chose. Sudo is used here only to change the system timezone. Start the sandbox script and the agent as your normal user afterward.

### 2. Choose and change the account language

1. Open **Settings → Region & Language**. Some Ubuntu versions place this under **System**.
2. Choose a language, such as **English (United States)** or **English (United Kingdom)**. If it is missing, open **Manage Installed Languages** and install the corresponding language packages.
3. Set **Formats** to the corresponding region to adjust date and number formats too.
4. Save, then **log out of Ubuntu and log back in**. Closing a terminal or locking the screen is not enough for every application to pick up the change.

### 3. Check the settings before starting the agent

After logging back in, open a new terminal and run:

```bash
date '+%Z %z'
locale
```

Check that the results match your choices. For example, UTC and English (United States) should show `UTC +0000` and primarily `en_US` language settings. Other choices should show their corresponding values.

If old settings still override your choices, check whether `~/.bashrc` or `~/.profile` explicitly sets a timezone or language. Remove or update those entries, then log in again.

Once the settings are correct, start the sandbox and the agent as described below. These changes reduce direct reporting of your original timezone and language, but do not hide other local information or guarantee that your environment cannot be recognized.

For details, see [Ubuntu's region and language settings](https://help.ubuntu.com/stable/ubuntu-help/prefs-language.html), [changing the Ubuntu language](https://help.ubuntu.com/stable/ubuntu-help/session-language.html), and [timedatectl timezone settings](https://www.freedesktop.org/software/systemd/man/247/timedatectl.html).

## How to use it

Run the following commands from the project directory.

### 1. Prepare your proxy

Start a proxy application that provides a SOCKS5 service on your computer. The default port is `1083`. If your proxy uses a different port, edit [docker-compose.yml](docker-compose.yml):

```yaml
environment:
  - PROXY_PROTOCOL=socks5
  - PROXY_PORT=1083
```

**Make sure your proxy supports UDP forwarding.** Some agents may communicate using UDP-based protocols, and hostname lookups commonly use UDP too. A TCP-only proxy may let ordinary web requests work while other agent features fail or hostname lookups time out. If you use intermediate forwarding tools, the entire path must support UDP; forwarding a TCP port alone is not enough.

The forwarding container must also be able to reach the proxy on your computer. A proxy listening only on `127.0.0.1` is not directly reachable from this container. Allow connections from the Docker network in your proxy application, and use firewall rules to restrict access to the necessary sources.

If your SOCKS proxy is remote, first use a local proxy application or forwarding tool to expose a local proxy port that the container can reach. This version has no option for directly entering a remote proxy address, username, and password.

### 2. Start the forwarding container

```bash
chmod +x entrypoint-gateway.sh proxy_safe_final.sh
sudo docker compose up -d
sudo docker compose ps
sudo docker compose logs --tail=50 tproxy-gateway
```

This container passes the agent's connections to your proxy. Its default name is `tproxy-gateway`.

Sudo here is for managing Docker. **Do not add it to the sandbox script command in the next step.**

### 3. Run the main script as a normal user

**Do not run `proxy_safe_final.sh` from a root account or with sudo.** Otherwise, the new shell and an agent started from it will have root privileges. The agent could then change networking, bypass restrictions, or read more system information to identify the sandbox and the real network.

Run it directly from your normal account:

```bash
./proxy_safe_final.sh
```

The script prompts for your password when it needs administrator access to configure networking. You do not need to put sudo before the command.

It prints startup information, then opens a new shell. **Run your usual agent startup command in that shell.** For example, if your agent is a Python program, run that program there.

Only the agent started there and programs it starts directly receive these restrictions. Agents already running in other terminals are not added automatically. The script also does not currently accept an agent command after its filename.

Using a normal account avoids giving the agent administrator access directly. Do not use sudo to start the agent after entering this shell either.

### 4. Check that connections use the proxy IP

In the new shell, run:

```bash
curl --noproxy '*' -4 --fail --show-error --connect-timeout 5 --max-time 15 https://ifconfig.me
```

This prints the public IP used by that connection. Compare it with your proxy's expected exit IP. **Reaching the website is not enough; the IP must be correct too.**

`--noproxy '*'` temporarily ignores curl's own proxy settings so you can check whether this project's forwarding works.

This version blocks external IPv6, so the following connection should fail:

```bash
curl --noproxy '*' -6 --fail --show-error --connect-timeout 5 --max-time 10 https://ifconfig.me
```

However, it would also fail if your computer had no working IPv6 in the first place. Failure alone does not prove the protection works.

### 5. Exit when finished

**Close the agent or application and stop any background tasks it left inside the sandbox before exiting the shell.**

Automatic cleanup removes network restrictions before stopping remaining programs. First make sure those programs have finished, then enter the following in the sandbox shell:

```bash
exit
```

The script then cleans up this session's networking. Follow the order above instead of relying on shell exit to close programs that are still making connections.

Back in the outer terminal, check for remaining session state with:

```bash
./proxy_safe_final.sh --status
```

This displays state; it does not test proxy connectivity. Some output may include other users' network rules.

When all agents are finished, you can also stop the forwarding container:

```bash
sudo docker compose stop
```

Stopping it disconnects agents still using it. To run multiple agents, open several terminals and start the main script separately in each. They share one proxy exit; each does not receive a separate public IP.

## How it works

### Connection diagram

```mermaid
flowchart TD
    AGENT["Agent in the new shell<br/>and programs it starts"]
    CONTAINER["Docker forwarding container on your computer"]
    SOCKS["Your local SOCKS proxy endpoint<br/>default port 1083"]
    EXIT["External proxy exit"]
    REMOTE["Remote service<br/>sees the proxy exit IP"]
    LOCAL["Local files, tools, and services"]

    AGENT --> CONTAINER --> SOCKS --> EXIT --> REMOTE
    AGENT -. "still available" .-> LOCAL
```

The script lets the system track programs started in this shell and sends their external IPv4 connections into the forwarding container. The container runs tun2socks, which passes the connections to your SOCKS proxy and out through its exit.

Normally, the agent needs no separate proxy settings because forwarding happens at the system level. Programs already running in other terminals do not automatically switch to the proxy when you start the sandbox.

The script also handles the following:

- **Redirect common hostname lookups.** DNS translates website names into IP addresses. Ordinary DNS queries sent directly by the agent are redirected to `1.1.1.1` through the same proxy path.
- **Block external IPv6.** This helps prevent the agent from using the computer's original IPv6 connection while IPv4 goes through the proxy.
- **Restrict local network access.** Selected private address ranges are blocked, while local services and the forwarding container remain reachable for development.
- **Block direct fallback on failure (fail-closed).** With the restrictions active, only local services and the designated Docker interface are allowed. An unavailable proxy should cause connection failures, while traffic attempting to leave through an ordinary external interface is dropped. In this simple edition, close applications before exiting the shell and check the forwarding environment as described below.
- **Clean up on exit.** A background process checks whether you have exited, then removes settings and stops remaining programs.

## Limitations

### Local files and tools remain accessible

The agent still runs on your computer. It can read local files, inspect local IP addresses, interfaces and routes, and use tools its account is allowed to use. This project does not separately limit file access, memory use, or which programs can be launched.

Distinguish two kinds of addresses: local addresses on the computer's interfaces, such as `192.168.x.x` or `10.x.x.x`, describe the local network. The public exit IP obtained through an external service should be the proxy's exit IP. Being able to inspect local interfaces and routes does not mean a connection through the sandbox reveals the computer's original public exit.

The tool does not rewrite interface information or remove addresses already stored in files. If a public IP is configured directly on a host interface, that address also remains readable as local host information.

Even under a normal account, an agent that can use sudo, manage Docker, or ask another local service to act for it may bypass restrictions. If work is handed to a service that is already running, do not assume that service's connections are covered too.

### Manage what the agent uploads separately

Some agents automatically send usage or device information, commonly called telemetry. This project changes where those connections go out; it does not remove their contents.

If an agent uploads an account identifier, device ID, hostname, timezone, file contents, or local IP, a remote service may still recognize the device or environment. These contents are separate from the connection's public source IP: traffic sent through the proxy still comes from the proxy's exit. Check the agent's own privacy and telemetry settings separately.

Your proxy provider may also observe or record connections. SOCKS itself does not encrypt all traffic; encryption depends on the agent's connection protocol and the proxy service.

### UDP, DNS, and IPv6 have requirements

- **Your proxy needs UDP forwarding.** Agent features using UDP may fail if the proxy or an intermediate tool does not support it. Successful ordinary web requests do not prove UDP works.
- **Hostname lookups can be affected too.** The script does not automatically convert UDP queries to TCP, so it cannot compensate for missing UDP support.
- **Ordinary DNS is fixed to `1.1.1.1`.** Internal company websites or other services requiring a private DNS server may stop working.
- **Not every lookup method is redirected.** Only TCP/UDP queries sent directly by the agent to IPv4 port `53` are rewritten. Lookups over HTTPS, TLS, or another local service need separate checking.
- **External IPv6 is blocked.** IPv6-only services cannot be reached through this version. Local IPv6 loopback at `::1` is retained.
- **Some network tools are unsuitable as connectivity checks.** For example, a proxy may not support the protocol used by ping. Failed pings do not necessarily mean ordinary agent connections will fail.

### Local network restrictions have exceptions

Selected private address ranges are blocked, but services on your own computer and the forwarding container remain accessible. A local service capable of forwarding connections may still let the agent reach other destinations.

<details>
<summary>Blocked address ranges</summary>

- `10.0.0.0/8`
- `172.16.0.0/12`
- `192.168.0.0/16`
- `169.254.0.0/16`
- `100.64.0.0/10`

Your computer and the forwarding container have exceptions, so this list does not mean all local services are blocked.

</details>

## Usage precautions and what to do

Use the guidance below to avoid problems. Have an administrator check your environment before changing network settings; do not clear the computer's entire rule set.

| Precaution | Why it matters and what to do |
| --- | --- |
| Close the agent or application before exiting | Automatic cleanup removes network restrictions before stopping remaining programs. Close the agent or application, stop background tasks it left inside the sandbox, and only then use `exit` to leave the shell. |
| Do not use `--cleanup` for routine exit | It stops all sandboxes under the current account and may affect unrelated networking. Normally follow the exit steps above. For leftovers, inspect `--status` first and have an administrator identify the rules to remove; do not run cleanup blindly when VPNs or other services are in use. |
| Check failed startup before launching an agent | Some cleanup steps may leave rules behind. Run `./proxy_safe_final.sh --status`, identify state belonging to this tool, and have an administrator handle it. Do not flush global rules or delete another service's rules. |
| Record settings first if full restoration is required | The script changes the Docker bridge's `route_localnet` setting without restoring it on exit. Record its original value before use, then have an administrator restore that value afterward rather than guessing. |
| Verify the exit before launching an agent | Startup messages do not prove the proxy works. Check the public exit with the command above or a browser launched inside the sandbox, then start the agent. Inspect `--status` after exiting for leftover state. |
| Start multiple sandboxes under one account | Allocation is coordinated within one account, but different accounts do not share that protection. Use multiple terminals under the same normal account, and avoid concurrent initialization or cleanup by different accounts. |
| Close unused sessions when capacity is reached | The scripts share rule priorities `100–199`, which other software may also occupy. Close unused sandboxes normally; do not delete another program's rules to make space. |
| Attach the forwarding container to one Docker network | Address detection does not properly handle multiple attached networks. Keep a single dedicated Docker network and do not attach additional networks to this container. |
| Check compatibility with existing firewalls or VPNs | This tool inserts allow rules, and the container does not fully reject all unlisted traffic. If the host has important network policies, verify the normal exit and disconnection behavior in a test environment where interruption is acceptable before combining them. Connectivity alone is not enough. |
| Verify the exit with real connections | Checking the outgoing Docker interface does not verify the full proxy path. Check the public IP, then follow the testing section for browser, UDP, and proxy-failure checks rather than relying only on interface or route output. |
| Prepare a local entry point for a remote proxy | First provide a local SOCKS5 service reachable from Docker with UDP support using your own proxy software, then start this tool. |
| Run full tests only on a machine where networking can be interrupted | Tests call `--cleanup` and may stop the gateway or affect unrelated networking. Close agents and all sandboxes on the test machine first; do not run the entire suite on your everyday work computer. |

## Testing

### Check with a browser (GUI applications)

GUI applications can also use the sandbox network. A browser provides a convenient visual check:

1. Enter the sandbox from a terminal in your normal desktop account, then **launch the browser from inside the sandbox shell**.
2. Fully close existing browser processes first, or use a separate profile and an independent instance supported by that browser. Opening a browser from the desktop, or handing a page to an existing process outside the sandbox, does not ensure that process is covered.
3. Open [BrowserLeaks](https://browserleaks.com/) or [BrowserScan](https://www.browserscan.net/) and check public IP, WebRTC, DNS, timezone, and language results.
4. **The public IP should be the proxy's exit. Any public IP shown by WebRTC should also be the proxy's exit, or no public result should be available.** A local private address alone does not indicate exposure of the original public exit. If the original public exit appears, stop using the setup and investigate.

DNS tests may show resolver addresses, which normally differ from the proxy's exit IP. A difference alone does not prove a leak, and the browser's own encrypted DNS settings can affect the results. Changing the exit does not automatically change timezone, language, fonts, or other browser information. A proxy/VPN label alone also does not show that traffic bypassed the proxy; check the reported addresses.

Only test disconnection where interrupted networking is acceptable: keep the sandbox and browser running, pause the proxy from outside, and make a new network request. The request should fail instead of using the original public exit. Cached or previously loaded pages do not demonstrate working connectivity. Browsing these sites checks the observed requests and does not replace failure testing or packet inspection.

### Check script syntax only

These commands do not start the sandbox, change firewall rules, or stop containers:

```bash
bash -n proxy_safe_final.sh
bash -n test_proxy_safe.sh
bash -n sandbox_test.sh
sh -n entrypoint-gateway.sh
bash ./test_proxy_safe.sh --self-test
```

`--self-test` only checks whether the test tool can parse startup information. **It does not prove proxy connectivity or leak protection.**

### Simple checks inside the sandbox

Start the sandbox as described above, then run inside it:

```bash
bash ./sandbox_test.sh
```

It checks internet access, local services, private network restrictions, and whether programs started by the agent remain covered.

Before using it, update two values in the test script for your computer:

- `PHYSICAL_IF`: Your actual internet-facing interface; the current value is `enp39s0`.
- `LAN_GATEWAY`: Your local router's address; the current value is `192.168.1.1`.

Some checks report success whenever a connection fails, but that could also mean an unreachable test address, a missing tool, or insufficient permissions. Do not rely on PASS alone; check that the addresses and settings suit your computer.

### Full tests: use a machine where network interruption is acceptable

Full tests start real sandboxes, connect to external sites, and run cleanup. **The cleanup issues above apply even without `--disruptive`.**

```bash
bash ./test_proxy_safe.sh ./proxy_safe_final.sh --sessions 3
```

To test interrupted forwarding, add `--disruptive`. It temporarily changes test networking and stops and restarts the forwarding container. Other agents sharing that container will also lose connectivity:

```bash
bash ./test_proxy_safe.sh ./proxy_safe_final.sh --sessions 3 --disruptive
```

The output shows the report directory, normally under the system temporary directory with a name starting with `proxy-safe-test-`. It contains execution logs and `summary.json`.

Full tests also have two limitations: unanswered UDP queries may produce only a warning, and permission checks use another low-privilege account rather than the actual agent account. A summary with no FAIL results does not prove every protection works.

## FAQ

**The container is running, but the agent cannot get online.**

First check that the proxy itself works, the port is correct, and connections from Docker are allowed. A proxy listening only on `127.0.0.1` is not directly reachable from this container. If only hostname-based connections fail, check DNS and UDP forwarding.

Inspect container errors with:

```bash
sudo docker compose logs --tail=50 tproxy-gateway
```

For further checking, these commands show the host address used by the container, whether its forwarding interface exists, and its routes:

```bash
sudo docker exec tproxy-gateway getent hosts host.docker.internal
sudo docker exec tproxy-gateway ip link show tun0
sudo docker exec tproxy-gateway ip route
```

Seeing `tun0` or `gateway ready` still requires a real connection test to confirm the proxy works. A plain `ip route get` query does not by itself show the agent's actual exit path.

**How do local IP addresses differ from the public exit IP?**

The agent can inspect local IP addresses, interfaces, and routes. Those details are separate from the public exit used for outgoing connections. **With the restrictions working and traffic following the proxy path, both the exit IP reported by an external lookup and the source IP seen by the remote service should be the proxy's exit IP.**

For example, an interface showing `192.168.1.10` while a public-IP lookup reports the proxy's exit is normal; it does not mean the original public exit has leaked. Local host data is not rewritten, so file access and telemetry contents still need separate management.

**Can I run `--cleanup` immediately if something remains after exit?**

Check with `./proxy_safe_final.sh --status` first. Current cleanup can affect unrelated networking and stop other sandboxes under the same account. If you have a VPN or other important network services, do not treat it as a routine cleanup button.

## Project files and other settings

| File | Purpose |
| --- | --- |
| [docker-compose.yml](docker-compose.yml) | Configures the forwarding container and the proxy port it connects to. |
| [entrypoint-gateway.sh](entrypoint-gateway.sh) | Prepares forwarding when the container starts. |
| [proxy_safe_final.sh](proxy_safe_final.sh) | The main script used to open the sandbox. |
| [sandbox_test.sh](sandbox_test.sh) | Runs simple checks inside the sandbox. |
| [test_proxy_safe.sh](test_proxy_safe.sh) | Runs full tests, which may affect host networking. |

For normal use, set `PROXY_PORT` to your proxy's port and keep `PROXY_PROTOCOL=socks5`. After changing them, run `sudo docker compose up -d` again to apply the container configuration.

If you rename the container, set `GATEWAY_CONTAINER` to the same name when starting the main script. The container reaches your computer through `host.docker.internal`; this name is configured by Docker and is not an option for entering a remote proxy address.

The main script also has `--help` and `--status` options. The DNS destination `1.1.1.1` and the system feature path mentioned above are currently fixed in the code, without separate configuration options.
