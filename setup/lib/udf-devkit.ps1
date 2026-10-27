# udf-devkit.ps1 - udf-devkit (Python and Rust UDFs on the local database):
# managed install + validation + the `exakit udf-setup | udf-use | udf-build |
# udf-file | model` commands. Twin of setup/lib/udf-devkit.sh; read that header
# for the facts (the container matrix in versions.json, the database's
# architecture, the digest check, --json and the exit codes). The rules and the
# database steps are setup/udf/udf_tool.py, the model files' rules
# setup/udf/model_tool.py, both shared by the two twins.

$script:UdfDevkitVersionFallback = if ($env:EXAKIT_UDF_DEVKIT_VERSION_FALLBACK) { $env:EXAKIT_UDF_DEVKIT_VERSION_FALLBACK } else { "0.1.0" }
$script:UdfDevkitVersion = if ($env:EXAKIT_UDF_DEVKIT_VERSION) { $env:EXAKIT_UDF_DEVKIT_VERSION } else { "" }
$script:UdfDevkitHome = if ($env:EXAKIT_UDF_DEVKIT_HOME) { $env:EXAKIT_UDF_DEVKIT_HOME } else { Join-Path $script:ExakitHome "udf-devkit" }
$script:UdfMinLauncher = "2.3.0"
$script:UdfOfficialAlias = "PYTHON3"
$script:UdfDefaultAlias = "PYTHON3_ML"
$script:UdfBuildAlias = "PYTHON3_CUSTOM"
$script:UdfRustAlias = "RUST"
# The language a persona install and the commands set up unless --language
# says otherwise; validated where it is read (Get-UdfLanguageProblem).
$script:UdfLanguage = if ($env:EXAKIT_UDF_LANGUAGE) { $env:EXAKIT_UDF_LANGUAGE } else { "python" }
$script:UdfSchema = "EXAKIT_UDF"
# Downloaded prebuilt containers, kept by file name so a second install
# verifies the cached file instead of downloading it again.
$script:UdfContainerCache = if ($env:EXAKIT_UDF_CONTAINER_CACHE) { $env:EXAKIT_UDF_CONTAINER_CACHE } else { Join-Path (Join-Path $script:ExakitHome "cache") "containers" }
# --json: the answer is one object on stdout (Write-Output); the steps' detail
# lines are gated to the log (ExakitQuietDetail).
$script:UdfJson = $false
# Why the last setup step stopped (Set-UdfFail): Code, Step, Remedy, Message.
$script:UdfFail = $null
# The selected matrix row (Select-UdfContainer) with DbArch and DbVersion, its verified
# file (Get-UdfContainerFile), and the smoke UDF's "name version" lines.
$script:UdfContainer = $null
$script:UdfContainerFile = ""
$script:UdfSmokeLines = @()
$script:UdfDeclined = $false
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
    $why = Get-UdfLauncherProblem
    if (-not $why) { return $true }
    Warn2 $why
    return $false
}

function Get-UdfDevkitInstalledAliases {
    $listing = Invoke-UdfSlc -SlcArgs @("list", "--json")
    if ($listing[0] -ne 0) { return @() }
    $result = Invoke-UdfTool -ToolArgs @("aliases") -StdIn (($listing[1]) -join "`n")
    return @($result[1] | Where-Object { $_ })
}

# Test-UdfDevkitSmoke - create and run the smoke UDF; $true when every declared
# package is there and each one pinned name==version is reported with that
# version. The "name version" lines are kept in UdfSmokeLines (for --json); a
# miss is Set-UdfFail 3 (missing) or 7 (another version, or the UDF did not
# run). Twin of udf_devkit_smoke.
function Test-UdfDevkitSmoke {
    param([Parameter(Mandatory)][string]$Alias, [string[]]$Packages = @())
    $script:UdfSmokeLines = @()
    $result = Invoke-UdfTool -ToolArgs (@("smoke", $Alias, $script:UdfSchema) + $Packages)
    $script:UdfSmokeLines = @($result[1] | Where-Object { $_ })
    if ($result[0] -ne 0) {
        $why = "The smoke UDF on $Alias did not pass: $(@($result[2] -split "`n")[-1])"
        Warn2 $why
        $code = 7
        if ($result[0] -eq 3) { $code = 3 }
        return (Set-UdfFail -Code $code -Step "smoke" -Remedy "exakit udf-use default" -Message $why)
    }
    $python = ($result[1] | Where-Object { $_ -like "python *" } | Select-Object -First 1) -replace "^python ", ""
    Ok "Python UDFs run on $Alias (Python $python)"
    if (-not $script:ExakitQuietDetail) {
        foreach ($line in @($result[1] | Where-Object { $_ -notlike "python *" })) {
            $parts = $line -split " ", 2
            Write-Host ("      {0,-24} {1}" -f $parts[0], $parts[1])
        }
    }
    Info "Use it in SQL: CREATE OR REPLACE $Alias SCALAR SCRIPT ..."
    Set-ExakitManifestValue "components.udf_devkit.validated" $true
    return $true
}

# Set-UdfFail - note why a setup step stopped, for the caller to turn into a
# refusal (the commands) or a warning (the persona install, which must not
# exit). Always $false. Twin of _udf_fail.
function Set-UdfFail {
    param([Parameter(Mandatory)][int]$Code, [Parameter(Mandatory)][string]$Step, [AllowEmptyString()][string]$Remedy = "",
          [Parameter(Mandatory)][string]$Message)
    $script:UdfFail = [pscustomobject]@{ Code = $Code; Step = $Step; Remedy = $Remedy; Message = $Message }
    if (Get-Command Write-ExakitLog -ErrorAction SilentlyContinue) { Write-ExakitLog "UDF" "$Step ($Code): $Message" }
    return $false
}

# Exit-UdfRefusal - stop with the exit code for what went wrong (AC-ML1.6): 2
# bad arguments, 3 a package the smoke UDF did not find, 4 no container for
# this database (language, arch or version) or a digest that did not match, 5
# not ready (the add-on, the database, the launcher, the download or the
# disk), 6 the launcher's install failed, 7 the smoke UDF did not pass or
# reported a version other than the pinned one. The JSON names the language
# and the step (select-container, download, verify, install, smoke) so an
# agent branches on both. No failure note: nothing of the install failed. Twin
# of _udf_refuse.
function Exit-UdfRefusal {
    param([Parameter(Mandatory)][int]$Code, [Parameter(Mandatory)][string]$Language, [Parameter(Mandatory)][string]$Step,
          [Parameter(Mandatory)][string]$Message, $Remedy = $null)
    if (Get-Command Write-ExakitLog -ErrorAction SilentlyContinue) { Write-ExakitLog "REFUSE" "udf $Language/$Step ($Code): $Message" }
    if ($script:ExakitRefusalJson) {
        Write-Output ([ordered]@{ ok = $false; language = $Language; step = $Step; reason = $Message; remedy = $Remedy } | ConvertTo-Json -Compress)
        exit $Code
    }
    Write-Host ""
    Write-Host ("  {0} {1}" -f $script:UiCross, $Message) -ForegroundColor Red
    if ($Remedy) { Write-Host "    Run: $Remedy" }
    exit $Code
}

# Exit-UdfLastFail - the refusal for the last Set-UdfFail. Twin of _udf_raise_fail.
function Exit-UdfLastFail {
    param([Parameter(Mandatory)][string]$Language)
    $f = $script:UdfFail
    if (-not $f) { $f = [pscustomobject]@{ Code = 1; Step = "install"; Remedy = ""; Message = "The step did not finish (see: exakit logs)." } }
    $remedy = $null
    if ($f.Remedy) { $remedy = $f.Remedy }
    Exit-UdfRefusal -Code $f.Code -Language $Language -Step $f.Step -Message $f.Message -Remedy $remedy
}

# Enable-UdfJson - --json: refusals and the answer as one object, detail to the log.
function Enable-UdfJson {
    $script:UdfJson = $true
    $script:ExakitRefusalJson = $true
    $script:ExakitQuietDetail = $true
}

# Write-UdfDone - the commands' success: with --json the object (the container
# from the selected row, the smoke UDF's lines as package and version);
# otherwise the steps have already said it. Twin of _udf_done.
function Write-UdfDone {
    param([Parameter(Mandatory)][string]$Language, [Parameter(Mandatory)][string]$Alias)
    if (-not $script:UdfJson) { return }
    $smoke = @()
    foreach ($line in @($script:UdfSmokeLines)) {
        $parts = "$line" -split " ", 2
        if ($parts[0]) { $smoke += [ordered]@{ package = $parts[0]; version = "" + $parts[1] } }
    }
    $c = $script:UdfContainer
    $container = [ordered]@{ url = $null; sha256 = $null; arch = $null; db_versions = $null }
    if ($c) {
        if ($c.url) { $container.url = "" + $c.url }
        if ($c.sha256) { $container.sha256 = "" + $c.sha256 }
        if ($c.DbArch) { $container.arch = "" + $c.DbArch }
        if ($c.db_versions) { $container.db_versions = "" + $c.db_versions }
    }
    Write-Output ([ordered]@{ ok = $true; language = $Language; alias = $Alias; container = $container; smoke = @($smoke) } | ConvertTo-Json -Compress -Depth 5)
}

# Get-UdfLanguageProblem - "" when the value is python or rust, else the reason.
function Get-UdfLanguageProblem {
    param([AllowEmptyString()][string]$Value)
    if ($Value -in @("python", "rust")) { return "" }
    return "The UDF language must be python or rust, not '$Value' (--language, or EXAKIT_UDF_LANGUAGE)."
}

# Get-UdfDbVersion - the running database's version, for the container matrix.
function Get-UdfDbVersion {
    $result = Invoke-UdfTool -ToolArgs @("dbversion")
    if ($result[0] -ne 0) { return "" }
    return ("" + @($result[1])[0]).Trim()
}

# Get-UdfOs - this machine as the matrix names it: darwin, linux or windows.
function Get-UdfOs {
    if ($env:OS -eq "Windows_NT") { return "windows" }
    if ($IsMacOS) { return "darwin" }
    if ($IsLinux) { return "linux" }
    return "windows"
}

# Get-UdfMachine - what `uname -m` says, or Windows' processor architecture.
function Get-UdfMachine {
    $uname = Get-Command uname -ErrorAction SilentlyContinue
    if ($uname -and (Get-UdfOs) -ne "windows") {
        try { return ("" + (& $uname.Source -m 2>$null)).Trim() } catch { }
    }
    return "" + $env:PROCESSOR_ARCHITECTURE
}

# Get-UdfArch - the DATABASE's architecture (x86_64 | aarch64), which is what a
# container is built for: the rule is in udf_tool.py; EXAKIT_UDF_ARCH
# overrides. @(ok, value or reason). Twin of _udf_arch.
function Get-UdfArch {
    $result = Invoke-UdfTool -NoConnection -ToolArgs @("arch", (Get-UdfMachine), (Get-UdfOs))
    if ($result[0] -ne 0) { return ,@($false, $result[2]) }
    return ,@($true, ("" + @($result[1])[0]).Trim())
}

# Get-UdfLauncherProblem - why the launcher cannot install containers, or "".
function Get-UdfLauncherProblem {
    $version = Get-PersonalLauncherVersion
    if (-not $version) { $version = "0" }
    if ((Invoke-UdfTool -NoConnection -ToolArgs @("atleast", $version, $script:UdfMinLauncher))[0] -eq 0) { return "" }
    return "The UDF dev kit needs Exasol launcher $($script:UdfMinLauncher) or later; this machine has $version. Update it with: exakit update personal"
}

# Test-UdfReady - the database running and the launcher able to install
# containers, or a Set-UdfFail (5) naming which. Twin of _udf_ready.
function Test-UdfReady {
    param([Parameter(Mandatory)][string]$Step)
    if (-not (Test-ExakitDbReachable)) { return (Set-UdfFail -Code 5 -Step $Step -Remedy "exakit start" -Message "The database is not running.") }
    $why = Get-UdfLauncherProblem
    if ($why) { return (Set-UdfFail -Code 5 -Step $Step -Remedy "exakit update personal" -Message $why) }
    return $true
}

# Select-UdfContainer - the matrix row for this language, the database's
# architecture and its version (udf_tool.py resolve) into UdfContainer, with
# DbArch and DbVersion added; a Set-UdfFail (4, step select-container) names what did
# not match. Twin of _udf_select_container.
function Select-UdfContainer {
    param([Parameter(Mandatory)][string]$Language)
    $script:UdfContainer = $null
    $doc = Resolve-ExakitVersionsDoc
    if (-not $doc) { return (Set-UdfFail -Code 4 -Step "select-container" -Remedy "exakit update" -Message "This kit copy has no readable versions.json to pick a container from.") }
    $arch = Get-UdfArch
    if (-not $arch[0]) { return (Set-UdfFail -Code 4 -Step "select-container" -Remedy "" -Message ("" + $arch[1])) }
    $db = Get-UdfDbVersion
    if (-not $db) { return (Set-UdfFail -Code 5 -Step "select-container" -Remedy "exakit status" -Message "The database version is not known: is the database running?") }
    $result = Invoke-UdfTool -NoConnection -ToolArgs @("resolve", $doc, $Language, $arch[1], $db)
    if ($result[0] -ne 0) {
        return (Set-UdfFail -Code 4 -Step "select-container" -Remedy "exakit update" -Message "No prebuilt $Language container fits this database ($($arch[1]), version $db): $($result[2]). A kit update may bring one.")
    }
    $row = (@($result[1]) -join "") | ConvertFrom-Json
    $row | Add-Member -NotePropertyName DbArch -NotePropertyValue $arch[1]
    $row | Add-Member -NotePropertyName DbVersion -NotePropertyValue $db
    $script:UdfContainer = $row
    Info "Container for $Language on $($arch[1]), database $($db): $(Split-Path -Leaf $row.url)"
    return $true
}

# Get-UdfContainerPins - the selected row's "name==version" pins (packages or crates).
function Get-UdfContainerPins {
    param([Parameter(Mandatory)][string]$Language)
    $c = $script:UdfContainer
    $result = Invoke-UdfTool -NoConnection -ToolArgs @("pins", (Resolve-ExakitVersionsDoc), $Language, $c.DbArch, $c.DbVersion)
    if ($result[0] -ne 0) { return @() }
    return @($result[1] | Where-Object { $_ } | ForEach-Object { $_ -replace " ", "==" })
}

# Get-UdfDownload - a release asset streamed to disk (WebClient, as
# Get-ExakitFile: Invoke-WebRequest on 5.1 buffers the whole response), three
# attempts; $false when it did not arrive, with no failure note.
function Get-UdfDownload {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Dest)
    try {
        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    } catch { }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $wc = New-Object System.Net.WebClient
            try {
                $wc.Proxy = [System.Net.WebRequest]::DefaultWebProxy
                if ($wc.Proxy) { $wc.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials }
                $wc.Headers.Add("User-Agent", "exakit")
                $wc.DownloadFile($Url, $Dest)
            } finally { $wc.Dispose() }
            return $true
        } catch {
            Remove-Item -Force $Dest -ErrorAction SilentlyContinue
            if (Get-Command Write-ExakitLog -ErrorAction SilentlyContinue) { Write-ExakitLog "WARN" "Download attempt $attempt failed: $Url ($_)" }
            if ($attempt -lt 3) { Start-Sleep -Seconds (5 * $attempt) }
        }
    }
    return $false
}

# Get-UdfContainerFile - the selected row's tarball into the cache
# (UdfContainerFile), verified against its pinned size and sha256 before
# anything installs it: a cached file that verifies is reused; otherwise it is
# downloaded or copied from EXAKIT_UDF_CONTAINERS_MIRROR (a folder, file:// or
# https:// base URL holding the file by name) into a .part that is renamed
# only once it verifies. A mismatch is Set-UdfFail 4 (step verify) and the
# file is removed, so running the command again downloads it afresh; a
# download that did not arrive is 5 (step download). Twin of
# _udf_fetch_container.
function Get-UdfContainerFile {
    param([Parameter(Mandatory)][string]$Language)
    $c = $script:UdfContainer
    $name = Split-Path -Leaf ("" + $c.url)
    $script:UdfContainerFile = Join-Path $script:UdfContainerCache $name
    try { New-Item -ItemType Directory -Force -Path $script:UdfContainerCache -ErrorAction Stop | Out-Null } catch {
        return (Set-UdfFail -Code 5 -Step "download" -Remedy "" -Message "Could not create the container cache $($script:UdfContainerCache).")
    }
    $verifyArgs = @("verify", $script:UdfContainerFile, ("" + $c.sha256), ("" + $c.size))
    if ((Test-Path $script:UdfContainerFile -PathType Leaf) -and (Invoke-UdfTool -NoConnection -ToolArgs $verifyArgs)[0] -eq 0) {
        Ok "Using the cached container $($script:UdfContainerFile) (digest verified)"
        return $true
    }
    $source = "" + $c.url
    $local = ""
    $mirror = $env:EXAKIT_UDF_CONTAINERS_MIRROR
    if ($mirror) {
        if ($mirror -match '^https://') {
            $source = $mirror.TrimEnd('/') + "/" + $name
        } elseif ($mirror -match '^file://') {
            $local = $mirror.Substring(7)
            # file:///C:/x reads as /C:/x; the drive letter is the path.
            if ($local -match '^/[A-Za-z]:') { $local = $local.Substring(1) }
            $local = Join-Path $local.TrimEnd('/', '\') $name
            $source = $local
        } elseif ($mirror -match '^[A-Za-z][A-Za-z0-9+.-]*://') {
            return (Set-UdfFail -Code 5 -Step "download" -Remedy "" -Message "EXAKIT_UDF_CONTAINERS_MIRROR must be a folder, a file:// URL or an https:// URL (got '$mirror').")
        } else {
            $local = Join-Path $mirror.TrimEnd('/', '\') $name
            $source = $local
        }
    }
    $mb = "{0} MB" -f [math]::Floor([double]$c.size / 1000000)
    $part = "$($script:UdfContainerFile).part"
    Remove-Item -Force $script:UdfContainerFile, $part -ErrorAction SilentlyContinue
    if ($local) {
        Info "Copying the $Language container ($mb) from $local"
        try { Copy-Item -LiteralPath $local -Destination $part -Force -ErrorAction Stop } catch {
            Remove-Item -Force $part -ErrorAction SilentlyContinue
            return (Set-UdfFail -Code 5 -Step "download" -Remedy "" -Message "The container $name is not in EXAKIT_UDF_CONTAINERS_MIRROR ($local).")
        }
    } else {
        Info "Downloading the $Language container ($mb, checked against its SHA-256) from $source"
        $script:ExakitActiveLabel = "Downloading the $Language container ($mb)"
        $got = Get-UdfDownload -Url $source -Dest $part
        $script:ExakitActiveLabel = ""
        if (-not $got) {
            return (Set-UdfFail -Code 5 -Step "download" -Remedy "exakit udf-use default" -Message "The container could not be downloaded from $source. Retry when online, or set EXAKIT_UDF_CONTAINERS_MIRROR to a folder or URL holding $name.")
        }
    }
    $verified = Invoke-UdfTool -NoConnection -ToolArgs @("verify", $part, ("" + $c.sha256), ("" + $c.size))
    if ($verified[0] -ne 0) {
        Remove-Item -Force $part -ErrorAction SilentlyContinue
        return (Set-UdfFail -Code 4 -Step "verify" -Remedy "exakit udf-use default" -Message "The container $name does not match its pinned digest ($($verified[2])); it was removed. Run this again to download it afresh; if it fails again the release asset changed and the kit needs an update.")
    }
    Move-Item -LiteralPath $part -Destination $script:UdfContainerFile -Force
    $short = ("" + $c.sha256).Substring(0, 12)
    Ok "Verified $name (sha256 $short..., $($c.size) bytes)"
    return $true
}

# Add-UdfLanguage - components.udf_devkit.languages, a comma list, each
# language once. Twin of _udf_record_language.
function Add-UdfLanguage {
    param([Parameter(Mandatory)][string]$Language)
    $have = "" + (Get-ExakitManifestValue "components.udf_devkit.languages")
    if (@($have -split ",") -contains $Language) { return }
    if ($have) { Set-ExakitManifestValue "components.udf_devkit.languages" "$have,$Language" }
    else { Set-ExakitManifestValue "components.udf_devkit.languages" $Language }
}

# Invoke-UdfWithRestart - confirm, stop the running add-on services, run the
# install, wait for the database, start the services again. Twin of
# _udf_with_restart.
function Invoke-UdfWithRestart {
    param([Parameter(Mandatory)][string]$What, [Parameter(Mandatory)][scriptblock]$Action)
    $script:UdfDeclined = $false
    if (-not $script:UdfYes -and -not (Confirm-ExakitPrompt "$What restarts the database (running add-ons are stopped and started again). Continue" $true)) {
        Info "$What was not started; nothing changed."
        $script:UdfDeclined = $true
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

# Install-UdfDevkitOfficial - the official Python container when it is missing
# (or forced), then the smoke UDF. $false with UdfFail set. Twin of
# udf_devkit_setup_container.
function Install-UdfDevkitOfficial {
    param([bool]$Force = $false)
    $script:UdfContainer = $null
    $arch = Get-UdfArch
    if ($arch[0]) { $script:UdfContainer = [pscustomobject]@{ url = ""; sha256 = ""; db_versions = ""; DbArch = $arch[1] } }
    if (-not (Test-UdfReady -Step "install")) { return $false }
    if ($Force -or -not (@(Get-UdfDevkitInstalledAliases) -contains $script:UdfOfficialAlias)) {
        $done = Invoke-UdfWithRestart -What "Installing the official $($script:UdfOfficialAlias) container" -Action {
            (Invoke-UdfSlc -SlcArgs @("install", $script:UdfOfficialAlias, "--auto-approve"))[0] -eq 0 }
        if (-not $done) {
            if ($script:UdfDeclined) { return (Set-UdfFail -Code 5 -Step "install" -Remedy "exakit udf-setup --yes" -Message "The install was not confirmed; nothing changed.") }
            return (Set-UdfFail -Code 6 -Step "install" -Remedy "exakit logs" -Message "The launcher could not install the $($script:UdfOfficialAlias) container (see: exakit logs).")
        }
    } else {
        Ok "The official $($script:UdfOfficialAlias) container is already installed"
    }
    if (-not (Test-UdfDevkitSmoke -Alias $script:UdfOfficialAlias)) { return $false }
    Add-UdfLanguage "python"
    return $true
}

# Install-UdfDevkitDefault - the prebuilt Python container of the matrix for
# this database (ML1.2): select, download or reuse the cache, verify, install
# as PYTHON3_ML, and the smoke UDF compares each package's version with the
# pin. $false with UdfFail set. Twin of udf_devkit_setup_default.
function Install-UdfDevkitDefault {
    if (-not (Test-UdfReady -Step "select-container")) { return $false }
    if (-not (Select-UdfContainer -Language "python")) { return $false }
    if (-not (Get-UdfContainerFile -Language "python")) { return $false }
    $pins = Get-UdfContainerPins -Language "python"
    if (-not (Install-UdfTarball -Tarball $script:UdfContainerFile -Alias $script:UdfDefaultAlias -Language "python" -Source ("" + $script:UdfContainer.url) -Packages $pins)) { return $false }
    Add-UdfLanguage "python"
    return $true
}

# Install-UdfDevkitRust - the Rust container of the matrix (alias RUST): the
# same select, download, verify and launcher install, through the restart. No
# smoke UDF yet: it arrives with the next kit step, so the add-on is recorded
# as not validated until then. $false with UdfFail set. Twin of
# udf_devkit_setup_rust.
function Install-UdfDevkitRust {
    if (-not (Test-UdfReady -Step "select-container")) { return $false }
    if (-not (Select-UdfContainer -Language "rust")) { return $false }
    if (-not (Get-UdfContainerFile -Language "rust")) { return $false }
    $verb = "install"
    if (@(Get-UdfDevkitInstalledAliases) -contains $script:UdfRustAlias) { $verb = "update" }
    $file = $script:UdfContainerFile
    $done = Invoke-UdfWithRestart -What "Installing the $($script:UdfRustAlias) container" -Action {
        (Invoke-UdfSlc -SlcArgs @("custom", $verb, "--source", $file, "--alias", $script:UdfRustAlias, "--language", "rust", "--auto-approve"))[0] -eq 0 }
    if (-not $done) {
        if ($script:UdfDeclined) { return (Set-UdfFail -Code 5 -Step "install" -Remedy "exakit udf-setup --language rust --yes" -Message "The install was not confirmed; nothing changed.") }
        return (Set-UdfFail -Code 6 -Step "install" -Remedy "exakit logs" -Message "The launcher could not install the $($script:UdfRustAlias) container (see: exakit logs).")
    }
    Set-ExakitManifestValue "components.udf_devkit.containers.$($script:UdfRustAlias)" ("" + $script:UdfContainer.url)
    Add-UdfLanguage "rust"
    Set-ExakitManifestValue "components.udf_devkit.validated" $false
    $script:UdfSmokeLines = @()
    $sdk = (@(Get-UdfContainerPins -Language "rust") | Where-Object { $_ -like "exasol-udf-sdk==*" } | Select-Object -First 1) -replace "^.*==", ""
    Ok "Rust UDFs: the $($script:UdfRustAlias) container is installed (rustc $($script:UdfContainer.runtime.rustc), exasol-udf-sdk $sdk)"
    Info "The Rust smoke UDF arrives with the next kit step; until then: exasol slc list shows $($script:UdfRustAlias)"
    return $true
}

function Install-UdfDevkit {
    if (-not $script:UdfDevkitVersion) { $script:UdfDevkitVersion = Get-UdfDevkitLatest }
    if (-not (Test-UdfDevkitLauncher)) {
        Set-ExakitFailureReason "the Exasol launcher is older than $($script:UdfMinLauncher)"
        return $false
    }
    # EXAKIT_UDF_LANGUAGE picks what the install sets up; a value that is
    # neither language is refused before anything is recorded.
    $problem = Get-UdfLanguageProblem $script:UdfLanguage
    if ($problem) {
        Warn2 $problem
        Set-ExakitFailureReason "EXAKIT_UDF_LANGUAGE is not python or rust"
        return $false
    }
    Set-ExakitManifestValue "components.udf_devkit.version" $script:UdfDevkitVersion
    Set-ExakitManifestValue "components.udf_devkit.schema" $script:UdfSchema
    # The container is part of the install; with no database up, it is the
    # first thing `exakit udf-setup` does.
    if (-not (Test-ExakitDbReachable)) {
        Info "Start the database, then set up $($script:UdfLanguage) UDFs with: exakit udf-setup --language $($script:UdfLanguage)"
        return $true
    }
    $script:UdfYes = $true
    try {
        if ($script:UdfLanguage -eq "rust") {
            if (-not (Install-UdfDevkitRust)) { Warn2 "Rust UDFs are not set up yet ($($script:UdfFail.Message)) - run: exakit udf-setup --language rust" }
        } elseif (-not (Install-UdfDevkitOfficial)) { Warn2 "Python UDFs are not set up yet - run: exakit udf-setup" }
    } finally { $script:UdfYes = $false }
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

function Get-UdfDevkitSummary {
    $languages = @(("" + (Get-ExakitManifestValue "components.udf_devkit.languages")) -split ",")
    if ($languages -contains "rust") { return "Python UDFs: exakit udf-setup; Rust UDFs: alias $($script:UdfRustAlias) (exasol slc list)" }
    return "Python UDFs: exakit udf-setup"
}

function Uninstall-UdfDevkit {
    param([switch]$DryRun)
    if ($DryRun) {
        if (Test-Path $script:UdfDevkitHome) { Info "  will remove: $($script:UdfDevkitHome)" }
        Info "  containers stay installed in the database (exasol slc remove <alias> removes one)"
        Info "  model files stay in the deployment's bucket directory; only their record goes"
        return $true
    }
    if (Get-Command Stop-UdfDevkit -ErrorAction SilentlyContinue) { Stop-UdfDevkit }
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $script:UdfDevkitHome
    Remove-ExakitManifestValue "components.udf_devkit"
    Remove-ExakitManifestValue "desired.udf_devkit"
    Info "Containers stay installed in the database; remove one with: exasol slc remove <alias> ($($script:UdfDefaultAlias), $($script:UdfBuildAlias), $($script:UdfRustAlias))"
    OkStep "udf-devkit removed - reinstall any time with: exakit marketplace udf-devkit"
    return $true
}

# --- the commands ------------------------------------------------------------------

function Assert-UdfDevkitInstalled {
    if (-not (Get-UdfDevkitInstalledVersion)) { Fail "The UDF dev kit is not installed. Install it with: exakit marketplace udf-devkit" }
}

function Get-UdfIdentifier {
    param([string]$Name)
    $result = Invoke-UdfTool -NoConnection -ToolArgs @("identifier", $Name)
    if ($result[0] -ne 0) { Deny-ExakitInput $result[2] }
    return @($result[1])[0]
}

# Assert-UdfDevkitInstalledFor - the udf-setup and udf-use form of the check: a
# refusal (5, step select-container) with the marketplace as remedy.
function Assert-UdfDevkitInstalledFor {
    param([Parameter(Mandatory)][string]$Language)
    if (-not (Get-UdfDevkitInstalledVersion)) {
        Exit-UdfRefusal -Code 5 -Language $Language -Step "select-container" -Message "The UDF dev kit is not installed." -Remedy "exakit marketplace udf-devkit"
    }
}

# Install-UdfTarball - the launcher installs (or updates) the container under
# the alias through the restart, the smoke UDF proves it (Python; a Rust
# container has no smoke UDF yet and is recorded as not validated), and the
# alias is recorded with where the container came from. $false with UdfFail
# set. Twin of _udf_install_tarball.
function Install-UdfTarball {
    param([string]$Tarball, [string]$Alias, [string]$Language, [string]$Source, [string[]]$Packages = @())
    $verb = if (@(Get-UdfDevkitInstalledAliases) -contains $Alias) { "update" } else { "install" }
    $done = Invoke-UdfWithRestart -What "Installing the container as $Alias" -Action {
        (Invoke-UdfSlc -SlcArgs @("custom", $verb, "--source", $Tarball, "--alias", $Alias, "--language", $Language, "--auto-approve"))[0] -eq 0 }
    if (-not $done) {
        if ($script:UdfDeclined) { return (Set-UdfFail -Code 5 -Step "install" -Remedy "" -Message "The install was not confirmed; nothing changed.") }
        return (Set-UdfFail -Code 6 -Step "install" -Remedy "exakit logs" -Message "The launcher could not install the container as $Alias (see: exakit logs).")
    }
    if ($Language -eq "rust") {
        Set-ExakitManifestValue "components.udf_devkit.validated" $false
        $script:UdfSmokeLines = @()
        Info "The Rust smoke UDF arrives with the next kit step; until then: exasol slc list shows $Alias"
    } elseif (-not (Test-UdfDevkitSmoke -Alias $Alias -Packages $Packages)) { return $false }
    Set-ExakitManifestValue "components.udf_devkit.containers.$Alias" $Source
    return $true
}

# Invoke-CmdUdfSetup [--language python|rust] [--force] [--yes] [--json] - the
# official Python container (PYTHON3) or the matrix's Rust container (RUST).
function Invoke-CmdUdfSetup {
    param([string[]]$CmdArgs = @())
    $force = $false; $language = $script:UdfLanguage; $json = $false
    for ($i = 0; $i -lt $CmdArgs.Count; $i++) {
        $arg = $CmdArgs[$i]
        if ($arg -eq "--force") { $force = $true }
        elseif ($arg -in @("--yes", "-y")) { $script:UdfYes = $true }
        elseif ($arg -in @("--json", "-j")) { $json = $true; $script:ExakitRefusalJson = $true }
        elseif ($arg -eq "--language") { $i++; if ($i -ge $CmdArgs.Count) { Deny-ExakitInput "--language needs python or rust" }; $language = $CmdArgs[$i] }
        else { Deny-ExakitInput "udf-setup takes --force (reinstall the container), --language python|rust, --yes and --json, nothing else: $arg" }
    }
    $problem = Get-UdfLanguageProblem $language
    if ($problem) { Deny-ExakitInput $problem }
    if ($json) { Enable-UdfJson }
    Assert-UdfDevkitInstalledFor -Language $language
    if ($language -eq "rust") {
        if (-not (Install-UdfDevkitRust)) { Exit-UdfLastFail -Language "rust" }
        Write-UdfDone -Language "rust" -Alias $script:UdfRustAlias
    } else {
        if (-not (Install-UdfDevkitOfficial -Force $force)) { Exit-UdfLastFail -Language "python" }
        Write-UdfDone -Language "python" -Alias $script:UdfOfficialAlias
    }
}

# Invoke-CmdUdfUse default|<container.tar.gz> [--language python|rust] [--alias
# NAME] [--yes] [--json] | --list - default is the matrix's container for this
# database (Python: PYTHON3_ML; rust: RUST); a tarball is yours.
function Invoke-CmdUdfUse {
    param([string[]]$CmdArgs = @())
    $what = ""; $alias = ""; $list = $false; $language = $script:UdfLanguage; $json = $false
    for ($i = 0; $i -lt $CmdArgs.Count; $i++) {
        $arg = $CmdArgs[$i]
        if ($arg -eq "--list") { $list = $true }
        elseif ($arg -in @("--yes", "-y")) { $script:UdfYes = $true }
        elseif ($arg -in @("--json", "-j")) { $json = $true; $script:ExakitRefusalJson = $true }
        elseif ($arg -eq "--alias") { $i++; if ($i -ge $CmdArgs.Count) { Deny-ExakitInput "--alias needs a name" }; $alias = $CmdArgs[$i] }
        elseif ($arg -eq "--language") { $i++; if ($i -ge $CmdArgs.Count) { Deny-ExakitInput "--language needs python or rust" }; $language = $CmdArgs[$i] }
        elseif ($arg.StartsWith("-")) { Deny-ExakitInput "Unknown option for udf-use: $arg (supported: --alias, --language, --list, --yes, --json)" }
        elseif ($what) { Deny-ExakitInput "Name one thing to install: default, or one container tarball" }
        else { $what = $arg }
    }
    $problem = Get-UdfLanguageProblem $language
    if ($problem) { Deny-ExakitInput $problem }
    if ($list) {
        Assert-UdfDevkitInstalled
        (Invoke-UdfSlc -SlcArgs @("list"))[1] | ForEach-Object { Write-Host $_ }
        return
    }
    if (-not $what) { Deny-ExakitInput "Name what to install: exakit udf-use default, or exakit udf-use <container.tar.gz>." }
    if ($what -ne "default") {
        if (-not ($what.EndsWith(".tar.gz") -or $what.EndsWith(".tgz"))) { Deny-ExakitInput "$what is not a container tarball (.tar.gz)." }
        if (-not (Test-Path $what -PathType Leaf)) { Deny-ExakitInput "$what is not a file." }
        if (-not $alias) { $alias = $script:UdfBuildAlias }
        $alias = Get-UdfIdentifier $alias
    }
    if ($json) { Enable-UdfJson }
    Assert-UdfDevkitInstalledFor -Language $language
    if ($what -eq "default") {
        if ($language -eq "rust") {
            if (-not (Install-UdfDevkitRust)) { Exit-UdfLastFail -Language "rust" }
            Write-UdfDone -Language "rust" -Alias $script:UdfRustAlias
        } else {
            if (-not (Install-UdfDevkitDefault)) { Exit-UdfLastFail -Language "python" }
            Write-UdfDone -Language "python" -Alias $script:UdfDefaultAlias
        }
        return
    }
    $script:UdfContainer = $null
    $arch = Get-UdfArch
    if ($arch[0]) { $script:UdfContainer = [pscustomobject]@{ url = ""; sha256 = ""; db_versions = ""; DbArch = $arch[1] } }
    if (-not (Test-UdfReady -Step "install")) { Exit-UdfLastFail -Language $language }
    if (-not (Install-UdfTarball -Tarball (Resolve-Path $what).Path -Alias $alias -Language $language -Source $what)) { Exit-UdfLastFail -Language $language }
    Write-UdfDone -Language $language -Alias $alias
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
    if (-not (Install-UdfTarball -Tarball $tarball -Alias $alias -Language "python" -Source $req -Packages @($packages | ForEach-Object { $_[0] }))) {
        if ($script:UdfFail.Step -ne "smoke") { Fail $script:UdfFail.Message }
    }
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
        foreach ($each in @("put", "list", "rm", "template")) { Show-ExakitHelpCommand -Name "exakit model $each" | Out-Null }
        return
    }
    if ($sub -in @("put", "list", "rm", "template") -and ($rest -contains "--help" -or $rest -contains "-h")) {
        Show-ExakitHelpCommand -Name "exakit model $sub" | Out-Null; return
    }
    switch ($sub) {
        "put"      { Invoke-CmdModelPut -CmdArgs $rest }
        "list"     { Invoke-CmdModelList -CmdArgs $rest }
        "rm"       { Invoke-CmdModelRm -CmdArgs $rest }
        "template" { Invoke-CmdModelTemplate -CmdArgs $rest }
        ""         { Deny-ExakitInput "Name what to do: exakit model put <file> | exakit model list | exakit model rm <name> | exakit model template (exakit model --help)." }
        default    { Deny-ExakitInput "Unknown model command '$sub' (supported: put, list, rm, template)." }
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
    if ($result[0] -eq 6) { Exit-UdfModel -Code 6 -Message $result[2] }
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
    if ($answer.warning) { Info "Warning: $($answer.warning)" }
}

function Invoke-CmdModelRm {
    param([string[]]$CmdArgs = @())
    $name = ""; $json = $false
    foreach ($arg in $CmdArgs) {
        if ($arg -in @("--json", "-j")) { $json = $true; $script:ExakitRefusalJson = $true }
        elseif ($arg.StartsWith("-")) { Deny-ExakitInput "Unknown option '$arg' for model rm (supported: --json)." }
        elseif ($name) { Deny-ExakitInput "Name one model: exakit model rm <name>" }
        else { $name = $arg }
    }
    if (-not $name) { Deny-ExakitInput "Name the model: exakit model rm <name>" }
    $bucket = Assert-UdfModelReady
    $result = Invoke-UdfTool -Script "model_tool.py" -NoConnection -StdIn (Get-UdfModelRecord) `
        -ToolArgs @("rm", $name, $bucket.Dir, $bucket.UdfRoot)
    if ($result[0] -eq 5) { Exit-UdfModel -Code 5 -Message $result[2] }
    if ($result[0] -eq 2) { Deny-ExakitInput $result[2] }
    if ($result[0] -ne 0) { Fail "Could not remove $name`: $($result[2])" }
    $lines = @($result[1])
    Set-ExakitManifestValue "components.udf_devkit.models" ($lines[1] | ConvertFrom-Json)
    if ($json) { Write-Output $lines[0] }
    else { Ok "Removed $name from the bucket directory and the kit's record" }
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
