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
$script:LogFile = $null
$script:PersonalDeployDir = Join-Path $work "deployment"
New-Item -ItemType Directory -Force -Path (Join-Path $script:PersonalDeployDir "local\runtime\exa") | Out-Null
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
$script:dbVersion = "2026.2.0-nano.3"
function Invoke-UdfSlc {
    param([string[]]$SlcArgs)
    if ($SlcArgs[0] -eq "list") { return ,@(0, @('[{"alias": "PYTHON3", "installed": false}]')) }
    [void]$script:calls.Add("launcher slc $($SlcArgs -join ' ')")
    return ,@(0, @())
}
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
    $pySha = (Get-FileHash -Path $pyFake -Algorithm SHA256).Hash.ToLowerInvariant()
    $rsSha = (Get-FileHash -Path $rsFake -Algorithm SHA256).Hash.ToLowerInvariant()
    # A test copy of the kit's versions.json: the same document, its container
    # rows replaced by ones that point at the fake tarballs (sha256 and size real).
    function New-Matrix($Path, $PythonSha, $Arches) {
        $doc = Get-Content -Raw (Join-Path $repo "versions.json") | ConvertFrom-Json
        $rows = @()
        foreach ($arch in $Arches) {
            $rows += [ordered]@{ language = "python"; alias = "PYTHON3_ML"; kind = "prebuilt"; arch = $arch; db_versions = ">=2026.1"
                                 runtime = [ordered]@{ python = "3.12" }; packages = [ordered]@{ "scikit-learn" = "1.9.0"; numpy = "2.4.6" }
                                 url = "https://example.invalid/containers/py-fake.tar.gz"; sha256 = $PythonSha; size = (Get-Item $pyFake).Length }
            $rows += [ordered]@{ language = "rust"; alias = "RUST"; kind = "prebuilt"; arch = $arch; db_versions = ">=2026.1"
                                 runtime = [ordered]@{ rustc = "1.98.1" }; crates = [ordered]@{ "exasol-udf-sdk" = "0.33.0" }
                                 url = "https://example.invalid/containers/lc-rust-fake.tar.gz"; sha256 = $rsSha; size = (Get-Item $rsFake).Length }
        }
        $doc.components.'udf-devkit' | Add-Member -NotePropertyName containers -NotePropertyValue $rows -Force
        [System.IO.File]::WriteAllText($Path, ($doc | ConvertTo-Json -Depth 12))
    }
    $goodDoc = Join-Path $work "versions.json"
    $badDoc = Join-Path $work "versions-bad-digest.json"
    $armDoc = Join-Path $work "versions-aarch64-only.json"
    New-Matrix $goodDoc $pySha @("x86_64", "aarch64")
    New-Matrix $badDoc ("0" * 64) @("x86_64", "aarch64")
    New-Matrix $armDoc $pySha @("aarch64")
    $script:VersionsDocPath = $goodDoc
    $env:EXAKIT_UDF_CONTAINERS_MIRROR = $mirror
    $env:EXAKIT_UDF_ARCH = "aarch64"
    $cache = $script:UdfContainerCache
    $cachedPy = Join-Path $cache "py-fake.tar.gz"
    $cachedRs = Join-Path $cache "lc-rust-fake.tar.gz"
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

    Write-Host "EXAKIT_UDF_LANGUAGE=rust takes the Rust row (alias RUST), with no smoke UDF yet:"
    Remove-Item -Recurse -Force $cache -ErrorAction SilentlyContinue
    Remove-ExakitManifestValue "components.udf_devkit"
    $script:UdfLanguage = "rust"
    Reset-Calls
    Check "the install succeeds" "True" (Install-UdfDevkit)
    Check "the install goes down the rust path: slc custom install --alias RUST --language rust, no smoke" `
        "stop dash-server|launcher slc custom install --source $cachedRs --alias RUST --language rust --auto-approve|wait|start dash-server" ($script:calls -join "|")
    Check "the language is recorded" "rust" (Get-ExakitManifestValue "components.udf_devkit.languages")
    Check "the url under the alias" "https://example.invalid/containers/lc-rust-fake.tar.gz" (Get-ExakitManifestValue "components.udf_devkit.containers.RUST")
    Check "validated false until the smoke UDF exists" "False" ("" + (Get-ExakitManifestValue "components.udf_devkit.validated"))
    Contains "and the summary names both languages" "Rust UDFs: alias RUST" (Get-UdfDevkitSummary)
    $script:UdfLanguage = "python"
    Set-ExakitManifestValue "components.udf_devkit.languages" "python"
    $json = Invoke-CmdUdfSetup -CmdArgs @("--language", "rust", "--json")
    $d = "$json" | ConvertFrom-Json
    Check "udf-setup --language rust --json: ok, alias RUST, an empty smoke list" "True rust RUST 0" "$($d.ok) $($d.language) $($d.alias) $(@($d.smoke).Count)"
    Check "a second language joins the record" "python,rust" (Get-ExakitManifestValue "components.udf_devkit.languages")
    $script:ExakitRefusalJson = $false; $script:UdfJson = $false; $script:ExakitQuietDetail = $false
    $script:installedAliases = @("RUST")
    function Get-UdfDevkitInstalledAliases { return $script:installedAliases }
    Reset-Calls
    Invoke-CmdUdfUse -CmdArgs @("default", "--language", "rust", "--yes")
    Contains "an installed RUST is updated, not installed twice" "slc custom update --source $cachedRs --alias RUST" ($script:calls -join "|")
    $script:installedAliases = @()

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
