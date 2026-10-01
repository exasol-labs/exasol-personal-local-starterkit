#!/usr/bin/env pwsh
# uninstall-ps.ps1 - regression test for Invoke-ExakitUninstallRun in
# setup/exakit.ps1 (the Windows CLI). Extracts just that function via the AST,
# runs it against a fully sandboxed fake $HOME, and asserts the same behavior as
# the bash tests/uninstall.sh: dry-run removes nothing; a real run deletes
# skills, exapump, the kit home and the CLI binaries AND invokes the database
# teardown + MCP config removal; and it leaves bystander files alone.
#
#   pwsh -NoProfile -File tests/uninstall-ps.ps1

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label = $actual" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected $expected, got $actual" }
}

# --- pull only the function under test out of the CLI via the AST ----------
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repo "setup/exakit.ps1"), [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "exakit.ps1 has parse errors" }
# EVERY function definition, not just the one under test.
#
# Extracting Invoke-ExakitUninstallRun alone meant the test broke the moment
# that function called a helper it had not called before -- and this suite had
# no caller anywhere, so nobody found out. On its first run it died on
# Get-ExakitServiceIds, with five more (Unregister-ExakitAutostart,
# Get-ExakitMarketplaceInstalledAddons, Get-ExakitMarketplaceAddon,
# Get-ExakitKitSkillNames, Get-ExakitSkillRoots) waiting behind it.
#
# Definitions only: the AST walk takes function bodies, never the CLI's
# top-level code, so nothing here runs a command or touches the machine. The
# stubs below are defined AFTER this and override the real ones by name, which
# is what keeps the sandbox sealed.
# Top-level functions only. exakit.ps1 declares no class today, but
# exakit-common.ps1 does, and on Windows PowerShell 5.1 a class constructor
# comes back from this walk looking like a function definition - running its
# extent is then a call to a command named after the class, which killed
# tests/skills.ps1 outright before its first check. The same filter here so
# that adding a class to this file is a change, not an outage.
$fns = $ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $n.Extent.Text -match '^\s*(function|filter)\s' }, $true)
if (-not $fns) { throw "no function definitions found in exakit.ps1" }
foreach ($f in $fns) { Invoke-Expression $f.Extent.Text }
if (-not (Get-Command Invoke-ExakitUninstallRun -ErrorAction SilentlyContinue)) {
    throw "Invoke-ExakitUninstallRun not found"
}

# --- sandbox + stubs -------------------------------------------------------
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-uninst-" + [guid]::NewGuid())
$fakeHome = Join-Path $sandbox "home"
# A SECOND home, on purpose. On a domain-joined Windows machine PowerShell's
# $HOME (the account's home-directory attribute, often H:\ or a UNC share) and
# %USERPROFILE% (the local profile) are different directories. exapump.exe
# reads its config from the second; uninstall used to delete only the first,
# so it reported success and left an admin-credentialed config.toml behind.
# The suite models the split machine, because the same-path machine hides it.
$fakeProfile = Join-Path $sandbox "profile"
Set-Variable -Name HOME -Value $fakeHome -Scope Global -Force
$script:ExakitHome = Join-Path $fakeHome ".exasol-starter-kit"
$script:BinDir     = Join-Path $fakeHome ".local\bin"

$script:markers = @{}
function Info($m) {}; function Ok($m) {}; function OkStep($m) {}; function InfoStep($m) {}; function Fail($m) { throw $m }
# Warn2 is RECORDED, not swallowed: one of the things this suite has to prove
# is that a warning was said at all, and when.
$script:warnings = @()
function Warn2($m) { $script:warnings += "$m" }
function Get-ExakitManifestValue { param([string]$Path) return "" }
function Get-RuntimeType { "personal" }
function Get-ExakitRepoRoot { return $null }   # force fallback skill list
function Get-ExakitProfileHome { return $fakeProfile }
function Remove-Personal { $script:markers.database = $true }
function Invoke-McpOperation { param($Operation, $InputArgs) $script:markers.mcp = $Operation; return $true }
# The real helper defers deletion to a detached process (so cmd.exe does not
# choke on exakit.cmd being removed mid-run); here we delete synchronously so
# the assertions below can observe the binaries being gone.
function Remove-ExakitBinariesDeferred { param([string[]]$Paths) foreach ($f in $Paths) { Remove-Item -Force -ErrorAction SilentlyContinue $f } }
# Autostart teardown: the real one writes to the user's login items, so it is
# recorded rather than performed. Asserted below -- this is uninstall's promise
# that it leaves nothing behind to start the database after it is gone.
function Get-ExakitServiceIds { @("database") }
function Test-ExakitAutostartRegistered { param([string]$Id) $true }
function Unregister-ExakitAutostart { param([string]$Id) $script:markers.autostart = $Id }
# No add-ons in the sandbox: their removal has its own suite
# (tests/uninstall-addons-only.sh) and dragging the registry in here would make
# this test depend on which add-ons happen to be registered.
function Get-ExakitMarketplaceInstalledAddons { @() }
function Get-ExakitMarketplaceAddon { param([string]$Id) $null }
function Get-ExakitMarketplaceAddons { @() }
# These four live in setup/lib/, not setup/exakit.ps1, so extracting the CLI's
# functions does not bring them along.
#
# The skill names are the two the sandbox seeds, because the assertions below
# are that BOTH are gone after a real run: a stub returning fewer would let a
# kit skill survive uninstall and still pass. The roots mirror the real helper
# exactly ($HOME is the fake home here, so it is already sealed).
function Get-ExakitKitSkillNames { @("local-agent-ready-starter", "trusted-ai-workflow") }
function Get-ExakitSkillRoots {
    @((Join-Path $HOME ".claude\skills"), (Join-Path $HOME ".agents\skills"))
}
function Write-ExakitLog { param($Level, $Message) }
# The allowlist removal lives in exakit-common.ps1, which this harness does not
# load; the uninstall run calls it beside the skills step.
function Remove-ExakitReadonlyAllowlist { return "REMOVED 0" }
# The one-line narration the real run wraps itself in. Stubbed rather than
# driven: this suite asserts what uninstall REMOVES, and an animation in a
# harness with no console would only get in the way.
function Start-ExakitSpinner { param([string]$Label) }
function Stop-ExakitSpinner { }

function Seed {
    if (Test-Path $sandbox) { Remove-Item -Recurse -Force $sandbox }
    foreach ($d in @(
        "$($script:BinDir)",
        "$fakeHome\.claude\skills\local-agent-ready-starter",
        "$fakeHome\.claude\skills\trusted-ai-workflow",
        "$fakeHome\.agents\skills\local-agent-ready-starter",
        "$fakeHome\.exapump",
        "$fakeProfile\.exapump",
        "$($script:ExakitHome)\credentials")) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }
    foreach ($f in @("exakit.cmd", "exapump.exe", "exasol.exe", "some-other-tool.exe")) {
        New-Item -ItemType File -Force -Path (Join-Path $script:BinDir $f) | Out-Null
    }
    New-Item -ItemType File -Force -Path (Join-Path $script:ExakitHome "manifest.json") | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $fakeHome ".exapump\config.toml") | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $fakeProfile ".exapump\config.toml") | Out-Null
    $script:markers = @{}
    $script:warnings = @()
}
function Ex($p) { if (Test-Path $p) { "yes" } else { "no" } }

Write-Host "Invoke-ExakitUninstallRun:"

# --- dry run: nothing removed, no teardown -------------------------------
Seed
Invoke-ExakitUninstallRun -DryRun
Check "dry: kit home kept"   "yes" (Ex $script:ExakitHome)
Check "dry: exapump kept"    "yes" (Ex (Join-Path $fakeHome ".exapump"))
Check "dry: exapump under the profile home kept" "yes" (Ex (Join-Path $fakeProfile ".exapump"))
Check "dry: skill kept"      "yes" (Ex "$fakeHome\.claude\skills\trusted-ai-workflow")
Check "dry: no db teardown"  ""    ("" + $script:markers.database)
# A dry run must not unregister anything either: it reports, it does not act.
Check "dry: autostart untouched" "" ("" + $script:markers.autostart)

# --- real run: everything removed, teardown + mcp invoked ----------------
Seed
Invoke-ExakitUninstallRun
Check "real: db teardown"       "True"      ("" + $script:markers.database)
Check "real: mcp uninstall"     "uninstall" ("" + $script:markers.mcp)
# Uninstall's promise: nothing is left behind that starts the database after
# the kit is gone. This assertion is new because the code it covers was added
# after this suite was written, and the suite had no caller to notice.
Check "real: autostart unregistered" "database" ("" + $script:markers.autostart)
Check "real: kit home gone"     "no"  (Ex $script:ExakitHome)
Check "real: exapump gone"      "no"  (Ex (Join-Path $fakeHome ".exapump"))
# The one an ordinary machine cannot tell apart from the line above.
Check "real: exapump under the profile home gone" "no" (Ex (Join-Path $fakeProfile ".exapump"))
Check "real: exapump.exe gone"  "no"  (Ex (Join-Path $script:BinDir "exapump.exe"))
Check "real: exakit.cmd gone"   "no"  (Ex (Join-Path $script:BinDir "exakit.cmd"))
Check "real: skill A gone"      "no"  (Ex "$fakeHome\.claude\skills\local-agent-ready-starter")
Check "real: skill B gone"      "no"  (Ex "$fakeHome\.claude\skills\trusted-ai-workflow")
Check "real: bystander kept"    "yes" (Ex (Join-Path $script:BinDir "some-other-tool.exe"))

# --- idempotent second run on empty tree ---------------------------------
$ok = $true; try { Invoke-ExakitUninstallRun } catch { $ok = $false }
Check "idempotent second run" "True" ("" + $ok)

Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "PASS=$($script:PASS) FAIL=$($script:FAIL)"
if ($script:FAIL -ne 0) { exit 1 }
