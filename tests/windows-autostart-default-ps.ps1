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
Check "  it starts the database" "True" ("" + ((Get-Content $entry -Raw) -match 'exasol\.exe" start'))

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

Write-Host "the install's closing line names the AI clients it connected (Get-ExakitReadyLineText)"
$env:EXAKIT_READY_LINE_COLS = "120"
Reset '{"manifest_version": 1, "components": {"mcp_server": {"client_setup": {"configured_clients": ["codex", "claude_code", "vscode_copilot"]}}}}'
Check "three clients: the sentence names them" "Exasol starterkit is ready and connected into Claude Code, Codex and GitHub Copilot. Ask them about your data." (Get-ExakitReadyLineText)
Reset '{"manifest_version": 1, "components": {"mcp_server": {"client_setup": {"configured_clients": ["claude_desktop"]}}}}'
Check "one client: it, and the short desktop name" "Exasol starterkit is ready and connected into Claude Desktop. Ask it about your data." (Get-ExakitReadyLineText)
Reset '{"manifest_version": 1, "components": {"mcp_server": {"client_setup": {"configured_clients": ["claude_code", "claude_desktop", "codex", "cursor", "vscode_copilot", "gemini_cli"]}}}}'
$long = Get-ExakitReadyLineText
Check "six clients: the list is cut" "True" ("" + $long.EndsWith(" more. Ask them about your data."))
Check "  and the line fits a 120-column console with its tick" "True" ("" + (($long.Length + 8) -le 120))
Reset '{"manifest_version": 1, "components": {"mcp_server": {"client_setup": {"configured_clients": []}}}}'
Check "no client: the plain line" "Your starter kit is ready to use." (Get-ExakitReadyLineText)
Remove-Item Env:EXAKIT_READY_LINE_COLS -ErrorAction SilentlyContinue

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "$($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -ne 0) { exit 1 }
exit 0
