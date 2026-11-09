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
        "if `"%~1`"==`"ps`" (echo %STUB_DOCKER_PS%",
        "exit /b 0)",
        "if `"%STUB_DOCKER_FAIL%`"==`"1`" (echo %STUB_DOCKER_ERR% 1>&2",
        "exit /b 1)",
        "echo %STUB_DOCKER_INFO%"
    )
    Set-Content -Path (Join-Path $stubDir "exasol-stub.cmd") -Encoding Ascii -Value @(
        "@echo off",
        "if `"%~1 %~2 %~3`"==`"install local --help`" (echo       --auto-approve",
        "if `"%STUB_HELP_ENGINE%`"==`"1`" echo       --container-engine string   Container engine",
        "exit /b 0)",
        "exit /b 0"
    )
} else {
    $docker = Join-Path $stubDir "docker"
    Set-Content -Path $docker -Value @(
        "#!/bin/sh",
        "if [ `"`$1`" = ps ]; then printf '%s\n' `"`$STUB_DOCKER_PS`"; exit 0; fi",
        "[ -n `"`${STUB_DOCKER_CALLS:-}`" ] && echo x >> `"`$STUB_DOCKER_CALLS`"",
        "if [ `"`${STUB_DOCKER_FAIL:-0}`" = 1 ]; then echo `"`$STUB_DOCKER_ERR`" >&2; exit 1; fi",
        "printf '%s\n' `"`$STUB_DOCKER_INFO`""
    )
    chmod +x $docker
    $launcher = Join-Path $stubDir "exasol-stub"
    Set-Content -Path $launcher -Value @(
        "#!/bin/sh",
        "if [ `"`$1 `$2 `$3`" = 'install local --help' ]; then",
        "  [ -n `"`${STUB_HELP_CALLS:-}`" ] && echo x >> `"`$STUB_HELP_CALLS`"",
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
$env:STUB_DOCKER_ERR = "Cannot connect to the Docker daemon"
$env:STUB_DOCKER_PS = ""
$env:EXAKIT_DOCKER_WAIT_STEP = "0"
function Get-PersonalCli { if ($onWindows) { return (Join-Path $stubDir "exasol-stub.cmd") } else { return (Join-Path $stubDir "exasol-stub") } }
# Set-PersonalManifest asks these of the launcher and the deployment on disk.
# $script:StubDeployed: the version the deployment's state names ("" = unreadable).
$script:StubDeployed = "2.4.0"
function Get-PersonalDeployedVersion { if ($script:StubDeployed) { return $script:StubDeployed }; return $null }
function Get-PersonalLauncherVersion { return "2.4.0" }
function Get-PersonalStatus { return "running" }
function Warn2([string]$Msg) { $script:lastWarn = $Msg }
function Info([string]$Msg) { $script:lastInfo = $Msg }

# NO CONSOLE UNLESS A CASE ASKS FOR ONE: from a terminal without -NonInteractive
# the "daemon down (no console)" case reached Read-Host and hung (WINR-05).
$realPromptable = ${function:Test-PersonalPromptable}
function Test-PersonalPromptable { return $false }

# The Docker and launcher verdicts are kept per process (WINR-02); every case
# that changes a stub's answer starts from a clean slate.
function Reset-Caches {
    $script:PersonalDockerCache = $null
    $script:PersonalLauncherCache = $null
}
function Resolve([string]$info, [string]$fail = "0") {
    $env:STUB_DOCKER_INFO = $info
    $env:STUB_DOCKER_FAIL = $fail
    $script:PersonalDockerSaid = ""
    Reset-Caches
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
$env:STUB_HELP_ENGINE = "0"; Reset-Caches
Check "2.3 launcher" "" ((Get-PersonalEngineFlag "docker") -join " ")
$env:STUB_HELP_ENGINE = "1"; Reset-Caches
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
Has "the rootful remedy is Podman-only"    'if ($engine -ne "podman") { return }' $src
Check "the gate probes no Podman machine"  $false ($src.Contains('"machine", "inspect"'))

Write-Host ""
Write-Host "Show-PersonalPodmanRootfulHint: a remedy on Podman, silence on Docker"
$savedEngine = $script:PersonalEngine
$script:PersonalEngine = "podman"; $script:lastInfo = ""
Show-PersonalPodmanRootfulHint
Has "podman names the rootless switch"     "podman machine set --rootful=false" $script:lastInfo
$script:PersonalEngine = "docker"; $script:lastInfo = ""
Show-PersonalPodmanRootfulHint
Check "docker says nothing about it"       "" $script:lastInfo
$script:PersonalEngine = ""; $script:lastInfo = ""
Set-ExakitManifestValue "runtime.engine" "docker"
Show-PersonalPodmanRootfulHint
Check "a recorded docker deployment neither" "" $script:lastInfo
Remove-ExakitManifestValue "runtime.engine"
$script:PersonalEngine = $savedEngine

Write-Host ""
Write-Host "Clear-PersonalStaleRecord: a Personal record keeps its engine (WIN-02)"
foreach ($k in @("runtime.engine", "runtime.container", "legacy.engine")) { Remove-ExakitManifestValue $k }
Set-ExakitManifestValue "runtime.engine" "docker"
Clear-PersonalStaleRecord
Check "resumed install keeps runtime.engine"  "docker" (Get-ExakitManifestValue "runtime.engine")
Check "  copies nothing to legacy"            "" ("" + (Get-ExakitManifestValue "legacy.engine"))
Check "  so the record still says docker"     "docker" (Get-PersonalEngineRecorded)
$script:PersonalEngine = ""
Set-PersonalManifest "healthy"; Set-PersonalManifest "healthy"
Check "two records keep docker"               "docker" (Get-ExakitManifestValue "runtime.engine")
Check "  with no phantom legacy.engine"       "" ("" + (Get-ExakitManifestValue "legacy.engine"))
Set-ExakitManifestValue "runtime.container" "exasol-nano"
Clear-PersonalStaleRecord
Check "a nano record still moves its engine"  "docker" (Get-ExakitManifestValue "legacy.engine")
Check "  out of runtime.*"                    "" ("" + (Get-ExakitManifestValue "runtime.engine"))
Remove-ExakitManifestValue "legacy.engine"

Write-Host ""
Write-Host "Docker only when the launcher can be told (WIN-03)"
$env:STUB_HELP_ENGINE = "0"
$script:lastInfo = ""
Check "Docker usable, older launcher -> podman" "podman" (Resolve "linux 29.1.0")
Has   "  and says why"                        "cannot be told which engine to use, so the database runs on Podman" $script:lastInfo
Check "  -Probe agrees"                       "podman" ("" + (Resolve-PersonalEngine -Probe))
$env:EXAKIT_CONTAINER_ENGINE = "docker"
Check "docker named, older launcher -> refused" "" (Resolve "linux 29.1.0")
Has   "  with that reason"                    "cannot be told which engine to use" $script:lastWarn
Remove-Item Env:EXAKIT_CONTAINER_ENGINE
$env:STUB_HELP_ENGINE = "1"

Write-Host ""
Write-Host "Test-PersonalDockerUsable keeps the reason"
$env:STUB_DOCKER_ERR = "permission denied while trying to connect to the Docker daemon"
Check "permission denied -> podman"           "podman" (Resolve "" "1")
Check "  kind"                                "denied" $script:PersonalDockerKind
Has   "  says what it is"                     "Docker is running but your user cannot use it" $script:PersonalDockerSaid
Has   "  says it before deploying (LNXR-06)"  "Joining the docker-users group and re-running will not move this deployment to Docker" $script:lastInfo
Has   "  names the way that does"             "'exakit uninstall' and reinstall with EXAKIT_CONTAINER_ENGINE=docker" $script:lastInfo
$env:STUB_DOCKER_ERR = "Cannot connect to the Docker daemon"

Write-Host ""
Write-Host "the Docker-stopped prompt never throws, and waits for a slow Docker (WIN-04, WSL-08)"
$origPromptable = ${function:Test-PersonalPromptable}
$origRead = ${function:Read-ExakitPrompt}
$origUsable = ${function:Test-PersonalDockerUsable}
if ([Environment]::GetCommandLineArgs() -match '^-noni') {
    function Test-ExakitInteractive { return $true }
    Check "-NonInteractive host -> no prompt"  $false (& $realPromptable)
}
function Test-PersonalPromptable { return $true }
function Read-ExakitPrompt { throw "PowerShell is in NonInteractive mode. Read and Prompt functionality is not available." }
$threw = "no"
try { $got = Resolve "" "1" } catch { $threw = "yes: $_" }
Check "a prompt that throws -> no throw"      "no" $threw
Check "  and Podman"                          "podman" $got
function Read-ExakitPrompt { return "" }
$script:usableCalls = 0
function Test-PersonalDockerUsable {
    $script:usableCalls++
    if ($script:usableCalls -le 3) { $script:PersonalDockerSaid = "Docker is installed but not running ('docker info' did not answer)"; $script:PersonalDockerKind = "down"; return $false }
    $script:PersonalDockerKind = ""; return $true
}
Check "answers on the third re-probe -> docker" "docker" ("" + (Resolve-PersonalEngine))
Check "  1 probe + 3 re-probes"               4 $script:usableCalls
$script:usableCalls = -10
$script:lastInfo = ""
Check "never answers -> podman"               "podman" ("" + (Resolve-PersonalEngine))
Has   "  and says so"                         "Docker still did not answer after about 30 s - the database will run on Podman" $script:lastInfo
Set-Item function:Test-PersonalPromptable $origPromptable
Set-Item function:Read-ExakitPrompt $origRead
Set-Item function:Test-PersonalDockerUsable $origUsable

Write-Host ""
Write-Host "adopting a deployment the kit did not record"
$dep = Join-Path $work "dep"
New-Item -ItemType Directory -Force -Path $dep | Out-Null
Set-Content -Path (Join-Path $dep "deployment.json") -Value '{"deploymentId":"exa-7f3a","dbPort":8563}'
$savedDir = $script:PersonalDeployDir
$script:PersonalDeployDir = $dep
foreach ($k in @("runtime.engine", "runtime.container")) { Remove-ExakitManifestValue $k }
$env:STUB_DOCKER_INFO = "linux 29.1.0"; $env:STUB_DOCKER_FAIL = "0"
$env:STUB_DOCKER_PS = "exa-7f3a-db-1"; Reset-Caches
Check "Docker lists its containers -> docker" "docker" (Get-PersonalEngineExisting -Quiet)
$env:STUB_DOCKER_PS = "something-else"
Check "Docker does not list it -> podman"     "podman" (Get-PersonalEngineExisting -Quiet)
$env:STUB_DOCKER_PS = "exa-7f3a-db-1"
Set-ExakitManifestValue "runtime.engine" "podman"
Check "a recorded engine wins"                "podman" (Get-PersonalEngineExisting -Quiet)
Remove-ExakitManifestValue "runtime.engine"
$env:STUB_DOCKER_PS = "exasol-nano`nmy-hexagon-app"
Set-Content -Path (Join-Path $dep "deployment.json") -Value '{"deploymentId":"exa","dbPort":8563}'
Check "id 'exa' is not a substring match (LNXR-05)" "podman" (Get-PersonalEngineExisting -Quiet)
foreach ($n in @("exa", "exa-db-1", "exa_db", "exasol_exa", "stack-exa")) {
    $env:STUB_DOCKER_PS = $n
    Check "  whole segment '$n' matches"     "docker" (Get-PersonalEngineExisting -Quiet)
}
Set-Content -Path (Join-Path $dep "deployment.json") -Value '{"deploymentId":"exa-7f3a","containerEngine":"docker"}'
$env:STUB_DOCKER_FAIL = "1"; Reset-Caches
Check "the launcher's state names docker -> docker (LNXR-04)" "docker" (Get-PersonalEngineExisting -Quiet)
Set-Content -Path (Join-Path $dep "deployment.json") -Value '{"deploymentId":"exa-7f3a","dbPort":8563}'
if (-not $onWindows) {
    $podmanStub = Join-Path $stubDir "podman"
    Set-Content -Path $podmanStub -Value @("#!/bin/sh", "if [ `"`$1`" = ps ]; then printf '%s\n' `"`$STUB_PODMAN_PS`"; fi", "exit 0")
    chmod +x $podmanStub
    $env:STUB_PODMAN_PS = "exa-7f3a-db-1"
    Check "Docker down, Podman lists it -> podman" "podman" (Get-PersonalEngineExisting -Quiet)
    $env:STUB_PODMAN_PS = ""
    Check "2.4 deployment, Docker down, Podman does not -> unknown" "" (Get-PersonalEngineExisting)

    Write-Host ""
    Write-Host "Install-PersonalDeployment: an unknown engine starts, replaces and records nothing (WIN3-02)"
    $calls = New-Object System.Collections.ArrayList
    $saved = @{}
    foreach ($f in @("Test-PersonalDeploymentExists", "Test-PersonalDeploymentRunning", "Get-PersonalLauncherState",
                     "Test-PersonalLauncherSupports", "Show-PersonalGuestRebuildNote", "Test-PersonalWslPodmanNetworkOk",
                     "Invoke-ExakitLogged", "Set-PersonalManifest", "Test-ExakitPortInUse")) {
        $saved[$f] = (Get-Item "function:$f").ScriptBlock
    }
    function Test-PersonalDeploymentExists { return $true }
    function Test-PersonalDeploymentRunning { return $false }
    function Get-PersonalLauncherState { return "stopped" }
    function Test-PersonalLauncherSupports { return $false }
    function Show-PersonalGuestRebuildNote { }
    function Test-PersonalWslPodmanNetworkOk { [void]$calls.Add("WSL"); return $false }
    function Invoke-ExakitLogged { [void]$calls.Add("LAUNCHER " + ($args -join " ")); return 0 }
    function Set-PersonalManifest { [void]$calls.Add("RECORD engine=[$($script:PersonalEngine)]") }
    function Test-ExakitPortInUse { return $true }
    $env:EXAKIT_REPLACE_DB = "1"; $env:EXAKIT_REUSE_DB = "0"
    $script:PersonalNoDatabase = $false; $script:lastWarn = ""; Reset-Caches
    Install-PersonalDeployment
    $joined = ($calls -join "|")
    Check "2.4, Docker down, Podman silent -> no database" $true $script:PersonalNoDatabase
    Has   "  says the engine cannot be read"  "engine cannot be read" $script:lastWarn
    Check "  nothing destroyed"               $false ($joined.Contains("destroy"))
    Check "  nothing recorded"                $false ($joined.Contains("RECORD"))
    Check "  never guessed as Docker"         "" ("" + $script:PersonalEngine)

    $calls.Clear()
    $script:StubDeployed = "2.3.1"
    $script:PersonalNoDatabase = $false; Reset-Caches
    Install-PersonalDeployment
    $joined = ($calls -join "|")
    Check "2.3, Docker down, Podman silent -> podman"      "podman" ("" + $script:PersonalEngine)
    Check "  the replace runs the WSL check"  $true ($joined.Contains("WSL"))
    Check "  which refuses: nothing destroyed" $false ($joined.Contains("destroy"))
    Check "  nothing recorded as Docker"      $false ($joined.Contains("RECORD engine=[docker]"))

    $calls.Clear()
    # Unreadable everywhere: the earlier Set-PersonalManifest cases recorded
    # runtime.deployment_version, which is the fallback read.
    Remove-ExakitManifestValue "runtime.deployment_version"
    $script:StubDeployed = ""
    $script:PersonalNoDatabase = $false; Reset-Caches
    Install-PersonalDeployment
    Check "version unreadable, no state engine -> podman" "podman" ("" + $script:PersonalEngine)
    Check "  the replace runs the WSL check"  $true (($calls -join "|").Contains("WSL"))
    $script:StubDeployed = "2.4.0"

    Write-Host ""
    Write-Host "the gate's 'Docker down' is asked again at the deploy (WIN3-01)"
    $savedExisting = (Get-Item "function:Get-PersonalEngineExisting").ScriptBlock
    function Get-PersonalEngineExisting { param([switch]$Quiet); $script:cacheAtDeploy = $script:PersonalDockerCache; return "" }
    $script:PersonalDockerCache = @{ Usable = $false; Said = "Docker is installed but not running"; Kind = "down" }
    Install-PersonalDeployment
    Check "a kept 'not usable' is dropped first" $true ($null -eq $script:cacheAtDeploy)
    $script:PersonalDockerCache = @{ Usable = $true; Said = ""; Kind = "" }
    Install-PersonalDeployment
    Check "a kept 'usable' stays"             $true ($null -ne $script:cacheAtDeploy -and $script:cacheAtDeploy.Usable)
    Set-Item function:Get-PersonalEngineExisting $savedExisting

    foreach ($f in $saved.Keys) { Set-Item "function:$f" $saved[$f] }
    Remove-Item Env:EXAKIT_REPLACE_DB, Env:EXAKIT_REUSE_DB -ErrorAction SilentlyContinue
    Remove-Item $podmanStub -Force
}

Write-Host ""
Write-Host "a deployment made before Exasol Personal 2.4 is Podman, period (WIN3-02)"
$env:STUB_DOCKER_FAIL = "1"; Reset-Caches
foreach ($v in @("2.3.1", "2.0.0", "1.9.0")) {
    $script:StubDeployed = $v
    Check "$v, Docker down -> podman"         "podman" (Get-PersonalEngineExisting -Quiet)
}
$env:STUB_DOCKER_FAIL = "0"; $env:STUB_DOCKER_PS = "exa-7f3a-db-1"; Reset-Caches
$script:StubDeployed = "2.3.1"
Check "2.3.1, even with Docker listing its id -> podman" "podman" (Get-PersonalEngineExisting -Quiet)
Remove-ExakitManifestValue "runtime.deployment_version"
$script:StubDeployed = ""
Check "version unreadable, no state engine -> podman" "podman" (Get-PersonalEngineExisting -Quiet)
Set-ExakitManifestValue "runtime.deployment_version" "2.3.0"
Check "the record's deployment_version 2.3.0 -> podman" "podman" (Get-PersonalEngineExisting -Quiet)
Remove-ExakitManifestValue "runtime.deployment_version"
$script:StubDeployed = "2.10.0"
Check "2.10 counts as 2.4+ -> docker on evidence" "docker" (Get-PersonalEngineExisting -Quiet)
$script:StubDeployed = ""
Set-Content -Path (Join-Path $dep "deployment.json") -Value '{"deploymentId":"exa-7f3a","containerEngine":"docker"}'
$env:STUB_DOCKER_FAIL = "1"; Reset-Caches
Check "version unreadable, state names docker -> docker" "docker" (Get-PersonalEngineExisting -Quiet)
Set-Content -Path (Join-Path $dep "deployment.json") -Value '{"deploymentId":"exa-7f3a","dbPort":8563}'
$script:StubDeployed = "2.4.0"
$env:STUB_DOCKER_PS = ""
$env:STUB_DOCKER_FAIL = "0"
$script:PersonalDeployDir = $savedDir
Has "a Docker deployment is checked as one" 'Test-PersonalEngineRunning "docker"' $src

if (-not $onWindows) {
    Write-Host ""
    Write-Host "the engine is decided once per process (WINR-02)"
    $env:STUB_DOCKER_CALLS = Join-Path $work "docker-calls"
    $env:STUB_HELP_CALLS = Join-Path $work "help-calls"
    function Count([string]$f) { if (Test-Path $f) { return @(Get-Content $f).Count } else { return 0 } }
    $env:STUB_DOCKER_INFO = "linux 29.1.0"; $env:STUB_DOCKER_FAIL = "0"; Reset-Caches
    $a = "" + (Resolve-PersonalEngine -Probe)
    $b = "" + (Get-PersonalPlannedEngine)
    $c = "" + (Resolve-PersonalEngine)
    $flag = (Get-PersonalEngineFlag $c) -join " "
    $running = Test-PersonalEngineRunning "docker"
    Check "gate, plan and deploy agree"       "docker docker docker" "$a $b $c"
    Check "  the flag is passed"              "--container-engine docker" $flag
    Check "  Docker still running"            $true $running
    Check "  docker info asked once"          1 (Count $env:STUB_DOCKER_CALLS)
    Check "  install local --help asked once"       1 (Count $env:STUB_HELP_CALLS)
    $other = Join-Path $stubDir "exasol-stub2"
    Copy-Item (Get-PersonalCli) $other
    $savedCli = ${function:Get-PersonalCli}
    function Get-PersonalCli { return $other }
    $null = Test-PersonalLauncherTakesEngine; $null = Test-PersonalLauncherTakesEngine
    Check "  a new launcher is asked again, once" 2 (Count $env:STUB_HELP_CALLS)
    Set-Item function:Get-PersonalCli $savedCli
    Remove-Item Env:STUB_DOCKER_CALLS, Env:STUB_HELP_CALLS
}

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "personal-engine-ps.ps1: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
