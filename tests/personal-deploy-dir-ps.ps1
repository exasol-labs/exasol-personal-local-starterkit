#!/usr/bin/env pwsh
# personal-deploy-dir-ps.ps1 - the Windows twin of personal-deploy-dir.sh: the
# kit finds its Exasol Personal deployment, starter-kit-local, the way launcher
# 2.5.0 does (%LOCALAPPDATA%\exasol\launcher first, %USERPROFILE%\.exasol\personal
# second), never a deployment of the user's because it is listed first, and
# its record follows the folder when the launcher moves it, whatever the
# recorded folder's name (a 0.3.0 kit's `default`) - only when that folder's
# deployment id is the one the kit recorded: the user's own deployment at the
# new default (another id, or none recorded) is never claimed, and uninstall
# --dry-run lists no removal of it.
# Function definitions only, against a sandboxed profile, an in-memory
# manifest and a stubbed launcher probe: no real launcher, database or kit
# home is touched. PowerShell 5.1 compatible.
#
#   pwsh -NoProfile -File tests/personal-deploy-dir-ps.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([IO.Path]::GetTempPath()) ('exakit-pdd-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$expected>, got <$actual>" }
}

$savedEnv = @{}
foreach ($name in @('USERPROFILE', 'LOCALAPPDATA', 'EXAKIT_PERSONAL_DEPLOY_DIR')) { $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name) }
$env:USERPROFILE = Join-Path $work 'profile'
$env:LOCALAPPDATA = Join-Path $work 'profile\AppData\Local'
Remove-Item Env:EXAKIT_PERSONAL_DEPLOY_DIR -ErrorAction SilentlyContinue

try {
    # Definitions only: nothing initializes against the real profile.
    foreach ($file in @('setup/lib/exakit-common.ps1', 'setup/lib/runtime-personal.ps1', 'setup/lib/mcp.ps1')) {
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $file), [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count) { throw "$file parse errors: $parseErrors" }
        foreach ($fn in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Extent.Text -match '^\s*(function|filter)\s' }, $true)) {
            Invoke-Expression $fn.Extent.Text
        }
    }
    $script:manifest = @{}
    function Get-ExakitManifestValue([string]$Path) { return $script:manifest[$Path] }
    function Set-ExakitManifestValue([string]$Path, $Value) { $script:manifest[$Path] = $Value }
    function Remove-ExakitManifestValue([string]$Path) { $script:manifest.Remove($Path) }
    function Info($m) {}; function Ok($m) {}; function Warn2($m) {}
    # The launcher's `info` answers when a deployment is in either folder.
    function Get-PersonalCli { return 'exasol-stub' }
    # `deployments list --json` answers $script:stubList (as launcher 2.5.0
    # and later do) when it is set, and nothing (a 2.4.x launcher) when not.
    $script:stubList = $null
    $script:stubListCalls = 0
    function Invoke-ExakitBounded { param($FilePath, $Arguments, $TimeoutSeconds)
        if ($Arguments[0] -eq 'deployments') { $script:stubListCalls++; return $script:stubList }
        $at = [array]::IndexOf([string[]]$Arguments, '--deployment-dir')
        if ($Arguments[0] -eq 'info' -and $at -ge 0) { if (Test-Path -LiteralPath $Arguments[$at + 1]) { return 'info' }; return $null }
        $r = Resolve-PersonalDeployDir
        if ($Arguments[0] -eq 'info' -and ((Test-Path -LiteralPath $r.New) -or (Test-Path -LiteralPath $r.Legacy))) { return 'info' }
        return $null
    }

    # The kit's own database, starter-kit-local, in each of the launcher's
    # roots; and `default` there: a 0.3.0 kit's own, or the user's.
    $NEW = Join-Path $env:LOCALAPPDATA 'exasol\launcher\deployments\starter-kit-local'
    $OLD = Join-Path $env:USERPROFILE '.exasol\personal\deployments\starter-kit-local'
    $NEW_DEF = Join-Path $env:LOCALAPPDATA 'exasol\launcher\deployments\default'
    $OLD_DEF = Join-Path $env:USERPROFILE '.exasol\personal\deployments\default'
    $script:PersonalPort = 8563
    function Reset-Home {
        foreach ($p in @((Join-Path $env:USERPROFILE '.exasol'), (Join-Path $env:LOCALAPPDATA 'exasol'), (Join-Path $env:LOCALAPPDATA '.exasol'))) {
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
        }
        $script:manifest = @{}
        $script:PersonalDeployDir = (Resolve-PersonalDeployDir).Dir
        $script:PersonalDeployFollowed = ''
        $script:PersonalDeployIdSeen = $false
        # The next refresh is a new process's first: it reads the record anew.
        $script:PersonalLauncherDecided = $false
        $script:PersonalDeployRec = ''
    }
    function Seed([string]$Dir, [int]$Port) {
        New-Item -ItemType Directory -Force -Path (Join-Path $Dir 'local\runtime\exa\certificates') | Out-Null
        Set-Content -LiteralPath (Join-Path $Dir 'deployment.json') -Value ('{"deploymentId": "exa-' + $Port + '", "connection": {"host": "127.0.0.1", "dbPort": ' + $Port + ', "username": "sys"}}')
        Set-Content -LiteralPath (Join-Path $Dir '.exasolLauncher.version') -Value '2.4.0'
        Set-Content -LiteralPath (Join-Path $Dir 'local\runtime\exa\certificates\fullchain.pem') -Value @('-----BEGIN CERTIFICATE-----', 'AAEC', '-----END CERTIFICATE-----')
    }
    # Record-NoId: what a 0.3.0 install wrote. Record: 0.3.1, the id as well.
    function Record-NoId([string]$Dir) {
        Set-ExakitManifestValue 'runtime.type' 'personal'
        Set-ExakitManifestValue 'runtime.deployment_dir' $Dir
        Set-ExakitManifestValue 'runtime.ownership' 'kit'
        Set-ExakitManifestValue 'runtime.ownership_path' $Dir
    }
    function Record([string]$Dir) {
        Record-NoId $Dir
        Set-ExakitManifestValue 'runtime.deployment_id' (Get-PersonalDeploymentId -Dir $Dir)
    }
    # Invoke-Kit: setup/exakit.ps1 as a user runs it, on a manifest file made
    # from the in-memory one, in the sandboxed profile. No launcher on PATH.
    $kitHome = Join-Path $work 'kit'
    $script:BinDir = Join-Path $work 'bin'
    $script:PersonalBinPath = Join-Path $script:BinDir 'exasol.exe'
    $hostExe = (Get-Process -Id $PID).Path
    function Invoke-Kit([string[]]$CliArgs) {
        New-Item -ItemType Directory -Force -Path $kitHome | Out-Null
        $doc = @{}
        foreach ($k in $script:manifest.Keys) {
            $parts = $k -split '\.'
            $node = $doc
            for ($i = 0; $i -lt $parts.Count - 1; $i++) {
                if (-not $node.ContainsKey($parts[$i])) { $node[$parts[$i]] = @{} }
                $node = $node[$parts[$i]]
            }
            $node[$parts[-1]] = $script:manifest[$k]
        }
        $doc['kit_level'] = 1; $doc['steps_completed'] = @()
        [IO.File]::WriteAllText((Join-Path $kitHome 'manifest.json'), ($doc | ConvertTo-Json -Depth 8))
        $prev = @($env:EXAKIT_HOME, $env:EXAKIT_BIN_DIR)
        $env:EXAKIT_HOME = $kitHome; $env:EXAKIT_BIN_DIR = (Join-Path $work 'bin')
        try { return ((& $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'setup/exakit.ps1') @CliArgs 2>&1 6>&1) | Out-String) }
        finally { $env:EXAKIT_HOME = $prev[0]; $env:EXAKIT_BIN_DIR = $prev[1] }
    }
    function Has($label, $needle, $haystack) {
        if ("$haystack".Contains($needle)) { $script:PASS++; Write-Host "  ok   $label" }
        else { $script:FAIL++; Write-Host "  FAIL $($label): <$needle> not in <$haystack>" }
    }
    function Hasnt($label, $needle, $haystack) {
        if (-not "$haystack".Contains($needle)) { $script:PASS++; Write-Host "  ok   $label" }
        else { $script:FAIL++; Write-Host "  FAIL $($label): <$needle> in <$haystack>" }
    }
    function Get-PruneList { return ((@(Get-PersonalPrunableStateDirs) | ForEach-Object { $_ }) -join ' ') }

    Write-Host 'the resolver itself:'
    Reset-Home
    Check 'fresh: nothing on disk is the 2.5.0 folder' $NEW (Resolve-PersonalDeployDir).Dir
    New-Item -ItemType Directory -Force -Path $OLD | Out-Null
    Check 'legacy: only the old folder is the old folder' $OLD (Resolve-PersonalDeployDir).Dir
    New-Item -ItemType Directory -Force -Path $NEW | Out-Null
    Check 'both: the new folder wins' $NEW (Resolve-PersonalDeployDir -Path $OLD).Dir
    Check 'both: a recorded old folder still on disk stays itself' $OLD (Resolve-PersonalDeployDir -Path $OLD -Recorded).Dir
    Remove-Item -LiteralPath $OLD -Recurse -Force
    Set-Content -LiteralPath (Join-Path $NEW 'deployment.json') -Value '{"deploymentId": "exa-kit"}'
    Check 'moved: a recorded old folder that is gone is the new one, with the kit''s id' $NEW (Resolve-PersonalDeployDir -Path $OLD -Recorded -DeploymentId 'exa-kit').Dir
    Check 'guard: not with another id there' $OLD (Resolve-PersonalDeployDir -Path $OLD -Recorded -DeploymentId 'exa-other').Dir
    Check 'guard: not with no id recorded' $OLD (Resolve-PersonalDeployDir -Path $OLD -Recorded).Dir
    Set-ExakitManifestValue 'runtime.deployment_id' 'exa-kit'
    Check 'guard: the recorded id is read from the manifest' $NEW (Resolve-PersonalDeployDir -Path $OLD -Recorded).Dir
    Remove-Item -LiteralPath (Join-Path $NEW 'deployment.json')
    Check 'guard: not when the folder names no id' $OLD (Resolve-PersonalDeployDir -Path $OLD -Recorded).Dir
    $script:manifest = @{}
    $mine = Join-Path $work 'mine'
    Check 'custom: a folder the user chose is itself' $mine (Resolve-PersonalDeployDir -Path $mine).Dir
    Remove-Item -LiteralPath $NEW -Recurse -Force
    Check 'gone: a default that was removed keeps naming its folder' $OLD (Resolve-PersonalDeployDir -Path $OLD).Dir
    $savedLocal = $env:LOCALAPPDATA; Remove-Item Env:LOCALAPPDATA
    Check 'no LOCALAPPDATA: only the old folder is known' $OLD (Resolve-PersonalDeployDir).Dir
    $env:LOCALAPPDATA = $savedLocal

    Write-Host 'the kit''s own by its name, never the first deployment listed:'
    # Row: a deployment as Get-PersonalLauncherDeployments keeps it.
    function Row([string]$Name, [string]$Path, [string]$Status) { return [pscustomobject]@{ Path = $Path; Status = $Status; Name = $Name; Infrastructure = 'local' } }
    function Set-Listed { param([object[]]$Rows) $script:PersonalLauncherListed = $true; $script:PersonalLauncherDeployments = @($Rows) }
    function Clear-Listed { $script:PersonalLauncherListed = $false; $script:PersonalLauncherDeployments = @() }
    Reset-Home
    Clear-Listed
    Check 'the names: starter-kit-local in each root' "$NEW|$OLD|starter-kit-local" ("{0}|{1}|{2}" -f (Resolve-PersonalDeployDir).New, (Resolve-PersonalDeployDir).Legacy, (Resolve-PersonalDeployDir).Name)
    Check '...and the roots themselves' ("{0}|{1}" -f (Split-Path -Parent $NEW), (Split-Path -Parent $OLD)) ("{0}|{1}" -f (Resolve-PersonalDeployDir).NewRoot, (Resolve-PersonalDeployDir).LegacyRoot)
    Seed $NEW_DEF 8601
    Check 'a user''s default and nothing named starter-kit-local: the kit''s folder is still starter-kit-local' $NEW (Resolve-PersonalDeployDir).Dir
    Set-Listed @((Row 'default' $NEW_DEF 'database_ready'))
    Check '...also when the launcher lists it' $NEW (Resolve-PersonalDeployDir).Dir
    Check '...with no status of the user''s' '' (Resolve-PersonalDeployDir).Status
    $mineDir = Join-Path (Split-Path -Parent $NEW) 'mine'
    Seed $mineDir 8602
    Set-Listed @((Row 'default' $NEW_DEF 'not_initialized'), (Row 'mine' $mineDir 'stopped'))
    Check 'a not_initialized default and a stopped one of the user''s: neither is the kit''s' $NEW (Resolve-PersonalDeployDir).Dir
    Seed $OLD 8603
    Check 'a starter-kit-local left in the older root: that one' $OLD (Resolve-PersonalDeployDir).Dir
    Seed $NEW 8604
    Set-Listed @((Row 'default' $NEW_DEF 'stopped'), (Row 'starter-kit-local' $NEW 'database_ready'))
    Check 'in both roots: the 2.5.0 one, with the launcher''s status' "$NEW|database_ready" ("{0}|{1}" -f (Resolve-PersonalDeployDir).Dir, (Resolve-PersonalDeployDir).Status)
    Check 'a folder the kit acts on keeps its name (a 0.3.0 default)' $NEW_DEF (Resolve-PersonalDeployDir -Path $NEW_DEF).Dir
    Reset-Home
    $SKL_ELSEWHERE = Join-Path $env:LOCALAPPDATA 'exasol\somewhere-new\deployments\starter-kit-local'
    $DEF_ELSEWHERE = Join-Path $env:LOCALAPPDATA 'exasol\somewhere-new\deployments\default'
    Seed $SKL_ELSEWHERE 8605; Seed $DEF_ELSEWHERE 8606
    Set-Listed @((Row 'default' $DEF_ELSEWHERE 'stopped'), (Row 'starter-kit-local' $SKL_ELSEWHERE 'stopped'))
    Check 'a launcher that keeps them somewhere new: the one it lists as starter-kit-local' $SKL_ELSEWHERE (Resolve-PersonalDeployDir).Dir
    Clear-Listed

    Write-Host 'a recorded folder that is gone is followed by its id, whatever its name:'
    Reset-Home
    Seed $NEW_DEF 8610
    Check 'a 0.3.0 default, moved to the 2.5.0 root' $NEW_DEF (Resolve-PersonalDeployDir -Path $OLD_DEF -Recorded -DeploymentId 'exa-8610').Dir
    Remove-Item -LiteralPath $NEW_DEF -Recurse -Force
    Seed $OLD 8610
    Check 'a 0.3.0 default, renamed to starter-kit-local in the older root' $OLD (Resolve-PersonalDeployDir -Path $OLD_DEF -Recorded -DeploymentId 'exa-8610').Dir
    Remove-Item -LiteralPath $OLD -Recurse -Force
    Seed $NEW 8610; Seed $NEW_DEF 8611
    Check '...then moved by 2.5.0, beside a default of the user''s' $NEW (Resolve-PersonalDeployDir -Path $OLD_DEF -Recorded -DeploymentId 'exa-8610').Dir
    Check '...never to another id' $OLD_DEF (Resolve-PersonalDeployDir -Path $OLD_DEF -Recorded -DeploymentId 'exa-other').Dir
    Check '...nor from a folder the user chose' (Join-Path $work 'chosen') (Resolve-PersonalDeployDir -Path (Join-Path $work 'chosen') -Recorded -DeploymentId 'exa-8610').Dir

    Write-Host 'fresh 2.5.0 layout:'
    Reset-Home
    Seed $NEW 8701; Record $NEW
    Update-PersonalDeployDir
    Check 'fresh: the deployment is found' $NEW $script:PersonalDeployDir
    Check 'fresh: its port' 8701 (Get-PersonalDbPort)
    Check 'fresh: it exists for the launcher' True (Test-PersonalDeploymentExists)
    Check 'fresh: the database is the kit''s' kit (Get-ExakitComponentOwnership 'database')
    Check 'fresh: uninstall prunes deployments, launcher, exasol' ((@((Split-Path -Parent $NEW), (Split-Path -Parent (Split-Path -Parent $NEW)), (Join-Path $env:LOCALAPPDATA 'exasol'))) -join ' ') (Get-PruneList)

    Write-Host 'old 2.4.0 layout:'
    Reset-Home
    Seed $OLD 8702; Record $OLD
    Update-PersonalDeployDir
    Check 'legacy: the deployment is found' $OLD $script:PersonalDeployDir
    Check 'legacy: its port' 8702 (Get-PersonalDbPort)
    Check 'legacy: the record is untouched' $OLD (Get-ExakitManifestValue 'runtime.deployment_dir')
    Check 'legacy: the database is the kit''s' kit (Get-ExakitComponentOwnership 'database')
    Check 'legacy: uninstall prunes deployments, personal, .exasol' ((@((Split-Path -Parent $OLD), (Split-Path -Parent (Split-Path -Parent $OLD)), (Join-Path $env:USERPROFILE '.exasol'))) -join ' ') (Get-PruneList)
    New-Item -ItemType Directory -Force -Path (Join-Path (Split-Path -Parent $NEW) 'theirs') | Out-Null
    Check 'legacy: a deployment in the 2.5.0 root is another deployment' (Join-Path (Split-Path -Parent $NEW) 'theirs') ((@(Get-PersonalOtherDeployments)) -join ' ')

    Write-Host 'migrated by the launcher after the install:'
    Reset-Home
    Seed $OLD 8703; Record $OLD
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $NEW) | Out-Null
    Move-Item -LiteralPath $OLD -Destination $NEW
    $script:PersonalDeployDir = $OLD; $script:PersonalDeployFollowed = ''
    Check 'moved: status reads the moved deployment''s port' 8703 (Get-PersonalDbPort)
    Check 'moved: the folder follows' $NEW $script:PersonalDeployDir
    Check 'moved: runtime.deployment_dir follows' $NEW (Get-ExakitManifestValue 'runtime.deployment_dir')
    Check 'moved: the ownership receipt follows' $NEW (Get-ExakitManifestValue 'runtime.ownership_path')
    Check 'moved: the receipt keeps its owner' kit (Get-ExakitManifestValue 'runtime.ownership')
    Check 'moved: the database is still the kit''s' kit (Get-ExakitComponentOwnership 'database')
    Check 'moved: it exists for the launcher (no second deploy)' True (Test-PersonalDeploymentExists)
    Check 'moved: the deployed version is read from it' '2.4.0' (Get-PersonalDeployedVersion)
    Check 'moved: the deployment id is read from it' 'exa-8703' (Get-PersonalDeploymentId)
    Check 'moved: nothing else is another deployment' '' ((@(Get-PersonalOtherDeployments)) -join ' ')
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $want = (($sha.ComputeHash([Convert]::FromBase64String('AAEC')) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
    Check 'moved: the TLS disk check reads the moved certificate' $want (Get-ExakitTlsDiskFingerprint)
    # The scheduler and the MCP server write sidecars.yaml there; the
    # virtual-schema engine is handed this folder.
    $vs = Get-Content -Raw -LiteralPath (Join-Path $repo 'setup/lib/virtual-schemas.ps1')
    Check 'moved: the virtual-schema engine gets the folder followed' True ($vs -match 'Resolve-PersonalDeployDir -Path \$value -Recorded')
    $mcp = Get-Content -Raw -LiteralPath (Join-Path $repo 'setup/lib/mcp.ps1')
    Check 'moved: the MCP sidecar definition refreshes the folder first' True ($mcp -match '(?s)function Write-McpSidecarDefinition.{0,200}Update-PersonalDeployDir')

    Write-Host 'a 0.3.0 kit''s default, moved or renamed: the record follows by its id, whatever the name:'
    Reset-Home
    Seed $OLD_DEF 8740; Record $OLD_DEF
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $NEW_DEF) | Out-Null
    Move-Item -LiteralPath $OLD_DEF -Destination $NEW_DEF
    Update-PersonalDeployDir
    Check '0.3.0 moved: the folder follows' $NEW_DEF $script:PersonalDeployDir
    Check '0.3.0 moved: runtime.deployment_dir follows' $NEW_DEF (Get-ExakitManifestValue 'runtime.deployment_dir')
    Check '0.3.0 moved: the ownership receipt follows' $NEW_DEF (Get-ExakitManifestValue 'runtime.ownership_path')
    Check '0.3.0 moved: its name is recorded' 'default' (Get-ExakitManifestValue 'runtime.deployment_name')
    Check '0.3.0 moved: still the kit''s' kit (Get-ExakitComponentOwnership 'database')
    Check '0.3.0 moved: nothing is said missing' '' (Get-ExakitPersonalKitMissing)
    Reset-Home
    Seed $OLD_DEF 8741; Record $OLD_DEF
    Set-ExakitManifestValue 'components.mcp_server.sidecar_dir' $OLD_DEF
    # Renamed to starter-kit-local in the older root (the update), then moved
    # by launcher 2.5.0 to its own root.
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $NEW) | Out-Null
    Move-Item -LiteralPath $OLD_DEF -Destination $NEW
    Update-PersonalDeployDir
    Check 'renamed and moved: the folder follows' $NEW $script:PersonalDeployDir
    Check '...runtime.deployment_dir follows' $NEW (Get-ExakitManifestValue 'runtime.deployment_dir')
    Check '...the ownership receipt follows' $NEW (Get-ExakitManifestValue 'runtime.ownership_path')
    Check '...the MCP sidecar''s folder follows' $NEW (Get-ExakitManifestValue 'components.mcp_server.sidecar_dir')
    Check '...its name is recorded' 'starter-kit-local' (Get-ExakitManifestValue 'runtime.deployment_name')
    Check '...the owner is kept' kit (Get-ExakitManifestValue 'runtime.ownership')
    Check '...its port' 8741 (Get-PersonalDbPort)

    Write-Host 'both folders on disk: the kit''s 0.3.0 database the launcher could not move, the user''s own 2.5 in the new one:'
    Reset-Home
    Seed $OLD_DEF 8704; Record $OLD_DEF
    Seed $NEW_DEF 8705
    Update-PersonalDeployDir
    Check 'both: the kit stays on its recorded folder' $OLD_DEF $script:PersonalDeployDir
    Check 'both: its port, never the user''s' 8704 (Get-PersonalDbPort)
    Check 'both: the record is not rewritten (not a move)' $OLD_DEF (Get-ExakitManifestValue 'runtime.deployment_dir')
    Check 'both: the kit''s own stays the kit''s' kit (Get-ExakitComponentOwnership 'database')
    Check 'both: every launcher call names the kit''s folder' "--deployment-dir $OLD_DEF" ((Get-PersonalDeployDirArgs) -join ' ')
    Check 'both: the user''s is another deployment' $NEW_DEF ((@(Get-PersonalOtherDeployments)) -join ' ')

    Write-Host 'the kit''s own moved deployment is followed, and only it:'
    Reset-Home
    Seed $OLD 8710; Record $OLD
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $NEW) | Out-Null
    Move-Item -LiteralPath $OLD -Destination $NEW
    Update-PersonalDeployDir
    Check 'same id: the record follows' $NEW (Get-ExakitManifestValue 'runtime.ownership_path')
    Check 'same id: the database is the kit''s' kit (Get-ExakitComponentOwnership 'database')
    Check 'same id: nothing is said missing' '' (Get-ExakitPersonalKitMissing)
    $t = Invoke-Kit @('uninstall', '--dry-run')
    Has 'same id: uninstall --dry-run lists the removal' 'deployment and ALL its data' $t

    Write-Host 'the user''s own deployment at the new default (another id) is not claimed:'
    Reset-Home
    Seed $OLD_DEF 8711; Record $OLD_DEF
    Remove-Item -LiteralPath (Join-Path $env:USERPROFILE '.exasol') -Recurse -Force
    Seed $NEW_DEF 8712
    Update-PersonalDeployDir
    Check 'another id: the launcher''s folder is the user''s' $NEW_DEF $script:PersonalDeployDir
    Check 'another id: runtime.deployment_dir is left as it is' $OLD_DEF (Get-ExakitManifestValue 'runtime.deployment_dir')
    Check 'another id: the receipt is left as it is' $OLD_DEF (Get-ExakitManifestValue 'runtime.ownership_path')
    Check 'another id: the recorded id is left as it is' 'exa-8711' (Get-ExakitManifestValue 'runtime.deployment_id')
    Check 'another id: the receipt is not followed' $OLD_DEF (Resolve-PersonalDeployDir -Path $OLD_DEF -Recorded).Dir
    Check 'another id: the database is the user''s' user (Get-ExakitComponentOwnership 'database')
    Check 'another id: the TLS disk check reads nothing of it' '' (Get-ExakitTlsDiskFingerprint)
    Check 'another id: the kit''s own is said missing, with both folders' "$OLD_DEF|$NEW_DEF" (Get-ExakitPersonalKitMissing)
    $t = Invoke-Kit @('uninstall', '--dry-run')
    Hasnt 'another id: uninstall --dry-run lists no deployment removal' 'deployment and ALL its data' $t
    Hasnt 'another id: ...nor the MCP server beside it' 'sidecar' $t
    Has 'another id: ...says the kit''s own was not found, and where' "The kit's own database was not found at $OLD_DEF." $t
    Has 'another id: ...and that the one found is left' "The Exasol Personal deployment at $NEW_DEF is not the kit's, so it is not removed." $t
    Check 'another id: the dry run touched nothing' True (Test-Path -LiteralPath (Join-Path $NEW_DEF 'deployment.json'))
    # A start or update records the runtime again: it must not take the user's
    # id (or folder) for the kit's, or the next uninstall would follow it.
    try { $null = Set-PersonalManifest 6>$null } catch { Write-Host "  (Set-PersonalManifest: $_ $($_.InvocationInfo.PositionMessage))" }
    Check 'another id: (the record ran)' 'exasol-stub' (Get-ExakitManifestValue 'runtime.launcher')
    Check 'another id: a later record keeps the kit''s id' 'exa-8711' (Get-ExakitManifestValue 'runtime.deployment_id')
    Check 'another id: ...and the kit''s folder' $OLD_DEF (Get-ExakitManifestValue 'runtime.deployment_dir')
    Check 'another id: ...so the database stays the user''s' user (Get-ExakitComponentOwnership 'database')
    $t = Invoke-Kit @('status')
    Has 'another id: status says the kit''s own was not found' 'Not found:' $t
    Has 'another id: ...and the user''s is left alone' "is not the kit's, and the kit leaves it alone." $t

    Write-Host 'no recorded id (a kit from before 0.3.1):'
    Reset-Home
    Seed $OLD_DEF 8713; Record-NoId $OLD_DEF
    Update-PersonalDeployDir
    Check 'no id, folder still there: the id is read from it' 'exa-8713' (Get-ExakitManifestValue 'runtime.deployment_id')
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $NEW_DEF) | Out-Null
    Move-Item -LiteralPath $OLD_DEF -Destination $NEW_DEF
    Update-PersonalDeployDir
    Check 'no id, folder still there: after the move it is followed' $NEW_DEF (Get-ExakitManifestValue 'runtime.ownership_path')
    Check 'no id, folder still there: and stays the kit''s' kit (Get-ExakitComponentOwnership 'database')
    Reset-Home
    Seed $OLD_DEF 8714; Record-NoId $OLD_DEF
    Remove-Item -LiteralPath (Join-Path $env:USERPROFILE '.exasol') -Recurse -Force
    Seed $NEW_DEF 8715
    Update-PersonalDeployDir
    Check 'no id + a folder at the new default: no id is taken from it' '' (Get-ExakitManifestValue 'runtime.deployment_id')
    Check 'no id + a folder at the new default: the record is left' $OLD_DEF (Get-ExakitManifestValue 'runtime.ownership_path')
    Check 'no id + a folder at the new default: not claimed' user (Get-ExakitComponentOwnership 'database')
    Check 'no id + a folder at the new default: said missing' "$OLD_DEF|$NEW_DEF" (Get-ExakitPersonalKitMissing)
    try { $null = Set-PersonalManifest 6>$null } catch { Write-Host "  (Set-PersonalManifest: $_ $($_.InvocationInfo.PositionMessage))" }
    Check 'no id + a folder at the new default: a later record takes no id from it' '' (Get-ExakitManifestValue 'runtime.deployment_id')
    Check 'no id + a folder at the new default: ...and it stays unclaimed' user (Get-ExakitComponentOwnership 'database')
    $t = Invoke-Kit @('uninstall', '--dry-run')
    Hasnt 'no id: uninstall --dry-run lists no deployment removal' 'deployment and ALL its data' $t
    Has 'no id: ...and says the kit''s own was not found' "The kit's own database was not found at $OLD_DEF." $t
    Remove-ExakitManifestValue 'runtime.ownership'; Remove-ExakitManifestValue 'runtime.ownership_path'
    Check 'no receipt, no id: not claimed' unknown (Get-ExakitComponentOwnership 'database')
    $t = Invoke-Kit @('uninstall', '--dry-run')
    Hasnt 'no receipt, no id: uninstall --dry-run lists no deployment removal' 'deployment and ALL its data' $t

    Write-Host 'a folder the user chose:'
    Reset-Home
    Seed $NEW 8706
    $custom = Join-Path $work 'custom'
    Seed $custom 8707; Record $custom
    $script:PersonalDeployDir = $custom
    Update-PersonalDeployDir
    Check 'custom: kept although the 2.5.0 folder exists' $custom $script:PersonalDeployDir
    Check 'custom: its port' 8707 (Get-PersonalDbPort)
    Check 'custom: the database is the kit''s' kit (Get-ExakitComponentOwnership 'database')

    Write-Host 'the launcher''s own list (exasol deployments list --json):'
    # List: the launcher's answer, as 2.5.0 prints it, from name/path/status triples.
    function List([string[]]$Triples) {
        $items = @()
        for ($i = 0; $i -le $Triples.Count - 3; $i += 3) {
            $items += [ordered]@{ name = $Triples[$i]; path = $Triples[$i + 1]; status = $Triples[$i + 2]; infrastructure = 'local'; installation = 'local' }
        }
        if ($items.Count -eq 0) { return '[]' }
        return (ConvertTo-Json -InputObject @($items) -Depth 4)
    }
    # Fresh-Process: what a new exakit process starts with (nothing asked yet).
    function Fresh-Process {
        $script:PersonalLauncherDecided = $false
        $script:PersonalLauncherAsked = $false
        $script:PersonalLauncherListed = $false
        $script:PersonalLauncherDeployments = @()
        $script:PersonalDeployFollowed = ''
        $script:PersonalDeployIdSeen = $false
        $script:PersonalDeployDir = ''
        $script:stubListCalls = 0
    }
    $CUSTOM = Join-Path $env:LOCALAPPDATA 'exasol\somewhere-new\deployments\default'
    # A launcher file that is there (the probe is Invoke-ExakitBounded's stub).
    $stubLauncher = Join-Path $work 'exasol-stub'
    Set-Content -LiteralPath $stubLauncher -Value 'stub'
    function Get-PersonalCli { return $stubLauncher }

    # (a) a 2.5-like launcher: the list names the kit's starter-kit-local, where the kit knows it.
    Reset-Home
    Seed $NEW 8720
    $script:stubList = List @('starter-kit-local', $NEW, 'database_ready')
    Fresh-Process
    Update-PersonalDeployDir
    Check '2.5 list: the launcher was asked' 1 $script:stubListCalls
    Check '2.5 list: its starter-kit-local is the folder' $NEW $script:PersonalDeployDir
    Check '2.5 list: with the launcher''s status' 'database_ready' (Resolve-PersonalDeployDir -Path $script:PersonalDeployDir).Status
    Check '2.5 list: the helper gives path, status and name' "$NEW|database_ready|starter-kit-local|local" ((@(Get-PersonalLauncherDeployments) | ForEach-Object { "$($_.Path)|$($_.Status)|$($_.Name)|$($_.Infrastructure)" }) -join ' ')
    $null = Test-PersonalDeploymentExists; $null = Get-PersonalDbPort
    Check '2.5 list: asked once per process' 1 $script:stubListCalls
    $null = Get-PersonalLauncherDeployments -Again
    Check '2.5 list: -Again asks anew' 2 $script:stubListCalls
    # The user's deployments, listed before the kit's would be: none is the kit's.
    Reset-Home
    Seed $NEW_DEF 8721
    $mineDir = Join-Path (Split-Path -Parent $NEW) 'mine'
    Seed $mineDir 8722
    $script:stubList = List @('default', $NEW_DEF, 'database_ready', 'mine', $mineDir, 'stopped')
    Fresh-Process
    Update-PersonalDeployDir
    Check '2.5 list: the user''s default and mine are not the kit''s folder' "$NEW|" ("{0}|{1}" -f $script:PersonalDeployDir, (Resolve-PersonalDeployDir -Path '').Status)
    Check '2.5 list: ...nor their port' 8563 (Get-PersonalDbPort)
    Check '2.5 list: ...and nothing claims them' unknown (Get-ExakitComponentOwnership 'database')
    $alphaDir = Join-Path (Split-Path -Parent $NEW) 'alpha'
    Seed $alphaDir 8723
    $script:stubList = List @('alpha', $alphaDir, 'stopped', 'default', $NEW_DEF, 'database_ready')
    Check '2.5 list: the launcher''s order, no default sorted first' 'alpha default' ((@(Get-PersonalLauncherDeployments -Again) | ForEach-Object { $_.Name }) -join ' ')
    Reset-Home
    $script:stubList = '[]'
    Fresh-Process
    Update-PersonalDeployDir
    Check '2.5 list: an empty list is an answer' "True|$NEW" ("{0}|{1}" -f $script:PersonalLauncherListed, $script:PersonalDeployDir)

    # (b) a 2.4-like launcher: no such command, the two known folders.
    Reset-Home
    Seed $OLD 8722
    $script:stubList = $null
    Fresh-Process
    Update-PersonalDeployDir
    Check '2.4 launcher: no list, the known folders' "False|$OLD" ("{0}|{1}" -f $script:PersonalLauncherListed, $script:PersonalDeployDir)
    Check '2.4 launcher: the helper gives nothing' 0 (@(Get-PersonalLauncherDeployments -Again).Count)

    # (c) a "2.6.0" that keeps its deployments somewhere new.
    Reset-Home
    Seed $CUSTOM 8723
    $script:stubList = List @('default', $CUSTOM, 'database_ready')
    Fresh-Process
    Update-PersonalDeployDir
    Check '2.6 list: the user''s default where the launcher keeps it is not the kit''s folder' $NEW $script:PersonalDeployDir
    Check '2.6 list: ...so no deployment of the kit''s exists' False (Test-PersonalDeploymentExists)
    Check '2.6 list: it is not the kit''s' unknown (Get-ExakitComponentOwnership 'database')
    # Recorded as the user's (a 0.3.0 kit's answer to "Use it instead?"): a
    # later process finds it from the record, without asking the launcher.
    Set-ExakitManifestValue 'runtime.type' 'personal'
    Set-ExakitManifestValue 'runtime.deployment_dir' $CUSTOM
    Set-ExakitReusedOwnership 'database' $CUSTOM
    Check '2.6 list: adopted as the user''s' user (Get-ExakitManifestValue 'runtime.ownership')
    Fresh-Process
    Update-PersonalDeployDir
    Check '2.6 list: a later process finds it from the record' $CUSTOM $script:PersonalDeployDir
    Check '...without a launcher call' 0 $script:stubListCalls
    Check '2.6 list: update and uninstall leave it' False (Test-ExakitComponentManaged 'database')
    $t = Invoke-Kit @('uninstall', '--dry-run')
    Hasnt '2.6 list: uninstall --dry-run lists no removal of it' 'deployment and ALL its data' $t
    Check '2.6 list: the dry run touched nothing' True (Test-Path -LiteralPath (Join-Path $CUSTOM 'deployment.json'))
    # The kit's own deployment, moved by that launcher out of the 2.5 folder:
    # the record follows it, the id guard holding.
    Reset-Home
    Seed $NEW 8724; Record $NEW
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $CUSTOM) | Out-Null
    Move-Item -LiteralPath $NEW -Destination $CUSTOM
    $script:stubList = List @('default', $CUSTOM, 'stopped')
    Fresh-Process
    Update-PersonalDeployDir
    Check '2.6 move: the folder follows' $CUSTOM $script:PersonalDeployDir
    Check '2.6 move: runtime.deployment_dir follows' $CUSTOM (Get-ExakitManifestValue 'runtime.deployment_dir')
    Check '2.6 move: the ownership receipt follows' $CUSTOM (Get-ExakitManifestValue 'runtime.ownership_path')
    Check '2.6 move: still the kit''s' kit (Get-ExakitComponentOwnership 'database')
    Check '2.6 move: nothing said missing' '' (Get-ExakitPersonalKitMissing)
    # Another id there: the user's own. Never claimed.
    Reset-Home
    Seed $NEW 8725; Record $NEW
    Remove-Item -LiteralPath $NEW -Recurse -Force
    Seed $CUSTOM 8726
    $script:stubList = List @('default', $CUSTOM, 'database_ready')
    Fresh-Process
    Update-PersonalDeployDir
    # The kit's own gone, and a deployment of another name of the user's: that
    # one is no stand-in for the kit's, so nothing is said missing either.
    Check '2.6 guard: the kit''s folder stays its own (gone), never the user''s' $NEW $script:PersonalDeployDir
    Check '2.6 guard: the record is left as it is' $NEW (Get-ExakitManifestValue 'runtime.deployment_dir')
    Check '2.6 guard: the receipt is not followed' $NEW (Resolve-PersonalDeployDir -Path $NEW -Recorded).Dir
    Check '2.6 guard: no id is read from the user''s' '' (Get-PersonalDeploymentId)
    Check '2.6 guard: the user''s is not said to stand in for the kit''s' '' (Get-ExakitPersonalKitMissing)
    if ($env:OS -ne 'Windows_NT') {
        # The kit as a user runs it, with a launcher that lists the folder
        # (a script; Windows needs a real exasol.exe, so not there).
        New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null
        $listFile = Join-Path $work 'list.json'
        Set-Content -LiteralPath $listFile -Value $script:stubList
        Set-Content -LiteralPath $script:PersonalBinPath -Value @('#!/bin/sh', ('[ "$1" = deployments ] && { cat "' + $listFile + '"; exit 0; }'), 'exit 1')
        & chmod +x $script:PersonalBinPath
        $t = Invoke-Kit @('uninstall', '--dry-run')
        Remove-Item -LiteralPath $script:PersonalBinPath -Force
        Hasnt '2.6 guard: uninstall --dry-run never names the user''s folder' $CUSTOM $t
        Check '2.6 guard: ...and touched nothing of it' True (Test-Path -LiteralPath (Join-Path $CUSTOM 'deployment.json'))
    }
    # The uninstall sees the launcher's other deployments and the kit's moved copy.
    Reset-Home
    Seed $NEW 8727; Record $NEW
    Seed $CUSTOM 8728
    $script:stubList = List @('default', $NEW, 'database_ready', 'other', $CUSTOM, 'stopped')
    Fresh-Process
    Update-PersonalDeployDir
    Check 'uninstall: a deployment the launcher lists elsewhere keeps the shared cache' $CUSTOM ((@(Get-PersonalOtherDeployments)) -join ' ')
    Reset-Home
    Seed $CUSTOM 8729
    $script:stubList = List @('default', $CUSTOM, 'stopped')
    Fresh-Process
    $script:PersonalDeployDir = Join-Path $work 'gone\default'
    Find-PersonalTeardownLeftovers -Id 'exa-8729'
    Check 'uninstall: the same deployment in a folder the launcher lists is named' $true (@($script:PersonalTeardownLeftovers) -contains "the deployment directory $CUSTOM (the database and ALL its data)")

    # (d) an answer that is not the list: the known folders.
    $customJson = (List @('default', $CUSTOM, 'database_ready'))
    foreach ($bad in @(@('garbage', 'Usage: exasol deployments list [flags]'), @('not a list', '{"name": "default"}'), @('half a list', '[{"name": "default", "path": '), @('fails', $null))) {
        Reset-Home
        Seed $NEW 8730; Seed $CUSTOM 8731
        $script:stubList = $bad[1]
        Fresh-Process
        Update-PersonalDeployDir
        Check "bad answer ($($bad[0])): the known folders" "False|$NEW" ("{0}|{1}" -f $script:PersonalLauncherListed, $script:PersonalDeployDir)
    }
    Reset-Home
    Seed $NEW 8732
    $script:stubList = "Migrated managed deployments to $(Split-Path -Parent $NEW)`n" + (List @('starter-kit-local', $NEW, 'stopped'))
    Fresh-Process
    Update-PersonalDeployDir
    Check 'a notice before the list: the list is read' "True|$NEW|stopped" ("{0}|{1}|{2}" -f $script:PersonalLauncherListed, $script:PersonalDeployDir, (Resolve-PersonalDeployDir -Path $NEW).Status)
    # A notice AFTER the list (OWN-05): read as the shell and Python twins read
    # it (raw_decode), the text after the array ignored. A bracket inside a
    # string does not end the list early.
    $script:stubList = (List @('starter-kit-local', $NEW, 'database_ready')) + "`nA new version of Exasol Personal is available: 2.6.1 [see https://example.org]"
    Fresh-Process
    Update-PersonalDeployDir
    Check 'a notice after the list: the list is read' "True|$NEW|database_ready" ("{0}|{1}|{2}" -f $script:PersonalLauncherListed, $script:PersonalDeployDir, (Resolve-PersonalDeployDir -Path $NEW).Status)
    Check 'the first JSON value: a bracket in a string stays in it' '[{"name": "a]b\"c"}]' (Get-PersonalFirstJsonValue '[{"name": "a]b\"c"}] trailing')
    Check '...a value that never closes is none' '' (Get-PersonalFirstJsonValue '[{"name": "default"')
    $script:stubList = List @('default', 'relative\default', 'stopped')
    Fresh-Process
    Update-PersonalDeployDir
    Check 'a relative path is no folder' "True|0|$NEW" ("{0}|{1}|{2}" -f $script:PersonalLauncherListed, @($script:PersonalLauncherDeployments).Count, $script:PersonalDeployDir)
    $script:stubList = $null
    Fresh-Process
    function Get-PersonalCli { return 'exasol-stub' }

    Write-Host 'the deployment id: one reader, the launcher''s state first (WSL-03, MCU-04):'
    Reset-Home
    New-Item -ItemType Directory -Force -Path $NEW | Out-Null
    $stateFile = Join-Path $NEW '.exasolLauncherState.json'; $jsonFile = Join-Path $NEW 'deployment.json'
    Set-Content -LiteralPath $stateFile -Value '{"deploymentId": "exa-state", "nested": {"deploymentId": "exa-deep"}}'
    Set-Content -LiteralPath $jsonFile -Value '{"deploymentId": "local", "connection": {}}'
    Check 'id: the state file wins over deployment.json' 'exa-state' (Get-PersonalDeploymentId -Dir $NEW)
    $script:PersonalDeployDir = $NEW
    Check 'id: the language container lookup reads the same' 'exa-state' (Get-PersonalSlcContainerId)
    Set-Content -LiteralPath $jsonFile -Value '{"deploymentId": "exa-old"}'
    Check 'id: both files differ: the state file' 'exa-state' (Get-PersonalDeploymentId -Dir $NEW)
    Remove-Item -LiteralPath $stateFile -Force
    Check 'id: deployment.json when the state file is not there' 'exa-old' (Get-PersonalDeploymentId -Dir $NEW)
    Set-Content -LiteralPath $jsonFile -Value '{"deploymentId": "local"}'
    Check 'id: "local" is no id' '' (Get-PersonalDeploymentId -Dir $NEW)
    Set-Content -LiteralPath $jsonFile -Value '{"deploymentId": "  "}'
    Check 'id: blank is no id' '' (Get-PersonalDeploymentId -Dir $NEW)
    Set-Content -LiteralPath $jsonFile -Value '{"connection": {"deploymentId": "exa-deep"}}'
    Check 'id: a nested key is no id' '' (Get-PersonalDeploymentId -Dir $NEW)
    Set-Content -LiteralPath $stateFile -Value '{"currentWorkflowState": {"running": {}}}'
    Set-Content -LiteralPath $jsonFile -Value '{"deploymentId": "exa-json"}'
    Check 'id: a state file without one falls back to deployment.json' 'exa-json' (Get-PersonalDeploymentId -Dir $NEW)
    Set-Content -LiteralPath $stateFile -Value '{"deploymentId": "exa-kit"}'
    Set-Content -LiteralPath $jsonFile -Value '{"deploymentId": "local"}'
    Check 'guard: followed on the state''s id' $NEW (Resolve-PersonalDeployDir -Path $OLD -Recorded -DeploymentId 'exa-kit').Dir
    Check 'guard: never on "local"' $OLD (Resolve-PersonalDeployDir -Path $OLD -Recorded -DeploymentId 'local').Dir
    Set-Content -LiteralPath $stateFile -Value '{"deploymentId": "exa-user"}'
    Set-Content -LiteralPath $jsonFile -Value '{"deploymentId": "exa-kit"}'
    Check 'guard: not on a deployment.json the state contradicts' $OLD (Resolve-PersonalDeployDir -Path $OLD -Recorded -DeploymentId 'exa-kit').Dir

    Write-Host 'another deployment made in the kit''s own folder (MCU-02):'
    Reset-Home
    Seed $NEW 8750; Record $NEW
    Update-PersonalDeployDir
    Check 'same folder: the kit''s own is the kit''s' kit (Get-ExakitComponentOwnership 'database')
    Remove-Item -LiteralPath $NEW -Recurse -Force; Seed $NEW 8751
    Check 'same folder, another id: the database is the user''s' user (Get-ExakitComponentOwnership 'database')
    Check '...so update and uninstall leave it' False (Test-ExakitComponentManaged 'database')
    $t = Invoke-Kit @('uninstall', '--dry-run')
    Hasnt '...uninstall --dry-run lists no removal of it' 'deployment and ALL its data' $t
    Set-ExakitReusedOwnership 'database' $NEW
    try { $null = Set-PersonalManifest 6>$null } catch { Write-Host "  (Set-PersonalManifest: $_)" }
    Check '...a later record keeps the kit''s id' 'exa-8750' (Get-ExakitManifestValue 'runtime.deployment_id')
    Check '...and records it as the user''s' user (Get-ExakitManifestValue 'runtime.ownership')
    Check '...which stays the user''s' user (Get-ExakitComponentOwnership 'database')
    $t = Invoke-Kit @('uninstall', '--dry-run')
    Hasnt '...uninstall --dry-run still lists no removal of it' 'deployment and ALL its data' $t
    $script:PersonalRecordFresh = $true
    try { $null = Set-PersonalManifest -Fresh 6>$null } catch { Write-Host "  (Set-PersonalManifest: $_)" }
    Check 'a fresh deploy of the kit''s: the new id is the kit''s' 'exa-8751' (Get-ExakitManifestValue 'runtime.deployment_id')

    Write-Host 'a start records that it runs, and leaves the version that created the deployment (F-02):'
    Reset-Home
    Seed $NEW 8760; Record $NEW
    Set-ExakitManifestValue 'runtime.deployment_version' '2.4.0'
    Set-ExakitManifestValue 'runtime.status' 'stopped'
    # Whatever the version file says after the start, the recorded version is
    # the one that created the deployment: a start does not move it.
    Set-Content -LiteralPath (Join-Path $NEW '.exasolLauncher.version') -Value '2.5.0'
    function Get-PersonalEngineRecorded { return 'podman' }
    function Get-PersonalPodman { return $null }
    function Get-PersonalLogOffset { return 0 }
    function Test-PersonalLauncherSupports { param($Subcommand) return $true }
    function Get-PersonalLauncherState { return 'stopped' }
    function Show-PersonalGuestRebuildNote { }
    function Get-PersonalAutoApproveFlag { param($Subcommand) return $null }
    function Initialize-PersonalSlcDns { }
    function Repair-PersonalSlcDns { return 0 }
    function Invoke-ExakitLogged { return 0 }
    Start-Personal 6>$null
    Check 'start: runtime.deployment_version stays the creating version' '2.4.0' (Get-ExakitManifestValue 'runtime.deployment_version')
    Check 'start: runtime.status says it runs' 'running' (Get-ExakitManifestValue 'runtime.status')

    Write-Host 'only the kit''s own deployment, or one adopted, is ever acted on (OWN-01, AGT-01):'
    # Every launcher call the functions make, logged; none may name a folder.
    $script:launcherCalls = @()
    function Invoke-ExakitLogged { $script:launcherCalls += ($args -join ' '); return 0 }
    # The screen helpers live in ui.ps1, which this test does not load.
    function Write-ExakitError($m) { Write-Host $m }
    function Get-JsonField([string]$Text, [string]$Path) {
        $start = $Text.IndexOf('{')
        if ($start -lt 0) { return '<no json>' }
        $doc = $Text.Substring($start) | ConvertFrom-Json
        foreach ($key in $Path.Split('.')) { if ($null -eq $doc) { break }; $doc = $doc.$key }
        if ($null -eq $doc) { return 'null' }
        return "$doc"
    }
    # (a) the kit's own gone, the user's in the launcher's default (OWN hA, AGT-01).
    Reset-Home
    Seed $OLD_DEF 8770; Record $OLD_DEF                 # the kit's own, id exa-8770
    Remove-Item -LiteralPath (Join-Path $env:USERPROFILE '.exasol\personal') -Recurse -Force
    Seed $NEW_DEF 8771                              # the user's own, id exa-8771
    Update-PersonalDeployDir
    Check 'kit gone: the state names both folders' "kit_database_missing|$OLD_DEF|$NEW_DEF" (Get-ExakitPersonalDbState)
    $t = Invoke-Kit @('start')
    Check 'kit gone: exakit start refuses, exit 3' 3 $LASTEXITCODE
    Has 'kit gone: ...says the kit''s own was not found' "The kit's own database was not found at $OLD_DEF." $t
    Has 'kit gone: ...and names the installer' 're-run the installer' $t
    $t = Invoke-Kit @('stop')
    Check 'kit gone: exakit stop refuses, exit 3' 3 $LASTEXITCODE
    $t = Invoke-Kit @('start', 'database')
    Check 'kit gone: exakit start database refuses, exit 3' 3 $LASTEXITCODE
    $t = Invoke-Kit @('status', '--json')
    Check 'kit gone: status --json exit 3' 3 $LASTEXITCODE
    Check 'kit gone: ...status no database' 'no database' (Get-JsonField $t 'status')
    Check 'kit gone: ...runtime.state names it' 'kit_database_missing' (Get-JsonField $t 'runtime.state')
    Check 'kit gone: ...runtime.found names the user''s folder' $NEW_DEF (Get-JsonField $t 'runtime.found')
    Has 'kit gone: ...the remedy is the installer, never exakit start' 'starter-kit.ps1 | iex' (Get-JsonField $t 'remedy')
    Has 'kit gone: ...the hint says the installer asks which database to use' 'The installer asks which database to use' (Get-JsonField $t 'remedy_hint')
    Check 'kit gone: status --json names whose database and where (AGT-05)' "user|$OLD_DEF" "$(Get-JsonField $t 'runtime.ownership')|$(Get-JsonField $t 'runtime.deployment_dir')"
    Check '...and the release the kit is tested with' $true ((Get-JsonField $t 'runtime.launcher_tested_version') -ne 'null')
    $t = Invoke-Kit @('status')
    Hasnt 'kit gone: the status screen never says exakit start' 'Start it:' $t
    Has 'kit gone: ...it names the installer' 'Use it:' $t
    $t = Invoke-Kit @('info', '--json')
    Check 'kit gone: info --json agrees' 'no database|kit_database_missing|3' "$(Get-JsonField $t 'status')|$(Get-JsonField $t 'runtime.state')|$LASTEXITCODE"
    Check 'kit gone: info --json shows the computed owner, the receipt beside it (AGT-05)' 'user|kit' "$(Get-JsonField $t 'runtime.ownership')|$(Get-JsonField $t 'runtime.ownership_recorded')"
    $t = Invoke-Kit @('mcp-doctor', '--json')
    Check 'kit gone: mcp-doctor --json agrees' 'no database|kit_database_missing|3' "$(Get-JsonField $t 'status')|$(Get-JsonField $t 'runtime.state')|$LASTEXITCODE"
    $t = Invoke-Kit @('connect', 'postgresql', '--name', 'pg', '--json')
    Check 'kit gone: connect --json refuses before anything runs' 'unreachable_db|22' "$(Get-JsonField $t 'kind')|$LASTEXITCODE"
    $t = Invoke-Kit @('source', 'check', 'pg', '--json')
    Check 'kit gone: source check --json refuses too' 'unreachable_db|22' "$(Get-JsonField $t 'kind')|$LASTEXITCODE"
    # The functions the commands reach say no as well.
    $script:launcherCalls = @()
    Start-Personal 6>$null
    Stop-Personal 6>$null
    Check 'kit gone: the wait-or-deploy deploys nothing' 'False' (Wait-PersonalReadyOrDeploy 6>$null)
    # The real one (a block above stubbed it).
    $rpAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'setup/lib/runtime-personal.ps1'), [ref]$null, [ref]$null)
    Invoke-Expression ($rpAst.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Repair-PersonalSlcDns' }, $true).Extent.Text)
    Check 'kit gone: the language-container DNS repair touches nothing' 'False' (Repair-PersonalSlcDns 6>$null)
    Check 'kit gone: the MCP sidecar definition is not written' '' "$(Write-McpSidecarDefinition 'mcp_readonly' 'pw' 4896 'uv' $repo 6>$null)"
    Check 'kit gone: nor the MCP sidecar applied' 'False' (Set-McpSidecar -Quiet 6>$null)
    Confirm-ExakitRuntimeRunning -Deploy 6>$null
    Check 'kit gone: ...none of them called the launcher' '' ($script:launcherCalls -join ';')
    # Recorded as the user's (the installer's one question renames the one
    # picked, and a 0.3.0 kit's "Use it instead?" recorded it as it was): then
    # it is the user's database the kit works with, and the refusal is gone.
    Set-ExakitReusedOwnership 'database' $NEW_DEF
    Check 'kit gone, then adopted: no state' '' (Get-ExakitPersonalDbState)
    Check 'kit gone, then adopted: the guard lets the kit act' 'True' (Test-ExakitKitDatabaseGuard)
    # (b) another deployment made in the kit's own folder (MCU-02).
    Reset-Home
    Seed $NEW 8772; Record $NEW                 # the kit's own, id exa-8772
    Remove-Item -LiteralPath $NEW -Recurse -Force; Seed $NEW 8773
    Update-PersonalDeployDir
    Check 'same folder, another id: the state names it' "kit_database_missing|$NEW|$NEW" (Get-ExakitPersonalDbState)
    $t = Invoke-Kit @('start')
    Check 'same folder, another id: exakit start refuses, exit 3' 3 $LASTEXITCODE
    $t = Invoke-Kit @('status', '--json')
    Check 'same folder, another id: status --json names it' "kit_database_missing|$NEW|3" "$(Get-JsonField $t 'runtime.state')|$(Get-JsonField $t 'runtime.found')|$LASTEXITCODE"
    Set-ExakitReusedOwnership 'database' $NEW
    Check 'same folder, adopted: no state' '' (Get-ExakitPersonalDbState)
    # (c) an adopted deployment gone, another in the launcher's default.
    Reset-Home
    $mine = Join-Path $work 'mine\default'
    Seed $OLD_DEF 8774
    Set-ExakitManifestValue 'runtime.type' 'personal'
    Set-ExakitManifestValue 'runtime.deployment_dir' $OLD_DEF
    Set-ExakitManifestValue 'runtime.ownership' 'user'
    Set-ExakitManifestValue 'runtime.ownership_path' $OLD_DEF
    Remove-Item -LiteralPath (Join-Path $env:USERPROFILE '.exasol\personal') -Recurse -Force
    Seed $NEW_DEF 8775
    Update-PersonalDeployDir
    Check 'adopted gone: the state names both folders' "kit_database_missing|$OLD_DEF|$NEW_DEF" (Get-ExakitPersonalDbState)
    $t = Invoke-Kit @('stop')
    Check 'adopted gone: exakit stop refuses, exit 3' 3 $LASTEXITCODE
    # (d) the kit's own, where it is: nothing in the way.
    Reset-Home
    Seed $NEW 8776; Record $NEW
    Update-PersonalDeployDir
    Check 'kit''s own: no state' '' (Get-ExakitPersonalDbState)
    Check 'kit''s own: the guard lets it act' 'True' (Test-ExakitKitDatabaseGuard)

    Write-Host 'the launcher cache:'
    Reset-Home
    Check 'cache: 2.5.0''s folder when none is there' (Join-Path $env:LOCALAPPDATA 'exasol\launcher\resources') (Get-PersonalLauncherCacheDir)
    New-Item -ItemType Directory -Force -Path (Join-Path $env:LOCALAPPDATA '.exasol') | Out-Null
    Check 'cache: the earlier folder while it is the only one' (Join-Path $env:LOCALAPPDATA '.exasol') (Get-PersonalLauncherCacheDir)
    New-Item -ItemType Directory -Force -Path (Join-Path $env:LOCALAPPDATA 'exasol\launcher\resources') | Out-Null
    Check 'cache: 2.5.0''s folder once it exists' (Join-Path $env:LOCALAPPDATA 'exasol\launcher\resources') (Get-PersonalLauncherCacheDir)

    Write-Host 'the port of a new starter-kit-local (D3: Select-PersonalDbPort):'
    Reset-Home
    # The launcher asked already, with no list: only the two roots are read.
    $script:PersonalLauncherAsked = $true; $script:PersonalLauncherListed = $false; $script:PersonalLauncherDeployments = @()
    $realPortFree = ${function:Test-PersonalPortFree}
    $script:busyPorts = @()
    function Test-PersonalPortFree { param([int]$Port) return ($script:busyPorts -notcontains $Port) }
    Check 'pick: nothing saved, nothing busy: 8563' 8563 (Select-PersonalDbPort)
    Seed $NEW_DEF 8563
    Check 'pick: a stopped database of the user''s saved 8563 (not in use now): the next port' 8564 (Select-PersonalDbPort)
    $theirsOld = Join-Path (Split-Path -Parent $OLD) 'older'
    New-Item -ItemType Directory -Force -Path (Join-Path $theirsOld 'infrastructure') | Out-Null
    Set-Content -LiteralPath (Join-Path $theirsOld 'infrastructure\infrastructure.yaml') -Value @('local:', '    cpuCount: 4', '    ports: db:8564', '    containerEngine: podman')
    Check 'saved: the db port of infrastructure.yaml' '8564' ((@(Get-PersonalSavedDbPorts -Dir $theirsOld)) -join ',')
    Check 'saved: dbPort of deployment.json' '8563' ((@(Get-PersonalSavedDbPorts -Dir $NEW_DEF)) -join ',')
    Check 'saved: a folder with neither has none' '' ((@(Get-PersonalSavedDbPorts -Dir (Join-Path $work 'nothing-here'))) -join ',')
    Check 'pick: ...and one in the older root, saved in its infrastructure.yaml' 8565 (Select-PersonalDbPort)
    $script:busyPorts = @(8565)
    Check 'pick: ...and a port in use now' 8566 (Select-PersonalDbPort)
    $elsewhere = Join-Path $work 'elsewhere\deployments\x'
    Seed $elsewhere 8566
    $script:PersonalLauncherListed = $true; $script:PersonalLauncherDeployments = @((Row 'x' $elsewhere 'stopped'))
    Check 'pick: ...and one the launcher lists in another root' 8567 (Select-PersonalDbPort)
    Seed $NEW 8567; $script:PersonalDeployDir = $NEW
    Check 'pick: the kit''s own folder reserves nothing against itself' 8567 (Select-PersonalDbPort)
    $script:busyPorts = @(8563..8663)
    Check 'pick: nothing free from 8563 to 8663: none' 0 (Select-PersonalDbPort)
    ${function:Test-PersonalPortFree} = $realPortFree
    $script:PersonalLauncherAsked = $false; $script:PersonalLauncherListed = $false; $script:PersonalLauncherDeployments = @()
    # The real probe, on a port of the test's own: free, then held.
    $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $probe.Start(); $probePort = ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port; $probe.Stop()
    Check 'free: a port nothing holds is free' True (Test-PersonalPortFree -Port $probePort)
    $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $probePort)
    $probe.Start()
    try { Check 'free: a port a program listens on is not' False (Test-PersonalPortFree -Port $probePort) } finally { $probe.Stop() }
    # Until the deployment says its port (deployment.json), the picked one is the answer.
    Reset-Home
    $script:PersonalPortPicked = 8571
    Check 'port: before the deploy writes its own, the picked one' 8571 (Get-PersonalDbPort)
    Seed $NEW 8572
    Check 'port: then the deployment''s own' 8572 (Get-PersonalDbPort)
    $script:PersonalPortPicked = 0

    Write-Host 'the launcher''s install local takes --ports (read from the help the engine probe reads):'
    $helpCli = Join-Path $work 'exasol-help-stub'
    Set-Content -LiteralPath $helpCli -Value 'stub'
    & {
        function Get-PersonalCli { return $helpCli }
        $script:helpText = "Flags:`n  --container-engine string   docker or podman`n  --ports string   host ports, e.g. db:8563`n"
        $script:helpCalls = 0
        function Invoke-ExakitBounded { param($FilePath, $Arguments, $TimeoutSeconds) if (($Arguments -join ' ') -eq 'install local --help') { $script:helpCalls++; return $script:helpText }; return $null }
        $script:PersonalLauncherCache = $null
        Check 'takes ports: launcher 2.5''s help names --ports' True (Test-PersonalLauncherTakesPorts)
        Check '...and the engine flag from the same help' True (Test-PersonalLauncherTakesEngine)
        Check '...one help read for both' 1 $script:helpCalls
        # Another launcher file (another size): a new question.
        $script:helpText = "Flags:`n  --container-engine string   docker or podman`n"
        Set-Content -LiteralPath $helpCli -Value 'another launcher'
        Check 'takes ports: a launcher whose help does not name it, no' False (Test-PersonalLauncherTakesPorts)
        function Get-PersonalCli { return (Join-Path $work 'no-launcher-here') }
        Check 'takes ports: no launcher, no' False (Test-PersonalLauncherTakesPorts)
    }
    $script:PersonalLauncherCache = $null

    Write-Host 'refresh writes nothing to the pipeline:'
    Reset-Home
    Seed $OLD 8708; Record $OLD
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $NEW) | Out-Null
    Move-Item -LiteralPath $OLD -Destination $NEW
    $script:PersonalDeployDir = $OLD; $script:PersonalDeployFollowed = ''
    Check 'quiet: a follow returns nothing' 0 (@(Update-PersonalDeployDir).Count)
    Check 'quiet: the port is still one number' 8708 (Get-PersonalDbPort)
    Write-Host 'the 20-session limit a 2.4 launcher set (Remove-PersonalSessionLimit):'
    # The launcher once more: a version ($script:stubVersion), a database state
    # that stop and start change, a stop that fails ($script:stubStopRc) and
    # $script:stubStartFails starts that fail before one works.
    $script:stubVersion = '2.5.0'; $script:stubState = 'stopped'; $script:stubStopRc = 0; $script:stubStartFails = 0
    $script:lifeCalls = @(); $script:kitCalls = @(); $script:said = @()
    function Invoke-ExakitBounded { param($FilePath, $Arguments, $TimeoutSeconds)
        $script:lifeCalls += ($Arguments -join ' ')
        if ($Arguments[0] -eq 'version') { return $script:stubVersion }
        if ($Arguments[0] -eq 'deployments') { return $script:stubList }
        $at = [array]::IndexOf([string[]]$Arguments, '--deployment-dir')
        if ($Arguments[0] -eq 'info' -and $at -ge 0) { if (Test-Path -LiteralPath $Arguments[$at + 1]) { return 'info' }; return $null }
        $r = Resolve-PersonalDeployDir
        if ($Arguments[0] -eq 'info' -and ((Test-Path -LiteralPath $r.New) -or (Test-Path -LiteralPath $r.Legacy))) { return 'info' }
        return $null
    }
    function Invoke-ExakitLogged {
        $line = (@($args | Select-Object -Skip 1) -join ' ')
        $script:lifeCalls += $line
        if ($args[1] -eq 'stop') { if ($script:stubStopRc -ne 0) { return 1 }; $script:stubState = 'stopped'; return 0 }
        if ($args[1] -eq 'start') {
            if ($script:stubStartFails -gt 0) { $script:stubStartFails--; return 1 }
            $script:stubState = 'running'; return 0
        }
        return 0
    }
    function Get-PersonalStatus { return $script:stubState }
    function Wait-PersonalReadyOrDeploy { $script:kitCalls += 'Wait-PersonalReadyOrDeploy'; return ($script:stubState -eq 'running') }
    if (-not (Get-Command Get-ExakitTilde -ErrorAction SilentlyContinue)) { function Get-ExakitTilde([string]$Path) { return $Path } }
    function Info($m) { $script:said += "INFO $m" }
    function Warn2($m) { $script:said += "WARN $m" }
    function Fail([string]$Msg) { throw $Msg }
    $CONF_REL = [IO.Path]::Combine('local', 'runtime', 'exa', 'exasol.conf')
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    function Get-ConfText([string]$Eol, [switch]$Without, [switch]$Last) {
        $lines = @('[Global]', '    Name = exa', '[DB_PARAMS]')
        if (-not $Without) { $lines += 'maxConnectionsLicenseLimit=20' }
        $lines += '    Params = -etlJdbcJavaEnv=-Xmx2g'
        $text = (($lines + 'tail = 1') -join $Eol)
        if (-not $Last) { $text += $Eol }
        return $text
    }
    function Write-Conf([string]$Dir, [string]$Text) {
        New-Item -ItemType Directory -Force -Path ([IO.Path]::Combine($Dir, 'local', 'runtime', 'exa')) | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $Dir $CONF_REL), $latin1.GetBytes($Text))
    }
    function Read-Conf([string]$Path) { if (Test-Path -LiteralPath $Path) { return $latin1.GetString([IO.File]::ReadAllBytes($Path)) }; return '<none>' }
    function Invoke-Lift([string]$State, [int]$StartFails = 0) {
        $script:stubState = $State; $script:stubStartFails = $StartFails
        $script:lifeCalls = @(); $script:kitCalls = @(); $script:said = @()
        $script:PersonalDeployFollowed = ''; $script:PersonalLauncherDecided = $false; $script:PersonalDeployRec = ''
        return (Remove-PersonalSessionLimit)
    }
    function Get-Acted { return ((@($script:lifeCalls | Where-Object { $_ -match '^(stop|start)\b' })) -join '|') }
    $LF = "`n"; $CRLF = "`r`n"
    $cf = Join-Path $NEW $CONF_REL

    # Running, launcher 2.5.0, the kit's own deployment: stop, edit, start.
    Reset-Home
    Seed $NEW 8790; Record $NEW; Write-Conf $NEW (Get-ConfText $CRLF)
    $r = Invoke-Lift 'running'
    Check 'lift running: succeeds' 'True' $r
    Check 'lift running: only the limit line is gone, CRLF kept' (Get-ConfText $CRLF -Without) (Read-Conf $cf)
    Check 'lift running: the backup is the file as it was' (Get-ConfText $CRLF) (Read-Conf "$cf.before-session-limit")
    Check 'lift running: stopped and started with the launcher, on the kit''s folder' "stop --deployment-dir $NEW|start --deployment-dir $NEW" (Get-Acted)
    Check 'lift running: waited for as exakit start does' 'Wait-PersonalReadyOrDeploy' ($script:kitCalls -join '|')
    Check 'lift running: the database runs again' 'running' $script:stubState
    Check 'lift running: the manifest records it' 'lifted' (Get-ExakitManifestValue 'runtime.session_limit')
    Check 'lift running: ...with the date' 'True' ("" + (Get-ExakitManifestValue 'runtime.session_limit_lifted_at') -match '^20\d\d-.*Z$')
    Check 'lift running: one line says it, with the restart' 'INFO Removing the 20-session limit that Exasol Personal 2.4 set on this database. The database restarts once.' ($script:said -join '|')
    $r = Invoke-Lift 'running'
    Check 'lift again: nothing to do' 'True' $r
    Check 'lift again: no launcher call' '' ($script:lifeCalls -join '|')
    Write-Conf $NEW (Get-ConfText $LF)
    $r = Invoke-Lift 'running'
    Check 'lift recorded: a line put back stays' 'True' (Test-PersonalSessionLimitSet $cf)
    Check 'lift recorded: no launcher call' '' ($script:lifeCalls -join '|')

    # LF and no final line end are kept as they were.
    Reset-Home
    Seed $NEW 8791; Record $NEW; Write-Conf $NEW (Get-ConfText $LF -Last)
    $r = Invoke-Lift 'stopped'
    Check 'lift lf: LF and the missing final line end are kept' (Get-ConfText $LF -Without -Last) (Read-Conf $cf)

    # Stopped: the file only, no stop and no start.
    Reset-Home
    Seed $NEW 8792; Record $NEW; Write-Conf $NEW (Get-ConfText $LF)
    $r = Invoke-Lift 'stopped'
    Check 'lift stopped: succeeds' 'True' $r
    Check 'lift stopped: the line is gone' 'False' (Test-PersonalSessionLimitSet $cf)
    Check 'lift stopped: no stop and no start' '' (Get-Acted)
    Check 'lift stopped: the database stays stopped' 'stopped' $script:stubState
    Check 'lift stopped: one line says when it applies' 'INFO Removing the 20-session limit that Exasol Personal 2.4 set on this database. The change takes effect when the database next starts.' ($script:said -join '|')

    # No line: nothing, no launcher call, no backup.
    Reset-Home
    Seed $NEW 8793; Record $NEW; Write-Conf $NEW (Get-ConfText $LF -Without)
    $r = Invoke-Lift 'running'
    Check 'no line: nothing to do' 'True' $r
    Check 'no line: no launcher call' '' ($script:lifeCalls -join '|')
    Check 'no line: no backup' 'False' (Test-Path -LiteralPath "$cf.before-session-limit")
    Check 'no line: not recorded' '' ("" + (Get-ExakitManifestValue 'runtime.session_limit'))

    # Launcher before 2.5.0: untouched.
    Reset-Home
    Seed $NEW 8794; Record $NEW; Write-Conf $NEW (Get-ConfText $LF)
    $script:stubVersion = '2.4.0'
    $r = Invoke-Lift 'running'
    $script:stubVersion = '2.5.0'
    Check 'launcher 2.4.0: nothing to do' 'True' $r
    Check 'launcher 2.4.0: the file is untouched' (Get-ConfText $LF) (Read-Conf $cf)
    Check 'launcher 2.4.0: no stop or start' '' (Get-Acted)

    # A database the user let the kit use (owner user): permission to use it
    # is permission to lift its limit, the same way, never more (CONTRACT
    # section 6). Twin of the same case in personal-deploy-dir.sh.
    Reset-Home
    Seed $NEW 8795; Record $NEW; Write-Conf $NEW (Get-ConfText $LF)
    Set-ExakitManifestValue 'runtime.ownership' 'user'
    $r = Invoke-Lift 'running'
    Check 'user''s database: succeeds' 'True' $r
    Check 'user''s database: only the limit line is gone' (Get-ConfText $LF -Without) (Read-Conf $cf)
    Check 'user''s database: the backup is the file as it was' (Get-ConfText $LF) (Read-Conf "$cf.before-session-limit")
    Check 'user''s database: one restart, on its folder' "stop --deployment-dir $NEW|start --deployment-dir $NEW" (Get-Acted)
    Check 'user''s database: still the user''s' 'user' (Get-ExakitManifestValue 'runtime.ownership')

    # kit_database_missing: the kit's own gone, the user's in the launcher's folder.
    Reset-Home
    Seed $OLD 8796; Record $OLD
    Remove-Item -LiteralPath (Join-Path $env:USERPROFILE '.exasol\personal') -Recurse -Force
    Seed $NEW 8797; Write-Conf $NEW (Get-ConfText $LF)
    Update-PersonalDeployDir
    Check 'kit gone: the state is kit_database_missing' "kit_database_missing|$OLD|$NEW" (Get-ExakitPersonalDbState)
    $r = Invoke-Lift 'running'
    Check 'kit gone: nothing to do' 'True' $r
    Check 'kit gone: the user''s file is untouched' (Get-ConfText $LF) (Read-Conf $cf)
    Check 'kit gone: no backup beside it' 'False' (Test-Path -LiteralPath "$cf.before-session-limit")
    Check 'kit gone: no launcher call that acts or names a folder' '' ((@($script:lifeCalls | Where-Object { $_ -match '--deployment-dir|^(stop|start)\b' })) -join '|')

    # Failures. The start without the line fails: the file put back, the
    # database started again with it.
    Reset-Home
    Seed $NEW 8798; Record $NEW; Write-Conf $NEW (Get-ConfText $LF)
    $r = Invoke-Lift 'running' 1
    Check 'start fails: reported' 'False' $r
    Check 'start fails: the file is restored' (Get-ConfText $LF) (Read-Conf $cf)
    Check 'start fails: the database runs again' 'running' $script:stubState
    Check 'start fails: not recorded' '' ("" + (Get-ExakitManifestValue 'runtime.session_limit'))
    Has 'start fails: says why' 'because the database did not start without it. The file is as it was, and the database is running again.' ($script:said -join '|')
    Has 'start fails: names the remedy' 'To remove the limit later, re-run the installer:' ($script:said -join '|')
    Hasnt 'start fails: no semicolon in what it says' ';' ((@($script:said | Where-Object { $_ -match 'limit|start again' })) -join '|')
    # The stop fails: nothing changed, the database still runs.
    Reset-Home
    Seed $NEW 8799; Record $NEW; Write-Conf $NEW (Get-ConfText $LF)
    $script:stubStopRc = 1
    $r = Invoke-Lift 'running'
    $script:stubStopRc = 0
    Check 'stop fails: reported' 'False' $r
    Check 'stop fails: the file is untouched' (Get-ConfText $LF) (Read-Conf $cf)
    Check 'stop fails: the database still runs' 'running' $script:stubState
    Has 'stop fails: says why' 'because the database did not stop. Nothing was changed.' ($script:said -join '|')
    # The file cannot be changed (held open with no sharing): the database that
    # was running is started again, the file as it was.
    Reset-Home
    Seed $NEW 8800; Record $NEW; Write-Conf $NEW (Get-ConfText $LF)
    function Copy-Item { throw 'copy refused' }
    $r = Invoke-Lift 'running'
    Remove-Item Function:\Copy-Item
    Check 'edit fails: reported' 'False' $r
    Check 'edit fails: the file is as it was' (Get-ConfText $LF) (Read-Conf $cf)
    Check 'edit fails: the database runs again' 'running' $script:stubState
    Has 'edit fails: says why' 'could not be changed. The file is as it was.' ($script:said -join '|')

    Write-Host 'an update whose launcher is already current removes the limit (U1-alt):'
    # A 2.4-made deployment already driven by launcher 2.5.0 kept the limit
    # through every `exakit update`: the lift ran only after a launcher swap.
    # Invoke-ExakitUpdateSessionLimit is what both current arms of
    # Invoke-ExakitUpdateRun now call. Twin of the U1-alt checks in
    # personal-deploy-dir.sh, which run the whole update.
    $kitAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'setup/exakit.ps1'), [ref]$null, [ref]$null)
    foreach ($want in @('Invoke-ExakitUpdateSessionLimit', 'Get-ExakitRuntimeUpdatePreanswer')) {
        $def = $kitAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $want }, $true) | Select-Object -First 1
        if ($def) { Invoke-Expression $def.Extent.Text }
    }
    function Get-RuntimeType { return (Get-ExakitManifestValue 'runtime.type') }
    function Test-ExakitInteractive { return $false }
    function Invoke-UpdateLimit([string]$State, [string]$Target, [bool]$Yes) {
        $script:stubState = $State; $script:stubStartFails = 0
        $script:lifeCalls = @(); $script:kitCalls = @(); $script:said = @()
        $script:PersonalDeployFollowed = ''; $script:PersonalLauncherDecided = $false; $script:PersonalDeployRec = ''
        return (@(Invoke-ExakitUpdateSessionLimit)[-1])
    }
    function Get-UpdLiftSeeded([int]$Port) {
        Reset-Home
        Seed $NEW $Port; Record $NEW; Write-Conf $NEW (Get-ConfText $LF)
        Set-ExakitManifestValue 'runtime.version' '2.5.0'
    }
    if (Get-Command Invoke-ExakitUpdateSessionLimit -ErrorAction SilentlyContinue) {
        Get-UpdLiftSeeded 8801
        $r = Invoke-UpdateLimit 'running' 'all' $true
        Check 'current launcher, update -Yes: lifted' 'lifted' $r
        Check 'current launcher, update -Yes: the limit line is gone' 'False' (Test-PersonalSessionLimitSet $cf)
        Check 'current launcher, update -Yes: one restart, with the launcher, on the kit''s folder' "stop --deployment-dir $NEW|start --deployment-dir $NEW" (Get-Acted)
        Check 'current launcher, update -Yes: the database runs again' 'running' $script:stubState
        Check 'current launcher, update -Yes: recorded' 'lifted' (Get-ExakitManifestValue 'runtime.session_limit')
        $r = Invoke-UpdateLimit 'running' 'all' $true
        Check 'second update: nothing to do' 'lifted' $r
        Check 'second update: no launcher call at all' '' ($script:lifeCalls -join '|')
        Get-UpdLiftSeeded 8802
        $r = Invoke-UpdateLimit 'running' 'all' $false
        Check 'current launcher, no answer: lifted, nothing asked' 'lifted' $r
        Check 'current launcher, no answer: the limit line is gone' 'False' (Test-PersonalSessionLimitSet $cf)
        Check 'current launcher, no answer: one restart' "stop --deployment-dir $NEW|start --deployment-dir $NEW" (Get-Acted)
        Has 'current launcher, no answer: says the restart' 'The database restarts once.' ($script:said -join '|')
        Hasnt 'current launcher, no answer: no opt-in hint' 'routine update' ($script:said -join '|')
        Get-UpdLiftSeeded 8803
        $r = Invoke-UpdateLimit 'running' 'personal' $false
        Check 'update personal, current launcher: lifted' 'lifted' $r
        Check 'update personal, current launcher: one restart' "stop --deployment-dir $NEW|start --deployment-dir $NEW" (Get-Acted)
        Get-UpdLiftSeeded 8804
        $r = Invoke-UpdateLimit 'stopped' 'all' $false
        Check 'current launcher, stopped: lifted with no question' 'lifted' $r
        Check 'current launcher, stopped: no stop and no start' '' (Get-Acted)
        # The user's database (owner user): its limit goes the same way.
        Get-UpdLiftSeeded 8805
        Set-ExakitManifestValue 'runtime.ownership' 'user'
        $r = Invoke-UpdateLimit 'running' 'all' $true
        Check 'user''s database, update -Yes: lifted' 'lifted' $r
        Check 'user''s database, update -Yes: the limit line is gone' 'False' (Test-PersonalSessionLimitSet $cf)
        Check 'user''s database, update -Yes: one restart' "stop --deployment-dir $NEW|start --deployment-dir $NEW" (Get-Acted)
        Check 'user''s database, update -Yes: still the user''s' 'user' (Get-ExakitManifestValue 'runtime.ownership')
    } else {
        Check 'Invoke-ExakitUpdateSessionLimit exists' 'yes' 'no'
    }
    $runBody = ($kitAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-ExakitUpdateRun' }, $true) | Select-Object -First 1).Extent.Text
    Check 'Invoke-ExakitUpdateRun removes the limit in both current arms' 2 (@([regex]::Matches(("" + $runBody), '(@|\[void\])\(Invoke-ExakitUpdateSessionLimit\)')).Count)

    Write-Host 'a launcher the user replaced still lets an update remove the limit (U1-alt follow-up):'
    # A 2.4-made kit deployment whose launcher the user replaced by hand with
    # 2.5.0 at the kit's own path: its bytes no longer match the receipt, so
    # the personal row took the foreign arm (kept as it is) before the lift.
    # Invoke-ExakitUpdateForeignPersonal is what that arm now calls first.
    # Twin of the follow-up checks in personal-deploy-dir.sh.
    $def = $kitAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-ExakitUpdateForeignPersonal' }, $true) | Select-Object -First 1
    if ($def) { Invoke-Expression $def.Extent.Text }
    function Invoke-ForeignLimit([string]$State, [string]$Target, [bool]$Yes) {
        $script:stubState = $State; $script:stubStartFails = 0
        $script:lifeCalls = @(); $script:kitCalls = @(); $script:said = @()
        $script:PersonalDeployFollowed = ''; $script:PersonalLauncherDecided = $false; $script:PersonalDeployRec = ''
        $script:ExakitUpdateJson = $true
        $script:ExakitUpdateResults = New-Object System.Collections.ArrayList
        return ("" + @(Invoke-ExakitUpdateForeignPersonal -Target $Target -Installed '2.5.0' -Advertised '2.5.0' -AssumeYes $Yes)[-1])
    }
    function Get-ForeignRows { return ((@($script:ExakitUpdateResults) | ForEach-Object { "$($_.component)|$($_.outcome)|$($_.remedy)" }) -join ' ') }
    if (Get-Command Invoke-ExakitUpdateForeignPersonal -ErrorAction SilentlyContinue) {
        Get-UpdLiftSeeded 8811
        $r = Invoke-ForeignLimit 'running' 'all' $true
        Check 'foreign launcher, update -Yes: the row is written here' 'current' $r
        Check 'foreign launcher, update -Yes: the limit line is gone' 'False' (Test-PersonalSessionLimitSet $cf)
        Check 'foreign launcher, update -Yes: one restart, with the launcher, on the kit''s folder' "stop --deployment-dir $NEW|start --deployment-dir $NEW" (Get-Acted)
        Check 'foreign launcher, update -Yes: the database runs again' 'running' $script:stubState
        Check 'foreign launcher, update -Yes: recorded' 'lifted' (Get-ExakitManifestValue 'runtime.session_limit')
        Check 'foreign launcher, update -Yes: one personal row, current' 'personal|current|' (Get-ForeignRows)
        $r = Invoke-ForeignLimit 'running' 'all' $true
        Check 'foreign launcher, second update: the foreign arm writes the row as before' '' $r
        Check 'foreign launcher, second update: no launcher call at all' '' ($script:lifeCalls -join '|')
        Check 'foreign launcher, second update: no row here' '' (Get-ForeignRows)
        Get-UpdLiftSeeded 8812
        $r = Invoke-ForeignLimit 'running' 'all' $false
        Check 'foreign launcher, no answer: lifted, nothing asked' 'current' $r
        Check 'foreign launcher, no answer: the limit line is gone' 'False' (Test-PersonalSessionLimitSet $cf)
        Check 'foreign launcher, no answer: one restart' "stop --deployment-dir $NEW|start --deployment-dir $NEW" (Get-Acted)
        Check 'foreign launcher, no answer: one personal row, current' 'personal|current|' (Get-ForeignRows)
        Get-UpdLiftSeeded 8813
        $r = Invoke-ForeignLimit 'running' 'personal' $false
        Check 'update personal, foreign launcher: lifted' 'current' $r
        Check 'update personal, foreign launcher: one restart' "stop --deployment-dir $NEW|start --deployment-dir $NEW" (Get-Acted)
        Get-UpdLiftSeeded 8814
        Set-ExakitManifestValue 'runtime.ownership' 'user'
        $r = Invoke-ForeignLimit 'running' 'all' $true
        Check 'foreign launcher, user''s database: the row is written here' 'current' $r
        Check 'foreign launcher, user''s database: the limit line is gone' 'False' (Test-PersonalSessionLimitSet $cf)
        Check 'foreign launcher, user''s database: one restart' "stop --deployment-dir $NEW|start --deployment-dir $NEW" (Get-Acted)
        Check 'foreign launcher, user''s database: one personal row, current' 'personal|current|' (Get-ForeignRows)
    } else {
        Check 'Invoke-ExakitUpdateForeignPersonal exists' 'yes' 'no'
    }
    $script:ExakitUpdateJson = $false
    $foreignAt = ("" + $runBody).IndexOf('Invoke-ExakitUpdateForeignPersonal -Target')
    $foreignArm = ("" + $runBody).IndexOf('Update-ExakitForeignComponent -Id')
    Check 'Invoke-ExakitUpdateRun asks about the limit before it keeps a foreign launcher' 'True' ($foreignAt -ge 0 -and $foreignAt -lt $foreignArm)
} finally {
    foreach ($name in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnv[$name]) }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "personal-deploy-dir-ps.ps1: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
