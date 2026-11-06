# personal-engine-ps.ps1 - which container engine a NEW Exasol Personal
# deployment gets on Windows, and how an existing one keeps its own. Twin of
# tests/personal-engine.sh for setup/lib/runtime-personal.ps1.
#
#   pwsh -NoProfile -File tests/personal-engine-ps.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/personal-engine-ps.ps1
#
# Stub docker and launcher commands on PATH; never touches a real one.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label = $actual" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected [$expected], got [$actual]" }
}
function Has($label, $needle, $haystack) {
    if (("" + $haystack).Contains($needle)) { Check $label "present" "present" } else { Check $label "present" "MISSING ($haystack)" }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-engine-ps-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:EXAKIT_HOME = Join-Path $work "home"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
$env:EXAKIT_PERSONAL_DEPLOY_DIR = Join-Path $work "no-deployment"
New-Item -ItemType Directory -Force -Path $env:EXAKIT_HOME | Out-Null
Set-Content -Path (Join-Path $env:EXAKIT_HOME "manifest.json") -Encoding Ascii -Value '{"manifest_version": 1}'
Remove-Item Env:EXAKIT_CONTAINER_ENGINE -ErrorAction SilentlyContinue
. (Join-Path $repo "setup/lib/exakit-common.ps1")
. (Join-Path $repo "setup/lib/runtime-personal.ps1")

# $env:OS, not $IsWindows: the automatic variable does not exist on 5.1.
$onWindows = ($env:OS -like "*Windows*")

# A docker that answers `docker info --format ...` with $env:STUB_DOCKER_INFO,
# or fails like a stopped daemon when $env:STUB_DOCKER_FAIL is 1.
$stubDir = Join-Path $work "stubs"
New-Item -ItemType Directory -Force -Path $stubDir | Out-Null
if ($onWindows) {
    Set-Content -Path (Join-Path $stubDir "docker.cmd") -Encoding Ascii -Value @(
        "@echo off",
        "if `"%STUB_DOCKER_FAIL%`"==`"1`" (echo Cannot connect to the Docker daemon 1>&2",
        "exit /b 1)",
        "echo %STUB_DOCKER_INFO%"
    )
    Set-Content -Path (Join-Path $stubDir "exasol-stub.cmd") -Encoding Ascii -Value @(
        "@echo off",
        "if `"%~1 %~2`"==`"install --help`" (echo       --auto-approve",
        "if `"%STUB_HELP_ENGINE%`"==`"1`" echo       --container-engine string   Container engine",
        "exit /b 0)",
        "exit /b 0"
    )
} else {
    $docker = Join-Path $stubDir "docker"
    Set-Content -Path $docker -Value @(
        "#!/bin/sh",
        "if [ `"`${STUB_DOCKER_FAIL:-0}`" = 1 ]; then echo 'Cannot connect to the Docker daemon' >&2; exit 1; fi",
        "printf '%s\n' `"`$STUB_DOCKER_INFO`""
    )
    chmod +x $docker
    $launcher = Join-Path $stubDir "exasol-stub"
    Set-Content -Path $launcher -Value @(
        "#!/bin/sh",
        "if [ `"`$1 `$2`" = 'install --help' ]; then",
        "  printf '      --auto-approve\n'",
        "  [ `"`${STUB_HELP_ENGINE:-1}`" = 1 ] && printf '      --container-engine string   Container engine\n'",
        "fi",
        "exit 0"
    )
    chmod +x $launcher
}
$pathSep = [System.IO.Path]::PathSeparator
$pathWithStubs = $stubDir + $pathSep + $env:PATH
$env:PATH = $pathWithStubs
$env:STUB_HELP_ENGINE = "1"
function Get-PersonalCli { if ($onWindows) { return (Join-Path $stubDir "exasol-stub.cmd") } else { return (Join-Path $stubDir "exasol-stub") } }
# Set-PersonalManifest asks these of the launcher and the deployment on disk.
function Get-PersonalDeployedVersion { return "2.4.0" }
function Get-PersonalLauncherVersion { return "2.4.0" }
function Get-PersonalStatus { return "running" }
function Warn2([string]$Msg) { $script:lastWarn = $Msg }
function Info([string]$Msg) { $script:lastInfo = $Msg }

function Resolve([string]$info, [string]$fail = "0") {
    $env:STUB_DOCKER_INFO = $info
    $env:STUB_DOCKER_FAIL = $fail
    $script:PersonalDockerSaid = ""
    return ("" + (Resolve-PersonalEngine))
}

Write-Host "Resolve-PersonalEngine: Docker when usable, else Podman, said once"
Check "Docker 29 -> docker"               "docker" (Resolve "linux 29.1.0")
Check "Docker 28 -> podman"               "podman" (Resolve "linux 28.3.1")
Has   "  and says why"                    "older than 29" $script:PersonalDockerSaid
Check "Windows containers -> podman"      "podman" (Resolve "windows 29.0.0")
Has   "  and says why"                    "Linux containers" $script:PersonalDockerSaid
Check "daemon down (no console) -> podman" "podman" (Resolve "" "1")
Has   "  and says why"                    "not running" $script:PersonalDockerSaid
Has   "  on the one line it prints"       "the database will run on Podman" $script:lastInfo
# An empty PATH, not merely one without the stubs: the machine running this
# test may well have a real docker further down.
$env:PATH = $work
$script:lastInfo = ""
Check "no docker at all -> podman"        "podman" (Resolve "linux 29.1.0")
Check "  silently"                        "" $script:lastInfo
$env:PATH = $pathWithStubs

Write-Host ""
Write-Host "EXAKIT_CONTAINER_ENGINE names one and is never swapped"
$env:EXAKIT_CONTAINER_ENGINE = "podman"
Check "podman named, Docker usable -> podman" "podman" (Resolve "linux 29.1.0")
$env:EXAKIT_CONTAINER_ENGINE = "docker"
Check "docker named, usable -> docker"    "docker" (Resolve "linux 29.1.0")
$script:ExakitFailureReason = $null
Check "docker named, down -> refused"     "" (Resolve "" "1")
Has   "  with the reason"                 "EXAKIT_CONTAINER_ENGINE=docker, but Docker is installed but not running" $script:lastWarn
Check "  -Probe still answers docker"     "docker" ("" + (Resolve-PersonalEngine -Probe))
Remove-Item Env:EXAKIT_CONTAINER_ENGINE
$script:lastInfo = ""
Check "-Probe, daemon down -> podman"     "podman" ("" + (Resolve-PersonalEngine -Probe))
Check "  without a line"                  "" $script:lastInfo

Write-Host ""
Write-Host "Get-PersonalEngineFlag: passed only to a launcher that takes it"
Check "2.4 launcher" "--container-engine docker" ((Get-PersonalEngineFlag "docker") -join " ")
$env:STUB_HELP_ENGINE = "0"
Check "2.3 launcher" "" ((Get-PersonalEngineFlag "docker") -join " ")
$env:STUB_HELP_ENGINE = "1"
Check "no engine"    "" ((Get-PersonalEngineFlag "") -join " ")

Write-Host ""
Write-Host "Get-PersonalEngineRecorded: the record's engine, Podman when it has none"
Check "no record -> podman"   "podman" (Get-PersonalEngineRecorded)
Set-ExakitManifestValue "runtime.engine" "docker"
Check "docker recorded"       "docker" (Get-PersonalEngineRecorded)
Set-ExakitManifestValue "runtime.container" "exasol-nano"
Check "nano record -> podman" "podman" (Get-PersonalEngineRecorded)
Remove-ExakitManifestValue "runtime.container"
Remove-ExakitManifestValue "runtime.engine"

Write-Host ""
Write-Host "Set-PersonalManifest: runtime.engine written from this run, else the record"
$script:PersonalEngine = "docker"
Set-PersonalManifest "healthy"
Check "this run chose docker"        "docker" (Get-ExakitManifestValue "runtime.engine")
$script:PersonalEngine = ""
Set-PersonalManifest "healthy"
Check "an update keeps docker"       "docker" (Get-ExakitManifestValue "runtime.engine")
Set-ExakitManifestValue "runtime.container" "exasol-nano"
$script:PersonalEngine = "podman"
Set-PersonalManifest "healthy"
Check "nano record crossed -> podman" "podman" (Get-ExakitManifestValue "runtime.engine")
Check "  old engine kept as legacy"  "docker" (Get-ExakitManifestValue "legacy.engine")
Remove-ExakitManifestValue "runtime.engine"
$script:PersonalEngine = ""
Set-PersonalManifest "healthy"
Check "pre-0.2.4 record -> podman"   "podman" (Get-ExakitManifestValue "runtime.engine")

Write-Host ""
Write-Host "the deploy and the gate read the engine"
$src = Get-Content -Raw (Join-Path $repo "setup/lib/runtime-personal.ps1")
Has "install local carries the flag"       '$installArgs += Get-PersonalEngineFlag $script:PersonalEngine' $src
Has "the rootful check is Podman-only"     '((Resolve-PersonalEngine -Probe) -eq "podman")' $src
Has "a Docker deployment is checked as one" 'Test-PersonalEngineRunning "docker"' $src

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "personal-engine-ps.ps1: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
