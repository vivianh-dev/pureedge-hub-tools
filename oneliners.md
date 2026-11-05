# Installer commands

Replace `192.168.1.50` with the hub address. Review the scripts before use.
The installers fetch and execute a separate Pi-side payload as root on the
hub; inspect that payload too. See [README.md](README.md) for offline use,
requirements, scan limits and validation status.

## Download, inspect, run

macOS:

```sh
curl -fsSL https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wiz-keepalive-installer-macos.command -o wiz-keepalive-installer-macos.command
less wiz-keepalive-installer-macos.command
sh wiz-keepalive-installer-macos.command install 192.168.1.50
```

Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wiz-keepalive-installer-linux.sh -o wiz-keepalive-installer-linux.sh
less wiz-keepalive-installer-linux.sh
sh wiz-keepalive-installer-linux.sh install 192.168.1.50
```

The macOS filename is `wiz-keepalive-installer-macos.command`. Both Unix
installers support Linux and macOS.

```powershell
Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wiz-keepalive-installer-windows.ps1 -OutFile wiz-keepalive-installer-windows.ps1
Get-Content .\wiz-keepalive-installer-windows.ps1
.\wiz-keepalive-installer-windows.ps1 install 192.168.1.50
```

## Piped forms, after review

```sh
curl -fsSL https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wiz-keepalive-installer-linux.sh | sh -s -- install 192.168.1.50
```

```sh
curl -fsSL https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wiz-keepalive-installer-macos.command | sh -s -- install 192.168.1.50
```

```powershell
Invoke-WebRequest -UseBasicParsing -ErrorAction Stop https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wiz-keepalive-installer-windows.ps1 | Invoke-Expression
```

In a POSIX shell, a failed curl can leave the final shell executing empty
input and returning success. Downloading to a file and checking curl's
exit status before running it avoids that ambiguity. `curl -fsSL` reports
HTTP failures and follows redirects; it does not authenticate script content.

## Several hubs and other actions

```sh
sh wiz-keepalive-installer-linux.sh install 192.168.1.50 192.168.1.51
sh wiz-keepalive-installer-linux.sh status 192.168.1.50
sh wiz-keepalive-installer-linux.sh run 192.168.1.50
sh wiz-keepalive-installer-linux.sh remove 192.168.1.50
sh wiz-keepalive-installer-linux.sh discover
```

```powershell
.\wiz-keepalive-installer-windows.ps1 discover
```

The laptop must be on the intended subnet for discovery. Results are
candidate hosts, not confirmed hubs. A scan failure returns nonzero.

## WireGuard and SSH (separate from the trial sweep)

For a **customer** with a pre-generated encrypted support bundle, use this
command after replacing the hub IP and bundle filename. Send the bundle
password separately. Each bundle is for one Pi and expires 24 hours after
creation. The customer needs no Neon account or laptop VPN.

```sh
curl -fsSL https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wireguard-customer-macos.command -o wireguard-customer-macos.command && sh wireguard-customer-macos.command install 192.168.1.50 https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/bundles/customer-support.age
```

See [customer setup and expiry](README.md#customer-installation-temporary-wireguard-and-ssh-support).

For an **admin** registering a new peer directly:

Run on an admin laptop with root SSH access to Neon and an active admin/test
WireGuard connection. Replace the hub IP and give each Pi a unique label.
The default public SSH key comes from the laptop's Neon SSH configuration;
use `--ssh-key /path/to/key.pub` to select another key. The Pi must allow
passwordless sudo. Review this installer and both payloads first; see the
[WireGuard requirements and verification steps](README.md#admin-installation-wireguard-and-remote-ssh-on-a-pureedge-pi).

```sh
curl -fsSL https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wireguard-installer-macos.command -o wireguard-installer-macos.command && sh wireguard-installer-macos.command install 192.168.1.50 pureedge-site-hub
```

The installer generates the private key on the Pi, enrolls only its public
key on Neon, and enables SSH and `wg-neon` at boot. It reports success only
after a recent tunnel handshake and an SSH login over the tunnel. Retry
partial failures with the same label and Pi; retained enrollments are not
automatically removed.
