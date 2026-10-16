#!/usr/bin/env pwsh
# runtime-nano-ps.ps1 - behavioural tests for setup/lib/runtime-nano.ps1, the
# Docker variant's Windows runtime (branch exasol-starterkit-docker).
# Dot-sources the real modules against a sandboxed kit home and a stub docker
# (tests/lib/docker-stub.ps1) that records every call and answers from a small
# state directory, and asserts: the tag resolution and its pin, the digest
# check after the pull, the container arguments (loopback port, data volume,
# the first-deploy password mount, the restart policy), the manifest keys, the
# status vocabulary, the installer's soft paths, stop/start/remove/update, the
# autostart policy, and the Docker Hub tag parser. No real engine is touched.
#
#   pwsh -NoProfile -File tests/runtime-nano-ps.ps1

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label = $actual" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected $expected, got $actual" }
}

# --- sandbox ----------------------------------------------------------------
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-rn-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:EXAKIT_HOME = Join-Path $work "home"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
$env:EXAKIT_DB_PORT = "18563"
$env:EXAKIT_VERSION_POLICY = "manifest"
$env:EXAKIT_VERSIONS_TTL = "999999"
$env:EXAKIT_NO_UPDATE_NOTICE = "1"
Remove-Item Env:EXAKIT_NANO_TAG -ErrorAction SilentlyContinue
Remove-Item Env:EXAKIT_NANO_CONTAINER -ErrorAction SilentlyContinue
Remove-Item Env:EXAKIT_NANO_VOLUME -ErrorAction SilentlyContinue
Remove-Item Env:NANO_STUB_DOWN -ErrorAction SilentlyContinue
# The manifest this kit ships, as the cached document, so no network is asked.
New-Item -ItemType Directory -Force -Path (Join-Path $env:EXAKIT_HOME "cache") | Out-Null
Copy-Item (Join-Path $repo "versions.json") (Join-Path $env:EXAKIT_HOME "cache/versions.json")

# --- the stub engine ----------------------------------------------------------
$state = Join-Path $work "stub-state"
New-Item -ItemType Directory -Force -Path $state | Out-Null
$env:NANO_STUB_STATE = $state
$stubDir = Join-Path $work "stubbin"
New-Item -ItemType Directory -Force -Path $stubDir | Out-Null
$stubBody = Join-Path $stubDir "docker-stub.ps1"
Copy-Item (Join-Path $repo "tests/lib/docker-stub.ps1") $stubBody
# $env:OS, not $IsWindows: the automatic variable does not exist on 5.1.
$onWindows = ($env:OS -like "*Windows*")
if ($onWindows) {
    $psExe = "powershell"
    if ($PSVersionTable.PSVersion.Major -ge 6) { $psExe = "pwsh" }
    Set-Content -Path (Join-Path $stubDir "docker.cmd") -Encoding Ascii -Value @(
        "@echo off",
        "$psExe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0docker-stub.ps1`" %*",
        "exit /b %ERRORLEVEL%"
    )
} else {
    $sh = Join-Path $stubDir "docker"
    Set-Content -Path $sh -Value @(
        "#!/bin/sh",
        "exec pwsh -NoProfile -File `"`$(dirname `"`$0`")/docker-stub.ps1`" `"`$@`""
    )
    chmod +x $sh
}
$env:PATH = $stubDir + [System.IO.Path]::PathSeparator + $env:PATH

function StatePath($n) { return (Join-Path $state $n) }
function Put($n, $v) { Set-Content -Path (StatePath $n) -Value $v }
function Gone($n) { Remove-Item -Force (StatePath $n) -ErrorAction SilentlyContinue }
function Calls() { if (Test-Path (StatePath "calls.log")) { return @(Get-Content (StatePath "calls.log")) }; return @() }
function ClearCalls() { Gone "calls.log" }
function RunLine() { return "" + ((Calls) | Where-Object { $_ -like "run *" } | Select-Object -First 1) }
function HasCall($pattern) { return [bool]((Calls) | Where-Object { $_ -like $pattern }) }

. (Join-Path $repo "setup/lib/exakit-common.ps1")
. (Join-Path $repo "setup/lib/runtime-nano.ps1")
Initialize-ExakitLogging
Initialize-ExakitManifest
Resolve-ExakitVersionsDoc | Out-Null
$script:NanoPullRetryDelay = 0
$advertised = "" + (Get-ExakitVersionsValue -Path "components.nano.version")
$pin = "" + (Get-ExakitVersionsValue -Path "components.nano.digest")
$image = "docker.io/exasol/nano:$advertised"

Write-Host "the tag and its pin:"
Check "the manifest advertises a nano tag" $true ($advertised -match '^\d+\.\d+\.\d+-nano\.\d+$')
Check "target tag (manifest)" $advertised (Get-NanoTargetTag)
Check "pin for the advertised tag" $pin (Get-NanoPinnedDigest -Tag $advertised)
Check "no pin for another tag" "" (Get-NanoPinnedDigest -Tag "2020.1.0-nano.1")
$env:EXAKIT_NANO_TAG = "2020.1.0-nano.1"
Check "EXAKIT_NANO_TAG wins" "2020.1.0-nano.1" (Get-NanoTargetTag)
Remove-Item Env:EXAKIT_NANO_TAG
Check "fallback constant has the tag shape" $true ($script:NanoTagFallback -match '^\d+\.\d+\.\d+-nano\.\d+$')
Check "fallback constant equals the manifest (they move together)" $advertised $script:NanoTagFallback
Check "image ref" $image (Get-NanoImageRef)

Write-Host "the port:"
Check "EXAKIT_DB_PORT" 18563 (Get-NanoDbPort)
Set-ExakitManifestValue "runtime.dsn" "127.0.0.1:19000"
Check "the recorded dsn beats it" 19000 (Get-NanoDbPort)
Remove-ExakitManifestValue "runtime.dsn"

Write-Host "the engine:"
Check "docker answers" "docker" (Get-NanoEngine)
$env:NANO_STUB_DOWN = "1"; Reset-NanoEngineCache
Check "docker down" "" ("" + (Get-NanoEngine))
Check "status with the engine down" "not installed" (Get-NanoStatus)
Remove-Item Env:NANO_STUB_DOWN; Reset-NanoEngineCache

Write-Host "the status vocabulary:"
Check "no container" "not installed" (Get-NanoStatus)
Put "container" "1"; Put "running" "false"; Put "cmd" "[]"; Put "image" $image
Check "stopped" "stopped" (Get-NanoStatus)
Put "running" "true"; Put "logs" "booting"
Check "running container, database silent" "starting" (Get-NanoStatus)
Check "Test-NanoDeploymentRunning while silent" $false (Test-NanoDeploymentRunning)
Put "logs" "... Database is now up and running! ..."
Check "the ready marker" "running" (Get-NanoStatus)
Check "Test-NanoDeploymentRunning" $true (Test-NanoDeploymentRunning)
Gone "container"
$listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 18563)
$listener.Start()
Check "port held by something else" "conflict" (Get-NanoStatus)
$listener.Stop()

Write-Host "the pull and its pin:"
Put "repodigests" "docker.io/exasol/nano@sha256:$pin"
Check "pinned digest matches" $true (Invoke-NanoPull -Tag $advertised)
Check "no removal on a match" $false (Test-Path (StatePath "image_removed"))
Put "repodigests" "docker.io/exasol/nano@sha256:0000000000000000000000000000000000000000000000000000000000000000"
Check "a mismatch is refused" $false (Invoke-NanoPull -Tag $advertised)
Check "the mismatched image is removed" $true (Test-Path (StatePath "image_removed"))
Gone "image_removed"
$env:EXAKIT_NANO_TAG = "2020.1.0-nano.1"
Check "a hand-picked tag pulls unverified" $true (Invoke-NanoPull -Tag "2020.1.0-nano.1")
Remove-Item Env:EXAKIT_NANO_TAG
Put "pull_rc" "1"
Check "a failed pull is a false" $false (Invoke-NanoPull -Tag $advertised)
Check "three attempts" 3 (@((Calls) | Where-Object { $_ -eq "pull $image" }).Count - 2)
Gone "pull_rc"
Put "repodigests" "docker.io/exasol/nano@sha256:$pin"

Write-Host "Install-Nano, fresh:"
# No database answers in a sandbox, so the ready-wait is answered here; the
# real one is exercised below on its timeout path.
$script:RealWaitNanoReady = (Get-Command Wait-NanoReady).ScriptBlock
function Wait-NanoReady { param([switch]$Fatal) return $true }
Put "secret_size" "0"
ClearCalls
Install-Nano
Check "no soft failure" $false $script:NanoNoDatabase
$run = RunLine
Check "pulled the advertised image" $true (HasCall "pull $image")
Check "run names the container" $true ($run -like "*--name exasol-nano*")
Check "publishes the port on the loopback" $true ($run -like "*-p 127.0.0.1:18563:8563*")
Check "mounts the data volume" $true ($run -like "*-v exasol-nano-data:/exa*")
Check "the first deploy reads the password file" $true ($run -like "*init sys_password_file=/run/secrets/sys_password")
Check "the password file is mounted read-only" $true ($run -like "*:/run/secrets/sys_password:ro*")
Check "the image limits" $true ($run -like "*--shm-size=512mb --pids-limit=-1*")
Check "no restart policy before autostart is on" $false ($run -like "*--restart*")
Check "the credential is written" $true (Test-Path (Join-Path $env:EXAKIT_HOME "credentials/nano_sys_password"))
Check "runtime.type" "nano" (Get-ExakitManifestValue "runtime.type")
Check "runtime.engine" "docker" (Get-ExakitManifestValue "runtime.engine")
Check "runtime.image" $image (Get-ExakitManifestValue "runtime.image")
Check "runtime.version is the tag" $advertised (Get-ExakitManifestValue "runtime.version")
Check "runtime.container" "exasol-nano" (Get-ExakitManifestValue "runtime.container")
Check "runtime.volume" "exasol-nano-data" (Get-ExakitManifestValue "runtime.volume")
Check "runtime.dsn" "127.0.0.1:18563" (Get-ExakitManifestValue "runtime.dsn")
Check "runtime.user" "sys" (Get-ExakitManifestValue "runtime.user")
Check "runtime.password_file" $true (("" + (Get-ExakitManifestValue "runtime.password_file")).EndsWith("nano_sys_password"))
Check "runtime.tls" "self-signed" (Get-ExakitManifestValue "runtime.tls")
Check "runtime.status" "running" (Get-ExakitManifestValue "runtime.status")
Check "no launcher key" "" ("" + (Get-ExakitManifestValue "runtime.launcher"))

Write-Host "Install-Nano adopts and resumes:"
Put "logs" "Database is now up and running!"
ClearCalls
Install-Nano
Check "a running container is adopted, not recreated" $false (HasCall "run *")
Put "running" "false"; ClearCalls
Install-Nano
Check "a stopped first-deploy container is removed" $true (HasCall "rm -f exasol-nano")
Check "and recreated over the volume" $true ((RunLine) -like "*-v exasol-nano-data:/exa*")
Check "without the single-use init arguments" $false ((RunLine) -like "*init*")
Put "running" "false"; ClearCalls
Install-Nano
Check "a plain stopped container is started" $true (HasCall "start exasol-nano")
Check "not recreated" $false (HasCall "run *")

Write-Host "Install-Nano soft paths:"
Gone "container"
$listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 18563)
$listener.Start()
Install-Nano
Check "a busy port is a soft failure" $true $script:NanoNoDatabase
$listener.Stop()
Put "repodigests" "docker.io/exasol/nano@sha256:0000000000000000000000000000000000000000000000000000000000000000"
ClearCalls
Install-Nano
Check "a pin mismatch is a soft failure" $true $script:NanoNoDatabase
Check "and nothing is started" $false (HasCall "run *")
Put "repodigests" "docker.io/exasol/nano@sha256:$pin"
Gone "image_removed"
$env:NANO_STUB_DOWN = "1"; Reset-NanoEngineCache
Install-Nano
Check "an engine that is down is a soft failure" $true $script:NanoNoDatabase
Remove-Item Env:NANO_STUB_DOWN; Reset-NanoEngineCache

Write-Host "the restart policy follows autostart:"
Set-ExakitManifestValue "autostart.enabled" $true
ClearCalls
Install-Nano
Check "created with --restart unless-stopped" $true ((RunLine) -like "*--restart unless-stopped*")
Check "Set-NanoRestartPolicy on" $true (Set-NanoRestartPolicy -Enabled $true)
Check "policy recorded" "unless-stopped" ((Get-Content (StatePath "restart") -Raw).Trim())
Check "Set-NanoRestartPolicy off" $true (Set-NanoRestartPolicy -Enabled $false)
Check "policy cleared" "no" ((Get-Content (StatePath "restart") -Raw).Trim())
Check "the autostart command starts the container" $true ((Get-NanoAutostartCommand) -like '*" start exasol-nano')
Set-ExakitManifestValue "autostart.enabled" $false

Write-Host "stop, start, remove:"
Stop-Nano
Check "stopped" "false" ((Get-Content (StatePath "running") -Raw).Trim())
Check "runtime.status stopped" "stopped" (Get-ExakitManifestValue "runtime.status")
Check "Get-NanoStatus stopped" "stopped" (Get-NanoStatus)
ClearCalls
Start-Nano
Check "started" "true" ((Get-Content (StatePath "running") -Raw).Trim())
Put "volume" "1"
Remove-Nano
Check "container removed" $false (Test-Path (StatePath "container"))
Check "volume kept without -Data" $true (Test-Path (StatePath "volume"))
Put "container" "1"; Put "running" "true"
Remove-Nano -Data
Check "volume removed with -Data" $false (Test-Path (StatePath "volume"))
Check "runtime.status removed" "removed" (Get-ExakitManifestValue "runtime.status")

Write-Host "update:"
Put "container" "1"; Put "running" "true"; Put "cmd" "[]"; Put "image" "docker.io/exasol/nano:2020.1.0-nano.1"; Put "volume" "1"
Set-ExakitManifestValue "runtime.image" "docker.io/exasol/nano:2020.1.0-nano.1"
ClearCalls
Update-Nano -Advertised $advertised
Check "pulled the advertised tag" $true (HasCall "pull $image")
Check "stopped the old container" $true (HasCall "stop -t 60 exasol-nano")
Check "removed the old container" $true (HasCall "rm -f exasol-nano")
Check "ran the new image over the volume" $true ((RunLine) -like "*-v exasol-nano-data:/exa $image")
Check "runtime.version moved" $advertised (Get-ExakitManifestValue "runtime.version")
Check "desired.nano recorded" $advertised (Get-ExakitManifestValue "desired.nano")
Check "a snapshot record exists" $true ((Get-ChildItem (Join-Path $env:EXAKIT_HOME "backups/nano-update") -Filter "*.json").Count -ge 1)
ClearCalls
Update-Nano -Advertised $advertised
Check "already current: nothing run" $false (HasCall "run *")

Write-Host "the real ready-wait gives up without a handshake:"
Set-Item function:Wait-NanoReady $script:RealWaitNanoReady
$script:NanoReadyTimeout = 1
Put "running" "true"; Put "logs" "booting"
Check "times out" $false (Wait-NanoReady)
Check "a stopped container ends the wait" $false $(Put "running" "false"; Wait-NanoReady)

Write-Host "the Docker Hub tag parser:"
function Invoke-RestMethod {
    param($Uri, [switch]$UseBasicParsing, $TimeoutSec)
    return [pscustomobject]@{ results = @(
        @{ name = "latest" }, @{ name = "2026.2.0-nano.6-arm64" }, @{ name = "2026.3.0-nano.1" },
        @{ name = "2026.2.0-nano.9" }, @{ name = "exasol-nano-db-2026.2.0-nano.6-x86_64.run" }, @{ name = "2026.10.0-nano.2" }
    ) }
}
Check "the highest plain nano tag" "2026.10.0-nano.2" (Get-NanoLatestTag)

Write-Host ""
Write-Host "$($script:PASS) passed, $($script:FAIL) failed"
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
if ($script:FAIL -gt 0) { exit 1 }
exit 0
