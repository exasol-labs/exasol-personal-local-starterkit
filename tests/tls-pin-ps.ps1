#!/usr/bin/env pwsh
# tls-pin-ps.ps1 - the Windows twin of tests/tls-pin.sh: the database's TLS
# certificate pin (audit SEC-14) in setup/lib/exakit-common.ps1, exapump.ps1
# and setup/exakit.ps1. Runs under Windows PowerShell 5.1 and pwsh.
#
#   pwsh -NoProfile -File tests/tls-pin-ps.ps1
#
# What it pins: trust on first use (Register-ExakitTlsPin records only when
# nothing is recorded, -Replace for a deployment the kit just made,
# Confirm-ExakitTlsPinned only while the kit's database is running); the
# exapump profile and the pinned DSN, pinned and unpinned; the client rewrite
# after a pin; `exakit status --json`'s tls object and the TLS row; and
# `exakit tls-pin` (exit 0 / 6 / 3 / 5 / 2, --accept --yes re-pins and
# rewrites). Invoke-CmdStatus and Invoke-CmdTlsPin end with `exit`, so they
# run in a child PowerShell lifted out of exakit.ps1 over stubs.
#
# A sandboxed kit home; no database: the "database port" is a local TLS server
# (tests/lib/tls_server.py, needs python3 and openssl). The password file
# holds a dummy value and is never printed.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$expected>, got <$actual>" }
}
function Has($label, $needle, $haystack) {
    if ("$haystack".Contains($needle)) { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): <$needle> not in <$haystack>" }
}
function Lacks($label, $needle, $haystack) {
    if (-not "$haystack".Contains($needle)) { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): did not expect <$needle> in <$haystack>" }
}

$py = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
if (-not $py -or -not (Get-Command openssl -ErrorAction SilentlyContinue)) {
    Write-Host "SKIP tls-pin-ps.ps1: needs python3 and openssl"
    exit 0
}
$script:Py = $py.Source
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-tlspin-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$server = Join-Path $repo "tests/lib/tls_server.py"
$certs = Join-Path $work "certs"
$fp1 = (& $script:Py $server cert $certs one).Trim()
$fp2 = (& $script:Py $server cert $certs two).Trim()
$procs = @()
function Start-TlsServer([string]$Name) {
    $portFile = Join-Path $work "port.$Name"
    $p = Start-Process -FilePath $script:Py -PassThru -NoNewWindow -ArgumentList @(
        "`"$server`"", "serve", "`"$(Join-Path $certs "$Name.pem")`"", "`"$(Join-Path $certs "$Name.key")`"", "`"$portFile`"")
    $script:procs += $p
    for ($i = 0; $i -lt 50 -and -not (Test-Path $portFile); $i++) { Start-Sleep -Milliseconds 100 }
    return [int](Get-Content $portFile -Raw)
}
$port1 = Start-TlsServer "one"
$port2 = Start-TlsServer "two"
$probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$probe.Start(); $closed = $probe.LocalEndpoint.Port; $probe.Stop()

$env:EXAKIT_HOME = Join-Path $work "kit"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
New-Item -ItemType Directory -Force -Path (Join-Path $env:EXAKIT_HOME "credentials") | Out-Null
$pwFile = Join-Path $env:EXAKIT_HOME "credentials/personal_sys_password"
Set-Content -Path $pwFile -Value "dummy-test-value" -NoNewline

try {
    . (Join-Path $repo "setup/lib/exakit-common.ps1")
    . (Join-Path $repo "setup/lib/exapump.ps1")
    $script:LogFile = $null
    $script:ExapumpConfigPath = Join-Path $work "exapump/config.toml"
    # The interpreter: this machine's python3 stands in for the kit's.
    function Test-ExakitSystemPython { return $true }
    function python { & $script:Py @args }
    function Write-ManifestDoc([int]$Port, [string]$Fp = "") {
        $runtime = [ordered]@{ type = "personal"; dsn = "127.0.0.1:$Port"; user = "sys"; password_file = $pwFile }
        if ($Fp) { $runtime.tls_fingerprint = $Fp; $runtime.tls_fingerprint_at = "2026-01-01T00:00:00Z" }
        $doc = [ordered]@{ kit_level = 1; runtime = $runtime
            steps_completed = @("launcher", "runtime", "exapump", "mcp", "pyexasol", "exakit_helper")
            components = [ordered]@{ exapump = @{ profile = "starter-kit" }; mcp_server = @{ validated = $true } } }
        [System.IO.File]::WriteAllText($script:ManifestPath, ($doc | ConvertTo-Json -Depth 6))
    }

    Write-Host "the library (exakit-common.ps1, exapump.ps1):"
    Write-ManifestDoc $port1
    Check "unpinned: the DSN is unchanged" "127.0.0.1:$port1" (Get-ExakitPinnedDsn)
    Check "unpinned: nothing is recorded" "" (Get-ExakitTlsFingerprint)
    Check "the live fingerprint is the certificate's" $fp1 (Get-ExakitTlsLiveFingerprint -DbHost "127.0.0.1" -Port "$port1" -TimeoutSeconds 5)
    Check "a port that does not answer TLS gives nothing" "" (Get-ExakitTlsLiveFingerprint -DbHost "127.0.0.1" -Port "$closed" -TimeoutSeconds 2)

    New-ExapumpProfile *> $null
    $toml = Get-Content $script:ExapumpConfigPath -Raw
    Lacks "an unpinned exapump profile has no certificate_fingerprint" "certificate_fingerprint" $toml
    Has "...and keeps the old TLS posture" "validate_certificate = false" $toml

    Check "first use records the live certificate" $true (Register-ExakitTlsPin)
    Check "...the recorded value" $fp1 (Get-ExakitManifestValue "runtime.tls_fingerprint")
    Check "...and when, as UTC ISO 8601 on 5.1 and pwsh alike" $true ((Get-ExakitTlsPinnedAt) -match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')
    Check "pinned: the DSN carries the pin (pyexasol form)" "127.0.0.1/${fp1}:$port1" (Get-ExakitPinnedDsn)
    Check "...for any DSN handed in" "127.0.0.1/${fp1}:9" (Get-ExakitPinnedDsn "127.0.0.1:9")

    Set-ExakitManifestValue "runtime.dsn" "127.0.0.1:$port2"
    Check "a recorded pin is never silently replaced" $false (Register-ExakitTlsPin)
    Check "...it stays" $fp1 (Get-ExakitTlsFingerprint)
    function Get-RuntimeType { return "personal" }
    function Test-PersonalDeploymentRunning { return $true }
    Confirm-ExakitTlsPinned *> $null
    Check "the lazy record leaves a recorded pin alone" $fp1 (Get-ExakitTlsFingerprint)
    Check "-Replace (a deployment the kit just made) records the new one" $true (Register-ExakitTlsPin -Replace)
    Check "...the new value" $fp2 (Get-ExakitTlsFingerprint)

    Set-ExakitManifestValue "runtime.tls_fingerprint" $fp2.ToUpperInvariant()
    Check "an uppercase record is not a pin (exapump compares lowercase)" "127.0.0.1:9" (Get-ExakitPinnedDsn "127.0.0.1:9")
    Set-ExakitManifestValue "runtime.tls_fingerprint" "not-a-fingerprint"
    Check "a malformed record is not a pin" "127.0.0.1:9" (Get-ExakitPinnedDsn "127.0.0.1:9")

    Remove-ExakitManifestValue "runtime.tls_fingerprint"
    Set-ExakitManifestValue "runtime.dsn" "127.0.0.1:$port1"
    function Test-PersonalDeploymentRunning { return $false }
    Confirm-ExakitTlsPinned *> $null
    Check "the lazy record waits for the kit's own database to be running" "" (Get-ExakitTlsFingerprint)
    function Test-PersonalDeploymentRunning { return $true }
    $script:Rewrites = @()
    function Update-McpClients { $script:Rewrites += "mcp"; return $true }
    Confirm-ExakitTlsPinned *> $null
    Check "the lazy record pins an install that predates the pin" $fp1 (Get-ExakitTlsFingerprint)
    Check "...and leaves the MCP entries alone (they name the server beside the database, no DSN)" "" ($script:Rewrites -join " ")
    $toml = Get-Content $script:ExapumpConfigPath -Raw
    Has "...and the exapump profile, carrying the pin lowercase" "certificate_fingerprint = `"$fp1`"" $toml
    Check "...once" 1 ([regex]::Matches($toml, "certificate_fingerprint").Count)
    $script:Rewrites = @()
    Update-ExakitTlsPinnedClients -ProfileOnly *> $null
    Check "-ProfileOnly leaves the MCP entries alone" "" ($script:Rewrites -join " ")
    Set-ExakitManifestValue "components.mcp_server.backend" "sidecar"
    Update-ExakitTlsPinnedClients *> $null
    Check "the launcher's sidecar entries hold no DSN and are left alone" "" ($script:Rewrites -join " ")

    $temp = Join-Path $work "temp.toml"
    Set-ExapumpTomlSection -ConfigPath $temp -Profile "admin" -Host_ "127.0.0.1" -Port "$port1" -User "sys" -Password "dummy-a" -Fingerprint (Get-ExakitTlsFingerprint)
    Set-ExapumpTomlSection -ConfigPath $temp -Profile "mcp_readonly" -Host_ "127.0.0.1" -Port "$port1" -User "mcp_readonly" -Password "dummy-b" -Schema "STARTER_KIT" -Fingerprint (Get-ExakitTlsFingerprint)
    Check "the MCP step's admin and read-only profiles are both pinned" 2 ([regex]::Matches((Get-Content $temp -Raw), "certificate_fingerprint = `"$fp1`"").Count)
    $temp2 = Join-Path $work "temp2.toml"
    Set-ExapumpTomlSection -ConfigPath $temp2 -Profile "legacy" -Host_ "127.0.0.1" -Port "8564" -User "sys" -Password "dummy-c"
    Lacks "a profile without -Fingerprint (the legacy crossing's) is unpinned" "certificate_fingerprint" (Get-Content $temp2 -Raw)

    # --- the CLI functions, in a child PowerShell -----------------------------
    Write-Host ""
    Write-Host "the CLI (Invoke-CmdStatus, Invoke-CmdTlsPin, lifted out of exakit.ps1):"
    $driver = Join-Path $work "driver.ps1"
    $driverText = @'
param([string]$Repo, [string]$Py, [string]$Mode, [string]$Rewrites)
$ErrorActionPreference = "Stop"
. (Join-Path $Repo "setup/lib/exakit-common.ps1")
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo "setup/exakit.ps1"), [ref]$tokens, [ref]$errors)
$wanted = @("Invoke-CmdStatus", "Invoke-CmdTlsPin", "Assert-ExakitInstalled", "Get-ExakitPlatformName", "Write-ExakitNotInstalledAnswer")
foreach ($d in @($ast.FindAll({ param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($wanted -contains $n.Name) }, $true))) {
    . ([scriptblock]::Create($d.Extent.Text))
}
$script:LogFile = $null
function Test-ExakitSystemPython { return $true }
function python { & $Py @args }
function Get-PersonalStatus { return "running" }
function Get-PersonalLauncherState { return "running" }
function Test-ExakitInstallRunning { return $false }
function Get-ExakitLoadedDatasets { return @() }
function Get-ExakitServiceIds { return @() }
function Test-ExakitAutostartAll { return $false }
function Get-ExakitMarketplaceAddons { return @() }
function Test-ExakitLegacyRuntimeRecorded { return $false }
function Get-McpConfiguredClients { return @() }
function Initialize-ExakitLogging { }
function New-ExapumpProfile { Add-Content -Path $Rewrites -Value "profile" }
function Update-McpClients { Add-Content -Path $Rewrites -Value "mcp"; return $true }
$script:PendingExitCode = 0
switch ($Mode) {
    "status-json"     { Invoke-CmdStatus -Json }
    "status"          { Invoke-CmdStatus }
    "tls-pin"         { Invoke-CmdTlsPin }
    "tls-pin-json"    { Invoke-CmdTlsPin -Json }
    "accept"          { Invoke-CmdTlsPin -Accept }
    "accept-json"     { Invoke-CmdTlsPin -Accept -Json }
    "accept-yes-json" { Invoke-CmdTlsPin -Accept -Yes -Json }
    "yes-alone"       { Invoke-CmdTlsPin -Yes }
}
exit $script:PendingExitCode
'@
    [System.IO.File]::WriteAllText($driver, $driverText)
    $rewrites = Join-Path $work "rewrites"
    $pwshExe = (Get-Process -Id $PID).Path
    function Invoke-Driver([string]$Mode) {
        Set-Content -Path $rewrites -Value "" -NoNewline
        $previous = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $out = & $pwshExe -NoProfile -NonInteractive -File $driver -Repo $repo -Py $script:Py -Mode $Mode -Rewrites $rewrites 2>&1
            $script:CODE = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previous }
        $script:OUT = (@($out) | ForEach-Object { "$_" }) -join "`n"
        return $script:OUT
    }
    function Get-JsonPart([string]$Text) {
        $start = $Text.IndexOf("{")
        if ($start -lt 0) { return $null }
        return ($Text.Substring($start) | ConvertFrom-Json)
    }

    Write-ManifestDoc $port1 $fp1
    $j = Get-JsonPart (Invoke-Driver "status-json")
    Check "status --json: pinned and matching" "True True" "$($j.tls.pinned) $($j.tls.matches)"
    Check "...and no tls remedy" "" "$($j.remedies.tls)"
    Write-ManifestDoc $port2 $fp1
    $j = Get-JsonPart (Invoke-Driver "status-json")
    Check "status --json: a changed certificate is matches: false" "True False" "$($j.tls.pinned) $($j.tls.matches)"
    Check "...its remedy SHOWS the two values (changes nothing)" "exakit tls-pin" "$($j.remedies.tls)"
    Has "...and the hint names both causes" "outside the kit" "$($j.remedy_hints.tls)"
    Has "status: the TLS row says the certificate changed" "certificate CHANGED" (Invoke-Driver "status")
    Write-ManifestDoc $closed $fp1
    $j = Get-JsonPart (Invoke-Driver "status-json")
    Check "status --json: nothing answering TLS is matches: null" "True " "$($j.tls.pinned) $($j.tls.matches)"
    Write-ManifestDoc $port1
    $j = Get-JsonPart (Invoke-Driver "status-json")
    Check "status --json: nothing recorded is pinned: false" "False " "$($j.tls.pinned) $($j.tls.matches)"

    Write-ManifestDoc $port1 $fp1
    $o = Invoke-Driver "tls-pin"
    Check "tls-pin: pinned and matching exits 0" 0 $script:CODE
    Has "...and says so" "serves the pinned certificate" $o
    $j = Get-JsonPart (Invoke-Driver "tls-pin-json")
    Check "tls-pin --json: status, matches, both values, changed" "pinned True $fp1 $fp1 False" "$($j.status) $($j.matches) $($j.fingerprint) $($j.live) $($j.changed)"
    # Read off the raw text: this test's own ConvertFrom-Json (pwsh 7) would turn the timestamp into a [datetime].
    Has "...recorded_at as written (UTC ISO 8601)" '"recorded_at": "2026-01-01T00:00:00Z"' $script:OUT
    Write-ManifestDoc $port2 $fp1
    $o = Invoke-Driver "tls-pin"
    Check "tls-pin: a changed certificate exits 6" 6 $script:CODE
    Has "...and shows the live one" $fp2 $o
    Invoke-Driver "accept" | Out-Null
    Check "tls-pin --accept without a console is not confirmed: exit 5" 5 $script:CODE
    $j = Get-JsonPart (Invoke-Driver "accept-json")
    Check "tls-pin --accept --json never prompts: declined, exit 5" "declined 5" "$($j.status) $($script:CODE)"
    Check "...nothing changed, nothing rewritten" "$fp1|" "$(Get-ExakitTlsFingerprint)|$((Get-Content $rewrites -Raw))"
    Invoke-Driver "yes-alone" | Out-Null
    Check "tls-pin --yes alone is bad input" $true ($script:CODE -ne 0)
    $j = Get-JsonPart (Invoke-Driver "accept-yes-json")
    Check "tls-pin --accept --yes re-pins: exit 0" 0 $script:CODE
    Check "...records the live certificate" $fp2 (Get-ExakitTlsFingerprint)
    Check "...answers changed, matching" "True True pinned" "$($j.changed) $($j.matches) $($j.status)"
    Check "...and rewrote the exapump profile (the MCP entries hold no DSN)" "profile" ((Get-Content $rewrites | Where-Object { $_ }) -join " ")
    Write-ManifestDoc $closed $fp1
    Invoke-Driver "tls-pin" | Out-Null
    Check "tls-pin with nothing answering TLS exits 3" 3 $script:CODE
} finally {
    foreach ($p in $procs) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { } }
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "$($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
exit 0
