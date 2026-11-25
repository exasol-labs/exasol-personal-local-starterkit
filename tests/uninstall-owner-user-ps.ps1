#!/usr/bin/env pwsh
# uninstall-owner-user-ps.ps1 - the Windows twin of tests/uninstall-owner-user.sh:
# what `exakit uninstall` does to a database the user let the kit use (owner
# user), and to the kit's own launcher (D4).
#
#   pwsh -NoProfile -File tests/uninstall-owner-user-ps.ps1
#
# Pinned here:
#   owner user   never destroyed (Remove-Personal is never called) and it keeps
#                its name starter-kit-local (D5). SEC-01 runs inside it through
#                the real marketplace/kit_logins.py, before the add-ons go: the
#                kit's read-only login and the Scheduler's are dropped (their
#                sessions killed first), a role the kit created goes unless one
#                of the user's own users holds it, every schema such a login or
#                role owns goes to SYS first, nothing with CASCADE, no
#                connection or schema dropped; the connection is listed with the
#                statement that drops it. The add-ons' own removal then runs
#                with EXAKIT_UNINSTALL_KEEP_DATABASE=1. A dry run lists the
#                steps and runs no statement. A stopped database is never
#                started: the statements are printed for later, in order.
#   D4           the kit's own exasol.exe stays while another deployment uses
#                it, and the line says which; a folder with no launcher state
#                does not count; with none it goes as before; a launcher that
#                is not the kit's is kept as before. Next to a launcher of the
#                user's it goes only when theirs is readable and on the 2.5 line
#                or newer
#   component    the database arm of Invoke-ExakitUninstallComponent checks the
#                owner itself before Remove-Personal
#   prune        (Windows only) the 2.5.0 launcher root is recognised by its
#                folder, not by the deployment's name in it
#
# Functions are pulled from the real files through the AST (definitions only,
# never top-level code); every external is a stub, HOME is a fresh sandbox, and
# the database is a stand-in (tests/lib/fake-kit-logins-db.py).

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected [$expected], got [$actual]" }
}
function Has($label, $needle, $lines) {
    if (@($lines) -contains $needle) { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): no line [$needle] in:"; foreach ($l in @($lines)) { Write-Host "         $l" } }
}
function Lacks($label, $needle, $text) {
    if ("$text".Contains($needle)) { $script:FAIL++; Write-Host "  FAIL $($label): must not contain [$needle]" }
    else { $script:PASS++; Write-Host "  ok   $label" }
}

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
foreach ($t in (Get-FunctionTexts (Join-Path $repo "setup/exakit.ps1"))) { Invoke-Expression $t }
foreach ($t in (Get-FunctionTexts (Join-Path $repo "setup/lib/runtime-personal.ps1") @("Get-PersonalPrunableStateDirs", "Get-PersonalVersionLine", "Test-PersonalVersionOutranks"))) { Invoke-Expression $t }
foreach ($t in (Get-FunctionTexts (Join-Path $repo "setup/lib/exakit-common.ps1") @("Resolve-PersonalDeployDir", "Get-ExakitProfileHome", "Get-PersonalDeploymentName"))) { Invoke-Expression $t }

# --- sandbox --------------------------------------------------------------
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-owner-user-" + [guid]::NewGuid())
$fakeHome = Join-Path $sandbox "home"
Set-Variable -Name HOME -Value $fakeHome -Scope Global -Force
$script:ExakitHome = Join-Path $fakeHome ".exasol-starter-kit"
$script:ManifestPath = Join-Path $script:ExakitHome "manifest.json"
$script:BinDir = Join-Path (Join-Path $fakeHome ".local") "bin"
$root25 = Join-Path (Join-Path (Join-Path $fakeHome "exasol") "launcher") "deployments"
$deploy = Join-Path $root25 "starter-kit-local"
$script:PersonalDeployDir = $deploy
$env:EXAKIT_STARTUP_DIR = Join-Path $fakeHome "Startup"
$env:APPDATA = Join-Path $fakeHome "AppData-Roaming"
$env:LOCALAPPDATA = Join-Path $fakeHome "AppData-Local"
$dbState = Join-Path $sandbox "db-state.json"
$dbLog = Join-Path $sandbox "db.log"
$env:EXAKIT_KIT_LOGINS_FAKE_DB = Join-Path (Join-Path $repo "tests") (Join-Path "lib" "fake-kit-logins-db.py")
$env:EXAKIT_FAKE_DB_STATE = $dbState
$env:EXAKIT_FAKE_DB_LOG = $dbLog
$onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
$script:py = $null
$pyNames = @("python3", "python")
if ($onWindows) { $pyNames = @("python", "python3") }
foreach ($candidate in $pyNames) {
    $cmd = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $script:py = $cmd.Source; break }
}
if (-not $script:py) { throw "python3 is needed (marketplace/kit_logins.py)" }

# --- stubs ----------------------------------------------------------------
$script:out = @()
$script:ExakitQuietDetail = $false
# Info is quiet inside the run's quiet bracket, as on screen; InfoStep, OkStep
# and Warn2 still print.
function Info($m) { if ($script:ExakitQuietDetail) { return }; $script:out += "INFO $m" }
function Ok($m) { $script:out += "OK $m" }
function OkStep($m) { $script:out += "OK $m" }
function InfoStep($m) { $script:out += "INFO $m" }
function Warn2($m) { $script:out += "WARN $m" }
function Fail($m) { throw $m }
function Write-ExakitLog { param($Level, $Message) }
function Get-ExakitTilde([string]$Path) { $Path }
function Get-ExakitManifestValue {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $script:ManifestPath)) { return "" }
    $node = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
    foreach ($key in $Path.Split(".")) {
        if ($null -eq $node -or -not $node.PSObject.Properties[$key]) { return "" }
        $node = $node.$key
    }
    return $node
}
function Get-RuntimeType { "personal" }
function Get-ExakitRepoRoot { return $null }
function Get-ExakitMarketplaceRoot { return $repo }
function Update-PersonalDeployDir { }
$script:managed = @{}
function Test-ExakitComponentManaged { param([string]$Id) return [bool]$script:managed[$Id] }
function Write-ExakitPreservedComponent { param([string]$Id) Info "Leaving $Id as it is (the kit did not install it, or has no record that it did)." }
function Get-ExakitPreservedComponentPaths { @() }
$script:kitDbState = ""
function Get-ExakitPersonalDbState { return $script:kitDbState }
function Get-ExakitPersonalKitMissing { return "" }
$script:removed = $false
function Remove-Personal { $script:removed = $true; Remove-Item -Recurse -Force -LiteralPath $script:PersonalDeployDir -ErrorAction SilentlyContinue }
function Get-PersonalLauncherLeftovers { [pscustomobject]@{ Cache = ""; CacheSize = ""; Dirs = @() } }
# The launcher's folders: every entry beside the kit's own, as the real one lists them.
function Get-PersonalOtherDeployments {
    @(Get-ChildItem -LiteralPath $root25 -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName.TrimEnd('\', '/') -ne $script:PersonalDeployDir.TrimEnd('\', '/') } |
        ForEach-Object { $_.FullName })
}
function Get-ExakitUninstallKitImageIds { return $null }
function Invoke-ExakitUninstallKitImages { param([switch]$DryRun, $Record) }
function Get-PersonalEngineRecorded { return "" }
function Read-PersonalDeploymentId { param([string]$Dir) return "" }
# Every bounded run, as "<path> <arguments> <seconds>", and what each launcher
# answers (a launcher not named here answers nothing: not readable).
$script:bounded = @()
$script:answers = @{}
function Invoke-ExakitBounded {
    param([string]$FilePath, [string[]]$Arguments = @(), [string]$ArgumentString = "", [int]$TimeoutSeconds = 8)
    $script:bounded += "$FilePath $($Arguments -join ' ') $TimeoutSeconds"
    return "" + $script:answers[$FilePath]
}
function Get-PersonalTargetVersion { return "2.5.0" }
$script:PersonalProbeTimeout = 10
function Invoke-McpOperation { param($Operation, $InputArgs) return $true }
# The launcher the real one runs is the kit's, in the kit's folder: was it
# there when the MCP server was removed (OWN-05)?
$script:sidecarLauncher = ""
function Remove-McpSidecar { param([switch]$DryRun) $script:sidecarLauncher = "" + (Test-Path -LiteralPath $script:PersonalSeparateBinPath) }
function Remove-ExakitBinariesDeferred { param([string[]]$Paths) foreach ($f in $Paths) { Remove-Item -Force -ErrorAction SilentlyContinue $f } }
function Get-ExakitServiceIds { @() }
function Test-ExakitAutostartRegistered { param([string]$Id) $false }
function Unregister-ExakitAutostart { param([string]$Id) }
function Get-ExakitStartupDir { return $env:EXAKIT_STARTUP_DIR }
function Get-ExakitAutostartPrefix { return "com.exasol.exakit" }
# $script:withAddon: one kit-managed add-on to remove, which writes when it ran
# (into the database log, so its place among the statements shows) and
# whether the run told it to keep the database.
$script:withAddon = $false
function Get-ExakitMarketplaceInstalledAddons { if ($script:withAddon) { @("semantic-views") } else { @() } }
function Get-ExakitMarketplaceRemovableAddons { if ($script:withAddon) { @("semantic-views") } else { @() } }
function Get-ExakitMarketplaceAddon {
    param([string]$Id)
    if ($script:withAddon -and $Id -eq "semantic-views") { return [pscustomobject]@{ Id = $Id; UninstallFn = "Invoke-FakeSemanticViewsUninstall" } }
    return $null
}
function Invoke-FakeSemanticViewsUninstall {
    param([switch]$DryRun)
    Add-Content -LiteralPath $dbLog -Value ("ADDON semantic-views dry=" + [int][bool]$DryRun + " keep=" + $env:EXAKIT_UNINSTALL_KEEP_DATABASE)
}
function Save-ExakitAddonSkillKits { param([string[]]$Ids) }
function Get-ExakitMarketplaceAddons { @() }
function Get-ExakitKitSkillNames { @() }
function Get-ExakitSkillRoots { @() }
function Remove-ExakitReadonlyAllowlist { return "REMOVED 0" }
function Start-ExakitSpinner { param([string]$Label) }
function Stop-ExakitSpinner { }
function Set-ExakitSpinnerLabel { param([string]$Label) }
function Get-ExakitProcessList { @() }
function Stop-ExakitPidQuiet { param([int]$Id) return $true }
function Test-ExakitSkillIsKits { param([string]$Root, [string]$Name) $false }
# The kit's Python step, as Invoke-ExakitPythonFile runs it: stdout lines and the exit code.
function Invoke-ExakitPythonFile {
    param([string]$Path, [string[]]$Arguments = @(), [switch]$Live)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { $lines = @(& $script:py $Path @Arguments 2>$null); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous }
    return [pscustomobject]@{ Code = $code; Lines = @($lines | ForEach-Object { "$_" }) }
}

# Seed [-Other demo|stray] [-Down] [-Owner user|kit] [-Launcher kit|user] - a fresh sandbox.
# The kit's own separate program (mode S, next to a 2.4 of the user's), as
# runtime-personal.ps1 spells it.
$script:PersonalSeparateBinPath = [IO.Path]::Combine($script:ExakitHome, "personal", "bin", "exasol.exe")
function Seed {
    param([string]$Other = "", [switch]$Down, [string]$Owner = "user", [string]$Launcher = "kit", [switch]$Separate, [switch]$Theirs, [switch]$NoBinLauncher)
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -Recurse -Force -LiteralPath $sandbox }
    foreach ($d in @($script:BinDir, (Join-Path $script:ExakitHome "credentials"), (Join-Path (Join-Path $script:ExakitHome "sources") "sales"), (Join-Path $deploy "data"))) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }
    Set-Content -LiteralPath (Join-Path (Join-Path $script:ExakitHome "credentials") "runtime_sys_password") -Value "not-a-real-password"
    Set-Content -LiteralPath (Join-Path (Join-Path (Join-Path $script:ExakitHome "sources") "sales") "config.json") -Value '{"objects": {"connection": "EXAKIT_SRC_SALES", "schema": "VS_SALES"}}'
    Set-Content -LiteralPath (Join-Path $deploy ".exasolLauncherState.json") -Value '{"deploymentId": "abcd1234"}'
    Set-Content -LiteralPath (Join-Path (Join-Path $deploy "data") "table.dat") -Value "the user data"
    foreach ($bin in @("exasol.exe", "exakit.cmd")) {
        if ($bin -eq "exasol.exe" -and $NoBinLauncher) { continue }
        Set-Content -LiteralPath (Join-Path $script:BinDir $bin) -Value "fixture"
    }
    if ($Separate -or $Theirs) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:PersonalSeparateBinPath) | Out-Null
        Set-Content -LiteralPath $script:PersonalSeparateBinPath -Value "the kit's own 2.5"
    }
    if ($Other -eq "demo") {
        $demo = Join-Path $root25 "demo"
        New-Item -ItemType Directory -Force -Path $demo | Out-Null
        Set-Content -LiteralPath (Join-Path $demo ".exasolLauncherState.json") -Value '{"deploymentId": "feed0001"}'
    } elseif ($Other -eq "stray") {
        New-Item -ItemType Directory -Force -Path (Join-Path $root25 "notes") | Out-Null
    }
    $manifest = [ordered]@{
        runtime = [ordered]@{ type = "personal"; user = "sys"; dsn = "127.0.0.1:8563"; ownership = $Owner; ownership_path = $deploy
                              deployment_dir = $deploy; password_file = (Join-Path (Join-Path $script:ExakitHome "credentials") "runtime_sys_password") }
        components = [ordered]@{
            mcp_server = @{ connection = @{ user = "mcp_readonly" } }
            semantic_views = @{ role_created = $true; ownership = "kit" }
            exasol_scheduler = @{ ownership = "kit"; db_user = "scheduler_svc"; schema = "SCHED" }
            preprocessor = @{ origin = "kit"; state = "active" }
            pyexasol = @{ python = $script:py }
            personal = $(if ($Theirs) { @{ ownership = $Launcher; ownership_path = $script:PersonalSeparateBinPath; user_launcher = (Join-Path $script:BinDir "exasol.exe") } }
                         else { @{ ownership = $Launcher; ownership_path = $(if ($Separate) { $script:PersonalSeparateBinPath } else { (Join-Path $script:BinDir "exasol.exe") }) } })
        }
    }
    Set-Content -LiteralPath $script:ManifestPath -Value ($manifest | ConvertTo-Json -Depth 6)
    $downText = "false"
    if ($Down) { $downText = "true" }
    Set-Content -LiteralPath $dbState -Value ('{"down": ' + $downText + ', "users": ["MCP_READONLY", "SCHEDULER_SVC", "THEIR_ANALYST"], ' +
        '"sessions": {"MCP_READONLY": [41, 42]}, ' +
        '"roles": {"SEMANTIC_USER": ["MCP_READONLY", "THEIR_ANALYST"], "PREPROC_ADMIN": ["SYS"]}, ' +
        '"owners": {"PREPROC": "PREPROC_ADMIN", "PREPROC_RT": "PREPROC_ADMIN", "SCHED": "SCHEDULER_SVC", "THEIRS": "THEIR_ANALYST"}, ' +
        '"connections": ["EXAKIT_SRC_SALES", "THEIR_OWN"], "schemas": ["VS_SALES"], "slot": "PREPROC_RT.MASTER"}')
    $script:managed = @{ database = ($Owner -eq "kit"); exasol = ($Launcher -eq "kit"); exapump = $true; "semantic-views" = $true }
    $script:kitDbState = ""
    $script:removed = $false
    $script:out = @()
    $script:ExakitQuietDetail = $false
}
function Statements { if (Test-Path -LiteralPath $dbLog) { return @(Get-Content -LiteralPath $dbLog) } return @() }
# Writes: every statement but the reads. marketplace/kit_logins.py's dry run
# may ask the database which schemas each login and role owns (SELECT only),
# so a dry run is pinned by its writes.
function Writes { return @(@(Statements) | Where-Object { -not "$_".StartsWith("SELECT ") }) }
# Before <first> <second> <lines> - "yes" when the line <first> comes before the line <second>.
function Before([string]$First, [string]$Second, $Lines) {
    $all = @($Lines)
    $a = [array]::IndexOf($all, $First); $b = [array]::IndexOf($all, $Second)
    if ($a -ge 0 -and $b -ge 0 -and $a -lt $b) { return "yes" }
    return "no"
}
function Ex($p) { if (Test-Path -LiteralPath $p) { "kept" } else { "gone" } }
$exasolExe = Join-Path $script:BinDir "exasol.exe"

try {
    Write-Host "owner user, a real run: the database stays as it is, the kit's logins inside it go"
    Seed
    Invoke-ExakitUninstallRun
    Check "the database is never torn down" "False" $script:removed
    Check "it keeps its folder, name and data (D5)" "the user data" ((Get-Content -LiteralPath (Join-Path (Join-Path $deploy "data") "table.dat")) -join "")
    $sql = Statements
    Check "the read-only login's sessions end before its drop" "yes" (Before "KILL SESSION 41" 'DROP USER "MCP_READONLY"' $sql)
    Has "...its CREATE SESSION revoked" 'REVOKE CREATE SESSION FROM "MCP_READONLY"' $sql
    Check "the Scheduler's schema goes to SYS before its login is dropped" "yes" (Before 'ALTER SCHEMA "SCHED" CHANGE OWNER SYS' 'DROP USER "SCHEDULER_SVC"' $sql)
    Check "PREPROC goes to SYS before the role is dropped" "yes" (Before 'ALTER SCHEMA "PREPROC" CHANGE OWNER SYS' 'DROP ROLE "PREPROC_ADMIN"' $sql)
    Check "PREPROC_RT goes to SYS before the role is dropped" "yes" (Before 'ALTER SCHEMA "PREPROC_RT" CHANGE OWNER SYS' 'DROP ROLE "PREPROC_ADMIN"' $sql)
    $owners = (Get-Content -LiteralPath $dbState -Raw | ConvertFrom-Json).owners
    Check "the framework's schemas and the Scheduler's are SYS's now, theirs untouched" "SYS SYS SYS THEIR_ANALYST" "$($owners.PREPROC) $($owners.PREPROC_RT) $($owners.SCHED) $($owners.THEIRS)"
    Lacks "a role one of their own users holds stays" 'DROP ROLE "SEMANTIC_USER"' ($sql -join "`n")
    Lacks "their own schema keeps its owner" 'ALTER SCHEMA "THEIRS"' ($sql -join "`n")
    Lacks "nothing with CASCADE" "CASCADE" ($sql -join "`n")
    Lacks "no connection dropped" "DROP CONNECTION" ($sql -join "`n")
    Has "the record line names the logins" "OK Removed the kit's logins MCP_READONLY and SCHEDULER_SVC from your database 'starter-kit-local'" $script:out
    Has "the Scheduler's schema stays, said" "INFO The schema SCHED stays in your database, now owned by SYS." $script:out
    Has "the dropped role is said" "OK Removed the role PREPROC_ADMIN from your database 'starter-kit-local'" $script:out
    Has "its schemas stay, said" "INFO The schemas PREPROC and PREPROC_RT stay in your database, now owned by SYS." $script:out
    Has "the kept role is said, with who holds it" "INFO The role SEMANTIC_USER stays in your database: THEIR_ANALYST holds it." $script:out
    Has "the connection is listed with its DROP statement" "INFO The connection EXAKIT_SRC_SALES stays in your database. To remove it: DROP CONNECTION EXAKIT_SRC_SALES;" $script:out
    Has "D4: the kit's launcher stays, and the line says why" "INFO Keeping the Exasol Personal launcher: your deployment 'starter-kit-local' still uses it." $script:out
    Check "...and exasol.exe is still there" "kept" (Ex $exasolExe)
    Check "...while the rest of the commands go" "gone" (Ex (Join-Path $script:BinDir "exakit.cmd"))
    Lacks "no password on the screen" "not-a-real-password" ($script:out -join "`n")

    Write-Host ""
    Write-Host "owner user, a dry run: the steps, and nothing changed"
    Seed
    Invoke-ExakitUninstallRun -DryRun
    Has "the database is kept, by name" "INFO Keeping your database 'starter-kit-local' and all its data. It keeps the name 'starter-kit-local'." $script:out
    Has "the login drop is a step" "INFO   will remove: the kit's login MCP_READONLY in your database 'starter-kit-local' (DROP USER)" $script:out
    Has "the Scheduler's login, its schema handed over first" "INFO   will remove: the kit's login SCHEDULER_SVC in your database 'starter-kit-local'. Its schema SCHED stays and goes to SYS first (ALTER SCHEMA SCHED CHANGE OWNER SYS, then DROP USER)" $script:out
    Has "the role drop is a step, with its condition" "INFO   will remove: the role SEMANTIC_USER in your database 'starter-kit-local', unless one of your own users holds it (DROP ROLE)" $script:out
    Has "the framework's role, its schemas handed over first" "INFO   will remove: the role PREPROC_ADMIN in your database 'starter-kit-local', unless one of your own users holds it. Its schemas PREPROC and PREPROC_RT stay and go to SYS first (ALTER SCHEMA ... CHANGE OWNER SYS for each, then DROP ROLE)" $script:out
    Has "the connection is listed" "INFO   The connection EXAKIT_SRC_SALES stays in your database. To remove it: DROP CONNECTION EXAKIT_SRC_SALES;" $script:out
    Has "Semantic Views stays" "INFO   The Semantic Views schemas and their models stay in your database." $script:out
    Lacks "the plan never lists the launcher for removal" "will remove: CLI binary $exasolExe" ($script:out -join "`n")
    Check "nothing but reads reached the database" "0" (@(Writes).Count)
    Check "the kit home is still there" "kept" (Ex $script:ManifestPath)

    Write-Host ""
    Write-Host "owner user, the database is stopped: never started, the statements printed for later"
    Seed -Down
    Invoke-ExakitUninstallRun
    Has "it says the database is not running" "WARN Your database 'starter-kit-local' is not running, so the kit's logins in it were not removed." $script:out
    $later = @($script:out)
    $start = [array]::IndexOf($later, "INFO Remove them once it runs, as sys:")
    $expected = @("INFO Remove them once it runs, as sys:",
        "INFO   DROP USER IF EXISTS MCP_READONLY;",
        "INFO   ALTER SCHEMA SCHED CHANGE OWNER SYS;  -- if SCHEDULER_SVC owns it",
        "INFO   DROP USER IF EXISTS SCHEDULER_SVC;",
        "INFO   -- only if none of your own users needs the role SEMANTIC_USER:",
        "INFO   DROP ROLE IF EXISTS SEMANTIC_USER;",
        "INFO   -- only if none of your own users needs the role PREPROC_ADMIN:",
        "INFO   ALTER SCHEMA PREPROC CHANGE OWNER SYS;",
        "INFO   ALTER SCHEMA PREPROC_RT CHANGE OWNER SYS;",
        "INFO   DROP ROLE IF EXISTS PREPROC_ADMIN;")
    # A module that names the schemas the records do not (it cannot ask a
    # stopped database) adds one comment line per login and role, before its
    # DROP: the same lines as the bash twin pins.
    if (([IO.File]::ReadAllText((Join-Path $repo "marketplace/kit_logins.py"))).Contains("def _any_other(")) {
        $expected = @("INFO Remove them once it runs, as sys:",
            "INFO   -- any schema MCP_READONLY owns: ALTER SCHEMA <name> CHANGE OWNER SYS;",
            "INFO   DROP USER IF EXISTS MCP_READONLY;",
            "INFO   ALTER SCHEMA SCHED CHANGE OWNER SYS;  -- if SCHEDULER_SVC owns it",
            "INFO   -- any other schema SCHEDULER_SVC owns: ALTER SCHEMA <name> CHANGE OWNER SYS;",
            "INFO   DROP USER IF EXISTS SCHEDULER_SVC;",
            "INFO   -- only if none of your own users needs the role SEMANTIC_USER:",
            "INFO   -- any schema SEMANTIC_USER owns: ALTER SCHEMA <name> CHANGE OWNER SYS;",
            "INFO   DROP ROLE IF EXISTS SEMANTIC_USER;",
            "INFO   -- only if none of your own users needs the role PREPROC_ADMIN:",
            "INFO   ALTER SCHEMA PREPROC CHANGE OWNER SYS;",
            "INFO   ALTER SCHEMA PREPROC_RT CHANGE OWNER SYS;",
            "INFO   -- any other schema PREPROC_ADMIN owns: ALTER SCHEMA <name> CHANGE OWNER SYS;",
            "INFO   DROP ROLE IF EXISTS PREPROC_ADMIN;")
    }
    $got = ""
    if ($start -ge 0) { $got = ($later[$start..([Math]::Min($start + $expected.Count - 1, $later.Count - 1))]) -join "|" }
    Check "...and what to run once it does, in the order a real run takes" ($expected -join "|") $got
    Lacks "...never CASCADE" "CASCADE" ($script:out -join "`n")
    Check "nothing was run" "0" (@(Statements).Count)
    Check "the database is still there" "kept" (Ex (Join-Path (Join-Path $deploy "data") "table.dat"))

    Write-Host ""
    Write-Host "owner user: SEC-01 first, then the add-ons, which leave the database alone"
    $script:withAddon = $true
    Seed
    Invoke-ExakitUninstallRun
    $sql = Statements
    Check "the add-on goes after the kit's logins and roles" "yes" (Before 'DROP ROLE "PREPROC_ADMIN"' "ADDON semantic-views dry=0 keep=1" $sql)
    Has "...and it is removed" "OK Add-ons removed: semantic-views" $script:out
    Check "...and the switch is gone after the run" "" ("" + $env:EXAKIT_UNINSTALL_KEEP_DATABASE)
    Seed
    Invoke-ExakitUninstallRun -DryRun
    Check "a dry run tells it the same (the logins' plan only reads the database)" "ADDON semantic-views dry=1 keep=1" ((Writes) -join "|")
    Seed -Owner kit
    Invoke-ExakitUninstallRun
    Has "the kit's own database: the add-on's removal is as before" "ADDON semantic-views dry=0 keep=" (Statements)
    $script:withAddon = $false

    Write-Host ""
    Write-Host "the database the kit may not act on (kit_database_missing): no statement"
    Seed
    $script:kitDbState = "kit_database_missing|x|y"
    Invoke-ExakitUninstallRun
    Check "no statement reached that database" "0" (@(Statements).Count)
    Lacks "no SEC-01 line" "Removed the kit's login" ($script:out -join "`n")
    Seed
    $script:kitDbState = "kit_database_missing|x|y"
    Invoke-ExakitUninstallRun -DryRun
    Has "it is left as it is" "INFO Leaving database as it is (the kit did not install it, or has no record that it did)." $script:out
    Lacks "...and no step inside it is planned" "will remove: the kit's login" ($script:out -join "`n")

    Write-Host ""
    Write-Host "D4, owner kit: exasol.exe stays while another deployment uses it"
    Seed -Owner kit -Other demo
    Invoke-ExakitUninstallRun
    Check "the kit's database is torn down" "True" $script:removed
    Has "the line names the deployment that still uses the launcher" "INFO Keeping the Exasol Personal launcher: your deployment 'demo' still uses it." $script:out
    Check "exasol.exe is kept" "kept" (Ex $exasolExe)
    Check "their deployment stays" "kept" (Ex (Join-Path (Join-Path $root25 "demo") ".exasolLauncherState.json"))
    Check "no statement: the kit's own database is destroyed, not cleaned" "0" (@(Statements).Count)
    Seed -Owner kit -Other stray
    Invoke-ExakitUninstallRun
    Lacks "a folder with no launcher state does not keep it" "Keeping the Exasol Personal launcher" ($script:out -join "`n")
    Check "...and exasol.exe goes as before" "gone" (Ex $exasolExe)
    Seed -Owner kit
    Invoke-ExakitUninstallRun
    Lacks "no other deployment: no line" "Keeping the Exasol Personal launcher" ($script:out -join "`n")
    Check "...and exasol.exe goes" "gone" (Ex $exasolExe)
    # Mode S (Krishna, Q2): the kit's own 2.5 as a separate program next to
    # their 2.4. Their 2.4 does not find a deployment in the 2.5 folder, so the
    # kit's stays for it (DOC-01), in the kit's folder, and their exasol.exe at
    # the kit's default path is never touched.
    Seed -Owner kit -Other demo -Theirs
    $script:answers = @{ $exasolExe = "2.4.0" }
    Invoke-ExakitUninstallRun
    Has "mode S, their 2.4: the D4 line" "INFO Keeping the Exasol Personal launcher: your deployment 'demo' still uses it." $script:out
    Check "...the kit's program stays in the kit's folder, their exasol.exe as it was" "kept|fixture" ("{0}|{1}" -f (Ex $script:PersonalSeparateBinPath), ((Get-Content -Raw -LiteralPath $exasolExe).Trim()))
    Check "...the rest of the kit home goes" "personal" ((Get-ChildItem -LiteralPath $script:ExakitHome -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join "|")
    Check "...and their deployment stays" "kept" (Ex (Join-Path (Join-Path $root25 "demo") ".exasolLauncherState.json"))
    Seed -Owner kit -Other demo -Theirs
    $script:answers = @{ $exasolExe = "2.5.0" }
    Invoke-ExakitUninstallRun
    Check "their 2.5 there: the kit's own separate program goes" "gone" (Ex $script:PersonalSeparateBinPath)
    Lacks "...no D4 line for their deployments" "Keeping the Exasol Personal launcher" ($script:out -join "`n")
    Check "...their exasol.exe at the kit's default path stays" "kept" (Ex $exasolExe)
    Check "...and their deployment stays" "kept" (Ex (Join-Path (Join-Path $root25 "demo") ".exasolLauncherState.json"))
    $script:answers = @{}
    # The kit's own launcher in the kit's folder (K, never on PATH), kept for
    # a deployment of theirs (D4): the kit's folder goes, so it moves to
    # %USERPROFILE%\.local\bin\exasol.exe when nothing is there.
    Seed -Owner kit -Other demo -Separate -NoBinLauncher
    Invoke-ExakitUninstallRun
    Has "D4, the kit's folder launcher: the line" "INFO Keeping the Exasol Personal launcher: your deployment 'demo' still uses it." $script:out
    Check "...still in the kit's folder while the MCP server is removed with it" "True" $script:sidecarLauncher
    Check "...moved to .local\bin\exasol.exe" "kept|the kit's own 2.5" ("{0}|{1}" -f (Ex $exasolExe), ((Get-Content -Raw -LiteralPath $exasolExe).Trim()))
    # A file there already: the kit's launcher stays in the kit's folder,
    # which the sweep leaves, and the file there is not touched.
    Seed -Owner kit -Other demo -Separate
    Invoke-ExakitUninstallRun
    Has "D4, a file at .local\bin already: the line" "INFO Keeping the Exasol Personal launcher: your deployment 'demo' still uses it." $script:out
    Check "...the kit's launcher stays in the kit's folder, the file there as it was" "kept|fixture" ("{0}|{1}" -f (Ex $script:PersonalSeparateBinPath), ((Get-Content -Raw -LiteralPath $exasolExe).Trim()))
    # #41: A LAUNCHER OF THE USER'S IS NEVER DELETED OR MOVED, whatever the
    # record says: theirs at .local\bin, with the kit's own in its folder and
    # no receipt for it (a lost record, an install cut short).
    foreach ($case in @('none', 'unknown', 'user')) {
        Seed -Owner kit -Separate
        $doc = Get-Content -Raw -LiteralPath $script:ManifestPath | ConvertFrom-Json
        $doc.components.personal = [pscustomobject]@{}
        if ($case -ne 'none') { $doc.components.personal = [pscustomobject]@{ ownership = $case; ownership_path = $exasolExe } }
        Set-Content -LiteralPath $script:ManifestPath -Value ($doc | ConvertTo-Json -Depth 6)
        & {
            function Get-PersonalSeparateBinPath { return $script:PersonalSeparateBinPath }
            function Get-PersonalCli { return $script:PersonalSeparateBinPath }
            Invoke-ExakitUninstallRun
        }
        Check "the kit's launcher in its folder, receipt '$case': theirs at .local\bin as it was, the kit's gone" "fixture|gone" ("{0}|{1}" -f $(if (Test-Path -LiteralPath $exasolExe) { (Get-Content -Raw -LiteralPath $exasolExe).Trim() }), (Ex $script:PersonalSeparateBinPath))
    }
    # D4 NEXT TO A LAUNCHER OF THE USER'S (DOC-01): the kit's goes only when
    # theirs can open the deployments that stay, so only when its version is
    # readable and on the 2.5 line or newer. Theirs is asked `version` only,
    # time-bounded, and its file is the same afterwards. The launchers of this
    # computer are taken off PATH for it.
    $pathBefore = $env:PATH
    $cleanPath = @($env:PATH -split [IO.Path]::PathSeparator | Where-Object {
        $_ -and -not (Test-Path -LiteralPath (Join-Path $_ "exasol")) -and -not (Test-Path -LiteralPath (Join-Path $_ "exasol.exe")) }) -join [IO.Path]::PathSeparator
    $theirsDir = Join-Path $fakeHome "theirs"
    $theirsExe = Join-Path $theirsDir $(if ($onWindows) { "exasol.exe" } else { "exasol" })
    # SeedTheirs <owner> <version|unread|none> <on|off>: a launcher of theirs on
    # PATH, or off PATH and on record.
    function SeedTheirs([string]$Owner, [string]$Version, [string]$Where) {
        $env:PATH = $cleanPath
        if ($Owner -eq "kit") { Seed -Owner kit -Other demo -Separate -NoBinLauncher } else { Seed -Separate -NoBinLauncher }
        $script:bounded = @()
        $script:answers = @{}
        if ($Version -ne "none") {
            New-Item -ItemType Directory -Force -Path $theirsDir | Out-Null
            Set-Content -LiteralPath $theirsExe -Value "theirs $Version"
            if (-not $onWindows) { & /bin/chmod +x $theirsExe }
            $script:answers[$theirsExe] = $(if ($Version -eq "unread") { "Error: no such command" } else { "$Version`nbuilt today" })
        }
        if ($Where -eq "on") { $env:PATH = $theirsDir + [IO.Path]::PathSeparator + $cleanPath }
        else {
            $doc = Get-Content -Raw -LiteralPath $script:ManifestPath | ConvertFrom-Json
            $doc.components.personal | Add-Member -NotePropertyName user_launcher -NotePropertyValue $theirsExe
            Set-Content -LiteralPath $script:ManifestPath -Value ($doc | ConvertTo-Json -Depth 6)
        }
    }
    foreach ($owner in @("user", "kit")) {
        $name = $(if ($owner -eq "kit") { "demo" } else { "starter-kit-local" })
        foreach ($where in @("on", "off")) {
            foreach ($version in @("2.4.0", "v2.4.9", "1.9", "unread", "2", "none", "2.5.0", "v2.5.3", "2.6.0", "2.10.1", "3.0.0")) {
                $label = "owner $owner, theirs $version $where PATH"
                SeedTheirs $owner $version $where
                Invoke-ExakitUninstallRun
                if (@("2.5.0", "v2.5.3", "2.6.0", "2.10.1", "3.0.0") -contains $version) {
                    Lacks "${label}: no line" "Keeping the Exasol Personal launcher" ($script:out -join "`n")
                    Check "${label}: the kit's launcher goes" "gone|gone" ("{0}|{1}" -f (Ex $script:PersonalSeparateBinPath), (Ex $exasolExe))
                } else {
                    Has "${label}: the line names the deployment" "INFO Keeping the Exasol Personal launcher: your deployment '$name' still uses it." $script:out
                    Check "${label}: the kit's launcher is at .local\bin\exasol.exe" "the kit's own 2.5" $(if (Test-Path -LiteralPath $exasolExe) { (Get-Content -Raw -LiteralPath $exasolExe).Trim() })
                }
                Check "${label}: the deployment stays" "kept" (Ex (Join-Path (Join-Path $root25 $name) ".exasolLauncherState.json"))
                if ($version -ne "none") {
                    Check "${label}: theirs is as it was" "theirs $version" ((Get-Content -Raw -LiteralPath $theirsExe).Trim())
                    Check "${label}: ...and asked its version only, time-bounded" "$theirsExe version 10" ((@($script:bounded) | Where-Object { "$_".StartsWith($theirsExe) } | Sort-Object -Unique) -join "|")
                }
            }
        }
    }
    SeedTheirs "user" "2.4.0" "on"
    Invoke-ExakitUninstallRun -DryRun
    Has "their 2.4, a dry run: the same line" "INFO Keeping the Exasol Personal launcher: your deployment 'starter-kit-local' still uses it." $script:out
    Check "...nothing changed" "kept|kept" ("{0}|{1}" -f (Ex $script:PersonalSeparateBinPath), (Ex $script:ManifestPath))
    SeedTheirs "user" "2.4.0" "on"
    $theirs25 = Join-Path $fakeHome "theirs25.exe"
    Set-Content -LiteralPath $theirs25 -Value "theirs 2.5.1"
    $script:answers[$theirs25] = "2.5.1"
    $doc = Get-Content -Raw -LiteralPath $script:ManifestPath | ConvertFrom-Json
    $doc.components.personal | Add-Member -NotePropertyName user_launcher -NotePropertyValue $theirs25
    Set-Content -LiteralPath $script:ManifestPath -Value ($doc | ConvertTo-Json -Depth 6)
    Invoke-ExakitUninstallRun
    Lacks "a 2.4 on PATH, a 2.5 of theirs on record: no line" "Keeping the Exasol Personal launcher" ($script:out -join "`n")
    if (-not $onWindows) {
        SeedTheirs "user" "none" "on"
        New-Item -ItemType Directory -Force -Path $theirsDir | Out-Null
        New-Item -ItemType SymbolicLink -Path $theirsExe -Target $script:PersonalSeparateBinPath | Out-Null
        & /bin/chmod +x $script:PersonalSeparateBinPath
        $script:answers[$theirsExe] = "2.5.0"
        Invoke-ExakitUninstallRun
        Has "a link on PATH to the kit's own launcher is not theirs: the line" "INFO Keeping the Exasol Personal launcher: your deployment 'starter-kit-local' still uses it." $script:out
    }
    $env:PATH = $pathBefore
    $script:answers = @{}
    Seed -Owner kit -Other demo -Launcher user
    Invoke-ExakitUninstallRun -DryRun
    Has "a launcher that is not the kit's is kept as before" "INFO Keeping $exasolExe (not installed by this kit)." $script:out
    Lacks "...with no D4 line" "Keeping the Exasol Personal launcher" ($script:out -join "`n")

    Write-Host ""
    Write-Host "the component removal checks the owner in its database arm"
    $fn = (Get-Command Invoke-ExakitUninstallComponent).Definition
    $arm = $fn.Substring($fn.IndexOf('"database" {'))
    $guard = $arm.IndexOf('if (-not (Test-ExakitComponentManaged "database"))')
    $teardown = $arm.IndexOf('Remove-Personal')
    Check "the owner check comes before Remove-Personal" "True" (($guard -ge 0) -and ($guard -lt $teardown))
    Seed
    Invoke-ExakitUninstallComponent -Key "database"
    Check "a database the user let the kit use is never torn down" "False" $script:removed

    Write-Host ""
    Write-Host "the record of who made the read-only login, written at setup"
    # marketplace/kit_logins.py drops only a login the kit created. Setup
    # records it: Set-McpReadonlyAccess with its database calls stubbed, the
    # login there or not, every other check passing. Twin of the same block
    # in uninstall-owner-user.sh.
    foreach ($t in (Get-FunctionTexts (Join-Path $repo "setup/lib/mcp.ps1") @("Set-McpReadonlyAccess", "Test-ExakitIdentifier", "ConvertTo-SqlLiteral", "Get-FirstSchema", "Test-ExakitSqlPasswordToken"))) { Invoke-Expression $t }
    foreach ($t in (Get-FunctionTexts (Join-Path $repo "setup/lib/exakit-common.ps1") @("ConvertTo-UpperInvariantString"))) { Invoke-Expression $t }
    $mcpWork = Join-Path $sandbox "mcp-setup"
    New-Item -ItemType Directory -Force -Path $mcpWork | Out-Null
    $mcpAdminPw = Join-Path $mcpWork "admin-pw"
    Set-Content -LiteralPath $mcpAdminPw -Value "pw" -NoNewline
    # McpSetup <present> [<recorded user> [<recorded created>]]: the record
    # after the setup, "none" when it writes none.
    function McpSetup([bool]$Present, [string]$User = "", $Created = $null, [string]$MadeIn = "") {
        $script:mcpMf = @{ "runtime.user" = "sys"; "runtime.password_file" = $mcpAdminPw; "runtime.deployment_id" = "exa-this" }
        if ($MadeIn) { $script:mcpMf["components.mcp_server.connection.made_in"] = $MadeIn }
        if ($User) { $script:mcpMf["components.mcp_server.connection.user"] = $User }
        if ($null -ne $Created) { $script:mcpMf["components.mcp_server.connection.created"] = $Created }
        $script:mcpSql = @()
        $script:mcpPresent = $Present
        $script:mcpThrew = ""
        & {
            function Get-ExakitManifestValue([string]$Path) { return $script:mcpMf[$Path] }
            function Set-ExakitManifestValue([string]$Path, $Value) { $script:mcpMf[$Path] = $Value }
            function Test-ExakitStdoutIsTerminal { return $false }
            function Get-ExakitExapumpBin { return (Join-Path $mcpWork "exapump.exe") }
            function Ensure-ExakitOnPath { param([string]$Dir) }
            function Get-RuntimeHost { return "localhost" }
            function Get-RuntimePort { return "8563" }
            function Get-ExakitCredential { param([string]$Name) return "A1234567890ABCDEFGHIJKLM" }
            function Set-ExakitCredential { }
            function Set-ExapumpTomlSection { }
            function Protect-ExakitFile { param([string]$Path) }
            function Get-ExakitTlsFingerprint { return "" }
            function Invoke-ExapumpAdminSql { param($ConfigPath, $Profile, $Sql) $script:mcpSql += (("" + $Sql) -split ' IDENTIFIED BY ')[0]; return [pscustomobject]@{ Code = 0; Output = "" } }
            function Assert-ExapumpResult { }
            function Test-ExapumpSqlHasToken { param($ConfigPath, $Profile, $Sql, $Token) if (("" + $Sql).Contains("EXAKIT_MCP_USER_PRESENT")) { return $script:mcpPresent }; return $true }
            function Assert-McpReadonlyPosture { }
            $script:McpReadonlyUser = "mcp_readonly"
            $script:McpReadonlySchemas = "STARTER_KIT"
            $script:CredsDir = $mcpWork
            try { Set-McpReadonlyAccess *> $null } catch { $script:mcpThrew = "$($_.Exception.Message)" }
        }
        $c = $script:mcpMf["components.mcp_server.connection.created"]
        if ($script:mcpThrew) { return "THREW $($script:mcpThrew)" }
        if ($null -eq $c) { return "none" }
        return ("" + $c).ToLowerInvariant()
    }
    Check "a login made now (CREATE USER): created true" "true" (McpSetup $false)
    Check "...it ran CREATE USER" "True" (@($script:mcpSql) -contains "CREATE USER MCP_READONLY")
    Check "a login that was there, no record of it: taken over, created false" "false" (McpSetup $true)
    Check "...a record of another login proves nothing: false" "false" (McpSetup $true "bi_reader" $true)
    Check "the kit's own login again, its record says created: stays true" "true" (McpSetup $true "mcp_readonly" $true)
    Check "a 0.3.0 record of the same login (no flag): none made up" "none" (McpSetup $true "mcp_readonly")
    # Which database it was made in (OWN-07): a record from another one says
    # nothing about the login of that name in this one.
    Check "made in this database: stays true, and says so" "true|exa-this" ("{0}|{1}" -f (McpSetup $true "mcp_readonly" $true "exa-this"), $script:mcpMf["components.mcp_server.connection.made_in"])
    Check "made in another database, the login there: not the kit's" "false|exa-this" ("{0}|{1}" -f (McpSetup $true "mcp_readonly" $true "exa-other"), $script:mcpMf["components.mcp_server.connection.made_in"])
    Check "made in another database, none here: made now, the kit's" "true|exa-this" ("{0}|{1}" -f (McpSetup $false "mcp_readonly" $true "exa-other"), $script:mcpMf["components.mcp_server.connection.made_in"])
    Check "a 0.3.0 record whose database became another one: not the kit's" "false" (McpSetup $true "mcp_readonly" $null "exa-other")

    if ($onWindows) {
        Write-Host ""
        Write-Host "prune: the 2.5.0 root is recognised by its folder (Windows)"
        Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue
        $kit25 = Join-Path $env:LOCALAPPDATA "exasol\launcher\deployments\starter-kit-local"
        New-Item -ItemType Directory -Force -Path $kit25 | Out-Null
        $script:PersonalDeployDir = $kit25
        $pruned = @(Get-PersonalPrunableStateDirs | ForEach-Object { Split-Path -Leaf $_ })
        Check "deployments, launcher and exasol go once the kit's database is gone" "deployments|launcher|exasol" ($pruned -join "|")
        $script:PersonalDeployDir = $deploy
    }
} finally {
    Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue
    foreach ($name in @("EXAKIT_KIT_LOGINS_FAKE_DB", "EXAKIT_FAKE_DB_STATE", "EXAKIT_FAKE_DB_LOG", "EXAKIT_STARTUP_DIR")) {
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "uninstall-owner-user-ps.ps1: PASS=$($script:PASS) FAIL=$($script:FAIL)"
if ($script:FAIL -gt 0) { exit 1 }
