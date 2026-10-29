param([string]$PowerShellPath = (Get-Process -Id $PID).Path)
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'wiz-keepalive-installer-windows.ps1'
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$source = Get-Content -LiteralPath $scriptPath -Raw
$functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($definition in $functions) { Invoke-Expression $definition.Extent.Text }

function Assert-Equal($Actual, $Expected, $Name) {
    if ($Actual -ne $Expected) { throw "${Name}: expected '$Expected', got '$Actual'" }
}

$cases = @(
    @('192.168.1.200', 25, '192.168.1.129', '192.168.1.254', 126),
    @('192.168.1.200', 23, '192.168.0.1', '192.168.1.254', 510),
    @('10.2.3.200', 16, '10.2.0.1', '10.2.255.254', 65534),
    @('192.168.1.200', 31, '192.168.1.200', '192.168.1.201', 2),
    @('255.255.255.255', 32, '255.255.255.255', '255.255.255.255', 1)
)
foreach ($case in $cases) {
    $range = Get-CidrRange $case[0] $case[1]
    Assert-Equal (ConvertTo-IPv4 $range.First) $case[2] 'first host'
    Assert-Equal (ConvertTo-IPv4 $range.Last) $case[3] 'last host'
    Assert-Equal ($range.Last - $range.First + 1) $case[4] 'host count'
}
foreach ($case in @(@('999.1.2.3', 24), @('1.2.3.4', 15), @('1.2.3.4', 33))) {
    $rejected = $false
    try { Get-CidrRange $case[0] $case[1] | Out-Null } catch { $rejected = $true }
    Assert-Equal $rejected $true 'reject invalid subnet'
}
Write-Host 'PASS: parser and subnet boundary checks'

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('wiz-ps-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir | Out-Null
try {
    $probeDefinition = $functions | Where-Object { $_.Name -eq 'Get-RespondingHosts' }
    $mockedSource = $source.Replace($probeDefinition.Extent.Text, @'
function Get-RespondingHosts {
    param($Range)
    if ($env:WIZ_TEST_PROBE_FAIL -eq '1') { throw 'test probe failure' }
    Write-Host ('TEST_RANGE {0} {1}' -f (ConvertTo-IPv4 $Range.First), (ConvertTo-IPv4 $Range.Last))
}
'@)
    $testInstaller = Join-Path $tempDir 'installer.ps1'
    Set-Content -LiteralPath $testInstaller -Value $mockedSource -Encoding UTF8
    $payload = Join-Path $tempDir 'payload.sh'
    Set-Content -LiteralPath $payload -Value '#!/bin/sh' -Encoding ASCII
    $wrapper = Join-Path $tempDir 'wrapper.ps1'
    $prelude = @'
param([string]$Scenario, [string]$Installer, [string]$Payload)
$ErrorActionPreference = 'Stop'
function Read-Host { 'discover' }
function Get-NetRoute {
    if ($Scenario -eq 'route-failure') { throw 'test route failure' }
    [pscustomobject]@{ RouteMetric = 0; InterfaceIndex = 7 }
}
function Get-NetIPAddress { [pscustomobject]@{ IPAddress = '192.168.1.200'; PrefixLength = 25 } }
function scp.exe { Write-Host 'MOCK_SCP'; $global:LASTEXITCODE = 0 }
function ssh.exe {
    Write-Host 'MOCK_SSH'
    if ($Scenario -eq 'remote-failure') { $global:LASTEXITCODE = 23 }
    else { $global:LASTEXITCODE = 0 }
}
function Invoke-WebRequest { throw 'test download failure' }
function Get-Command {
    param([string]$Name, [string]$ErrorAction)
    if ($Scenario -eq 'missing-ssh' -and $Name -eq 'ssh.exe') { throw 'test missing SSH command' }
    Microsoft.PowerShell.Core\Get-Command $Name -ErrorAction Stop
}
if ($Scenario -eq 'probe-failure') { $env:WIZ_TEST_PROBE_FAIL = '1' }
switch ($Scenario) {
    'prompt-discover' { & $Installer }
    'route-failure' { & $Installer discover }
    'probe-failure' { & $Installer discover }
    'invalid-action' { & $Installer instal }
    'download-failure' { & $Installer install 192.0.2.1 }
    'missing-ssh' { & $Installer install 192.0.2.1 -PayloadPath $Payload }
    'remote-failure' { & $Installer install 192.0.2.1 -PayloadPath $Payload }
    'success' { & $Installer install 192.0.2.1 -PayloadPath $Payload }
}
exit $LASTEXITCODE
'@
    Set-Content -LiteralPath $wrapper -Value $prelude -Encoding UTF8
    foreach ($scenario in @('prompt-discover', 'route-failure', 'probe-failure', 'invalid-action', 'download-failure', 'missing-ssh', 'remote-failure', 'success')) {
        $ErrorActionPreference = 'Continue'
        $output = & $PowerShellPath -NoProfile -File $wrapper $scenario $testInstaller $payload 2>&1
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        $text = $output | Out-String
        if ($scenario -in @('prompt-discover', 'success')) { Assert-Equal $code 0 $scenario }
        elseif ($code -eq 0) { throw "${scenario}: failure was reported as success" }
        if ($scenario -eq 'prompt-discover') {
            if ($text -notmatch 'TEST_RANGE 192.168.1.129 192.168.1.254') { throw "Wrong discovery range/dispatch: $text" }
        }
        if ($scenario -in @('prompt-discover', 'route-failure', 'probe-failure', 'invalid-action', 'download-failure', 'missing-ssh')) {
            if ($text -match 'MOCK_SSH|MOCK_SCP') { throw "${scenario}: unexpected transfer/execution" }
        }
        Write-Host "PASS: $scenario"
    }
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force
}
