#!/usr/bin/env pwsh
# udf-devkit-addon-ps.ps1 - the Windows twin of tests/udf-devkit-addon.sh: the
# udf-devkit add-on's own behaviour in setup/lib/udf-devkit.ps1 (read that
# test's header for what is pinned). Runs under Windows PowerShell 5.1 and
# pwsh; a sandboxed kit home and deployment folder, the launcher, the services
# and the refusals stubbed, a test copy of versions.json whose rows point at a
# tiny fake tarball in a mirror folder; no database.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-udf-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:EXAKIT_HOME = Join-Path $work "home"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
. (Join-Path $repo "setup/lib/exakit-common.ps1")
. (Join-Path $repo "setup/lib/udf-devkit.ps1")
$script:realGetExakitVersionsBakedPath = ${function:Get-ExakitVersionsBakedPath}
function Get-ExakitVersionsBakedPath {
    if ($script:VersionsDocPath) { return $script:VersionsDocPath }
    return (& $script:realGetExakitVersionsBakedPath)
}
$script:LogFile = $null
$script:PersonalDeployDir = Join-Path $work "deployment"
New-Item -ItemType Directory -Force -Path (Join-Path $script:PersonalDeployDir "local\runtime\exa\bucketfs") | Out-Null
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$expected>, got <$actual>" }
}
function Contains($label, $needle, $haystack) {
    if ("$haystack".Contains($needle)) { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): <$needle> not in <$haystack>" }
}
# The machine, stubbed at the module's seams.
function Fail([string]$Msg) { throw "FAIL: $Msg" }
$script:calls = New-Object System.Collections.ArrayList
$script:launcher = "2.3.0"
$script:confirmAnswer = $true
function Get-PersonalLauncherVersion { return $script:launcher }
function Get-PersonalCli { return "test-launcher" }
function Test-ExakitDbReachable { return $true }
function Wait-PersonalReady { [void]$script:calls.Add("wait") }
function Get-ExakitServiceIds { return @("database", "dash-server", "exasol-scheduler") }
function Get-ExakitServiceStatus($id) { if ($id -eq "dash-server") { return "running" } return "stopped" }
function Stop-ExakitService($id) { [void]$script:calls.Add("stop $id") }
function Start-ExakitService($id) { [void]$script:calls.Add("start $id") }
function Confirm-ExakitPrompt { return $script:confirmAnswer }
function Test-UdfDevkitSmoke {
    param([string]$Alias, [string[]]$Packages = @())
    [void]$script:calls.Add(("smoke $Alias " + ($Packages -join " ")).TrimEnd())
    $script:UdfSmokeLines = @("python 3.12.3", "scikit-learn 1.9.0", "numpy 2.4.6")
    return $true
}
# A refusal is read as its code, language and step; the JSON shape of the real
# function is checked once through a child PowerShell below.
function Exit-UdfRefusal {
    param([int]$Code, [string]$Language, [string]$Step, [string]$Message, $Remedy = $null)
    throw "EXIT $($Code): $Language/$($Step): $Message | $Remedy"
}
function Get-UdfDbVersion { return $script:dbVersion }
# The Rust smoke UDF needs a database: its tool call is recorded and answered
# with what the kit library reports (stubRustc: the rustc it was built with;
# stubRustLoadError: the database refused it); every other tool call is real.
$script:stubRustc = "1.98.1"
$script:stubRustLoadError = ""
$script:packagedSmoke = $false
$script:realInvokeUdfTool = ${function:Invoke-UdfTool}
function Invoke-UdfTool {
    param([string[]]$ToolArgs, [string]$StdIn = "", [string]$Python = "", [string]$Script = "udf_tool.py", [switch]$NoConnection)
    if ($Script -eq "rust_container.py") {
        if ($ToolArgs[0] -eq "check") {
            if ($script:packagedSmoke) { return ,@(0, @(), "") }
            return ,@(1, @(), "")
        }
        if (-not $NoConnection -or $ToolArgs.Count -ne 7 -or $ToolArgs[1] -ne $script:UdfSmokeAsset.sha256) {
            throw "The fallback must use the verified smoke digest without database credentials."
        }
        [void]$script:calls.Add("pack-rust")
        $script:packagedSmoke = $true
        return ,@(0, @('{"ok":true}'), "")
    }
    if ($ToolArgs[0] -eq "bucket-file") { return ,@(0, @(), "") }
    if ($ToolArgs[0] -eq "smoke-rust") {
        [void]$script:calls.Add("smoke-rust " + ($ToolArgs -join " "))
        if ($script:stubRustLoadError) { return ,@(7, @(), $script:stubRustLoadError) }
        $lines = @("container RUST", "rustc $($script:stubRustc)", "sdk 0.33.0", "rustc_full rustc $($script:stubRustc) (48a229cea 2026-09-01)")
        if ($script:stubRustc -ne "1.98.1") { return ,@(7, $lines, "rustc reported $($script:stubRustc), pinned 1.98.1") }
        return ,@(0, $lines, "")
    }
    return (& $script:realInvokeUdfTool @PSBoundParameters)
}
$script:dbVersion = "2026.2.0-nano.3"
function Invoke-UdfSlc {
    param([string[]]$SlcArgs)
    if ($SlcArgs[0] -eq "list") { return ,@(0, @('[{"alias": "PYTHON3", "installed": false}]')) }
    [void]$script:calls.Add("launcher slc $($SlcArgs -join ' ')")
    return ,@(0, @())
}
function Prepare-UdfMlContainer { $script:UdfContainerInstallFile = $script:UdfContainerFile; return $true }
function Reset-Calls { $script:calls.Clear() }

try {
    Initialize-ExakitManifest | Out-Null
    Set-ExakitManifestValue "components.udf_devkit.version" "0.1.0"
    Write-Host "a container install is confirmed, and the services follow the restart:"
    Reset-Calls
    Invoke-CmdUdfSetup
    Check "stop, install, wait, start, smoke - in that order" "stop dash-server|launcher slc install PYTHON3 --auto-approve|wait|start dash-server|smoke PYTHON3" ($script:calls -join "|")
    Check "the language is recorded" "python" (Get-ExakitManifestValue "components.udf_devkit.languages")
    Reset-Calls
    $script:confirmAnswer = $false
    $said = ""
    try { Invoke-CmdUdfSetup } catch { $said = "$_" }
    Contains "a decline is exit 5, step install" "EXIT 5: python/install: The install was not confirmed" $said
    Check "and installs nothing, stops nothing" "" ($script:calls -join "|")
    $script:confirmAnswer = $true

    Write-Host "an old launcher is refused first:"
    Reset-Calls
    $script:launcher = "2.2.0"
    $said = ""
    try { Invoke-CmdUdfSetup } catch { $said = "$_" }
    Contains "exit 5 with the remedy" "EXIT 5: python/install: The UDF dev kit needs Exasol launcher 2.3.0 or later; this machine has 2.2.0" $said
    Contains "naming the remedy" "exakit update personal" $said
    Check "and runs nothing" "" ($script:calls -join "|")
    $script:launcher = "2.3.0"

    Write-Host "udf-file copies into the bucket and names the UDF path:"
    $model = Join-Path $work "model.pkl"
    Set-Content -Path $model -Value "weights" -NoNewline
    Invoke-CmdUdfFile -CmdArgs @($model, "models/m.pkl")
    $dest = Join-Path $script:PersonalDeployDir "local\runtime\exa\bucketfs\bfsdefault\default\models\m.pkl"
    Check "the file is in the bucket" "weights" (Get-Content -Raw $dest)
    $said = ""
    try { Invoke-CmdUdfFile -CmdArgs @($model, "../escape.pkl") } catch { $said = "$_" }
    Contains "never outside the bucket" "not a path inside the bucket" $said

    Write-Host "an internal SLC mapping keeps the default directory bucket usable:"
    $conf = Join-Path $script:PersonalDeployDir "local/runtime/exa/bucketfs.conf"
    Set-Content $conf "/exa/slc __builtin__ slc /exa/slc internal"
    $location = Get-UdfBucketLocation
    Check "internal-only configuration uses the default directory mapping" "default /buckets/bfsdefault/default " "$($location.Mapping) $($location.UdfRoot) $($location.Error)"
    Set-Content $conf "/exa/other other bucket /buckets/other/bucket internal"
    Contains "an explicit different bucket is still refused" "maps no bucket" (Get-UdfBucketLocation).Error
    Remove-Item $conf

    Write-Host "the commands refuse what they do not know:"
    function Deny-ExakitInput { param([string]$Message, $Remedy = $null) throw "EXIT 2: $Message" }
    foreach ($case in @(@{ Fn = "Invoke-CmdUdfUse"; Args = @("default", "--language", "frob"); Needle = "EXIT 2: The UDF language must be python or rust, not 'frob'" },
                        @{ Fn = "Invoke-CmdUdfUse"; Args = @("nope.zip"); Needle = "is not a container tarball" },
                        @{ Fn = "Invoke-CmdUdfSetup"; Args = @("--frob"); Needle = "takes --force" })) {
        $said = ""
        try { & $case.Fn -CmdArgs $case.Args } catch { $said = "$_" }
        Contains "$($case.Fn) $($case.Args -join ' ')" $case.Needle $said
    }
    $req = Join-Path $work "req.txt"
    Set-Content -Path $req -Value "numpy>=1"
    $said = ""
    try { Invoke-CmdUdfBuild -CmdArgs @($req) } catch { $said = "$_" }
    Contains "udf-build refuses an unpinned package before anything heavy" "not pinned" $said
    Write-Host "udf-build checks the container engine before it starts (AC-ML1.3):"
    $pinnedReq = Join-Path $work "pinned.txt"
    Set-Content -Path $pinnedReq -Value "numpy==1.26.4"
    function Get-NotebookInstalledVersion { return "1.0.0" }
    function Get-NotebookUv { throw "preflight passed" }
    foreach ($case in @(@{ Runtime = ""; Needle = "needs a running container engine, Docker or Podman, and none answers" },
                        @{ Runtime = "podman-no-api"; Needle = "Podman answers, but not its Docker-compatible API" },
                        @{ Runtime = "podman"; Needle = "preflight passed" },
                        @{ Runtime = "docker"; Needle = "preflight passed" })) {
        $script:stubRuntime = $case.Runtime
        function Find-UdfContainerRuntime { return $script:stubRuntime }
        $said = ""
        try { Invoke-CmdUdfBuild -CmdArgs @($pinnedReq) } catch { $said = "$_" }
        if ($case.Needle -eq "preflight passed" -and $said -like "*GB free*") { $said = "preflight passed (stopped at the disk check)" }
        Contains "engine '$($case.Runtime)'" $case.Needle $said
    }

    Write-Host "the install itself is refused on an old launcher (ML-1 preflight):"
    Remove-ExakitManifestValue "components.udf_devkit"
    $script:launcher = "2.2.9"
    Reset-Calls
    Check "the install fails" "False" (Install-UdfDevkit)
    Check "nothing is recorded" "" (Get-ExakitManifestValue "components.udf_devkit.version")
    Check "and nothing runs" "" ($script:calls -join "|")
    $script:launcher = "2.3.0"

    Remove-ExakitManifestValue "components.udf_devkit"
    $said = ""
    try { Invoke-CmdUdfSetup } catch { $said = "$_" }
    Contains "not installed names the marketplace" "exakit marketplace udf-devkit" $said
    Contains "as exit 5" "EXIT 5:" $said

    Write-Host "udf-use default: the matrix row for this database, verified before it is installed (AC-ML1.2):"
    Set-ExakitManifestValue "components.udf_devkit.version" "0.1.0"
    $mirror = Join-Path $work "mirror"
    New-Item -ItemType Directory -Force -Path $mirror | Out-Null
    $pyFake = Join-Path $mirror "py-fake.tar.gz"
    $rsFake = Join-Path $mirror "lc-rust-fake.tar.gz"
    [System.IO.File]::WriteAllText($pyFake, "fake python container")
    [System.IO.File]::WriteAllText($rsFake, "fake rust container")
    foreach ($a in @("x86_64", "aarch64")) { [System.IO.File]::WriteAllText((Join-Path $mirror "libexakit_smoke-$a.so"), "fake rust smoke $a") }
    $pySha = (Get-FileHash -Path $pyFake -Algorithm SHA256).Hash.ToLowerInvariant()
    $rsSha = (Get-FileHash -Path $rsFake -Algorithm SHA256).Hash.ToLowerInvariant()
    # A test copy of the kit's versions.json: the same document, its container
    # rows replaced by ones that point at the fake tarballs (sha256 and size
    # real); the Rust rows' smoke_asset points at the fake smoke library of the
    # arch (SmokeMode: ok, bad = a wrong sha256, placeholder = the pre-CI ones).
    function New-Matrix($Path, $PythonSha, $Arches, $SmokeMode = "ok") {
        $doc = Get-Content -Raw (Join-Path $repo "versions.json") | ConvertFrom-Json
        $rows = @()
        foreach ($arch in $Arches) {
            $rows += [ordered]@{ language = "python"; alias = "PYTHON3_ML"; kind = "prebuilt"; arch = $arch; db_versions = ">=2026.1"
                                 runtime = [ordered]@{ python = "3.12" }; packages = [ordered]@{ "scikit-learn" = "1.9.0"; numpy = "2.4.6" }
                                 url = "https://example.invalid/containers/py-fake.tar.gz"; sha256 = $PythonSha; size = (Get-Item $pyFake).Length }
            $lib = Join-Path $mirror "libexakit_smoke-$arch.so"
            $smoke = [ordered]@{ url = "https://example.invalid/smoke/libexakit_smoke-$arch.so"
                                 sha256 = (Get-FileHash -Path $lib -Algorithm SHA256).Hash.ToLowerInvariant(); size = (Get-Item $lib).Length }
            if ($SmokeMode -eq "bad") { $smoke.sha256 = ("0" * 64) }
            elseif ($SmokeMode -eq "placeholder") { $smoke.sha256 = "set after the first CI build"; $smoke.size = "set after the first CI build" }
            $rows += [ordered]@{ language = "rust"; alias = "RUST"; kind = "prebuilt"; arch = $arch; db_versions = ">=2026.1"
                                 runtime = [ordered]@{ rustc = "1.98.1" }; crates = [ordered]@{ "exasol-udf-sdk" = "0.33.0" }
                                 url = "https://example.invalid/containers/lc-rust-fake.tar.gz"; sha256 = $rsSha; size = (Get-Item $rsFake).Length
                                 validated = $false; smoke_asset = $smoke }
        }
        $doc.components.'udf-devkit' | Add-Member -NotePropertyName containers -NotePropertyValue $rows -Force
        [System.IO.File]::WriteAllText($Path, ($doc | ConvertTo-Json -Depth 12))
    }
    $goodDoc = Join-Path $work "versions.json"
    $badDoc = Join-Path $work "versions-bad-digest.json"
    $armDoc = Join-Path $work "versions-aarch64-only.json"
    $badSmokeDoc = Join-Path $work "versions-bad-smoke.json"
    $unpinnedSmokeDoc = Join-Path $work "versions-unpinned-smoke.json"
    New-Matrix $goodDoc $pySha @("x86_64", "aarch64")
    New-Matrix $badDoc ("0" * 64) @("x86_64", "aarch64")
    New-Matrix $armDoc $pySha @("aarch64")
    New-Matrix $badSmokeDoc $pySha @("x86_64", "aarch64") "bad"
    New-Matrix $unpinnedSmokeDoc $pySha @("x86_64", "aarch64") "placeholder"
    $bucketUdf = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $script:PersonalDeployDir "local\runtime\exa\bucketfs") "bfsdefault") "default") "udf") "libexakit_smoke.so"
    $script:VersionsDocPath = $goodDoc
    $env:EXAKIT_UDF_CONTAINERS_MIRROR = $mirror
    $env:EXAKIT_UDF_ARCH = "aarch64"
    $cache = $script:UdfContainerCache
    $cachedPy = Join-Path $cache "py-fake.tar.gz"
    $cachedRs = Join-Path $cache "lc-rust-fake.tar.gz"
    $cachedSo = Join-Path $cache "libexakit_smoke-aarch64.so"
    $smokeCall = "smoke-rust smoke-rust RUST STARTER_KIT /buckets/bfsdefault/default/udf/libexakit_smoke.so 1.98.1 0.33.0"
    Remove-Item -Recurse -Force $cache -ErrorAction SilentlyContinue
    Reset-Calls
    Invoke-CmdUdfUse -CmdArgs @("default")
    Check "the mirror's tarball goes to the launcher as PYTHON3_ML, --language python, then the pins to the smoke UDF" `
        "stop dash-server|launcher slc custom install --source $cachedPy --alias PYTHON3_ML --language python --auto-approve|wait|start dash-server|smoke PYTHON3_ML scikit-learn==1.9.0 numpy==2.4.6" ($script:calls -join "|")
    Check "the verified file is in the cache" "fake python container" ([System.IO.File]::ReadAllText($cachedPy))
    Check "the container's url is recorded under its alias" "https://example.invalid/containers/py-fake.tar.gz" (Get-ExakitManifestValue "components.udf_devkit.containers.PYTHON3_ML")
    Check "and the language" "python" (Get-ExakitManifestValue "components.udf_devkit.languages")
    Check "the row is the database's (aarch64, its version)" "aarch64 2026.2.0-nano.3" "$($script:UdfContainer.DbArch) $($script:UdfContainer.DbVersion)"
    $json = Invoke-CmdUdfUse -CmdArgs @("default", "--json")
    $d = "$json" | ConvertFrom-Json
    Check "--json: one object - ok, language, alias, container (url, sha256, arch, db_versions), smoke (package, version)" `
        "True python PYTHON3_ML arch,db_versions,sha256,url aarch64 >=2026.1 https://example.invalid/containers/py-fake.tar.gz python=3.12.3,scikit-learn=1.9.0,numpy=2.4.6" `
        "$($d.ok) $($d.language) $($d.alias) $((@($d.container.PSObject.Properties.Name) | Sort-Object) -join ',') $($d.container.arch) $($d.container.db_versions) $($d.container.url) $((@($d.smoke) | ForEach-Object { "$($_.package)=$($_.version)" }) -join ',')"
    Check "--json: the cached file was reused (no second download)" "True" (Test-Path $cachedPy)
    $script:ExakitRefusalJson = $false; $script:UdfJson = $false; $script:ExakitQuietDetail = $false

    Write-Host "an existing ML runtime is proved without reinstalling or restarting:"
    $originalAliases = ${function:Get-UdfDevkitInstalledAliases}
    $originalSmoke = ${function:Test-UdfDevkitSmoke}
    try {
        function Get-UdfDevkitInstalledAliases { return @("PYTHON3_ML") }
        Reset-Calls
        Check "the existing alias passes" "True" (Assert-UdfDevkitMl)
        Check "only the package smoke ran" "smoke PYTHON3_ML scikit-learn==1.9.0 numpy==2.4.6" ($script:calls -join "|")
        Check "the selected alias is recorded" "PYTHON3_ML" (Get-ExakitManifestValue "components.udf_devkit.python_alias")
        function Test-UdfDevkitSmoke { param([string]$Alias, [string[]]$Packages = @()); return ($Alias -ne "PYTHON3_ML") }
        Check "a missing ML package fails the add-on" "False" (Install-UdfDevkit)
        Check "and it is not marked validated" "False" (Get-ExakitManifestValue "components.udf_devkit.validated")
    } finally {
        ${function:Get-UdfDevkitInstalledAliases} = $originalAliases
        ${function:Test-UdfDevkitSmoke} = $originalSmoke
    }

    Write-Host "a digest that does not match is refused before the launcher sees the file:"
    Remove-Item -Recurse -Force $cache -ErrorAction SilentlyContinue
    $script:VersionsDocPath = $badDoc
    Reset-Calls
    $said = ""
    try { Invoke-CmdUdfUse -CmdArgs @("default") } catch { $said = "$_" }
    Contains "exit 4, step verify, naming the mismatch" "EXIT 4: python/verify: The container py-fake.tar.gz does not match its pinned digest (sha256 expected 0000" $said
    Contains "and the remedy" "Run this again" $said
    Check "the launcher saw nothing" "" ($script:calls -join "|")
    Check "and the file is gone" "False" (Test-Path $cachedPy)

    Write-Host "no row for this architecture or database version is refused, naming what did not match:"
    $script:VersionsDocPath = $armDoc
    $env:EXAKIT_UDF_ARCH = "x86_64"
    $said = ""
    try { Invoke-CmdUdfUse -CmdArgs @("default") } catch { $said = "$_" }
    Contains "no row for the arch: exit 4, step select-container" "EXIT 4: python/select-container: No prebuilt python container fits this database (x86_64, version 2026.2.0-nano.3): no python container for x86_64" $said
    Contains "with exakit update as the remedy" "| exakit update" $said
    $env:EXAKIT_UDF_ARCH = "aarch64"
    $script:VersionsDocPath = $goodDoc
    $script:dbVersion = "2025.3"
    $said = ""
    try { Invoke-CmdUdfUse -CmdArgs @("default") } catch { $said = "$_" }
    Contains "an older database: exit 4 naming the range and the version" "EXIT 4: python/select-container: " $said
    Contains "..." "container needs database >=2026.1, this one is 2025.3" $said
    $script:dbVersion = ""
    $said = ""
    try { Invoke-CmdUdfUse -CmdArgs @("default") } catch { $said = "$_" }
    Contains "no database version: exit 5, asks for the status" "EXIT 5: python/select-container: The database version is not known" $said
    $script:dbVersion = "2026.2.0-nano.3"
    $env:EXAKIT_UDF_CONTAINERS_MIRROR = Join-Path $work "empty-mirror"
    $said = ""
    try { Invoke-CmdUdfUse -CmdArgs @("default") } catch { $said = "$_" }
    Contains "a mirror without the file: exit 5, step download" "EXIT 5: python/download: The container py-fake.tar.gz is not in EXAKIT_UDF_CONTAINERS_MIRROR" $said
    $env:EXAKIT_UDF_CONTAINERS_MIRROR = $mirror

    Write-Host "EXAKIT_UDF_LANGUAGE=rust takes the Rust row (alias RUST) and proves it with the Rust smoke UDF (AC-ML1.5):"
    Remove-Item -Recurse -Force $cache -ErrorAction SilentlyContinue
    Remove-Item -Force $bucketUdf -ErrorAction SilentlyContinue
    Remove-ExakitManifestValue "components.udf_devkit"
    $script:UdfLanguage = "rust"
    Reset-Calls
    Check "the install succeeds" "True" (Install-UdfDevkit)
    Check "Rust and Python install together, then the ML runtime installs and checks every declared package" `
        "stop dash-server|launcher slc custom install --source $cachedRs --alias RUST --language rust --auto-approve --no-restart|launcher slc install PYTHON3 --auto-approve|wait|start dash-server|smoke PYTHON3|$smokeCall|stop dash-server|launcher slc custom install --source $cachedPy --alias PYTHON3_ML --language python --auto-approve|wait|start dash-server|smoke PYTHON3_ML scikit-learn==1.9.0 numpy==2.4.6" ($script:calls -join "|")
    Check "the smoke library was verified into the cache before the install" "fake rust smoke aarch64" ([System.IO.File]::ReadAllText($cachedSo))
    Check "and copied into the bucket directory under udf/" "fake rust smoke aarch64" ([System.IO.File]::ReadAllText($bucketUdf))
    Check "both languages are recorded" "rust,python" (Get-ExakitManifestValue "components.udf_devkit.languages")
    Check "the url under the alias" "https://example.invalid/containers/lc-rust-fake.tar.gz" (Get-ExakitManifestValue "components.udf_devkit.containers.RUST")
    Check "validated, with the reported rustc and sdk" "True 1.98.1 0.33.0" ("" + (Get-ExakitManifestValue "components.udf_devkit.rust.validated") + " " + (Get-ExakitManifestValue "components.udf_devkit.rust.rustc") + " " + (Get-ExakitManifestValue "components.udf_devkit.rust.sdk"))
    Check "...and the add-on's flag" "True" ("" + (Get-ExakitManifestValue "components.udf_devkit.validated"))
    Contains "and the summary names both languages" "Rust UDFs: alias RUST" (Get-UdfDevkitSummary)
    Write-Host "a missing shared bucket uses the verified container fallback after consent:"
    $savedBucketLocation = ${function:Get-UdfBucketLocation}
    try {
        if (-not (Select-UdfContainer -Language "rust")) { throw "Rust fixture row is missing." }
        function Get-UdfBucketLocation { return [pscustomobject]@{ Error = "no shared bucket" } }
        Reset-Calls
        Check "fallback smoke succeeds" "True" (Test-UdfDevkitSmokeRust -Alias "RUST")
        Check "services surround the container restart, then smoke uses its packaged path" `
            "stop dash-server|pack-rust|wait|start dash-server|smoke-rust smoke-rust RUST STARTER_KIT /opt/exakit/udf/libexakit_smoke-aarch64.so 1.98.1 0.33.0" ($script:calls -join "|")
        Reset-Calls
        Check "repeat validation reuses the packaged library" "True" (Test-UdfDevkitSmokeRust -Alias "RUST")
        Check "repeat validation does not restart" "smoke-rust smoke-rust RUST STARTER_KIT /opt/exakit/udf/libexakit_smoke-aarch64.so 1.98.1 0.33.0" ($script:calls -join "|")
        Reset-Calls
        $script:packagedSmoke = $false
        $script:UdfYes = $false; $script:confirmAnswer = $false
        Check "declined fallback is refused" "False" (Test-UdfDevkitSmokeRust -Alias "RUST")
        Check "decline packs nothing and stops nothing" "" ($script:calls -join "|")
        Check "decline has code 5" "5" $script:UdfFail.Code
    } finally {
        ${function:Get-UdfBucketLocation} = $savedBucketLocation
        $script:confirmAnswer = $true
    }
    $script:UdfLanguage = "python"
    Set-ExakitManifestValue "components.udf_devkit.languages" "python"
    $json = Invoke-CmdUdfSetup -CmdArgs @("--language", "rust", "--json")
    $d = "$json" | ConvertFrom-Json
    Check "udf-setup --language rust --json: ok, alias RUST, the smoke lines (container, rustc, sdk)" "True rust RUST container=RUST,rustc=1.98.1,sdk=0.33.0,rustc_full=rustc 1.98.1 (48a229cea 2026-09-01)" `
        "$($d.ok) $($d.language) $($d.alias) $((@($d.smoke) | ForEach-Object { "$($_.package)=$($_.version)" }) -join ',')"
    Check "the JSON names both language actions" "rust:installed|python:kept" ((@($d.steps) | ForEach-Object { "$($_.language):$($_.action)" }) -join "|")
    Check "a second language joins the record" "python,rust" (Get-ExakitManifestValue "components.udf_devkit.languages")
    $script:ExakitRefusalJson = $false; $script:UdfJson = $false; $script:ExakitQuietDetail = $false
    $script:installedAliases = @("RUST")
    function Get-UdfDevkitInstalledAliases { return $script:installedAliases }
    Reset-Calls
    Invoke-CmdUdfUse -CmdArgs @("default", "--language", "rust", "--yes")
    Contains "udf-use default updates an installed RUST, not installs it twice" "slc custom update --source $cachedRs --alias RUST" ($script:calls -join "|")
    Reset-Calls
    Invoke-CmdUdfSetup -CmdArgs @("--language", "rust", "--yes")
    Check "udf-setup proves both installed languages without a reinstall" "smoke PYTHON3|$smokeCall" ($script:calls -join "|")
    Reset-Calls
    Invoke-CmdUdfSetup -CmdArgs @("--language", "rust", "--yes", "--force")
    Contains "--force reinstalls it" "slc custom update --source $cachedRs --alias RUST" ($script:calls -join "|")
    $script:installedAliases = @()

    Write-Host "a rustc other than the pinned one, or a library the container refuses, is exit 7 at step smoke naming both:"
    $script:stubRustc = "1.97.0"
    $said = ""
    try { Invoke-CmdUdfSetup -CmdArgs @("--language", "rust", "--yes") } catch { $said = "$_" }
    Contains "exit 7, step smoke, both versions" "EXIT 7: rust/smoke: The Rust smoke UDF on RUST did not pass: rustc reported 1.97.0, pinned 1.98.1 | exakit udf-setup --language rust" $said
    Check "and the record says not validated" "False" ("" + (Get-ExakitManifestValue "components.udf_devkit.rust.validated"))
    $script:stubRustc = "1.98.1"
    $script:stubRustLoadError = "the RUST container refused to load the smoke library (F-UDF-CL-RUST-9001: ABI fingerprint mismatch): the library was built for another exasol-udf-sdk or rustc than the container's 0.33.0:rustc_1.98.1 - F-UDF-CL-RUST-9001"
    $said = ""
    try { Invoke-CmdUdfSetup -CmdArgs @("--language", "rust", "--yes") } catch { $said = "$_" }
    Contains "the container refusing the library (F-UDF-CL-RUST-9001): exit 7, step smoke, the fingerprint named" "EXIT 7: rust/smoke: The Rust smoke UDF on RUST did not pass: the RUST container refused to load the smoke library (F-UDF-CL-RUST-9001" $said
    Contains "..." "0.33.0:rustc_1.98.1" $said
    $script:stubRustLoadError = ""

    Write-Host "a smoke library whose digest does not match is refused before the launcher runs:"
    Remove-Item -Recurse -Force $cache -ErrorAction SilentlyContinue
    $script:VersionsDocPath = $badSmokeDoc
    Reset-Calls
    $said = ""
    try { Invoke-CmdUdfSetup -CmdArgs @("--language", "rust", "--yes") } catch { $said = "$_" }
    Contains "exit 4, step verify, naming the library" "EXIT 4: rust/verify: The smoke UDF library libexakit_smoke-aarch64.so does not match its pinned digest (sha256 expected 0000" $said
    Check "the launcher saw nothing" "" ($script:calls -join "|")
    Check "and the library is gone from the cache (the container stays)" "False True" "$(Test-Path $cachedSo) $(Test-Path $cachedRs)"

    Write-Host "a row whose smoke_asset is still a placeholder installs the container and stops at step smoke:"
    Remove-Item -Recurse -Force $cache -ErrorAction SilentlyContinue
    $script:VersionsDocPath = $unpinnedSmokeDoc
    Set-ExakitManifestValue "components.udf_devkit.validated" $true
    Reset-Calls
    $said = ""
    try { Invoke-CmdUdfSetup -CmdArgs @("--language", "rust", "--yes") } catch { $said = "$_" }
    Contains "exit 7, step smoke, saying the pin is missing, exakit update as the remedy" "EXIT 7: rust/smoke: The Rust smoke UDF library for aarch64 is not pinned in this kit's versions.json yet (its sha256 is a placeholder (set after the first CI build)): the RUST container is installed (exasol slc list) but not proven. A kit update brings the pin. | exakit update" $said
    Check "the Rust smoke did not run after the missing asset" "stop dash-server|launcher slc custom install --source $cachedRs --alias RUST --language rust --auto-approve|wait|start dash-server|smoke PYTHON3" ($script:calls -join "|")
    Check "the add-on is not validated" "False" ("" + (Get-ExakitManifestValue "components.udf_devkit.validated"))
    $script:VersionsDocPath = $goodDoc

    Write-Host "udf-setup --json answers with the same shape for the official container:"
    $json = Invoke-CmdUdfSetup -CmdArgs @("--json")
    $d = "$json" | ConvertFrom-Json
    Check "ok, python, PYTHON3, no url (the launcher's own), the arch, the smoke lines" "True python PYTHON3 True aarch64 3" "$($d.ok) $($d.language) $($d.alias) $($null -eq $d.container.url) $($d.container.arch) $(@($d.smoke).Count)"
    $script:ExakitRefusalJson = $false; $script:UdfJson = $false; $script:ExakitQuietDetail = $false
    Remove-Item Env:EXAKIT_UDF_CONTAINERS_MIRROR -ErrorAction SilentlyContinue
    Remove-Item Env:EXAKIT_UDF_ARCH -ErrorAction SilentlyContinue

    Write-Host "the real refusal is one JSON object with the exit code (a child PowerShell, since it exits):"
    $pwsh = (Get-Process -Id $PID).Path
    $probe = @(
        "`$env:EXAKIT_HOME = '$($env:EXAKIT_HOME)'",
        ". '$(Join-Path $repo "setup/lib/exakit-common.ps1")'",
        ". '$(Join-Path $repo "setup/lib/udf-devkit.ps1")'",
        "`$script:ExakitRefusalJson = `$true",
        "Exit-UdfRefusal -Code 4 -Language python -Step verify -Message 'digest differs' -Remedy 'exakit udf-use default'"
    ) -join "; "
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $lines = @(& $pwsh -NoProfile -Command $probe 2>$null | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    Check "exit 4" "4" $code
    $r = ($lines -join "") | ConvertFrom-Json
    Check "ok false, language, step, reason, remedy" "False python verify digest differs exakit udf-use default" "$($r.ok) $($r.language) $($r.step) $($r.reason) $($r.remedy)"
    Check "and nothing else on stdout" "1" $lines.Count
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "udf-devkit-addon-ps: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
