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
# Load ownership helpers as definitions, without running shared module setup.
$commonAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repo "setup/lib/exakit-common.ps1"), [ref]$tokens, [ref]$errors)
foreach ($name in @('Get-ExakitOwnershipKey','Get-ExakitComponentOwnership','Test-ExakitComponentManaged','Get-ExakitPreservedComponentPaths','Write-ExakitPreservedComponent')) {
    $definition = $commonAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    Invoke-Expression $definition.Extent.Text
}
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
function Get-ExakitManifestValue {
    param([string]$Path)
    if ($Path -in @('runtime.ownership','components.personal.ownership','components.exapump.ownership')) { return 'kit' }
    return ""
}
function Get-RuntimeType { "personal" }
function Get-ExakitRepoRoot { return $null }   # force fallback skill list
function Get-ExakitProfileHome { return $fakeProfile }
function Remove-Personal { $script:markers.database = $true }
# The launcher cache and state folders: nothing to remove here (their own
# cases live in uninstall-leftovers-ps.ps1).
function Get-PersonalLauncherLeftovers { [pscustomobject]@{ Cache = ""; CacheSize = ""; Dirs = @() } }
function Get-PersonalOtherDeployments { @() }
# No recorded engine: the image record is empty and step 1c asks no engine.
function Get-PersonalEngineRecorded { return "" }
# The container-image step asks docker/podman through the bounded runner: a stub
# that runs nothing, so no real engine is ever asked or touched (its own cases
# live in tests/uninstall-leftovers-ps.ps1).
function Invoke-ExakitBounded { param([string]$FilePath, [string[]]$Arguments = @(), [string]$ArgumentString = "", [int]$TimeoutSeconds = 8) return "" }
function Invoke-McpOperation { param($Operation, $InputArgs) $script:markers.mcp = $Operation; return $true }
# The real helper defers deletion to a detached process (so cmd.exe does not
# choke on exakit.cmd being removed mid-run); here we delete synchronously so
# the assertions below can observe the binaries being gone.
function Remove-ExakitBinariesDeferred { param([string[]]$Paths) foreach ($f in $Paths) { Remove-Item -Force -ErrorAction SilentlyContinue $f } }
# Autostart teardown: the real one writes to the user's login items, so it is
# recorded rather than performed. Asserted below -- this is uninstall's promise
# that it leaves nothing behind to start the database after it is gone.
# Ownership (exakit-common.ps1): everything in this fixture was installed by the kit, so nothing is kept.
function Get-ExakitPreservedComponentPaths { @() }
function Test-ExakitComponentManaged { param([string]$Component) $true }
function Write-ExakitPreservedComponent { param([string]$Component) }
function Get-ExakitServiceIds { @("database") }
function Test-ExakitAutostartRegistered { param([string]$Id) $true }
function Unregister-ExakitAutostart { param([string]$Id) $script:markers.autostart = $Id }
# The orphan sweep reads the Startup folder: a sandbox path with nothing in
# it, never the real one (its own cases live in uninstall-leftovers-ps.ps1).
function Get-ExakitStartupDir { return (Join-Path $sandbox "Startup") }
function Get-ExakitAutostartPrefix { return "com.exasol.exakit" }
# No add-ons in the sandbox: their removal has its own suite
# (tests/uninstall-addons-only.sh) and dragging the registry in here would make
# this test depend on which add-ons happen to be registered.
function Get-ExakitMarketplaceInstalledAddons { @() }
function Get-ExakitMarketplaceRemovableAddons { @() }
function Get-ExakitMarketplaceAddon { param([string]$Id) $null }
function Get-ExakitMarketplaceAddons { @([pscustomobject]@{ Id = "dash-server" }) }
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
# ui.ps1 shortens paths under the home to ~ on screen; identity here, so
# the assertions read the paths the run removed.
function Get-ExakitTilde([string]$Path) { $Path }
# The allowlist removal lives in exakit-common.ps1, which this harness does not
# load; the uninstall run calls it beside the skills step.
function Remove-ExakitReadonlyAllowlist { return "REMOVED 0" }
# The MCP sidecar lives in setup/lib/mcp.ps1, which this test does not load; uninstall guards the call with
# Get-Command, and the sidecar itself is covered by tests/mcp-sidecar-ps.ps1.
function Remove-McpSidecar { param([switch]$DryRun) }
# The one-line narration the real run wraps itself in. Stubbed rather than
# driven: this suite asserts what uninstall REMOVES, and an animation in a
# harness with no console would only get in the way.
function Start-ExakitSpinner { param([string]$Label) }
function Stop-ExakitSpinner { }
function Set-ExakitSpinnerLabel { param([string]$Label) }
# The process list is a FIXTURE, never the machine's: a real run here would
# enumerate - and stop - the exasol-mcp-server of whatever AI client is open on
# the box running the suite. Stops are recorded, never sent. Empty by default.
$script:procFixture = @()
$script:stopped = @()
function Get-ExakitProcessList { return $script:procFixture }
function Stop-ExakitPidQuiet { param([int]$Id) $script:stopped += $Id; return $true }
# Info is silent above; the cases below need what it said.
$script:said = @()

# A skill folder is the kit's when it carries the kit's mark (tests/skills.ps1
# covers the whole rule, an older kit's unmarked copies included).
function Test-ExakitSkillIsKits { param([string]$Root, [string]$Name) return (Test-Path -LiteralPath (Join-Path (Join-Path $Root $Name) ".exakit-owned")) }

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
    foreach ($f in @("exakit.cmd", "exapump.exe", "exasol.exe", "some-other-tool.exe",
                     "exakit.cmd.new", "dash-server.cmd", "dash-server.cmd.new", "some-other-tool.cmd.new")) {
        New-Item -ItemType File -Force -Path (Join-Path $script:BinDir $f) | Out-Null
    }
    # The kit's skill folders carry its mark; a folder without one is never the kit's.
    foreach ($skill in @("$fakeHome\.claude\skills\local-agent-ready-starter", "$fakeHome\.claude\skills\trusted-ai-workflow",
                         "$fakeHome\.agents\skills\local-agent-ready-starter")) {
        New-Item -ItemType File -Force -Path (Join-Path $skill ".exakit-owned") | Out-Null
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
$script:dryInfo = @()
function Info($m) { $script:dryInfo += "$m" }
Invoke-ExakitUninstallRun -DryRun
function Info($m) {}
$dryText = $script:dryInfo -join "`n"
Check "dry: lists a staged exakit.cmd.new" "True" ($dryText.Contains("will remove: CLI binary " + (Join-Path $script:BinDir "exakit.cmd.new")))
Check "dry: lists a staged add-on .cmd.new" "True" ($dryText.Contains("will remove: CLI binary " + (Join-Path $script:BinDir "dash-server.cmd.new")))
Check "dry: does not list a bystander .cmd.new" "False" ($dryText.Contains("some-other-tool.cmd.new"))
Check "dry: staged .new kept" "yes" (Ex (Join-Path $script:BinDir "exakit.cmd.new"))
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
Check "real: user's exapump profiles kept" "yes" (Ex (Join-Path $fakeHome ".exapump"))
# The one an ordinary machine cannot tell apart from the line above.
Check "real: user's profile-home exapump profiles kept" "yes" (Ex (Join-Path $fakeProfile ".exapump"))
Check "real: exapump.exe gone"  "no"  (Ex (Join-Path $script:BinDir "exapump.exe"))
Check "real: exakit.cmd gone"   "no"  (Ex (Join-Path $script:BinDir "exakit.cmd"))
Check "real: skill A gone"      "no"  (Ex "$fakeHome\.claude\skills\local-agent-ready-starter")
Check "real: skill B gone"      "no"  (Ex "$fakeHome\.claude\skills\trusted-ai-workflow")
Check "real: bystander kept"    "yes" (Ex (Join-Path $script:BinDir "some-other-tool.exe"))
Check "real: exakit.cmd.new gone" "no" (Ex (Join-Path $script:BinDir "exakit.cmd.new"))
Check "real: add-on launcher gone" "no" (Ex (Join-Path $script:BinDir "dash-server.cmd"))
Check "real: add-on .cmd.new gone" "no" (Ex (Join-Path $script:BinDir "dash-server.cmd.new"))
Check "real: bystander .cmd.new kept" "yes" (Ex (Join-Path $script:BinDir "some-other-tool.cmd.new"))

# --- the add-on registry is read from the kit copy, which step 5 removes ---
# The real Get-ExakitMarketplaceAddons reads marketplace/catalog.json under the
# kit home; asked again at step 6 (the CLI binary sweep) it threw "Cannot find
# path ...\.exasol-starter-kit\kit" and the uninstall stopped with exakit.cmd,
# exapump.exe and exasol.exe still in the bin dir (found live on Windows). The
# stub above never noticed the kit home was gone; this one does.
Seed
function Get-ExakitMarketplaceAddons {
    if (-not (Test-Path -LiteralPath $script:ExakitHome)) {
        throw "Cannot find path '$($script:ExakitHome)\kit' because it does not exist."
    }
    @([pscustomobject]@{ Id = "dash-server" })
}
$registryThrew = ""
try { Invoke-ExakitUninstallRun } catch { $registryThrew = "$_" }
Check "registry gone: the uninstall does not stop" "" $registryThrew
Check "registry gone: kit home gone" "no" (Ex $script:ExakitHome)
Check "registry gone: exakit.cmd still removed" "no" (Ex (Join-Path $script:BinDir "exakit.cmd"))
Check "registry gone: exasol.exe still removed" "no" (Ex (Join-Path $script:BinDir "exasol.exe"))
Check "registry gone: add-on launcher still swept" "no" (Ex (Join-Path $script:BinDir "dash-server.cmd"))
function Get-ExakitMarketplaceAddons { @([pscustomobject]@{ Id = "dash-server" }) }

# --- the user's work stays: notebooks, MLflow runs, dashboards (audit DAY-01) ---
Seed
foreach ($d in @("notebooks\analyst", "mlflow\artifacts", "dash-server\instance\gitops-repo", "dash-server\venv", "logs")) {
    New-Item -ItemType Directory -Force -Path (Join-Path $script:ExakitHome $d) | Out-Null
}
Set-Content -Path (Join-Path $script:ExakitHome "mlflow\mlflow.db") -Value "registry"
Set-Content -Path (Join-Path $script:ExakitHome "dash-server\instance\gitops-repo\sales.json") -Value "board"
Check "work: the kept work is named" "notebooks, MLflow runs and models, dashboards" (Get-ExakitUninstallKeptWork)
Invoke-ExakitUninstallRun
$left = (@(Get-ChildItem -LiteralPath $script:ExakitHome -Force | ForEach-Object { $_.Name }) | Sort-Object) -join " "
Check "work: only the work is left in the kit home" "dash-server mlflow notebooks" $left
Check "work: Dash Server keeps only its instance" "instance" ((@(Get-ChildItem -LiteralPath (Join-Path $script:ExakitHome "dash-server") -Force | ForEach-Object { $_.Name })) -join " ")
Check "work: the MLflow store is still there" "registry" ((Get-Content -Path (Join-Path $script:ExakitHome "mlflow\mlflow.db")) -join "")
Check "work: a home holding only kept work is still a kit home" "True" ("" + (Test-ExakitSafeUninstallTarget $script:ExakitHome))
$env:EXAKIT_UNINSTALL_NOTEBOOKS = "remove"
try { Invoke-ExakitUninstallRun } finally { Remove-Item Env:EXAKIT_UNINSTALL_NOTEBOOKS -ErrorAction SilentlyContinue }
Check "work: EXAKIT_UNINSTALL_NOTEBOOKS=remove takes it too" "no" (Ex $script:ExakitHome)

# --- the AI client config snapshots: only the newest is kept (audit SEC-16) ---
Seed
New-Item -ItemType Directory -Force -Path (Join-Path $script:ExakitHome "backups\claude") | Out-Null
Set-Content -Path (Join-Path $script:ExakitHome "backups\claude\config.json") -Value '{"EXA_PASSWORD": "x"}'
$older = "$($script:ExakitHome)-backups-20200101-000000"
New-Item -ItemType Directory -Force -Path $older | Out-Null
Invoke-ExakitUninstallRun
$kept = @(Get-ChildItem -LiteralPath $fakeHome -Directory -Force | Where-Object { $_.Name -like ".exasol-starter-kit-backups-*" })
Check "snapshots: one is kept" "1" $kept.Count
Check "snapshots: the older one is gone" "no" (Ex $older)

# --- idempotent second run on empty tree ---------------------------------
$ok = $true; try { Invoke-ExakitUninstallRun } catch { $ok = $false }
Check "idempotent second run" "True" ("" + $ok)

# --- MCP servers the open AI clients still run are never stopped ---------
# Windows cannot read another process's environment, so ownership of an
# exasol-mcp-server cannot be proven. Uninstall (dry or real) neither names nor
# stops one, even one whose command line names the kit's own uvx; the closing
# hints ask the user to restart the AI client instead.
Write-Host ""
Write-Host "uninstall never stops exasol-mcp-server processes:"
function Info($m) { $script:said += "$m" }
function OkStep($m) { $script:said += "OK $m" }
$kitUvx = Join-Path $script:BinDir "uvx.exe"
$script:procFixture = @(
    [pscustomobject]@{ ProcessId = 501; ParentProcessId = 1;   CommandLine = "`"$kitUvx`" exasol-mcp-server@1.2.0" },
    [pscustomobject]@{ ProcessId = 502; ParentProcessId = 501; CommandLine = "C:\cache\uv\archive-v0\x\Scripts\python.exe C:\cache\uv\archive-v0\x\Scripts\exasol-mcp-server" },
    [pscustomobject]@{ ProcessId = 601; ParentProcessId = 1;   CommandLine = "C:\other\uvx.exe exasol-mcp-server@1.2.0" })
Seed
$script:said = @(); $script:stopped = @()
Invoke-ExakitUninstallRun -DryRun
Check "dry: no MCP process is listed" "0" (@($script:said | Where-Object { $_ -like "*exasol-mcp-server process*" }).Count)
Check "dry: nothing stopped" "0" $script:stopped.Count
Seed
$script:said = @(); $script:stopped = @()
Invoke-ExakitUninstallRun
Check "real: no MCP process is stopped" "0" $script:stopped.Count
Check "real: none reported stopped" "0" (@($script:said | Where-Object { $_ -like "*Stopped the kit's exasol-mcp-server*" }).Count)
$script:procFixture = @()
$srcMcp = Get-Content -Raw (Join-Path $repo "setup/exakit.ps1")
Check "the engine has no MCP process stop" "False" ($srcMcp -match 'Invoke-ExakitUninstallMcpProcesses|Get-ExakitKitMcpServerPids')

# --- the closing hints ---------------------------------------------------
Write-Host ""
Write-Host "uninstall ends with the restart advice and the uv cache hint:"
$script:said = @()
Write-ExakitUninstallClosingHints
Check "the restart advice is printed" "1" (@($script:said | Where-Object { $_ -like "Restart any AI client that was open*" }).Count)
Check "the uv cache hint is printed" "1" (@($script:said | Where-Object { $_ -like "*cache clean exasol-mcp-server" }).Count)
# A dry run says nothing: --yes runs the plan first, so hints there printed twice.
$script:said = @()
Write-ExakitUninstallClosingHints -DryRun
Check "dry run: no hints" "0" $script:said.Count
$src = Get-Content -Raw (Join-Path $repo "setup/exakit.ps1")
Check "the engine prints the hints" "True" ($src -match '(?m)^\s+Write-ExakitUninstallClosingHints -DryRun:\$DryRun\s*$')

# --- the permission rules: every one the kit ever wrote, and only those ---
Write-Host ""
Write-Host "uninstall removes every permission rule the kit wrote, and no other:"
$common = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repo "setup/lib/exakit-common.ps1"), [ref]$null, [ref]$null)
foreach ($f in $common.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        @("Remove-ExakitReadonlyAllowlist", "Invoke-ExakitReadonlyAllowlist", "Test-ExakitLegacyAllowlistRule", "Write-ExakitSettingsJson") -contains $n.Name }, $true)) {
    Invoke-Expression $f.Extent.Text
}
# The kit manifest, in memory. An older kit (0.2.5) placed skills and recorded no
# rules, so the rules of its list in the file are taken as its own.
$script:rulesManifest = '{"components": {"skills": {"installed": ["exakit"]}}}' | ConvertFrom-Json
function Read-ExakitManifest { return $script:rulesManifest }
function Set-ExakitManifestValue { param([string]$Path, $Value)
    if ($Path -eq "components.skills.claude_rules") {
        $script:rulesManifest.components.skills | Add-Member -Force -NotePropertyName claude_rules -NotePropertyValue @($Value)
    }
}
$rulesHome = Join-Path $sandbox "rules-home"
function Get-ExakitAgentHome { return $rulesHome }
New-Item -ItemType Directory -Force -Path (Join-Path $rulesHome ".claude") | Out-Null
$settings = Join-Path $rulesHome ".claude\settings.json"
@'
{
  "model": "keep-me",
  "permissions": {
    "allow": [
      "Bash(git status:*)",
      "Bash(exakit mcp-validate:*)",
      "Bash(~/.local/bin/exakit mcp-validate:*)",
      "Bash($HOME/.local/bin/exakit mcp-validate:*)",
      "Bash(exakit.cmd mcp-validate:*)",
      "Bash(exakit status:*)",
      "mcp__exasol",
      "Bash(exakit-other mcp-validate:*)"
    ],
    "deny": ["Bash(rm -rf:*)", "PowerShell(exakit uninstall:*)"]
  }
}
'@ | Set-Content -LiteralPath $settings
Check "the removal counts all seven kit rules" "REMOVED 7" (Remove-ExakitReadonlyAllowlist)
$doc = Get-Content -Raw $settings | ConvertFrom-Json
$left = @($doc.permissions.allow) + @($doc.permissions.deny)
Check "only the user's rules are left" "Bash(git status:*)|Bash(exakit-other mcp-validate:*)|Bash(rm -rf:*)" ($left -join '|')
Check "the rest of the file is kept" "keep-me" $doc.model
# MCP-04: once the kit records the rules it added, a rule of the kit's spelling
# that the user had before the kit is theirs: uninstall leaves it.
$script:rulesManifest = '{"components": {"skills": {"installed": ["exakit"], "claude_rules": ["PowerShell(exakit uninstall:*)"]}}}' | ConvertFrom-Json
Set-Content -LiteralPath $settings -Value '{"permissions": {"allow": ["Bash(exakit status:*)", "mcp__exasol"], "deny": ["PowerShell(exakit uninstall:*)"]}}'
Check "with a record: only the recorded rule goes" "REMOVED 1" (Remove-ExakitReadonlyAllowlist)
$doc = Get-Content -Raw $settings | ConvertFrom-Json
Check "with a record: the user's own rules of the kit's spelling stay" "Bash(exakit status:*)|mcp__exasol" ((@($doc.permissions.allow) + @($doc.permissions.deny)) -join '|')

# --- the exakit.cmd shim cleans itself up once its target is gone ----------
# Uninstall deletes the shim from a detached process after it exits. When that
# process is killed with the console's job, or the delete fails, the shim used
# to survive the kit home and fail with powershell's "-File parameter does not
# exist". The shim now checks its target and removes itself.
Write-Host ""
Write-Host "exakit.cmd self-cleaning shim"
$cErr = $null; $cTok = $null
$cAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repo "setup/lib/exakit-common.ps1"), [ref]$cTok, [ref]$cErr)
foreach ($name in @("Get-ExakitCmdShimContent", "Get-ExakitOemEncoding", "Set-ExakitCmdShim", "Test-ExakitCmdShimCurrent", "Write-ExakitCmdShimFile", "Get-ExakitShimLauncherPids", "Write-ExakitCmdShimDeferred", "Start-ExakitDetachedPowerShell", "Get-ExakitLauncherRunningPids")) {
    $def = $cAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1
    if (-not $def) { throw "$name not found in exakit-common.ps1" }
    Invoke-Expression $def.Extent.Text
}
# Not under a running exakit.cmd here: in place. (Without WMI - this suite off
# Windows - the real probe answers "under it" by its fail-safe rule.)
function Get-ExakitShimLauncherPids { param([string]$ShimPath) return @() }
function Get-ExakitLauncherRunningPids { param([string]$Path) return @() }
function Get-ExakitKitScriptRunningPids { param([string]$Path) return @() }
$shimBin = Join-Path $sandbox "shimbin"
$savedBin = $script:BinDir
$script:BinDir = $shimBin
$missing = Join-Path $sandbox "gone\kit\setup\exakit.ps1"
$shim = Get-ExakitCmdShimContent -PsTarget $missing
# The shim folds a target under the profile to %USERPROFILE% (on Windows the
# sandbox lives under TEMP, inside the profile), so expect the folded form.
$want = $missing
if ($env:USERPROFILE -and $want.StartsWith($env:USERPROFILE + [string][char]92, [System.StringComparison]::OrdinalIgnoreCase)) {
    $want = "%USERPROFILE%" + $want.Substring($env:USERPROFILE.Length)
}
Check "shim: checks its target exists" "True" ($shim.Contains("if exist `"$want`" goto run"))
Check "shim: says it is a leftover" "True" ($shim.Contains("exakit is no longer installed here (its files are gone), so this leftover launcher (`"%~f0`") removes itself now. To install exakit again, run the installer from the starter kit README."))
Check "shim: self-deletes after leaving the batch context" "True" ($shim.Contains("(goto) 2>nul & del `"%~f0`" & cmd /c exit 1"))
Check "shim: still runs the target" "True" ($shim.Contains("powershell -NoProfile -ExecutionPolicy Bypass -File `"$want`" %*"))
Check "shim: pure ASCII" "True" (-not ($shim -match '[^\x00-\x7F]'))
New-Item -ItemType Directory -Force -Path $shimBin | Out-Null
# The previous format: no target check. An install or update must rewrite it.
[System.IO.File]::WriteAllText((Join-Path $shimBin "exakit.cmd"),
    "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$missing`" %*`r`n",
    [System.Text.Encoding]::ASCII)
Check "shim: an old-format shim is not current" "False" (Test-ExakitCmdShimCurrent -PsTarget $missing)
$shimPath = Set-ExakitCmdShim -PsTarget $missing
Check "shim: the rewritten shim is current" "True" (Test-ExakitCmdShimCurrent -PsTarget $missing)
$cmdExe = Get-Command cmd.exe -ErrorAction SilentlyContinue
if ($cmdExe) {
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $out = & cmd.exe /d /c "`"$shimPath`" version" 2>&1 | Out-String -Width 4096
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    Check "shim (cmd.exe): prints the leftover message" "True" ($out -match 'exakit is no longer installed here \(its files are gone\), so this leftover launcher')
    Check "shim (cmd.exe): no -File error" "False" ($out -match 'does not exist')
    Check "shim (cmd.exe): exits non-zero" "True" ($code -ne 0)
    Check "shim (cmd.exe): deleted itself" "False" (Test-Path -LiteralPath $shimPath)
} else {
    Write-Host "  skip shim (cmd.exe): not on Windows"
}
$script:BinDir = $savedBin

# --- mcp-doctor: a failed record over a database that answers ------------
# The launcher says deployment_failed, the probe answers and the port is
# provably this deployment's own runner: mcp-doctor checks against it (with one
# warning). Any one missing - or no runner proof on this side at all - and it
# does not. Twin of the shell check in tests/personal-agent-contract.sh.
Write-Host ""
Write-Host "mcp-doctor: deployment_failed while the database answers:"
$script:stubState = "deployment_failed"; $script:stubAnswers = $true; $script:stubOwn = $true
function Get-PersonalLauncherState { $script:stubState }
function Test-PersonalDbAnswers { $script:stubAnswers }
# The shipped Windows twin proves nothing (the port is the engine relay's).
$rpText = Get-Content -Raw (Join-Path $repo "setup/lib/runtime-personal.ps1")
Check "doctor: the Windows runner proof always says no" "True" ($rpText -match 'function Test-PersonalPortHeldByOwnRunner \{\s*return \$false')
$script:probed = 0
function Test-PersonalDbAnswers { $script:probed++; $script:stubAnswers }
function Test-PersonalPortHeldByOwnRunner { $false }
Check "doctor: no runner proof on this side -> not reachable" "False" (Test-ExakitMcpDoctorFailedRecordAnswers -RuntimeType "personal")
Check "doctor: no runner proof -> the database is never probed" "0" $script:probed
function Test-PersonalPortHeldByOwnRunner { $script:stubOwn }
Check "doctor: failed record, answers, own runner -> reachable" "True" (Test-ExakitMcpDoctorFailedRecordAnswers -RuntimeType "personal")
$script:stubOwn = $false
Check "doctor: ...not the own runner -> not reachable" "False" (Test-ExakitMcpDoctorFailedRecordAnswers -RuntimeType "personal")
$script:stubOwn = $true; $script:stubAnswers = $false
Check "doctor: ...database silent -> not reachable" "False" (Test-ExakitMcpDoctorFailedRecordAnswers -RuntimeType "personal")
$script:stubAnswers = $true; $script:stubState = "stopped"
Check "doctor: ...launcher says stopped -> not reachable" "False" (Test-ExakitMcpDoctorFailedRecordAnswers -RuntimeType "personal")
$script:stubState = "deployment_failed"
Check "doctor: ...not a personal runtime -> not reachable" "False" (Test-ExakitMcpDoctorFailedRecordAnswers -RuntimeType "")
Remove-Item Function:\Test-PersonalPortHeldByOwnRunner -ErrorAction SilentlyContinue
$cliText = Get-Content -Raw (Join-Path $repo "setup/exakit.ps1")
Check "doctor: the mcp-doctor arm asks it" "True" ($cliText.Contains('if (-not $doctorUp -and (Test-ExakitMcpDoctorFailedRecordAnswers -RuntimeType $doctorType)) {'))
Check "doctor: and says the one warning" "True" ($cliText.Contains('Exasol marked this database as failed, but it is running. To clear that, run: exakit start (it restarts the database; your data is kept).'))
$cliText = Get-Content -Raw (Join-Path $repo "setup/exakit.ps1")
Check "uninstall: says the commands go as the window closes" "True" ($cliText.Contains('are removed when you close this window: '))
Check "uninstall: deferred cleaner starts outside the job (Win32_Process Create)" "True" ($cliText -match 'Invoke-CimMethod -ClassName Win32_Process -MethodName Create')

# --- the deferred delete, run for real (Windows only) ----------------------
# The checks above read the source. This one runs Remove-ExakitBinariesDeferred
# in a child powershell under a cmd.exe - the exakit.cmd shape - and waits for
# the detached cleaner to remove the sandbox files once both have exited.
if ($cmdExe) {
    Write-Host ""
    Write-Host "deferred delete (cmd.exe)"
    $ddDir = Join-Path $sandbox "deferred"
    New-Item -ItemType Directory -Force -Path $ddDir | Out-Null
    $ddA = Join-Path $ddDir "a.exe"; $ddB = Join-Path $ddDir "exakit.cmd"
    foreach ($f in @($ddA, $ddB)) { Set-Content -Path $f -Value "x" }
    $cliAst = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repo "setup/exakit.ps1"), [ref]$null, [ref]$null)
    $ddDef = $cliAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Name -eq "Remove-ExakitBinariesDeferred" }, $true) | Select-Object -First 1
    $ddChild = Join-Path $ddDir "child.ps1"
    $qA = $ddA -replace "'", "''"; $qB = $ddB -replace "'", "''"
    Set-Content -Path $ddChild -Value ($ddDef.Extent.Text + "`r`nRemove-ExakitBinariesDeferred -Paths @('$qA', '$qB')`r`nexit 0`r`n")
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & cmd.exe /d /c "powershell -NoProfile -ExecutionPolicy Bypass -File `"$ddChild`"" 2>&1 | Out-Null
    $ErrorActionPreference = $prevEap
    for ($i = 0; $i -lt 40 -and ((Test-Path -LiteralPath $ddA) -or (Test-Path -LiteralPath $ddB)); $i++) { Start-Sleep -Milliseconds 500 }
    Check "deferred delete (cmd.exe): the binary is gone" "False" (Test-Path -LiteralPath $ddA)
    Check "deferred delete (cmd.exe): the shim is gone" "False" (Test-Path -LiteralPath $ddB)
} else {
    Write-Host "  skip deferred delete (cmd.exe): not on Windows"
}

# --- exakit uninstall <addon-id>: its staged <id>.cmd.new goes too -------
Write-Host ""
Write-Host "exakit uninstall <addon-id> removes its staged launcher:"
Seed
function Get-ExakitMarketplaceAddon { param([string]$Id) if ($Id -eq "dash-server") { [pscustomobject]@{ Id = "dash-server"; UninstallFn = "Uninstall-FakeDash" } } }
function Uninstall-FakeDash { param([switch]$DryRun) if (-not $DryRun) { Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $script:BinDir "dash-server.cmd") } }
function Test-ExakitMarketplaceAddonInstalled { param([string]$Id) $true }
function Remove-ExakitAddonSkills { param([string]$Id) }
function Initialize-ExakitLogging { }
function Show-ExakitHomeNotice { }
# The skill it placed (the kit's copy in one agent folder) and its boot entry (stubbed as registered above): the
# removal takes both, so the preview names both - it once listed the add-on's own lines only.
function Get-ExakitSkillsForAddon { param([string]$Id) if ($Id -eq "dash-server") { @("dash-server") } }
function Test-ExakitSkillIsKits { param([string]$Root, [string]$Name) $true }
$addonSkill = Join-Path (Join-Path $HOME ".claude\skills") "dash-server"
New-Item -ItemType Directory -Force -Path $addonSkill | Out-Null
$script:dryInfo = @()
function Info($m) { $script:dryInfo += "$m" }
$script:ManifestPath = Join-Path $script:ExakitHome "manifest.json"
Invoke-CmdUninstall -Addon "dash-server" -DryRun
function Info($m) {}
Check "addon dry: lists its staged .cmd.new" "True" (($script:dryInfo -join "`n").Contains("will remove: staged launcher " + (Join-Path $script:BinDir "dash-server.cmd.new")))
Check "addon dry: names its boot entry" "True" (($script:dryInfo -join "`n").Contains("will remove: the automatic-start entry for dash-server"))
Check "addon dry: names the skill it placed" "True" (($script:dryInfo -join "`n").Contains("will remove: AI skill $addonSkill"))
Check "addon dry: and no skill folder it did not place" "False" (($script:dryInfo -join "`n").Contains(".agents"))
Check "addon dry: the skill is kept" "yes" (Ex $addonSkill)
Check "addon dry: the staged .cmd.new is kept" "yes" (Ex (Join-Path $script:BinDir "dash-server.cmd.new"))
Invoke-ExakitUninstallComponent -Key "dash-server"
Check "addon: its staged .cmd.new is gone" "no" (Ex (Join-Path $script:BinDir "dash-server.cmd.new"))
Check "addon: exakit.cmd.new is not its to remove" "yes" (Ex (Join-Path $script:BinDir "exakit.cmd.new"))
Check "addon: a bystander .cmd.new stays" "yes" (Ex (Join-Path $script:BinDir "some-other-tool.cmd.new"))
Check "addon: exakit.cmd stays" "yes" (Ex (Join-Path $script:BinDir "exakit.cmd"))
# F2: an add-on that refuses its own removal (semantic-views with a model
# defined) says why as a failure line through Fail, as bash's die does - the
# exception used to reach the top-level handler, printed "Unexpected error".
$refusalText = "dash-server: 1 semantic model(s) are defined in the database: they are your work, so nothing was removed."
function Uninstall-FakeDash { param([switch]$DryRun) if (-not $DryRun) { throw $refusalText } }
$script:failed = @()
function Fail($m) { $script:failed += "$m"; throw "FAIL-CARD" }
$escaped = ""
try { Invoke-CmdUninstall -Addon "dash-server" -AssumeYes } catch { $escaped = "$_" }
function Fail($m) { throw $m }
Check "F2: an add-on's own refusal is a Fail line, its sentence as it is" $refusalText ($script:failed -join "|")
Check "...not an exception for the Unexpected error handler" "FAIL-CARD" $escaped
# --- another exakit run of this kit blocks a full uninstall (named, never stopped) ---
Write-Host ""
Write-Host "another exakit run of this kit blocks a full uninstall:"
$kitPs1 = Join-Path $script:ExakitHome "kit\setup\exakit.ps1"
$script:fakeProcs = @(
    [pscustomobject]@{ ProcessId = 900;  ParentProcessId = 1;    Name = "cmd.exe";        CommandLine = "cmd.exe /c `"$($script:BinDir)\exakit.cmd`" uninstall -Yes" },
    [pscustomobject]@{ ProcessId = $PID; ParentProcessId = 900;  Name = "powershell.exe"; CommandLine = "powershell.exe -NoProfile -File `"$kitPs1`" uninstall -Yes" },
    [pscustomobject]@{ ProcessId = 4241; ParentProcessId = 1;    Name = "cmd.exe";        CommandLine = "cmd.exe /c `"$($script:BinDir)\exakit.cmd`" connect" },
    [pscustomobject]@{ ProcessId = 4242; ParentProcessId = 4241; Name = "powershell.exe"; CommandLine = "powershell.exe -NoProfile -File `"$kitPs1`" connect --name pg" },
    [pscustomobject]@{ ProcessId = 4243; ParentProcessId = $PID; Name = "powershell.exe"; CommandLine = "powershell.exe -NoProfile -File `"$kitPs1`" mcp-doctor" },
    [pscustomobject]@{ ProcessId = 4250; ParentProcessId = 1;    Name = "cmd.exe";        CommandLine = "cmd.exe /K `"$($script:BinDir)\exakit.cmd`" start" },
    [pscustomobject]@{ ProcessId = 4251; ParentProcessId = 1;    Name = "notepad.exe";    CommandLine = "notepad.exe `"$kitPs1`"" },
    [pscustomobject]@{ ProcessId = 4252; ParentProcessId = 1;    Name = "powershell.exe"; CommandLine = "powershell.exe -File C:\elsewhere\setup\exakit.ps1 connect" }
)
function Get-CimInstance { param([string]$ClassName, [string]$Filter, $ErrorAction) $script:fakeProcs }
$runs = @(Get-ExakitUninstallOtherRuns)
Check "other runs: only the open connect counts" "4242" (($runs | ForEach-Object { $_.Pid }) -join ",")
Check "other runs: named by its command" "exakit connect --name pg" (($runs | ForEach-Object { $_.Command }) -join ",")
$script:warned = @()
function Warn2($m) { $script:warned += "$m" }
Check "blocked: true while it runs" "True" ("" + (Test-ExakitUninstallBlocked))
Check "blocked: the line names it and what to do" "exakit is still running in another window: exakit connect --name pg (pid 4242). Close it, then run exakit uninstall again." ($script:warned -join "|")
$script:fakeProcs = @($script:fakeProcs | Where-Object { $_.ProcessId -ne 4242 })
$script:warned = @()
Check "not blocked: this run, its parents, children, idle shells, editors and another kit's exakit" "False" ("" + (Test-ExakitUninstallBlocked))
Check "not blocked: nothing named" "" ($script:warned -join "|")
Remove-Item Function:\Get-CimInstance
# The refusal comes before anything is removed and answers 1; read off the
# command's own source (an exit would end this suite).
$cmdAst = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Invoke-CmdUninstall" }, $true).Extent.Text
$iBlock = $cmdAst.IndexOf("Test-ExakitUninstallBlocked")
$iRun = $cmdAst.IndexOf("Invoke-ExakitUninstallRun")
Check "refusal: checked before the first removal" "True" ("" + ($iBlock -gt 0 -and $iBlock -lt $iRun))
Check "refusal: exits 1 with nothing removed" "True" ("" + ($cmdAst -match 'if \(\$blocked -and -not \$DryRun\) \{\s*Info "Nothing was removed\."\s*exit 1'))
# --- the Claude permission rules: uninstall removes every rule the install wrote ---
# The real writer and remover, run against the sandboxed profile. Uninstall used
# to miss the 14 `tls-pin` rules (12 Bash spellings, 2 PowerShell): only a
# round trip through both functions catches a rule added to one and not the other.
foreach ($name in @('Test-ExakitLegacyAllowlistRule','Write-ExakitSettingsJson','Get-ExakitAgentHome','Set-ExakitReadonlyAllowlist','Remove-ExakitReadonlyAllowlist','Invoke-ExakitReadonlyAllowlist')) {
    $definition = $commonAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    Invoke-Expression $definition.Extent.Text
}
$claudeDir = Join-Path $fakeProfile ".claude"
New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
$settings = Join-Path $claudeDir "settings.json"
Set-Content -Path $settings -Value '{"permissions": {"allow": ["Bash(git status:*)", "Bash(exakit tls-pin --accept)"], "deny": ["Bash(rm -rf:*)"]}, "theme": "dark"}'
# A fresh kit: nothing recorded yet, and the kit's Claude Code entry is the
# one named exasol-starter-kit beside the user's own exasol.
$script:rulesManifest = '{"components": {"skills": {}, "mcp_server": {"managed_state": {"artifacts": [{"client": "claude_code", "metadata": {"entry_name": "exasol-starter-kit", "server": "exasol"}}]}}}}' | ConvertFrom-Json
[void](Set-ExakitReadonlyAllowlist)
$allowed = @((Get-Content -Raw $settings | ConvertFrom-Json).permissions.allow)
Check "rules: the MCP tools only for the kit's entry" "mcp__exasol-starter-kit" ((@($allowed | Where-Object { "$_" -like "mcp__*" })) -join "|")
Check "rules: mcp-doctor only as the report, in every spelling" "7 0" ("" + @($allowed | Where-Object { "$_" -like "*mcp-doctor --json)" }).Count + " " + @($allowed | Where-Object { "$_" -like "*mcp-doctor:*" }).Count)
$written = @((Get-Content -Raw $settings | ConvertFrom-Json).permissions.allow | Where-Object { "$_" -like "*tls-pin*" -and "$_" -ne "Bash(exakit tls-pin --accept)" })
Check "rules: the install writes the tls-pin rules" "14" $written.Count
[void](Remove-ExakitReadonlyAllowlist)
$doc = Get-Content -Raw $settings | ConvertFrom-Json
Check "rules: uninstall leaves only the user's own" "Bash(git status:*)|Bash(exakit tls-pin --accept)|Bash(rm -rf:*)|dark" ((@($doc.permissions.allow) + @($doc.permissions.deny) + @($doc.theme)) -join "|")
Check "rules: a second uninstall removes nothing" "REMOVED 0" (Remove-ExakitReadonlyAllowlist)
# A settings file holding non-ASCII text, BOM-less UTF-8 as Claude Code writes
# it: Windows PowerShell 5.1 read it in the ANSI code page and the merge wrote
# "Jos\u00c3\u00a9" back for "Jos\u00e9". Both the install and the uninstall keep it.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$nonAscii = "C:\Users\Jos" + [char]0x00E9 + "\" + [char]0x65E5 + [char]0x672C + "\hook.cmd"
$nonAsciiJson = ConvertTo-Json @{ permissions = @{ allow = @("Bash(git status:*)") }; hooks = @{ cmd = $nonAscii } } -Depth 5
[System.IO.File]::WriteAllText($settings, $nonAsciiJson, $utf8NoBom)
[void](Set-ExakitReadonlyAllowlist)
$doc = [System.IO.File]::ReadAllText($settings, $utf8NoBom) | ConvertFrom-Json
Check "rules: the install keeps non-ASCII text in the user's settings" "True True" ("" + ($doc.hooks.cmd -ceq $nonAscii) + " " + (@($doc.permissions.allow).Count -gt 1))
[void](Remove-ExakitReadonlyAllowlist)
$doc = [System.IO.File]::ReadAllText($settings, $utf8NoBom) | ConvertFrom-Json
Check "rules: ...and so does the uninstall" "True Bash(git status:*)" ("" + ($doc.hooks.cmd -ceq $nonAscii) + " " + (@($doc.permissions.allow) -join "|"))

# --- the dispatch arm refuses an option it does not know (audit WPS-05) ------
# `exakit uninstall --yes --dry-rnu` and `-Yes -WhatIf` used to run the real,
# complete uninstall with exit 0: the arm read the switches it knew and dropped
# the rest. The CLI itself, in a child process, against a sandboxed kit home
# holding a manifest and a marker file: each line must exit 2 and remove
# nothing. Every home the child could resolve points into the sandbox, and a
# stub dir first on PATH answers for the engines, so even a regression stays
# inside it.
$cliSandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-uninst-cli-" + [guid]::NewGuid())
$cliKit = Join-Path $cliSandbox "home\.exasol-starter-kit"
$cliStubs = Join-Path $cliSandbox "stubs"
New-Item -ItemType Directory -Force -Path $cliKit, $cliStubs | Out-Null
foreach ($tool in @("docker", "podman", "exasol", "launchctl", "systemctl", "schtasks", "wsl")) {
    $stub = Join-Path $cliStubs $tool
    Set-Content -Path $stub -Value "#!/bin/sh`necho STUB-BLOCKED`nexit 97"
    Set-Content -Path "$stub.cmd" -Value "@echo STUB-BLOCKED`r`n@exit /b 97"
    if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) { & chmod +x $stub }
}
Set-Content -Path (Join-Path $cliKit "manifest.json") -Value '{"kit": {"version": "0.0.0"}}'
$cliMarker = Join-Path $cliKit "marker.txt"
Set-Content -Path $cliMarker -Value "keep"
$cliEnvNames = @("HOME", "USERPROFILE", "LOCALAPPDATA", "APPDATA", "EXAKIT_HOME", "EXAKIT_BIN_DIR", "EXAKIT_NO_UPDATE_NOTICE", "PATH")
$cliSaved = @{}
foreach ($n in $cliEnvNames) { $cliSaved[$n] = [Environment]::GetEnvironmentVariable($n) }
$cliHomeDir = Join-Path $cliSandbox "home"
$env:HOME = $cliHomeDir; $env:USERPROFILE = $cliHomeDir
$env:LOCALAPPDATA = Join-Path $cliHomeDir "AppData\Local"; $env:APPDATA = Join-Path $cliHomeDir "AppData\Roaming"
$env:EXAKIT_HOME = $cliKit; $env:EXAKIT_BIN_DIR = Join-Path $cliHomeDir ".local\bin"
$env:EXAKIT_NO_UPDATE_NOTICE = "1"
$env:PATH = $cliStubs + [System.IO.Path]::PathSeparator + $env:PATH
$engine = (Get-Process -Id $PID).Path
$cli = Join-Path $repo "setup/exakit.ps1"
foreach ($case in @(
    @{ Args = @("uninstall", "--yes", "--dry-rnu"); Says = "Unknown option '--dry-rnu' for uninstall" },
    @{ Args = @("uninstall", "-Yes", "-WhatIf");    Says = "Unknown option '-WhatIf' for uninstall" },
    @{ Args = @("uninstall", "--yes", "--keep-data"); Says = "Unknown option '--keep-data' for uninstall" },
    @{ Args = @("uninstall", "--yes", "dash-server", "dash-server"); Says = "uninstall takes at most one add-on id." }
)) {
    $label = "cli: exakit $($case.Args -join ' ')"
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $out = (& $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $cli @($case.Args) 2>&1 | Out-String -Width 4096)
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    Check "$label exits 2" "2" $code
    Check "$label names the refusal" "True" ("" + $out.Contains($case.Says))
    Check "$label removes nothing" "True" ("" + ((Test-Path $cliMarker) -and (Test-Path (Join-Path $cliKit "manifest.json"))))
}
foreach ($n in $cliEnvNames) { [Environment]::SetEnvironmentVariable($n, $cliSaved[$n]) }
Remove-Item -Recurse -Force $cliSandbox -ErrorAction SilentlyContinue

# --- an interrupted first install (receipt state=installing) is removable (audit MKT-06) ---
# `exakit uninstall <id>` answered "not installed - nothing to remove", so the
# schemas or the extension that install had made could not be removed with the
# kit. Invoke-CmdUninstall in a child (it can exit), with the real registry,
# the real hook body and Invoke-ExakitMarketplacePython; only the service
# process is a stand-in that answers as the add-on module does for partial
# objects (what it removed, one per line).
Write-Host ""
Write-Host "an interrupted add-on install is removed by exakit uninstall <id>:"
$intWork = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-uninst-int-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $intWork | Out-Null
$intChild = Join-Path $intWork "child.ps1"
$repoQ = $repo -replace "'", "''"; $intQ = $intWork -replace "'", "''"
Set-Content -LiteralPath $intChild -Value @"
param([string]`$Addon, [string]`$State, [switch]`$DryRun, [switch]`$List)
`$ErrorActionPreference = 'Stop'
foreach (`$file in @('setup/lib/exakit-common.ps1','setup/exakit.ps1')) {
    `$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path '$repoQ' `$file), [ref]`$null, [ref]`$null)
    foreach (`$fn in `$ast.FindAll({ param(`$n) `$n -is [Management.Automation.Language.FunctionDefinitionAst] -and `$n.Extent.Text -match '^\s*(function|filter)\s' }, `$true)) { Invoke-Expression `$fn.Extent.Text }
}
`$script:ExakitMarketplaceSourceRoot = '$repoQ'
`$script:ExakitHome = Join-Path '$intQ' 'kit'
`$script:BinDir = Join-Path '$intQ' 'bin'
`$script:ManifestPath = Join-Path `$script:ExakitHome 'manifest.json'
`$script:ExakitHookMemo = @{}
New-Item -ItemType Directory -Force `$script:ExakitHome, `$script:BinDir | Out-Null
Set-Content -LiteralPath `$script:ManifestPath '{}'
`$key = Get-ExakitOwnershipKey `$Addon
`$script:manifest = @{}
if (`$State) { `$script:manifest["`$key.ownership"] = 'kit'; `$script:manifest["`$key.state"] = `$State }
function Get-ExakitManifestValue([string]`$Path) { return `$script:manifest[`$Path] }
# The module's installed-version answer for a receipt with no version: not installed.
function Test-ExakitMarketplaceAddonInstalled(`$Id) { `$false }
function Get-ExakitUvBin { 'Invoke-FakeService' }
function Invoke-FakeService {
    Add-Content -LiteralPath (Join-Path '$intQ' 'service-calls') -Value (`$args -join ' ')
    if (`$args -contains '--dry-run') { 'the objects the interrupted install made, where present' }
    elseif (`$Addon -eq 'semantic-views') { 'schema SEMANTIC_ADMIN'; 'schema SYS_SEMANTIC'; 'role SEMANTIC_USER' }
    else { '  ' + [char]0x2022 + ' Removing Exasol for VS Code'; 'exasol.exasol-vscode' }
    `$global:LASTEXITCODE = 0
}
`$stem = ((`$Addon -split '-') | ForEach-Object { `$_.Substring(0, 1).ToUpperInvariant() + `$_.Substring(1) }) -join ''
Set-Item -Path "Function:Global:Invoke-Marketplace`${stem}Uninstall" -Value ([scriptblock]::Create("param([switch]```$DryRun) Invoke-ExakitMarketplacePython -Id '`$Addon' -Operation 'uninstall' -DryRun ```$DryRun.IsPresent"))
function Write-ExakitAddonRemovalPreview { param([string]`$Id) }
function Remove-ExakitAddonSkills { param([string]`$Id) }
function Unregister-ExakitAutostart { param([string]`$Id) }
function Write-ExakitLog { }
function Initialize-ExakitLogging { }
function Show-ExakitHomeNotice { }
# Write-Host, as the real ones: a hook's output is discarded, its lines are not.
function Info(`$m) { Write-Host "INFO `$m" }
function Ok(`$m) { Write-Host "OK `$m" }
function Warn2(`$m) { Write-Host "WARN `$m" }
if (`$List) { Write-Output ("REMOVABLE " + (@(Get-ExakitMarketplaceRemovableAddons) -join ',')); exit 0 }
Invoke-CmdUninstall -Addon `$Addon -AssumeYes:(-not `$DryRun) -DryRun:`$DryRun
exit 0
"@
$intEngine = (Get-Process -Id $PID).Path
$intCalls = Join-Path $intWork "service-calls"
foreach ($intCase in @(
    @{ Id = "semantic-views"; Removed = "schema SEMANTIC_ADMIN, schema SYS_SEMANTIC, role SEMANTIC_USER" },
    @{ Id = "exasol-vscode";  Removed = "exasol.exasol-vscode" }
)) {
    $id = $intCase.Id
    $previous = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    Remove-Item -Force $intCalls -ErrorAction SilentlyContinue
    $out = (& $intEngine -NoProfile -ExecutionPolicy Bypass -File $intChild -Addon $id -State installing -DryRun 2>&1 | Out-String -Width 4096)
    $rc = $LASTEXITCODE
    $calls = if (Test-Path $intCalls) { Get-Content -Raw $intCalls } else { "" }
    $ErrorActionPreference = $previous
    Check "$($id) installing, --dry-run: exits 0" "0" $rc
    Check "$($id) installing, --dry-run: never says not installed" "False" ("" + $out.Contains("is not installed"))
    Check "$($id) installing, --dry-run: names the interrupted install" "True" ("" + $out.Contains("Dry run - the $id install was interrupted; removing what it created would:"))
    Check "$($id) installing, --dry-run: the add-on's own preview, nothing removed" "True" ("" + ($out.Contains("will remove: the objects the interrupted install made") -and $calls.Contains("$id uninstall --dry-run")))
    $previous = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    Remove-Item -Force $intCalls -ErrorAction SilentlyContinue
    $out = (& $intEngine -NoProfile -ExecutionPolicy Bypass -File $intChild -Addon $id -State installing 2>&1 | Out-String -Width 4096)
    $rc = $LASTEXITCODE
    $calls = if (Test-Path $intCalls) { Get-Content -Raw $intCalls } else { "" }
    $ErrorActionPreference = $previous
    Check "$($id) installing, --yes: exits 0" "0" $rc
    Check "$($id) installing, --yes: the add-on's own removal ran" "True" ("" + ($calls.Contains("$id uninstall") -and -not $calls.Contains("--dry-run")))
    Check "$($id) installing, --yes: reports what it removed" "True" ("" + $out.Contains("OK Removed what the interrupted $id install had created: $($intCase.Removed)."))
    $previous = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    $out = (& $intEngine -NoProfile -ExecutionPolicy Bypass -File $intChild -Addon $id -State installing -List 2>&1 | Out-String -Width 4096)
    $ErrorActionPreference = $previous
    Check "$($id) installing: the whole-kit uninstall and its menu list it" "True" ("" + ($out -match "REMOVABLE [a-z,-]*\b$id\b"))
    $previous = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    Remove-Item -Force $intCalls -ErrorAction SilentlyContinue
    $out = (& $intEngine -NoProfile -ExecutionPolicy Bypass -File $intChild -Addon $id 2>&1 | Out-String -Width 4096)
    $rc = $LASTEXITCODE
    $ErrorActionPreference = $previous
    Check "$($id) with no receipt: still not installed, exit 0" "True 0" ("" + $out.Contains("INFO $id is not installed - nothing to remove.") + " " + $rc)
    Check "$($id) with no receipt: nothing ran" "False" ("" + (Test-Path $intCalls))
}
Remove-Item -Recurse -Force $intWork -ErrorAction SilentlyContinue

Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "PASS=$($script:PASS) FAIL=$($script:FAIL)"
if ($script:FAIL -ne 0) { exit 1 }
