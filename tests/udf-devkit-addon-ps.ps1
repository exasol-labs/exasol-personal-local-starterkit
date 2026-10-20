#!/usr/bin/env pwsh
# udf-devkit-addon-ps.ps1 - the Windows twin of tests/udf-devkit-addon.sh: the
# udf-devkit add-on's own behaviour in setup/lib/udf-devkit.ps1. Runs under
# Windows PowerShell 5.1 and pwsh; a sandboxed kit home and deployment folder,
# the launcher and the services stubbed; no database.
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
function Test-UdfDevkitSmoke { param([string]$Alias, [string[]]$Packages = @()) [void]$script:calls.Add("smoke $Alias"); return $true }
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
    Reset-Calls
    $script:confirmAnswer = $false
    Invoke-CmdUdfSetup
    Check "a decline installs nothing, stops nothing" "" ($script:calls -join "|")
    $script:confirmAnswer = $true

    Write-Host "an old launcher is refused first:"
    Reset-Calls
    $script:launcher = "2.2.0"
    Invoke-CmdUdfSetup
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
    foreach ($case in @(@{ Fn = "Invoke-CmdUdfUse"; Args = @("default"); Needle = "No prebuilt container" },
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
    Remove-ExakitManifestValue "components.udf_devkit"
    $said = ""
    try { Invoke-CmdUdfSetup } catch { $said = "$_" }
    Contains "not installed names the marketplace" "exakit marketplace udf-devkit" $said
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "udf-devkit-addon-ps: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
