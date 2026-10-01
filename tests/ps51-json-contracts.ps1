#!/usr/bin/env pwsh
# ps51-json-contracts.ps1 - the --json contracts of the Windows CLI, run under
# WINDOWS POWERSHELL 5.1 as well as pwsh (.github/workflows/windows-ps51.yml).
#
# Every bug this pins escaped a suite that only ever ran under pwsh on Linux:
# ConvertFrom-Json handing an array back as ONE object (rows wrapped as
# {"value": [...], "Count": n}), a one-element array written as a bare string,
# a `return 0` after the payload, JSON swallowed by an `if (-not (...))` caller,
# a UTF-8 BOM on settings.json, and a crashed install reading as "installing"
# forever. The shim (exakit.cmd) runs powershell.exe, so 5.1 IS the engine every
# Windows agent gets.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/ps51-json-contracts.ps1
#   pwsh -NoProfile -File tests/ps51-json-contracts.ps1
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0
$script:FAIL = 0
function Pass($label) { $script:PASS++; Write-Host "  ok   $label" }
function Miss($label, $detail) { $script:FAIL++; Write-Host "  FAIL $label -- $detail" }
function Check($label, $condition, $detail) { if ($condition) { Pass $label } else { Miss $label "$detail" } }
function Head($text, $n) { $t = "$text".Trim(); if ($t.Length -gt $n) { return $t.Substring(0, $n) }; return $t }

$engine = (Get-Process -Id $PID).Path
Write-Host "engine: $engine ($($PSVersionTable.PSVersion))"

# A sandboxed kit home. No manifest -> the not-installed answers; the checkout
# stands in for the kit copy (the repo-root lookup falls back to it).
$kitHome = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-ps51-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $kitHome | Out-Null
$env:EXAKIT_HOME = $kitHome
$env:EXAKIT_NO_UPDATE_NOTICE = "1"
$env:EXAKIT_VERSION_POLICY = "pinned"
$cli = Join-Path $repo "setup\exakit.ps1"

function Run-Cli {
    param([string[]]$CliArgs)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        # -Width for the same reason as the legacy suite's Screen: a folded
        # capture is a capture of the terminal, and this one is parsed as JSON.
        $text = (& $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $cli @CliArgs 2>$null | Out-String -Width 4096)
        return @{ Out = $text; Code = $LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $previous
    }
}
function Parse-Json($label, $text) {
    try { return ("$text" | ConvertFrom-Json) } catch {
        Miss "$label is one valid JSON object" ("parse error: " + $_.Exception.Message + " :: " + (Head $text 160))
        return $null
    }
}

# --- 1. the not-installed answers: one shape, exit 4 ------------------------
Write-Host "--- not installed"
foreach ($case in @(
    @{ Args = @("status", "--json");     Label = "status --json" },
    @{ Args = @("info", "--json");       Label = "info --json" },
    @{ Args = @("mcp-doctor", "--json"); Label = "mcp-doctor --json" },
    @{ Args = @("version", "--json");    Label = "version --json" }
)) {
    $r = Run-Cli $case.Args
    Check "$($case.Label) (not installed) exits 4" ($r.Code -eq 4) "exit $($r.Code): $(Head $r.Out 120)"
    $doc = Parse-Json "$($case.Label) (not installed)" $r.Out
    if ($doc) {
        Check "$($case.Label) (not installed) says installed=false" ($doc.installed -eq $false) "installed=$($doc.installed)"
        Check "$($case.Label) (not installed) carries status and remedy" ($doc.PSObject.Properties["status"] -and $doc.PSObject.Properties["remedy"]) (Head $r.Out 160)
    }
}

# --- 2. the catalog and skills are one object each, nothing else on stdout --
Write-Host "--- catalog, help, skills"
$r = Run-Cli @("catalog", "--json")
Check "catalog --json exits 0" ($r.Code -eq 0) "exit $($r.Code)"
$doc = Parse-Json "catalog --json" $r.Out
if ($doc) { Check "catalog --json lists the commands" (@($doc.commands).Count -gt 10) "count $(@($doc.commands).Count)" }
$r = Run-Cli @("help", "sql", "--json")
$doc = Parse-Json "help sql --json" $r.Out
if ($doc) { Check "help sql --json finds the sql command" (@($doc.commands | Where-Object { $_.command -eq "sql" }).Count -ge 1) (Head $r.Out 120) }
$r = Run-Cli @("skills", "--json")
Check "skills --json exits 0" ($r.Code -eq 0) "exit $($r.Code)"
$doc = Parse-Json "skills --json" $r.Out
if ($doc) { Check "skills --json lists the kit's skills" (@($doc.skills).Count -ge 5) "count $(@($doc.skills).Count): $(Head $r.Out 120)" }

# --- 3. the library, dot-sourced: the helpers behind the shapes -------------
Write-Host "--- library"
. (Join-Path $repo "setup\lib\exakit-common.ps1")

$rows = @(ConvertFrom-ExakitJsonRows -Text '[{"a":1},{"a":2}]')
$json = ([ordered]@{ rows = $rows } | ConvertTo-Json -Compress)
Check "rows: a two-row result is a plain array" ($json -eq '{"rows":[{"a":1},{"a":2}]}') $json
$rows = @(ConvertFrom-ExakitJsonRows -Text '[{"a":1}]')
$json = ([ordered]@{ rows = $rows } | ConvertTo-Json -Compress)
Check "rows: a one-row result is still an array" ($json -eq '{"rows":[{"a":1}]}') $json
$rows = @(ConvertFrom-ExakitJsonRows -Text '[]')
$json = ([ordered]@{ rows = $rows } | ConvertTo-Json -Compress)
Check "rows: an empty result is an empty array" ($json -eq '{"rows":[]}') $json

$remedy = @(Get-ExakitDbErrorRemedy -Text "exapump.exe : Error: Failed to connect to 127.0.0.1:8564: Network I/O error: No connection could be made because the target machine actively refused it. (os error 10061)") -join " "
Check "remedy: the Windows refused-socket text names exakit start" ($remedy -match "exakit start") $remedy
$remedy = @(Get-ExakitDbErrorRemedy -Text "Connection refused") -join " "
Check "remedy: 'Connection refused' still names exakit start" ($remedy -match "exakit start") $remedy
$remedy = @(Get-ExakitDbErrorRemedy -Text "syntax error, unexpected FETCH_, expecting UNION_") -join " "
Check "remedy: FETCH FIRST names LIMIT" ($remedy -match "LIMIT") $remedy

Check "allowlist: a legacy update-check rule is recognised" (Test-ExakitLegacyAllowlistRule 'Bash(exakit update-check:*)') "returned false"
Check "allowlist: a legacy .cmd mcp-validate rule is recognised" (Test-ExakitLegacyAllowlistRule 'Bash(~/.local/bin/exakit.cmd mcp-validate:*)') "returned false"
Check "allowlist: a current rule is kept" (-not (Test-ExakitLegacyAllowlistRule 'Bash(exakit status:*)')) "returned true"

$settings = Join-Path $kitHome "settings.json"
Write-ExakitSettingsJson -Path $settings -Doc ([pscustomobject]@{ permissions = [pscustomobject]@{ allow = @("Bash(exakit status:*)") } })
$bytes = [System.IO.File]::ReadAllBytes($settings)
$bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
Check "settings.json is written without a UTF-8 BOM" (-not $bom) ("first bytes " + (($bytes[0..2] | ForEach-Object { $_.ToString("X2") }) -join " "))
$settingsText = Get-Content -Raw -Path $settings
Check "settings.json keeps a one-rule allow list as an array" ($settingsText -match '"allow":\s*\[') (Head $settingsText 120)

Set-Content -Path $script:InstallLockPath -Value "999999"
Check "install lock: a dead pid is not installing" (-not (Test-ExakitInstallRunning)) "reported running"
Set-Content -Path $script:InstallLockPath -Value "$PID"
Check "install lock: a live pid is installing" (Test-ExakitInstallRunning) "reported not running"
Remove-Item -Path $script:InstallLockPath -Force

# --- 4. the manifest round trip, then the CLI on that manifest --------------
Write-Host "--- installed, no runtime"
Initialize-ExakitManifest
Set-ExakitStepDone "launcher"
$manifestText = Get-Content -Raw -Path $script:ManifestPath
Check "manifest: the first step tick is an array on disk" ($manifestText -match '"steps_completed":\s*\[') (Head $manifestText 200)

$r = Run-Cli @("status", "--json")
$doc = Parse-Json "status --json (manifest, no runtime)" $r.Out
Check "status --json (no runtime) exits 3" ($r.Code -eq 3) "exit $($r.Code): $(Head $r.Out 120)"
if ($doc) {
    Check "status --json: not installing without a lock" ($doc.installing -eq $false -and $doc.status -ne "installing") "status=$($doc.status) installing=$($doc.installing)"
    Check "status --json: steps_completed is an array" ($doc.steps_completed -is [array]) "type $($doc.steps_completed.GetType().Name)"
    Check "status --json: carries datasets_source" ([bool]$doc.PSObject.Properties["datasets_source"]) "missing"
}

Set-ExakitManifestValue "install.current_step" "runtime"
$r = Run-Cli @("status", "--json")
$doc = Parse-Json "status --json (crashed install)" $r.Out
if ($doc) {
    Check "status --json: a dead install is not 'installing'" ($doc.installing -eq $false -and $doc.status -ne "installing") "status=$($doc.status) installing=$($doc.installing)"
    # `remedy` is a RUNNABLE command and prose lives in `remedy_hint`, so the
    # dead-install remedy is the installer invocation, not the sentence it used
    # to be. Both halves are asserted: the command in remedies.install, the
    # explanation in remedy_hints.install.
    Check "status --json: a dead install names the runnable re-run" ("$($doc.remedies.install)" -match "iex") "remedies.install=$($doc.remedies.install)"
    Check "status --json: the prose moved to remedy_hints" ("$($doc.remedy_hints.install)" -match "resumes|re-runn?ing") "remedy_hints.install=$($doc.remedy_hints.install)"
    Check "status --json: a dead install still reports install_step" ($doc.install_step -eq "runtime") "install_step=$($doc.install_step)"
}

Set-Content -Path $script:InstallLockPath -Value "$PID"
$r = Run-Cli @("status", "--json")
$doc = Parse-Json "status --json (live install)" $r.Out
if ($doc) { Check "status --json: a live installer reads as installing, exit 3" ($doc.status -eq "installing" -and $r.Code -eq 3) "status=$($doc.status) exit=$($r.Code)" }
$r = Run-Cli @("info", "--json")
$doc = Parse-Json "info --json (live install)" $r.Out
if ($doc) {
    Check "info --json agrees: installing, exit 3" ($doc.status -eq "installing" -and $r.Code -eq 3) "status=$($doc.status) exit=$($r.Code)"
    Check "info --json: steps_completed is an array" ($doc.steps_completed -is [array]) "type $($doc.steps_completed.GetType().Name)"
}
$r = Run-Cli @("mcp-doctor", "--json")
$doc = Parse-Json "mcp-doctor --json (live install)" $r.Out
if ($doc) { Check "mcp-doctor --json agrees: installing, installed, exit 3" ($doc.status -eq "installing" -and $doc.installed -eq $true -and $r.Code -eq 3) "status=$($doc.status) installed=$($doc.installed) exit=$($r.Code)" }
Remove-Item -Path $script:InstallLockPath -Force

# --- a checksum does not depend on a cmdlet that may not load ----------------
# Get-FileHash arrives through module auto-loading, which is not guaranteed on
# a managed machine: with a OneDrive-redirected Documents folder at the head of
# $env:PSModulePath, an `exakit update` died with "The term 'Get-FileHash' is
# not recognized" - after downloading the binary, at the moment it was about to
# be verified. The .NET fallback must give the same answer, byte for byte.
$probe = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-hash-" + [guid]::NewGuid().ToString("N") + ".bin")
[System.IO.File]::WriteAllBytes($probe, [byte[]](1..255))
$viaCmdlet = Get-ExakitSha256 $probe
# Shadowing the lookup the helper uses is what a machine whose module never
# loads looks like from inside the function.
function Get-Command { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) return $null }
$viaFallback = Get-ExakitSha256 $probe
Remove-Item -Force $probe -ErrorAction SilentlyContinue
Check "the digest is a sha256" ($viaCmdlet -match '^[0-9a-f]{64}$') "got $viaCmdlet"
Check "and the fallback agrees with the cmdlet" ($viaFallback -eq $viaCmdlet) "cmdlet=$viaCmdlet fallback=$viaFallback"

Remove-Item -Recurse -Force -Path $kitHome -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "$($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
exit 0
