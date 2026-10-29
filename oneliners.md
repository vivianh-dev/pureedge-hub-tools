# Installer commands

Replace `192.168.1.50` with the hub address. Review the scripts before use.
The installers fetch and execute a separate Pi-side payload as root on the
hub; inspect that payload too. See [README.md](README.md) for offline use,
requirements, scan limits and validation status.

## Download, inspect, run

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
