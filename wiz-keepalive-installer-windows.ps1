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

if (-not $Mode) {
    $Mode = Read-Host "install, remove or status? (install)"
    if (-not $Mode) { $Mode = "install" }
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
