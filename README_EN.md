<div align="right">
  <a href="README.md">Русский</a>
</div>

# dropweb VPN on Keenetic — One-Shot Installer (XKeen 2 + mihomo)

A single script turns a Keenetic router with Entware into a **transparent VPN router** for a dropweb subscription: selected devices (TV, PC, phone, console) route through the VPN automatically without installing client software on each device. Direct/domestic traffic bypasses the tunnel according to the rules delivered by the dropweb subscription.

## What You Get

- **Transparent VPN for selected devices** via [XKeen 2](https://github.com/jameszeroX/XKeen) + **mihomo** (Clash.Meta) with dropweb routing rules: both TCP and UDP from devices in the policy are intercepted at the router
- **Web toggle panel ("Disable / Enable VPN")** at `http://192.168.1.1:8181/` — no SSH required for daily control
- **Zashboard UI** at `http://192.168.1.1:9090/ui/` — nodes, active connections, logs, latency checks. Protected by an API secret
- **Hourly subscription sync** — full config diffing with hot reload via the mihomo API (zero connection drops when changed)
- **Watchdog** — automatically restarts mihomo within a minute if the process crashes
- **One-click / one-command emergency bypass** — and the VPN **stays disabled across router reboots** until explicitly re-enabled

## Requirements

1. **Keenetic router** running KeeneticOS 4+ with Entware support (Giga, Ultra, Hopper, Sprinter, Peak, etc.)
2. **Entware/OPKG** installed on a USB drive (Keenetic web UI → Applications → install OPKG → reboot router)
3. **Root SSH access** to Entware (default: `root@192.168.1.1`, password `keenetic`)
4. **Subscription URL from the dropweb bot** — current gateway link (`https://….apigw.yandexcloud.net/…`)

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

## Post-Install Endpoints

```text
On/Off Web Panel :  http://192.168.1.1:8181/
mihomo Dashboard :  http://192.168.1.1:9090/ui/
mihomo API       :  http://192.168.1.1:9090 (secret printed after install)
```

The API secret and all persisted settings live in `/opt/etc/dropweb-xkeen/settings.env` (`API_SECRET=`). At the end of installation, the script prints a pre-authenticated dashboard URL.

## Emergency Bypass Scenarios

### 1. Web Panel → "⛔ Disable VPN"

One click stops mihomo and removes traffic interception so **all devices go directly to the internet**. The disabled state persists across reboots until you click "✅ Enable VPN".

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

## Troubleshooting: "Service Returned a Stub Config"

If the subscription returns a stub instead of proxy nodes, the **device limit** has been reached or the HWID was rejected:

1. In the dropweb bot → **Devices**, remove an unused device slot
2. Re-run the installer: `sh /tmp/install.sh`

The router's HWID is printed in the error message and stored in `/opt/etc/dropweb-xkeen/settings.env`. Avoid changing it unnecessarily, as a new HWID consumes another device slot.

## Installed File Layout

| Path | Purpose |
|---|---|
| `/opt/etc/dropweb-xkeen/settings.env` | Persisted configuration: subscription URL, HWID, ports, API secret |
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
| `/opt/sbin/mihomo-panel.py` | Lightweight web control panel (Python stdlib) |
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
- **Deterministic HWID from LAN MAC.** Re-installs and upgrades reuse the same HWID so device slots are never leaked.
- **XKeen 2.0.1 Beta only when required.** Non-interactive installation (`xkeen -i auto`) requires 2.0.1 Beta; stable is tried first and Beta is used only as a fallback.
- **Fail-open by design (XKeen killswitch off).** If mihomo crashes, LAN devices fall back to direct internet access for up to a minute until the cron watchdog restarts mihomo, rather than bricking household connectivity.
- **`geoipset` disabled** — all split-tunneling decisions happen inside mihomo using the subscription's rule providers rather than static iptables IP sets.

## License

MIT — see [LICENSE](LICENSE).
