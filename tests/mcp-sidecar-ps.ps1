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
# Every launcher call names the kit's deployment folder (launcher 2.4.0 would
# otherwise act on a deployment in the current folder): the flag is checked
# here and left out of what is recorded, and a call without it is kept apart.
$script:noDeployDir = @()
function Invoke-ExakitLogged {
    param([Parameter(Mandatory)][string]$Cmd, [Parameter(ValueFromRemainingArguments)]$CmdArgs)
    $line = ($CmdArgs -join " ")
    $dd = " --deployment-dir $($script:PersonalDeployDir)"
    if ($line.EndsWith($dd)) { $line = $line.Substring(0, $line.Length - $dd.Length) } else { $script:noDeployDir += $line }
    $script:calls.Add($line); return 0
}
# uv, as a function called by name - exactly how `& $uv run ...` calls a path.
function fake-uv {
    $script:calls.Add("editor " + ($args[7..9] -join " "))
    $script:definition = Get-Content -Raw -LiteralPath $args[10]
    $script:definitionBytes = [System.IO.File]::ReadAllBytes($args[10])
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
# Windows PowerShell 5.1's `Set-Content -Encoding UTF8` writes a BOM (pwsh 7
# does not), and the editor's json.loads refused it: no sidecar, no MCP entry.
$bom = ($script:definitionBytes.Length -ge 3 -and $script:definitionBytes[0] -eq 0xEF -and $script:definitionBytes[1] -eq 0xBB -and $script:definitionBytes[2] -eq 0xBF)
Check "the definition file handed to the editor has no UTF-8 BOM" $false $bom
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
# Q5 (Krishna, 24 Nov): a port another deployment's MCP server has SAVED is
# taken even when that deployment is stopped and nothing listens on it now.
$otherDep = Join-Path $work "other-deployment"
New-Item -ItemType Directory -Force -Path $otherDep | Out-Null
Set-Content -LiteralPath (Join-Path $otherDep "sidecars.yaml") -Value "sidecars:`n  mcp:`n    container:`n      ports:`n        - name: mcp`n          containerPort: 4896`n          hostPort: 4896`n  other:`n    container:`n      ports:`n        - {name: x, containerPort: 1, `"hostPort`": 4897}"
$realOthers = ${function:Get-PersonalOtherDeployments}
function Get-PersonalOtherDeployments { return @($otherDep) }
Check "the ports other deployments' MCP servers saved" "4896,4897" ((Get-McpSidecarSavedPorts) -join ",")
$script:said = @()
$script:statusQueue.Enqueue($starting)
Check "port 4896 saved by a stopped deployment of theirs (Q5): applied" $true (Set-McpSidecar -Quiet)
Check "...moved past both saved ports, to 4898" "4898" (Get-ExakitManifestValue "components.mcp_server.port")
Check "...the definition publishes it" 4898 (($script:definition | ConvertFrom-Json).container.ports[0].hostPort)
Set-Item -Path function:Get-PersonalOtherDeployments -Value $realOthers
Remove-Item -Recurse -Force -LiteralPath $otherDep
Reset-Manifest; $script:calls.Clear()
$script:statusQueue.Enqueue($starting); $script:statusQueue.Enqueue($restart)
Check "a deployment that needs one restart: restarted, then applied" $true (Set-McpSidecar -Quiet)
Check "...stopped and started once" "personal-stop|personal-start" ((@($script:calls) | Where-Object { $_ -like "personal-*" }) -join "|")
Check "...recorded" "sidecar" (Get-ExakitManifestValue "components.mcp_server.backend")
Reset-Manifest; $script:calls.Clear(); $script:status = $restart
Check "still asking for a restart after one: not applied" $false (Set-McpSidecar -Quiet)
Check "...restarted only once" 1 (@($script:calls | Where-Object { $_ -eq "personal-stop" }).Count)
Check "...the fix is said" "Fix: exakit stop; exakit start" $script:McpSidecarProblem[1]
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
# The kit's own launcher: its update is the fix. A launcher the user installed
# is not the kit's to update, and the fix says so.
$realManaged = ${function:Test-ExakitComponentManaged}
function Test-ExakitComponentManaged { param($Id) return $true }
Check "a launcher without sidecars: not applied" $false (Set-McpSidecar -Quiet)
Check "...the fix is a launcher update" "Fix: exakit update personal" $script:McpSidecarProblem[1]
function Test-ExakitComponentManaged { param($Id) return $false }
[void](Set-McpSidecar -Quiet)
Check "...a launcher the user installed: the user updates it" "Fix: update your launcher to Exasol Personal 2.4.0 or later, then run exakit mcp-setup" $script:McpSidecarProblem[1]
${function:Test-ExakitComponentManaged} = $realManaged
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

Write-Host "a serving sidecar retires the install's MCP record:"
# The install step failed ("mcp did not finish ..." in the manifest and the
# failure note); a later `exakit mcp-setup` got the server serving, and
# `exakit status` still said "Last failure: mcp did not finish" and
# "Unfinished: mcp". Twin of the same block in tests/mcp-sidecar.sh.
Reset-Manifest; $script:status = $serving; $script:calls.Clear()
Register-ExakitSoftFailure -Component "mcp" -Repair "exakit mcp-doctor" -Reason "The MCP server beside your database did not start (status: unknown)."
Check "...booked (record)" $true ($null -ne (Get-ExakitManifestValue "install.soft_failures.mcp"))
Check "...booked (failure note)" $true (Test-Path -LiteralPath $script:FailureNotePath)
Check "the sidecar applies" $true (Set-McpSidecar -Quiet)
Check "...the record is gone" $true ($null -eq (Get-ExakitManifestValue "install.soft_failures.mcp"))
Check "...and so is its failure note" $false (Test-Path -LiteralPath $script:FailureNotePath)
Register-ExakitSoftFailure -Component "skills" -Repair "exakit skills-install" -Reason "no network" -Label "AI skills"
Register-ExakitSoftFailure -Component "mcp" -Repair "exakit mcp-doctor" -Reason "did not start"
Write-ExakitFailureNote "AI skills did not finish - no network. Retry with: exakit skills-install"
Check "a note about another step" $true (Set-McpSidecar -Quiet)
Check "...stays" $true (Test-Path -LiteralPath $script:FailureNotePath)
Check "...and so does that step's record" $true ($null -ne (Get-ExakitManifestValue "install.soft_failures.skills"))
Remove-Item -LiteralPath $script:FailureNotePath -Force -ErrorAction SilentlyContinue
$script:ExakitSoftFailed.Clear()

Write-Host "the definition editor fails:"
# A real process writing stderr and exiting 1, as the editor's traceback did.
# Under 5.1's 'Stop' its first stderr line used to escape as a terminating
# error, so only "Traceback (most recent call last):" reached the log.
# A REAL interpreter: on Windows `python3`/`python` can be the Microsoft Store
# App Execution Alias (...\WindowsApps\python3.exe), which exits 9009 with
# "Python was not found" - the two log checks then fail for the stub, not the
# kit. Every candidate on PATH, Store aliases skipped, each probed.
$script:failPython = $null
$probeEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
foreach ($candidate in @(Get-Command python3, python -All -CommandType Application -ErrorAction SilentlyContinue)) {
    $path = "" + $candidate.Source
    if (-not $path -or $path -like "*\WindowsApps\*") { continue }
    & $path -c "import sys" *> $null
    if ($LASTEXITCODE -eq 0) { $script:failPython = $path; break }
}
$ErrorActionPreference = $probeEap
if ($script:failPython) {
    function fail-uv {
        & $script:failPython -c "import sys; sys.stderr.write('Traceback (most recent call last):\n'); sys.stderr.write('ValueError: editor-boom\n'); sys.exit(1)"
    }
    $script:LogFile = Join-Path $work "editor-fail.log"
    Set-Content -LiteralPath $script:LogFile -Value "" -Encoding Ascii
    $threw = $false
    $got = "unset"
    try { $got = Write-McpSidecarDefinition "mcp_readonly" $pwFile 4896 "fail-uv" $repo } catch { $threw = $true }
    Check "a failed editor is no exception" $false $threw
    Check "...and no definition" $true ($null -eq $got)
    $logText = Get-Content -Raw -LiteralPath $script:LogFile
    Check "...the log has its exit code" $true ($logText -like "*definition editor exited 1*")
    Check "...and its last line, not only the traceback header" $true ($logText -like "*ValueError: editor-boom*")
    Check "...never the password" $false ($logText -like "*readonly-secret*")
    $script:LogFile = $null
} else {
    Write-Host "  SKIP the failing-editor checks: no real Python on PATH (Store aliases skipped)"
}

Write-Host "Update-McpSidecarDefinition: a kit update gives a running server this kit's definition:"
# PRE-01, twin of the mcp_sidecar_refresh block in tests/mcp-sidecar.sh: the
# preprocessor tools are on, and a server an earlier kit wrote gets them at the
# next whole-kit update - reconciled only when the definition changed.
Reset-Manifest; Set-ExakitManifestValue "components.mcp_server.backend" "sidecar"; $script:status = $serving; $script:calls.Clear()
$script:editorSays = "changed"
function fake-uv {
    $script:calls.Add("editor " + ($args[7..9] -join " "))
    $script:definition = Get-Content -Raw -LiteralPath $args[10]
    $global:LASTEXITCODE = 0
    $script:editorSays
}
function Test-PersonalDeploymentRunning { return $true }
Check "a changed definition: refreshed" $true (Update-McpSidecarDefinition)
$settings = (@(($script:definition | ConvertFrom-Json).container.env) | Where-Object { $_.name -eq "EXA_MCP_SETTINGS" }).value
Check "...with the SQL-preprocessor tools off" $true ($settings -like '*"enable_preprocessor_tools":false*')
Check "...and the write tools still off" $true ($settings -like '*"enable_write_query":false*')
Check "...reconciled by exasol start" $true (@($script:calls) -contains "start")
$script:calls.Clear(); $script:editorSays = "unchanged"
Check "unchanged: nothing started" "True False" "$(Update-McpSidecarDefinition) $(@($script:calls) -contains 'start')"
$script:calls.Clear(); $script:editorSays = "changed"
function Test-PersonalDeploymentRunning { return $false }
Check "a stopped database: written, nothing started" "True False" "$(Update-McpSidecarDefinition) $(@($script:calls) -contains 'start')"
Set-ExakitManifestValue "components.mcp_server.backend" "stdio"; $script:calls.Clear()
Check "a kit whose MCP server is not the sidecar: untouched" "True 0" "$(Update-McpSidecarDefinition) $($script:calls.Count)"

Write-Host "Restart-McpSidecar: a running server signs in again (U5):"
# Twin of the mcp_sidecar_restart block in tests/mcp-sidecar.sh: its pooled
# session keeps the SQL preprocessor slot it logged in with, so the kit
# restarts it once after the framework takes the slot - switched off, written
# again, reconciled; the database is not restarted.
Reset-Manifest; Set-ExakitManifestValue "components.mcp_server.backend" "sidecar"
$script:status = $serving; $script:statusQueue.Clear(); $script:calls.Clear(); $script:editorSays = "changed"
Check "a running server is restarted" $true (Restart-McpSidecar)
Check "...switched off, written again, then reconciled - in that order" "sidecar disable mcp|editor put|start" `
    ((@($script:calls) | ForEach-Object { if ("$_" -like "editor *") { "editor put" } else { "$_" } }) -join "|")
Check "...and the database is not restarted" $false (@($script:calls) -contains "personal-stop")
$script:status = [pscustomobject]@{ name = "mcp"; running = $false; health = "stopped" }; $script:calls.Clear()
Check "a server that is not running: nothing restarted" "True 0" "$(Restart-McpSidecar) $($script:calls.Count)"
Set-ExakitManifestValue "components.mcp_server.backend" "stdio"; $script:status = $serving; $script:calls.Clear()
Check "a kit whose MCP server is not the sidecar: untouched" "True 0" "$(Restart-McpSidecar) $($script:calls.Count)"
Set-ExakitManifestValue "components.mcp_server.backend" "sidecar"; $script:calls.Clear()
$script:statusQueue.Enqueue($serving)
$script:status = [pscustomobject]@{ name = "mcp"; running = $false; health = "starting" }
Check "a server that does not come back: failure" $false (Restart-McpSidecar)
Check "...and the record says it is not validated" "False" "$(Get-ExakitManifestValue 'components.mcp_server.validated')"
$script:status = $serving

Write-Host "exakit update over a 0.2.5 install: its clients move to the sidecar, once:"
# The record 0.2.5's mcp.ps1 wrote (git show 14df2ecb:setup/lib/mcp.ps1): the
# kit's own stdio uvx server, version 2.4.0 - the same number as the image this
# kit pins - and no backend. Reading that version as the sidecar's made the
# real update loop call the MCP server current, so every client stayed on
# stdio uvx.exe. Twin of "the MCP update moves a kit from before the sidecar,
# once" in tests/versions-manifest.sh.
function Reset-Manifest025 {
    Reset-Manifest
    Set-ExakitManifestValue "components.mcp_server.package" "exasol-mcp-server"
    Set-ExakitManifestValue "components.mcp_server.version" (Get-McpSidecarImageVersion)
    Set-ExakitManifestValue "components.mcp_server.command" "C:\Users\u\.local\bin\uvx.exe"
    Set-ExakitManifestValue "components.mcp_server.uv_path" "C:\Users\u\.local\bin\uv.exe"
    Set-ExakitManifestValue "components.mcp_server.mode" "stdio"
    Set-ExakitManifestValue "components.mcp_server.validated" $true
    Set-ExakitManifestValue "components.mcp_server.connection.validated" $true
}
Reset-Manifest025
Check "a 0.2.5 record has no version: it is not the sidecar" "" (Get-ExakitComponentCurrent "mcp")
Set-ExakitManifestValue "components.mcp_server.backend" "sidecar"
Check "...a sidecar record keeps its version" (Get-McpSidecarImageVersion) (Get-ExakitComponentCurrent "mcp")
$cliAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo "setup/exakit.ps1"), [ref]$null, [ref]$null)
foreach ($name in @("Invoke-ExakitUpdateRun", "Test-ExakitComponentSupported", "Test-ExakitComponentAhead",
                    "Test-ExakitMinKitSatisfied", "Get-ExakitComponentMinKit")) {
    $fn = $cliAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    Invoke-Expression $fn.Extent.Text
}
function Write-ExakitVersionsSourceLine { }
$script:notes = New-Object System.Collections.Generic.List[string]
function Add-ExakitUpdateNote { param([string]$Component, [string]$Outcome, [string]$From, [string]$To, [string]$Remedy, [string]$ErrorText, [string]$Hint)
    $script:notes.Add("$Component|$Outcome") }
function Update-McpClients { $script:calls.Add("clients-refreshed"); return $true }
$script:VersionPolicy = "pinned"
Reset-Manifest025; $script:status = $serving; $script:statusQueue.Clear(); $script:calls.Clear(); $script:notes.Clear()
Invoke-ExakitUpdateRun -Target "mcp" -Components @("mcp") 6>$null | Out-Null
Check "the update moves it: the row is updated" "mcp|updated" (@($script:notes) -join ";")
Check "...the sidecar is recorded" "sidecar" (Get-ExakitManifestValue "components.mcp_server.backend")
Check "...at its URL" "http://127.0.0.1:4896/mcp" (Get-ExakitManifestValue "components.mcp_server.url")
Check "...the clients are moved to it, once" 1 (@($script:calls | Where-Object { $_ -eq "clients-refreshed" }).Count)
Check "...the bridge gets the kit's absolute uvx" "/abs/uvx" (Get-ExakitManifestValue "components.mcp_server.command")
Check "...and the kit's receipt is written" "kit" (Get-ExakitComponentOwnership "mcp")
$script:calls.Clear(); $script:notes.Clear()
Invoke-ExakitUpdateRun -Target "mcp" -Components @("mcp") 6>$null | Out-Null
Check "run again: current" "mcp|current" (@($script:notes) -join ";")
Check "...no client touched" 0 (@($script:calls | Where-Object { $_ -eq "clients-refreshed" }).Count)

Write-Host "a 0.2.5 move whose sidecar does not start: the next update finishes it (UGR-02):"
# The failure records backend=sidecar (the clients' address). Read as current
# from then on, the update never moved the clients: they kept the 0.2.5 stdio
# server, the read-only password in their configs. Twin of the same block in
# tests/mcp-sidecar.sh.
Reset-Manifest025; $script:status = $failing; $script:statusQueue.Clear(); $script:calls.Clear(); $script:notes.Clear()
try { Invoke-ExakitUpdateRun -Target "mcp" -Components @("mcp") *>$null } catch { }
Check "the failed move: the sidecar address is recorded" "sidecar" (Get-ExakitManifestValue "components.mcp_server.backend")
Check "...no client touched" 0 (@($script:calls | Where-Object { $_ -eq "clients-refreshed" }).Count)
Check "...and the MCP server does not read as current" "" (Get-ExakitComponentCurrent "mcp")
$script:status = $serving; $script:calls.Clear(); $script:notes.Clear()
Invoke-ExakitUpdateRun -Target "mcp" -Components @("mcp") 6>$null | Out-Null
Check "the next update moves them: the row is updated" "mcp|updated" (@($script:notes) -join ";")
Check "...the clients are moved, once" 1 (@($script:calls | Where-Object { $_ -eq "clients-refreshed" }).Count)
Check "...now current" (Get-McpSidecarImageVersion) (Get-ExakitComponentCurrent "mcp")
Check "...the pending move is cleared" "" "$(Get-ExakitManifestValue 'components.mcp_server.clients_move')"
# A refresh that fails keeps the move pending for the next update.
function Update-McpClients { $script:calls.Add("clients-refreshed"); return $false }
Reset-Manifest025; $script:calls.Clear(); $script:notes.Clear()
Invoke-ExakitUpdateRun -Target "mcp" -Components @("mcp") 6>$null | Out-Null
Check "a client refresh that fails: the move stays pending" "pending" "$(Get-ExakitManifestValue 'components.mcp_server.clients_move')"
Check "...and the MCP server does not read as current" "" (Get-ExakitComponentCurrent "mcp")
function Update-McpClients { $script:calls.Add("clients-refreshed"); return $true }

Write-Host "mcp-doctor --json over a 0.2.5 record: a real answer, and nothing written:"
# What the runtime does there (mcp/runtime/exakit.py): no stdout, the reason on
# stderr, exit 1. --json printed "produced no result (see log)" with remedy
# "exakit logs setup", and set the read-only user up again first (ALTER USER,
# the GRANTs) although --json only reports. Twin of the same block in
# tests/mcp-sidecar.sh.
function Invoke-McpModule { param([string[]]$ModuleArgs)
    $script:calls.Add("module " + $ModuleArgs[0] + " " + $ModuleArgs[1])
    return @{ Output = "runtime_mcp_server_not_set_up: The MCP server beside your database is not set up yet. Run: exakit mcp-setup"; ExitCode = 1 } }
function Invoke-DoctorJson {
    $env:EXAKIT_MCP_RESULT_JSON = "1"
    $saved = [Console]::Out; $writer = New-Object System.IO.StringWriter
    [Console]::SetOut($writer)
    try { $script:doctorOk = Invoke-McpOperation -Operation "doctor" -InputArgs @("claude_code") 6>$null }
    finally { [Console]::SetOut($saved); Remove-Item Env:EXAKIT_MCP_RESULT_JSON -ErrorAction SilentlyContinue }
    return $writer.ToString()
}
Reset-Manifest025; $script:calls.Clear()
$doctorDoc = (Invoke-DoctorJson) | ConvertFrom-Json
Check "a pre-sidecar record: blocked" "blocked" $doctorDoc.status
Check "...the remedy moves the clients" "exakit update" $doctorDoc.remedy
Check "...installed, as every state answer says" $true $doctorDoc.installed
Check "...and the doctor fails" $false $script:doctorOk
Check "--json did not set the read-only user up again" $false (@($script:calls) -contains "readonly-setup")
Check "...the runtime was still asked" $true (@($script:calls) -contains "module run-runtime-operation doctor")
Set-ExakitManifestValue "components.mcp_server.backend" "sidecar"; $script:calls.Clear()
$doctorDoc = (Invoke-DoctorJson) | ConvertFrom-Json
Check "a sidecar that produced no result keeps the generic answer" "exakit logs setup" $doctorDoc.remedy
$script:calls.Clear()
[void](Invoke-McpOperationCli -Operation "doctor" -Clients @("claude_code") 6>$null)
Check "a plain doctor (it repairs) still sets the read-only user up" $true (@($script:calls) -contains "readonly-setup")

Write-Host "mcp-doctor --json carries mcp_privileges, the read-only user's own list:"
# AGENTS.md promises it on every platform. Read as the MCP user from
# SYS.EXA_USER_SYS_PRIVS (CSV, as exapump prints by default). Twin of the same
# block in tests/mcp-sidecar.sh.
$runtimePw = Join-Path $env:EXAKIT_HOME "credentials/runtime_sys_password"
Set-Content -LiteralPath $runtimePw -Value "admin-secret"
Reset-Manifest
Set-ExakitManifestValue "runtime.user" "sys"
Set-ExakitManifestValue "runtime.password_file" $runtimePw
Set-ExakitManifestValue "components.mcp_server.backend" "sidecar"
Set-ExakitManifestValue "components.mcp_server.connection.schemas" @("STARTER_KIT")
function Get-RuntimeHost { return "127.0.0.1" }
function Get-RuntimePort { return "8563" }
function Get-ExakitTlsFingerprint { return "" }
function Set-ExapumpTomlSection { param($ConfigPath, $Profile, $Host_, $Port, $User, $Password, $Schema, $Fingerprint) }
$script:postureOk = $true
function Assert-McpReadonlyPosture { param($ConfigPath, $ReadonlyUser, $Schemas) if (-not $script:postureOk) { throw "drift" } }
function Invoke-ExapumpAdminSql { param($ConfigPath, $Profile, $Sql)
    if ($Sql -like "*EXA_USER_SYS_PRIVS*") { return @{ Success = $true; Output = "PRIVILEGE`r`nCREATE SESSION`r`nSELECT ANY TABLE`r`nUSE ANY SCHEMA`r`n" } }
    return @{ Success = $true; Output = "STATUS`nOK`n" } }
function Invoke-McpOperationCli { param($Operation, $Clients) $script:McpLastRunFailed = $false; return '{"operation": "doctor", "status": "success", "findings": []}' }
$doctorDoc = (Invoke-DoctorJson) | ConvertFrom-Json
Check "doctor --json: mcp_privileges" "CREATE SESSION,SELECT ANY TABLE,USE ANY SCHEMA" (@($doctorDoc.mcp_privileges) -join ",")
Check "...the doctor's own fields untouched" "success" $doctorDoc.status
Check "...and it passes" $true $script:doctorOk
$script:postureOk = $false; $script:McpReadonlyPrivileges = @()
$doctorDoc = (Invoke-DoctorJson) | ConvertFrom-Json
Check "a drifted posture: no list claimed" $false ([bool]$doctorDoc.PSObject.Properties["mcp_privileges"])
Check "...and the doctor fails" $false $script:doctorOk

# A removal left a client file untouched because the kit could not parse it: the
# line names the file and the entry. Twin of _exakit_mcp_result_untouched.
$untouchedJson = '{"operation":"uninstall","status":"blocked","findings":[{"code":"client_config_left_untouched","severity":"warning","scope":{"client":"cursor","path":"C:\\u\\.cursor\\mcp.json","entry":"exasol"}},{"code":"other","severity":"warning","scope":{}}]}'
Check "a removal left untouched names the file and the entry" "Left C:\u\.cursor\mcp.json untouched (the kit could not parse it): delete its MCP entry 'exasol' by hand." ((@(Get-McpResultUntouched -Text $untouchedJson)) -join "|")

# A misspelt client name: the answer lists every name Windows accepts, the same
# sentence as exakit_mcp_operation in common.sh.
$warn2Kept = ${function:Warn2}
$script:warned = @()
function Warn2 { $script:warned += "$args" }
$typoOk = Invoke-McpOperation -Operation "status" -InputArgs @("claud")
Set-Item -Path Function:\Warn2 -Value $warn2Kept
Check "a misspelt client is refused" $false $typoOk
Check "...with every client name, as on Mac and Linux" "Please choose valid AI clients: claude, claude_desktop, claude_code, codex, cursor, copilot, gemini, opencode, continue, or all." ($script:warned -join "|")
foreach ($name in @("claude", "claude_desktop", "claude_code", "codex", "cursor", "copilot", "gemini", "opencode", "continue")) {
    Check "...and $name is a name Windows accepts" $true ($null -ne (ConvertTo-McpClientSelection $name))
}
# E2: a client skipped because its settings file cannot be written is not
# configured: its own Skipped line names it, the Ok list never does, and with
# every client skipped there is no Ok line. Twin of install-output-brevity.sh.
$script:sumOk = @(); $script:sumWarn = @()
function Ok { $script:sumOk += "$args" }
function Warn2 { $script:sumWarn += "$args" }
$skipJson = '{"status":"success_with_warnings","selected_clients":["claude_desktop","claude_code","codex","vscode_copilot"],"details":{"skipped_clients":[{"client":"vscode_copilot","reason":"its settings file C:\\u\\mcp.json cannot be written. Fix the folder''s permissions, then run: exakit mcp-setup"}]}}'
Show-McpSetupSummary -ResultJson $skipJson
Check "E2: the Ok line names only the configured clients" "MCP configured for Claude, Claude Code (CLI), Codex" ($script:sumOk -join "|")
Check "...the skipped one has its own line" $true (($script:sumWarn -join "|") -like "Skipped GitHub Copilot: its settings file*cannot be written*")
$script:sumOk = @(); $script:sumWarn = @()
Show-McpSetupSummary -ResultJson '{"status":"success_with_warnings","selected_clients":["vscode_copilot"],"details":{"skipped_clients":[{"client":"vscode_copilot","reason":"cannot be written"}]}}'
Check "...every client skipped: no Ok line" "" ($script:sumOk -join "|")
Check "...only the Skipped line" "Skipped GitHub Copilot: cannot be written" ($script:sumWarn -join "|")
Write-Host "the user's own MCP sidecar on a deployment the kit adopted (OWN-04):"
# The editor as it answers a sidecar of that name it was told to keep.
function fake-uv-foreign {
    $script:calls.Add("editor " + ($args -join " "))
    if ($args -contains "--keep-foreign") { $global:LASTEXITCODE = 3; "foreign"; return }
    $global:LASTEXITCODE = 0
    "changed"
}
Reset-Manifest
Set-ExakitManifestValue "runtime.deployment_dir" $env:EXAKIT_PERSONAL_DEPLOY_DIR
Set-ExakitManifestValue "runtime.ownership" "user"
Set-ExakitManifestValue "runtime.ownership_path" $env:EXAKIT_PERSONAL_DEPLOY_DIR
$script:status = $serving; $script:calls.Clear()
function Get-ExakitUvBin { return "fake-uv-foreign" }
Check "the user's own MCP sidecar: not replaced" $false (Set-McpSidecar -Quiet)
Check "...the kit asked the editor to keep it" $true ((@($script:calls) -join "|") -like "*put*--keep-foreign*")
Check "...said" $true ((@($script:McpSidecarProblem) -join "|") -like "*already has an MCP server of its own*")
Check "...no start reconciles it" $false (@($script:calls) -contains "start")
Check "...nothing recorded as the kit's sidecar" "|" "$(Get-ExakitManifestValue 'components.mcp_server.backend')|$(Get-ExakitManifestValue 'components.mcp_server.sidecar_dir')"
# The uninstall removes only the sidecar the kit wrote.
Set-ExakitManifestValue "components.mcp_server.backend" "sidecar"
$script:calls.Clear()
Remove-McpSidecar
Check "uninstall: the user's own MCP sidecar stays" $false ((@($script:calls) -join "|") -like "*sidecar disable*")
Set-ExakitManifestValue "components.mcp_server.backend" "sidecar"
Set-ExakitManifestValue "components.mcp_server.sidecar_dir" $env:EXAKIT_PERSONAL_DEPLOY_DIR
$script:calls.Clear()
Remove-McpSidecar
Check "uninstall: one the kit wrote in that folder goes" $true ((@($script:calls) -join "|") -like "*sidecar disable mcp*")
Check "...and its record with it" "" "$(Get-ExakitManifestValue 'components.mcp_server.sidecar_dir')"
function Get-ExakitUvBin { return "fake-uv" }
Check "every launcher call named the kit's deployment folder" "" ($script:noDeployDir -join "|")
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "passed: $($script:PASS), failed: $($script:FAIL)"
if ($script:FAIL -gt 0) { exit 1 }
