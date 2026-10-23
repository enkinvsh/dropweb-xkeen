<div align="right">
  <a href="README.md">Русский</a>
</div>

# dropweb VPN on Keenetic — One-Shot Installer (XKeen 2 + mihomo)

A single script turns a Keenetic router with Entware into a **transparent VPN router** for a dropweb subscription: selected devices (TV, PC, phone, console) route through the VPN automatically without installing client software on each device. Direct/domestic traffic bypasses the tunnel according to the rules delivered by the dropweb subscription.

## What You Get

- **Transparent VPN for selected devices** via [XKeen 2](https://github.com/jameszeroX/XKeen) + **mihomo** (Clash.Meta) with dropweb routing rules: both TCP and UDP from devices in the policy are intercepted at the router
- **Games without extra ping** — only the UDP the subscription can route to the VPN (QUIC, Telegram/WhatsApp/Discord/Meet calls) enters mihomo; games and other UDP go direct. The router builds the list from the subscription itself, see [Games and Calls (UDP)](#games-and-calls-udp)
- **Web panel** at `http://192.168.1.1:8181/` — no SSH for daily use: VPN on/off, connection check, subscription expiry, "Update subscription", change the subscription link. When the subscription hits its device limit or expires, the panel says so and offers the one button that fixes it
- **Zashboard UI** at `http://192.168.1.1:9090/ui/` — nodes, active connections, logs, latency checks. Protected by an API secret
- **Hourly subscription sync** — full config diffing with hot reload via the mihomo API (zero connection drops when changed). If the primary subscription address is unreachable, the router falls back to the mirror addresses dropweb sends in the subscription itself
- **Watchdog** — automatically restarts mihomo within a minute if the process crashes
- **One-click / one-command emergency bypass** — and the VPN **stays disabled across router reboots** until explicitly re-enabled

## Requirements

1. **Keenetic router** running KeeneticOS 4+ with Entware support (Giga, Ultra, Hopper, Sprinter, Peak, etc.)
2. **Entware on a USB drive** — see [Entware from scratch](#entware-from-scratch)
3. **Root SSH access** to Entware (default: `root@192.168.1.1`, password `keenetic` — change it right after setup)
4. **Subscription URL from the dropweb bot** — copy it from the bot as is, the address changes over time. If the installer says the subscription could not be downloaded, get a fresh link from the bot

### Entware from scratch

The "OPKG" component in the web UI only enables package support — it does **not** install Entware. Working sequence (the USB drive gets wiped):

1. Keenetic web UI → firmware components → install **Open Package support** (OPKG), the **Ext file system**, and both **Netfilter kernel module** entries (XKeen needs them). The router reboots
2. Plug in the USB drive → open it on the USB storage page → **initialize / format as EXT4** (Keenetic creates a swap partition plus EXT4). Note the EXT4 partition label, e.g. `EXT4-9jgJCLGS`
3. Open the router CLI at `http://192.168.1.1/a` and run one command — label from step 2, installer URL for your architecture:

   ```text
   opkg disk EXT4-9jgJCLGS:/ https://bin.entware.net/aarch64-k3.10/installer/aarch64-installer.tar.gz
   ```

   | `arch` in `show version` | Installer URL |
   |---|---|
   | `aarch64` | `https://bin.entware.net/aarch64-k3.10/installer/aarch64-installer.tar.gz` |
   | `mipsel` | `https://bin.entware.net/mipselsf-k3.4/installer/mipsel-installer.tar.gz` |
   | `mips` | `https://bin.entware.net/mipssf-k3.4/installer/mips-installer.tar.gz` |

   `show version` in the same CLI prints the architecture (`arch` field). Tested on Netcraze Hopper NC-3811 (aarch64, KeeneticOS 5.1)
4. After 1–3 minutes the router log reports that Entware installation finished. SSH: `ssh root@192.168.1.1`, password `keenetic`. If the Keenetic "SSH server" component is installed, it owns port 22 — check the Entware port in `/opt/etc/config/dropbear.conf`
5. Key-based login: Entware's dropbear reads root keys from `/opt/etc/dropbear/authorized_keys`, not from `~/.ssh`

## Installation

```sh
ssh root@192.168.1.1
opkg update && opkg install curl
curl -fsSL -o /tmp/install.sh https://raw.githubusercontent.com/enkinvsh/dropweb-xkeen/main/install.sh
sh /tmp/install.sh
```

The script prompts for your subscription URL, prints the detected parameters, and asks for confirmation. It then validates the subscription, installs XKeen and mihomo, builds the config, and starts the service.

### Unattended Mode

```sh
SUB_URL='https://…' sh /tmp/install.sh -y
```

All flags and environment variables: `sh /tmp/install.sh -h`.

### Re-running = Upgrade

Running the installer again preserves your existing HWID and subscription URL (press Enter to keep the current URL), upgrades mihomo, and refreshes the scripts and configuration. Settings (including HWID) are migrated automatically from v1, so the router never consumes an extra device slot.

## Installer Prompts & Auto-Detected Settings

Only the **subscription URL** (and confirmation) is requested interactively. Everything else is derived automatically and shown in the summary before installation:

| Parameter | Source |
|---|---|
| HWID | Derived from the router's LAN MAC address and persisted permanently so the router appears as a single device in dropweb |
| Model (`x-device-model`) | Queried via `ndmc` — e.g., `Keenetic Giga (KN-1011)` |
| OS Version (`x-ver-os`) | KeeneticOS version from `ndmc` |
| User-Agent | `clash.meta` |
| Ports | Control panel `8181`, mihomo API/dashboard `9090` |
| API Secret | Randomly generated |

Any parameter can be overridden via environment variables (`HWID`, `DEVICE_MODEL`, `PANEL_PORT`, `API_PORT`, `API_SECRET`, `LAN_IP`, …).

## Choosing Which Devices Use the VPN

XKeen looks for a Keenetic access policy named **xkeen**:

- **No `xkeen` policy exists** — **all** LAN devices route through mihomo (direct rules in the subscription still bypass the tunnel for domestic traffic).
- **`xkeen` policy exists** — **only** devices assigned to that policy route through the VPN.

To route only specific devices through the VPN:

1. Open `http://192.168.1.1/` (Keenetic admin UI)
2. **Connection Priorities** → add a policy named **xkeen**
3. **Client Lists** → click a device → assign access policy **xkeen** → Save. Repeat for each device you want on the VPN
4. Restart XKeen: `ssh root@192.168.1.1 xkeen -restart`

Verify the policy via RCI:

```sh
ssh root@192.168.1.1 'curl -s 127.0.0.1:79/rci/show/ip/policy'
```

The output should include a policy with `"description": "xkeen"`. The installer also checks and reports this at the end of setup.

## Games and Calls (UDP)

dropweb rules decide "VPN or direct" mostly by domain. UDP usually carries no domain: games, voice and video calls send packets straight to an IP. If all UDP goes into mihomo, games still end up direct by the rules, but with extra latency on the router: a PS5 went from 80–100 ms ping to 150–200.

So the router reads the subscription config itself and sends into mihomo only the UDP that the rules can route to the VPN:

- QUIC — UDP to the ports where mihomo sniffs the domain (currently 443), so YouTube and Instagram over QUIC follow the rules just like over TCP;
- addresses from IP rules that lead to the VPN: Telegram, WhatsApp, Discord, Google Meet and whatever dropweb adds to the subscription;
- mihomo's fake-ip range.

All other UDP — games, PSN, Steam — bypasses mihomo through plain NAT. TCP is unaffected. The list is rebuilt on every subscription update. XKeen wipes its iptables chain on restart, so a `netfilter.d` hook puts the rule back, and the watchdog checks every minute that it is in place.

If the subscription rules cannot be reduced to such a list (for example, the final `MATCH` rule leads to the VPN), the bypass turns itself off and all UDP goes through mihomo as before. The install summary says which mode was chosen and why. Same information:

```sh
ssh root@192.168.1.1 /opt/sbin/dropweb-udp-bypass.sh status
```

To send all UDP through mihomo: `UDP_BYPASS=0` in `/opt/etc/dropweb-xkeen/settings.env`, then `/opt/sbin/dropweb-udp-bypass.sh apply`.

## Post-Install Endpoints

```text
Web Panel        :  http://192.168.1.1:8181/
mihomo Dashboard :  http://192.168.1.1:9090/ui/
mihomo API       :  http://192.168.1.1:9090 (secret printed after install)
```

The API secret and all persisted settings live in `/opt/etc/dropweb-xkeen/settings.env` (`API_SECRET=`). At the end of installation, the script prints a pre-authenticated dashboard URL.

## Web Panel

`http://192.168.1.1:8181/` — from any device on the home network, no password or SSH.

- **VPN** — running or disabled; a switch with confirmation
- **Connection check** — tests plain internet and the VPN server separately, so you can tell an ISP problem from a server or config problem
- **Subscription** — paid-until date, days left, last successful update, and whether a mirror address had to be used
- **Update subscription** — fetch it now instead of waiting for the hourly run
- **Change subscription link** — paste a new link from the bot. The panel tests it first; a broken link leaves the old one in place
- **Update** — installed version and whether a new one is out; "Update to …" now and an "Update automatically" switch (on by default)

When something is wrong with the subscription, an alert with a single action appears on top:

| Panel says | What to press |
|---|---|
| All device slots are taken | "Free a slot" opens the dropweb devices page. Come back to the panel tab — it re-fetches the subscription by itself |
| Subscription expired | "Renew subscription" opens the dropweb cabinet |
| Subscription could not be downloaded | Check the internet; if that does not help, paste a fresh link from the bot |

### How the router updates itself

Updates come from this repository: a new version is released when `DROPWEB_XKEEN_VERSION` in `install.sh` is bumped on `main`. The router checks every night and installs it by itself; with "Update automatically" off it only updates from the panel button. The work is done by `/opt/sbin/dropweb-xkeen-update.sh`:

1. The branch is resolved to a commit via the GitHub API — raw files are cached for 5 minutes per branch, but a commit-hash URL is always fresh. `install.sh` and `panel/` come from the same commit
2. The downloaded `install.sh` must pass `sh -n`, `mihomo-panel.py` must compile, `index.html` must contain `<html`
3. A snapshot of everything the installer touches (our scripts, mihomo, init scripts, panel, settings, config, cron) goes to `/opt/backups/dropweb-xkeen/snapshot`
4. The new `install.sh -y` runs with the same subscription and HWID. A VPN disabled in the panel stays disabled
5. Health check: mihomo and its API are up, XKeen rules are in place, internet via mihomo works (if it did before), the panel answers
6. If the check fails, the snapshot is restored and that version is marked as failed: the nightly run skips it and waits for the next one. The button can still retry it

While an update runs, the watchdog stays quiet, and the panel page shows "Router is updating" and reloads by itself when it is done. The result goes to `/opt/etc/dropweb-xkeen/update-state.env` (shown in the panel) and `/opt/var/log/dropweb-xkeen-update.log`.

By hand over SSH: `/opt/sbin/dropweb-xkeen-update.sh check` (look up the latest version) or `run` (update now).

Routers on 2.1.x cannot update as a whole yet: press "Update panel" there, and the new panel gets the "Update" section.

To try your own branch on a router, set `UPDATE_URL='https://raw.githubusercontent.com/<user>/dropweb-xkeen/<branch>'` in `/opt/etc/dropweb-xkeen/settings.env` and bump the version in that branch's `install.sh`. The installer honours the same `UPDATE_URL` (`UPDATE_URL=… sh install.sh`); `AUTO_UPDATE=0` means button only.

## Emergency Bypass Scenarios

### 1. Web Panel → disable VPN

One click stops mihomo and removes traffic interception so **all devices go directly to the internet**. The disabled state persists across reboots until you enable it in the panel again.

### 2. SSH — if the web panel is unreachable

```sh
ssh root@192.168.1.1 /opt/sbin/mihomo-panic.sh
```

Default password: `keenetic`. Same effect as the web button: VPN is stopped and stays off across reboots. Re-enable with `/opt/sbin/mihomo-resume.sh` or the web panel button.

### 3. Keenetic CLI via Telnet — if SSH is unreachable

```sh
telnet 192.168.1.1
# Keenetic admin login / password
> system reboot
> yes
```

Note: **a normal reboot (without panic) brings the VPN back up automatically** by design. If it was previously disabled via the panel or `mihomo-panic.sh`, it remains disabled after reboot.

### 4. Power Cycle

Same behavior as a normal reboot: without panic, the VPN starts on boot; after panic, it stays off.

**Do not hold the physical Reset button for 10+ seconds** — that performs a factory reset of KeeneticOS and wipes all router settings.

## The VPN is gone entirely and the panel does not open

Everything except Keenetic itself lives on the USB drive. If it is ejected, traffic goes direct and both the panel and SSH on port 22 go silent.

- Check that the drive is in the router's USB port. Once it is back, Entware, the VPN and the panel come up on their own within a minute or two, no reboot needed.
- By default the Keenetic FN button ejects the drive on a single press. The installer moves that to a 3-second hold and leaves a short press doing nothing. If the button already had its own hold action, the installer leaves it alone; then the drive can only be ejected from the Keenetic web UI.
- The drive should be listed in the Keenetic web UI (http://192.168.1.1) under applications and storage. If it is missing, suspect the port or the drive itself.

## Troubleshooting: "All Device Slots Are Taken" / "Service Returned a Stub Config"

If the subscription returns a stub instead of proxy nodes, the **device limit** has been reached or the HWID was rejected:

1. The installer prints the link where you can free a slot (the **Devices** page of your account); the same list is in the dropweb bot → **Devices**. Remove an unused device
2. Re-run the installer: `sh /tmp/install.sh -y`. If the router is already set up, just press "Free a slot" in the web panel and then "Update subscription"

The router's HWID is printed in the error message and stored in `/opt/etc/dropweb-xkeen/settings.env`. Avoid changing it unnecessarily, as a new HWID consumes another device slot.

## Installed File Layout

| Path | Purpose |
|---|---|
| `/opt/etc/dropweb-xkeen/settings.env` | Persisted configuration: subscription URL, HWID, ports, API secret |
| `/opt/etc/dropweb-xkeen/sub-state.env` | Result of the last subscription update: expiry, mirrors, cabinet links (the panel builds its alerts from it) |
| `/opt/etc/dropweb-xkeen/update-state.env` | Latest version on GitHub and the result of the last dropweb-xkeen self-update |
| `/opt/sbin/xkeen`, `/opt/sbin/.xkeen/` | XKeen 2 |
| `/opt/etc/init.d/S05xkeen` | XKeen init script (managed by XKeen: mihomo core, `start_auto`) |
| `/opt/sbin/mihomo` | mihomo binary (installed and updated by XKeen) |
| `/opt/sbin/yq` | YAML processor |
| `/opt/etc/mihomo/config.yaml` | Active mihomo configuration (subscription + router patches) |
| `/opt/etc/mihomo/.disabled` | Persistent "VPN disabled" flag |
| `/opt/etc/mihomo/zash/` | Zashboard web UI |
| `/opt/sbin/update-mihomo-sub.sh` | Hourly subscription updater (cron) |
| `/opt/sbin/mihomo-watchdog.sh` | Process watchdog (every minute via cron) |
| `/opt/sbin/mihomo-panic.sh` | Emergency VPN kill/bypass script |
| `/opt/sbin/mihomo-resume.sh` | Re-enable VPN script |
| `/opt/sbin/dropweb-xkeen-update.sh` | dropweb-xkeen self-update from GitHub (nightly cron, panel button) |
| `/opt/backups/dropweb-xkeen/snapshot` | Pre-update snapshot for rollback |
| `/opt/sbin/dropweb-udp-bypass.sh` | UDP bypass: builds the VPN-bound address list from the subscription and adds a rule to the XKeen chain |
| `/opt/etc/dropweb-xkeen/udp-bypass/` | Built lists and the build result (`state.env`) |
| `/opt/etc/ndm/netfilter.d/zz-dropweb-udp.sh` | Restores the bypass rule after XKeen rebuilds iptables |
| `/opt/share/dropweb-xkeen/panel/` | Web panel: `mihomo-panel.py` (Python stdlib) and `index.html` |
| `/opt/etc/init.d/S96mihomo-panel` | Web panel init script |
| `/opt/sbin/mihomo-vpn-uninstall.sh` | Uninstaller |
| `/opt/var/spool/cron/crontabs/root` | Cron jobs |
| `/opt/var/log/mihomo-*.log`, `/opt/var/log/dropweb-xkeen-install.log` | Logs |
| `/opt/backups/mihomo/` | Config backups (last 5 revisions) |

## Uninstallation

```sh
ssh root@192.168.1.1 /opt/sbin/mihomo-vpn-uninstall.sh
```

Disables the VPN and removes our scripts, web panel, cron jobs, config, and settings. XKeen and mihomo remain installed (with autostart disabled); to remove them as well:

```sh
ssh root@192.168.1.1 xkeen -remove
```

## Design Decisions

- **Hybrid interception: TCP via REDIRECT on `:1182`, UDP via TPROXY on `:1181`.** Ports are declared under `listeners` rather than top-level `redir-port`/`tproxy-port`. Because the upstream template sets `allow-lan: false`, top-level ports bind only to `127.0.0.1`, whereas iptables REDIRECT delivers packets to the router's LAN IP. Explicit `listeners` entries bind `0.0.0.0` regardless of `allow-lan`.
- **TUN disabled.** Running TUN with `auto-route` on a router breaks LAN routing; transparent packet interception is handled by XKeen via iptables.
- **`mixed-port` stays local to the router** (`allow-lan: false`) — no SOCKS/HTTP proxy is exposed on the LAN; the installer uses it locally to verify outbound connectivity.
- **`find-process-mode: off`** — resolving local socket owners makes no sense for forwarded LAN traffic and wastes CPU on MIPS/ARM routers.
- **Content-addressed subscription updates.** Every hour the subscription is fetched, patched, validated with `mihomo -t`, and compared against the active config. Only if the resulting config differs is a backup saved and hot-reloaded via the mihomo API. If fetching fails or returns a stub, the working config is untouched.
- **Subscription mirrors come from the subscription headers.** dropweb sends `dropweb-sub-mirrors` and `fallback-url`; the updater remembers them and uses them when the primary address does not respond. The stored link itself is not changed.
- **The panel explains instead of logging.** Every updater run records its outcome (`updated`, `unchanged`, `device_limit`, `fetch_failed`, …) in `sub-state.env`; the panel turns it into one sentence and one button.
- **One version for everything, and rollback instead of hope.** The panel lives in its own files (`panel/`) so its look can change without touching the installer, but it updates together with the rest: the panel and the scripts on the router always come from the same commit. An update is a plain reinstall, and the snapshot taken before it brings everything back if the new version works worse.
- **Deterministic HWID from LAN MAC.** Re-installs and upgrades reuse the same HWID so device slots are never leaked.
- **XKeen 2.0.1 Beta only when required.** Non-interactive installation (`xkeen -i auto`) requires 2.0.1 Beta; stable is tried first and Beta is used only as a fallback.
- **Fail-open by design (XKeen killswitch off).** If mihomo crashes, LAN devices fall back to direct internet access for up to a minute until the cron watchdog restarts mihomo, rather than bricking household connectivity.
- **`geoipset` disabled** — all split-tunneling decisions happen inside mihomo using the subscription's rule providers rather than static iptables IP sets.
- **The UDP bypass is derived from the rules, not configured by hand.** The only IP list in iptables is the one the router derives from the subscription config: dropweb changes rules in its template, routers pick them up with the next subscription update. The list errs on the side of inclusion (an extra address just means a packet goes through mihomo as before), and anything that cannot be parsed turns the bypass off entirely instead of letting traffic skip the rules.

## License

MIT — see [LICENSE](LICENSE).
