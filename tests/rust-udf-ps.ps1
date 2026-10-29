$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo "setup/lib/rust-udf.ps1")
function Get-UdfDevkitInstalledVersion { return "0.1.0" }
function Invoke-UdfTool {
    param($Script, $ToolArgs)
    if ($Script -ne "rust_udf_tool.py") { throw "wrong script" }
    if ($ToolArgs[0] -eq "deploy") {
        if ($env:EXAKIT_RUST_BUCKET_DIR -or $env:EXAKIT_RUST_UDF_ROOT -or
            $env:EXAKIT_RUST_LAUNCHER -ne "test-launcher" -or $env:EXAKIT_RUST_DEPLOYMENT -ne "test-deployment") {
            throw "Fallback environment differs from the shell wrapper."
        }
    }
    return ,@(0, @('{"ok":true}'), "")
}
Invoke-CmdRustUdf -CmdArgs @("new", "score_model", "--json") | Out-Null
function Get-UdfBucketLocation { return [pscustomobject]@{ Error = "no shared bucket" } }
function Get-PersonalCli { return "test-launcher" }
$script:PersonalDeployDir = "test-deployment"
$env:EXAKIT_RUST_LAUNCHER = "original"
Invoke-CmdRustUdf -CmdArgs @("deploy", "score_model", "--yes", "--json") | Out-Null
if ($env:EXAKIT_RUST_LAUNCHER -ne "original" -or $env:EXAKIT_RUST_DEPLOYMENT) { throw "Wrapper did not restore the environment." }
Write-Output "rust-udf PowerShell wrapper: OK"
