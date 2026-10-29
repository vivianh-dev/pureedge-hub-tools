# pureedge-hub-tools

Tooling for ATX LED / PureEdge hubs, including the DMX-to-WiZ converters.

## WiZ keepalive sweep

Keeps Wi-Fi lighting clients visible to the network by sweeping the local
subnet on a fixed interval. The idea is that a fixture that stops talking
gets aged out by the access point and drops off the controller, and a
periodic sweep keeps it answering.

This is a trial, not a proven fix. It increases how often the network sees
the fixtures. It cannot repair a fixture that has failed to associate, RF or
capacity problems, client isolation, or a hub whose lighting application has
stopped. Note that the hub already talks to its fixtures every five minutes
on its own, so the sweep may turn out to be redundant; the point of trying
it is to see whether it changes anything.

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

The pushers need `ssh`, and `scp` on Windows. macOS has both built in; on
Linux, install `openssh-client`. The hub password is asked for once per hub
on Linux and macOS, twice on Windows (once to copy the file, once to run it).
The factory default on these units is `pi` / `DALInew`.

The install step runs as root on the hub. It uses `sudo -n`, so a hub whose
`pi` account has passwordless sudo completes unattended, and a hub that
wants a password fails immediately with a message instead of hanging on a
prompt. The same is true of the systemd timer path: it is only ever touched
as root, so it never raises an authentication prompt.

### What it does on the hub

- Detects the subnet from the interface that carries the default route, so
  it works on any network without configuration.
- Writes `/usr/local/bin/wiz-keepalive-sweep`, which runs `nmap -sn` (host
  discovery over ARP) against that subnet. If nmap is not installed it falls
  back to a broadcast ping. It installs nmap from apt when it can and works
  offline otherwise.
- Schedules it every 10 minutes. The minute offsets are derived from the
  unit's machine-id, so hubs on one site do not all sweep at the same
  moment. Uses cron where cron is present, otherwise a systemd timer, and
  never leaves both installed at once.
- The sweep itself is local and sends nothing off the network. Installing
  may contact the package repository if nmap is not already on the hub, and
  the scheduler will of course write its own service logs.

### Notes

- The sweep is a diagnostic-grade workaround for client sleep and AP aging
  behavior, not a replacement for fixing AP settings. If the access point has
  a client idle timeout, tuning that is the real fix.
- It does not change the hub's lighting behavior, only how often the network
  sees the fixtures.
- The sweep runs as root, from cron or from the systemd timer. Run as root,
  nmap uses ARP for host discovery; unprivileged it falls back to TCP
  connect probes, which is slower and will not find hosts that block those
  ports.
- `curl -fsSL` is deliberate: `-f` stops a 404 page being piped into `sh`,
  `-s` hides the progress meter, `-S` still shows errors, `-L` follows
  redirects.

## License

Internal use for Lightology and PureEdge projects.
