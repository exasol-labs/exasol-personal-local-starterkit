# udf-devkit.ps1 - udf-devkit (Python UDFs on the local database): managed
# install + validation + the `exakit udf-setup | udf-use | udf-build | udf-file
# | model` commands. Twin of setup/lib/udf-devkit.sh; read that header for the
# facts. The rules and the database steps are setup/udf/udf_tool.py, the model
# files' rules setup/udf/model_tool.py, both shared by the two twins.

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
# -Script model_tool.py -NoConnection runs the model files' tool instead, with
# no connection settings in its environment (twin of _model_tool).
function Invoke-UdfTool {
    param([Parameter(Mandatory)][string[]]$ToolArgs, [string]$StdIn = "", [string]$Python = "",
          [string]$Script = "udf_tool.py", [switch]$NoConnection)
    if (-not $Python) {
        $Python = if (Get-Command Get-PyexasolVenvPython -ErrorAction SilentlyContinue) { Get-PyexasolVenvPython } else { "" }
        if (-not ($Python -and (Test-Path $Python))) {
            $found = @("python3", "python", "py") | ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
            $Python = if ($found) { $found.Source } else { "python" }
        }
    }
    $tool = $Script
    if (-not [System.IO.Path]::IsPathRooted($Script)) { $tool = Join-Path (Join-Path (Join-Path (Get-ExakitRepoRoot) "setup") "udf") $Script }
    $saved = @{}
    $envs = @{}
    if (-not $NoConnection) {
        $envs = @{ EXAKIT_PYX_DSN = (Get-ExakitManifestValue "runtime.dsn"); EXAKIT_PYX_USER = (Get-ExakitManifestValue "runtime.user")
                   EXAKIT_PYX_PWFILE = (Get-ExakitManifestValue "runtime.password_file") }
        if (-not $envs.EXAKIT_PYX_USER) { $envs.EXAKIT_PYX_USER = "sys" }
    }
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

# Get-UdfBucketLocation - where the deployment's bucket is, resolved in this one
# place for every command that hands a UDF a file (udf-file, model put | list;
# the external-sources work stages its drivers through the same mapping).
# @{ Dir = the folder on this machine; UdfRoot = /buckets/<service>/<bucket>;
# Error = why there is none, or "" }. Twin of udf_bucket_locate.
function Get-UdfBucketLocation {
    $root = Join-Path $script:PersonalDeployDir $script:UdfBucketfsDir
    if (-not (Test-Path (Split-Path -Parent $root))) {
        return [pscustomobject]@{ Dir = ""; UdfRoot = ""
            Error = "The deployment has no BucketFS folder at $root; is the database deployed by this launcher? (exakit status)" }
    }
    # One separator: the setting is written with backslashes, which pwsh on
    # macOS or Linux accepts but the Python tool given this path would not.
    $dir = (Join-Path (Join-Path $root $script:UdfBucketfsService) $script:UdfBucketfsBucket).Replace([char]'\', [System.IO.Path]::DirectorySeparatorChar)
    return [pscustomobject]@{
        Dir     = $dir
        UdfRoot = "$($script:UdfBucketfsRoot)/$($script:UdfBucketfsService)/$($script:UdfBucketfsBucket)"
        Error   = ""
    }
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
        Info "  model files stay in the deployment's bucket directory; only their record goes"
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

# Find-UdfContainerRuntime - the engine udf-build's exaslct talks to, checked
# before anything is built (AC-ML1.3): "docker" when the Docker CLI answers;
# "podman" when Podman answers and its Docker-compatible API is known
# (DOCKER_HOST already set, or the machine's pipe or socket, set here for
# exaslct) - so the Podman the launcher installed is enough; "podman-no-api"
# when Podman answers without one; "" when no engine answers. Bounded: `podman
# info` can block while a machine is still coming up. Twin of
# _udf_container_runtime.
function Find-UdfContainerRuntime {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if ($docker -and $null -ne (Invoke-ExakitBounded -FilePath $docker.Source -Arguments @("info") -TimeoutSeconds 20)) { return "docker" }
    $podman = Get-Command podman -ErrorAction SilentlyContinue
    if (-not $podman -or $null -eq (Invoke-ExakitBounded -FilePath $podman.Source -Arguments @("info") -TimeoutSeconds 20)) { return "" }
    if ($env:DOCKER_HOST) { return "podman" }
    $pipe = ("" + (Invoke-ExakitBounded -FilePath $podman.Source -Arguments @("machine", "inspect", "--format", "{{.ConnectionInfo.PodmanPipe.Path}}") -TimeoutSeconds 20)).Trim()
    if ($pipe -match '^\\\\\.\\pipe\\(.+)$') {
        $env:DOCKER_HOST = "npipe:////./pipe/$($Matches[1])"
        return "podman"
    }
    $sock = ("" + (Invoke-ExakitBounded -FilePath $podman.Source -Arguments @("machine", "inspect", "--format", "{{.ConnectionInfo.PodmanSocket.Path}}") -TimeoutSeconds 20)).Trim()
    if ($sock -and (Test-Path $sock)) {
        $env:DOCKER_HOST = "unix://$sock"
        return "podman"
    }
    return "podman-no-api"
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
    $runtime = Find-UdfContainerRuntime
    if ($runtime -eq "podman-no-api") { Fail "Podman answers, but not its Docker-compatible API, which the container build talks to. Start Podman's machine again (podman machine start) or point DOCKER_HOST at its API, then run this again." }
    if (-not $runtime) { Fail "Building a container needs a running container engine, Docker or Podman, and none answers (start Docker Desktop, or Podman's machine: podman machine start)." }
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
    Info "Building a container with $($packages.Count) package(s) on $runtime; this takes a while the first time"
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
    $bucket = Get-UdfBucketLocation
    if ($bucket.Error) { Fail $bucket.Error }
    $dest = Join-Path $bucket.Dir ($relative -replace "/", "\")
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    Copy-Item -Path $source -Destination "$dest.part" -Force
    Move-Item -Path "$dest.part" -Destination $dest -Force
    Ok "Copied into BucketFS: $dest"
    Info "A UDF reads it as: $($bucket.UdfRoot)/$relative"
}

# --- exakit model put | list | template ---------------------------------------
# Twin of the block of the same name in udf-devkit.sh; read its comment for the
# rules. The model files' tool is setup/udf/model_tool.py, shared by both.

# Exit-UdfModel - stop with the kit's exit code for what went wrong (3 no
# deployment, 4 not installed, 5 not confirmed). No failure note: nothing of
# the install failed. With --json, one object on stdout. Twin of _model_refuse.
function Exit-UdfModel {
    param([Parameter(Mandatory)][int]$Code, [Parameter(Mandatory)][string]$Message, $Remedy = $null)
    if ($script:ExakitRefusalJson) {
        Write-Output ([ordered]@{ ok = $false; error = $Message; remedy = $Remedy } | ConvertTo-Json -Compress)
        exit $Code
    }
    Write-Host ""
    Write-Host ("  {0} {1}" -f $script:UiCross, $Message) -ForegroundColor Red
    if ($Remedy) { Write-Host "    Run: $Remedy" }
    exit $Code
}

# Assert-UdfModelReady - the add-on installed and a deployment to put files
# into; the bucket location. Twin of _model_ready.
function Assert-UdfModelReady {
    if (-not (Get-UdfDevkitInstalledVersion)) { Exit-UdfModel -Code 4 -Message "The UDF dev kit is not installed." -Remedy "exakit marketplace udf-devkit" }
    $bucket = Get-UdfBucketLocation
    if ($bucket.Error) { Exit-UdfModel -Code 3 -Message $bucket.Error -Remedy "exakit status" }
    return $bucket
}

# Get-UdfModelRecord - the recorded models as one JSON object ({} when none yet).
function Get-UdfModelRecord {
    $record = Get-ExakitManifestValue "components.udf_devkit.models"
    if ($null -eq $record -or $record -isnot [System.Management.Automation.PSCustomObject]) { return "{}" }
    return ($record | ConvertTo-Json -Depth 6 -Compress)
}

function Invoke-CmdModel {
    param([string[]]$CmdArgs = @())
    $sub = ""
    if ($CmdArgs.Count -gt 0) { $sub = $CmdArgs[0] }
    $rest = @()
    if ($CmdArgs.Count -gt 1) { $rest = @($CmdArgs[1..($CmdArgs.Count - 1)]) }
    # One page per command: Show-ExakitHelpCommand renders the first match only.
    if ($sub -in @("--help", "-h")) {
        foreach ($each in @("put", "list", "template")) { Show-ExakitHelpCommand -Name "exakit model $each" | Out-Null }
        return
    }
    if ($sub -in @("put", "list", "template") -and ($rest -contains "--help" -or $rest -contains "-h")) {
        Show-ExakitHelpCommand -Name "exakit model $sub" | Out-Null; return
    }
    switch ($sub) {
        "put"      { Invoke-CmdModelPut -CmdArgs $rest }
        "list"     { Invoke-CmdModelList -CmdArgs $rest }
        "template" { Invoke-CmdModelTemplate -CmdArgs $rest }
        ""         { Deny-ExakitInput "Name what to do: exakit model put <file> | exakit model list | exakit model template (exakit model --help)." }
        default    { Deny-ExakitInput "Unknown model command '$sub' (supported: put, list, template)." }
    }
}

function Invoke-CmdModelPut {
    param([string[]]$CmdArgs = @())
    $file = ""; $replace = $false; $json = $false
    foreach ($arg in $CmdArgs) {
        if ($arg -eq "--replace") { $replace = $true }
        elseif ($arg -in @("--json", "-j")) { $json = $true; $script:ExakitRefusalJson = $true }
        elseif ($arg.StartsWith("-")) { Deny-ExakitInput "Unknown option '$arg' for model put (supported: --replace --json)." }
        elseif ($file) { Deny-ExakitInput "Name one model file: exakit model put <file> [--replace]" }
        else { $file = $arg }
    }
    if (-not $file) { Deny-ExakitInput "Name the model file: exakit model put <file> [--replace] [--json]" }
    $bucket = Assert-UdfModelReady
    if (-not (Test-Path $file -PathType Leaf)) { Deny-ExakitInput "$file is not a file." }
    $replaceArg = "0"
    if ($replace) { $replaceArg = "1" }
    $result = Invoke-UdfTool -Script "model_tool.py" -NoConnection -StdIn (Get-UdfModelRecord) `
        -ToolArgs @("put", (Resolve-Path $file).Path, $bucket.Dir, $bucket.UdfRoot, $replaceArg)
    if ($result[0] -eq 5) { Exit-UdfModel -Code 5 -Message $result[2] -Remedy "exakit model put $file --replace" }
    if ($result[0] -eq 2) { Deny-ExakitInput $result[2] }
    if ($result[0] -ne 0) { Fail "Could not put $file into the bucket directory: $($result[2])" }
    $lines = @($result[1])
    $action = $lines[0]
    Set-ExakitManifestValue "components.udf_devkit.models" ($lines[2] | ConvertFrom-Json)
    if ($json) { Write-Output $lines[1]; return }
    $answer = $lines[1] | ConvertFrom-Json
    $dest = Join-Path (Join-Path $bucket.Dir "models") $answer.name
    if ($action -eq "unchanged") { Ok "$($answer.name) is already in the bucket directory with the same digest; nothing was copied" }
    elseif ($action -eq "replaced") { Ok "Replaced $($answer.name) in the bucket directory: $dest" }
    else { Ok "Copied $($answer.name) into the bucket directory: $dest" }
    Info "sha256 $($answer.sha256), $($answer.size) bytes, recorded"
    Info "A UDF reads it as: $($answer.path)"
}

function Invoke-CmdModelList {
    param([string[]]$CmdArgs = @())
    $json = $false
    foreach ($arg in $CmdArgs) {
        if ($arg -in @("--json", "-j")) { $json = $true; $script:ExakitRefusalJson = $true }
        else { Deny-ExakitInput "Unknown argument '$arg' for model list (supported: --json)." }
    }
    $bucket = Assert-UdfModelReady
    $result = Invoke-UdfTool -Script "model_tool.py" -NoConnection -StdIn (Get-UdfModelRecord) `
        -ToolArgs @("list", $bucket.Dir, $bucket.UdfRoot)
    if ($result[0] -ne 0) { Fail "Could not list the bucket directory: $($result[2])" }
    $text = (@($result[1]) -join "`n")
    # The tool's own JSON, as it printed it: a round trip through ConvertFrom-Json
    # and back would turn an empty "models": [] into null on PowerShell 5.1.
    if ($json) { Write-Output $text; return }
    $doc = $text | ConvertFrom-Json
    Write-Host "  Bucket directory: $($doc.bucket_dir)"
    Write-Host "  UDFs read it as:  $($doc.udf_root)"
    Write-Host ""
    $models = @($doc.models | Where-Object { $_ })
    if ($models.Count -eq 0) { Write-Host "  No models yet. Put one with: exakit model put <file>" }
    foreach ($m in $models) {
        $note = ""
        if ($m.status -eq "changed") { $note = "  ! CHANGED since it was put (recorded $("$($m.recorded_sha256)".Substring(0, 12))...)" }
        elseif ($m.status -eq "unrecorded") { $note = "  (not put with exakit model put)" }
        Write-Host ("  {0,-28} {1,10} bytes  sha256 {2}...{3}" -f $m.name, $m.size, $m.sha256.Substring(0, 12), $note)
        Write-Host "      $($m.path)"
    }
    foreach ($name in @($doc.missing | Where-Object { $_ })) {
        Write-Host ("  {0,-28} recorded, but no longer in the bucket directory" -f $name)
    }
}

function Invoke-CmdModelTemplate {
    param([string[]]$CmdArgs = @())
    $json = $false
    foreach ($arg in $CmdArgs) {
        if ($arg -in @("--json", "-j")) { $json = $true }
        else { Deny-ExakitInput "Unknown argument '$arg' for model template (supported: --json)." }
    }
    $dir = Join-Path (Join-Path (Get-ExakitRepoRoot) "udf") "templates"
    $renderer = Join-Path $dir "render.py"
    if (-not (Test-Path $renderer -PathType Leaf)) { Fail "The UDF templates are missing from this kit copy ($dir). Repair with: exakit update" }
    $template = Join-Path $dir "score_model.sql"
    $found = Invoke-UdfTool -Script $renderer -NoConnection -ToolArgs @("--placeholders")
    $places = @($found[1] | Where-Object { $_ })
    if ($json) {
        Write-Output ([ordered]@{ template = $template; renderer = $renderer; placeholders = $places; usage = "python $renderer --help" } | ConvertTo-Json -Compress)
        return
    }
    Info "Scoring UDF template: $template"
    Info "Placeholders: $($places -join ' ')"
    Info "Fill them with the renderer (every value is checked; none may be left unfilled):"
    Write-Host "    python $renderer ``"
    Write-Host "      --schema SCORING --name SCORE_MODEL --model-path <the path exakit model put printed> ``"
    Write-Host "      --input category:VARCHAR(2000) --input doc_text:VARCHAR(2000000):text --output DOUBLE --method predict_proba"
}
