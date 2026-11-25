#!/usr/bin/env pwsh
# personal-update-rename-ps.ps1 - the Windows twin of personal-update-rename.sh:
# the update from a 0.3.0 kit. The database the 0.3.0 kit uses becomes the
# deployment starter-kit-local on Exasol Personal 2.5, in one restart, and
# nothing 2.5 runs before its folder has its new name.
#   owner kit   the kit's own 2.4 launcher: stopped with it, `default` renamed
#               in its root, the launcher swapped (checksum checked), the
#               folder moved by the new launcher's first command and followed
#               by its id, the 20-session limit lifted while stopped, started
#               once, only when it ran
#   current     a launcher at 2.5 already, `default` in the 2.5 root (or still
#               in the older root): renamed there, no swap
#   named       a database already starter-kit-local: no rename
#   target      a starter-kit-local in the way: nothing changed
#   undo        a swap that fails (bad checksum, a launcher that does not run,
#               one that moved the folder first): the launcher, the folder's
#               name and the records put back, started again only when it ran
#   in use      a launcher file another program runs, which Windows does not
#               replace: nothing changed (or put back), and `exakit update`
#               asked for again; a kit swapped under the run defers the row
#   owner user  a database the user let the 0.3.0 kit use, run by their own
#               2.4: their launcher replaced in place and kept theirs; one
#               that cannot be replaced is left as it is, with nothing changed
#   installer   the installer run again over a 0.3.0 kit takes the same steps
#   --json      the rows: updated, or deferred with the reason
#   mcp         the MCP sidecar a 0.3.0 kit set up (and kept no record of) is
#               recorded as the kit's when it proves it, so the uninstall
#               removes it; one the user set up is never claimed
#
#   pwsh -NoProfile -File tests/personal-update-rename-ps.ps1
#
# Function definitions only, in a scratch profile (USERPROFILE, LOCALAPPDATA)
# and kit home, with an in-memory manifest and a stand-in launcher: a launcher
# file holds its version, and the launcher calls (Invoke-ExakitBounded,
# Invoke-ExakitLogged) answer as that version does, 2.5 moving the stopped
# deployments of the older root on every command but help, as the real one
# does (startup_migration.go). No real launcher, database, container, port or
# kit home is touched, and nothing is downloaded. PowerShell 5.1 compatible.

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([IO.Path]::GetTempPath()) ('exakit-pur-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -ceq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$expected>, got <$actual>" }
}
function Has($label, $needle, $haystack) {
    if ("$haystack".Contains("$needle")) { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): <$needle> not in <$haystack>" }
}
function Hasnt($label, $needle, $haystack) {
    if (-not "$haystack".Contains("$needle")) { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): <$needle> in <$haystack>" }
}
function YN([bool]$Value) { if ($Value) { return 'yes' }; return 'no' }

$savedEnv = @{}
$envNames = @('USERPROFILE', 'LOCALAPPDATA', 'APPDATA', 'EXAKIT_STARTUP_DIR', 'EXAKIT_PERSONAL_DEPLOY_DIR', 'EXAKIT_PERSONAL_VERSION',
    'EXAKIT_CONFIRM_RUNTIME_UPDATE', 'EXAKIT_FORCE_COMPONENT_INSTALL', 'EXAKIT_PERSONAL_S3', 'EXAKIT_CORE_RERUN', 'EXAKIT_REUSE_DB')
foreach ($name in $envNames) { $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name) }
$env:USERPROFILE = Join-Path $work 'profile'
$env:LOCALAPPDATA = Join-Path (Join-Path $env:USERPROFILE 'AppData') 'Local'
$env:APPDATA = Join-Path (Join-Path $env:USERPROFILE 'AppData') 'Roaming'
# W4-01: this machine's own Startup entries are never in reach.
$env:EXAKIT_STARTUP_DIR = Join-Path $work 'Startup'
foreach ($name in @('EXAKIT_PERSONAL_DEPLOY_DIR', 'EXAKIT_PERSONAL_VERSION', 'EXAKIT_CONFIRM_RUNTIME_UPDATE', 'EXAKIT_FORCE_COMPONENT_INSTALL',
                    'EXAKIT_PERSONAL_S3', 'EXAKIT_CORE_RERUN', 'EXAKIT_REUSE_DB')) {
    Remove-Item "Env:$name" -ErrorAction SilentlyContinue
}

try {
    # Definitions only: nothing initializes against the real profile.
    foreach ($file in @('setup/lib/exakit-common.ps1', 'setup/lib/runtime-personal.ps1', 'setup/exakit.ps1')) {
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $file), [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count) { throw "$file parse errors: $parseErrors" }
        foreach ($fn in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Extent.Text -match '^\s*(function|filter)\s' }, $true)) {
            Invoke-Expression $fn.Extent.Text
        }
    }
    # What the libraries set when they load, in the scratch kit home.
    $script:ExakitHome = Join-Path $work 'kit'
    $script:CacheDir = Join-Path $script:ExakitHome 'cache'
    $script:CredsDir = Join-Path $script:ExakitHome 'credentials'
    $script:FailureNotePath = Join-Path $script:ExakitHome '.last-failure'
    $script:BinDir = Join-Path $work 'bin'
    $script:PersonalBinPath = Join-Path $script:BinDir 'exasol.exe'
    $script:PersonalProbeTimeout = 10
    $script:PersonalPort = 8563
    $script:PersonalVersionFallback = '2.5.0'
    $script:PersonalRepo = 'exasol/exasol-personal'
    $script:VersionPolicy = 'pinned'
    $script:ExakitQuietDetail = $false
    $script:LogFile = $null
    New-Item -ItemType Directory -Force -Path $script:ExakitHome, $script:BinDir | Out-Null

    # The manifest and the credential store, in memory.
    $script:mf = @{}
    function Get-ExakitManifestValue([string]$Path) { return $script:mf[$Path] }
    function Set-ExakitManifestValue([string]$Path, $Value) { $script:mf[$Path] = $Value }
    function Remove-ExakitManifestValue([string]$Path) { $script:mf.Remove($Path) }
    $script:creds = @{}
    function Get-ExakitCredential([string]$Name) { return $script:creds[$Name] }
    function Set-ExakitCredential([string]$Name, [string]$Value) { $script:creds[$Name] = $Value }
    # What the run says, in order.
    $script:said = New-Object System.Collections.ArrayList
    function Info($m) { [void]$script:said.Add("INFO $m") }
    function Warn2($m) { [void]$script:said.Add("WARN $m") }
    function Ok($m) { [void]$script:said.Add("OK $m") }
    function OkStep($m) { [void]$script:said.Add("OK $m") }
    function Write-ExakitError($m) { [void]$script:said.Add("ERROR $m") }
    function Fail([string]$Msg) { [void]$script:said.Add("FAIL $Msg"); throw $Msg }
    function Write-ExakitLog { }
    function Start-ExakitSpinner { }
    function Stop-ExakitSpinner { }
    function Get-ExakitTilde([string]$Path) {
        if ($Path -and $Path.StartsWith($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase)) { return '~' + $Path.Substring($env:USERPROFILE.Length) }
        return $Path
    }
    function Get-ExakitInstallCommand { return 'irm https://example.test/install.ps1 | iex' }
    function Get-RuntimeType { return ("" + (Get-ExakitManifestValue 'runtime.type')) }
    function Test-ExakitStdoutIsTerminal { return $false }
    function Register-ExakitTlsPin { param([switch]$Replace) return $false }
    function Update-ExakitTlsPinnedClients { param([switch]$ProfileOnly) }
    function Test-ExakitCoreRerunActive { return ($env:EXAKIT_CORE_RERUN -eq '1') }

    # THE STAND-IN LAUNCHER. A launcher file holds its version ("2.5.0
    # broken": `version` answers nothing). Every call is kept as "<version>
    # <args> [<the folders in both roots before it ran>]"; a database's state
    # (running or stopped) is kept by its id.
    $script:calls = New-Object System.Collections.ArrayList
    $script:dbState = @{}
    $script:stopRc = 0
    $script:startFails = 0
    $script:userLauncher = ''
    function Get-StubRoots { $r = Resolve-PersonalDeployDir -Path ''; return @($r.LegacyRoot, $r.NewRoot) }
    function Get-StubState([string]$Dir) {
        $id = "" + (Read-PersonalDeploymentId -Dir $Dir)
        if ($id -and $script:dbState.ContainsKey($id)) { return $script:dbState[$id] }
        return 'stopped'
    }
    function Get-StubSeen {
        $names = @()
        foreach ($root in @(Get-StubRoots)) {
            if ($root -and (Test-Path -LiteralPath $root -PathType Container)) {
                $names += @(Get-ChildItem -LiteralPath $root -Directory -Force | Sort-Object Name | ForEach-Object { $_.Name })
            }
        }
        return ($names -join ' ')
    }
    # From 2.5, any command but help first moves every deployment of the older
    # root that is stopped, unlocked and has no namesake in the 2.5 root.
    # $script:noMove: it cannot (the profile on another drive, a file open in
    # the folder), and the folder stays where it is.
    $script:noMove = $false
    function Move-StubLegacy {
        if ($script:noMove) { return }
        $roots = @(Get-StubRoots)
        if (-not (Test-Path -LiteralPath $roots[0] -PathType Container)) { return }
        foreach ($d in @(Get-ChildItem -LiteralPath $roots[0] -Directory -Force)) {
            if ((Get-StubState $d.FullName) -eq 'running') { continue }
            if (@(Get-ChildItem -LiteralPath $d.FullName -Force -Filter '.dirmutex*').Count -gt 0) { continue }
            $to = Join-Path $roots[1] $d.Name
            if (Test-Path -LiteralPath $to) { continue }
            New-Item -ItemType Directory -Force -Path $roots[1] | Out-Null
            [IO.Directory]::Move($d.FullName, $to)
        }
    }
    function Invoke-StubLauncher([string]$Exe, [string[]]$Arguments) {
        $text = ''
        if ($Exe -and (Test-Path -LiteralPath $Exe -PathType Leaf)) { $text = ([IO.File]::ReadAllText($Exe)).Trim() }
        $parts = @($text -split '\s+')
        $version = $parts[0]
        $broken = $parts -contains 'broken'
        [void]$script:calls.Add(("{0} {1} [{2}]" -f $version, ($Arguments -join ' '), (Get-StubSeen)))
        $sub = ''
        if ($Arguments.Count -gt 0) { $sub = $Arguments[0] }
        $help = ($Arguments -contains '--help') -or ($Arguments -contains '-h') -or ($sub -eq 'help')
        $current = ($version -match '^2\.([5-9]|[1-9][0-9])\.')
        if ($current -and -not $help) { Move-StubLegacy }
        $dir = ''
        $at = [array]::IndexOf($Arguments, '--deployment-dir')
        if ($at -ge 0 -and $at + 1 -lt $Arguments.Count) { $dir = $Arguments[$at + 1] }
        $there = ($dir -and (Test-Path -LiteralPath $dir -PathType Container))
        if ($help) {
            if ($sub -eq '--help' -or $sub -eq 'help') { return @{ Rc = 0; Out = "Commands:`n  start  Start`n  stop  Stop`n  status  Status`n  deployments  Deployments" } }
            if ($sub -eq 'install') { return @{ Rc = 0; Out = "Commands:`n  local  Local" } }
            return @{ Rc = 0; Out = 'Usage' }
        }
        switch ($sub) {
            'version' {
                if ($broken) { return @{ Rc = 1; Out = $null } }
                # "slow": its first command takes 12 s (the move of the older
                # root, antivirus on a new program file); "hangsonce": its
                # first command never ends. Out of time is Rc 124.
                if (($parts -contains 'slow' -or $parts -contains 'hangsonce') -and -not $script:firstRunDone) {
                    $script:firstRunDone = $true
                    $script:firstRunBudget = $script:boundedTimeout
                    if ($parts -contains 'hangsonce' -or $script:boundedTimeout -lt 12) { return @{ Rc = 124; Out = $null } }
                }
                return @{ Rc = 0; Out = $version }
            }
            'info' {
                if ($there) { return @{ Rc = 0; Out = 'info' } }
                return @{ Rc = 1; Out = $null }
            }
            'status' {
                if (-not $there) { return @{ Rc = 0; Out = '{"status": "not_initialized"}' } }
                $s = 'stopped'
                if ((Get-StubState $dir) -eq 'running') { $s = 'database_ready' }
                if ($script:launcherSays) { $s = $script:launcherSays }
                return @{ Rc = 0; Out = ('{"status": "' + $s + '"}') }
            }
            'stop' {
                if ($script:stopRc -ne 0 -or -not $there) { return @{ Rc = 1; Out = $null } }
                $script:dbState["" + (Read-PersonalDeploymentId -Dir $dir)] = 'stopped'
                $script:kitSays = ''
                return @{ Rc = 0; Out = '' }
            }
            'start' {
                if (-not $there) { return @{ Rc = 1; Out = $null } }
                if ($script:startFails -gt 0) { $script:startFails--; return @{ Rc = 1; Out = $null } }
                $script:dbState["" + (Read-PersonalDeploymentId -Dir $dir)] = 'running'
                return @{ Rc = 0; Out = '' }
            }
            'deployments' {
                if (-not $current) { return @{ Rc = 1; Out = $null } }
                $roots = @(Get-StubRoots)
                $rows = @()
                foreach ($root in @($roots[1], $roots[0])) {
                    if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
                    foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -Force | Sort-Object Name)) {
                        if (-not (Test-Path -LiteralPath (Join-Path $d.FullName '.exasolLauncherState.json'))) { continue }
                        if ($root -eq $roots[0] -and (Test-Path -LiteralPath (Join-Path $roots[1] $d.Name))) { continue }
                        $s = 'stopped'
                        if ((Get-StubState $d.FullName) -eq 'running') { $s = 'database_ready' }
                        $rows += [pscustomobject]@{ name = $d.Name; path = $d.FullName; status = $s; infrastructure = 'local' }
                    }
                }
                return @{ Rc = 0; Out = (ConvertTo-Json -InputObject @($rows) -Compress) }
            }
        }
        return @{ Rc = 0; Out = '' }
    }
    function Invoke-ExakitBounded {
        param([string]$FilePath, [string[]]$Arguments = @(), [string]$ArgumentString = '', [int]$TimeoutSeconds = 8)
        $script:boundedTimeout = $TimeoutSeconds
        $r = Invoke-StubLauncher -Exe $FilePath -Arguments $Arguments
        if ($r.Rc -eq 124) { $script:ExakitBoundedOutcome = 'timeout'; return $null }
        if ($r.Rc -ne 0) { $script:ExakitBoundedOutcome = "exit $($r.Rc)"; return $null }
        $script:ExakitBoundedOutcome = 'ok'
        return $r.Out
    }
    function Invoke-ExakitLogged {
        $exe = "" + $args[0]
        $rest = @($args | Select-Object -Skip 1 | ForEach-Object { "$_" })
        return (Invoke-StubLauncher -Exe $exe -Arguments $rest).Rc
    }
    # The launcher the kit runs: its own, else the user's on PATH.
    function Get-PersonalCli {
        if (Test-Path -LiteralPath $script:PersonalBinPath) { return $script:PersonalBinPath }
        if ($script:userLauncher -and (Test-Path -LiteralPath $script:userLauncher)) { return $script:userLauncher }
        return $script:PersonalBinPath
    }
    # The database's state as the kit asks it, a start as the launcher's start
    # on the folder in use, and the wait asks that state.
    # $script:launcherSays: the launcher's answer about the database, whatever
    # its state. $script:kitSays: the kit's own status. $script:portBusy: its
    # port is held.
    $script:launcherSays = ''; $script:kitSays = ''; $script:portBusy = $false
    function Test-ExakitPortInUse { return [bool]$script:portBusy }
    function Get-PersonalStatus {
        if ($script:kitSays) { return $script:kitSays }
        Update-PersonalDeployDir
        $out = "" + (Invoke-ExakitBounded -FilePath (Get-PersonalCli) -Arguments @('status', '--json', '--deployment-dir', $script:PersonalDeployDir))
        if ($out -match 'database_ready') { return 'running' }
        if ($out -match '"stopped"') { return 'stopped' }
        return 'not deployed'
    }
    function Start-Personal {
        Update-PersonalDeployDir
        if (-not (Test-ExakitKitDatabaseGuard)) { return }
        if ((Invoke-ExakitLogged (Get-PersonalCli) start --deployment-dir $script:PersonalDeployDir) -ne 0) { Fail 'Failed to start the database.' }
        Ok 'Database started'
    }
    function Wait-PersonalReadyOrDeploy { return ((Get-PersonalStatus) -eq 'running') }
    # The pinned release: Exasol's S3, pinned to the 2.5.0 launcher's checksum.
    # $script:download names the file the server hands out.
    $script:downloads = New-Object System.Collections.ArrayList
    function Get-PersonalS3Source { param([string]$Version) return [pscustomobject]@{ Url = 'https://example.test/personal/exasol.exe'; Sha256 = $script:pin } }
    function Get-ExakitFile {
        param([string]$Url, [string]$Dest, [switch]$Soft)
        [void]$script:downloads.Add($Url)
        Copy-Item -LiteralPath $script:download -Destination $Dest -Force
        return $true
    }
    # `exakit update`, the personal row (and the kit's own, when a case adds it).
    $script:targets = @('personal')
    $script:advertised = '2.5.0'
    function Get-ExakitUpdateTargets { param([string]$Target) return $script:targets }
    function Write-ExakitVersionsSourceLine { }
    function Get-ExakitComponentAvailable { param([string]$Component) if ($Component -eq 'exakit') { return '0.3.1' }; return $script:advertised }
    function Get-ExakitComponentCurrent {
        param([string]$Component)
        if ($Component -eq 'exakit') { return '0.3.0' }
        if ($Component -eq 'personal' -or $Component -eq 'runtime') { return ("" + (Get-ExakitManifestValue 'runtime.version')) }
        return ''
    }
    function Test-ExakitComponentSupported { param([string]$Component) return $true }
    function Test-ExakitComponentAhead { param([string]$Component) return $false }
    function Get-ExakitMarketplaceAddon { param([string]$Id) return $null }
    function Test-ExakitAddonNeedsUpdate { param([string]$Id) return $false }
    function Test-ExakitSkillsUnplaced { return $false }
    function Get-ExakitComponentMinKit { param([string]$Component) return '' }
    function Update-ExakitAutostartEntries { }
    # The kit's own update, staged for the moment the running copy exits
    # (Windows does not replace a running kit): everything after it waits.
    function Update-ExakitSelf { param([string]$Advertised, [string]$Installed) $script:ExakitKitSwapped = $true }

    $NAME = 'starter-kit-local'
    $roots = Resolve-PersonalDeployDir -Path ''
    $NEWROOT = $roots.NewRoot
    $OLDROOT = $roots.LegacyRoot
    $NEW = Join-Path $NEWROOT $NAME
    $OLD = Join-Path $OLDROOT $NAME
    $DEF = Join-Path $OLDROOT 'default'
    $CONF_REL = [IO.Path]::Combine('local', 'runtime', 'exa', 'exasol.conf')
    $COPY = Join-Path $script:CacheDir 'personal-launcher-before-update'
    $L5 = "INFO Renaming the database to 'starter-kit-local'."
    foreach ($v in @('2.4.0', '2.5.0')) { [IO.File]::WriteAllText((Join-Path $work "exasol-$v"), $v) }
    [IO.File]::WriteAllText((Join-Path $work 'exasol-2.5.0-broken'), '2.5.0 broken')
    [IO.File]::WriteAllText((Join-Path $work 'exasol-2.5.0-slow'), '2.5.0 slow')
    [IO.File]::WriteAllText((Join-Path $work 'exasol-2.5.0-hangsonce'), '2.5.0 hangsonce')
    [IO.File]::WriteAllText((Join-Path $work 'exasol-silent'), 'none broken')
    [IO.File]::WriteAllText((Join-Path $work 'corrupt'), 'not a launcher')
    function Sha([string]$Path) {
        if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
        return ''
    }
    $script:pin25 = Sha (Join-Path $work 'exasol-2.5.0')
    $script:sha24 = Sha (Join-Path $work 'exasol-2.4.0')

    # Fresh: a new process on the machine as the case set it up.
    function Fresh {
        $script:PersonalLauncherAsked = $false; $script:PersonalLauncherListed = $false; $script:PersonalLauncherDeployments = @()
        $script:PersonalLauncherDecided = $false; $script:PersonalDeployRec = ''; $script:PersonalDeployFollowed = ''; $script:PersonalDeployIdSeen = $false
        $script:ExakitKitDbGuardSaid = $false; $script:ExakitRuntimeUpdateSaid = $false; $script:PersonalLauncherPlan = $null
        $script:PersonalUpdateResult = ''; $script:PersonalUpdateWhy = ''; $script:PersonalUpdateRestarted = $false
        Remove-Item Env:EXAKIT_PERSONAL_VERSION -ErrorAction SilentlyContinue
        $script:PersonalDeployDir = (Resolve-PersonalDeployDir -Path '').Dir
    }
    function Reset-Home {
        foreach ($p in @((Join-Path $env:USERPROFILE '.exasol'), (Join-Path $env:LOCALAPPDATA 'exasol'), $script:CacheDir,
                         (Join-Path $work 'userbin'), (Join-Path $work 'cellar'))) {
            if (-not (Test-Path -LiteralPath $p)) { continue }
            foreach ($f in @(Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction SilentlyContinue)) {
                try { if ($f.IsReadOnly) { $f.IsReadOnly = $false } } catch { }
            }
            Remove-Item -LiteralPath $p -Recurse -Force
        }
        Remove-Item -LiteralPath $script:PersonalBinPath, $script:FailureNotePath -Force -ErrorAction SilentlyContinue
        # A fresh process: the kit's launcher where the libraries put it at
        # load, its own folder copy gone.
        Remove-Item -LiteralPath (Get-PersonalSeparateBinPath) -Force -ErrorAction SilentlyContinue
        $script:PersonalBinPath = Join-Path $script:BinDir 'exasol.exe'
        $script:PersonalSeparate = $false; $script:PersonalBinSynced = $false
        $script:mf = @{}; $script:creds = @{}; $script:dbState = @{}
        $script:userLauncher = ''
        $script:download = Join-Path $work 'exasol-2.5.0'
        $script:pin = $script:pin25
        $script:stopRc = 0; $script:startFails = 0; $script:noMove = $false
        $script:launcherSays = ''; $script:kitSays = ''; $script:portBusy = $false
        $script:firstRunDone = $false; $script:firstRunBudget = 0
        $script:targets = @('personal')
        Fresh
    }
    # Seed <dir> <id> <port> [running]: a deployment Exasol Personal 2.4 made,
    # its 20-session limit in exasol.conf.
    function Seed([string]$Dir, [string]$Id, [int]$Port, [string]$State = 'stopped') {
        New-Item -ItemType Directory -Force -Path ([IO.Path]::Combine($Dir, 'local', 'runtime', 'exa')), (Join-Path $Dir 'infrastructure') | Out-Null
        [IO.File]::WriteAllText((Join-Path $Dir 'deployment.json'), ('{"deploymentId": "' + $Id + '", "connection": {"host": "127.0.0.1", "dbPort": ' + $Port + ', "username": "sys"}}'))
        [IO.File]::WriteAllText((Join-Path $Dir '.exasolLauncherState.json'), ('{"deploymentId": "' + $Id + '", "deploymentVersion": "2.4.0"}'))
        [IO.File]::WriteAllText((Join-Path $Dir '.exasolLauncher.version'), '2.4.0')
        [IO.File]::WriteAllText([IO.Path]::Combine($Dir, 'infrastructure', 'infrastructure.yaml'), "name: Exasol Local`nbackend: local`nlocal:`n  ports: db:$Port`n")
        [IO.File]::WriteAllText((Join-Path $Dir $CONF_REL), "[DB_PARAMS]`nmaxConnectionsLicenseLimit=20`nother = 1`n")
        [IO.File]::WriteAllText((Join-Path $Dir 'secrets.json'), ('{"dbPassword": "pw-' + $Id + '-0123456789"}'))
        [IO.File]::WriteAllText([IO.Path]::Combine($Dir, 'local', 'runtime', 'exa', 'data.bin'), "tables of $Id")
        $script:dbState[$Id] = $State
    }
    function State([string]$Id) { if ($script:dbState.ContainsKey($Id)) { return $script:dbState[$Id] }; return 'stopped' }
    # Kit030 <dir> <launcher version> [id]: what a 0.3.0 kit recorded about the
    # database it deployed with its own launcher (no id: 0.3.0 kept none).
    function Kit030([string]$Dir, [string]$Version, [string]$Id = '') {
        Copy-Item -LiteralPath (Join-Path $work "exasol-$Version") -Destination $script:PersonalBinPath -Force
        Set-ExakitManifestValue 'runtime.type' 'personal'
        Set-ExakitManifestValue 'runtime.version' $Version
        Set-ExakitManifestValue 'runtime.deployment_dir' $Dir
        Set-ExakitManifestValue 'runtime.launcher' $script:PersonalBinPath
        Set-ExakitManifestValue 'runtime.dsn' '127.0.0.1:8563'
        Set-ExakitComponentOwnership 'personal' 'kit' $script:PersonalBinPath
        Set-ExakitComponentOwnership 'database' 'kit' $Dir
        if ($Id) { Set-ExakitManifestValue 'runtime.deployment_id' $Id }
        $script:creds['personal_sys_password'] = 'pw-' + (Read-PersonalDeploymentId -Dir $Dir) + '-0123456789'
    }
    # User030 <dir> <their launcher> <version>: a database the user let the
    # 0.3.0 kit use ("Use it instead?" yes), run by their own launcher.
    function User030([string]$Dir, [string]$Their, [string]$Version) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Their) | Out-Null
        Copy-Item -LiteralPath (Join-Path $work "exasol-$Version") -Destination $Their -Force
        $script:userLauncher = $Their
        Set-ExakitManifestValue 'runtime.type' 'personal'
        Set-ExakitManifestValue 'runtime.version' $Version
        Set-ExakitManifestValue 'runtime.deployment_dir' $Dir
        Set-ExakitManifestValue 'runtime.launcher' $Their
        Set-ExakitManifestValue 'runtime.dsn' '127.0.0.1:8563'
        Set-ExakitComponentOwnership 'personal' 'user' $Their
        Set-ExakitComponentOwnership 'database' 'user' $Dir
        $script:creds['personal_sys_password'] = 'pw-' + (Read-PersonalDeploymentId -Dir $Dir) + '-0123456789'
    }
    # Kit030Theirs <dir> <their launcher> <version>: Q15, the 0.3.0 kit's OWN
    # database (receipt kit), deployed with the user's own launcher (receipt
    # user).
    function Kit030Theirs([string]$Dir, [string]$Their, [string]$Version) {
        User030 $Dir $Their $Version
        Set-ExakitComponentOwnership 'database' 'kit' $Dir
    }
    # Upd: `exakit update` on this machine, as a user runs it (no answer
    # given), its rows kept as --json keeps them.
    function Upd {
        $script:calls.Clear(); $script:said.Clear(); $script:downloads.Clear()
        Fresh
        $script:ExakitUpdateJson = $true
        $script:ExakitUpdateResults = New-Object System.Collections.ArrayList
        $script:updThrew = ''
        try { Invoke-ExakitUpdateRun -Target 'all' -AssumeYes $false 6>$null | Out-Null } catch { $script:updThrew = "$($_.Exception.Message)" }
        Remove-Item Env:EXAKIT_PERSONAL_VERSION -ErrorAction SilentlyContinue
    }
    # Row [-Remedy]: the personal rows, "personal|<outcome>[|<remedy>]".
    function Row([switch]$Remedy) {
        $rows = @(@($script:ExakitUpdateResults) | Where-Object { $_.component -eq 'personal' } | ForEach-Object {
            if ($Remedy) { "personal|$($_.outcome)|$($_.remedy)" } else { "personal|$($_.outcome)" } })
        return ($rows -join ' ')
    }
    # RowError: the reason the personal rows carry.
    function RowError { return ((@(@($script:ExakitUpdateResults) | Where-Object { $_.component -eq 'personal' }) | ForEach-Object { "$($_.error)" }) -join ' ') }
    function Json { return (& { Write-ExakitUpdateJsonReport } | Out-String | ConvertFrom-Json) }
    function Calls([string]$Verbs) {
        return ((@($script:calls | Where-Object { ("$_" -split ' ')[1] -match "^($Verbs)$" } | ForEach-Object { "$_" -replace ' \[[^\]]*\]$', '' })) -join "`n")
    }
    function First25 { $c = @($script:calls | Where-Object { "$_".StartsWith('2.5.0 ') }); if ($c.Count) { return "$($c[0])" }; return '' }
    function Said { return ($script:said -join "`n") }
    function LineOf([string]$Text) { for ($i = 0; $i -lt $script:said.Count; $i++) { if ("$($script:said[$i])".Contains($Text)) { return $i } }; return -1 }
    function Before([string]$Label, [string]$First, [string]$Second) {
        $a = LineOf $First; $b = LineOf $Second
        Check $Label 'yes' (YN ($a -ge 0 -and $b -ge 0 -and $a -lt $b))
    }
    function Conf([string]$Dir) { $f = Join-Path $Dir $CONF_REL; if (Test-Path -LiteralPath $f) { return [IO.File]::ReadAllText($f) }; return '' }
    function Note { if (Test-Path -LiteralPath $script:FailureNotePath) { return "" + @(Get-Content -LiteralPath $script:FailureNotePath)[0] }; return '' }
    $tildeOld = Get-ExakitTilde $OLD
    $tildeNew = Get-ExakitTilde $NEW

    Write-Host "owner kit: a 0.3.0 kit's own database on its own launcher 2.4.0, running:"
    Reset-Home
    Seed $DEF 'exa-030' 8563 'running'
    Seed (Join-Path $OLDROOT 'theirs') 'exa-theirs' 8600     # a stopped deployment of the user's, beside it
    Kit030 $DEF '2.4.0'
    Set-ExakitManifestValue 'runtime.deployment_id' 'exa-030'   # the record 0.3.1 backfills from the folder
    Upd
    Check 'succeeds' '' $script:updThrew
    Check 'the row: updated' 'personal|updated' (Row)
    Check 'the database is starter-kit-local in the 2.5 root' 'yes|no|no' "$(YN (Test-Path $NEW))|$(YN (Test-Path $DEF))|$(YN (Test-Path $OLD))"
    Check '...its data and its id with it' 'tables of exa-030|exa-030' ("{0}|{1}" -f [IO.File]::ReadAllText([IO.Path]::Combine($NEW, 'local', 'runtime', 'exa', 'data.bin')), (Read-PersonalDeploymentId -Dir $NEW))
    Check 'the records follow: folder, receipt, name, owner, id' "$NEW|$NEW|$NAME|kit|exa-030" ("{0}|{1}|{2}|{3}|{4}" -f $script:mf['runtime.deployment_dir'], $script:mf['runtime.ownership_path'], $script:mf['runtime.deployment_name'], $script:mf['runtime.ownership'], $script:mf['runtime.deployment_id'])
    Fresh
    Check '...still the kit''s, managed' 'kit' (Get-ExakitComponentOwnership 'database')
    Check 'the launcher is 2.5.0, checksum checked, the kit''s receipt on it' "$($script:pin25)|kit|True" ("{0}|{1}|{2}" -f (Sha $script:PersonalBinPath), $script:mf['components.personal.ownership'], ((Get-FileHash -LiteralPath $script:PersonalBinPath).Hash -eq $script:mf['components.personal.ownership_sha256']))
    Check '...recorded' '2.5.0' $script:mf['runtime.version']
    # OFF PATH (Krishna, 24 Nov): the update put the kit's 2.5 in the kit's
    # folder and removed the old file at .local\bin, still the one the kit
    # recorded, and says where the launcher is now.
    Check 'the kit''s launcher left PATH: in the kit''s folder, the old file gone' "$(Get-PersonalSeparateBinPath)|no" ("{0}|{1}" -f $script:mf['components.personal.ownership_path'], (YN (Test-Path (Join-Path $script:BinDir 'exasol.exe'))))
    Has '...said where, and how to run it' "INFO The kit's Exasol launcher is now in $(Get-ExakitTilde (Split-Path -Parent (Get-PersonalSeparateBinPath))). Run it with: exakit exasol" (Said)
    Check 'the old launcher''s copy is gone' 'no' (YN (Test-Path $COPY))
    Check 'stopped once, by the old launcher, on the 0.3.0 folder' "2.4.0 stop --deployment-dir $DEF" (Calls 'stop')
    Check 'started once, by the new launcher, on the new folder' "2.5.0 start --deployment-dir $NEW" (Calls 'start')
    Check 'the database runs again' 'running' (State 'exa-030')
    Has 'nothing 2.5 ran before the rename: its first call saw starter-kit-local' "[$NAME theirs]" (First25)
    Hasnt '...and never a default' 'default' (First25)
    Check 'the 20-session limit is gone, the rest kept, a backup beside it' 'no|yes|yes' "$(YN ((Conf $NEW) -match 'maxConnectionsLicenseLimit'))|$(YN ((Conf $NEW) -match 'other = 1'))|$(YN (Test-Path ((Join-Path $NEW $CONF_REL) + '.before-session-limit')))"
    Check '...recorded as lifted' 'lifted' $script:mf['runtime.session_limit']
    Has 'the stop line is said' 'WARN personal 2.4.0 -> 2.5.0 needs the database stopped.' (Said)
    Has 'approved line 5, exactly' $L5 (Said)
    Before '...after the stop line' 'needs the database stopped' $L5
    Before '...and after the stop' 'OK Database stopped' $L5
    Check 'the stop line is said once' 1 (@($script:said | Where-Object { "$_" -match 'needs the database stopped' }).Count)
    Check 'their own deployment is not stopped or started' '' (@($script:calls | Where-Object { ("$_" -replace ' \[[^\]]*\]$', '') -match '^\S+ (stop|start) .*theirs' }) -join '|')
    Check '...and is still theirs, moved by the 2.5 launcher like any stopped legacy one' 'yes|stopped' "$(YN (Test-Path (Join-Path $NEWROOT 'theirs')))|$(State 'exa-theirs')"
    Check 'said: updated and running again' 'yes' (YN ($script:said -contains 'OK Runtime updated and the database is running again.'))
    Fresh
    Check 'nothing is missing afterwards' '' (Get-ExakitPersonalDbState)
    Upd
    Check 'a second update: nothing to do' '|personal|current' "$($script:updThrew)|$(Row)"
    Check '...no stop, no start' '' (Calls 'stop|start')

    Write-Host "owner kit: the old launcher at .local\bin changed since the kit recorded it:"
    # No longer the file the kit recorded: not the kit's to replace, move or
    # remove. Left where and as it is, and nothing goes into the kit's folder.
    Reset-Home
    Seed $DEF 'exa-030c' 8563 'running'
    Kit030 $DEF '2.4.0' 'exa-030c'
    Add-Content -LiteralPath $script:PersonalBinPath -Value ' changed by the user'
    $changedSha = Sha $script:PersonalBinPath
    Upd
    Check 'not the kit''s any more: left where and as it is, nothing in the kit''s folder' "personal|skipped|$changedSha|no" ("{0}|{1}|{2}" -f (Row), (Sha (Join-Path $script:BinDir 'exasol.exe')), (YN (Test-Path (Get-PersonalSeparateBinPath))))
    Write-Host "owner kit: the new launcher does not run, so the move off PATH is put back:"
    Reset-Home
    Seed $DEF 'exa-030d' 8563 'running'
    Kit030 $DEF '2.4.0' 'exa-030d'
    $oldSha = Sha $script:PersonalBinPath
    $oldPath = $script:PersonalBinPath
    $script:download = Join-Path $work 'exasol-2.5.0-broken'; $script:pin = Sha $script:download
    Upd
    Check 'put back exactly: the old launcher where it was, its receipt, no kit folder launcher' "$oldSha|$oldPath|$oldSha|no" ("{0}|{1}|{2}|{3}" -f (Sha $oldPath), $script:mf['components.personal.ownership_path'], ("" + $script:mf['components.personal.ownership_sha256']).ToLowerInvariant(), (YN (Test-Path (Get-PersonalSeparateBinPath))))
    Check '...the kit runs the old one again' $oldPath (Get-PersonalCli)

    Write-Host "owner kit, the 0.3.0 record with no id, the database stopped:"
    Reset-Home
    Seed $DEF 'exa-030b' 8563
    Kit030 $DEF '2.4.0'
    Upd
    Check 'succeeds, updated' '|personal|updated' "$($script:updThrew)|$(Row)"
    Check 'the id is recorded from the folder, and followed' "exa-030b|$NEW" "$($script:mf['runtime.deployment_id'])|$($script:mf['runtime.deployment_dir'])"
    Check 'a stopped database is started once at the end, by the new launcher (Krishna Q8)' "2.5.0 start --deployment-dir $NEW|running" "$(Calls 'stop|start')|$(State 'exa-030b')"
    Check '...its limit lifted for its next start' 'no' (YN ((Conf $NEW) -match 'maxConnectionsLicenseLimit'))
    Has 'line 5' $L5 (Said)

    Write-Host "only the launcher's own 'stopped' is stopped: nothing is renamed on another answer:"
    # "conflict": the port is held and nothing answers on it yet, a hung
    # database, or one coming up. Stopped first, like a running one.
    Reset-Home
    Seed $DEF 'exa-conf' 8563 'running'
    Kit030 $DEF '2.4.0' 'exa-conf'
    $script:kitSays = 'conflict'; $script:portBusy = $true
    Upd
    Check 'a database in conflict: stopped by the launcher that runs it, then renamed, then started once' "personal|updated|2.4.0 stop --deployment-dir $DEF`n2.5.0 start --deployment-dir $NEW" "$(Row)|$(Calls 'stop|start')"
    Before '...renamed after the stop' 'OK Database stopped' $L5
    # One that cannot be stopped: nothing changes.
    Reset-Home
    Seed $DEF 'exa-hung' 8563 'running'
    Kit030 $DEF '2.4.0' 'exa-hung'
    $script:launcherSays = 'not_initialized'; $script:kitSays = 'conflict'; $script:portBusy = $true
    Upd
    Check 'the launcher never says stopped, the port is held: not renamed, the launcher as it was' "yes|no|$(Sha (Join-Path $work 'exasol-2.4.0'))" "$(YN (Test-Path $DEF))|$(YN (Test-Path $NEW))|$(Sha (Join-Path $script:BinDir 'exasol.exe'))"
    Has '...said' 'WARN The database did not stop, so it was not updated. Nothing was changed.' (Said)
    # The launcher cannot speak for it, and nothing holds its port.
    Reset-Home
    Seed $DEF 'exa-mute' 8563
    Kit030 $DEF '2.4.0' 'exa-mute'
    $script:launcherSays = 'not_initialized'; $script:kitSays = 'unknown'
    Upd
    Check 'the launcher cannot say, nothing on the port: asked to stop, and never renamed' "yes|no|no|2.4.0 stop --deployment-dir $DEF" "$(YN (Test-Path $DEF))|$(YN (Test-Path $NEW))|$(YN (Test-Path $OLD))|$(Calls 'stop')"
    Hasnt '...line 5 is not said' $L5 (Said)
    Reset-Home
    $def25m = Join-Path $NEWROOT 'default'
    Seed $def25m 'exa-mute25' 8563
    Kit030 $def25m '2.5.0' 'exa-mute25'
    $script:launcherSays = 'not_initialized'; $script:kitSays = 'unknown'
    Upd
    Check 'the same with the launcher at 2.5.0: neither renamed nor its limit edited' "yes|no|yes" "$(YN (Test-Path $def25m))|$(YN (Test-Path $NEW))|$(YN ((Conf $def25m) -match 'maxConnectionsLicenseLimit'))"

    Write-Host "a kit from before ownership receipts (0.2.4, 0.2.5): its database and launcher stay the kit's:"
    Reset-Home
    Seed $DEF 'exa-025' 8563 'running'
    Kit030 $DEF '2.4.0'
    $script:PersonalPublished240Sha = Sha $script:PersonalBinPath
    foreach ($k in @('components.personal.ownership', 'components.personal.ownership_path', 'components.personal.ownership_sha256', 'runtime.ownership', 'runtime.ownership_path', 'runtime.ownership_sha256')) { $script:mf.Remove($k) }
    Fresh
    Check 'before: the kit''s, by what it recorded' 'kit|kit' "$(Get-ExakitComponentOwnership 'personal')|$(Get-ExakitComponentOwnership 'database')"
    Upd
    Check 'updated, renamed, in one restart' "personal|updated|yes|2.4.0 stop --deployment-dir $DEF`n2.5.0 start --deployment-dir $NEW" "$(Row)|$(YN (Test-Path $NEW))|$(Calls 'stop|start')"
    Fresh
    Check '...still the kit''s afterwards' 'kit|kit' "$(Get-ExakitComponentOwnership 'personal')|$(Get-ExakitComponentOwnership 'database')"
    Check '...its limit lifted, the old launcher gone from .local\bin' 'no|no' "$(YN ((Conf $NEW) -match 'maxConnectionsLicenseLimit'))|$(YN (Test-Path (Join-Path $script:BinDir 'exasol.exe')))"

    # Its launcher is not the published 2.4.0: the place proves the receipt,
    # never the file, so it stays.
    Reset-Home
    Seed $DEF 'exa-025b' 8563
    Kit030 $DEF '2.4.0'
    foreach ($k in @('components.personal.ownership', 'components.personal.ownership_path', 'components.personal.ownership_sha256', 'runtime.ownership', 'runtime.ownership_path', 'runtime.ownership_sha256')) { $script:mf.Remove($k) }
    $script:PersonalPublished240Sha = ('0' * 64)
    Upd
    Check 'another file at .local\bin: updated, and that file stays' 'personal|updated|yes' "$(Row)|$(YN (Test-Path (Join-Path $script:BinDir 'exasol.exe')))"
    # The same after an update that was undone (WP2-01): the receipt it put
    # back still proves the place only.
    Reset-Home
    Seed $DEF 'exa-025c' 8563
    Kit030 $DEF '2.4.0'
    foreach ($k in @('components.personal.ownership', 'components.personal.ownership_path', 'components.personal.ownership_sha256', 'runtime.ownership', 'runtime.ownership_path', 'runtime.ownership_sha256')) { $script:mf.Remove($k) }
    $theirs025 = Sha (Join-Path $script:BinDir 'exasol.exe')
    $script:download = Join-Path $work 'exasol-2.5.0-broken'; $script:pin = Sha $script:download
    Upd
    $first025 = Row
    $script:download = Join-Path $work 'exasol-2.5.0'; $script:pin = $script:pin25
    $script:PersonalSeparate = $false; $script:PersonalBinSynced = $false; $script:PersonalReceiptLauncher = ''; $script:PersonalBinPath = Join-Path $script:BinDir 'exasol.exe'
    Upd
    Check 'another file at .local\bin, an update undone, then updated: that file stays' "personal|deferred|personal|updated|$theirs025" "$first025|$(Row)|$(Sha (Join-Path $script:BinDir 'exasol.exe'))"

    Write-Host "an update cut short while the new launcher's receipt is written (RGR-04):"
    # The owner is written `unknown` first, with the old path and checksum still
    # there: the next update is not stuck on "the kit did not install it".
    foreach ($half in @('kit', 'theirs')) {
        Reset-Home
        Seed $NEW 'exa-half' 8563
        if ($half -eq 'kit') { Kit030 $NEW '2.4.0' 'exa-half' } else { Kit030Theirs $NEW (Join-Path (Join-Path $work 'userbin') 'exasol.exe') '2.4.0'; Set-ExakitManifestValue 'runtime.deployment_id' 'exa-half' }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent (Get-PersonalSeparateBinPath)) | Out-Null
        Copy-Item -LiteralPath (Join-Path $work 'exasol-2.5.0') -Destination (Get-PersonalSeparateBinPath) -Force
        Set-ExakitManifestValue 'components.personal.ownership' 'unknown'
        Upd
        Check "${half}: the next update finishes it" "personal|updated|kit|$(Get-PersonalSeparateBinPath)|running" "$(Row)|$($script:mf['components.personal.ownership'])|$($script:mf['components.personal.ownership_path'])|$(State 'exa-half')"
        if ($half -eq 'theirs') { Check '...theirs is as it was' $script:sha24 (Sha (Join-Path (Join-Path $work 'userbin') 'exasol.exe')) }
    }
    # A launcher that the user changed is not that: no checksum, no claim on the
    # file. It stays as it is, and the kit gets its own.
    Reset-Home
    Seed $NEW 'exa-half2' 8563
    Kit030 $NEW '2.4.0' 'exa-half2'
    Add-Content -LiteralPath $script:PersonalBinPath -Value ' changed by the user'
    Set-ExakitManifestValue 'components.personal.ownership' 'unknown'
    $halfSha = Sha $script:PersonalBinPath
    Upd
    Check 'changed since: left as it is, the kit''s own in its folder' "personal|updated|$halfSha|$($script:pin25)" "$(Row)|$(Sha (Join-Path $script:BinDir 'exasol.exe'))|$(Sha (Get-PersonalSeparateBinPath))"

    Write-Host "an update cut short later than that is finished by the next one:"
    # While the database starts (UP2-04): the start it owes comes.
    Reset-Home
    Seed $DEF 'exa-owed' 8563 'running'
    Kit030 $DEF '2.4.0'
    & { function Invoke-PersonalSessionLimitStart { throw 'KILLED' }; Upd }
    Check 'cut short at its one start: renamed, stopped, the start on record' 'yes|stopped|true' "$(YN (Test-Path $NEW))|$(State 'exa-owed')|$($script:mf['runtime.start_owed'])"
    $env:EXAKIT_CONFIRM_RUNTIME_UPDATE = '0'
    Upd
    Remove-Item Env:EXAKIT_CONFIRM_RUNTIME_UPDATE
    Check '...EXAKIT_CONFIRM_RUNTIME_UPDATE=0 holds it back, the row waits for --yes' 'personal|deferred|exakit update --yes|stopped|true' "$(Row -Remedy)|$(State 'exa-owed')|$($script:mf['runtime.start_owed'])"
    Upd
    Check '...the next update starts it, once, and nothing is owed any more' "personal|current|running|2.5.0 start --deployment-dir $NEW|False" "$(Row)|$(State 'exa-owed')|$(Calls 'stop|start')|$($script:mf.ContainsKey('runtime.start_owed'))"
    Set-ExakitManifestValue 'runtime.start_owed' 'true'
    $null = Stop-Personal
    Upd
    Check '...a stop the user asks for settles it: the update leaves it stopped' 'personal|current|stopped|False' "$(Row)|$(State 'exa-owed')|$($script:mf.ContainsKey('runtime.start_owed'))"
    Set-ExakitManifestValue 'runtime.start_owed' 'true'
    $script:startFails = 1
    Upd
    Check '...one that does not start is said, with the command, and waits' "personal|deferred|exakit start|yes" "$(Row -Remedy)|$(YN ((Said).Contains('WARN The database did not start again. Start it with: exakit start')))"

    # Before the kit's old launcher is retired (UPG-10): a later update does it.
    Reset-Home
    Seed $DEF 'exa-ret' 8563
    Kit030 $DEF '2.4.0'
    $oldBin = Join-Path $script:BinDir 'exasol.exe'
    & { function Remove-PersonalUpdateLauncherCopy { throw 'KILLED' }; Upd }
    $retSha = ([string]$script:mf['components.personal.retire_sha256']).ToLowerInvariant()
    Check 'cut short before the old launcher is retired: it is there, and on record' "yes|$oldBin|$($script:sha24)" "$(YN (Test-Path $oldBin))|$($script:mf['components.personal.retire_path'])|$retSha"
    Upd
    Check '...the next update retires it, and drops the note' 'personal|updated|no|False' "$(Row)|$(YN (Test-Path $oldBin))|$($script:mf.ContainsKey('components.personal.retire_path'))"
    # Current already, and a file a program held until now.
    Copy-Item -LiteralPath (Join-Path $work 'exasol-2.4.0') -Destination $oldBin -Force
    Set-ExakitManifestValue 'components.personal.retire_path' $oldBin
    Set-ExakitManifestValue 'components.personal.retire_sha256' $script:sha24
    Upd
    Check '...by a current update too' 'personal|current|no|False' "$(Row)|$(YN (Test-Path $oldBin))|$($script:mf.ContainsKey('components.personal.retire_path'))"
    # Not the file the kit recorded: the user's, left as it is, for good.
    [IO.File]::WriteAllText($oldBin, 'the user''s own')
    Set-ExakitManifestValue 'components.personal.retire_path' $oldBin
    Set-ExakitManifestValue 'components.personal.retire_sha256' $script:sha24
    Upd
    Check '...a changed file there stays, and the note goes' 'the user''s own|False' "$([IO.File]::ReadAllText($oldBin))|$($script:mf.ContainsKey('components.personal.retire_path'))"
    Remove-Item -LiteralPath $oldBin -Force

    # Between the kit folder's launcher and its receipt, the user's own at 2.5
    # (UP2-01): the file without the receipt is not there yet.
    foreach ($half in @('user', 'unknown')) {
        Reset-Home
        $theirs25 = Join-Path (Join-Path $work 'userbin') 'exasol.exe'
        Seed $NEW 'exa-cut' 8563
        User030 $NEW $theirs25 '2.5.0'
        Set-ExakitManifestValue 'runtime.deployment_id' 'exa-cut'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent (Get-PersonalSeparateBinPath)) | Out-Null
        [IO.File]::WriteAllText((Get-PersonalSeparateBinPath), 'half a launcher')
        Set-ExakitManifestValue 'components.personal.ownership' $half
        Upd
        Check "the kit's copy with no receipt (theirs '$half'): installed over, recorded, theirs on record and as it was" `
            "personal|current|$($script:pin25)|kit|$(Get-PersonalSeparateBinPath)|$theirs25|$($script:pin25)" `
            "$(Row)|$(Sha (Get-PersonalSeparateBinPath))|$($script:mf['components.personal.ownership'])|$($script:mf['components.personal.ownership_path'])|$($script:mf['components.personal.user_launcher'])|$(Sha $theirs25)"
        Check '...no half-written file left' 'no' (YN (Test-Path "$(Get-PersonalSeparateBinPath).new"))
    }

    Write-Host "the undo renames back only a database the launcher says is stopped (RGR-01):"
    foreach ($word in @('stopped', 'database_ready', '')) {
        Reset-Home
        Seed $DEF 'exa-back' 8563 'running'
        Kit030 $DEF '2.4.0'
        $script:download = Join-Path $work 'exasol-2.5.0-broken'; $script:pin = Sha $script:download
        & { function Get-PersonalStateOf { param([string]$Dir) return $word }; Upd }
        Check "it says '$word'" "personal|deferred|$(YN ($word -eq 'stopped'))" "$(Row)|$(YN (Test-Path $DEF))"
        if ($word -ne 'stopped') { Has '...it keeps its name, and the kit says so' "WARN The database could not be renamed back to 'default'. It keeps the name 'starter-kit-local', and the kit uses it under that name." (Said) }
    }

    Write-Host "EXAKIT_CONFIRM_RUNTIME_UPDATE=0 holds back exakit update personal by name (N3):"
    Reset-Home
    Seed $DEF 'exa-n3' 8563 'running'
    Kit030 $DEF '2.4.0'
    $env:EXAKIT_CONFIRM_RUNTIME_UPDATE = '0'
    $script:calls.Clear(); $script:said.Clear(); $script:downloads.Clear(); Fresh
    $script:ExakitUpdateJson = $true
    $script:ExakitUpdateResults = New-Object System.Collections.ArrayList
    try { Invoke-ExakitUpdateRun -Target 'personal' -AssumeYes $false 6>$null | Out-Null } catch { [void]$script:said.Add("THREW $($_.Exception.Message)") }
    Remove-Item Env:EXAKIT_CONFIRM_RUNTIME_UPDATE
    Check 'nothing stopped, downloaded or renamed, the row waits for --yes' "personal|deferred|exakit update --yes||0|yes|running|$($script:sha24)" "$(Row -Remedy)|$(Calls 'stop|start')|$($script:downloads.Count)|$(YN (Test-Path $DEF))|$(State 'exa-n3')|$(Sha (Join-Path $script:BinDir 'exasol.exe'))"
    Has '...said' "WARN personal 2.4.0 -> 2.5.0 was left alone: the database update is answered 'no' (EXAKIT_CONFIRM_RUNTIME_UPDATE)." (Said)
    Has '...with the command' 'INFO Apply it when convenient:  exakit update --yes' (Said)

    Write-Host "a launcher at 2.5.0 already, the database still default in the 2.5 root:"
    Reset-Home
    $def25 = Join-Path $NEWROOT 'default'
    Seed $def25 'exa-25' 8563 'running'
    Kit030 $def25 '2.5.0' 'exa-25'
    Upd
    Check 'succeeds, current (no launcher to replace)' '|personal|current' "$($script:updThrew)|$(Row)"
    Check 'renamed in the 2.5 root' 'yes|no' "$(YN (Test-Path $NEW))|$(YN (Test-Path $def25))"
    Check 'the records follow' "$NEW|$NEW|$NAME" ("{0}|{1}|{2}" -f $script:mf['runtime.deployment_dir'], $script:mf['runtime.ownership_path'], $script:mf['runtime.deployment_name'])
    Check 'nothing downloaded' 0 $script:downloads.Count
    Check 'one restart' "2.5.0 stop --deployment-dir $def25`n2.5.0 start --deployment-dir $NEW" (Calls 'stop|start')
    Check '...running again' 'running' (State 'exa-25')
    Check 'its limit lifted while stopped' 'no|lifted' "$(YN ((Conf $NEW) -match 'maxConnectionsLicenseLimit'))|$($script:mf['runtime.session_limit'])"
    Has 'a line says the restart first' "WARN The database stops and starts again once, to rename it to 'starter-kit-local'." (Said)
    Has 'line 5' $L5 (Said)
    Before '...after the stop' 'OK Database stopped' $L5

    Write-Host "EXAKIT_CONFIRM_RUNTIME_UPDATE=0 holds back the rename under a launcher at 2.5.0 too (UPG-05):"
    foreach ($arm in @('rename', 'limit')) {
    foreach ($case in @('routine', 'named', 'json')) {
        # limit: named already, only the 20-session limit to remove.
        $at = $def25; if ($arm -eq 'limit') { $at = $NEW }
        Reset-Home
        Seed $at 'exa-no25' 8563 'running'
        Kit030 $at '2.5.0' 'exa-no25'
        $jsonRow = ''
        switch ($case) {
            'routine' { $env:EXAKIT_CONFIRM_RUNTIME_UPDATE = '0'; Upd }
            'named' {
                $env:EXAKIT_CONFIRM_RUNTIME_UPDATE = '0'
                $script:calls.Clear(); $script:said.Clear(); $script:downloads.Clear(); Fresh
                $script:ExakitUpdateJson = $true
                $script:ExakitUpdateResults = New-Object System.Collections.ArrayList
                $script:updThrew = ''
                try { Invoke-ExakitUpdateRun -Target 'personal' -AssumeYes $false 6>$null | Out-Null } catch { $script:updThrew = "$($_.Exception.Message)" }
            }
            # `exakit update --json` with no --yes and no answer: the answer it
            # gives itself is no.
            'json' {
                Remove-Item Env:EXAKIT_CONFIRM_RUNTIME_UPDATE -ErrorAction SilentlyContinue
                $body = (Get-Command Invoke-CmdUpdateLocked).Definition
                $noAnswer = [regex]::Match($body, '(?s)if \(-not \$AssumeYes\) \{\s*\$confirmAnswer.*?\n    \}').Value
                & ([scriptblock]::Create('$AssumeYes = $false; ' + $noAnswer))
                Check 'update --json without --yes answers no itself' '0' $env:EXAKIT_CONFIRM_RUNTIME_UPDATE
                Upd
            }
        }
        Remove-Item Env:EXAKIT_CONFIRM_RUNTIME_UPDATE -ErrorAction SilentlyContinue
        Check "$arm, ${case}: nothing stopped, started or renamed, the limit as it was" "|yes|$(YN ($arm -eq 'limit'))|running|yes" "$(Calls 'stop|start')|$(YN (Test-Path $at))|$(YN (Test-Path $NEW))|$(State 'exa-no25')|$(YN ((Conf $at) -match 'maxConnectionsLicenseLimit'))"
        Check '...the row waits for --yes' 'personal|deferred|exakit update --yes' (Row -Remedy)
        Has '...said' "was left alone: the database update is answered 'no' (EXAKIT_CONFIRM_RUNTIME_UPDATE)." (Said)
        Has '...with the command' 'INFO Apply it when convenient:  exakit update --yes' (Said)
    }
    }
    # The yes applies it, for both.
    $env:EXAKIT_CONFIRM_RUNTIME_UPDATE = '1'
    Upd
    Check 'then EXAKIT_CONFIRM_RUNTIME_UPDATE=1: the limit removed in one restart' "no|2|running|personal|current" "$(YN ((Conf $NEW) -match 'maxConnectionsLicenseLimit'))|$(@((Calls 'stop|start') -split "`n" | Where-Object { $_ }).Count)|$(State 'exa-no25')|$(Row)"
    Reset-Home
    Seed $def25 'exa-no25' 8563 'running'
    Kit030 $def25 '2.5.0' 'exa-no25'
    Upd
    Remove-Item Env:EXAKIT_CONFIRM_RUNTIME_UPDATE
    Check 'then EXAKIT_CONFIRM_RUNTIME_UPDATE=1: renamed in one restart' "yes|no|2" "$(YN (Test-Path $NEW))|$(YN (Test-Path $def25))|$(@((Calls 'stop|start') -split "`n" | Where-Object { $_ }).Count)"

    Write-Host "a launcher at 2.5.0, the database still default in the older root (it ran when 2.5.0 came):"
    Reset-Home
    Seed $DEF 'exa-25b' 8563 'running'
    Kit030 $DEF '2.5.0'
    Upd
    Check 'succeeds' '|personal|current' "$($script:updThrew)|$(Row)"
    Check 'moved by the launcher after the stop, followed by its id, renamed where it is' 'yes|no|no' "$(YN (Test-Path $NEW))|$(YN (Test-Path $DEF))|$(YN (Test-Path (Join-Path $NEWROOT 'default')))"
    Check '...the records with it' "$NEW|exa-25b" "$($script:mf['runtime.deployment_dir'])|$($script:mf['runtime.deployment_id'])"
    Check '...one restart' 2 (@((Calls 'stop|start') -split "`n" | Where-Object { $_ }).Count)
    Check '...running again' 'running' (State 'exa-25b')

    Write-Host "the new launcher leaves the renamed folder in the older root (another drive, a file open in it): followed there:"
    Reset-Home
    Seed $DEF 'exa-a5' 8563 'running'
    Kit030 $DEF '2.4.0' 'exa-a5'
    $script:noMove = $true
    Upd
    $script:noMove = $false
    Check 'updated, renamed, left in the older root' 'personal|updated|yes|no|no' "$(Row)|$(YN (Test-Path $OLD))|$(YN (Test-Path $NEW))|$(YN (Test-Path $DEF))"
    Check '...the records point there' "$OLD|$OLD|$NAME|exa-a5" ("{0}|{1}|{2}|{3}" -f $script:mf['runtime.deployment_dir'], $script:mf['runtime.ownership_path'], $script:mf['runtime.deployment_name'], $script:mf['runtime.deployment_id'])
    Check '...one restart, the new launcher starts it there' "2.4.0 stop --deployment-dir $DEF`n2.5.0 start --deployment-dir $OLD|running" "$(Calls 'stop|start')|$(State 'exa-a5')"
    Check '...its limit lifted there' 'no|lifted' "$(YN ((Conf $OLD) -match 'maxConnectionsLicenseLimit'))|$($script:mf['runtime.session_limit'])"
    Fresh
    Check '...still the kit''s, nothing missing' 'kit|' "$(Get-ExakitComponentOwnership 'database')|$(Get-ExakitPersonalDbState)"

    Write-Host "a database already starter-kit-local: no rename:"
    Reset-Home
    Seed $NEW 'exa-new' 8563 'running'
    [IO.File]::WriteAllText((Join-Path $NEW $CONF_REL), "[DB_PARAMS]`nother = 1`n")
    Kit030 $NEW '2.5.0' 'exa-new'
    Upd
    Check 'current launcher: nothing to do' '|personal|current' "$($script:updThrew)|$(Row)"
    Check '...no stop, no start, no rename line' '|no' "$(Calls 'stop|start')|$(YN ($script:said -contains $L5))"
    Reset-Home
    Seed $OLD 'exa-old' 8563 'running'
    Kit030 $OLD '2.4.0' 'exa-old'
    Upd
    Check 'launcher 2.4.0 over a starter-kit-local: updated' '|personal|updated' "$($script:updThrew)|$(Row)"
    Hasnt '...with no rename' 'Renaming the database' (Said)
    Check '...moved by the new launcher and followed' "yes|$NEW" "$(YN (Test-Path $NEW))|$($script:mf['runtime.deployment_dir'])"
    Check '...one restart' "2.4.0 stop --deployment-dir $OLD`n2.5.0 start --deployment-dir $NEW" (Calls 'stop|start')

    Write-Host "the rename target exists: nothing is changed:"
    Reset-Home
    Seed $DEF 'exa-t1' 8563 'running'
    Kit030 $DEF '2.4.0' 'exa-t1'
    New-Item -ItemType Directory -Force -Path $OLD | Out-Null
    $oldSha = Sha $script:PersonalBinPath
    Upd
    Check 'the update runs to its end' '' $script:updThrew
    Check 'the row waits for the next update' 'personal|deferred|exakit update' (Row -Remedy)
    Has 'said, with the folder in the way' "WARN The database 'default' was not renamed to 'starter-kit-local', because $tildeOld already exists. Nothing was changed." (Said)
    Has '...and when it is tried again' 'INFO The next exakit update tries again.' (Said)
    Check 'nothing stopped, nothing downloaded' '|0' "$(Calls 'stop|start')|$($script:downloads.Count)"
    Check '...still running, still default, the launcher as it was' "running|yes|$oldSha" "$(State 'exa-t1')|$(YN (Test-Path $DEF))|$(Sha $script:PersonalBinPath)"
    Check '...the records as they were' "$DEF|2.4.0" "$($script:mf['runtime.deployment_dir'])|$($script:mf['runtime.version'])"
    Hasnt '...never called updated' 'Runtime updated' (Said)
    Has '...the reason kept for exakit status --json' "was not renamed to 'starter-kit-local'" (Note)
    Remove-Item -LiteralPath $OLD -Force
    Upd
    Check 'the folder out of the way: the next update goes through' '|personal|updated|yes' "$($script:updThrew)|$(Row)|$(YN (Test-Path $NEW))"
    Check '...and the earlier reason is gone' 'no' (YN (Test-Path $script:FailureNotePath))
    Reset-Home
    Seed $DEF 'exa-t2' 8563 'running'
    Kit030 $DEF '2.4.0' 'exa-t2'
    New-Item -ItemType Directory -Force -Path $NEW | Out-Null
    Upd
    Has 'a starter-kit-local in the 2.5 root blocks it too (2.5 would not move one onto it)' "because $tildeNew already exists. Nothing was changed." (Said)
    Check '...nothing stopped' '|running' "$(Calls 'stop|start')|$(State 'exa-t2')"
    Reset-Home
    Seed $DEF 'exa-t3' 8563
    Kit030 $DEF '2.4.0' 'exa-t3'
    [IO.File]::WriteAllText((Join-Path $DEF '.dirmutex.exclusive'), '')
    Upd
    Has 'a launcher command holding it: not renamed' 'because another Exasol Personal command is using it. Nothing was changed.' (Said)
    Check '...the row waits' 'personal|deferred' (Row)
    Remove-Item -LiteralPath (Join-Path $DEF '.dirmutex.exclusive') -Force
    # --json: the reason travels with the row.
    Reset-Home
    Seed $DEF 'exa-t4' 8563 'running'
    Kit030 $DEF '2.4.0' 'exa-t4'
    New-Item -ItemType Directory -Force -Path $OLD | Out-Null
    Upd
    $j = Json
    Check '--json: one object, deferred' 'deferred' $j.status
    Check '--json: the personal row, remedy exakit update' 'personal|exakit update' "$($j.deferred[0].component)|$($j.deferred[0].remedy)"
    Has '--json: the row says why' 'already exists' $j.deferred[0].error
    Check '--json: the hint is the row''s' 'Run exakit update again once that is solved.' $j.remedy_hint
    Check '--json: still running, not renamed' 'running|yes' "$(State 'exa-t4')|$(YN (Test-Path $DEF))"
    Remove-Item -LiteralPath $OLD -Force
    Upd
    $j = Json
    Check '--json: the next update goes through' 'updated|personal' "$($j.status)|$($j.updated[0].component)"
    Check '--json: ...and the earlier reason is gone' 'no' (YN (Test-Path $script:FailureNotePath))

    Write-Host "a swap that fails is put back:"
    # The download fails its checksum: no new launcher.
    Reset-Home
    Seed $DEF 'exa-u1' 8563 'running'
    Kit030 $DEF '2.4.0'
    $oldSha = Sha $script:PersonalBinPath
    $oldReceipt = $script:mf['components.personal.ownership_sha256']
    $script:download = Join-Path $work 'corrupt'
    Upd
    Check 'the update runs to its end, the row waits' '|personal|deferred|exakit update' "$($script:updThrew)|$(Row -Remedy)"
    Has 'the checksum is what failed' 'does not match the checksum this kit pins' (Said)
    Has 'said, with what is as it was' 'WARN Exasol Personal was not updated to 2.5.0, because the new launcher could not be installed. The launcher and the database are as they were.' (Said)
    Check 'the launcher put back, with its receipt' "$oldSha|$oldReceipt|kit" ("{0}|{1}|{2}" -f (Sha $script:PersonalBinPath), $script:mf['components.personal.ownership_sha256'], $script:mf['components.personal.ownership'])
    Check 'the folder renamed back' 'yes|no|no' "$(YN (Test-Path $DEF))|$(YN (Test-Path $OLD))|$(YN (Test-Path $NEW))"
    Check 'the records put back' "$DEF|$DEF|default|2.4.0" ("{0}|{1}|{2}|{3}" -f $script:mf['runtime.deployment_dir'], $script:mf['runtime.ownership_path'], $script:mf['runtime.deployment_name'], $script:mf['runtime.version'])
    Check 'it ran, so it runs again, started by the old launcher on its old folder' "2.4.0 stop --deployment-dir $DEF`n2.4.0 start --deployment-dir $DEF|running" "$(Calls 'stop|start')|$(State 'exa-u1')"
    Check 'no 2.5 command ever ran' '' (First25)
    Check 'its limit is as it was' 'yes' (YN ((Conf $DEF) -match 'maxConnectionsLicenseLimit'))
    Check 'the copy of the launcher is gone' 'no' (YN (Test-Path $COPY))
    Hasnt '...never called updated' 'Runtime updated' (Said)
    # Stopped before: put back, and not started.
    Reset-Home
    Seed $DEF 'exa-u2' 8563
    Kit030 $DEF '2.4.0' 'exa-u2'
    $script:download = Join-Path $work 'corrupt'
    Upd
    Check 'stopped before: put back, the row waits' 'personal|deferred|yes' "$(Row)|$(YN (Test-Path $DEF))"
    Check '...and never started' '|stopped' "$(Calls 'stop|start')|$(State 'exa-u2')"
    # The new launcher is installed but does not run: put back.
    Reset-Home
    Seed $DEF 'exa-u3' 8563 'running'
    Kit030 $DEF '2.4.0' 'exa-u3'
    $oldSha = Sha $script:PersonalBinPath
    $script:download = Join-Path $work 'exasol-silent'; $script:pin = Sha $script:download
    Upd
    Has 'a launcher that does not run: said' 'because the new launcher did not run on this computer. The launcher and the database are as they were.' (Said)
    Check '...put back: the launcher, the folder, the records, running again' "$oldSha|yes|$DEF|running" "$(Sha $script:PersonalBinPath)|$(YN (Test-Path $DEF))|$($script:mf['runtime.deployment_dir'])|$(State 'exa-u3')"
    Check '...the kit''s receipt names the launcher put back' 'True' ((Get-FileHash -LiteralPath $script:PersonalBinPath).Hash -eq $script:mf['components.personal.ownership_sha256'])
    # The new launcher moves the folder on its first command, then does not
    # answer: the folder comes back from the 2.5 root.
    Reset-Home
    Seed $DEF 'exa-u4' 8563 'running'
    Kit030 $DEF '2.4.0' 'exa-u4'
    $script:download = Join-Path $work 'exasol-2.5.0-broken'; $script:pin = Sha $script:download
    Upd
    Has 'it moved the folder first, then did not answer' "2.5.0 version [$NAME]" (($script:calls | ForEach-Object { "$_" }) -join "`n")
    Check '...the folder is brought back to its 0.3.0 place and name' 'yes|no|no' "$(YN (Test-Path $DEF))|$(YN (Test-Path $NEW))|$(YN (Test-Path $OLD))"
    Check '...its data with it, the records put back' "tables of exa-u4|$DEF|default" ("{0}|{1}|{2}" -f [IO.File]::ReadAllText([IO.Path]::Combine($DEF, 'local', 'runtime', 'exa', 'data.bin')), $script:mf['runtime.deployment_dir'], $script:mf['runtime.deployment_name'])
    Check '...the old launcher back, the database running again' '2.4.0|running' "$(([IO.File]::ReadAllText($script:PersonalBinPath)).Trim())|$(State 'exa-u4')"
    Has '...nothing else was there to move: all as it was' 'because the new launcher did not run on this computer. The launcher and the database are as they were.' (Said)
    # The user's other stopped deployments in the older root: the new
    # launcher's first command moved them too, and the old launcher, put
    # back, does not look where they are now. Never "as they were": said
    # where they are. Twin of the L1 case in personal-update-rename.sh.
    Reset-Home
    Seed $DEF 'exa-u6' 8563 'running'
    Seed (Join-Path $OLDROOT 'demo') 'exa-demo' 8600
    Seed (Join-Path $OLDROOT 'dev') 'exa-dev6' 8601
    Kit030 $DEF '2.4.0' 'exa-u6'
    $script:download = Join-Path $work 'exasol-2.5.0-broken'; $script:pin = Sha $script:download
    Upd
    Check 'their others moved by the new launcher''s one run, the kit''s own back' 'yes|yes|yes|no' "$(YN (Test-Path $DEF))|$(YN (Test-Path (Join-Path $NEWROOT 'demo')))|$(YN (Test-Path (Join-Path $NEWROOT 'dev')))|$(YN (Test-Path (Join-Path $OLDROOT 'demo')))"
    Hasnt '...never said to be as they were' 'The launcher and the database are as they were.' (Said)
    Has '...the kit''s own database named as the one as it was' "WARN Exasol Personal was not updated to 2.5.0, because the new launcher did not run on this computer. The launcher and the database 'default' are as they were." (Said)
    Has '...and where theirs are now' "INFO Your other databases 'demo' and 'dev' are now in $(Get-ExakitTilde $NEWROOT), where Exasol Personal 2.5 keeps them." (Said)
    Reset-Home
    Seed $DEF 'exa-u7' 8563 'running'
    Seed (Join-Path $OLDROOT 'demo') 'exa-demo7' 8600
    Kit030 $DEF '2.4.0' 'exa-u7'
    $script:download = Join-Path $work 'exasol-2.5.0-broken'; $script:pin = Sha $script:download
    Upd
    Has 'one other: said as one' "INFO Your other database 'demo' is now in $(Get-ExakitTilde $NEWROOT), where Exasol Personal 2.5 keeps it." (Said)
    Reset-Home
    Seed $DEF 'exa-u8' 8563 'running'
    Seed (Join-Path $OLDROOT 'demo') 'exa-demo8' 8600
    Kit030 $DEF '2.4.0' 'exa-u8'
    $script:download = Join-Path $work 'corrupt'
    Upd
    Check 'a swap that never ran the new launcher: theirs not moved, all as it was' 'yes|yes' "$(YN (Test-Path (Join-Path $OLDROOT 'demo')))|$(YN ((Said).Contains('The launcher and the database are as they were.')))"
    # The stop fails: nothing is changed.
    Reset-Home
    Seed $DEF 'exa-u5' 8563 'running'
    Kit030 $DEF '2.4.0' 'exa-u5'
    $script:stopRc = 1
    Upd
    $script:stopRc = 0
    Has 'the stop fails: said' 'WARN The database did not stop, so it was not updated. Nothing was changed.' (Said)
    Check '...still running, not renamed, nothing downloaded' 'running|yes|0' "$(State 'exa-u5')|$(YN (Test-Path $DEF))|$($script:downloads.Count)"
    Check '...the row waits' 'personal|deferred' (Row)

    Write-Host "the new launcher's first command is slow (the move of the older root, antivirus): the update stands:"
    # Its first `version` is not a probe: 2.5 moves the older root first, and
    # Windows scans a new program file before its first run. A first command
    # of 12 s used to run out of the probes' 10 s and put the update back.
    Reset-Home
    Seed $DEF 'exa-f1' 8563 'running'
    Kit030 $DEF '2.4.0' 'exa-f1'
    $script:download = Join-Path $work 'exasol-2.5.0-slow'; $script:pin = Sha $script:download
    Upd
    Check 'a first command of 12 s: updated, not put back' "personal|updated|$NEW|running" "$(Row)|$($script:mf['runtime.deployment_dir'])|$(State 'exa-f1')"
    Check '...its first version given 120 s' '120' "$($script:firstRunBudget)"
    Hasnt '...never said as a launcher that did not run' 'did not run on this computer' (Said)
    Reset-Home
    Seed $DEF 'exa-f2' 8563 'running'
    Kit030 $DEF '2.4.0' 'exa-f2'
    $script:download = Join-Path $work 'exasol-2.5.0-hangsonce'; $script:pin = Sha $script:download
    Upd
    Check 'a first command that runs out of time and then answers: asked once more, updated' "personal|updated|$NEW" "$(Row)|$($script:mf['runtime.deployment_dir'])"

    Write-Host "the copy of the old launcher that an update could not put back is never written over:"
    # The new launcher did not answer, and the old one could not be written
    # back over it (the killed probe still held the file): the undo names the
    # copy. A later update never writes over that copy, the only one of the
    # old launcher, nor removes it: it keeps its own copy beside it, and its
    # own undo puts back only what it replaced.
    # The kit's launcher already in the kit's own folder (it left PATH in an
    # earlier update), so this update replaces it there, in place.
    function Set-PartialUndo([string]$Id) {
        Reset-Home
        Seed $DEF $Id 8563 'running'
        Kit030 $DEF '2.4.0' $Id
        $sep = Get-PersonalSeparateBinPath
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $sep) | Out-Null
        Move-Item -LiteralPath $script:PersonalBinPath -Destination $sep -Force
        Use-PersonalSeparateLauncher
        Set-ExakitManifestValue 'runtime.launcher' $sep
        Set-ExakitComponentOwnership 'personal' 'kit' $sep
        $script:download = Join-Path $work 'exasol-2.5.0-broken'; $script:pin = Sha $script:download
        function Copy-Item {
            [CmdletBinding()] param([string]$LiteralPath, [string]$Destination, [switch]$Force)
            if ($Destination -eq $script:PersonalBinPath) { throw 'The process cannot access the file because it is being used by another process.' }
            Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
        }
        Upd
        Remove-Item Function:\Copy-Item
    }
    function Copied([string]$File) { if (Test-Path -LiteralPath $File -PathType Leaf) { return ([IO.File]::ReadAllText($File)).Trim() }; return 'gone' }
    function OtherCopies { return @(Get-ChildItem -LiteralPath $COPY -Directory -Force -ErrorAction SilentlyContinue).Count }
    $copyFile = Join-Path $COPY 'exasol.exe'
    Set-PartialUndo 'exa-c1'
    Has 'the first update: the launcher not put back, its copy named' "WARN The launcher could not be put back. A copy of it is at $(Get-ExakitTilde $copyFile)." (Said)
    Check '...the copy holds the old launcher, the new one is in place' '2.4.0|2.5.0 broken' "$(Copied $copyFile)|$(([IO.File]::ReadAllText($script:PersonalBinPath)).Trim())"
    $script:download = Join-Path $work 'corrupt'
    Upd
    Check 'a later update that fails too: the row waits, the launcher as this update found it' 'personal|deferred|2.5.0 broken' "$(Row)|$(([IO.File]::ReadAllText($script:PersonalBinPath)).Trim())"
    Has '...said as it was, its own copy put nothing back over it' 'The launcher and the database are as they were.' (Said)
    Check '...the earlier copy kept as it was, this update''s own gone' '2.4.0|0' "$(Copied $copyFile)|$(OtherCopies)"
    Set-PartialUndo 'exa-c2'
    New-Item -ItemType Directory -Force -Path $NEW | Out-Null
    $script:download = Join-Path $work 'exasol-2.5.0'; $script:pin = $script:pin25
    Upd
    Has 'a later update that stops before the swap (the target is there)' 'already exists. Nothing was changed.' (Said)
    Check '...keeps that copy, as it was' '2.4.0|0' "$(Copied $copyFile)|$(OtherCopies)"
    Remove-Item -LiteralPath $NEW -Recurse -Force
    Upd
    Check '...and one that goes through: updated, the earlier copy still where its undo named it' "personal|updated|$($script:pin25)|2.4.0|0" "$(Row)|$(Sha $script:PersonalBinPath)|$(Copied $copyFile)|$(OtherCopies)"

    Write-Host "a manifest that cannot be written, between the rename and the end of the swap, and after it:"
    # Between the rename and the end of the swap, the full undo: the swap is
    # caught whatever fails in it, a receipt that cannot be written included.
    Reset-Home
    Seed $DEF 'exa-m1' 8563 'running'
    Kit030 $DEF '2.4.0' 'exa-m1'
    $oldSha = Sha $script:PersonalBinPath
    & {
        function Set-ExakitManifestValue([string]$Path, $Value) {
            if ($Path -eq 'components.personal.ownership') { throw 'manifest locked (fixture)' }
            $script:mf[$Path] = $Value
        }
        Upd
    }
    Check 'the launcher''s receipt cannot be written: the row waits' 'personal|deferred' (Row)
    Has '...said, with everything as it was' 'because the new launcher could not be installed. The launcher and the database are as they were.' (Said)
    Check '...the launcher, the folder and the records put back, running again' "$oldSha|yes|$DEF|default|running" "$(Sha $script:PersonalBinPath)|$(YN (Test-Path $DEF))|$($script:mf['runtime.deployment_dir'])|$($script:mf['runtime.deployment_name'])|$(State 'exa-m1')"
    # The rename's own record cannot be written (the kit home read-only right
    # after the stop): the folder goes back, the record as it was, and the
    # database that ran starts again with the old launcher. Twin of the 5b
    # case in personal-update-rename.sh.
    Reset-Home
    Seed $DEF 'exa-m4' 8563 'running'
    Kit030 $DEF '2.4.0' 'exa-m4'
    $oldSha = Sha $script:PersonalBinPath
    & {
        function Set-ExakitManifestValue([string]$Path, $Value) {
            if (@('runtime.deployment_dir', 'runtime.ownership_path', 'runtime.deployment_name') -contains $Path) { throw 'manifest locked (fixture)' }
            $script:mf[$Path] = $Value
        }
        Upd
    }
    Has 'the rename''s record cannot be written: said' "WARN The database 'default' was not renamed to 'starter-kit-local', because the kit could not write its record. Nothing was changed." (Said)
    Check '...the folder back as default, the record as it was, started again by 2.4.0 on it, the launcher as it was, the row waits' "yes|no|$DEF|2.4.0 stop --deployment-dir $DEF`n2.4.0 start --deployment-dir $DEF|running|$oldSha|personal|deferred" "$(YN (Test-Path $DEF))|$(YN (Test-Path $OLD))|$($script:mf['runtime.deployment_dir'])|$(Calls 'stop|start')|$(State 'exa-m4')|$(Sha $script:PersonalBinPath)|$(Row)"
    # After the swap, a record step that fails no longer leaves the database
    # stopped: the one start still comes, and the failure still ends the row.
    Reset-Home
    Seed $DEF 'exa-m2' 8563 'running'
    Kit030 $DEF '2.4.0' 'exa-m2'
    & {
        function Set-PersonalManifest { param([string]$Status = '', [switch]$Fresh) throw 'manifest locked (fixture)' }
        Upd
    }
    Check 'the record after the swap cannot be written: the row is failed, with that reason' 'personal|failed|manifest locked (fixture)' "$(Row)|$(RowError)"
    Check '...the database that ran runs again, once, by the new launcher' "running|2.5.0 start --deployment-dir $NEW" "$(State 'exa-m2')|$(Calls 'start')"
    Reset-Home
    $m3 = Join-Path $NEWROOT 'default'
    Seed $m3 'exa-m3' 8563 'running'
    Kit030 $m3 '2.5.0' 'exa-m3'
    & {
        function Remove-PersonalSessionLimit { throw 'manifest locked (fixture)' }
        Upd
    }
    Check 'no launcher to swap, the lift after the rename fails: the database runs again' "manifest locked (fixture)|running|yes" "$($script:updThrew)|$(State 'exa-m3')|$(YN (Test-Path $NEW))"

    Write-Host "the start after the update fails without the limit: the file is put back:"
    Reset-Home
    Seed $DEF 'exa-s1' 8563 'running'
    Kit030 $DEF '2.4.0' 'exa-s1'
    $script:startFails = 1
    Upd
    Check 'updated (the launcher and the name stand)' "personal|updated|$NEW" "$(Row)|$($script:mf['runtime.deployment_dir'])"
    Has 'said, as the lift says it' 'The 20-session limit was not removed, because the database did not start without it. The file is as it was, and the database is running again.' (Said)
    Check '...the file as it was, not recorded as lifted, running' 'yes||running' "$(YN ((Conf $NEW) -match 'maxConnectionsLicenseLimit'))|$($script:mf['runtime.session_limit'])|$(State 'exa-s1')"
    Hasnt '...and the update does not start it a second time' 'Bringing the database back up' (Said)

    Write-Host "a launcher file another program runs (Windows does not replace it):"
    # Found before anything stops: nothing changed, and exakit update asked for again.
    Reset-Home
    Seed $DEF 'exa-w1' 8563 'running'
    Kit030 $DEF '2.4.0' 'exa-w1'
    $oldSha = Sha $script:PersonalBinPath
    $script:inUse = @($script:PersonalBinPath)
    function Test-PersonalLauncherInUse { param([string]$Path = '') return (@($script:inUse) -contains $Path) }
    Upd
    Check 'in use: the row waits for the next update' 'personal|deferred|exakit update' (Row -Remedy)
    Has '...said why' "WARN Exasol Personal was not updated, because another program is using the launcher at $(Get-ExakitTilde $script:PersonalBinPath). Nothing was changed." (Said)
    Has '...and what to do' 'INFO Close that program, then run exakit update again.' (Said)
    Check '...nothing stopped, renamed or downloaded' '|yes|0|running' "$(Calls 'stop|start')|$(YN (Test-Path $DEF))|$($script:downloads.Count)|$(State 'exa-w1')"
    Check '...the launcher as it was' $oldSha (Sha $script:PersonalBinPath)
    Has '...the reason kept for exakit status --json' 'another program is using the launcher' (Note)
    # Taken by another program during the stop: the swap is refused, and put back.
    Reset-Home
    Seed $DEF 'exa-w2' 8563 'running'
    Kit030 $DEF '2.4.0' 'exa-w2'
    $oldSha = Sha $script:PersonalBinPath
    $script:inUse = @()
    $script:inUseAsked = 0
    function Test-PersonalLauncherInUse { param([string]$Path = '') $script:inUseAsked++; return ($script:inUseAsked -gt 1) }
    function Move-Item { throw 'The process cannot access the file because it is being used by another process.' }
    Upd
    Remove-Item Function:\Move-Item
    Check 'in use at the swap: the row waits' 'personal|deferred|exakit update' (Row -Remedy)
    # The swap is into the kit's own folder now (the launcher leaves PATH):
    # the launcher named is the one there (W2).
    Has '...said why, and that all is as it was' "WARN Exasol Personal was not updated to 2.5.0, because another program is using the launcher at $(Get-ExakitTilde (Get-PersonalSeparateBinPath)). The launcher and the database are as they were." (Said)
    Has '...and what to do' 'INFO Close that program, then run exakit update again.' (Said)
    Check '...the folder, the records and the launcher put back' "yes|$DEF|$oldSha" "$(YN (Test-Path $DEF))|$($script:mf['runtime.deployment_dir'])|$(Sha $script:PersonalBinPath)"
    Check '...started again by the old launcher' "2.4.0 stop --deployment-dir $DEF`n2.4.0 start --deployment-dir $DEF|running" "$(Calls 'stop|start')|$(State 'exa-w2')"
    function Test-PersonalLauncherInUse { param([string]$Path = '') return $false }
    # The kit itself swapped under the run (staged until this process exits):
    # the database's row waits for the new kit's `exakit update`.
    Reset-Home
    Seed $DEF 'exa-w3' 8563 'running'
    Kit030 $DEF '2.4.0' 'exa-w3'
    $script:targets = @('exakit', 'personal')
    Upd
    Check 'kit swapped: the database row waits' 'personal|deferred|exakit update' (Row -Remedy)
    Has '...run exakit update again, said' "INFO The starter kit itself was updated; run 'exakit update' again so the rest is updated by the new kit." (Said)
    Check '...nothing stopped, renamed or downloaded' '|yes|0' "$(Calls 'stop|start')|$(YN (Test-Path $DEF))|$($script:downloads.Count)"
    $j = Json
    Check '--json: the hint says to run it again' "the starter kit itself was updated; run 'exakit update' again so the rest is updated by the new kit" $j.remedy_hint
    # The real check: no program runs from a file that is not running.
    Remove-Item Function:\Test-PersonalLauncherInUse
    foreach ($fn in ([Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'setup/lib/runtime-personal.ps1'), [ref]$null, [ref]$null)).FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-PersonalLauncherInUse' }, $true)) {
        Invoke-Expression $fn.Extent.Text
    }
    Check 'a launcher file no program runs is not in use' 'False|False' "$(Test-PersonalLauncherInUse -Path $script:PersonalBinPath)|$(Test-PersonalLauncherInUse -Path (Join-Path $work 'nothing-here.exe'))"

    Write-Host "exakit update personal, named: a put-back is failed, as on macOS and Linux, and only a launcher in use waits:"
    # The same event gives the same row and exit code on both platforms
    # (review F-02): an explicit update that was put back is failed, remedy
    # `exakit update personal`, and the run exits 1. Windows alone meets a
    # launcher another program runs: that row waits for the next update, as
    # the update said ("Close that program, then run exakit update again.").
    function UpdNamed {
        $script:calls.Clear(); $script:said.Clear(); $script:downloads.Clear()
        Fresh
        $script:ExakitUpdateJson = $true
        $script:ExakitUpdateResults = New-Object System.Collections.ArrayList
        $script:updThrew = ''
        try { Invoke-ExakitUpdateRun -Target 'personal' -Components @('personal') -AssumeYes $false 6>$null | Out-Null } catch { $script:updThrew = "$($_.Exception.Message)" }
        Remove-Item Env:EXAKIT_PERSONAL_VERSION -ErrorAction SilentlyContinue
    }
    Reset-Home
    Seed $DEF 'exa-n1' 8563 'running'
    Kit030 $DEF '2.4.0' 'exa-n1'
    $script:download = Join-Path $work 'corrupt'
    UpdNamed
    Check 'a swap that failed and was put back: the row is failed, remedy exakit update personal' '|personal|failed|exakit update personal' "$($script:updThrew)|$(Row -Remedy)"
    Check '...with the reason the update gave' 'Exasol Personal was not updated to 2.5.0, because the new launcher could not be installed' (RowError)
    Check '...and it was put back: default, the old launcher, running' "yes|2.4.0|running" "$(YN (Test-Path $DEF))|$(([IO.File]::ReadAllText($script:PersonalBinPath)).Trim())|$(State 'exa-n1')"
    Reset-Home
    Seed $DEF 'exa-n2' 8563 'running'
    Kit030 $DEF '2.4.0' 'exa-n2'
    New-Item -ItemType Directory -Force -Path $OLD | Out-Null
    UpdNamed
    Check 'not renamed (the target is there): failed too' 'personal|failed|exakit update personal' (Row -Remedy)
    Remove-Item -LiteralPath $OLD -Force
    Reset-Home
    Seed $DEF 'exa-n3' 8563 'running'
    Kit030 $DEF '2.4.0' 'exa-n3'
    $script:inUse = @($script:PersonalBinPath)
    function Test-PersonalLauncherInUse { param([string]$Path = '') return (@($script:inUse) -contains $Path) }
    UpdNamed
    Check 'a launcher another program runs (Windows only): the row waits for the next update' 'personal|deferred|exakit update' (Row -Remedy)
    Reset-Home
    Seed $DEF 'exa-n4' 8563 'running'
    Kit030 $DEF '2.4.0' 'exa-n4'
    $script:inUseAsked = 0
    function Test-PersonalLauncherInUse { param([string]$Path = '') $script:inUseAsked++; return ($script:inUseAsked -gt 1) }
    function Move-Item { throw 'The process cannot access the file because it is being used by another process.' }
    UpdNamed
    Remove-Item Function:\Move-Item
    Check '...and one that meets it at the swap, put back: waits too' 'personal|deferred|exakit update' (Row -Remedy)
    Remove-Item Function:\Test-PersonalLauncherInUse
    foreach ($fn in ([Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'setup/lib/runtime-personal.ps1'), [ref]$null, [ref]$null)).FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-PersonalLauncherInUse' }, $true)) {
        Invoke-Expression $fn.Extent.Text
    }
    # On the screen the run ends with exit 1 (a put-back) or 0 (in use), so
    # the closing lines and the code are read from a child process of the same
    # engine.
    $namedChild = Join-Path $work 'named-update-child.ps1'
    Set-Content -LiteralPath $namedChild -Encoding ASCII -Value @'
param([string]$Repo, [string]$Mode)
$ErrorActionPreference = "Stop"
$t = $null; $e = $null
$cliAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo "setup/exakit.ps1"), [ref]$t, [ref]$e)
$libAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo "setup/lib/exakit-common.ps1"), [ref]$t, [ref]$e)
foreach ($pair in @(@($cliAst, "Invoke-ExakitUpdateRun"), @($cliAst, "Get-ExakitUpdateFailureRemedy"), @($libAst, "Get-ExakitOwnershipKey"), @($libAst, "Get-ExakitVersionPlain"), @($libAst, "Test-ExakitVersionSame"))) {
    $wanted = $pair[1]
    $node = $pair[0].Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $wanted }, $true)
    Invoke-Expression $node.Extent.Text
}
$script:VersionPolicy = "pinned"
$script:ExakitUpdateJson = $false
function Write-ExakitVersionsSourceLine { }
function Add-ExakitUpdateNote { }
function Info([string]$Message) { Write-Host "info: $Message" }
function Ok([string]$Message) { Write-Host "ok: $Message" }
function Warn2([string]$Message) { Write-Host "warn: $Message" }
function Get-ExakitActualTarget([string]$Name) { return $Name }
function Get-ExakitComponentCurrent([string]$Name) { return "2.4.0" }
function Get-ExakitComponentAvailable([string]$Name) { return "2.5.0" }
function Get-ExakitManifestValue([string]$Key) { return $null }
function Test-ExakitComponentManaged { return $true }
function Test-ExakitComponentSupported { return $true }
function Test-ExakitComponentAhead { return $false }
function Test-ExakitComponentHeavy { return $true }
function Test-ExakitAddonNeedsUpdate { return $false }
function Test-ExakitAddonSystemPresent { return $false }
function Test-ExakitSkillsUnplaced { return $false }
function Get-ExakitComponentMinKit { return "" }
function Get-ExakitMarketplaceAddon([string]$Id) { return $null }
# The update of the database, put back: said by the updater, then this.
function Invoke-ExakitRuntimeComponentUpdate {
    param([string]$Component, [string]$Advertised)
    $script:PersonalUpdateResult = "undone"
    $script:PersonalUpdateWhy = "Exasol Personal was not updated to 2.5.0, because the new launcher could not be installed"
    $script:PersonalUpdateInUse = ($Mode -eq "inuse")
}
Invoke-ExakitUpdateRun -Target "personal" -Components @("personal")
exit 0
'@
    $engine = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    function Invoke-NamedChild([string]$Mode) {
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $out = & $engine -NoProfile -ExecutionPolicy Bypass -File $namedChild -Repo $repo -Mode $Mode 2>&1 | Out-String; $code = $LASTEXITCODE }
        finally { $ErrorActionPreference = $previous }
        return [pscustomobject]@{ Out = $out; Code = $code }
    }
    $named = Invoke-NamedChild 'putback'
    Check 'on the screen, put back: exit 1, as on macOS and Linux' '1' "$($named.Code)"
    Has '...said as there' 'warn: personal did not update. Details: exakit logs' $named.Out
    Has '...and the run closes with problems' 'warn: Update finished with problems. Retry with: exakit update' $named.Out
    Hasnt '...never as a deferred runtime change' 'deferred runtime change' $named.Out
    $named = Invoke-NamedChild 'inuse'
    Check 'a launcher in use: exit 0, the change waits' '0' "$($named.Code)"
    Has '...said as deferred' 'info: See everything, including the deferred runtime change: exakit version' $named.Out
    Hasnt '...not as a failure' 'did not update' $named.Out

    Write-Host "owner user: a database the user let the 0.3.0 kit use, run by their own 2.4.0:"
    $THEIRS = [IO.Path]::Combine($work, 'userbin', 'exasol.exe')
    Reset-Home
    Seed $DEF 'exa-usr' 8563 'running'
    Seed (Join-Path $OLDROOT 'dev') 'exa-dev' 8564
    User030 $DEF $THEIRS '2.4.0'
    Upd
    Check 'succeeds, updated' '|personal|updated' "$($script:updThrew)|$(Row)"
    # #41 (Krishna, 24 Nov): a launcher of the user's is never written.
    Check 'their launcher, at its own path, is as it was' $script:sha24 (Sha $THEIRS)
    # The kit runs its own launcher from now on (Krishna, 24 Nov): the same
    # checked release in the kit's folder, recorded as the kit's. Theirs is
    # recorded as theirs.
    Check '...and stays theirs: the kit records its own 2.5 in its folder, theirs as theirs' "kit|$(Get-PersonalSeparateBinPath)|True|$($script:pin25)|$THEIRS" ("{0}|{1}|{2}|{3}|{4}" -f $script:mf['components.personal.ownership'], $script:mf['components.personal.ownership_path'], ((Get-FileHash -LiteralPath (Get-PersonalSeparateBinPath)).Hash -eq $script:mf['components.personal.ownership_sha256']), (Sha (Get-PersonalSeparateBinPath)), $script:mf['components.personal.user_launcher'])
    Check '...which the kit runs from now on' (Get-PersonalSeparateBinPath) (Get-PersonalCli)
    Check 'their database is starter-kit-local, still theirs' "yes|no|user|$NEW|$NEW" ("{0}|{1}|{2}|{3}|{4}" -f (YN (Test-Path $NEW)), (YN (Test-Path $DEF)), $script:mf['runtime.ownership'], $script:mf['runtime.ownership_path'], $script:mf['runtime.deployment_dir'])
    Fresh
    Check '...never managed, so never destroyed' 'False' (Test-ExakitComponentManaged 'database')
    Check '...its id recorded (0.3.0 kept none for theirs)' 'exa-usr' $script:mf['runtime.deployment_id']
    Check '...its limit lifted' 'no|lifted' "$(YN ((Conf $NEW) -match 'maxConnectionsLicenseLimit'))|$($script:mf['runtime.session_limit'])"
    Check 'one restart: stopped by their 2.4, started by the kit''s 2.5' "2.4.0 stop --deployment-dir $DEF`n2.5.0 start --deployment-dir $NEW|running" "$(Calls 'stop|start')|$(State 'exa-usr')"
    Has 'nothing 2.5 ran before the rename' "[dev $NAME]" (First25)
    Before 'the download came before the stop' 'Downloading Exasol launcher v2.5.0' 'OK Database stopped'
    Hasnt 'nothing says their launcher is updated' 'your Exasol Personal launcher' (Said).ToLowerInvariant().Replace('your exasol personal launcher', 'your Exasol Personal launcher')
    Has 'said: where the kit''s launcher is' "INFO The kit's Exasol launcher is now in $(Get-ExakitTilde (Split-Path -Parent (Get-PersonalSeparateBinPath))). Run it with: exakit exasol" (Said)
    Has '...line 5' $L5 (Said)
    Check 'their other database: moved by the kit''s 2.5 (accepted), never stopped or started' 'yes|stopped|0' "$(YN (Test-Path (Join-Path $NEWROOT 'dev')))|$(State 'exa-dev')|$(@($script:calls | Where-Object { ("$_" -replace ' \[[^\]]*\]$', '') -match '^\S+ (stop|start) .*[\\/]dev$' }).Count)"
    Upd
    Check 'a second update: nothing to do (the kit''s own launcher is at the pin)' 'personal|current' (Row)
    Write-Host "Q15: the 0.3.0 kit's own database, deployed with the user's own 2.4.0:"
    # Krishna, 24 Nov: every 0.3.0 user goes to 2.5. The owner-user update: the
    # kit's own 2.5 in its folder, the database renamed, one restart, their
    # launcher never touched. The database receipt stays the kit's.
    Reset-Home
    Seed $DEF 'exa-q15' 8563 'running'
    Kit030Theirs $DEF $THEIRS '2.4.0'
    Upd
    Check 'Q15, exakit update: updated, their launcher as it was' "|personal|updated|$($script:sha24)" "$($script:updThrew)|$(Row)|$(Sha $THEIRS)"
    Check '...the database starter-kit-local, same id and data, still the kit''s' "yes|no|exa-q15|tables of exa-q15|kit" ("{0}|{1}|{2}|{3}|{4}" -f (YN (Test-Path $NEW)), (YN (Test-Path $DEF)), (Read-PersonalDeploymentId -Dir $NEW), [IO.File]::ReadAllText([IO.Path]::Combine($NEW, 'local', 'runtime', 'exa', 'data.bin')), $script:mf['runtime.ownership'])
    Check '...the same port' '8563' ("" + (Get-PersonalSavedDbPorts -Dir $NEW)[0])
    Check '...one restart: stopped by their 2.4, started by 2.5' "2.4.0 stop --deployment-dir $DEF`n2.5.0 start --deployment-dir $NEW|running" "$(Calls 'stop|start')|$(State 'exa-q15')"
    Check '...the kit''s own 2.5 in its folder, recorded as the kit''s' "kit|$(Get-PersonalSeparateBinPath)|$($script:pin25)" ("{0}|{1}|{2}" -f $script:mf['components.personal.ownership'], $script:mf['components.personal.ownership_path'], (Sha (Get-PersonalSeparateBinPath)))
    # The new launcher does not run: put back exactly.
    Reset-Home
    Seed $DEF 'exa-q15u' 8563 'running'
    Kit030Theirs $DEF $THEIRS '2.4.0'
    $theirSha = Sha $THEIRS
    $script:download = Join-Path $work 'exasol-2.5.0-broken'; $script:pin = Sha $script:download
    Upd
    Check 'Q15, a new launcher that does not run: put back exactly' "$theirSha|yes|user|$THEIRS|no|running" ("{0}|{1}|{2}|{3}|{4}|{5}" -f (Sha $THEIRS), (YN (Test-Path $DEF)), $script:mf['components.personal.ownership'], $script:mf['components.personal.ownership_path'], (YN (Test-Path (Get-PersonalSeparateBinPath))), (State 'exa-q15u'))

    # Their launcher read-only, or a link (a package manager's): nothing of it
    # is written, so neither stands in the way.
    Reset-Home
    Seed $DEF 'exa-ro' 8563 'running'
    User030 $DEF $THEIRS '2.4.0'
    (Get-Item -LiteralPath $THEIRS).IsReadOnly = $true
    Upd
    (Get-Item -LiteralPath $THEIRS).IsReadOnly = $false
    Check 'read-only: updated, their launcher as it was' "|personal|updated|$($script:sha24)|running" "$($script:updThrew)|$(Row)|$(Sha $THEIRS)|$(State 'exa-ro')"
    Reset-Home
    Seed $DEF 'exa-ln' 8563 'running'
    $cellar = [IO.Path]::Combine($work, 'cellar', 'exasol.exe')
    User030 $DEF $cellar '2.4.0'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $THEIRS) | Out-Null
    $linked = $true
    try { New-Item -ItemType SymbolicLink -Path $THEIRS -Target $cellar -ErrorAction Stop | Out-Null } catch { $linked = $false }
    if ($linked) {
        $script:userLauncher = $THEIRS
        Set-ExakitManifestValue 'runtime.launcher' $THEIRS
        Set-ExakitComponentOwnership 'personal' 'user' $THEIRS
        Upd
        Check 'a link: updated, still a link to their file, which is as it was' 'personal|updated|yes|2.4.0|running' "$(Row)|$(YN ([bool](Get-Item -LiteralPath $THEIRS -Force).LinkType))|$(([IO.File]::ReadAllText($cellar)).Trim())|$(State 'exa-ln')"
        Remove-Item -LiteralPath $THEIRS -Force
    } else {
        Write-Host '  skip a link: this machine does not let this user make one'
    }
    # The download fails its check: nothing changed.
    Reset-Home
    Seed $DEF 'exa-dl' 8563 'running'
    User030 $DEF $THEIRS '2.4.0'
    $dlSha = Sha $THEIRS
    $script:download = Join-Path $work 'corrupt'
    Upd
    Has 'a download that fails its check: said' 'Exasol Personal was not updated to 2.5.0, because the new launcher could not be installed. The launcher and the database are as they were.' (Said)
    Check '...nothing stopped, nothing renamed, theirs as it was' "|yes|$dlSha|running" "$(Calls 'stop|start')|$(YN (Test-Path $DEF))|$(Sha $THEIRS)|$(State 'exa-dl')"
    # The rename target exists: put back, theirs as it was.
    Reset-Home
    Seed $DEF 'exa-ut' 8563 'running'
    User030 $DEF $THEIRS '2.4.0'
    $utSha = Sha $THEIRS
    New-Item -ItemType Directory -Force -Path $OLD | Out-Null
    Upd
    Has 'the target exists: said' "because $tildeOld already exists. Nothing was changed." (Said)
    Check '...theirs as it was, still running' "$utSha|running|personal|deferred" "$(Sha $THEIRS)|$(State 'exa-ut')|$(Row)"
    # EXAKIT_CONFIRM_RUNTIME_UPDATE=0 keeps it as it is.
    Reset-Home
    Seed $DEF 'exa-no' 8563 'running'
    User030 $DEF $THEIRS '2.4.0'
    $env:EXAKIT_CONFIRM_RUNTIME_UPDATE = '0'
    Upd
    Remove-Item Env:EXAKIT_CONFIRM_RUNTIME_UPDATE
    Check 'EXAKIT_CONFIRM_RUNTIME_UPDATE=0: left alone, the row waits for --yes' 'personal|deferred|exakit update --yes|running' "$(Row -Remedy)|$(State 'exa-no')"
    # Another program runs their launcher: nothing of it is written, so it does
    # not stand in the way.
    Reset-Home
    Seed $DEF 'exa-uw' 8563 'running'
    User030 $DEF $THEIRS '2.4.0'
    $script:inUse = @($THEIRS)
    function Test-PersonalLauncherInUse { param([string]$Path = '') return (@($script:inUse) -contains $Path) }
    Upd
    Check 'theirs in use: updated, theirs as it was' "personal|updated|$($script:sha24)|running" "$(Row)|$(Sha $THEIRS)|$(State 'exa-uw')"
    # A file in the kit's folder that a program runs: found before anything stops.
    Reset-Home
    Seed $DEF 'exa-uk' 8563 'running'
    User030 $DEF $THEIRS '2.4.0'
    $script:inUse = @(Get-PersonalSeparateBinPath)
    Upd
    Has 'the kit''s own in use: said' "WARN Exasol Personal was not updated, because another program is using the launcher at $(Get-ExakitTilde (Get-PersonalSeparateBinPath)). Nothing was changed." (Said)
    Check '...theirs as it was, nothing stopped or downloaded, the row waits' "$($script:sha24)||0|running|personal|deferred" "$(Sha $THEIRS)|$(Calls 'stop|start')|$($script:downloads.Count)|$(State 'exa-uk')|$(Row)"
    function Test-PersonalLauncherInUse { param([string]$Path = '') return $false }
    # The kit's launcher cannot be put in its folder, does not run, or cannot be
    # recorded: put back, theirs as it was in every case.
    function PutBack([string]$Label, [string]$Id, [scriptblock]$Run) {
        Reset-Home
        Seed $DEF $Id 8563 'running'
        User030 $DEF $THEIRS '2.4.0'
        & $Run
        Check "${Label}: theirs as it was, nothing in the kit's folder" "$($script:sha24)|no" "$(Sha $THEIRS)|$(YN (Test-Path (Get-PersonalSeparateBinPath)))"
        Check '...the folder and the record back, running again by their own 2.4' "yes|$DEF|2.4.0 stop --deployment-dir $DEF`n2.4.0 start --deployment-dir $DEF|running" "$(YN (Test-Path $DEF))|$($script:mf['runtime.deployment_dir'])|$(Calls 'stop|start')|$(State $Id)"
        Check '...the row waits, the record names theirs' "personal|deferred|user|$THEIRS" "$(Row)|$($script:mf['components.personal.ownership'])|$($script:mf['components.personal.ownership_path'])"
        Has '...tried again next time' 'INFO The next exakit update tries again.' (Said)
    }
    PutBack 'the kit''s folder cannot be written' 'exa-ux' { function Move-Item { throw 'Access to the path is denied.' }; Upd }
    PutBack 'the new launcher does not run' 'exa-ub' { $script:download = Join-Path $work 'exasol-2.5.0-broken'; $script:pin = Sha $script:download; Upd }
    PutBack 'the kit''s receipt cannot be written' 'exa-ur' {
        function Set-ExakitManifestValue([string]$Path, $Value) {
            if ($Path -eq 'components.personal.ownership' -and $Value -eq 'kit') { throw 'manifest locked (fixture)' }
            $script:mf[$Path] = $Value
        }
        Upd }
    # Their launcher at 2.5.0 already, their database still default in the 2.5
    # root: renamed, their launcher untouched.
    Reset-Home
    $u25 = Join-Path $NEWROOT 'default'
    Seed $u25 'exa-u25' 8563 'running'
    User030 $u25 $THEIRS '2.5.0'
    Set-ExakitManifestValue 'runtime.deployment_id' 'exa-u25'
    $u25Sha = Sha $THEIRS
    Upd
    Check 'their 2.5.0: renamed, launcher untouched, the database still theirs' "yes|$u25Sha|user" ("{0}|{1}|{2}" -f (YN (Test-Path $NEW)), (Sha $THEIRS), $script:mf['runtime.ownership'])
    # The kit runs only its own launcher (Krishna, 24 Nov): the update puts it
    # in the kit's folder, checksum checked, and theirs stays recorded as theirs.
    Check '...the kit''s own launcher in its folder, the kit''s receipt' "1|$($script:pin25)|kit|$(Get-PersonalSeparateBinPath)|$THEIRS" `
        ("{0}|{1}|{2}|{3}|{4}" -f $script:downloads.Count, (Sha (Get-PersonalSeparateBinPath)), $script:mf['components.personal.ownership'], $script:mf['components.personal.ownership_path'], $script:mf['components.personal.user_launcher'])
    Check '...one restart' 2 (@((Calls 'stop|start') -split "`n" | Where-Object { $_ }).Count)
    Check '...its row' 'personal|current' (Row)
    # A kit database run by the user's own 2.4 (0.3.0 used their launcher):
    # Q15, updated like a database of theirs (the "Q15" cases above), the
    # database receipt staying the kit's.
    Reset-Home
    Seed $DEF 'exa-mix' 8563 'running'
    User030 $DEF $THEIRS '2.4.0'
    Set-ExakitComponentOwnership 'database' 'kit' $DEF
    Upd
    Check 'kit database, their 2.4 (Q15): their launcher as it was, renamed, still the kit''s, running' "$($script:sha24)|yes|kit|running|personal|updated" "$(Sha $THEIRS)|$(YN (Test-Path $NEW))|$($script:mf['runtime.ownership'])|$(State 'exa-mix')|$(Row)"

    Write-Host "the installer run again over a 0.3.0 kit:"
    # The launcher step, as setup-windows.ps1 runs it.
    function Inst-Launcher {
        $script:calls.Clear(); $script:said.Clear(); $script:downloads.Clear()
        Fresh
        $env:EXAKIT_PERSONAL_VERSION = '2.5.0'
        $script:instThrew = ''
        try { Install-PersonalLauncher 6>$null | Out-Null } catch { $script:instThrew = "$($_.Exception.Message)" }
        Remove-Item Env:EXAKIT_PERSONAL_VERSION -ErrorAction SilentlyContinue
    }
    Reset-Home
    Seed $DEF 'exa-i1' 8563 'running'
    Kit030 $DEF '2.4.0'
    Inst-Launcher
    Check 'the launcher step: done' '' $script:instThrew
    Check 'the same steps: renamed, moved, followed, the launcher 2.5.0' "yes|$NEW|$($script:pin25)|kit" ("{0}|{1}|{2}|{3}" -f (YN (Test-Path $NEW)), $script:mf['runtime.deployment_dir'], (Sha $script:PersonalBinPath), $script:mf['components.personal.ownership'])
    Check '...one restart, stopped by the old launcher' "2.4.0 stop --deployment-dir $DEF`n2.5.0 start --deployment-dir $NEW|running" "$(Calls 'stop|start')|$(State 'exa-i1')"
    Has '...line 5' $L5 (Said)
    Hasnt '...nothing 2.5 before the rename' 'default' (First25)
    Check '...the limit lifted' 'lifted' $script:mf['runtime.session_limit']
    Check '...the stop line once, and the update said' '1|yes' "$(@($script:said | Where-Object { "$_" -match 'needs the database stopped' }).Count)|$(YN ($script:said -contains 'OK Runtime updated and the database is running again.'))"
    Reset-Home
    Seed $DEF 'exa-i2' 8563
    Kit030 $DEF '2.4.0'
    Inst-Launcher
    Check 'stopped: the same steps, then started once (Krishna Q8)' "yes|$NEW|2.5.0 start --deployment-dir $NEW|running" ("{0}|{1}|{2}|{3}" -f (YN (Test-Path $NEW)), $script:mf['runtime.deployment_dir'], (Calls 'stop|start'), (State 'exa-i2'))
    Reset-Home
    Seed $DEF 'exa-i6' 8563 'running'
    Kit030 $DEF '2.4.0' 'exa-i6'
    New-Item -ItemType Directory -Force -Path $OLD | Out-Null
    Inst-Launcher
    Check 'the rename cannot happen: the step goes on, nothing changed, not called updated' "|yes|running|no" ("{0}|{1}|{2}|{3}" -f $script:instThrew, (YN (Test-Path $DEF)), (State 'exa-i6'), (YN ((Said).Contains('Runtime updated'))))
    # A deliberate no holds the installer run again back too, whatever state
    # the database is in (WP2-04, RGR-08).
    foreach ($noState in @('running', 'stopped', 'conflict')) {
        Reset-Home
        $seeded = 'running'; if ($noState -eq 'stopped') { $seeded = 'stopped' }
        Seed $DEF 'exa-no1' 8563 $seeded
        Kit030 $DEF '2.4.0' 'exa-no1'
        $env:EXAKIT_CONFIRM_RUNTIME_UPDATE = '0'
        & {
            if ($noState -eq 'conflict') { function Get-PersonalStatus { return 'conflict' } }
            Inst-Launcher
        }
        Remove-Item Env:EXAKIT_CONFIRM_RUNTIME_UPDATE
        Check "=0, ${noState}: nothing stopped, started, renamed or replaced" "|yes|no|$seeded|$($script:sha24)|no" "$(Calls 'stop|start')|$(YN (Test-Path $DEF))|$(YN (Test-Path $NEW))|$(State 'exa-no1')|$(Sha (Join-Path $script:BinDir 'exasol.exe'))|$(YN (Test-Path (Get-PersonalSeparateBinPath)))"
        Has '...said' "was left alone: the database update is answered 'no' (EXAKIT_CONFIRM_RUNTIME_UPDATE)." (Said)
    }
    # The kit's own launcher behind the pin, with no database: the new one goes
    # into the kit's folder, and the file at .local\bin goes only while it is
    # the one the kit recorded, checked right before it goes (WP2-11).
    foreach ($changes in @($false, $true)) {
        Reset-Home
        Copy-Item -LiteralPath (Join-Path $work 'exasol-2.4.0') -Destination $script:PersonalBinPath -Force
        Set-ExakitManifestValue 'runtime.launcher' $script:PersonalBinPath
        Set-ExakitComponentOwnership 'personal' 'kit' $script:PersonalBinPath
        $oldFile = Join-Path $script:BinDir 'exasol.exe'
        & {
            function Get-ExakitFile {
                param([string]$Url, [string]$Dest, [switch]$Soft)
                if ($changes) { Add-Content -LiteralPath $oldFile -Value ' changed by the user' }
                Copy-Item -LiteralPath $script:download -Destination $Dest -Force
                return $true
            }
            Inst-Launcher
        }
        Check "no database, the old file changed during the download = ${changes}: the kit's in its folder, that file $(if ($changes) { 'stays' } else { 'goes' })" "$($script:pin25)|$(YN $changes)" "$(Sha (Get-PersonalSeparateBinPath))|$(YN (Test-Path $oldFile))"
    }
    # The runtime step done: a launcher at 2.5.0 already, default in its root.
    $setupLines = @([IO.File]::ReadAllLines((Join-Path $repo 'setup/setup-windows.ps1')))
    $from = -1; $to = -1
    for ($i = 0; $i -lt $setupLines.Count; $i++) {
        if ($from -lt 0 -and $setupLines[$i].Trim() -eq 'Clear-PersonalStaleRecord') { $from = $i }
        if ($from -ge 0 -and $setupLines[$i] -match 'Remove-PersonalSessionLimit\)') { $to = $i; break }
    }
    $stepLines = @()
    if ($from -ge 0 -and $to -gt $from) { $stepLines = @($setupLines[($from + 1)..$to] | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') } | ForEach-Object { $_.Trim() }) }
    Check 'setup-windows.ps1: the rename before the lift, on the database it reuses' 'Update-PersonalCurrent|Remove-PersonalSessionLimit' (@($stepLines | ForEach-Object { if ($_ -match '\]\(([A-Za-z-]+)\)') { $Matches[1] } }) -join '|')
    function Inst-Runtime {
        $script:calls.Clear(); $script:said.Clear()
        Fresh
        foreach ($line in $stepLines) { Invoke-Expression $line }
    }
    Reset-Home
    $i3 = Join-Path $NEWROOT 'default'
    Seed $i3 'exa-i3' 8563 'running'
    Kit030 $i3 '2.5.0' 'exa-i3'
    Inst-Runtime
    Check 'runtime step: renamed in the 2.5 root, one restart, the limit lifted' "yes|$NEW|2|lifted|running" ("{0}|{1}|{2}|{3}|{4}" -f (YN (Test-Path $NEW)), $script:mf['runtime.deployment_dir'], @((Calls 'stop|start') -split "`n" | Where-Object { $_ }).Count, $script:mf['runtime.session_limit'], (State 'exa-i3'))
    Inst-Runtime
    Check '...run again: nothing' '' (Calls 'stop|start')
    # A no holds back the runtime step's rename, and its limit after it.
    Reset-Home
    Seed $i3 'exa-nr' 8563 'running'
    Kit030 $i3 '2.5.0' 'exa-nr'
    $env:EXAKIT_CONFIRM_RUNTIME_UPDATE = '0'
    Inst-Runtime
    Remove-Item Env:EXAKIT_CONFIRM_RUNTIME_UPDATE
    Check 'runtime step with a no: not stopped, not renamed, the limit as it was' '|yes|yes|running' "$(Calls 'stop|start')|$(YN (Test-Path $i3))|$(YN ((Conf $i3) -match 'maxConnectionsLicenseLimit'))|$(State 'exa-nr')"
    # The limit's file is never changed under a database that holds its port and
    # does not answer yet ("conflict", every Windows boot, WP2-09).
    Reset-Home
    Seed $NEW 'exa-cf' 8563 'running'
    Kit030 $NEW '2.5.0' 'exa-cf'
    $env:EXAKIT_CONFIRM_RUNTIME_UPDATE = '0'
    $script:calls.Clear(); $script:said.Clear(); Fresh
    & { function Get-PersonalStatus { return 'conflict' }; $null = Remove-PersonalSessionLimit }
    Remove-Item Env:EXAKIT_CONFIRM_RUNTIME_UPDATE
    Check 'the limit, a database in conflict, a no: held back, its file as it was' 'yes|' "$(YN ((Conf $NEW) -match 'maxConnectionsLicenseLimit'))|$(Calls 'stop|start')"
    $script:calls.Clear(); Fresh
    # Until it is stopped.
    & { function Get-PersonalStatus { if (Calls 'stop') { return 'running' }; return 'conflict' }; $null = Remove-PersonalSessionLimit }
    Check '...without it: stopped before its file is changed' "no|2.5.0 stop --deployment-dir $NEW" "$(YN ((Conf $NEW) -match 'maxConnectionsLicenseLimit'))|$(Calls 'stop')"
    # Owner user, through the installer.
    Reset-Home
    Seed $DEF 'exa-i4' 8563 'running'
    User030 $DEF $THEIRS '2.4.0'
    Inst-Launcher
    Check 'owner user: their launcher as it was, the database renamed, still theirs' "$($script:sha24)|yes|user|running" ("{0}|{1}|{2}|{3}" -f (Sha $THEIRS), (YN (Test-Path $NEW)), $script:mf['runtime.ownership'], (State 'exa-i4'))
    Check '...and the kit records its own 2.5 in its folder (owner kit)' "kit|$(Get-PersonalSeparateBinPath)|$($script:pin25)" ("{0}|{1}|{2}" -f $script:mf['components.personal.ownership'], $script:mf['components.personal.ownership_path'], (Sha (Get-PersonalSeparateBinPath)))
    # Q15, the installer run again: the same update.
    Reset-Home
    Seed $DEF 'exa-q15i' 8563 'running'
    Kit030Theirs $DEF $THEIRS '2.4.0'
    Inst-Launcher
    Check 'Q15, the installer run again: their launcher as it was, renamed, still the kit''s, running' "$($script:sha24)|yes|kit|running" ("{0}|{1}|{2}|{3}" -f (Sha $THEIRS), (YN (Test-Path $NEW)), $script:mf['runtime.ownership'], (State 'exa-q15i'))
    Reset-Home
    Seed $DEF 'exa-i5' 8563 'running'
    User030 $DEF $THEIRS '2.4.0'
    $i5Sha = Sha $THEIRS
    $env:EXAKIT_CORE_RERUN = '1'
    Inst-Launcher
    Remove-Item Env:EXAKIT_CORE_RERUN
    Check 'an installer exakit update started: the update decided it, nothing here' "$i5Sha|yes" "$(Sha $THEIRS)|$(YN (Test-Path $DEF))"

    Write-Host "the MCP sidecar a 0.3.0 kit set up is recorded as the kit's, so an uninstall removes it:"
    # 0.3.0 kept no record of the folder it wrote its sidecar in
    # (components.mcp_server.sidecar_dir): on a database of the user's, the
    # uninstall could not prove the sidecar was the kit's, kept it, and it
    # went on answering on 127.0.0.1:4896. The update records it, only on
    # proof: the kit's MCP server on record as that sidecar, and the sidecar
    # connecting as the kit's read-only login on the kit's port.
    foreach ($fn in ([Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'setup/lib/mcp.ps1'), [ref]$null, [ref]$null)).FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and @('Test-McpSidecarIsKits', 'Remove-McpSidecar', 'Get-McpSidecarPort') -contains $n.Name }, $true)) {
        Invoke-Expression $fn.Extent.Text
    }
    $script:McpSidecarName = 'mcp'
    $script:McpSidecarPort = 4896
    $script:McpReadonlyUser = 'mcp_readonly'
    # Write-Sidecars <dir> <login> <port> [-FromSecret]: sidecars.yaml as the
    # kit's editor saves it (PyYAML, block style), the password a literal
    # value. -FromSecret: EXA_USER taken from the deployment's secret, as the
    # launcher's own MCP server signs in.
    function Write-Sidecars([string]$Dir, [string]$Login, [int]$Port, [switch]$FromSecret) {
        $user = @('      - name: EXA_USER', "        value: $Login")
        if ($FromSecret) { $user = @('      - name: EXA_USER', '        valueFrom:', '          secretKeyRef:', '            name: exasol-database', '            key: username') }
        $yaml = @('version: 1', 'sidecars:', '  mcp:', '    enabled: true', '    container:',
            '      image: docker.io/exasol/mcp-server:2.4.0', '      env:',
            '      - name: EXASOL_DB_HOST', '        valueFrom:', '          secretKeyRef:', '            name: exasol-database', '            key: host') + $user + @(
            '      - name: EXA_PASSWORD', '        value: not-a-real-password-4711',
            '      ports:', '      - name: mcp', '        containerPort: 4896', "        hostPort: $Port", '        hostIP: 127.0.0.1',
            '    endpoints:', '    - port: mcp', '      scheme: http', '      path: /mcp')
        [IO.File]::WriteAllText((Join-Path $Dir 'sidecars.yaml'), (($yaml -join "`n") + "`n"))
    }
    # Mcp030: what a 0.3.0 kit recorded about the MCP server it set up beside
    # the database (no sidecar_dir).
    function Mcp030 {
        Set-ExakitManifestValue 'components.mcp_server.backend' 'sidecar'
        Set-ExakitManifestValue 'components.mcp_server.version' '2.4.0'
        Set-ExakitManifestValue 'components.mcp_server.port' '4896'
        Set-ExakitManifestValue 'components.mcp_server.connection.user' 'mcp_readonly'
        Set-ExakitComponentOwnership 'mcp' 'kit'
    }
    function Removal { $script:said.Clear(); Fresh; Remove-McpSidecar -DryRun; return (YN ((Said).Contains("will remove: the MCP server the kit set up beside your database (sidecar 'mcp')"))) }
    Reset-Home
    Seed $DEF 'exa-mcp' 8563 'running'
    User030 $DEF $THEIRS '2.4.0'
    Mcp030
    Write-Sidecars $DEF 'mcp_readonly' 4896
    Fresh
    Check 'before: a 0.3.0 kit''s sidecar on a database of the user''s is not provably the kit''s' 'False|no' "$(Test-McpSidecarIsKits)|$(Removal)"
    Upd
    Check 'the update of their database: done' 'personal|updated' (Row)
    Check '...the sidecar recorded as the kit''s, in the renamed folder' "$NEW|yes" "$($script:mf['components.mcp_server.sidecar_dir'])|$(YN (Test-Path (Join-Path $NEW 'sidecars.yaml')))"
    Fresh
    Check '...so it is the kit''s to refresh and to remove' 'True|yes' "$(Test-McpSidecarIsKits)|$(Removal)"
    Hasnt '...and nothing said or logged holds the password' 'not-a-real-password-4711' (Said)
    # A sidecar of that name the user set up: never claimed.
    Reset-Home
    Seed $DEF 'exa-mcp2' 8563 'running'
    User030 $DEF $THEIRS '2.4.0'
    Mcp030
    Write-Sidecars $DEF 'sys' 4896
    Upd
    Check 'a sidecar that connects as another login: not recorded, not removed' "personal|updated||False|no" "$(Row)|$($script:mf['components.mcp_server.sidecar_dir'])|$(Fresh; Test-McpSidecarIsKits)|$(Removal)"
    Reset-Home
    Seed $DEF 'exa-mcp3' 8563 'running'
    User030 $DEF $THEIRS '2.4.0'
    Mcp030
    Write-Sidecars $DEF 'mcp_readonly' 4900
    Upd
    Check 'the kit''s login on another port: not recorded' '' ("" + $script:mf['components.mcp_server.sidecar_dir'])
    Reset-Home
    Seed $DEF 'exa-mcp4' 8563 'running'
    User030 $DEF $THEIRS '2.4.0'
    Write-Sidecars $DEF 'mcp_readonly' 4896
    Upd
    Check 'no MCP server of the kit''s on record: not recorded' '' ("" + $script:mf['components.mcp_server.sidecar_dir'])
    Reset-Home
    Seed $DEF 'exa-mcp7' 8563 'running'
    User030 $DEF $THEIRS '2.4.0'
    Mcp030
    Write-Sidecars $DEF 'mcp_readonly' 4896 -FromSecret
    Upd
    Check 'EXA_USER taken from the deployment''s secret (the launcher''s own MCP server): not recorded' '' ("" + $script:mf['components.mcp_server.sidecar_dir'])
    Reset-Home
    Seed $DEF 'exa-mcp8' 8563 'running'
    User030 $DEF $THEIRS '2.4.0'
    Mcp030
    Remove-ExakitManifestValue 'components.mcp_server.port'
    Write-Sidecars $DEF 'mcp_readonly' 4896
    Upd
    Check 'no port of the kit''s on record: not recorded' '' ("" + $script:mf['components.mcp_server.sidecar_dir'])
    # The kit's own database: nothing to record, its sidecar is the kit's anyway.
    Reset-Home
    Seed $DEF 'exa-mcp5' 8563 'running'
    Kit030 $DEF '2.4.0'
    Mcp030
    Write-Sidecars $DEF 'mcp_readonly' 4896
    Upd
    Check 'the kit''s own database: no record needed, the sidecar is the kit''s' "personal|updated||True" "$(Row)|$($script:mf['components.mcp_server.sidecar_dir'])|$(Fresh; Test-McpSidecarIsKits)"
    # A database of the user's run by the kit's own launcher (Update-Personal).
    Reset-Home
    Seed $DEF 'exa-mcp9' 8563 'running'
    Kit030 $DEF '2.4.0'
    Set-ExakitComponentOwnership 'database' 'user' $DEF
    Mcp030
    Write-Sidecars $DEF 'mcp_readonly' 4896
    Upd
    Check 'their database, the kit''s own launcher: updated, the sidecar recorded' "personal|updated|$NEW|True" "$(Row)|$($script:mf['components.mcp_server.sidecar_dir'])|$(Fresh; Test-McpSidecarIsKits)"
    # The installer's one question, kit_database_missing: the 0.3.0 kit's own
    # `default` that their 2.5 moved, picked and renamed: recorded there too.
    Reset-Home
    $moved = Join-Path $NEWROOT 'default'
    Seed $moved 'exa-mcp10' 8563
    Copy-Item -LiteralPath (Join-Path $work 'exasol-2.5.0') -Destination $script:PersonalBinPath -Force
    Mcp030
    Write-Sidecars $moved 'mcp_readonly' 4896
    $script:said.Clear(); Fresh
    $renamed = Rename-PersonalUserDatabase -Pick ([pscustomobject]@{ Name = 'default'; Path = $moved; Status = 'stopped'; State = 'stopped' })
    Check 'the one question, their pick of the moved default: renamed, the user''s, the sidecar recorded' "True|user|$NEW" "$renamed|$($script:mf['runtime.ownership'])|$($script:mf['components.mcp_server.sidecar_dir'])"
    # With a launcher at 2.5.0 already (the rename alone): recorded too.
    Reset-Home
    $mcp25 = Join-Path $NEWROOT 'default'
    Seed $mcp25 'exa-mcp6' 8563 'running'
    User030 $mcp25 $THEIRS '2.5.0'
    Set-ExakitManifestValue 'runtime.deployment_id' 'exa-mcp6'
    Mcp030
    Write-Sidecars $mcp25 'mcp_readonly' 4896
    Upd
    Check 'their 2.5.0, the rename alone: recorded in the renamed folder' "yes|$NEW" "$(YN (Test-Path $NEW))|$($script:mf['components.mcp_server.sidecar_dir'])"

    Write-Host "a 0.3.0 kit whose database a hand-installed 2.5 moved: Step 1 gets the kit's own launcher 2.5, and the one question lists that database:"
    # The 0.3.0 kit's own `default`, moved into the 2.5 root by the user's own
    # 2.5 (0.3.0 kept no id), the kit's own launcher still 2.4.0: the kit's
    # database is missing. Its 2.4.0 has no deployments list, so the one
    # question never saw that `default`. Step 1 now replaces the kit's
    # launcher like a first install (nothing stopped or started), and the list
    # the old launcher could not give is asked again. Twin of the H1 and M1
    # checks in personal-named-deploy.sh.
    function Deny-ExakitInput([string]$Message) { throw "DENIED: $Message" }
    function Test-PersonalPromptable { return $false }
    $movedDef = Join-Path $NEWROOT 'default'
    function Set-H1Machine {
        Reset-Home
        Seed $movedDef 'exa-moved' 8563
        Kit030 $DEF '2.4.0'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $THEIRS) | Out-Null
        Copy-Item -LiteralPath (Join-Path $work 'exasol-2.5.0') -Destination $THEIRS -Force
        $script:userLauncher = $THEIRS
        Fresh
    }
    Set-H1Machine
    Check 'the 0.3.0 layout: the kit''s own database missing, the moved default found' "kit_database_missing|$DEF|$movedDef" (Get-ExakitPersonalDbState)
    Check '...the kit''s 2.4.0 could not list it' 'True|False' "$($script:PersonalLauncherAsked)|$($script:PersonalLauncherListed)"
    Inst-Launcher
    Check 'Step 1: the kit''s own launcher replaced like a first install' "|$($script:pin25)|kit" ("{0}|{1}|{2}" -f $script:instThrew, (Sha $script:PersonalBinPath), $script:mf['components.personal.ownership'])
    Check '...nothing stopped or started, nothing renamed' '|yes|stopped' "$(Calls 'stop|start')|$(YN (Test-Path $movedDef))|$(State 'exa-moved')"
    Has '...said as a replace' 'Replacing the kit''s launcher at' (Said)
    Check '...and the list the old launcher could not give is asked again (M1)' 'False' "$($script:PersonalLauncherAsked)"
    Check '...the new launcher lists it' $movedDef ((@(Get-PersonalLauncherDeployments) | ForEach-Object { $_.Path }) -join ',')
    $script:said.Clear()
    $env:EXAKIT_REUSE_DB = 'default'
    $h1 = "" + (Select-PersonalDatabase)
    Remove-Item Env:EXAKIT_REUSE_DB
    Check 'EXAKIT_REUSE_DB=default: renamed, the user''s, its data kept' "renamed|user|exa-moved|tables of exa-moved" ("{0}|{1}|{2}|{3}" -f $h1, $script:mf['runtime.ownership'], $script:mf['runtime.deployment_id'], [IO.File]::ReadAllText([IO.Path]::Combine($NEW, 'local', 'runtime', 'exa', 'data.bin')))
    Has '...line 1 of the one question' 'INFO Exasol Personal 2.5 is on this computer, with 1 database of yours.' (Said)
    Has '...and line 3' "OK Your database 'default' is now 'starter-kit-local'. The kit uses it and never deletes it." (Said)
    Check '...nothing is missing any more' '' (Get-ExakitPersonalDbState)
    Set-H1Machine
    Inst-Launcher
    $script:said.Clear()
    $h1 = "" + (Select-PersonalDatabase)
    Check 'no terminal and no answer: a new database (D1), their default untouched' "new|yes|no" ("{0}|{1}|{2}" -f $h1, (YN (Test-Path $movedDef)), (YN (Test-Path $NEW)))
    $script:userLauncher = ''

    Write-Host "the one question's rename of a database their 2.5 kept in its older root: its limit is lifted where it goes:"
    # Running when their 2.5 came, so it stayed in the older root. The rename's
    # limit edit is followed by its id when the launcher's `version`, asked
    # for the lift, moves the renamed folder. PowerShell already did this
    # (Remove-PersonalSessionLimit reads exasol.conf again after `version`):
    # the bash twin's L1 fix, checked here.
    Reset-Home
    $devOld = Join-Path $OLDROOT 'dev'
    Seed $devOld 'exa-dev2' 8570 'running'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $THEIRS) | Out-Null
    Copy-Item -LiteralPath (Join-Path $work 'exasol-2.5.0') -Destination $THEIRS -Force
    $script:userLauncher = $THEIRS
    Fresh
    $script:said.Clear()
    $l1 = Rename-PersonalUserDatabase -Pick ([pscustomobject]@{ Name = 'dev'; Path = $devOld; Status = 'database_ready'; State = 'running' })
    Check 'renamed in the older root, moved by their 2.5 after it, the record following' "True|no|yes|$NEW|user" ("{0}|{1}|{2}|{3}|{4}" -f $l1, (YN (Test-Path $OLD)), (YN (Test-Path $NEW)), $script:mf['runtime.deployment_dir'], $script:mf['runtime.ownership'])
    Check '...its 20-session limit lifted where it is now' 'no|yes|lifted' "$(YN ((Conf $NEW) -match 'maxConnectionsLicenseLimit'))|$(YN (Test-Path ((Join-Path $NEW $CONF_REL) + '.before-session-limit')))|$($script:mf['runtime.session_limit'])"
    Check '...stopped by its old folder, no launcher command between the stop and the rename' "2.5.0 stop --deployment-dir $devOld" (Calls 'stop|start')
    Check '...lifted with nothing said, as the sh twin lifts it there' '' (@($script:said | Where-Object { "$_" -match '20-session limit' }) -join '|')
    # The file cannot be changed: one line, the sh twin's, and no remedy line.
    Reset-Home
    Seed $devOld 'exa-dev3' 8571
    [IO.File]::SetAttributes((Join-Path $devOld $CONF_REL), [IO.FileAttributes]::ReadOnly)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $THEIRS) | Out-Null
    Copy-Item -LiteralPath (Join-Path $work 'exasol-2.5.0') -Destination $THEIRS -Force
    $script:userLauncher = $THEIRS
    Fresh
    $script:said.Clear()
    $l1 = Rename-PersonalUserDatabase -Pick ([pscustomobject]@{ Name = 'dev'; Path = $devOld; Status = 'stopped'; State = 'stopped' })
    Check 'its limit cannot be removed: still renamed, the limit kept' 'True|yes|' ("{0}|{1}|{2}" -f $l1, (YN ((Conf $NEW) -match 'maxConnectionsLicenseLimit')), $script:mf['runtime.session_limit'])
    Check '...said in one line, as the sh twin says it' 'WARN The 20-session limit of this database was not removed. Its file is as it was.' (@($script:said | Where-Object { "$_" -match '20-session limit|remove the limit' }) -join '|')
    foreach ($f in @(Get-ChildItem -LiteralPath $NEWROOT -Recurse -Force -File -ErrorAction SilentlyContinue)) { try { if ($f.IsReadOnly) { $f.IsReadOnly = $false } } catch { } }
    $script:userLauncher = ''

    Write-Host "#41: a launcher of the user's is the same file after everything the kit does:"
    # Their launcher (2.4, 2.5 or 2.6) at .local\bin or elsewhere, on PATH or
    # not, under each 0.3.0 kit: on its own launcher (theirs beside it), on a
    # database of theirs, and Q15. The real resolver finds it. After an update
    # that goes through, one put back (a launcher that does not run, a swap
    # that cannot happen) and the installer run again, its bytes are the same.
    & {
        $realCli = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'setup/lib/runtime-personal.ps1'), [ref]$null, [ref]$null).Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-PersonalCli' }, $true).Extent.Text
        Invoke-Expression $realCli
        $script:pathLauncher = ''
        function Get-Command {
            if ("$($args[0])" -eq 'exasol') { if ($script:pathLauncher) { return [pscustomobject]@{ Source = $script:pathLauncher } }; return $null }
            Microsoft.PowerShell.Core\Get-Command @args
        }
        [IO.File]::WriteAllText((Join-Path $work 'exasol-2.6.0'), '2.6.0')
        $atBin = Join-Path $script:BinDir 'exasol.exe'
        $changed = @(); $ran = 0; $notUpdated = @()
        foreach ($kind in @('kit', 'user', 'q15')) {
            foreach ($place in @('bin', 'elsewhere')) {
                if ($kind -eq 'kit' -and $place -eq 'bin') { continue }   # the kit's own 0.3.0 launcher is there
                foreach ($onPath in @($true, $false)) {
                    foreach ($ver in @('2.4.0', '2.5.0', '2.6.0')) {
                        foreach ($act in @('update', 'broken', 'noswap', 'installer')) {
                            Reset-Home
                            $script:PersonalReceiptLauncher = ''
                            $their = $atBin; if ($place -eq 'elsewhere') { $their = $THEIRS }
                            $script:pathLauncher = ''; if ($onPath) { $script:pathLauncher = $their }
                            Seed $DEF 'exa-41' 8563 'running'
                            switch ($kind) {
                                'user' { User030 $DEF $their $ver }
                                'q15' { Kit030Theirs $DEF $their $ver }
                                default {
                                    Kit030 $DEF '2.4.0'
                                    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $their) | Out-Null
                                    Copy-Item -LiteralPath (Join-Path $work "exasol-$ver") -Destination $their -Force
                                }
                            }
                            $sha = Sha $their
                            $name = "$kind $place path=$onPath $ver $act"
                            switch ($act) {
                                'update' { Upd }
                                'broken' { $script:download = Join-Path $work 'exasol-2.5.0-broken'; $script:pin = Sha $script:download; Upd }
                                'noswap' { & { function Move-Item { throw 'Access to the path is denied.' }; Upd } }
                                'installer' { Inst-Launcher }
                            }
                            $ran++
                            if ((Sha $their) -ne $sha) { $changed += $name }
                            if ($act -eq 'update' -and ($kind -eq 'kit' -or $ver -eq '2.4.0') -and
                                -not ((Test-Path $NEW) -and (Sha (Get-PersonalSeparateBinPath)) -eq $script:pin25 -and (State 'exa-41') -eq 'running')) { $notUpdated += $name }
                        }
                    }
                }
            }
        }
        Check "$ran runs: no launcher of the user's changed, moved or gone" '' ($changed -join '; ')
        Check '...and each update that was due went through: renamed, the kit''s own 2.5.0 in its folder, running' '' ($notUpdated -join '; ')
    }
    Reset-Home

    Write-Host "what the update says is full sentences, never with a semicolon:"
    $src = [IO.File]::ReadAllText((Join-Path $repo 'setup/lib/runtime-personal.ps1'))
    $start = $src.IndexOf('# --- the update from a 0.3.0 kit')
    $end = $src.IndexOf("`nfunction Update-Personal {")
    $block = ''
    if ($start -ge 0 -and $end -gt $start) { $block = $src.Substring($start, $end - $start) }
    $lines = @(($block -split "`n") | Where-Object { $_ -match '(Warn2|Info|Ok) "' })
    Check 'the update''s lines are there' 'yes' (YN ($lines.Count -gt 10))
    Check '...none with a semicolon' '' (@($lines | Where-Object { $_.Contains(';') }) -join ' | ')
} finally {
    foreach ($name in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnv[$name]) }
    foreach ($f in @(Get-ChildItem -LiteralPath $work -Recurse -Force -File -ErrorAction SilentlyContinue)) {
        try { if ($f.IsReadOnly) { $f.IsReadOnly = $false } } catch { }
    }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "personal-update-rename-ps.ps1: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
