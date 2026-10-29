# pureedge-hub-tools

Tooling for ATX LED / PureEdge hubs, including the DMX-to-WiZ converters.

## WiZ keepalive sweep

Keeps Wi-Fi lighting clients associated with the access point by sweeping the
local subnet on a fixed interval. Sleeping clients that stop talking get aged
out of the AP and drop off the controller.

Generic: works on any Raspberry Pi / Debian-family Linux, any subnet, wired or
wireless. Nothing is hardcoded to a site.

### One-line install

Linux or macOS, from the machine that can reach the hub:

```sh
curl -fsSL https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wiz-keepalive-installer-linux.sh | sh -s -- install 192.168.1.50
```

macOS uses the same command with `wiz-keepalive-installer-macos.command` in
place of `wiz-keepalive-installer-linux.sh`.

Windows, PowerShell:

```powershell
iwr -useb https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wiz-keepalive-installer-windows.ps1 | iex
```

With no arguments the Windows installer asks what to do and which hubs to
use. The Linux and macOS installers take the hub addresses as arguments, or
ask for them if none are given.

### Running on the hub directly

```sh
sudo sh wiz-keepalive.sh install     # set it up
sudo sh wiz-keepalive.sh status       # check it
sudo sh wiz-keepalive.sh run          # one sweep now
sudo sh wiz-keepalive.sh remove       # undo
```

### Files

| File | Runs on | Does |
|---|---|---|
| `wiz-keepalive.sh` | the Pi | The actual installer. Sets up the scheduled job on the hub. |
| `wiz-keepalive-installer-linux.sh` | Linux laptop | Fetches the installer and pushes it to the hub over SSH. |
| `wiz-keepalive-installer-macos.command` | Mac | Same. |
| `wiz-keepalive-installer-windows.ps1` | Windows | Same. |

The pushers need `ssh` and `scp`. On macOS and Windows those are built in; on
Linux, install `openssh-client`. The hub password is asked for once per hub
(factory default on these units: `pi` / `DALInew`).

### What it does on the hub

- Detects the subnet from the default route interface, so it works on any
  network without configuration.
- Writes `/usr/local/bin/wiz-keepalive-sweep`, which runs `nmap -sn` (host
  discovery over ARP) against that subnet. If nmap is not installed it falls
  back to a broadcast ping. It installs nmap from apt when it can and works
  offline otherwise.
- Schedules it every 10 minutes, offset by a few seconds per unit so a row of
  hubs on one site does not all sweep at the same moment. Uses cron where
  cron is present, otherwise a systemd timer.
- Writes no logs and sends nothing off the network.

### Notes

- The sweep is a diagnostic-grade workaround for client sleep and AP aging
  behavior, not a replacement for fixing AP settings. If the access point has
  a client idle timeout, tuning that is the real fix.
- It does not change the hub's lighting behavior, only how often the network
  sees the fixtures.
- `nmap -sn` needs root for raw socket use. It runs from cron or the systemd
  timer as root, which is why the install step uses sudo.
- `curl -fsSL` is deliberate: `-f` stops a 404 page being piped into `sh`,
  `-s` hides the progress meter, `-S` still shows errors, `-L` follows
  redirects.

## License

Internal use for Lightology and PureEdge projects.
