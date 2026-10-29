# pureedge-hub-tools

A trial network sweep for ATX LED / PureEdge Raspberry Pi hubs. It schedules
local host discovery approximately every ten minutes. It does not send
lighting commands or change fixture configuration.

This is an **unproven workaround**, not an established fix for UWGB. Wi-Fi
association, hub discovery and successful lighting commands are separate
checks. The firmware inspected already attempts WiZ discovery about every
five minutes and can skip commands to fixtures it considers missing.

## Install from a laptop

The laptop must reach the hub on SSH. The hub uses account `pi` and must
allow passwordless sudo for unattended installation. Linux/macOS need `sh`,
`curl` and OpenSSH; Windows needs PowerShell 5.1 or later and Windows
OpenSSH (`ssh.exe` and `scp.exe`). Use the actual hub address below.

Download and inspect the installer before running it:

```sh
curl -fsSL https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wiz-keepalive-installer-linux.sh -o wiz-keepalive-installer-linux.sh
less wiz-keepalive-installer-linux.sh
sh wiz-keepalive-installer-linux.sh install 192.168.1.50
```

The Linux and macOS scripts both detect the laptop's platform. The macOS
filename `wiz-keepalive-installer-macos.command` remains available too.
Windows:

```powershell
Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wiz-keepalive-installer-windows.ps1 -OutFile wiz-keepalive-installer-windows.ps1
Get-Content .\wiz-keepalive-installer-windows.ps1
.\wiz-keepalive-installer-windows.ps1 install 192.168.1.50
```

Actions are `install`, `status`, `run`, `remove` and `discover`. With no
arguments, the installers prompt for an action and addresses. Multiple
addresses can follow an action. `discover` scans the laptop's own subnet
and lists candidates; an open web/SSH port does not identify an ATX hub.

The Unix installers use one SSH connection per hub. Windows uses separate
copy and execution connections and may ask for the password twice. Failed
remote executions retain a uniquely named payload and print a retry command.
Successful executions remove that temporary payload.

Payloads are downloaded explicitly; a nearby `wiz-keepalive.sh` is never
selected automatically. For an offline laptop, explicitly select a saved,
reviewed payload:

```sh
WIZ_KEEPALIVE_PAYLOAD=/path/to/wiz-keepalive.sh sh wiz-keepalive-installer-linux.sh install 192.168.1.50
```

```powershell
.\wiz-keepalive-installer-windows.ps1 install 192.168.1.50 -PayloadPath .\wiz-keepalive.sh
```

## On the Pi

```sh
sudo sh wiz-keepalive.sh install
sudo sh wiz-keepalive.sh status
sudo sh wiz-keepalive.sh run
sudo sh wiz-keepalive.sh remove
```

The script detects the IPv4 subnet on the default-route interface, falling
back to another configured interface if no default route exists. Check the
printed subnet is the fixture LAN, especially on a Pi with several interfaces
or a VPN. An explicit interface is saved into the installed sweep:

```sh
sudo env WIZ_KEEPALIVE_INTERFACE=wlan0 sh wiz-keepalive.sh install
```

Supported prefixes are `/16` through `/32`. Wider networks fail explicitly;
they are not silently reduced to a `/24`. The fallback handles subnet
boundaries, including `/31` and `/32`. It runs at most sixteen one-second
ping probes concurrently. A `/16` fallback can take over an hour; use nmap
for large networks. A lock skips overlapping sweeps.

Installation attempts to install nmap with apt when it is absent; this may
contact package repositories. If unavailable, the script requires ping.
The Pi also needs `ip`, `awk`, `flock` (util-linux), and cron or a running
systemd. No lighting application or OS image is replaced.

Cron runs six times per hour, ten minutes apart, with a machine-id-derived
offset; offsets can collide between hubs. The systemd fallback runs about
every ten minutes with a small randomized delay. The installer verifies the
scheduler starts and removes the alternate scheduler only after success.
It touches systemd timer cleanup only when its timer/service files exist.

`status` returns nonzero for a missing/inactive scheduler, missing sweep,
invalid subnet or missing scan tool. A successful scan means the scan tool
completed, not that every fixture answered or that lighting control works.
Removal unschedules future sweeps; an already running sweep may finish.

## Verification

```sh
python3 -m unittest discover -s tests -v
pwsh -NoProfile -File tests/test_windows.ps1
```

Tests isolate package/service commands, SSH and host discovery. They cover
subnet boundaries, scheduler failures, payload selection, remote failure
recovery, and PowerShell discovery dispatch. Real ATX hardware and native
Windows/macOS network integration still need a site test on one hub before
rollout. A supplied hub-image update remains ATX's responsibility.

## License

Internal use for Lightology and PureEdge projects.
