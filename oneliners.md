# One-line installs

The installer scripts can be fetched and run in a single command, with no
copying and no separate ssh step.

## What the flags mean

`curl -fsSL` is four separate things:

| Flag | Does |
|---|---|
| `-f` | fail on HTTP errors, send no body. Without it a 404 page gets piped into `sh` and run. |
| `-s` | no progress meter, no noise. |
| `-S` | still show the error when something goes wrong. `-s` alone hides the reason. |
| `-L` | follow redirects, so a moved URL still works. |

`sh -s --` feeds the piped script to `sh` as standard input and passes the
arguments after `--` to it. `install`, `remove`, `status` and `run` are the
arguments.

The install runs on the hub as root and uses `sudo -n`, so it either
completes unattended or fails straight away with a message, rather than
stopping on a password prompt.

`iex` is the PowerShell equivalent of `| sh`: it runs the text it is given as
PowerShell. `iwr -useb URL | iex` is the Windows form of `curl URL | sh`.

One thing to know about `iex`: it does not check that the download worked. If
the URL is wrong you get an error message from PowerShell instead of a
script, which is confusing but harmless. For the same reason `curl ... | sh`
can return success even when the download failed, because the shell still
runs, on an empty script. If you want to be certain, download the file
first and run it as a second step.

## Linux and macOS

Both ship curl, so the command is identical. Run it on the laptop that can
reach the hub:

```sh
curl -fsSL https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wiz-keepalive-installer-linux.sh | sh -s -- install 192.168.1.50
```

macOS, same command with a different filename:

```sh
curl -fsSL https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wiz-keepalive-installer-macos.command | sh -s -- install 192.168.1.50
```

If the hub itself has internet access, the same thing straight onto the Pi:

```sh
curl -fsSL https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wiz-keepalive.sh | sudo sh -s -- install
```

Without curl, wget does the same job (`-q` quiet, `-O-` to stdout, and it
already exits non-zero on an HTTP error):

```sh
wget -qO- https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wiz-keepalive-installer-linux.sh | sh -s -- install 192.168.1.50
```

## Windows

PowerShell, one line, no file saved:

```powershell
iwr -useb https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wiz-keepalive-installer-windows.ps1 | iex
```

It asks what to do and which hubs to use. With the addresses given up front,
as a saved script:

```powershell
.\wiz-keepalive-installer-windows.ps1 install 192.168.1.50 192.168.1.51
```

On Windows 10 version 1803 and later, curl is included, so the shell form
works in cmd or PowerShell. This form fetches the hub-side script, not the
PowerShell installer, because it is the hub that runs it:

```
curl.exe -fsSL https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wiz-keepalive.sh | ssh pi@HUB "sudo sh -s -- install"
```

Note that PowerShell's `curl` is an alias for `Invoke-WebRequest`, not the
real curl. Use `curl.exe` if you want the flags above to behave exactly like
the Linux one.

## Several hubs at once

```sh
for h in 192.168.1.50 192.168.1.51; do curl -fsSL https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wiz-keepalive-installer-linux.sh | sh -s -- install $h; done
```

## Checking the file before running it

On a hub that has internet access, download it and look at it first:

```sh
curl -fsSL https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wiz-keepalive.sh -o wiz-keepalive.sh
less wiz-keepalive.sh
sudo sh wiz-keepalive.sh install
```

To verify the download against a published checksum:

```sh
curl -fsSL https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wiz-keepalive.sh -o wiz-keepalive.sh
sha256sum wiz-keepalive.sh
```

The published checksum and the file should come from the same place, so this
only helps if that place is trustworthy. On a hub with no internet, use scp
from a laptop instead, and read the file before running it.

## Where the file lives

`github.com/vivianh-dev/pureedge-hub-tools`, served as raw files. It has to
be a stable URL that will not change between installations, since it goes
into install instructions people will follow in a year.
