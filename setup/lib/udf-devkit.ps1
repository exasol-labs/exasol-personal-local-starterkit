# udf-devkit.ps1 - udf-devkit (Python UDFs on the local database): managed
# install + validation + the `exakit udf-setup | udf-use | udf-build | udf-file`
# commands. Twin of setup/lib/udf-devkit.sh; read that header for the facts.
# The rules and the database steps are setup/udf/udf_tool.py, shared by both.

$script:UdfDevkitVersionFallback = if ($env:EXAKIT_UDF_DEVKIT_VERSION_FALLBACK) { $env:EXAKIT_UDF_DEVKIT_VERSION_FALLBACK } else { "0.1.0" }
$script:UdfDevkitVersion = if ($env:EXAKIT_UDF_DEVKIT_VERSION) { $env:EXAKIT_UDF_DEVKIT_VERSION } else { "" }
$script:UdfDevkitHome = if ($env:EXAKIT_UDF_DEVKIT_HOME) { $env:EXAKIT_UDF_DEVKIT_HOME } else { Join-Path $script:ExakitHome "udf-devkit" }
$script:UdfMinLauncher = "2.3.0"
$script:UdfOfficialAlias = "PYTHON3"
$script:UdfDefaultAlias = "PYTHON3_ML"
$script:UdfBuildAlias = "PYTHON3_CUSTOM"
$script:UdfLanguage = "python"
$script:UdfSchema = "EXAKIT_UDF"
$script:UdfBucketfsDir = "local\runtime\exa\bucketfs"
$script:UdfBucketfsService = "bfsdefault"
$script:UdfBucketfsBucket = "default"
$script:UdfBucketfsRoot = "/buckets"
$script:UdfBuildFlavor = "template-Exasol-all-python-3.12"
$script:UdfBuildName = "kit_custom"
$script:UdfBuildMinFreeGb = 25
$script:UdfYes = $false

function Get-UdfDevkitLatest {
    $advertised = Get-ExakitVersionsValue "components.udf-devkit.version"
    if ($advertised) { return $advertised }
    return $script:UdfDevkitVersionFallback
}

function Get-UdfDevkitInstalledVersion { return (Get-ExakitManifestValue "components.udf_devkit.version") }

# Invoke-UdfTool - setup/udf/udf_tool.py with the pyexasol venv's Python,
# connected as the kit's admin user (the password is read from its file by the
# child). @(exit code, stdout lines, stderr text). Twin of _udf_tool.
function Invoke-UdfTool {
    param([Parameter(Mandatory)][string[]]$ToolArgs, [string]$StdIn = "", [string]$Python = "")
    if (-not $Python) {
        $Python = if (Get-Command Get-PyexasolVenvPython -ErrorAction SilentlyContinue) { Get-PyexasolVenvPython } else { "" }
        if (-not ($Python -and (Test-Path $Python))) {
            $found = @("python3", "python", "py") | ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
            $Python = if ($found) { $found.Source } else { "python" }
        }
    }
    $tool = Join-Path (Join-Path (Join-Path (Get-ExakitRepoRoot) "setup") "udf") "udf_tool.py"
    $saved = @{}
    $envs = @{ EXAKIT_PYX_DSN = (Get-ExakitManifestValue "runtime.dsn"); EXAKIT_PYX_USER = (Get-ExakitManifestValue "runtime.user")
               EXAKIT_PYX_PWFILE = (Get-ExakitManifestValue "runtime.password_file") }
    if (-not $envs.EXAKIT_PYX_USER) { $envs.EXAKIT_PYX_USER = "sys" }
    foreach ($key in $envs.Keys) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
        [Environment]::SetEnvironmentVariable($key, [string]$envs[$key], "Process")
    }
    $errFile = [System.IO.Path]::GetTempFileName()
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        if ($StdIn) { $out = @($StdIn | & $Python $tool @ToolArgs 2>$errFile) } else { $out = @(& $Python $tool @ToolArgs 2>$errFile) }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
        foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key], "Process") }
    }
    $err = (Get-Content -Raw $errFile -ErrorAction SilentlyContinue)
    Remove-Item -Force -ErrorAction SilentlyContinue $errFile
    return ,@($code, @($out | ForEach-Object { "$_" }), "$err".Trim())
}

# Invoke-UdfSlc - the launcher's container commands for this deployment;
# @(exit code, output). Twin of _udf_slc.
function Invoke-UdfSlc {
    param([Parameter(Mandatory)][string[]]$SlcArgs)
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $out = @(& (Get-PersonalCli) slc @SlcArgs --deployment-dir $script:PersonalDeployDir 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prevEap }
    if ($script:LogFile -and $out.Count) { $out | Add-Content -Path $script:LogFile }
    return ,@($code, $out)
}

function Test-UdfDevkitLauncher {
    $version = Get-PersonalLauncherVersion
    if (-not $version) { $version = "0" }
    if ((Invoke-UdfTool -ToolArgs @("atleast", $version, $script:UdfMinLauncher))[0] -eq 0) { return $true }
    Warn2 "The UDF dev kit needs Exasol launcher $($script:UdfMinLauncher) or later; this machine has $version. Update it with: exakit update personal"
    return $false
}

function Get-UdfDevkitInstalledAliases {
    $listing = Invoke-UdfSlc -SlcArgs @("list", "--json")
    if ($listing[0] -ne 0) { return @() }
    $result = Invoke-UdfTool -ToolArgs @("aliases") -StdIn (($listing[1]) -join "`n")
    return @($result[1] | Where-Object { $_ })
}

# Test-UdfDevkitSmoke - create and run the smoke UDF; $true when every declared
# package is there. Twin of udf_devkit_smoke.
function Test-UdfDevkitSmoke {
    param([Parameter(Mandatory)][string]$Alias, [string[]]$Packages = @())
    $result = Invoke-UdfTool -ToolArgs (@("smoke", $Alias, $script:UdfSchema) + $Packages)
    if ($result[0] -ne 0) {
        Warn2 "The smoke UDF on $Alias did not pass: $(@($result[2] -split "`n")[-1])"
        return $false
    }
    $python = ($result[1] | Where-Object { $_ -like "python *" } | Select-Object -First 1) -replace "^python ", ""
    Ok "Python UDFs run on $Alias (Python $python)"
    foreach ($line in @($result[1] | Where-Object { $_ -notlike "python *" })) {
        $parts = $line -split " ", 2
        Write-Host ("      {0,-24} {1}" -f $parts[0], $parts[1])
    }
    Info "Use it in SQL: CREATE OR REPLACE $Alias SCALAR SCRIPT ..."
    Set-ExakitManifestValue "components.udf_devkit.validated" $true
    return $true
}

# Invoke-UdfWithRestart - confirm, stop the running add-on services, run the
# install, wait for the database, start the services again. Twin of
# _udf_with_restart.
function Invoke-UdfWithRestart {
    param([Parameter(Mandatory)][string]$What, [Parameter(Mandatory)][scriptblock]$Action)
    if (-not $script:UdfYes -and -not (Confirm-ExakitPrompt "$What restarts the database (running add-ons are stopped and started again). Continue" $true)) {
        Info "$What was not started; nothing changed."
        return $false
    }
    $running = @()
    foreach ($id in @(Get-ExakitServiceIds)) {
        if ($id -eq "database") { continue }
        if ((Get-ExakitServiceStatus $id) -ne "running") { continue }
        try { Stop-ExakitService $id | Out-Null; $running += $id } catch { }
    }
    $script:ExakitActiveLabel = $What
    $ok = & $Action
    Info "Waiting for the database to answer after the restart"
    Wait-PersonalReady
    foreach ($id in $running) {
        try { Start-ExakitService $id | Out-Null } catch { Warn2 "$id did not start again - start it with: exakit start $id" }
    }
    return [bool]$ok
}

function Install-UdfDevkitOfficial {
    param([bool]$Force = $false)
    if (-not (Test-ExakitDbReachable)) { Warn2 "The database is not running. Start it with: exakit start"; return $false }
    if (-not (Test-UdfDevkitLauncher)) { return $false }
    if ($Force -or -not (@(Get-UdfDevkitInstalledAliases) -contains $script:UdfOfficialAlias)) {
        $done = Invoke-UdfWithRestart -What "Installing the official $($script:UdfOfficialAlias) container" -Action {
            (Invoke-UdfSlc -SlcArgs @("install", $script:UdfOfficialAlias, "--auto-approve"))[0] -eq 0 }
        if (-not $done) {
            Warn2 "The launcher could not install the $($script:UdfOfficialAlias) container (see the log)."
            return $false
        }
    } else {
        Ok "The official $($script:UdfOfficialAlias) container is already installed"
    }
    return (Test-UdfDevkitSmoke -Alias $script:UdfOfficialAlias)
}

function Install-UdfDevkit {
    if (-not $script:UdfDevkitVersion) { $script:UdfDevkitVersion = Get-UdfDevkitLatest }
    if (-not (Test-UdfDevkitLauncher)) {
        Set-ExakitFailureReason "the Exasol launcher is older than $($script:UdfMinLauncher)"
        return $false
    }
    Set-ExakitManifestValue "components.udf_devkit.version" $script:UdfDevkitVersion
    Set-ExakitManifestValue "components.udf_devkit.schema" $script:UdfSchema
    if (Test-ExakitDbReachable) {
        $script:UdfYes = $true
        try {
            if (-not (Install-UdfDevkitOfficial)) { Warn2 "Python UDFs are not set up yet - run: exakit udf-setup" }
        } finally { $script:UdfYes = $false }
    } else {
        Info "Start the database, then set up Python UDFs with: exakit udf-setup"
    }
    return $true
}

function Test-UdfDevkit {
    if (-not (Test-ExakitDbReachable)) { return }
    if (@(Get-UdfDevkitInstalledAliases) -contains $script:UdfOfficialAlias) {
        if (-not (Test-UdfDevkitSmoke -Alias $script:UdfOfficialAlias)) { Set-ExakitManifestValue "components.udf_devkit.validated" $false }
    } else {
        Set-ExakitManifestValue "components.udf_devkit.validated" $false
    }
}

function Update-UdfDevkit {
    $target = Get-UdfDevkitLatest
    $current = Get-UdfDevkitInstalledVersion
    if ($current -eq $target) { Ok "udf-devkit is current ($target)"; return }
    Set-ExakitManifestValue "components.udf_devkit.version" $target
    Set-ExakitManifestValue "desired.udf_devkit" $target
    if ($current -and ($current.Split(".")[0] -ne $target.Split(".")[0])) {
        Warn2 "udf-devkit $current -> $target is a major version: its prebuilt container, alias or packages may differ (exakit help udf-devkit). Your installed containers and UDFs keep working until you switch."
    }
    Info "The prebuilt container $target is available - install it when ready with: exakit udf-use default"
    Ok "udf-devkit $(if ($current) { $current } else { 'not installed' }) -> $target"
}

function Get-UdfDevkitSummary { return "Python UDFs: exakit udf-setup" }

function Uninstall-UdfDevkit {
    param([switch]$DryRun)
    if ($DryRun) {
        if (Test-Path $script:UdfDevkitHome) { Info "  will remove: $($script:UdfDevkitHome)" }
        Info "  containers stay installed in the database (exasol slc remove <alias> removes one)"
        return $true
    }
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $script:UdfDevkitHome
    Remove-ExakitManifestValue "components.udf_devkit"
    Remove-ExakitManifestValue "desired.udf_devkit"
    Info "Containers stay installed in the database; remove one with: exasol slc remove <alias> ($($script:UdfDefaultAlias), $($script:UdfBuildAlias))"
    OkStep "udf-devkit removed - reinstall any time with: exakit marketplace udf-devkit"
    return $true
}

# --- the commands ------------------------------------------------------------------

function Assert-UdfDevkitInstalled {
    if (-not (Get-UdfDevkitInstalledVersion)) { Fail "The UDF dev kit is not installed. Install it with: exakit marketplace udf-devkit" }
}

function Get-UdfIdentifier {
    param([string]$Name)
    $result = Invoke-UdfTool -ToolArgs @("identifier", $Name)
    if ($result[0] -ne 0) { Fail $result[2] }
    return @($result[1])[0]
}

function Install-UdfTarball {
    param([string]$Tarball, [string]$Alias, [string]$Source, [string[]]$Packages = @())
    $verb = if (@(Get-UdfDevkitInstalledAliases) -contains $Alias) { "update" } else { "install" }
    $done = Invoke-UdfWithRestart -What "Installing the container as $Alias" -Action {
        (Invoke-UdfSlc -SlcArgs @("custom", $verb, "--source", $Tarball, "--alias", $Alias, "--language", $script:UdfLanguage, "--auto-approve"))[0] -eq 0 }
    if (-not $done) { Fail "The launcher could not install the container as $Alias (see: exakit logs)." }
    if (Test-UdfDevkitSmoke -Alias $Alias -Packages $Packages) {
        Set-ExakitManifestValue "components.udf_devkit.containers.$Alias" $Source
    }
}

function Invoke-CmdUdfSetup {
    param([string[]]$CmdArgs = @())
    $force = $false
    foreach ($arg in $CmdArgs) {
        switch ($arg) {
            "--force" { $force = $true }
            { $_ -in @("--yes", "-y") } { $script:UdfYes = $true }
            default { Fail "udf-setup takes --force (reinstall the container) and --yes, nothing else: $arg" }
        }
    }
    Assert-UdfDevkitInstalled
    [void](Install-UdfDevkitOfficial -Force $force)
}

function Invoke-CmdUdfUse {
    param([string[]]$CmdArgs = @())
    $what = ""; $alias = ""; $list = $false
    for ($i = 0; $i -lt $CmdArgs.Count; $i++) {
        $arg = $CmdArgs[$i]
        if ($arg -eq "--list") { $list = $true }
        elseif ($arg -in @("--yes", "-y")) { $script:UdfYes = $true }
        elseif ($arg -eq "--alias") { $i++; if ($i -ge $CmdArgs.Count) { Fail "--alias needs a name" }; $alias = $CmdArgs[$i] }
        elseif ($arg.StartsWith("-")) { Fail "Unknown option for udf-use: $arg (supported: --alias, --list, --yes)" }
        elseif ($what) { Fail "Name one thing to install: default, or one container tarball" }
        else { $what = $arg }
    }
    Assert-UdfDevkitInstalled
    if ($list) { (Invoke-UdfSlc -SlcArgs @("list"))[1] | ForEach-Object { Write-Host $_ }; return }
    if (-not $what) { Fail "Name what to install: exakit udf-use default, or exakit udf-use <container.tar.gz>." }
    if (-not (Test-ExakitDbReachable)) { Fail "The database is not running. Start it with: exakit start" }
    if (-not (Test-UdfDevkitLauncher)) { Fail "The Exasol launcher is too old for containers." }
    if ($what -eq "default") {
        Fail "No prebuilt container $(Get-UdfDevkitLatest) is published for this machine yet. Build one from a requirements file with: exakit udf-build requirements.txt - or install your own tarball with: exakit udf-use <file>"
    }
    if (-not ($what.EndsWith(".tar.gz") -or $what.EndsWith(".tgz"))) { Fail "$what is not a container tarball (.tar.gz)." }
    if (-not (Test-Path $what -PathType Leaf)) { Fail "$what is not a file." }
    if (-not $alias) { $alias = $script:UdfBuildAlias }
    Install-UdfTarball -Tarball (Resolve-Path $what).Path -Alias (Get-UdfIdentifier $alias) -Source $what
}

function Invoke-CmdUdfBuild {
    param([string[]]$CmdArgs = @())
    $req = ""; $alias = ""
    for ($i = 0; $i -lt $CmdArgs.Count; $i++) {
        $arg = $CmdArgs[$i]
        if ($arg -in @("--yes", "-y")) { $script:UdfYes = $true }
        elseif ($arg -eq "--alias") { $i++; if ($i -ge $CmdArgs.Count) { Fail "--alias needs a name" }; $alias = $CmdArgs[$i] }
        elseif ($arg.StartsWith("-")) { Fail "Unknown option for udf-build: $arg (supported: --alias, --yes)" }
        elseif ($req) { Fail "Name one requirements file" }
        else { $req = $arg }
    }
    if (-not $req) { Fail "Name the requirements file: exakit udf-build requirements.txt (every package pinned name==version)." }
    Assert-UdfDevkitInstalled
    if (-not (Test-Path $req -PathType Leaf)) { Fail "$req is not a file." }
    $pins = Invoke-UdfTool -ToolArgs @("pinned", (Resolve-Path $req).Path)
    if ($pins[0] -ne 0) { Fail $pins[2] }
    if (-not $alias) { $alias = $script:UdfBuildAlias }
    $alias = Get-UdfIdentifier $alias
    if (-not (Get-Command Get-NotebookInstalledVersion -ErrorAction SilentlyContinue) -or -not (Get-NotebookInstalledVersion)) {
        Fail "Building a container uses the notebook add-on's tooling, which is not installed. Install it with: exakit marketplace notebook"
    }
    if (-not (Test-ExakitDbReachable)) { Fail "The database is not running. Start it with: exakit start" }
    if (-not (Test-UdfDevkitLauncher)) { Fail "The Exasol launcher is too old for containers." }
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    $dockerOk = $false
    if ($docker) {
        $prevEap = $ErrorActionPreference
        try { $ErrorActionPreference = "Continue"; & docker info 2>$null | Out-Null; $dockerOk = ($LASTEXITCODE -eq 0) } finally { $ErrorActionPreference = $prevEap }
    }
    if (-not $dockerOk) { Fail "Building a container needs a running Docker engine, and none answers (start Docker Desktop)." }
    $work = Join-Path $script:UdfDevkitHome "build"
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $drive = (Get-Item $work).PSDrive
    $freeGb = if ($drive -and $drive.Free) { [math]::Floor($drive.Free / 1GB) } else { 0 }
    if ($freeGb -lt $script:UdfBuildMinFreeGb) { Fail "Building a container needs about $($script:UdfBuildMinFreeGb) GB free; $work has $freeGb GB." }
    $uv = Get-NotebookUv
    if (-not $uv) { Fail "uv (the Python tool runner) is not available." }
    $script:ExakitActiveLabel = "Adding the container build tooling to the notebook environment"
    $spec = "$($script:NotebookPackage)[$($script:NotebookExtras),slc]==$(Get-NotebookPackageVersion)"
    if ((Invoke-ExakitLogged $uv "pip" "install" "--python" (Get-NotebookVenvPython) $spec) -ne 0) {
        Fail "The container build tooling could not be added to the notebook environment (see the log)."
    }
    if (-not (Write-NotebookConnection)) { Fail "The notebook connection store could not be written." }
    $packages = @($pins[1] | Where-Object { $_ } | ForEach-Object { ,@(($_ -split "==", 2)) })
    $doc = @{ work_dir = $work; name = $script:UdfBuildName; flavor = $script:UdfBuildFlavor; packages = $packages } | ConvertTo-Json -Compress -Depth 4
    Info "Building a container with $($packages.Count) package(s); this takes a while the first time"
    $saved = @{ EXAKIT_UDF_BUILD = $env:EXAKIT_UDF_BUILD; SCS_FILE = $env:SCS_FILE; SCS_MASTER_PASSWORD = $env:SCS_MASTER_PASSWORD }
    $env:EXAKIT_UDF_BUILD = $doc; $env:SCS_FILE = Get-NotebookStoreFile; $env:SCS_MASTER_PASSWORD = Get-NotebookSecret $script:NotebookMasterCred
    try {
        $built = Invoke-UdfTool -ToolArgs @("build") -Python (Get-NotebookVenvPython)
    } finally {
        foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key], "Process") }
    }
    if ($script:LogFile -and $built[2]) { Add-Content -Path $script:LogFile -Value $built[2] }
    if ($built[0] -ne 0) { Fail "The container build failed (see: exakit logs)." }
    $tarball = ((@($built[1])[-1]) | ConvertFrom-Json).tarball
    if (-not ($tarball -and (Test-Path $tarball))) { Fail "The container build did not report its tarball (see: exakit logs)." }
    Install-UdfTarball -Tarball $tarball -Alias $alias -Source $req -Packages @($packages | ForEach-Object { $_[0] })
}

function Invoke-CmdUdfFile {
    param([string[]]$CmdArgs = @())
    if ($CmdArgs.Count -lt 1 -or $CmdArgs.Count -gt 2) { Fail "Name the file and, optionally, where in the bucket: exakit udf-file model.pkl models/model.pkl" }
    Assert-UdfDevkitInstalled
    $source = $CmdArgs[0]
    if (-not (Test-Path $source -PathType Leaf)) { Fail "$source is not a file." }
    $target = if ($CmdArgs.Count -eq 2) { $CmdArgs[1] } else { Split-Path -Leaf $source }
    $rel = Invoke-UdfTool -ToolArgs @("relative", $target)
    if ($rel[0] -ne 0) { Fail $rel[2] }
    $relative = @($rel[1])[0]
    $root = Join-Path $script:PersonalDeployDir $script:UdfBucketfsDir
    if (-not (Test-Path (Split-Path -Parent $root))) { Fail "The deployment has no BucketFS folder at $root; is the database deployed by this launcher? (exakit status)" }
    $dest = Join-Path (Join-Path (Join-Path $root $script:UdfBucketfsService) $script:UdfBucketfsBucket) ($relative -replace "/", "\")
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    Copy-Item -Path $source -Destination "$dest.part" -Force
    Move-Item -Path "$dest.part" -Destination $dest -Force
    Ok "Copied into BucketFS: $dest"
    Info "A UDF reads it as: $($script:UdfBucketfsRoot)/$($script:UdfBucketfsService)/$($script:UdfBucketfsBucket)/$relative"
}
