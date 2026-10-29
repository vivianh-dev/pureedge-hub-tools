# wiz-keepalive-installer-windows.ps1
#
# Installs the WiZ keepalive sweep onto a Raspberry Pi hub, from Windows.
#
# One-liner (no file needed):
#   iwr -useb https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wiz-keepalive-installer-windows.ps1 | iex
#
# With hub addresses given:
#   .\wiz-keepalive-installer-windows.ps1 install 192.168.1.50 192.168.1.51
#   .\wiz-keepalive-installer-windows.ps1 remove 192.168.1.50
#   .\wiz-keepalive-installer-windows.ps1 status 192.168.1.50
#   .\wiz-keepalive-installer-windows.ps1 discover
#
# With no arguments it asks what to do and which hubs to use.
#
# Requires the Windows OpenSSH client (ssh and scp). On Windows 10 version
# 1803 and later it is an optional feature that may need installing.
# You will be asked for the hub password, once per hub (factory default on
# these units: pi / DALInew).

param(
    [Parameter(Position = 0)]
    [string]$Mode = "",
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Hub,
    [string]$PayloadUrl = "https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wiz-keepalive.sh"
)

# discover lists hosts on this machine's subnet that look like a hub, so
# nobody has to know the hub address in advance. These are candidates, not a
# confirmed identification.
function Find-Hubs {
    $cidr = $null
    try {
        $route = Get-NetRoute -DestinationPrefix 0.0.0.0/0 -ErrorAction Stop |
            Sort-Object RouteMetric | Select-Object -First 1
        $ip = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.PrefixLength -ge 16 -and $_.PrefixLength -le 28 } | Select-Object -First 1
        if ($ip) { $cidr = $ip.IPAddress + "/" + $ip.PrefixLength }
    } catch { }
    if (-not $cidr) {
        Write-Output "could not determine this machine's network"
        return
    }
    Write-Output "scanning $cidr for hosts that look like a hub"
    $base = ($cidr -split '/')[0] -replace '\.\d+$', ''
    $ping = New-Object System.Net.NetworkInformation.Ping
    $replies = @()
    foreach ($i in 1..254) {
        $target = "$base.$i"
        try {
            $r = $ping.Send($target, 300)
            if ($r.Status -eq "Success") { $replies += $r.Address.ToString() }
        } catch { }
    }
    $ping.Dispose()
    foreach ($h in $replies) {
        $found = @()
        foreach ($p in 22, 80, 443) {
            $t = New-Object System.Net.Sockets.TcpClient
            try {
                $iar = $t.BeginConnect($h, $p, $null, $null)
                if ($iar.AsyncWaitHandle.WaitOne(500, $false)) {
                    $t.EndConnect($iar)
                    if ($t.Connected) { $found += $p }
                }
            } catch { } finally { $t.Close() }
        }
        if ($found.Count -gt 0) {
            Write-Output "  $h  candidate (ports open: $($found -join ' '))"
        } else {
            Write-Output "  $h  no ssh or web ports open"
        }
    }
}

if ($Mode -eq "discover") {
    Find-Hubs
    exit 0
}

if (-not $Mode) {
    $Mode = Read-Host "install, remove, status or discover? (install)"
    if (-not $Mode) { $Mode = "install" }
}

if ($Mode -notin @("install", "remove", "status", "run")) {
    Write-Output "unknown action: $Mode"
    exit 1
}

if (-not $Hub -or $Hub.Count -eq 0) {
    $answer = Read-Host "hub IP address(es), space separated"
    $Hub = $answer -split '\s+' | Where-Object { $_ }
}

if (-not $Hub -or $Hub.Count -eq 0) {
    Write-Output "no hub address given"
    exit 1
}

$ProgressPreference = "SilentlyContinue"
$temp = Join-Path $env:TEMP "wiz-keepalive.sh"

try {
    Invoke-WebRequest -UseBasicParsing -ErrorAction Stop -Uri $PayloadUrl -OutFile $temp
} catch {
    Write-Output "could not download $PayloadUrl : $($_.Exception.Message)"
    exit 1
}

$failed = $false
foreach ($h in $Hub) {
    Write-Output "== $h =="
    # Capture the remote exit status before the cleanup runs, so a failed
    # install is not reported as a success.
    # sudo -n so the hub either has passwordless sudo for pi or fails
    # immediately, instead of hanging on a prompt nobody can see.
    # scp copies the file byte for byte. Piping it through PowerShell would
    # rewrite the line endings to CRLF and break the script on the hub.
    & scp.exe -q $temp "pi@${h}:/tmp/wiz-keepalive.sh"
    if ($LASTEXITCODE -ne 0) {
        Write-Output "== $h failed to copy"
        $failed = $true
        continue
    }
    & ssh.exe "pi@$h" "sudo -n sh /tmp/wiz-keepalive.sh $Mode; rc=`$?; rm -f /tmp/wiz-keepalive.sh; exit `$rc"
    if ($LASTEXITCODE -eq 0) {
        Write-Output "== $h ok"
    } else {
        Write-Output "== $h failed (check password and that the hub is reachable)"
        Write-Output "   if the hub wants a sudo password, log in with ssh pi@$h and run: sudo sh /tmp/wiz-keepalive.sh $Mode"
        $failed = $true
    }
}

Remove-Item $temp -Force -ErrorAction SilentlyContinue
if ($failed) { exit 1 }
exit 0
