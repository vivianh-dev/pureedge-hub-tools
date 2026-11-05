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

## Customer installation: temporary WireGuard and SSH support

Use `wireguard-customer-macos.command` when a customer must install a
pre-enrolled profile without access to Neon. The installer is public. A
separate, customer-specific `.age` file contains the device's WireGuard
private key and your **public** SSH key, encrypted with a random password.
Send the password separately; never upload it or an administrator's
private SSH key to GitHub. The script itself contains no secret and does
not need encryption.

On the admin machine, with `age`, WireGuard's `wg`, Python 3, and root SSH
access to Neon:

```sh
python3 make-support-bundle.py \
  --ssh-key ~/.ssh/id_ed25519.pub \
  --output bundles/customer-support.age \
  --password-file ~/private-support/customer-support.password
```

This generates a unique production peer and schedules revocation on Neon
**24 hours from bundle creation**. Persistent systemd unit files survive
reboots and run overdue revocation on startup. Revocation checks the
original label, public key, and class before removing the peer; its
service retries failures. The expiry timer must be active and enabled
before a new peer is registered. Existing support labels cannot be reused
to extend their expiry. Verify Neon's printed timer before distribution.

Upload only the encrypted `.age` file and public scripts. Give the
customer the bundle URL and this command, replacing the hub IP and bundle
filename:

```sh
curl -fsSL https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wireguard-customer-macos.command -o wireguard-customer-macos.command && sh wireguard-customer-macos.command install 192.168.1.50 https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/bundles/customer-support.age
```

The customer enters the bundle password, then the Pi's current password
at the normal SSH prompt if needed. The installer uses an existing `age`
binary or downloads an official v1.3.2 binary and checks its pinned
SHA-256 hash. It supports Intel and Apple silicon Macs, plus Linux x86-64
and ARM64 laptops. No Homebrew, Neon login, admin SSH private key, or
laptop VPN is required. The customer laptop must reach the Pi over LAN
SSH; the `pi` account needs passwordless sudo. The Pi needs internet,
systemd, `flock`, and a kernel with WireGuard support.

The decrypted profile is transferred over SSH and installed on the Pi
with root-only permissions. Your SSH public key is added to `pi` without
removing existing keys or changing SSH server configuration. SSH and
`wg-neon` start at boot. No router port forwarding is required. A recent
WireGuard handshake is required before the customer sees success; **your
actual SSH login still needs to be tested** from an admin/test tunnel
device using the printed Pi IP. After rebooting the Pi, test SSH again.

Use each bundle on **one Pi only**, and reuse the same bundle only for
retries on that Pi. Multiple devices sharing a peer would fight over one
tunnel address. A Pi with a different existing `wg-neon` key is rejected.
Local networks overlapping `10.88.0.0/16` and unsupported kernels are also
rejected. Installation never upgrades the kernel, firmware, or OS image.
Temporary plaintext files on the laptop are removed when the installer
exits; the installed private key remains on the Pi. Revoking the peer
ends access through this tunnel, including SSH; it does not uninstall the
Pi's profile or remove your SSH public key.

To revoke earlier, run `neon-fleet remove <printed-device-label>` on Neon.
To inspect the scheduled expiry, run `systemctl status
pureedge-support-<printed-device-label>.timer` and `systemctl list-timers`.

## Admin installation: WireGuard and remote SSH on a PureEdge Pi

`wireguard-installer-macos.command` runs on a Mac or Linux admin laptop. It
installs a separate `wg-neon` profile on an existing Debian/Raspberry Pi OS
hub, registers it with Neon's `neon-fleet` as a **production** peer, adds
your SSH public key to the `pi` account, and enables WireGuard and SSH at
boot. It does not install the trial network sweep above.

Requirements:

- The laptop can SSH to the hub as `pi`, and `pi` has passwordless sudo.
  Enter the hub's current password at the normal SSH prompt when needed;
  no password is embedded in these scripts.
- The laptop has root SSH access to Neon, normally through its `neon` SSH
  alias. Use `--neon root@drgb.vivianh.dev` if you do not use that alias.
  This requires an already-authorized SSH key, not the hub's password.
- The laptop is connected to Neon as an admin/test WireGuard peer. A
  production peer cannot initiate connections to other production peers.
- The hub has internet access, systemd, `flock` (util-linux), and kernel
  WireGuard support. Missing tools are installed with apt; kernels,
  firmware, and OS images are not upgraded. Unsupported kernels stop
  installation before a new peer is registered on Neon.

Review the installer and both payloads, `wireguard-pi.sh` and
`wireguard-neon.sh`, before use. Replace the IP and unique device label:

```sh
curl -fsSL https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wireguard-installer-macos.command -o wireguard-installer-macos.command
less wireguard-installer-macos.command
sh wireguard-installer-macos.command install 192.168.1.50 pureedge-site-hub
```

The default SSH public key is the first available `.pub` file associated
with a Neon SSH identity, falling back to `~/.ssh/id_ed25519.pub` and
`~/.ssh/id_rsa.pub`. To choose a different key or Neon SSH target:

```sh
sh wireguard-installer-macos.command install 192.168.1.50 pureedge-site-hub \
  --ssh-key ~/.ssh/id_ed25519.pub --neon root@drgb.vivianh.dev
```

Each Pi generates its own private key and keeps it on the Pi in
`/etc/wireguard/wg-neon.key`, readable only by root. Only its public key
is sent to Neon. Rerun with the **same label and same Pi** after a partial
failure: the saved device key and existing matching enrollment are reused.
A label assigned to a different key or class is rejected. An unrelated
existing `wg-neon.conf` is not overwritten. The installer stops if the
hub's local network overlaps the fleet network, `10.88.0.0/16`.

The profile routes the fleet network through Neon and sets a 25-second
keepalive. Normal internet and lighting LAN traffic keep their existing
routes. Existing SSH authorized keys and server configuration are
preserved. No router port forwarding is needed. The script does not
change existing SSH listen addresses or firewall rules; restrictive
settings may need a site-specific adjustment.

Success requires a recent handshake with Neon **and a key-authenticated
SSH login from the laptop to the Pi's tunnel IP**, using the host key
learned over the original LAN SSH connection. The installer prints the
assigned IP and exact SSH command. If the laptop is not connected to the
admin/test tunnel or its key is unavailable, verification fails even if
the Pi's profile was installed. Retained enrollments are not automatically
revoked after failures; retry with the same device or deliberately revoke
the peer using `neon-fleet remove <label>` on Neon.

After a first install, reboot one hub and check from your admin device:

```sh
ssh pi@<assigned-wireguard-ip>
sudo systemctl is-enabled ssh.service wg-quick@wg-neon.service
sudo systemctl is-active ssh.service wg-quick@wg-neon.service
sudo wg show wg-neon latest-handshakes
```

Expected: SSH login works, both services are enabled and active, and the
server peer has a recent nonzero handshake. Real hub hardware, native
macOS integration, and reboot persistence require this site test before
rollout. Automated tests use isolated files and mocked SSH, WireGuard,
package, and service operations; they do not establish hardware acceptance.

For an offline installer laptop, explicitly select previously reviewed
payload files (the Pi still needs network access for apt and its tunnel):

```sh
PUREEDGE_WG_PI_PAYLOAD=./wireguard-pi.sh \
PUREEDGE_WG_NEON_PAYLOAD=./wireguard-neon.sh \
sh wireguard-installer-macos.command install 192.168.1.50 pureedge-site-hub
```

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
