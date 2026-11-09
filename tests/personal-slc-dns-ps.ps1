# personal-slc-dns-ps.ps1 - the Windows twin of the language container DNS
# repair: Repair-PersonalSlcDns in setup/lib/runtime-personal.ps1 asks the
# deployment's own engine (Docker or Podman) and names its database container
# by the deployment id. The helper it runs, setup/lib/personal-slc-dns.py, is
# exercised byte for byte by tests/personal-slc-dns.sh; here it is replaced by
# a recorder, so this suite pins what the PowerShell side hands it.
#
#   pwsh -NoProfile -File tests/personal-slc-dns-ps.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/personal-slc-dns-ps.ps1
#
# Stub docker and podman commands on PATH; never touches a real one.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected [$expected], got [$actual]" }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-slc-dns-ps-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:EXAKIT_HOME = Join-Path $work "home"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
$dep = Join-Path $work "dep"
$env:EXAKIT_PERSONAL_DEPLOY_DIR = $dep
New-Item -ItemType Directory -Force -Path $env:EXAKIT_HOME, $dep | Out-Null
$manifest = Join-Path $env:EXAKIT_HOME "manifest.json"
Set-Content -Path $manifest -Encoding Ascii -Value '{"manifest_version": 1}'
. (Join-Path $repo "setup/lib/exakit-common.ps1")
. (Join-Path $repo "setup/lib/runtime-personal.ps1")

# $env:OS, not $IsWindows: the automatic variable does not exist on 5.1.
$onWindows = ($env:OS -like "*Windows*")

# Engine stubs, found by Get-Command only: the helper never runs here. One
# directory with both, one with Podman alone, one with neither.
function New-EngineStub([string]$Dir, [string]$Name) {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    if ($onWindows) {
        Set-Content -Path (Join-Path $Dir "$Name.cmd") -Encoding Ascii -Value @("@echo off", "exit /b 0")
    } else {
        $file = Join-Path $Dir $Name
        Set-Content -Path $file -Encoding Ascii -Value @("#!/bin/sh", "exit 0")
        chmod +x $file
    }
}
$both = Join-Path $work "both"; New-EngineStub $both "docker"; New-EngineStub $both "podman"
$podmanOnly = Join-Path $work "podman-only"; New-EngineStub $podmanOnly "podman"
$none = Join-Path $work "none"; New-Item -ItemType Directory -Force -Path $none | Out-Null
$realPath = $env:PATH

# The kit around the repair, replaced.
function Get-PersonalSlcInstalledFlavors { return @("java-17") }
$script:helperCalls = New-Object System.Collections.ArrayList
$script:helperLines = @("EXAKIT_SLC_DNS java-17 repaired")
function Invoke-ExakitPythonFile {
    param([string]$Path, [string[]]$Arguments = @(), [switch]$Live)
    [void]$script:helperCalls.Add(((Split-Path -Leaf $Path) + " " + ($Arguments -join " ")))
    $script:emptyArgument = @($Arguments | Where-Object { "$_" -eq "" }).Count
    return [pscustomobject]@{ Code = $script:helperCode; Lines = $script:helperLines }
}
$script:helperCode = 0
$script:logged = New-Object System.Collections.ArrayList
function Write-ExakitLog { param($Level, $Message) [void]$script:logged.Add("$Level $Message") }
$script:shown = New-Object System.Collections.ArrayList
function Info([string]$Msg) { [void]$script:shown.Add("INFO $Msg") }

function Set-Record([string]$Runtime) {
    Set-Content -Path $manifest -Encoding Ascii -Value ('{"manifest_version": 1' + $Runtime + '}')
}
function Set-DeploymentId([string]$Id) {
    $file = Join-Path $dep "deployment.json"
    if ($Id) { Set-Content -Path $file -Encoding Ascii -Value ('{"deploymentId": "' + $Id + '", "dbPort": 8563}') }
    else { Remove-Item -Force -Path $file -ErrorAction SilentlyContinue }
}
# Repair <PATH dir> - one repair with only that directory on PATH; returns
# "<result> | <the helper's arguments, or none>".
function Repair([string]$Dir) {
    $script:helperCalls.Clear(); $script:logged.Clear(); $script:shown.Clear()
    $env:PATH = $Dir
    try { $ok = Repair-PersonalSlcDns } finally { $env:PATH = $realPath }
    $call = if ($script:helperCalls.Count -gt 0) { $script:helperCalls[0] } else { "none" }
    return "$ok | $call"
}

Write-Host ""
Write-Host "== the deployment's engine is the one asked =="
Set-DeploymentId "exa-7f3a"
$script:PersonalEngine = ""
Set-Record ', "runtime": {"type": "personal", "engine": "docker"}'
Check "Docker recorded: the helper runs with --engine docker and the deployment id" `
    "True | personal-slc-dns.py --engine docker --deployment-id=exa-7f3a java-17" (Repair $both)
Check "...and says what it repaired" "INFO Gave the java-17 language container the deployment's DNS" ($script:shown -join "|")
Set-Record ', "runtime": {"type": "personal", "engine": "podman"}'
Check "Podman recorded: --engine podman" "True | personal-slc-dns.py --engine podman --deployment-id=exa-7f3a java-17" (Repair $both)
Set-Record ', "runtime": {"type": "personal"}'
Check "no engine recorded (before kit 0.2.4): podman, as before" `
    "True | personal-slc-dns.py --engine podman --deployment-id=exa-7f3a java-17" (Repair $both)
Set-Record ', "runtime": {"engine": "docker", "container": "exasol-nano"}'
Check "a nano record's engine is the OLD database's: podman" `
    "True | personal-slc-dns.py --engine podman --deployment-id=exa-7f3a java-17" (Repair $both)
Set-Record ', "runtime": {"engine": "docker", "container": null}'
Check "...runtime.container null is a nano record too (as the shell reads it)" `
    "True | personal-slc-dns.py --engine podman --deployment-id=exa-7f3a java-17" (Repair $both)
Set-Record ', "runtime": {"engine": "docker", "container": ""}'
Check "...an empty runtime.container is none: the record's docker" `
    "True | personal-slc-dns.py --engine docker --deployment-id=exa-7f3a java-17" (Repair $both)
Set-Record ', "runtime": {"type": "personal"}'
$script:PersonalEngine = "docker"
Check "nothing recorded: this run's choice (an install not recorded yet)" `
    "True | personal-slc-dns.py --engine docker --deployment-id=exa-7f3a java-17" (Repair $both)
Set-Record ', "runtime": {"type": "personal", "engine": "podman"}'
Check "the record beats this run's choice" `
    "True | personal-slc-dns.py --engine podman --deployment-id=exa-7f3a java-17" (Repair $both)
$script:PersonalEngine = ""

Write-Host ""
Write-Host "== an engine that is not there =="
Set-Record ', "runtime": {"type": "personal", "engine": "docker"}'
Check "Docker recorded, no docker on PATH: false, the helper not run" "False | none" (Repair $podmanOnly)
Check "...logged by name" "WARN language container DNS: no docker on PATH" ($script:logged -join "|")
Set-Record ', "runtime": {"type": "personal"}'
Check "no engine at all: false, as before" "False | none" (Repair $none)
Check "...logged by name" "WARN language container DNS: no podman on PATH" ($script:logged -join "|")

Write-Host ""
Write-Host "== a helper that never answered =="
# Every caller ignores the result, so the log line is all a reader gets.
Set-Record ', "runtime": {"type": "personal", "engine": "docker"}'
$script:helperCode = 2; $script:helperLines = @()
Check "no EXAKIT_SLC_DNS line: false" "False | personal-slc-dns.py --engine docker --deployment-id=exa-7f3a java-17" (Repair $both)
Check "...and one WARN line with the exit code" "WARN language container DNS repair did not run (exit 2): no output (its stderr is in the PY lines above)" ($script:logged -join "|")
$script:helperLines = @("Traceback (most recent call last):")
[void](Repair $both)
Check "...or the first line it printed" "WARN language container DNS repair did not run (exit 2): Traceback (most recent call last):" ($script:logged -join "|")
$script:helperCode = 0; $script:helperLines = @("EXAKIT_SLC_DNS java-17 repaired")

Write-Host ""
Write-Host "== the deployment id =="
Set-DeploymentId ""
Set-Record ', "runtime": {"type": "personal", "engine": "docker"}'
Check "no id to read: no --deployment-id at all" "True | personal-slc-dns.py --engine docker java-17" (Repair $both)
Check "...and no empty argument (5.1 drops it and shifts the rest)" 0 $script:emptyArgument
Set-DeploymentId "exa-7f3a"

# The same fixtures as tests/personal-slc-dns.sh, through Get-PersonalSlcContainerId.
$stateFile = Join-Path $dep ".exasolLauncherState.json"
$depFile = Join-Path $dep "deployment.json"
function Set-State([string]$State, [string]$Deployment) {
    foreach ($pair in @(@($stateFile, $State), @($depFile, $Deployment))) {
        if ($pair[1] -eq "-") { Remove-Item -Force -LiteralPath $pair[0] -ErrorAction SilentlyContinue }
        else { Set-Content -LiteralPath $pair[0] -Encoding Ascii -Value $pair[1] }
    }
}
Set-State '{"currentWorkflowState": {"running": {}}, "deploymentId": "  exa-7f3a "}' '{"deploymentId": "local"}'
Check "the launcher's state file first, trimmed; deployment.json's local ignored" "exa-7f3a" (Get-PersonalSlcContainerId)
Check "...and that id reaches the helper" "True | personal-slc-dns.py --engine docker --deployment-id=exa-7f3a java-17" (Repair $both)
Set-State '{"deploymentId": "aaaa1111"}' '{"deploymentId": "bbbb2222"}'
Check "state and deployment.json disagree: the state's id" "aaaa1111" (Get-PersonalSlcContainerId)
Set-State '{"nested": {"deploymentId": "nested-id"}, "deploymentId": "top-id", "x": {"deploymentId": "later-id"}}' "-"
Check "the top-level key, not an occurrence before or after it" "top-id" (Get-PersonalSlcContainerId)
Set-State '{"nested": {"deploymentId": "nested-id"}}' '{"deploymentId": "bbbb2222"}'
Check "a state file with none at the top: deployment.json's" "bbbb2222" (Get-PersonalSlcContainerId)
Set-State '{not json' '{"deploymentId": "bbbb2222"}'
Check "an unreadable state file: deployment.json's" "bbbb2222" (Get-PersonalSlcContainerId)
Set-State '{"deploymentId": "   "}' "-"
Check "a blank id is none" "" (Get-PersonalSlcContainerId)
Set-State "-" "-"
Check "no state at all: none" "" (Get-PersonalSlcContainerId)
Set-State '{"deploymentId": "-x7"}' "-"
Check "an id starting with - goes in the = form" "True | personal-slc-dns.py --engine docker --deployment-id=-x7 java-17" (Repair $both)
Set-State "-" "-"
Set-DeploymentId "exa-7f3a"

Write-Host ""
Write-Host "== what the helper says =="
$script:helperLines = @("EXAKIT_SLC_DNS - nocontainer")
Check "no database container: false" "False | personal-slc-dns.py --engine docker --deployment-id=exa-7f3a java-17" (Repair $both)
Check "...logged" "INFO language container DNS: -:nocontainer" ($script:logged -join "|")
$script:helperLines = @("EXAKIT_SLC_DNS java-17 ok")
Check "already repaired: true, nothing said" "True | personal-slc-dns.py --engine docker --deployment-id=exa-7f3a java-17" (Repair $both)
Check "...nothing shown" "" ($script:shown -join "|")
Check "...nothing for the next start to do" "False" $script:PersonalSlcDnsNeedsStart

Write-Host ""
Write-Host "== Docker: the image linked (derived) =="
$script:helperLines = @("EXAKIT_SLC_DNS java-17 derived")
Check "linked in the image: false, for now" "False | personal-slc-dns.py --engine docker --deployment-id=exa-7f3a java-17" (Repair $both)
Check "...the next start is what it needs" "True" $script:PersonalSlcDnsNeedsStart
Check "...and says so" "INFO Gave the java-17 language container image the deployment's DNS; the database sees it from its next start" ($script:shown -join "|")
$script:helperLines = @("EXAKIT_SLC_DNS java-17 ok")
[void](Repair $both)
Check "a repair after it starts afresh: nothing pending" "False" $script:PersonalSlcDnsNeedsStart
$script:helperLines = @("EXAKIT_SLC_DNS java-17 derived", "EXAKIT_SLC_DNS - nocontainer")
Check "derived beside a failure: false, and no restart offered for it" "False | False" ("$((Repair $both).Split('|')[0].Trim()) | $script:PersonalSlcDnsNeedsStart")

Write-Host ""
Write-Host "== Docker, before a start (Initialize-PersonalSlcDns) =="
$stateFile = Join-Path $dep ".exasolLauncherState.json"
# Prepare <PATH dir> [-Pull] - one Initialize-PersonalSlcDns with only that
# directory on PATH; returns the helper's arguments, or none.
function Prepare([string]$Dir, [switch]$Pull) {
    $script:helperCalls.Clear(); $script:logged.Clear(); $script:shown.Clear()
    $env:PATH = $Dir
    try { Initialize-PersonalSlcDns -Pull:$Pull } finally { $env:PATH = $realPath }
    if ($script:helperCalls.Count -gt 0) { return $script:helperCalls[0] }
    return "none"
}
Set-Content -LiteralPath $stateFile -Encoding Ascii -Value '{"deploymentId": "exa-7f3a", "installedSlcs": [{"flavor": "java-17", "image": "docker.io/exa/slc:java-17"}]}'
$script:helperLines = @("EXAKIT_SLC_DNS java-17 derived")
Set-Record ', "runtime": {"type": "personal", "engine": "docker"}'
Check "Docker: the helper links the images the launcher state lists" "personal-slc-dns.py --engine docker --prepare $stateFile" (Prepare $both)
Check "...and says so" "INFO Gave the java-17 language container image the deployment's DNS" ($script:shown -join "|")
Check "...logged" "INFO language container DNS (before the start): java-17:derived" ($script:logged -join "|")
Check "-Pull: the helper pulls a missing image first" "personal-slc-dns.py --engine docker --prepare $stateFile --pull" (Prepare $both -Pull)
Set-Record ', "runtime": {"type": "personal", "engine": "podman"}'
Check "Podman: nothing (its mount is writable, repaired after the start)" "none" (Prepare $both)
Set-Record ', "runtime": {"type": "personal", "engine": "docker"}'
Check "no docker on PATH: nothing" "none" (Prepare $podmanOnly)
Remove-Item -Force -LiteralPath $stateFile
Check "no launcher state file: nothing" "none" (Prepare $both)

Write-Host ""
Write-Host "== wiring =="
$runtimeText = Get-Content -Raw -LiteralPath (Join-Path $repo "setup/lib/runtime-personal.ps1")
$startText = $runtimeText.Substring($runtimeText.IndexOf("function Start-Personal"))
$startText = $startText.Substring(0, $startText.IndexOf("function Get-PersonalSlcInstalledFlavors"))
$initAt = $startText.IndexOf("try { Initialize-PersonalSlcDns }")
$launchAt = $startText.IndexOf('if ((Invoke-ExakitLogged (Get-PersonalCli) @startArgs) -ne 0) {')
Check "Start-Personal links the images before the launcher's start" "True" (($initAt -gt 0) -and ($initAt -lt $launchAt))
Check "...and restarts once when the repair after it needs a start" "True" ($startText.Contains('if ($script:PersonalSlcDnsNeedsStart) {') -and $startText.Contains('(Invoke-ExakitLogged (Get-PersonalCli) stop) -ne 0 -or (Invoke-ExakitLogged (Get-PersonalCli) @startArgs) -ne 0'))
$vsText = Get-Content -Raw -LiteralPath (Join-Path $repo "setup/lib/virtual-schemas.ps1")
$javaText = $vsText.Substring($vsText.IndexOf("function Install-ExakitVsJava"))
$javaText = $javaText.Substring(0, $javaText.IndexOf("function Restart-ExakitVsDatabase"))
Check "the Java install pulls and links before its restart" "True" ($javaText.IndexOf("Initialize-PersonalSlcDns -Pull") -gt 0 -and $javaText.IndexOf("Initialize-PersonalSlcDns -Pull") -lt $javaText.IndexOf("Restart-ExakitVsDatabase"))
Check "exit 20 on Docker asks before it restarts" "True" ($vsText.Contains('if (-not (Confirm-ExakitVs "Restart the database now?")) {'))

Remove-Item -Recurse -Force -Path $work -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "$($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
exit 0
