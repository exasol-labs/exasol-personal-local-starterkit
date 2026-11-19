# Tests Windows ownership decisions on temporary fixtures; never a real deployment.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([IO.Path]::GetTempPath()) ('exakit-owners-' + [guid]::NewGuid())
$script:PASS = 0
function Check($label, $expected, $actual) {
    if ("$expected" -ne "$actual") { throw "$label expected <$expected>, got <$actual>" }
    $script:PASS++
}
# Definitions only: do not initialize modules against the real user profile.
foreach ($file in @('setup/lib/exakit-common.ps1','setup/lib/exapump.ps1','setup/lib/runtime-personal.ps1','setup/lib/pyexasol.ps1','setup/exakit.ps1')) {
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $file), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw "$file parse errors: $parseErrors" }
    foreach ($fn in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Extent.Text -match '^\s*(function|filter)\s' }, $true)) {
        Invoke-Expression $fn.Extent.Text
    }
}
$script:ExakitHome = Join-Path $work 'kit'
$script:ManifestPath = Join-Path $script:ExakitHome 'manifest.json'
# The versions cache the uv pin is read from (none here: the kit's own versions.json answers).
$script:VersionsCachePath = Join-Path $work 'versions-cache.json'
$script:BinDir = Join-Path $work 'bin'
$script:manifest = @{}
function Get-ExakitManifestValue([string]$Path) { return $script:manifest[$Path] }
function Set-ExakitManifestValue([string]$Path, $Value) { $script:manifest[$Path] = $Value }
function Remove-ExakitManifestValue([string]$Path) { $script:manifest.Remove($Path) }
function Info($m) {}; function Ok($m) {}; function Warn2($m) {}; function InfoStep($m) {}; function OkStep($m) {}
function Fail($m) { throw $m }
function Get-ExakitMarketplaceInstalledAddons { @() }
function Get-ExakitMarketplaceAddons { @() }
function Get-ExakitMarketplaceAddon($id) { $null }
function Get-ExakitServiceIds { @() }
function Get-ExakitKitSkillNames { @() }
function Get-ExakitSkillRoots { @() }
function Get-ExakitRepoRoot { $null }
function Remove-ExakitReadonlyAllowlist { 'REMOVED 0' }
function Invoke-McpOperation { $true }
function Write-ExakitLog { }
function Start-ExakitSpinner { }
function Stop-ExakitSpinner { }
function Remove-ExakitBinariesDeferred([string[]]$Paths) { foreach ($p in $Paths) { Remove-Item -Force $p } }
function Remove-Personal { Set-Content (Join-Path $work 'teardown') 'called' }
function Get-RuntimeType { Get-ExakitManifestValue 'runtime.type' }
function Remove-ExakitStepDone { }
try {
    New-Item -ItemType Directory -Force $script:ExakitHome, $script:BinDir | Out-Null
    Set-Content (Join-Path $script:ExakitHome 'manifest.json') '{}'
    $pump = Join-Path $work 'user-exapump.ps1'
    $script:PersonalBinPath = Join-Path $script:BinDir 'exasol.exe'
    function Get-ExapumpCli { $pump }
    Set-Content $pump "Write-Output 'exapump 0.14.0'; exit 0"
    Check 'untracked binary is unknown' unknown (Get-ExakitComponentOwnership exapump)
    Set-ExakitReusedOwnership exapump $pump
    Check 'reuse records user' user (Get-ExakitComponentOwnership exapump)
    Set-ExakitComponentOwnership exapump kit $pump
    Set-ExakitReusedOwnership exapump $pump
    Check 'same-path kit receipt retained' kit (Get-ExakitComponentOwnership exapump)
    Add-Content $pump '# user replacement'
    Check 'same-path replacement is protected' user (Get-ExakitComponentOwnership exapump)
    Set-ExakitReusedOwnership exapump (Join-Path $work 'different.exe')
    Check 'different path becomes user' user (Get-ExakitComponentOwnership exapump)
    Check 'launcher does not own database' unknown (Get-ExakitComponentOwnership database)
    function Get-ExapumpCli { $pump }
    function Get-ExapumpAssetName { 'fixture' }
    function Invoke-ExakitLogged { throw 'Unexpected installation' }
    $script:ExapumpVersion = '99.0.0'
    $script:ExapumpBinPath = $pump
    $hash = (Get-FileHash $pump).Hash
    Install-Exapump
    Check 'existing package is reused' user (Get-ExakitComponentOwnership exapump)
    Check 'existing executable unchanged' $hash ((Get-FileHash $pump).Hash)
    Check 'actual external version recorded' '0.14.0' (Get-ExakitManifestValue 'components.exapump.version')
    $script:VersionPolicy = 'pinned'
    $listing = & {
        function Get-ExakitVersionTableTargets { @('exapump') }
        function Invoke-ExakitWithSpinner { param($Label, [scriptblock]$Body) & $Body }
        function Get-ExakitComponentCurrent { param($Id) '0.14.0' }
        function Get-ExakitComponentAvailable { param($Id) '99.0.0' }
        function Get-ExakitComponentNote { param($Id) '' }
        function Get-ExakitComponentSeverity { param($Id) '' }
        function Test-ExakitComponentSupported { param($Id) $true }
        function Get-ExakitVersionsSource { 'fixture' }
        Invoke-CmdVersion -Json
    } | ConvertFrom-Json
    Check 'JSON lists external ownership' user $listing.components[0].ownership
    Check 'JSON lists external status' external $listing.components[0].status
    Check 'JSON does not claim kit installation' False $listing.components[0].installed_by_kit
    Check 'external component has no update remedy' '' $listing.components[0].remedy
    Check 'external update is not counted' 0 $listing.pending
    # An add-on at the advertised version whose launcher an earlier kit wrote:
    # the row says a refresh is waiting, not the version it already has, and it
    # still counts as pending. Twin of the json-tables check in tests/marketplace.sh.
    $refresh = & {
        function Get-ExakitVersionTableTargets { @('json-tables') }
        function Invoke-ExakitWithSpinner { param($Label, [scriptblock]$Body) & $Body }
        function Get-ExakitComponentCurrent { param($Id) 'v0.4.1' }
        function Get-ExakitComponentAvailable { param($Id) 'v0.4.1' }
        function Get-ExakitComponentNote { param($Id) '' }
        function Get-ExakitComponentSeverity { param($Id) '' }
        function Test-ExakitComponentSupported { param($Id) $true }
        function Test-ExakitComponentManaged { param($Id) $true }
        function Test-ExakitAddonNeedsUpdate { param($Id) $true }
        function Get-ExakitVersionsSource { 'fixture' }
        Invoke-CmdVersion -Json
    } | ConvertFrom-Json
    Check 'a stale add-on at its version: update_available in JSON' update_available $refresh.components[0].status
    Check '...with its remedy' 'exakit update json-tables' $refresh.components[0].remedy
    Check '...and counted as pending' 1 $refresh.pending
    $refreshScreen = & {
        function Get-ExakitVersionTableTargets { @('json-tables') }
        function Invoke-ExakitWithSpinner { param($Label, [scriptblock]$Body) & $Body }
        function Get-ExakitComponentCurrent { param($Id) 'v0.4.1' }
        function Get-ExakitComponentAvailable { param($Id) 'v0.4.1' }
        function Get-ExakitComponentNote { param($Id) '' }
        function Get-ExakitComponentSeverity { param($Id) '' }
        function Test-ExakitComponentSupported { param($Id) $true }
        function Test-ExakitComponentManaged { param($Id) $true }
        function Test-ExakitAddonNeedsUpdate { param($Id) $true }
        function Get-ExakitVersionsSource { 'fixture' }
        Invoke-CmdVersion 6>&1 | Out-String
    }
    Check 'the screen row says refresh available' True ($refreshScreen -match 'json-tables +0\.4\.1 +\S+ +refresh available')
    Check '...and not the version it already has' False ($refreshScreen -match '0\.4\.1 available')
    Set-Content $pump 'exit 1'
    $refused = $false
    try { Install-Exapump } catch { $refused = $true }
    Check 'broken external executable refused' True $refused
    Check 'broken executable preserved' True (Test-Path $pump)

    foreach ($name in @('exasol.exe','exapump.exe','exakit.cmd')) { Set-Content (Join-Path $script:BinDir $name) 'fixture' }
    $kept = Join-Path $script:ExakitHome 'user-env'
    New-Item -ItemType Directory $kept | Out-Null
    Set-Content (Join-Path $kept 'user-data') 'keep'
    New-Item -ItemType Directory (Join-Path $script:ExakitHome 'exapump') | Out-Null
    Set-Content (Join-Path $script:ExakitHome 'exapump/config.toml') 'kit'
    Set-ExakitManifestValue 'runtime.type' personal
    Set-ExakitComponentOwnership database user (Join-Path $work 'database')
    Set-ExakitComponentOwnership personal user (Join-Path $script:BinDir 'exasol.exe')
    Set-ExakitComponentOwnership pyexasol user $kept
    Invoke-ExakitUninstallComponent database
    Check 'selective uninstall preserves database' False (Test-Path (Join-Path $work 'teardown'))
    Invoke-ExakitUninstallRun -DryRun
    Check 'dry run preserves manifest' True (Test-Path (Join-Path $script:ExakitHome 'manifest.json'))
    Invoke-ExakitUninstallRun
    Check 'full uninstall preserves database' False (Test-Path (Join-Path $work 'teardown'))
    Check 'user launcher retained' True (Test-Path (Join-Path $script:BinDir 'exasol.exe'))
    Check 'user exapump retained' True (Test-Path (Join-Path $script:BinDir 'exapump.exe'))
    Check 'user files inside kit retained' True (Test-Path (Join-Path $kept 'user-data'))
    Check 'kit profile removed' False (Test-Path (Join-Path $script:ExakitHome 'exapump/config.toml'))
    Check 'kit entrypoint removed' False (Test-Path (Join-Path $script:BinDir 'exakit.cmd'))

    # Untracked shared installs are preserved as conservatively as user receipts.
    Set-Content (Join-Path $script:ExakitHome 'manifest.json') '{}'
    $script:manifest = @{'runtime.type' = 'personal'}
    Invoke-ExakitUninstallRun
    Check 'unknown database retained' False (Test-Path (Join-Path $work 'teardown'))
    Check 'unknown launcher retained' True (Test-Path (Join-Path $script:BinDir 'exasol.exe'))
    New-Item -ItemType Directory -Force $script:ExakitHome | Out-Null
    Set-Content (Join-Path $script:ExakitHome 'manifest.json') '{}'
    Set-ExakitComponentOwnership database kit
    Set-ExakitComponentOwnership personal kit
    Set-ExakitComponentOwnership exapump kit $pump
    Invoke-ExakitUninstallRun
    Check 'owned database teardown called' True (Test-Path (Join-Path $work 'teardown'))
    Check 'owned launcher removed' False (Test-Path (Join-Path $script:BinDir 'exasol.exe'))
    Check 'owned custom exapump removed' False (Test-Path $pump)
    Check 'same-named user binary at default path kept' True (Test-Path (Join-Path $script:BinDir 'exapump.exe'))
    # AN INSTALL FROM BEFORE RECEIPTS (every kit up to 0.2.4, audit LCY-01):
    # no ownership key, only what the old kit recorded. Twin of the same
    # block in component-ownership.sh.
    New-Item -ItemType Directory -Force -Path $script:BinDir, (Join-Path $work 'legacy-deployment') | Out-Null
    Set-Content -LiteralPath (Join-Path $script:BinDir 'exasol.exe') -Value 'x'
    Set-Content -LiteralPath (Join-Path $script:BinDir 'exapump.exe') -Value 'x'
    $script:manifest = @{
        'runtime.type' = 'personal'; 'runtime.launcher' = (Join-Path $script:BinDir 'exasol.exe')
        'runtime.deployment_dir' = (Join-Path $work 'legacy-deployment')
        'components.exapump.path' = (Join-Path $script:BinDir 'exapump.exe'); 'components.mcp_server.version' = '1.9.0'
    }
    $script:PersonalDeployDir = Join-Path $work 'legacy-deployment'
    Remove-Item Env:EXAKIT_EXAPUMP_BIN -ErrorAction SilentlyContinue
    Check 'pre-receipt: the kit launcher is the kit''s' kit (Get-ExakitComponentOwnership personal)
    Check 'pre-receipt: the database its launcher deployed is the kit''s' kit (Get-ExakitComponentOwnership database)
    Check 'pre-receipt: the kit exapump is the kit''s' kit (Get-ExakitComponentOwnership exapump)
    Check 'pre-receipt: the MCP server it recorded is the kit''s' kit (Get-ExakitComponentOwnership mcp)
    Set-ExakitReusedOwnership personal (Join-Path $script:BinDir 'exasol.exe')
    Check 'pre-receipt: an installer re-run writes the kit receipt, never user' kit $script:manifest['components.personal.ownership']
    $script:manifest = @{ 'runtime.type' = 'personal'; 'runtime.launcher' = (Join-Path $work 'their-own\exasol.exe'); 'runtime.deployment_dir' = (Join-Path $work 'legacy-deployment') }
    Check 'pre-receipt: a launcher outside the kit bin stays unknown' unknown (Get-ExakitComponentOwnership personal)
    Check '...and so does the database it deployed' unknown (Get-ExakitComponentOwnership database)

    # THE KIT'S OWN uv (audit UPG-06): kits 0.2.3 to 0.2.5 recorded path,
    # version and managed for the uv they installed, and no receipt. That
    # record plus the exact bytes of the pinned release's uv is the kit's;
    # other bytes at the same path, a uv elsewhere, or no "managed" is not.
    # Twin of the same block in component-ownership.sh.
    New-Item -ItemType Directory -Force -Path $script:ExakitHome, $script:BinDir | Out-Null
    Set-Content -LiteralPath $script:ManifestPath -Value '{}'
    $kitUv = Get-ExakitUvKitBin
    $release = Join-Path $work 'uv-0.13.7-release'
    Set-Content -LiteralPath $release -Value 'uv 0.13.7 fixture release bytes'
    $releaseKey = 'uv-0.13.7-' + (Get-ExakitUvPlatform).Key
    $realTable = ${function:Get-ExakitUvBinarySha256}
    function Get-ExakitUvBinarySha256 { param([string]$Key) if ($Key -eq $releaseKey) { return (Get-FileHash -LiteralPath $release -Algorithm SHA256).Hash.ToLowerInvariant() }; return (& $realTable -Key $Key) }
    Copy-Item -Force $release $kitUv
    $uvRecord = @{ 'components.uv.path' = $kitUv; 'components.uv.version' = '0.13.7'; 'components.uv.managed' = $true }
    $script:manifest = $uvRecord.Clone()
    Check 'uv a 0.2.5 kit installed (pinned bytes, managed) is the kit''s' kit (Get-ExakitComponentOwnership uv)
    $script:manifest = $uvRecord.Clone(); $script:manifest['components.uv.version'] = '0.13.6'
    Check 'a recorded version whose release bytes differ is not the kit''s' unknown (Get-ExakitComponentOwnership uv)
    $script:manifest = $uvRecord.Clone(); $script:manifest['components.uv.managed'] = $false
    Check 'a record that does not say managed is not the kit''s' unknown (Get-ExakitComponentOwnership uv)
    $script:manifest = $uvRecord.Clone(); $script:manifest['components.uv.path'] = (Join-Path $work 'scoop\uv.exe')
    Check 'a uv recorded outside the kit bin folder stays the user''s' unknown (Get-ExakitComponentOwnership uv)
    $script:manifest = $uvRecord.Clone()
    Add-Content -LiteralPath $kitUv -Value 'the user''s own uv build'
    Check 'a uv with other bytes at the kit path stays the user''s' unknown (Get-ExakitComponentOwnership uv)
    # A uv the kit installs now carries a receipt, and a later user
    # replacement voids it.
    $script:manifest = @{}
    $ownInstalled = & {
        function Get-ExakitUvReport { @{ Verdict = 'none'; Path = ''; Version = ''; Min = '0.13.4' } }
        function Get-ExakitComponentAvailable { param($Id) '0.13.8' }
        function Get-ExakitUvVersionOf { param($Path) '0.13.8' }
        function Install-ExakitUvPinned { Set-Content -LiteralPath $kitUv -Value 'uv 0.13.8 fixture install'; return $kitUv }
        Update-ExakitUv
        Get-ExakitManifestValue 'components.uv.ownership'
    }
    Check 'a uv the kit installs gets the kit receipt' kit $ownInstalled
    Check '...so it is the kit''s' kit (Get-ExakitComponentOwnership uv)
    Add-Content -LiteralPath $kitUv -Value 'uv self update by the user'
    Check 'the user replacing the kit''s uv makes it theirs' user (Get-ExakitComponentOwnership uv)
    $script:manifest = @{}; $script:UvKitInstalled = $false; $script:UvBin = $kitUv
    Set-ExakitUvManifest
    Check 'a uv the kit found at its path gets no kit receipt' '' ("" + (Get-ExakitManifestValue 'components.uv.ownership'))
    Set-Item -Path function:Get-ExakitUvBinarySha256 -Value $realTable
    Check 'release table: uv 0.13.7 Windows' 1791d7a9ed5b6df13ccf80f102e025c333010d96326b4ff0262aa3b578835c5a (Get-ExakitUvBinarySha256 uv-0.13.7-windows-x86_64)
    Check 'release table: an unpinned release has no entry' '' (Get-ExakitUvBinarySha256 uv-0.13.5-windows-x86_64)
    Remove-Item -Force -LiteralPath $kitUv -ErrorAction SilentlyContinue
    $script:UvBin = $null; $script:UvVetted = $null

    # THE SCHEDULER AND THE VS CODE EXTENSION KIT 0.2.5 INSTALLED (audit
    # STA-01): no ownership key, and none of venv/home/python/path. Twin of the
    # same block in component-ownership.sh.
    $engine = Join-Path $script:ExakitHome 'exasol-scheduler\libexec\exasol_scheduler.exe'
    $sched = @{ 'components.exasol_scheduler.version' = '0.4.1'; 'components.exasol_scheduler.engine' = $engine
        'components.exasol_scheduler.db_user' = 'scheduler_svc'; 'components.exasol_scheduler.schema' = 'SCHED' }
    $vsc = @{ 'components.exasol_vscode.version' = '1.9.1'; 'components.exasol_vscode.extension_id' = 'exasol.exasol-vscode'
        'components.exasol_vscode.code_cli' = 'C:\Program Files\Microsoft VS Code\bin\code.cmd' }
    $script:manifest = $sched.Clone(); foreach ($k in $vsc.Keys) { $script:manifest[$k] = $vsc[$k] }
    Check '0.2.5 Scheduler receipt (engine under the kit home) is the kit''s' kit (Get-ExakitComponentOwnership exasol-scheduler)
    Check '0.2.5 VS Code extension receipt (its exact shape) is the kit''s' kit (Get-ExakitComponentOwnership exasol-vscode)
    foreach ($owner in @('user','unknown')) {
        $script:manifest['components.exasol_scheduler.ownership'] = $owner
        $script:manifest['components.exasol_vscode.ownership'] = $owner
        Check "a Scheduler receipt saying ownership $owner is never adopted" $owner (Get-ExakitComponentOwnership exasol-scheduler)
        Check "a VS Code receipt saying ownership $owner is never adopted" $owner (Get-ExakitComponentOwnership exasol-vscode)
    }
    $script:manifest = $sched.Clone()
    $script:manifest['components.exasol_scheduler.engine'] = ($script:ExakitHome + '-other\exasol-scheduler\libexec\exasol_scheduler.exe')
    Check 'an engine in a sibling folder whose name starts with the kit home is not the kit''s' unknown (Get-ExakitComponentOwnership exasol-scheduler)
    $script:manifest = $vsc.Clone(); $script:manifest.Remove('components.exasol_vscode.code_cli')
    Check 'a VS Code receipt without code_cli is not the 0.2.5 shape' unknown (Get-ExakitComponentOwnership exasol-vscode)

    # A KEPT ADD-ON NEVER ANSWERS "removed": exit 1 and "Nothing was
    # removed"; the preview exits 0. Run in a child, because the command exits.
    $child = Join-Path $work 'kept-addon.ps1'
    $repoQ = $repo -replace "'", "''"; $workQ = $work -replace "'", "''"
    Set-Content -LiteralPath $child -Value @"
param([switch]`$DryRun)
`$ErrorActionPreference = 'Stop'
foreach (`$file in @('setup/lib/exakit-common.ps1','setup/exakit.ps1')) {
    `$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path '$repoQ' `$file), [ref]`$null, [ref]`$null)
    foreach (`$fn in `$ast.FindAll({ param(`$n) `$n -is [Management.Automation.Language.FunctionDefinitionAst] -and `$n.Extent.Text -match '^\s*(function|filter)\s' }, `$true)) { Invoke-Expression `$fn.Extent.Text }
}
`$script:ExakitHome = Join-Path '$workQ' 'kept-kit'
`$script:BinDir = Join-Path '$workQ' 'kept-bin'
`$script:ManifestPath = Join-Path `$script:ExakitHome 'manifest.json'
New-Item -ItemType Directory -Force `$script:ExakitHome, `$script:BinDir | Out-Null
Set-Content -LiteralPath `$script:ManifestPath '{}'
`$script:manifest = @{ 'components.exasol_scheduler.version' = '0.4.1'; 'components.exasol_scheduler.ownership' = 'user'
    'components.exasol_scheduler.engine' = (Join-Path `$script:ExakitHome 'exasol-scheduler\libexec\exasol_scheduler.exe') }
function Get-ExakitManifestValue([string]`$Path) { return `$script:manifest[`$Path] }
function Get-ExakitMarketplaceAddons { @([pscustomobject]@{ Id = 'exasol-scheduler' }) }
function Get-ExakitMarketplaceAddon(`$id) { if (`$id -eq 'exasol-scheduler') { [pscustomobject]@{ Id = 'exasol-scheduler' } } }
function Test-ExakitMarketplaceAddonInstalled(`$Id) { `$true }
function Invoke-ExakitUninstallComponent { param([string]`$Key) Write-Output 'COMPONENT-REMOVAL-RAN' }
function Initialize-ExakitLogging { }
function Show-ExakitHomeNotice { }
function Info(`$m) { Write-Output "INFO `$m" }
function Ok(`$m) { Write-Output "OK `$m" }
function Warn2(`$m) { Write-Output "WARN `$m" }
Invoke-CmdUninstall -Addon 'exasol-scheduler' -AssumeYes:(-not `$DryRun) -DryRun:`$DryRun
exit 0
"@
    $hostExe = (Get-Process -Id $PID).Path
    # Windows PowerShell 5.1 turns a child's stderr line into a terminating error under Stop.
    $ErrorActionPreference = "Continue"
    $out = (& $hostExe -NoProfile -ExecutionPolicy Bypass -File $child 2>&1 | Out-String)
    $keptRc = $LASTEXITCODE
    $dryOut = (& $hostExe -NoProfile -ExecutionPolicy Bypass -File $child -DryRun 2>&1 | Out-String)
    $dryRc = $LASTEXITCODE
    $ErrorActionPreference = "Stop"
    Check 'kept add-on: uninstall -Yes exits 1' 1 $keptRc
    Check '...and says nothing was removed' True ($out.Contains('Nothing was removed'))
    Check '...and never claims removed' False ($out.Contains('exasol-scheduler removed'))
    Check '...and never runs the removal' False ($out.Contains('COMPONENT-REMOVAL-RAN'))
    Check 'kept add-on: the preview exits 0' 0 $dryRc
    Check '...and says nothing would be removed' True ($dryOut.Contains('Nothing would be removed'))
    Write-Host "$script:PASS PowerShell ownership checks passed"
} finally { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
