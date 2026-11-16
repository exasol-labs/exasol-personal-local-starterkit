#!/usr/bin/env pwsh
# uninstall-leftovers-ps.ps1 - the Windows twin of tests/uninstall-leftovers.sh:
# a full uninstall must never report success while the database deployment is
# still on the machine.
#
#   pwsh -NoProfile -File tests/uninstall-leftovers-ps.ps1
#
# THE BUG: Remove-Personal ran the launcher's destroy (only when `exasol info`
# answered), warned on a non-zero exit, and returned normally either way, so
# Invoke-ExakitUninstallRun printed "Database removed" and Invoke-CmdUninstall
# "Uninstall complete" (exit 0) over a deployment that was still there.
#
# Pinned here:
#   Remove-Personal      destroy exits 0 but the directory remains -> leftover
#                        named, remedy given, status NOT recorded "removed";
#                        destroy fails -> leftover; `info` fails but the
#                        directory exists -> destroy still attempted; a
#                        container carrying the id -> named, `rm -f` remedy;
#                        a clean destroy -> nothing left, "removed" recorded
#   Invoke-ExakitUninstallRun  no "Database removed" over a leftover
#   Invoke-CmdUninstall -Yes   exit 1 and no "Uninstall complete" over a
#                        leftover; exit 0 and the success line when clean;
#                        -DryRun unchanged (exit 0, no teardown)
#
# Functions are pulled from the real files through the AST (definitions only,
# never top-level code); every external - launcher, engines, manifest, logging,
# the binaries' deferred delete - is a stub, and HOME is a fresh sandbox. The
# exit-code cases run in a child pwsh, because the code under test calls exit.

param([string]$Mode = "")

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot

# Returns the definitions' text; the caller runs them at SCRIPT scope (an
# Invoke-Expression in here would define them in this function's scope only).
function Get-FunctionTexts([string]$Path, [string[]]$Only = @()) {
    $errors = $null; $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "$Path has parse errors" }
    $fns = $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Extent.Text -match '^\s*(function|filter)\s' }, $true)
    foreach ($f in $fns) {
        if ($Only.Count -gt 0 -and $Only -notcontains $f.Name) { continue }
        $f.Extent.Text
    }
}

# Every CLI function (so the uninstall path resolves), then the four runtime
# functions under test. Stubs below are defined AFTER and win by name.
foreach ($t in (Get-FunctionTexts (Join-Path $repo "setup/exakit.ps1"))) { Invoke-Expression $t }
foreach ($t in (Get-FunctionTexts (Join-Path $repo "setup/lib/runtime-personal.ps1") @(
    "Remove-Personal", "Find-PersonalTeardownLeftovers", "Test-PersonalNamesCarryId", "Get-PersonalDeploymentId",
    "Get-PersonalLauncherCacheDir", "Get-PersonalOtherDeployments", "Get-PersonalPrunableStateDirs",
    "Get-PersonalLauncherLeftovers"))) { Invoke-Expression $t }
foreach ($need in @("Remove-Personal", "Invoke-ExakitUninstallRun", "Invoke-CmdUninstall")) {
    if (-not (Get-Command $need -ErrorAction SilentlyContinue)) { throw "$need not found" }
}

# --- sandbox -------------------------------------------------------------
$sandbox = $env:EXAKIT_LEFTOVER_SANDBOX
if (-not $sandbox) { $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-left-" + [guid]::NewGuid()) }
$fakeHome = Join-Path $sandbox "home"
New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
Set-Variable -Name HOME -Value $fakeHome -Scope Global -Force
$script:ExakitHome = Join-Path $fakeHome ".exasol-starter-kit"
$script:BinDir     = Join-Path $fakeHome ".local\bin"
$script:ManifestPath = Join-Path $script:ExakitHome "manifest.json"
$script:PersonalDeployDir = Join-Path $fakeHome ".exasol\personal\deployments\default"
# The launcher cache lives under LOCALAPPDATA: point it into the sandbox for
# every case (the clean uninstall runs now remove it), never at the real one.
$env:LOCALAPPDATA = Join-Path $fakeHome "AppData\Local"
# Engines: empty files on a PATH that holds nothing else, so Get-Command finds
# these and never a real docker/podman. They are never executed (the bounded
# runner below is a stub).
$engineDir = Join-Path $sandbox "engines"
New-Item -ItemType Directory -Force -Path $engineDir | Out-Null
$onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
foreach ($e in @("docker", "podman")) {
    if ($onWindows) { $p = Join-Path $engineDir "$e.cmd" } else { $p = Join-Path $engineDir $e }
    if (-not (Test-Path $p)) { Set-Content -Path $p -Value "#!/bin/sh" }
    if (-not $onWindows) { & /bin/chmod +x $p }
}
$env:PATH = $engineDir

# --- stubs ---------------------------------------------------------------
$script:out = @()
$script:calls = @()
$script:manifest = @{}
function Info($m) { $script:out += "INFO $m"; Write-Host "INFO $m" }
function Ok($m) { $script:out += "OK $m"; Write-Host "OK $m" }
function OkStep($m) { Ok $m }
function InfoStep($m) { Info $m }
function Warn2($m) { $script:out += "WARN $m"; Write-Host "WARN $m" }
function Fail($m) { throw $m }
function Write-ExakitLog { param($Level, $Message) }
function Initialize-ExakitLogging { }
function Get-ExakitManifestValue { param([string]$Path) return "" }
function Set-ExakitManifestValue { param($Path, $Value) $script:manifest[$Path] = $Value }
function Remove-ExakitStepDone { param($Name) }
function Get-RuntimeType { if ($env:STUB_NO_TYPE -eq "1") { return "" } return "personal" }
function Get-ExakitRepoRoot { return $null }
function Get-ExakitProfileHome { return $fakeHome }
function Get-ExakitServiceIds { @() }
function Test-ExakitAutostartRegistered { param([string]$Id) $false }
function Unregister-ExakitAutostart { param([string]$Id) }
function Get-ExakitMarketplaceInstalledAddons { @() }
function Get-ExakitMarketplaceAddon { param([string]$Id) $null }
function Get-ExakitMarketplaceAddons { @() }
function Get-ExakitKitSkillNames { @() }
function Get-ExakitSkillRoots { @() }
function Get-ExakitExapumpProfileDirs { @() }
function Remove-ExakitReadonlyAllowlist { return "REMOVED 0" }
function Invoke-McpOperation { param($Operation, $InputArgs) return $true }
function Start-ExakitSpinner { param([string]$Label) }
function Stop-ExakitSpinner { }
function Remove-ExakitBinariesDeferred { param([string[]]$Paths) foreach ($f in $Paths) { Remove-Item -Force -ErrorAction SilentlyContinue $f } }
# The launcher. STUB_INFO_OK / STUB_DESTROY_RC / STUB_DESTROY_REMOVES as in the
# bash suite.
function Get-PersonalCli { return "exasol-stub" }
function Test-PersonalDeploymentExists {
    $script:calls += "info"
    return ((Test-Path $script:PersonalDeployDir) -and ($env:STUB_INFO_OK -ne "0"))
}
function Invoke-ExakitLogged {
    $script:calls += ($args -join " ")
    if ($args -contains "destroy") {
        if ($env:STUB_DESTROY_REMOVES -eq "1") { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $script:PersonalDeployDir }
        return [int]("0" + $env:STUB_DESTROY_RC)
    }
    return 0
}
function Invoke-ExakitBounded {
    param([string]$FilePath, [string[]]$Arguments = @(), [string]$ArgumentString = "", [int]$TimeoutSeconds = 8)
    if ([System.IO.Path]::GetFileNameWithoutExtension($FilePath) -eq "docker") { return $env:STUB_DOCKER_PS }
    return ""
}

function Seed-Deploy {
    if (Test-Path $script:PersonalDeployDir) { Remove-Item -Recurse -Force $script:PersonalDeployDir }
    New-Item -ItemType Directory -Force -Path $script:PersonalDeployDir | Out-Null
    Set-Content -Path (Join-Path $script:PersonalDeployDir "deployment.json") -Value '{"deploymentId": "exa-test1"}'
    $script:calls = @(); $script:manifest = @{}; $script:out = @()
}
function Seed-Kit {
    New-Item -ItemType Directory -Force -Path (Join-Path $script:ExakitHome "credentials") | Out-Null
    New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null
    New-Item -ItemType File -Force -Path $script:ManifestPath | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $script:BinDir "exakit.cmd") | Out-Null
}

# --- child mode: one Invoke-CmdUninstall run, exit code is the answer ----
if ($Mode) {
    Seed-Kit
    Seed-Deploy
    if ($Mode -eq "yes-left")  { $env:STUB_DESTROY_RC = "0"; $env:STUB_DESTROY_REMOVES = "0"; Invoke-CmdUninstall -AssumeYes }
    if ($Mode -eq "yes-clean") { $env:STUB_DESTROY_RC = "0"; $env:STUB_DESTROY_REMOVES = "1"; Invoke-CmdUninstall -AssumeYes }
    if ($Mode -eq "dry")       { $env:STUB_DESTROY_RC = "1"; $env:STUB_DESTROY_REMOVES = "0"; Invoke-CmdUninstall -DryRun
                                 if ($script:calls -match "destroy") { Write-Host "DESTROY-CALLED" } }
    exit 0
}

$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label = $actual" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected [$expected], got [$actual]" }
}
function Has($label, $needle, $hay) {
    if (("" + ($hay -join "`n")).Contains($needle)) { $script:PASS++; Write-Host "  ok   $label contains `"$needle`"" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected to contain `"$needle`"" }
}
function Lacks($label, $needle, $hay) {
    if (("" + ($hay -join "`n")).Contains($needle)) { $script:FAIL++; Write-Host "  FAIL $($label): must not contain `"$needle`"" }
    else { $script:PASS++; Write-Host "  ok   $label lacks `"$needle`"" }
}
function Left { "" + (@($script:PersonalTeardownLeftovers) -join "; ") }

Write-Host "Remove-Personal verifies the end state:"
$dir = $script:PersonalDeployDir

Seed-Deploy; $env:STUB_INFO_OK = "1"; $env:STUB_DESTROY_RC = "0"; $env:STUB_DESTROY_REMOVES = "0"; $env:STUB_DOCKER_PS = ""
$script:PersonalTeardownLeftovers = $null; $script:PersonalTeardownRemedy = $null
Remove-Personal
Has   "a: destroy 0 + dir left names the directory" $dir (Left)
Has   "a: the remedy removes it" "Remove-Item -Recurse -Force '$dir'" ("" + $script:PersonalTeardownRemedy)
Check "a: the record is not 'removed'" "" ("" + $script:manifest["runtime.status"])

Seed-Deploy; $env:STUB_DESTROY_RC = "1"; $env:STUB_DESTROY_REMOVES = "0"
$script:PersonalTeardownLeftovers = $null
Remove-Personal
Has   "b: a failed destroy leaves the directory named" $dir (Left)

Seed-Deploy; $env:STUB_INFO_OK = "0"; $env:STUB_DESTROY_RC = "0"; $env:STUB_DESTROY_REMOVES = "1"
Remove-Personal
Has   "d: destroy is attempted when info fails" "destroy --remove --auto-approve" $script:calls
Check "d: and nothing is left" "" (Left)
$env:STUB_INFO_OK = "1"

Seed-Deploy; $env:STUB_DESTROY_RC = "0"; $env:STUB_DESTROY_REMOVES = "1"; $env:STUB_DOCKER_PS = "exa-test1-db-1`nsomebody-else`nexa-test10"
Remove-Personal
Has   "g: a container carrying the id is named" "the docker container exa-test1-db-1" (Left)
Has   "g: the remedy removes it" "docker rm -f exa-test1-db-1" ("" + $script:PersonalTeardownRemedy)
Lacks "g: an unrelated container is not named" "somebody-else" (Left)
Lacks "g: nor one that merely starts with the id" "exa-test10" (Left)
$env:STUB_DOCKER_PS = ""

Seed-Deploy; $env:STUB_DESTROY_RC = "0"; $env:STUB_DESTROY_REMOVES = "1"
Remove-Personal
Check "c: a clean destroy leaves nothing" "" (Left)
Check "c: and records removed" "removed" ("" + $script:manifest["runtime.status"])

Write-Host ""
Write-Host "Invoke-ExakitUninstallRun does not claim a removal that did not happen:"
Seed-Kit; Seed-Deploy; $env:STUB_DESTROY_RC = "0"; $env:STUB_DESTROY_REMOVES = "0"
Invoke-ExakitUninstallRun
Lacks "a leftover: no 'Database removed'" "Database removed" $script:out
Has   "the leftover is printed" $dir $script:out
Has   "with the command that removes it" "Remove-Item -Recurse -Force" $script:out
Seed-Kit; Seed-Deploy; $env:STUB_DESTROY_REMOVES = "1"
Invoke-ExakitUninstallRun
Has   "a clean teardown still says 'Database removed'" "Database removed" $script:out
# No runtime recorded and the deployment on disk: nothing removes it.
Seed-Kit; Seed-Deploy; $env:STUB_NO_TYPE = "1"; $env:STUB_DESTROY_REMOVES = "0"
Invoke-ExakitUninstallRun
Check "no runtime recorded + deployment on disk: flagged" "True" ("" + $script:ExakitUninstallDbLeft)
Has   "and reported with its remedy" "Remove-Item -Recurse -Force" $script:out
Remove-Item -Recurse -Force $script:PersonalDeployDir
Seed-Kit; $script:out = @()
Invoke-ExakitUninstallRun
Check "no runtime recorded + nothing on disk: not flagged" "False" ("" + $script:ExakitUninstallDbLeft)
$env:STUB_NO_TYPE = ""

Write-Host ""
Write-Host "Invoke-ExakitUninstallRun removes the launcher cache and the empty state folders:"
$cache = Join-Path $env:LOCALAPPDATA ".exasol"
$exaRoot = Join-Path $fakeHome ".exasol"
$deplRoot = Split-Path -Parent $script:PersonalDeployDir
function Seed-Cache {
    if (Test-Path $cache) { Remove-Item -Recurse -Force $cache }
    $img = Join-Path $cache "personal\runtime-artifacts\artifacts\exasol-nano-image"
    New-Item -ItemType Directory -Force -Path $img | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $img "img"), (New-Object byte[] 2097152))
}
function Reset-Exa { if (Test-Path $exaRoot) { Remove-Item -Recurse -Force $exaRoot } }
# (h1) dry run lists the cache with its size and every folder that goes.
Reset-Exa; Seed-Kit; Seed-Deploy; Seed-Cache
Invoke-ExakitUninstallRun -DryRun
Has   "h1: dry run lists the launcher cache" "will remove: Exasol launcher download cache $cache (2 MB)" $script:out
Has   "h1: dry run lists the deployments folder" "will remove: empty launcher folder $deplRoot" $script:out
Has   "h1: dry run lists ~/.exasol" "will remove: empty launcher folder $exaRoot" $script:out
Check "h1: dry run keeps the cache" "True" (Test-Path $cache)
# (h2) the real run removes them.
$env:STUB_DESTROY_RC = "0"; $env:STUB_DESTROY_REMOVES = "1"; $script:out = @()
Invoke-ExakitUninstallRun
Has   "h2: the cache removal is recorded" "Launcher download cache removed: $cache" $script:out
Check "h2: the cache is gone" "False" (Test-Path $cache)
Check "h2: LOCALAPPDATA itself stays" "True" (Test-Path $env:LOCALAPPDATA)
Check "h2: ~/.exasol is gone" "False" (Test-Path $exaRoot)
# (h3) another deployment beside the kit's: cache and folders stay.
Reset-Exa; Seed-Kit; Seed-Deploy; Seed-Cache
New-Item -ItemType Directory -Force -Path (Join-Path $deplRoot "other") | Out-Null
Invoke-ExakitUninstallRun -DryRun
Lacks "h3: dry run does not list the shared cache" "launcher download cache" $script:out
Lacks "h3: nor any launcher folder" "empty launcher folder" $script:out
Seed-Kit; $script:out = @()
Invoke-ExakitUninstallRun
Check "h3: the cache stays" "True" (Test-Path $cache)
Check "h3: the sibling deployment stays" "True" (Test-Path (Join-Path $deplRoot "other"))
# (h4) a file in ~/.exasol keeps it; the empty folders below still go.
Reset-Exa; Seed-Kit; Seed-Deploy; Seed-Cache
New-Item -ItemType File -Force -Path (Join-Path $exaRoot "notes") | Out-Null
Invoke-ExakitUninstallRun
Check "h4: ~/.exasol/personal is gone" "False" (Test-Path (Join-Path $exaRoot "personal"))
Check "h4: ~/.exasol with a file in it stays" "True" (Test-Path (Join-Path $exaRoot "notes"))
# (h5) a teardown that left the deployment: nothing beside it is touched.
Reset-Exa; Seed-Kit; Seed-Deploy; Seed-Cache; $env:STUB_DESTROY_REMOVES = "0"
Invoke-ExakitUninstallRun
Check "h5: a failed teardown keeps the cache" "True" (Test-Path $cache)
Check "h5: and the deployments folder" "True" (Test-Path $deplRoot)
Reset-Exa; if (Test-Path $cache) { Remove-Item -Recurse -Force $cache }

Write-Host ""
Write-Host "Invoke-CmdUninstall -Yes only says complete when it is:"
$pwshExe = (Get-Process -Id $PID).Path
function Child([string]$m) {
    $env:EXAKIT_LEFTOVER_SANDBOX = Join-Path $sandbox ("child-" + $m)
    # Continue, around the call only: under Stop, Windows PowerShell 5.1 turns
    # the child's stderr into a terminating error before $LASTEXITCODE is read.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $o = & $pwshExe -NoProfile -File $PSCommandPath -Mode $m 2>&1 | Out-String
    $script:childRc = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    return $o
}
$o = Child "yes-left"
Check "a leftover exits 1" "1" $script:childRc
Lacks "and never says 'Uninstall complete'" "Uninstall complete" $o
Has   "and says it did not finish" "did not finish" $o
$o = Child "yes-clean"
Check "a clean run exits 0" "0" $script:childRc
Has   "and says 'Uninstall complete'" "Uninstall complete" $o
$o = Child "dry"
Check "-DryRun exits 0" "0" $script:childRc
Lacks "and never runs the destroy" "DESTROY-CALLED" $o

Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "PASS=$($script:PASS) FAIL=$($script:FAIL)"
if ($script:FAIL -ne 0) { exit 1 }
