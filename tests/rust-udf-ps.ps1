$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo "setup/lib/rust-udf.ps1")
function Get-UdfDevkitInstalledVersion { return "0.1.0" }
function Invoke-UdfTool { param($Script, $ToolArgs) if ($Script -ne "rust_udf_tool.py") { throw "wrong script" }; return ,@(0, @('{"ok":true}'), "") }
Invoke-CmdRustUdf -CmdArgs @("new", "score_model", "--json") | Out-Null
Write-Output "rust-udf PowerShell wrapper: OK"
