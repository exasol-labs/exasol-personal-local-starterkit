#!/usr/bin/env pwsh
# mcp-sidecar-ps.ps1 - twin of tests/mcp-sidecar.sh for setup/lib/mcp.ps1: the
# kit's MCP server as the launcher's sidecar (Exasol Personal 2.4.0+), the only
# MCP server the kit runs, against stubs. Pins the same facts: the definition is
# the kit's, connected as the read-only user with the password as a file
# reference; a serving sidecar is recorded; what stands in the way is healed
# (the read-only user, a taken port, one restart, one recreate); what cannot be
# healed is said with its fix, and the record stays (validated false).
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

. (Join-Path $repo "setup/lib/exakit-common.ps1")
. (Join-Path $repo "setup/lib/runtime-personal.ps1")
. (Join-Path $repo "setup/lib/mcp.ps1")

$pwFile = Join-Path $env:EXAKIT_HOME "credentials/mcp_readonly_password"
Set-Content -LiteralPath $pwFile -Value "readonly-secret"
function Reset-Manifest([string]$Type = "personal") {
    Remove-Item -LiteralPath $script:ManifestPath -Force -ErrorAction SilentlyContinue
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
# Statuses queued for the next polls, then $script:status for every later one.
$script:statusQueue = New-Object System.Collections.Generic.Queue[object]
function Get-McpSidecarStatus {
    if ($script:statusQueue.Count -gt 0) { return $script:statusQueue.Dequeue() }
    return $script:status
}
$script:busyPorts = @()
function Test-ExakitPortInUse { param([int]$Port, [string]$ComputerName = "127.0.0.1", [int]$TimeoutMs = 700) return ($script:busyPorts -contains $Port) }
function Stop-Personal { $script:calls.Add("personal-stop") }
function Start-Personal { $script:calls.Add("personal-start") }
function Set-McpReadonlyAccess {
    $script:calls.Add("readonly-setup")
    Set-Content -LiteralPath $pwFile -Value "readonly-secret"
    Set-ExakitManifestValue "components.mcp_server.connection.user" "mcp_readonly"
    Set-ExakitManifestValue "components.mcp_server.connection.password_file" $pwFile
}
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
$env:EXAKIT_MCP_BACKEND = "uvx"; Check "EXAKIT_MCP_BACKEND is gone: it no longer turns the sidecar off" $true (Test-McpSidecarSupported)
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

Write-Host "Set-McpSidecar, healing what stands in the way:"
$starting = [pscustomobject]@{ name = "mcp"; health = "starting"; restartRequired = $false; endpoints = @() }
$restart = [pscustomobject]@{ name = "mcp"; health = "starting"; restartRequired = $true; endpoints = @() }
$failing = [pscustomobject]@{ name = "mcp"; health = "failing"; restartRequired = $false; endpoints = @(); message = "pull access denied for docker.io/exasol/mcp-server" }
Reset-Manifest; Set-ExakitManifestValue "components.mcp_server.connection.password_file" (Join-Path $work "missing"); $script:calls.Clear()
$script:status = $serving
Check "the read-only user not ready: set up, then applied" $true (Set-McpSidecar -Quiet)
Check "...the read-only setup ran" $true (@($script:calls) -contains "readonly-setup")
Reset-Manifest; $script:calls.Clear(); $script:busyPorts = @(4896, 4897)
$script:statusQueue.Enqueue($starting)
Check "port 4896 taken by another program: applied" $true (Set-McpSidecar -Quiet)
Check "...moved to the first free port" "4898" (Get-ExakitManifestValue "components.mcp_server.port")
Check "...the definition publishes it" 4898 (($script:definition | ConvertFrom-Json).container.ports[0].hostPort)
Check "...and the next run keeps it" 4898 (Get-McpSidecarPort)
$script:busyPorts = @()
Reset-Manifest; $script:calls.Clear()
$script:statusQueue.Enqueue($starting); $script:statusQueue.Enqueue($restart)
Check "a deployment that needs one restart: restarted, then applied" $true (Set-McpSidecar -Quiet)
Check "...stopped and started once" "personal-stop|personal-start" ((@($script:calls) | Where-Object { $_ -like "personal-*" }) -join "|")
Check "...recorded" "sidecar" (Get-ExakitManifestValue "components.mcp_server.backend")
Reset-Manifest; $script:calls.Clear(); $script:status = $restart
Check "still asking for a restart after one: not applied" $false (Set-McpSidecar -Quiet)
Check "...restarted only once" 1 (@($script:calls | Where-Object { $_ -eq "personal-stop" }).Count)
Check "...the fix is said" "Fix: exakit stop && exakit start" $script:McpSidecarProblem[1]
Reset-Manifest; $script:calls.Clear()
$script:statusQueue.Enqueue($starting); $script:statusQueue.Enqueue($starting); $script:status = $serving
Check "a container that did not start: recreated, then applied" $true (Set-McpSidecar -Quiet)
Check "...switched off and reconciled again" $true ((@($script:calls) -contains "sidecar disable mcp") -and (@($script:calls | Where-Object { $_ -eq "start" }).Count -eq 2))
Check "...without removing its definition" $false ((@($script:calls) -join "|") -like "*--remove*")
Reset-Manifest; Set-ExakitManifestValue "components.mcp_server.backend" "sidecar"
Set-ExakitManifestValue "components.mcp_server.url" "http://127.0.0.1:4896/mcp"; $script:calls.Clear(); $script:status = $failing
Check "a sidecar that never serves: not applied" $false (Set-McpSidecar -Quiet)
Check "...recreated once" 1 (@($script:calls | Where-Object { $_ -eq "sidecar disable mcp" }).Count)
Check "...the record stays: the clients keep the URL" "sidecar|http://127.0.0.1:4896/mcp" "$(Get-ExakitManifestValue 'components.mcp_server.backend')|$(Get-ExakitManifestValue 'components.mcp_server.url')"
Check "...marked not validated" $false (Get-ExakitManifestValue "components.mcp_server.validated")
Check "...the error names the status and the launcher's words" $true ($script:McpSidecarProblem[0] -like "*did not start (status: failing)*pull access denied*")
Check "...and its fix" "Fix: exakit mcp-doctor (details: exasol mcp status)" $script:McpSidecarProblem[1]
Reset-Manifest; $script:calls.Clear(); $script:status = $failing
Check "a first run that never serves: not applied" $false (Set-McpSidecar -Quiet)
Check "...still records where the server will answer, not validated" "sidecar|http://127.0.0.1:4896/mcp|False" "$(Get-ExakitManifestValue 'components.mcp_server.backend')|$(Get-ExakitManifestValue 'components.mcp_server.url')|$(Get-ExakitManifestValue 'components.mcp_server.validated')"
Reset-Manifest; $script:helpHas = @("install"); $script:calls.Clear()
Check "a launcher without sidecars: not applied" $false (Set-McpSidecar -Quiet)
Check "...the fix is a launcher update" "Fix: exakit update personal" $script:McpSidecarProblem[1]
Check "...and nothing was started" $false (@($script:calls) -contains "start")
$script:helpHas = @("sidecar", "mcp"); $script:status = $serving

Write-Host "updating the launcher's MCP server: the image is the version:"
$pinned = Get-ExakitVersionsPin -Path "components.mcp.sidecar_image"
$imageVersion = $pinned.Split("@")[0].Split(":")[-1]
Check "the image comes from this kit copy" $pinned (Get-McpSidecarImage)
Check "...and its version is the image tag" $imageVersion (Get-McpSidecarImageVersion)
function Get-ExakitComponentLatest([string]$Component) { return "9.9.9" }
$savedPolicy = $script:VersionPolicy
$script:VersionPolicy = "latest"
Reset-Manifest; Set-ExakitManifestValue "components.mcp_server.backend" "sidecar"
Check "offered on a sidecar: the image's version, not PyPI's newest" $imageVersion (Get-ExakitComponentAvailable "mcp")
Reset-Manifest
Check "...and on a kit from before (no backend recorded) too" $imageVersion (Get-ExakitComponentAvailable "mcp")
$script:VersionPolicy = $savedPolicy
$updater = Get-Content -Raw -LiteralPath (Join-Path $repo "setup/exakit.ps1")
Check "exakit update refuses a version with no pinned image" $true ($updater -match '\(Get-McpSidecarImageVersion\) -ne \$available')

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "passed: $($script:PASS), failed: $($script:FAIL)"
if ($script:FAIL -gt 0) { exit 1 }
