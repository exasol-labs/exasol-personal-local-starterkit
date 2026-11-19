# windows-autostart-default-ps.ps1 - a fresh Windows install turns automatic
# start ON (Startup entry + autostart.enabled = true), and an earlier
# `exakit autostart off` (marked autostart.user_set) is never overridden. An
# unmarked false - what kit 0.2.0-0.2.3 wrote on every Windows install - is no
# answer, and nothing is written when there is nothing to register yet. Twin
# of exakit_autostart_default_on.
#
#   pwsh -NoProfile -NonInteractive -File tests/windows-autostart-default-ps.ps1
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0; $script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label = $actual" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected [$expected], got [$actual]" }
}
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-autostart-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:EXAKIT_HOME = Join-Path $work "home"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
New-Item -ItemType Directory -Force -Path $env:EXAKIT_HOME | Out-Null
. (Join-Path $repo "setup/lib/exakit-common.ps1")
# The Startup folder and the launcher are redirected into the sandbox.
$startup = Join-Path $work "Startup"
function Get-ExakitStartupDir { return $startup }
function Get-PersonalCli { return (Join-Path $work "bin\exasol.exe") }

function Reset([string]$json) { Set-Content -Path (Join-Path $env:EXAKIT_HOME "manifest.json") -Encoding Ascii -Value $json; Remove-Item -Recurse -Force $startup -ErrorAction SilentlyContinue }
$entry = Join-Path $startup "com.exasol.exakit.database.cmd"

Write-Host "fresh install: autostart is turned on"
Reset '{"manifest_version": 1, "runtime": {"type": "personal"}}'
Enable-ExakitAutostartDefault
Check "autostart.enabled"        "True" ("" + (Get-ExakitManifestValue "autostart.enabled"))
Check "Startup entry written"    "True" ("" + (Test-Path $entry))
# OSX-03 / LIN-01 on Windows: the kit's own start, which repairs the language
# containers' DNS, not the bare launcher, which never did.
Check "  it runs the kit's start for the database" "True" ("" + ((Get-Content $entry -Raw) -match 'kit[\\/]setup[\\/]exakit\.ps1" start database'))
Check "  not the bare launcher" "False" ("" + ((Get-Content $entry -Raw) -match 'exasol\.exe" start'))
Check "  minimised, through powershell (a .cmd would leave cmd /K open)" "True" ("" + ((Get-Content $entry -Raw) -match 'start "" /min powershell -NoProfile -ExecutionPolicy Bypass -File '))

Write-Host "exakit update rewrites a Startup entry an earlier kit wrote (Update-ExakitAutostartEntries)"
Reset '{"manifest_version": 1, "runtime": {"type": "personal"}, "autostart": {"enabled": true}}'
New-Item -ItemType Directory -Force -Path $startup | Out-Null
Set-Content -Path $entry -Value ("@echo off`r`nstart `"`" /min `"" + (Get-PersonalCli) + "`" start`r`n") -NoNewline
Update-ExakitAutostartEntries
Check "  the old entry now runs the kit's start" "True" ("" + ((Get-Content $entry -Raw).Contains('" start database')))
Check "  and no longer the bare launcher" "False" ("" + ((Get-Content $entry -Raw) -match 'exasol\.exe" start'))
$before = (Get-Item $entry).LastWriteTimeUtc
Start-Sleep -Milliseconds 1100
Update-ExakitAutostartEntries
Check "  a current entry is left as it is" "True" ("" + ((Get-Item $entry).LastWriteTimeUtc -eq $before))
Remove-Item -Force $entry
Update-ExakitAutostartEntries
Check "  no entry (autostart off) stays no entry" "False" ("" + (Test-Path $entry))
$cliText = Get-Content -Raw (Join-Path $repo "setup/exakit.ps1")
Check "  exakit update calls it" "True" ("" + $cliText.Contains('try { Update-ExakitAutostartEntries }'))

Write-Host "an earlier 'exakit autostart off' (user_set) is kept"
Reset '{"manifest_version": 1, "runtime": {"type": "personal"}, "autostart": {"enabled": false, "user_set": true}}'
Enable-ExakitAutostartDefault
Check "still off"                "False" ("" + (Get-ExakitManifestValue "autostart.enabled"))
Check "no Startup entry"         "False" ("" + (Test-Path $entry))

Write-Host "an unmarked off (kit 0.2.0-0.2.3, or a first install with no database) is re-defaulted"
Reset '{"manifest_version": 1, "runtime": {"type": "personal"}, "autostart": {"enabled": false}}'
Enable-ExakitAutostartDefault
Check "turned on"                "True" ("" + (Get-ExakitManifestValue "autostart.enabled"))
Check "Startup entry written"    "True" ("" + (Test-Path $entry))
Check "  and not marked as the user's" "" ("" + (Get-ExakitManifestValue "autostart.user_set"))

Write-Host "no runtime recorded: nothing to start, nothing written"
Reset '{"manifest_version": 1}'
Enable-ExakitAutostartDefault
Check "autostart.enabled unset"  "" ("" + (Get-ExakitManifestValue "autostart.enabled"))
Check "no Startup entry"         "False" ("" + (Test-Path $entry))

Write-Host "a refused first install, then a re-run that deployed the database: on"
Reset '{"manifest_version": 1}'
Enable-ExakitAutostartDefault
Set-ExakitManifestValue "runtime.type" "personal"
Enable-ExakitAutostartDefault
Check "turned on by the re-run"  "True" ("" + (Get-ExakitManifestValue "autostart.enabled"))
Check "Startup entry written"    "True" ("" + (Test-Path $entry))

Write-Host "the CLI's answer writes the marker (source check: exakit.ps1 is not loaded here)"
$cli = Get-Content -Raw (Join-Path $repo "setup/exakit.ps1")
$en = [regex]::Match($cli, '(?s)\r?\nfunction Enable-ExakitAutostart \{.*?\r?\n\}').Value
$dis = [regex]::Match($cli, '(?s)\r?\nfunction Disable-ExakitAutostart \{.*?\r?\n\}').Value
Check "Enable-ExakitAutostart marks user_set"  "True" ("" + $en.Contains('Set-ExakitManifestValue "autostart.user_set" $true'))
Check "Disable-ExakitAutostart marks user_set" "True" ("" + $dis.Contains('Set-ExakitManifestValue "autostart.user_set" $true'))

Write-Host "the install's closing line says the kit is connected to the AI clients (Get-ExakitReadyLineText)"
$ready = "Exasol starterkit is ready and connected to your AI clients. Ask them about your data."
Reset '{"manifest_version": 1, "components": {"mcp_server": {"client_setup": {"configured_clients": ["claude_desktop"]}}}}'
Check "one client: the connected sentence" $ready (Get-ExakitReadyLineText)
Reset '{"manifest_version": 1, "components": {"mcp_server": {"client_setup": {"configured_clients": ["codex", "claude_code", "vscode_copilot"]}}}}'
Check "three clients: the same sentence" $ready (Get-ExakitReadyLineText)
Reset '{"manifest_version": 1, "components": {"mcp_server": {"client_setup": {"configured_clients": ["claude_code", "claude_desktop", "codex", "cursor", "vscode_copilot", "gemini_cli"]}}}}'
Check "six clients: the same sentence" $ready (Get-ExakitReadyLineText)
Reset '{"manifest_version": 1, "components": {"mcp_server": {"client_setup": {"configured_clients": []}}}}'
Check "no client: the plain line" "Your starter kit is ready to use." (Get-ExakitReadyLineText)

# WNX-01: an add-on's hook (service.py autostart-command) answers its argv one
# item per line - Dash Server five, the Scheduler one. The entry writer took a
# [string], so five items threw a binding error (exakit autostart ended red, and
# exakit update stopped at Dash Server), and one item was written unquoted,
# which runs C:\Users\John for a profile folder with a space. Last section: it
# replaces the service registry with test add-ons.
Write-Host "an add-on's Startup entry: its argv as one quoted command line (WNX-01)"
$savedProfile = $env:USERPROFILE
$script:LogFile = Join-Path $work "exakit.log"
$script:TestIds = @()
$script:DashArgv = @()
$script:SchedArgv = @()
function Invoke-TestDashAutostart { $script:DashArgv }
function Invoke-TestSchedAutostart { $script:SchedArgv }
function Invoke-TestBrokenAutostart { throw "service.py autostart-command failed" }
function Get-ExakitServiceIds { return $script:TestIds }
function Get-ExakitMarketplaceAddon {
    param([string]$Id)
    $fn = @{ "dash-server" = "Invoke-TestDashAutostart"; "exasol-scheduler" = "Invoke-TestSchedAutostart"; "broken" = "Invoke-TestBrokenAutostart" }[$Id]
    if (-not $fn) { return $null }
    return [pscustomobject]@{ Id = $Id; AutostartFn = $fn }
}
$script:Warned = @()
function Warn2([string]$Msg) { $script:Warned += $Msg }
function RunLine([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return "(no entry)" }
    return [regex]::Match([System.IO.File]::ReadAllText($path), '(?m)^start "" /min .*$').Value.TrimEnd()
}
function TryRegister([string]$id) {
    try { return ("" + (Register-ExakitAutostart -Id $id)) } catch { return "threw: $_" }
}
$dashEntry = Join-Path $startup "com.exasol.exakit.dash-server.cmd"
$schedEntry = Join-Path $startup "com.exasol.exakit.exasol-scheduler.cmd"
$brokenEntry = Join-Path $startup "com.exasol.exakit.broken.cmd"

Reset '{"manifest_version": 1, "runtime": {"type": "personal"}, "autostart": {"enabled": true}}'
$env:USERPROFILE = "C:\Users\John Doe"
$script:DashArgv = @("C:\Users\John Doe\.exasol-starter-kit\marketplace\dash-server\bin\dash-server.exe", "--host", "127.0.0.1", "--port", "5100")
$script:SchedArgv = @("C:\Users\John Doe\.exasol-starter-kit\bin\exasol-scheduler.cmd")
$dashWant = 'start "" /min "%USERPROFILE%\.exasol-starter-kit\marketplace\dash-server\bin\dash-server.exe" "--host" "127.0.0.1" "--port" "5100"'
$schedWant = 'start "" /min "%USERPROFILE%\.exasol-starter-kit\bin\exasol-scheduler.cmd"'
Check "Dash Server (5 items): the entry is written" "True" (TryRegister "dash-server")
Check "  every item quoted, in order" $dashWant (RunLine $dashEntry)
Check "Scheduler (1 item) under a profile with a space: written" "True" (TryRegister "exasol-scheduler")
Check "  the path quoted (not C:\Users\John)" $schedWant (RunLine $schedEntry)

Write-Host "  a non-ASCII profile, and & % ( ) in a path"
$nonAscii = "C:\Users\Jos" + [char]0x00E9 + " M" + [char]0x00FC + "ller"
$env:USERPROFILE = $nonAscii
$script:SchedArgv = @("$nonAscii\.exasol-starter-kit\bin\exasol-scheduler.cmd", "D:\R&D (x86)\100%\jobs")
Check "non-ASCII profile: written" "True" (TryRegister "exasol-scheduler")
Check "  folded into %USERPROFILE%, specials kept as text" 'start "" /min "%USERPROFILE%\.exasol-starter-kit\bin\exasol-scheduler.cmd" "D:\R&D (x86)\100%%\jobs"' (RunLine $schedEntry)
$nonAsciiBytes = @([System.IO.File]::ReadAllBytes($schedEntry) | Where-Object { $_ -gt 127 }).Count
Check "  the entry's bytes are ASCII" "0" ("" + $nonAsciiBytes)

Write-Host "exakit update: one add-on failing does not skip the others (Update-ExakitAutostartEntries)"
Reset '{"manifest_version": 1, "runtime": {"type": "personal"}, "autostart": {"enabled": true}}'
$env:USERPROFILE = "C:\Users\John Doe"
$script:SchedArgv = @("C:\Users\John Doe\.exasol-starter-kit\bin\exasol-scheduler.cmd")
$script:TestIds = @("database", "dash-server", "broken", "exasol-scheduler")
New-Item -ItemType Directory -Force -Path $startup | Out-Null
[void](Register-ExakitAutostart -Id "database")
# Stale entries: Dash Server on an older port, a broken add-on, and the
# Scheduler line the regression wrote (unquoted).
Set-Content -Path $dashEntry -Value ("@echo off`r`nstart `"`" /min `"%USERPROFILE%\.exasol-starter-kit\marketplace\dash-server\bin\dash-server.exe`" `"--host`" `"127.0.0.1`" `"--port`" `"5099`"`r`n") -NoNewline
Set-Content -Path $brokenEntry -Value "@echo off`r`nstart `"`" /min `"old`"`r`n" -NoNewline
Set-Content -Path $schedEntry -Value "@echo off`r`nstart `"`" /min %USERPROFILE%\.exasol-starter-kit\bin\exasol-scheduler.cmd`r`n" -NoNewline
$script:Warned = @()
$threw = ""
try { Update-ExakitAutostartEntries } catch { $threw = "$_" }
Check "  the walk does not throw" "" $threw
Check "  Dash Server's entry is refreshed" $dashWant (RunLine $dashEntry)
Check "  the Scheduler's entry, after the failing add-on, is refreshed" $schedWant (RunLine $schedEntry)
Check "  the failing add-on's entry is left as it was" 'start "" /min "old"' (RunLine $brokenEntry)
Check "  the user is told which one failed" "True" ("" + (@($script:Warned | Where-Object { $_ -like "broken:*exakit autostart" }).Count -eq 1))
Check "  and only that one" "1" ("" + @($script:Warned).Count)
$logText = ""
if (Test-Path -LiteralPath $script:LogFile) { $logText = Get-Content -Raw -LiteralPath $script:LogFile }
Check "  the failure is logged with its reason" "True" ("" + $logText.Contains("broken: Startup entry refresh failed: service.py autostart-command failed"))

Write-Host "  an entry the add-on's own install wrote (no rem lines) is current"
$script:TestIds = @("exasol-scheduler")
Set-Content -Path $schedEntry -Value ("@echo off`r`n" + $schedWant + "`r`n") -NoNewline
$before = (Get-Item $schedEntry).LastWriteTimeUtc
Start-Sleep -Milliseconds 1100
$script:Warned = @()
Update-ExakitAutostartEntries
Check "  left as it is" "True" ("" + ((Get-Item $schedEntry).LastWriteTimeUtc -eq $before))
Check "  no warning" "0" ("" + @($script:Warned).Count)
$env:USERPROFILE = $savedProfile

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "$($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -ne 0) { exit 1 }
exit 0
