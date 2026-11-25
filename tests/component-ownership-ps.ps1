# Tests Windows ownership decisions on temporary fixtures; never a real deployment.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([IO.Path]::GetTempPath()) ('exakit-owners-' + [guid]::NewGuid())
# W4-01: THE MACHINE'S OWN FOLDERS ARE NEVER IN REACH. The uninstall runs below
# remove the kit's Startup entries, and with the real APPDATA they deleted the
# real com.exasol.exakit.*.cmd files of the kit installed on the test machine.
# tests/autostart-sandbox-guard.sh keeps every suite to this.
$env:EXAKIT_STARTUP_DIR = Join-Path $work 'Startup'
$env:APPDATA = Join-Path $work 'AppData\Roaming'
$env:LOCALAPPDATA = Join-Path $work 'AppData\Local'
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
    # Installed ahead of the manifest (#46): the screen says ahead, the twin of current, not a bare "none" that read as a
    # missing value; the JSON keeps its "ahead" token. Twin of the ahead row in versions-manifest.sh.
    $aheadRun = {
        param([switch]$Json)
        function Get-ExakitVersionTableTargets { @('exapump') }
        function Invoke-ExakitWithSpinner { param($Label, [scriptblock]$Body) & $Body }
        function Get-ExakitComponentCurrent { param($Id) '0.15.0' }
        function Get-ExakitComponentAvailable { param($Id) '0.14.0' }
        function Get-ExakitComponentNote { param($Id) '' }
        function Get-ExakitComponentSeverity { param($Id) '' }
        function Test-ExakitComponentSupported { param($Id) $true }
        function Test-ExakitComponentManaged { param($Id) $true }
        function Get-ExakitVersionsSource { 'fixture' }
        if ($Json) { Invoke-CmdVersion -Json } else { Invoke-CmdVersion 6>&1 | Out-String }
    }
    $aheadScreen = & $aheadRun
    Check 'an install ahead of the manifest says ahead' True ($aheadScreen -match 'exapump +0\.15\.0 +\S+ +ahead\b')
    Check '...and never a bare none' False ($aheadScreen -match 'exapump +0\.15\.0 +\S+ +none\s*(\||$)')
    Check '...while the JSON keeps ahead' ahead ((& $aheadRun -Json | ConvertFrom-Json).components[0].status)
    Set-Content $pump 'exit 1'
    $refused = $false
    try { Install-Exapump } catch { $refused = $true }
    Check 'broken external executable refused' True $refused
    Check 'broken executable preserved' True (Test-Path $pump)

    # AN UPGRADED INSTALL (#40). A 0.2.x kit recorded only components.exapump.path (its own exapump.exe, no
    # receipt), and the user's own exapump.exe is first on PATH, so Get-ExapumpCli answers that one. The re-run
    # never writes a kit receipt on the user's copy, so neither a repair nor the uninstall can delete it.
    $savedManifest = $script:manifest.Clone(); $savedBinPath = $script:ExapumpBinPath
    $script:manifest = @{}
    $legacyKitPump = Join-Path $script:BinDir 'exapump.exe'
    $userFirstPump = Join-Path $work 'user-first-on-path-exapump.ps1'
    Set-Content $legacyKitPump 'the kit exapump a 0.2.x kit installed'
    Set-Content $userFirstPump 'exit 1'
    $script:ExapumpBinPath = $legacyKitPump
    Set-ExakitManifestValue 'components.exapump.path' $legacyKitPump
    function Get-ExapumpCli { $legacyKitPump }
    Check 'pre-receipt: the exapump a 0.2.x kit recorded is the kit''s' kit (Get-ExakitComponentOwnership exapump)
    function Get-ExapumpCli { $userFirstPump }
    Set-ExakitReusedOwnership exapump $userFirstPump
    Check 'pre-receipt: the user''s exapump first on PATH gets no kit receipt' user (Get-ExakitManifestValue 'components.exapump.ownership')
    $refused = $false
    try { Install-Exapump } catch { $refused = $true }
    Check '...a re-run with it broken refuses' True $refused
    Check '...and never deletes it' True (Test-Path $userFirstPump)
    $script:manifest = @{}
    Set-ExakitManifestValue 'components.exapump.path' $legacyKitPump
    function Get-ExapumpCli { $legacyKitPump }
    Set-ExakitReusedOwnership exapump $legacyKitPump
    Check 'pre-receipt: the kit''s own recorded path still gets the kit receipt' kit (Get-ExakitManifestValue 'components.exapump.ownership')
    Remove-Item -Force $legacyKitPump, $userFirstPump
    $script:manifest = $savedManifest; $script:ExapumpBinPath = $savedBinPath
    function Get-ExapumpCli { $pump }

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
    # The advertised uv is in the table for every platform: a full uninstall keeps uv but removes its
    # receipt, and the next install can tell the kit's own uv from the user's only by this table.
    $uvAdvertised = "" + ((Get-Content -Raw -LiteralPath (Join-Path $repo "versions.json") | ConvertFrom-Json).components.uv.version)
    $uvMissing = @(@("linux-aarch64", "linux-x86_64", "macos-aarch64", "macos-x86_64", "windows-x86_64") |
        Where-Object { -not (Get-ExakitUvBinarySha256 "uv-$uvAdvertised-$_") }) -join " "
    Check "release table: the advertised uv $uvAdvertised is listed for every platform" '' $uvMissing
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

    # A LAUNCHER AT THE KIT'S OWN PATH THAT IS NOT ON PATH (#41). Get-Command exasol missed a launcher the user put
    # in the kit's bin folder before that folder was on PATH: the install moved its own over it and gave it a kit
    # receipt. Next to a launcher of the user's whose version cannot be read, a new install now runs the kit's own
    # 2.5 as a separate program in the kit's home (mode S, Krishna Q2): the user's file is never written, and no
    # receipt names it. Twin of the off-PATH checks in component-ownership.sh (the fixture's bin folder is never
    # on PATH).
    $script:manifest = @{}
    $marker = Join-Path $work 'would-download'
    $theirsAtKitPath = $script:PersonalBinPath
    Set-Content $theirsAtKitPath 'the user own exasol.exe, not runnable here'
    $launcherHash = (Get-FileHash $theirsAtKitPath).Hash
    $script:refusedLauncher = ""
    & {
        function Get-PersonalTargetVersion { '9.9.9' }
        function Get-PersonalS3Source { $null }
        function Get-ExakitFile { Set-Content $marker 'reached'; throw 'download (fixture)' }
        try { Install-PersonalLauncher } catch { $script:refusedLauncher = "$_" }
    }
    Check 'off-PATH user launcher, version unread: the kit installs its own separate program (mode S)' "True|$(Get-PersonalSeparateBinPath)" ("{0}|{1}" -f (Test-Path $marker), $script:PersonalBinPath)
    Check '...the user launcher is untouched' $launcherHash ((Get-FileHash $theirsAtKitPath).Hash)
    Check '...and no receipt names it' '' ("" + (Get-ExakitManifestValue 'components.personal.ownership'))
    $script:PersonalSeparate = $false; $script:PersonalBinSynced = $false; $script:PersonalBinPath = $theirsAtKitPath
    $script:PersonalLauncherPlan = $null

    # THE KIT'S OWN LAUNCHER, BEHIND THE PIN (MAC-01). Re-running the installer over a 0.3.0 kit kept launcher
    # 2.4.0. The step now updates it as `exakit update` does (a running database only for an answer), replaces
    # it like a first install when no deployment is recorded, and leaves a user's launcher and a current one
    # alone. The launcher is a text file holding its version; Invoke-ExakitBounded answers for it. The download
    # is the S3 path with its real checksum check. Twin of the MAC-01 checks in component-ownership.sh.
    $newLauncher = Join-Path $work 'new-exasol.exe'
    Set-Content $newLauncher '2.5.0'
    $newHash = (Get-FileHash $newLauncher).Hash
    $kitDb = Join-Path $work 'kitdb'
    # <Owner>: kit, user (a launcher of the user's at the kit's path), or userdb
    # (theirs too, over a database the user let the 0.3.0 kit use).
    # <DbState>: what Get-ExakitPersonalDbState answers ("" = the kit's own database is there).
    function Invoke-BehindRun([string]$Version, [string]$Owner, [bool]$Deployment, [string]$DbStatus, [string]$Confirm = "", [string]$CoreRerun = "", [string]$DbState = "", [string]$Leftover = "") {
        $script:manifest = @{}
        foreach ($m in @('downloaded', 'lifted')) { Remove-Item -Force (Join-Path $work $m) -ErrorAction SilentlyContinue }
        Remove-Item -Recurse -Force $kitDb -ErrorAction SilentlyContinue
        # A 0.3.0 kit, in a fresh process: its launcher at .local\bin, nothing
        # in the kit's folder yet (or <Leftover>, a file there with no record).
        $sepBin = Get-PersonalSeparateBinPath
        Remove-Item -Force -LiteralPath $sepBin -ErrorAction SilentlyContinue
        $script:PersonalSeparate = $false; $script:PersonalBinSynced = $false; $script:PersonalLauncherPlan = $null
        $script:PersonalBinPath = $theirsAtKitPath
        if ($Leftover) {
            New-Item -ItemType Directory -Force (Split-Path -Parent $sepBin) | Out-Null
            Set-Content $sepBin $Leftover
        }
        Set-Content $script:PersonalBinPath $Version
        Set-ExakitComponentOwnership "personal" "kit" $script:PersonalBinPath
        # A user's launcher at the kit's path: the receipt's digest is not its own.
        if ($Owner -eq 'user' -or $Owner -eq 'userdb') { Add-Content $script:PersonalBinPath 'the user replaced it' }
        # A kit from before receipts: only the path it recorded for the launcher.
        if ($Owner -eq 'legacy') { $script:manifest = @{ 'runtime.launcher' = $script:PersonalBinPath } }
        if ($Deployment) {
            New-Item -ItemType Directory -Force $kitDb | Out-Null
            Set-ExakitManifestValue 'runtime.type' 'personal'
            Set-ExakitManifestValue 'runtime.version' $Version
            if ($Owner -eq 'userdb') { Set-ExakitComponentOwnership "database" "user" $kitDb }
        }
        $before = (Get-FileHash $script:PersonalBinPath).Hash
        $script:behindSaid = @()
        # The database's state, which a stop and a start change: the update
        # stops a running database before the launcher swap and starts it once
        # after it.
        $script:behindStatus = $DbStatus
        $script:behindRestarts = @()
        $script:behindDbState = $DbState
        $env:EXAKIT_CONFIRM_RUNTIME_UPDATE = $Confirm
        $env:EXAKIT_CORE_RERUN = $CoreRerun
        $script:behindRc = 0
        & {
            function Get-PersonalTargetVersion { '2.5.0' }
            function Invoke-ExakitBounded { param($FilePath, $Arguments, $TimeoutSeconds)
                if ($Arguments[0] -eq 'version') { return ([IO.File]::ReadAllLines($FilePath)[0]).Trim() }
                return "Commands:`n  local  Install locally"
            }
            function Test-ExakitCoreRerunActive { $env:EXAKIT_CORE_RERUN -eq '1' }
            function Get-ExakitPersonalDbState { $script:behindDbState }
            function Test-ExakitKitDatabaseGuard { -not $script:behindDbState }
            function Update-PersonalDeployDir { $script:PersonalDeployDir = $kitDb }
            function Get-PersonalStatus { $script:behindStatus }
            function Stop-Personal { $script:behindStatus = 'stopped'; $script:behindRestarts += 'stop' }
            function Start-Personal { $script:behindStatus = 'running'; $script:behindRestarts += 'start' }
            function Wait-PersonalReadyOrDeploy { $true }
            function Get-PersonalS3Source { @{ Url = 'https://fixture.invalid/exasol.exe'; Sha256 = $newHash } }
            function Get-ExakitFile { param($Url, $Dest, [switch]$Soft) Set-Content (Join-Path $work 'downloaded') 'yes'; Copy-Item $newLauncher $Dest; return $true }
            function Set-PersonalManifest { Set-ExakitManifestValue 'runtime.version' (Get-PersonalLauncherVersion) }
            function Get-ExakitCredential([string]$Name) { 'fixture' }
            function Update-PersonalChangedPassword { 'same' }
            function Test-PersonalSecretsReadable { $true }
            function Test-PersonalUpdateCrossesTo24 { $false }
            function Remove-PersonalSessionLimit { Set-Content (Join-Path $work 'lifted') 'yes'; $true }
            function Test-ExakitInteractive { $false }
            function Get-ExakitTilde([string]$Path) { $Path }
            function Warn2($m) { $script:behindSaid += $m }
            function Info($m) { $script:behindSaid += $m }
            try { Install-PersonalLauncher } catch { $script:behindRc = 1; $script:behindSaid += "$_" }
        }
        Remove-Item Env:EXAKIT_CONFIRM_RUNTIME_UPDATE, Env:EXAKIT_CORE_RERUN -ErrorAction SilentlyContinue
        # <same>: the file at .local\bin as it was, changed, or gone; <version>
        # and <kit>: what the kit runs, and what is in the kit's folder.
        $same = 'gone'
        if (Test-Path -LiteralPath $theirsAtKitPath) { $same = 'no'; if ($before -eq (Get-FileHash $theirsAtKitPath).Hash) { $same = 'yes' } }
        $kit = 'none'; if (Test-Path -LiteralPath $sepBin) { $kit = ([IO.File]::ReadAllLines($sepBin)[0]).Trim() }
        $runs = 'none'; if (Test-Path -LiteralPath (Get-PersonalCli)) { $runs = ([IO.File]::ReadAllLines((Get-PersonalCli))[0]).Trim() }
        $dl = 'no'; if (Test-Path (Join-Path $work 'downloaded')) { $dl = 'yes' }
        $lift = 'no'; if (Test-Path (Join-Path $work 'lifted')) { $lift = 'yes' }
        return "rc=$($script:behindRc) download=$dl version=$runs same=$same kit=$kit owner=$(Get-ExakitManifestValue 'components.personal.ownership') lifted=$lift"
    }
    Check 'kit launcher 2.4.0, kit deployment stopped: updated to 2.5.0 as exakit update does' `
        'rc=0 download=yes version=2.5.0 same=gone kit=2.5.0 owner=kit lifted=yes' (Invoke-BehindRun '2.4.0' kit $true stopped)
    Check '...the record says 2.5.0' '2.5.0' (Get-ExakitManifestValue 'runtime.version')
    Check '...and the kit receipt names the new launcher' $newHash (Get-ExakitManifestValue 'components.personal.ownership_sha256')
    Check 'kit launcher 2.4.0, database running, no console and no answer: updated, nothing asked' `
        'rc=0 download=yes version=2.5.0 same=gone kit=2.5.0 owner=kit lifted=yes' (Invoke-BehindRun '2.4.0' kit $true running)
    Check '...and it says the database stops first' True ([bool]($script:behindSaid -match 'needs the database stopped'))
    Check '...and it never defers' False ([bool]($script:behindSaid -match 'not part of a routine update'))
    Check '...stopped before the swap and started once after it' 'stop start|running' "$($script:behindRestarts -join ' ')|$($script:behindStatus)"
    Check '...said once' 1 (@($script:behindSaid -match 'needs the database stopped').Count)
    Check 'kit launcher 2.4.0, database running, EXAKIT_CONFIRM_RUNTIME_UPDATE=1: updated' `
        'rc=0 download=yes version=2.5.0 same=gone kit=2.5.0 owner=kit lifted=yes' (Invoke-BehindRun '2.4.0' kit $true running '1')
    Check 'kit launcher 2.4.0, database running, EXAKIT_CONFIRM_RUNTIME_UPDATE=0: left alone' `
        'rc=0 download=no version=2.4.0 same=yes kit=none owner=kit lifted=no' (Invoke-BehindRun '2.4.0' kit $true running '0')
    Check '...not stopped' 'running|' "$($script:behindStatus)|$($script:behindRestarts -join ' ')"
    Check 'kit launcher 2.4.0, no deployment recorded: replaced like a first install' `
        'rc=0 download=yes version=2.5.0 same=gone kit=2.5.0 owner=kit lifted=no' (Invoke-BehindRun '2.4.0' kit $false stopped)
    Check 'user launcher 2.4.0 at the kit path: untouched, recorded as the user''s' `
        'rc=0 download=no version=2.4.0 same=yes kit=none owner=user lifted=no' (Invoke-BehindRun '2.4.0' user $true stopped)
    # A DATABASE THE USER LET THE 0.3.0 KIT USE (runtime.ownership user), run by their own 2.4.0: that permission
    # never covers their launcher (#41): it is as it was, and the kit's own runs the database from the kit's
    # folder, as `exakit update` does it (Update-PersonalUser); the limit of their database goes with it. Twin of the userdb checks in
    # component-ownership.sh.
    Check 'user launcher 2.4.0 over a database they let the kit use: updated, their launcher as it was' `
        'rc=0 download=yes version=2.5.0 same=yes kit=2.5.0 owner=kit lifted=yes' (Invoke-BehindRun '2.4.0' userdb $true stopped)
    Check '...no kit receipt on it: the receipt is the kit''s own copy, theirs recorded as theirs' "$(Get-PersonalSeparateBinPath)|$theirsAtKitPath" ("{0}|{1}" -f (Get-ExakitManifestValue 'components.personal.ownership_path'), (Get-ExakitManifestValue 'components.personal.user_launcher'))
    Check '...running: stopped before, started once after' 'rc=0 download=yes version=2.5.0 same=yes kit=2.5.0 owner=kit lifted=yes|stop start|running' `
        "$(Invoke-BehindRun '2.4.0' userdb $true running)|$($script:behindRestarts -join ' ')|$($script:behindStatus)"
    Check '...an installer that exakit update started leaves it to the update' `
        'rc=0 download=no version=2.4.0 same=yes kit=none owner=user lifted=no' (Invoke-BehindRun '2.4.0' userdb $true stopped '' '1')
    # Their launcher at the pin: never the one the kit runs. The kit's own goes
    # into its folder, and theirs stays (WPS-04).
    Check '...at the pin: theirs as it was, the kit runs its own copy' `
        'rc=0 download=yes version=2.5.0 same=yes kit=2.5.0 owner=kit lifted=no' (Invoke-BehindRun '2.5.0' userdb $true stopped)
    Check '...theirs recorded as theirs, the database still theirs' "$theirsAtKitPath|user" ("{0}|{1}" -f (Get-ExakitManifestValue 'components.personal.user_launcher'), (Get-ExakitManifestValue 'runtime.ownership'))
    Check '...a release ahead on another line: reused as before, nothing of the kit''s put there' `
        'rc=0 download=no version=2.6.0 same=yes kit=none owner=user lifted=no' (Invoke-BehindRun '2.6.0' userdb $true stopped)
    Check 'kit launcher at the pin: reused, no download' `
        'rc=0 download=no version=2.5.0 same=yes kit=none owner=kit lifted=no' (Invoke-BehindRun '2.5.0' kit $true stopped)
    Check 'kit launcher ahead of the pin: reused, never downgraded' `
        'rc=0 download=no version=2.6.0 same=yes kit=none owner=kit lifted=no' (Invoke-BehindRun '2.6.0' kit $true stopped)
    # THE KIT'S OWN DATABASE MISSING (a 0.3.0 kit whose `default` a hand-installed 2.5 moved, or another
    # deployment in the kit's folder): its launcher 2.4.0 cannot list that deployment for the one question. It is
    # replaced like a first install, and nothing is stopped or started: the deployment found is not the kit's.
    # Twin of the H1 checks in component-ownership.sh.
    Check 'kit launcher 2.4.0, the kit''s own database gone: replaced like a first install' `
        'rc=0 download=yes version=2.5.0 same=gone kit=2.5.0 owner=kit lifted=no' (Invoke-BehindRun '2.4.0' kit $true running '' '' "kit_database_missing|$kitDb|$kitDb-moved")
    Check '...nothing stopped or started, nothing said about a stop' 'running||False' "$($script:behindStatus)|$($script:behindRestarts -join ' ')|$([bool]($script:behindSaid -match 'needs the database stopped'))"
    Check 'kit launcher 2.4.0, another deployment running in the kit''s folder: replaced, nothing stopped' `
        'rc=0 download=yes version=2.5.0 same=gone kit=2.5.0 owner=kit lifted=no|running|' "$(Invoke-BehindRun '2.4.0' kit $true running '' '' "kit_database_missing|$kitDb|$kitDb")|$($script:behindStatus)|$($script:behindRestarts -join ' ')"
    Check 'an installer that exakit update started: the update decides, the step reuses' `
        'rc=0 download=no version=2.4.0 same=yes kit=none owner=kit lifted=no' (Invoke-BehindRun '2.4.0' kit $true stopped '' '1')

    # THE OLD FILE GOES ONLY WHEN IT IS THE ONE THE KIT RECORDED (ISS-07). With
    # a receipt written from an older kit's record, that is the published 2.4.0.
    $script:PersonalPublished240Sha = ('0' * 64)
    Check 'a kit from before receipts, the file at .local\bin not the published 2.4.0: it stays' `
        'rc=0 download=yes version=2.5.0 same=yes kit=2.5.0 owner=kit lifted=no' (Invoke-BehindRun '2.4.0' legacy $false stopped)
    $asIs = Join-Path $work 'published-2.4.0'; Set-Content $asIs '2.4.0'
    $script:PersonalPublished240Sha = (Get-FileHash $asIs).Hash
    Check '...the published 2.4.0: it goes' `
        'rc=0 download=yes version=2.5.0 same=gone kit=2.5.0 owner=kit lifted=no' (Invoke-BehindRun '2.4.0' legacy $false stopped)
    # A FILE LEFT IN THE KIT'S FOLDER WITH NO RECEIPT FOR IT (WPS-03): an update
    # that could not take it away, an install cut short, a lost record. The
    # kit's by its place: never recorded as the user's, kept only when it is the
    # pinned release.
    $leftPinned = '2.5.0'
    $script:runAgain = {
        # The next process: what the kit runs, and whose it is.
        $script:PersonalSeparate = $false; $script:PersonalBinSynced = $false; $script:PersonalBinPath = $theirsAtKitPath
        "$((Get-PersonalCli) -eq (Get-PersonalSeparateBinPath))|$(Get-ExakitComponentOwnership 'personal')"
    }
    Check 'a 0.3.0 kit launcher 2.4.0 beside a 2.5.0 left in the kit folder: updated, the old file goes' `
        'rc=0 download=yes version=2.5.0 same=gone kit=2.5.0 owner=kit lifted=yes' (Invoke-BehindRun '2.4.0' kit $true stopped -Leftover $leftPinned)
    Check '...the next process runs the kit folder''s, the kit''s' 'True|kit' (& $script:runAgain)
    Check 'a receipt of the kit''s at .local\bin: that launcher is run until its update, whatever is left in the kit folder' 'False|kit' (& {
        $null = Invoke-BehindRun '2.4.0' kit $true running '0' -Leftover $leftPinned
        & $script:runAgain })
    function Invoke-LeftoverRun([string]$Content, [string]$ReceiptOwner) {
        $script:manifest = @{}
        Remove-Item -Force (Join-Path $work 'downloaded') -ErrorAction SilentlyContinue
        Remove-Item -Force -LiteralPath $theirsAtKitPath -ErrorAction SilentlyContinue
        $sepBin = Get-PersonalSeparateBinPath
        New-Item -ItemType Directory -Force (Split-Path -Parent $sepBin) | Out-Null
        Set-Content $sepBin $Content
        if ($ReceiptOwner) { Set-ExakitManifestValue 'components.personal.ownership' $ReceiptOwner; Set-ExakitManifestValue 'components.personal.ownership_path' $sepBin }
        $script:PersonalSeparate = $false; $script:PersonalBinSynced = $false; $script:PersonalLauncherPlan = $null; $script:PersonalBinPath = $theirsAtKitPath
        & {
            function Get-PersonalTargetVersion { '2.5.0' }
            function Invoke-ExakitBounded { param($FilePath, $Arguments, $TimeoutSeconds)
                if ($Arguments[0] -eq 'version') { return ([IO.File]::ReadAllLines($FilePath)[0]).Trim() }
                return "Commands:`n  local  Install locally" }
            function Get-Command { param($Name, $ErrorAction, $CommandType) if ($Name -eq 'exasol') { return $null }; Microsoft.PowerShell.Core\Get-Command @PSBoundParameters }
            function Resolve-PersonalDeployDir { return [pscustomobject]@{ LegacyRoot = ''; NewRoot = ''; Dir = ''; New = ''; Legacy = '' } }
            function Get-PersonalS3Source { @{ Url = 'https://fixture.invalid/exasol.exe'; Sha256 = $newHash } }
            function Get-ExakitFile { param($Url, $Dest, [switch]$Soft) Set-Content (Join-Path $work 'downloaded') 'yes'; Copy-Item $newLauncher $Dest; return $true }
            function Reset-PersonalDeployFollow { }
            function Get-ExakitTilde([string]$Path) { $Path }
            Install-PersonalLauncher
        }
        $dl = 'no'; if (Test-Path (Join-Path $work 'downloaded')) { $dl = 'yes' }
        return "download=$dl owner=$(Get-ExakitManifestValue 'components.personal.ownership') kit=$(([IO.File]::ReadAllLines($sepBin)[0]).Trim()) next=$(& $script:runAgain)"
    }
    foreach ($receipt in @('', 'unknown', 'user')) {
        Check "the pinned release in the kit folder, receipt '$receipt': the kit's, nothing downloaded" `
            'download=no owner=kit kit=2.5.0 next=True|kit' (Invoke-LeftoverRun '2.5.0' $receipt)
    }
    Check 'another file in the kit folder, no receipt: installed again, checksum checked' `
        'download=yes owner=kit kit=2.5.0 next=True|kit' (Invoke-LeftoverRun '2.5.0 not the release' '')
    $script:manifest = @{}
    Check 'a lost record: the kit folder''s launcher is the kit''s, and what the kit runs' 'True|kit' (& $script:runAgain)
    Remove-Item -Force -LiteralPath (Get-PersonalSeparateBinPath) -ErrorAction SilentlyContinue
    $script:PersonalSeparate = $false; $script:PersonalBinSynced = $false; $script:PersonalBinPath = $theirsAtKitPath

    # A VENV AN UNINSTALL HALF DELETED (a program held its python.exe: no
    # pyvenv.cfg left) is made again, never installed into.
    function Invoke-VenvRun([bool]$Config) {
        $script:manifest = @{}
        $script:PyexasolVenv = Join-Path $work 'pyexasol-venv'
        Remove-Item -Recurse -Force $script:PyexasolVenv -ErrorAction SilentlyContinue
        $py = Get-PyexasolVenvPython
        New-Item -ItemType Directory -Force (Split-Path -Parent $py) | Out-Null
        Set-Content $py 'not a program'
        if ($Config) { Set-Content (Join-Path $script:PyexasolVenv 'pyvenv.cfg') 'home = x' }
        $script:PyexasolVersion = '9.9.9'; $script:PyexasolPackage = 'pyexasol'; $script:ManagedPythonVersion = '3.12'; $script:PyexasolMinVersion = '2.4.0'
        $script:uvCalls = @()
        & {
            function Install-ExakitUv { return 'uv' }
            function Invoke-ExakitLogged { $script:uvCalls += ((@($args | Select-Object -Skip 1) -join ' ') -replace [regex]::Escape($work), ''); return 0 }
            $null = Install-Pyexasol
        }
        return (($script:uvCalls | ForEach-Object { ($_ -split ' ')[0..2] -join ' ' }) -join '|')
    }
    Check 'a venv with no pyvenv.cfg: made again, then installed' 'venv --seed --clear|pip install --python' (Invoke-VenvRun $false)
    Check '...a whole one: installed into, never made again' 'pip install --python' (Invoke-VenvRun $true)

    # THE LAUNCHER STEP OF A RE-RUN IS NOT SKIPPED WHILE THE LAUNCHER IS BEHIND (MAC-01): Begin-ExakitStep said
    # "already done, skipping" for it, so Install-PersonalLauncher never ran. Twin of the drift checks in
    # kit-upgrade.sh.
    $stepRun = {
        param([string]$Recorded)
        $script:manifest = @{ 'runtime.type' = 'personal'; 'runtime.version' = $Recorded }
        & {
            function Test-ExakitStepDone([string]$Name) { $true }
            function Get-PersonalTargetVersion { '2.5.0' }
            function Write-ExakitStepHeading([string]$Title) { }
            $script:stepAnswer = [bool](Begin-ExakitStep "launcher" "Step 1/4  Exasol launcher")
        }
        return "$($script:stepAnswer)|$($script:ExakitStepRerunReason)"
    }
    Check 'a done launcher step, the launcher behind the pin: run again' `
        'True|personal 2.4.0 is installed and this kit installs 2.5.0 - updating it' (& $stepRun '2.4.0')
    Check 'a done launcher step at the pin: skipped as before' 'False|' (& $stepRun '2.5.0')
    Check 'a done launcher step ahead of the pin: skipped, never downgraded' 'False|' (& $stepRun '2.6.0')
    Write-Host "$script:PASS PowerShell ownership checks passed"
} finally { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
