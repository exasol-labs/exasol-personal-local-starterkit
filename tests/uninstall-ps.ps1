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
$fn = $ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $n.Name -eq "Invoke-ExakitUninstallRun" }, $true) | Select-Object -First 1
if (-not $fn) { throw "Invoke-ExakitUninstallRun not found" }
Invoke-Expression $fn.Extent.Text

# --- sandbox + stubs -------------------------------------------------------
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-uninst-" + [guid]::NewGuid())
$fakeHome = Join-Path $sandbox "home"
Set-Variable -Name HOME -Value $fakeHome -Scope Global -Force
$script:ExakitHome = Join-Path $fakeHome ".exasol-starter-kit"
$script:BinDir     = Join-Path $fakeHome ".local\bin"

$script:markers = @{}
function Info($m) {}; function Ok($m) {}; function Warn2($m) {}; function Fail($m) { throw $m }
function Get-RuntimeType { "nano" }
function Get-ExakitRepoRoot { return $null }   # force fallback skill list
function Remove-Nano { param([switch]$Data) $script:markers.nano = [bool]$Data }
function Invoke-McpOperation { param($Operation, $InputArgs) $script:markers.mcp = $Operation; return $true }
# The real helper defers deletion to a detached process (so cmd.exe does not
# choke on exakit.cmd being removed mid-run); here we delete synchronously so
# the assertions below can observe the binaries being gone.
function Remove-ExakitBinariesDeferred { param([string[]]$Paths) foreach ($f in $Paths) { Remove-Item -Force -ErrorAction SilentlyContinue $f } }

function Seed {
    if (Test-Path $sandbox) { Remove-Item -Recurse -Force $sandbox }
    foreach ($d in @(
        "$($script:BinDir)",
        "$fakeHome\.claude\skills\local-agent-ready-starter",
        "$fakeHome\.claude\skills\trusted-ai-workflow",
        "$fakeHome\.agents\skills\local-agent-ready-starter",
        "$fakeHome\.exapump",
        "$($script:ExakitHome)\credentials")) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }
    foreach ($f in @("exakit.cmd", "exapump.exe", "exasol.exe", "some-other-tool.exe")) {
        New-Item -ItemType File -Force -Path (Join-Path $script:BinDir $f) | Out-Null
    }
    New-Item -ItemType File -Force -Path (Join-Path $script:ExakitHome "manifest.json") | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $fakeHome ".exapump\config.toml") | Out-Null
    $script:markers = @{}
}
function Ex($p) { if (Test-Path $p) { "yes" } else { "no" } }

Write-Host "Invoke-ExakitUninstallRun:"

# --- dry run: nothing removed, no teardown -------------------------------
Seed
Invoke-ExakitUninstallRun -DryRun
Check "dry: kit home kept"   "yes" (Ex $script:ExakitHome)
Check "dry: exapump kept"    "yes" (Ex (Join-Path $fakeHome ".exapump"))
Check "dry: skill kept"      "yes" (Ex "$fakeHome\.claude\skills\trusted-ai-workflow")
Check "dry: no db teardown"  ""    ("" + $script:markers.nano)

# --- real run: everything removed, teardown + mcp invoked ----------------
Seed
Invoke-ExakitUninstallRun
Check "real: db teardown -Data" "True"      ("" + $script:markers.nano)
Check "real: mcp uninstall"     "uninstall" ("" + $script:markers.mcp)
Check "real: kit home gone"     "no"  (Ex $script:ExakitHome)
Check "real: exapump gone"      "no"  (Ex (Join-Path $fakeHome ".exapump"))
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
