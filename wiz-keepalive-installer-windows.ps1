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
# Requires the built-in Windows OpenSSH client (ssh and scp).
# You will be asked for the hub password for each one (factory default on
# these units: pi / DALInew).

param(
    [Parameter(Position = 0)]
    [string]$Mode = "",
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Hub,
    [string]$PayloadUrl = "https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wiz-keepalive.sh"
)

# discover lists hosts on this machine's subnet that answer on the ports the
# hub web interface uses, so nobody has to know the hub address in advance.
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
    Write-Output "scanning $cidr"
    $base = ($cidr -split '/')[0] -replace '\.\d+$', ''
    $ping = New-Object System.Net.NetworkInformation.Ping
    $targets = foreach ($i in 1..254) { "$base.$i" }
    $replies = $targets | ForEach-Object {
        $r = $ping.Send($_, 300)
        if ($r.Status -eq "Success") { $_.Address }
    }
    $ping.Dispose()
    foreach ($h in $replies) {
        $isHub = $false
        foreach ($p in 80, 443, 5500) {
            $t = New-Object System.Net.Sockets.TcpClient
            try {
                $iar = $t.BeginConnect($h, $p, $null, $null)
                if ($iar.AsyncWaitHandle.WaitOne(500, $false) -and $t.Connected) {
                    Write-Output "$h  (hub, port $p)"
                    $isHub = $true
                    break
                }
            } catch { } finally { $t.Close() }
        }
        if (-not $isHub) { Write-Output "$h  (no hub ports open)" }
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

if ($Mode -eq "discover") {
    Find-Hubs
    exit 0
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

foreach ($h in $Hub) {
    Write-Output "== $h =="
    & scp.exe -q $temp "pi@${h}:/tmp/wiz-keepalive.sh"
    if ($LASTEXITCODE -ne 0) {
        Write-Output "== $h failed to copy"
        continue
    }
    & ssh.exe "pi@$h" "sudo sh /tmp/wiz-keepalive.sh $Mode; rm -f /tmp/wiz-keepalive.sh"
    if ($LASTEXITCODE -eq 0) {
        Write-Output "== $h ok"
    } else {
        Write-Output "== $h failed (check password and that the hub is reachable)"
    }
}

Remove-Item $temp -Force -ErrorAction SilentlyContinue
