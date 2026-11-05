#!/usr/bin/env pwsh
# mcp-sidecar-ps.ps1 - twin of tests/mcp-sidecar.sh for setup/lib/mcp.ps1: the
# kit's MCP server as the launcher's sidecar (Exasol Personal 2.4.0+), against
# stubs. Pins the same facts: the definition is the kit's, connected as the
# read-only user with the password as a file reference; a serving sidecar is
# recorded; a deployment that needs a restart, an older launcher or
# EXAKIT_MCP_BACKEND=uvx leave no record, so the clients keep the stdio server.
#
#   pwsh -NoProfile -File tests/mcp-sidecar-ps.ps1

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label = $actual" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected $expected, got $actual" }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-mcp-sidecar-ps-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path (Join-Path $work "home/credentials"), (Join-Path $work "deployment") | Out-Null
$env:EXAKIT_HOME = Join-Path $work "home"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
$env:EXAKIT_PERSONAL_DEPLOY_DIR = Join-Path $work "deployment"
$env:EXAKIT_MCP_SIDECAR_WAIT = "0"
$env:EXAKIT_MCP_BRIDGE_PREFETCH = "0"
Remove-Item Env:EXAKIT_MCP_BACKEND -ErrorAction SilentlyContinue

. (Join-Path $repo "setup/lib/exakit-common.ps1")
. (Join-Path $repo "setup/lib/runtime-personal.ps1")
. (Join-Path $repo "setup/lib/mcp.ps1")

$pwFile = Join-Path $env:EXAKIT_HOME "credentials/mcp_readonly_password"
Set-Content -LiteralPath $pwFile -Value "readonly-secret"
function Reset-Manifest([string]$Type = "personal") {
    Initialize-ExakitManifest
    Set-ExakitManifestValue "runtime.type" $Type
    Set-ExakitManifestValue "components.mcp_server.connection.user" "mcp_readonly"
    Set-ExakitManifestValue "components.mcp_server.connection.password_file" $pwFile
}

# Stubs: the launcher's help, its `mcp status --json`, its logged calls, and uv
# (a script block that records what the editor was handed).
$script:helpHas = @("sidecar", "mcp")
$script:status = $null
$script:calls = New-Object System.Collections.Generic.List[string]
$script:definition = ""
function Get-PersonalCli { return "exasol-stub" }
function Test-PersonalLauncherSupports([string]$Token) { return ($script:helpHas -contains $Token) }
function Get-McpSidecarStatus { return $script:status }
function Invoke-ExakitLogged {
    param([Parameter(Mandatory)][string]$Cmd, [Parameter(ValueFromRemainingArguments)]$CmdArgs)
    $script:calls.Add(($CmdArgs -join " ")); return 0
}
# uv, as a function called by name - exactly how `& $uv run ...` calls a path.
function fake-uv {
    $script:calls.Add("editor " + ($args[7..9] -join " "))
    $script:definition = Get-Content -Raw -LiteralPath $args[10]
    $global:LASTEXITCODE = 0          # what the real uv leaves after a clean run
    "changed"
}
function Get-ExakitUvBin { return "fake-uv" }
function Get-McpCommandPath { return "/abs/uvx" }
$serving = [pscustomobject]@{ name = "mcp"; health = "serving"; restartRequired = $false
    endpoints = @([pscustomobject]@{ ip = "127.0.0.1"; port = 4896; url = "http://127.0.0.1:4896/mcp" }) }

Write-Host "Test-McpSidecarSupported:"
Reset-Manifest
Check "a 2.4.0 launcher and the kit's deployment" $true (Test-McpSidecarSupported)
$script:helpHas = @("install"); Check "a launcher without sidecars" $false (Test-McpSidecarSupported); $script:helpHas = @("sidecar", "mcp")
$env:EXAKIT_MCP_BACKEND = "uvx"; Check "EXAKIT_MCP_BACKEND=uvx keeps the kit's own server" $false (Test-McpSidecarSupported)
Remove-Item Env:EXAKIT_MCP_BACKEND
Reset-Manifest "docker"; Check "a database the launcher does not run" $false (Test-McpSidecarSupported)

Write-Host "Set-McpSidecar, serving:"
Reset-Manifest; $script:status = $serving; $script:calls.Clear()
Check "applies" $true (Set-McpSidecar)
Check "backend recorded" "sidecar" (Get-ExakitManifestValue "components.mcp_server.backend")
Check "url recorded" "http://127.0.0.1:4896/mcp" (Get-ExakitManifestValue "components.mcp_server.url")
Check "bridge recorded" (Get-ExakitVersionsValue "components.mcp.bridge") (Get-ExakitManifestValue "components.mcp_server.bridge")
$doc = $script:definition | ConvertFrom-Json
$envByName = @{}; foreach ($e in $doc.container.env) { $envByName[$e.name] = $e }
Check "the read-only user, not SYS" "mcp_readonly" $envByName["EXA_USER"].value
Check "the password is a file reference" $pwFile $envByName["EXA_PASSWORD"].valueFile
Check "...never the password itself" $false ($script:definition -like "*readonly-secret*")
Check "the image is pinned by digest" (Get-ExakitVersionsValue "components.mcp.sidecar_image") $doc.container.image
Check "loopback only" "127.0.0.1" $doc.container.ports[0].hostIP
Check "the uv the bridge runs through is recorded" "fake-uv" (Get-ExakitManifestValue "components.mcp_server.uv_path")
Check "...and an absolute uvx for Claude Desktop" "/abs/uvx" (Get-ExakitManifestValue "components.mcp_server.command")
Check "written into the deployment's sidecars.yaml" $true ((@($script:calls) -join "|") -like "*put*sidecars.yaml mcp*")
Check "a changed definition is reconciled by exasol start" $true (@($script:calls) -contains "start")
Check "the catalog template is never enabled" $false ((@($script:calls) -join "|") -like "*sidecar enable*")

Write-Host "Set-McpSidecar, falling back:"
Reset-Manifest
$script:status = [pscustomobject]@{ name = "mcp"; health = "starting"; restartRequired = $true; endpoints = @() }
Check "a deployment that needs a restart first: not applied" $false (Set-McpSidecar)
Check "...nothing recorded" "" "$(Get-ExakitManifestValue 'components.mcp_server.backend')"
Reset-Manifest; Set-ExakitManifestValue "components.mcp_server.backend" "sidecar"; $script:calls.Clear()
$script:status = [pscustomobject]@{ name = "mcp"; health = "failing"; restartRequired = $false; endpoints = @() }
Check "a sidecar that never serves: not applied" $false (Set-McpSidecar)
Check "...the old record is cleared" "" "$(Get-ExakitManifestValue 'components.mcp_server.backend')"
Check "...and the sidecar is switched off" $true (@($script:calls) -contains "sidecar disable mcp")

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "passed: $($script:PASS), failed: $($script:FAIL)"
if ($script:FAIL -gt 0) { exit 1 }
