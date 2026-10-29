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
    Write-Host "$script:PASS PowerShell ownership checks passed"
} finally { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
