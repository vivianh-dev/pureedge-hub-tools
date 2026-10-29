# Run on Windows PowerShell 5.1 or PowerShell 7 with Windows OpenSSH.
# .\wiz-keepalive-installer-windows.ps1 install 192.168.1.50
param(
    [Parameter(Position = 0)] [string]$Mode = '',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)] [string[]]$Hub,
    [string]$PayloadUrl = 'https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wiz-keepalive.sh',
    [string]$PayloadPath = ''
)

$ErrorActionPreference = 'Stop'

function Get-CidrRange {
    param([string]$Address, [int]$PrefixLength)
    if ($PrefixLength -lt 16 -or $PrefixLength -gt 32) {
        throw 'Supported IPv4 prefixes are /16 through /32; larger scans are refused.'
    }
    if ($Address -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { throw 'Invalid IPv4 address.' }
    [uint64]$number = 0
    foreach ($octet in $Address.Split('.')) {
        if ([int]$octet -gt 255) { throw 'Invalid IPv4 address.' }
        $number = $number * 256 + [uint64]$octet
    }
    [uint64]$size = [math]::Pow(2, 32 - $PrefixLength)
    [uint64]$network = [math]::Floor($number / $size) * $size
    [uint64]$first = $network
    [uint64]$last = $network + $size - 1
    if ($size -gt 2) { $first++; $last-- }
    [pscustomobject]@{ Network = $network; Prefix = $PrefixLength; First = $first; Last = $last }
}

function ConvertTo-IPv4 {
    param([uint64]$Number)
    '{0}.{1}.{2}.{3}' -f (($Number -shr 24) -band 255), (($Number -shr 16) -band 255), (($Number -shr 8) -band 255), ($Number -band 255)
}

function Get-RespondingHosts {
    param($Range)
    # Sixteen asynchronous probes at a time. Never truncate a prefix to /24.
    $batch = @()
    try {
        for ([uint64]$number = $Range.First; $number -le $Range.Last; $number++) {
            $target = ConvertTo-IPv4 $number
            $client = New-Object System.Net.NetworkInformation.Ping
            try { $task = $client.SendPingAsync($target, 1000) }
            catch { $client.Dispose(); throw }
            $batch += [pscustomobject]@{ Client = $client; Task = $task }
            if ($batch.Count -eq 16 -or $number -eq $Range.Last) {
                foreach ($probe in $batch) {
                    $reply = $probe.Task.GetAwaiter().GetResult()
                    if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                        $reply.Address.ToString()
                    }
                }
                foreach ($probe in $batch) { $probe.Client.Dispose() }
                $batch = @()
            }
        }
    } finally {
        foreach ($probe in $batch) { $probe.Client.Dispose() }
    }
}

function Find-Hubs {
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
        Sort-Object RouteMetric | Select-Object -First 1
    if (-not $route) { throw 'No IPv4 default route found.' }
    $address = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
    if (-not $address) { throw 'No usable IPv4 address found.' }
    $range = Get-CidrRange $address.IPAddress $address.PrefixLength
    Write-Host ('Scanning {0}/{1} for candidate hubs' -f (ConvertTo-IPv4 $range.Network), $range.Prefix)
    foreach ($candidate in @(Get-RespondingHosts $range)) {
        $ports = @()
        foreach ($port in 22, 80, 443) {
            $client = New-Object System.Net.Sockets.TcpClient
            try {
                $pending = $client.BeginConnect($candidate, $port, $null, $null)
                if ($pending.AsyncWaitHandle.WaitOne(500, $false)) {
                    $client.EndConnect($pending)
                    if ($client.Connected) { $ports += $port }
                }
            } catch { } finally { $client.Close() }
        }
        Write-Output "$candidate  open ports: $($ports -join ' ') (candidate only)"
    }
}

try {
    if (-not $Mode) {
        $Mode = Read-Host 'install, remove, status, run or discover? (install)'
        if (-not $Mode) { $Mode = 'install' }
    }
    $Mode = $Mode.ToLowerInvariant()
    if ($Mode -notin @('install', 'remove', 'status', 'run', 'discover')) { throw "Unknown action: $Mode" }
    if ($Mode -eq 'discover') { Find-Hubs; exit 0 }

    if (-not $Hub -or $Hub.Count -eq 0) {
        $Hub = (Read-Host 'hub IPv4 address(es) or hostnames, space separated') -split '\s+' | Where-Object { $_ }
    }
    if (-not $Hub -or $Hub.Count -eq 0) { throw 'No hub address given.' }
    foreach ($target in $Hub) {
        if ($target -notmatch '^[a-zA-Z0-9_][a-zA-Z0-9._-]*$') { throw "Invalid IPv4 address or hostname: $target" }
    }
    Get-Command ssh.exe -ErrorAction Stop | Out-Null
    Get-Command scp.exe -ErrorAction Stop | Out-Null

    $downloaded = $null
    try {
        if ($PayloadPath) {
            $payload = (Resolve-Path -LiteralPath $PayloadPath -ErrorAction Stop).Path
        } else {
            $downloaded = [System.IO.Path]::GetTempFileName()
            $payload = $downloaded
            Invoke-WebRequest -UseBasicParsing -ErrorAction Stop -TimeoutSec 60 -Uri $PayloadUrl -OutFile $payload
        }
        if ((Get-Item -LiteralPath $payload).Length -eq 0) { throw 'Payload is empty.' }
        $failed = $false
        foreach ($target in $Hub) {
            # scp preserves bytes; unique remote paths avoid install collisions.
            $remoteFile = '/tmp/wiz-keepalive-' + [guid]::NewGuid().ToString('N') + '.sh'
            Write-Host "${target}: $Mode"
            & scp.exe -q -o ConnectTimeout=10 $payload "pi@${target}:$remoteFile"
            if ($LASTEXITCODE -ne 0) {
                Write-Host "${target}: copy failed"
                $failed = $true
                continue
            }
            $remote = 'chmod 600 {0} && sudo -n sh {0} {1}; rc=$?; if [ "$rc" -eq 0 ]; then rm -f {0}; else printf "Retry on the hub: sudo sh {0} {1}\n" >&2; fi; exit "$rc"' -f $remoteFile, $Mode
            & ssh.exe -o ConnectTimeout=10 "pi@$target" $remote
            if ($LASTEXITCODE -ne 0) {
                Write-Host "${target}: failed (check the error above)"
                $failed = $true
            } else { Write-Host "${target}: succeeded" }
        }
    } finally {
        if ($downloaded) { Remove-Item -LiteralPath $downloaded -Force -ErrorAction SilentlyContinue }
    }
    if ($failed) { exit 1 }
    exit 0
} catch {
    Write-Error -ErrorAction Continue $_
    exit 1
}
