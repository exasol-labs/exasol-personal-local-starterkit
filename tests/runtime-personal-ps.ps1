#!/usr/bin/env pwsh
# runtime-personal-ps.ps1 - behavioural tests for setup/lib/runtime-personal.ps1
# (the Windows twin of runtime-personal.sh). Dot-sources the real modules
# against a fully sandboxed kit home and asserts the twin holds the same
# contracts the sh suite pins: the deployment's own port beats the constant,
# state files answer for the deployed version, the wedge probe reads the
# launcher's workflow state, the guest rebuild is recognised, the manifest keys
# come out identical to the sh side's, and the per-subcommand --auto-approve
# probe says yes and no against a stub launcher.
#
#   pwsh -NoProfile -File tests/runtime-personal-ps.ps1

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label = $actual" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected $expected, got $actual" }
}

# --- sandbox ----------------------------------------------------------------
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-rp-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:EXAKIT_HOME = Join-Path $work "home"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
$env:EXAKIT_PERSONAL_DEPLOY_DIR = Join-Path $work "no-deployment-yet"
Remove-Item Env:EXAKIT_PERSONAL_VERSION -ErrorAction SilentlyContinue

. (Join-Path $repo "setup/lib/exakit-common.ps1")
. (Join-Path $repo "setup/lib/runtime-personal.ps1")

# HERMETIC LAUNCHER. Get-PersonalCli falls back to an "exasol" on PATH, so
# without this every probe answers from the developer's real launcher - and a
# check that pins a launcher VERSION then passes or fails on which machine ran
# it. The stub answers the three things the probes ask: its version, the
# per-subcommand help, and `info`.
# $env:OS, not $IsWindows: the automatic variable does not exist on 5.1, where
# it is $null and would route the Windows runner onto the sh stub (and chmod).
$onWindows = ($env:OS -like "*Windows*")
$script:stubSeq = 0
function New-StubLauncher([string]$Version) {
    $script:stubSeq++
    $dir = Join-Path $work "stub$($script:stubSeq)"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if ($onWindows) {
        $path = Join-Path $dir "exasol.cmd"
        # %~1/%~2, not %1/%2: Invoke-ExakitBounded quotes every argument and cmd
        # keeps those quotes in %1, so an unstripped compare never matches.
        Set-Content -Path $path -Encoding Ascii -Value @(
            "@echo off",
            "if `"%~1`"==`"version`" (echo $Version",
            "exit /b 0)",
            "if `"%~1 %~2`"==`"install --help`" (echo   -a, --auto-approve   Approve host preparation",
            "exit /b 0)",
            "echo   --help    help"
        )
    } else {
        $path = Join-Path $dir "exasol"
        Set-Content -Path $path -Value @(
            "#!/bin/sh",
            "if [ `"`$1`" = version ]; then printf '$Version\n'; exit 0; fi",
            "if [ `"`$1 `$2`" = 'install --help' ]; then printf '  -a, --auto-approve   Approve host preparation\n'; exit 0; fi",
            "printf '  --help    help\n'",
            "exit 0"
        )
        chmod +x $path
    }
    return $path
}

Write-Host "the deployment's own port beats the constant:"
$dep = Join-Path $work "deploy"
New-Item -ItemType Directory -Force -Path $dep | Out-Null
Set-Content -Path (Join-Path $dep "deployment.json") -Value '{"connection": {"host": "127.0.0.1", "dbPort": 8571, "username": "sys"}}'
$script:PersonalDeployDir = $dep
Check "port(configured)" 8571 (Get-PersonalDbPort)
$script:PersonalDeployDir = Join-Path $work "absent"
Check "port(no deployment falls back)" 8563 (Get-PersonalDbPort)

Write-Host "state files answer for the deployed version:"
$dep2 = Join-Path $work "deploy2"
New-Item -ItemType Directory -Force -Path $dep2 | Out-Null
Set-Content -Path (Join-Path $dep2 ".exasolLauncher.version") -Value "2.2.0"
$script:PersonalDeployDir = $dep2
Check "deployed(bare version file)" "2.2.0" (Get-PersonalDeployedVersion)
Remove-Item -Force (Join-Path $dep2 ".exasolLauncher.version")
Set-Content -Path (Join-Path $dep2 ".exasolLauncherState.json") -Value '{"deploymentVersion": "v2.1.5", "currentWorkflowState": {"interrupted": {"reason": "killed"}}}'
Check "deployed(state json, v stripped)" "2.1.5" (Get-PersonalDeployedVersion)
Set-Content -Path (Join-Path $dep2 ".exasolLauncher.version") -Value "not a version!!"
Check "garbage reads as unknown, never a blocker" "" "$(Get-PersonalDeployedVersion)"
Remove-Item -Force (Join-Path $dep2 ".exasolLauncher.version")

Write-Host "the wedge probe reads the launcher's workflow state:"
Check "wedged(interrupted present)" $true (Test-PersonalDeploymentWedged)
Set-Content -Path (Join-Path $dep2 ".exasolLauncherState.json") -Value '{"deploymentVersion": "2.1.5", "currentWorkflowState": {}}'
Check "wedged(clean state)" $false (Test-PersonalDeploymentWedged)

Write-Host "the guest rebuild is recognised, and only across a launcher change:"
Set-Content -Path (Join-Path $dep2 ".exasolLauncher.version") -Value "2.2.0"
Remove-Item Env:EXAKIT_PERSONAL_VERSION -ErrorAction SilentlyContinue
# The LAUNCHER's own version decides this, so a stub reports it.
$script:PersonalBinPath = New-StubLauncher "2.3.0-rc2"
Check "the launcher reports its own version" "2.3.0-rc2" (Get-PersonalLauncherVersion)
Check "rebuild(2.2.0 deployment, 2.3 launcher)" $true (Test-PersonalGuestRebuildExpected)
$script:PersonalBinPath = New-StubLauncher "2.2.0"
Check "rebuild(same version)" $false (Test-PersonalGuestRebuildExpected)
$script:PersonalBinPath = New-StubLauncher "2.3.0-rc2"

Write-Host "the manifest keys are the sh side's, byte for byte:"
Set-Content -Path (Join-Path $dep2 "deployment.json") -Value '{"connection": {"host": "127.0.0.1", "dbPort": 8571, "username": "sys"}}'
Set-Content -Path (Join-Path $dep2 "secrets.json") -Value '{"dbPassword": "s3cret"}'
Initialize-ExakitManifest
Set-PersonalManifest "stopped"
Check "runtime.type" "personal" (Get-ExakitManifestValue "runtime.type")
Check "runtime.dsn" "127.0.0.1:8571" (Get-ExakitManifestValue "runtime.dsn")
Check "runtime.user" "sys" (Get-ExakitManifestValue "runtime.user")
Check "runtime.tls" "self-signed" (Get-ExakitManifestValue "runtime.tls")
Check "runtime.status is the argument, never assumed" "stopped" (Get-ExakitManifestValue "runtime.status")
# runtime.version is the COMPONENT versions.json names - the launcher - so a
# completed update converges instead of advertising itself forever; the
# deployment's own version rides beside it.
Check "runtime.version is the launcher's" "2.3.0-rc2" (Get-ExakitManifestValue "runtime.version")
Check "runtime.deployment_version is the deployment's" "2.2.0" (Get-ExakitManifestValue "runtime.deployment_version")
# ...and the rebuild notice retires once a start has completed under it.
Set-ExakitManifestValue "runtime.guest_rebuilt_for" "2.3.0-rc2"
Check "a completed start retires the rebuild notice" $false (Test-PersonalGuestRebuildExpected)
Remove-ExakitManifestValue "runtime.guest_rebuilt_for"
$credFile = Join-Path $script:CredsDir "personal_sys_password"
Check "the password lands in the credentials store" $true (Test-Path $credFile)
Check "runtime.password_file points at it" $credFile (Get-ExakitManifestValue "runtime.password_file")
# The password itself is compared where it lives, never printed on a FAIL line.
Check "the stored credential is the secrets' password" $true ((Get-Content $credFile -Raw).Trim() -eq "s3cret")

Write-Host "the per-subcommand --auto-approve probe, against a stub launcher:"
# A stub whose install advertises the flag and whose start does not - the exact
# case the sh suite pins, because no top-level probe can tell them apart.
# The same hermetic stub the rebuild checks used.
$script:PersonalBinPath = New-StubLauncher "2.3.0-rc2"
Check "a launcher that takes the flag gets it" "--auto-approve" (Get-PersonalAutoApproveFlag "install")
Check "a launcher that does not is left alone" "" "$(Get-PersonalAutoApproveFlag 'start')"

Write-Host "status vocabulary:"
# The stub answers `info` (exit 0), the deployment dir exists, nothing listens
# on the fixture port - a stopped deployment, in the documented word.
$script:PersonalDeployDir = $dep2
Check "status(deployment exists, port silent)" "stopped" (Get-PersonalStatus)
$script:PersonalDeployDir = Join-Path $work "absent"
Check "status(no deployment)" "not deployed" (Get-PersonalStatus)

Write-Host "readiness is a TLS handshake, not an open port:"
# Under rootless Podman the published port is pasta's from the moment the
# container starts; it accepts the TCP connection and resets it while the
# database inside is still booting, which clients report as "tls handshake
# eof". A listener that never completes a handshake must therefore read as
# "not answering" - both the port nothing listens on and the one that accepts
# and then says nothing. The probe's ceiling is shortened so the silent case
# does not cost the suite the full budget.
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$silentPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
$probeDir = Join-Path $work "probe"
New-Item -ItemType Directory -Force -Path $probeDir | Out-Null
Set-Content -Path (Join-Path $probeDir "deployment.json") -Value ('{"connection": {"host": "127.0.0.1", "dbPort": ' + $silentPort + ', "username": "sys"}}')
$script:PersonalDeployDir = $probeDir
$savedProbeTimeout = $script:PersonalProbeTimeout
$script:PersonalProbeTimeout = 1
Check "an open port that never completes a handshake does not answer" $false (Test-PersonalTlsAnswers)
$listener.Stop()
Check "a closed port does not answer" $false (Test-PersonalTlsAnswers)
$script:PersonalProbeTimeout = $savedProbeTimeout
$script:PersonalDeployDir = Join-Path $work "absent"

Write-Host "the launcher's word outranks the port, and ownership is proven before a database is adopted:"
# The decision function, with its inputs stubbed one at a time: the port is
# open, and what the launcher says about its own deployment decides.
function Test-ExakitPortInUse { return $true }
function Test-PersonalDbAnswers { return $true }
function Test-PersonalDeploymentExists { return $true }
function Get-PersonalLauncherState { return "stopped" }
Check "ours, launcher says stopped, port answers -> not running" $false (Test-PersonalDeploymentRunning)
function Get-PersonalLauncherState { return "deployment_failed" }
Check "ours, launcher says deployment_failed, port answers -> not running" $false (Test-PersonalDeploymentRunning)
function Get-PersonalLauncherState { return "database_ready" }
Check "ours, launcher says database_ready, database answers -> running" $true (Test-PersonalDeploymentRunning)
function Get-PersonalLauncherState { return "" }
Check "ours, launcher cannot say, database answers -> running" $true (Test-PersonalDeploymentRunning)
function Test-PersonalDbAnswers { return $false }
Check "ours, launcher says nothing, port open but no answer -> not running" $false (Test-PersonalDeploymentRunning)
# No deployment of ours at all: something answers on 8563 (Windows and WSL
# share the port), and without a SELECT through the kit's own profile it is
# never adopted - the run that did adopt one handed every later step a
# password that could never work.
function Test-PersonalDeploymentExists { return $false }
function Test-PersonalDbAnswers { return $true }
Check "no deployment of ours, port answers, no profile -> NOT adopted" $false (Test-PersonalDeploymentRunning)
function Test-ExakitDbReachable { return $false }
function Get-ExakitManifestValue($Key) { if ($Key -eq "components.exapump.profile") { return "starter-kit" }; return $null }
Check "no deployment of ours, the profile's SELECT fails -> NOT adopted" $false (Test-PersonalDeploymentRunning)
function Test-ExakitDbReachable { return $true }
Check "no deployment of ours, the profile's SELECT works -> running" $true (Test-PersonalDeploymentRunning)

Write-Host "the reconcile is the ownership proof:"
# Wait-PersonalSlowFirstBoot: the database answers, and the launcher's own
# deploy either agrees (success) or does not - in which case the recovery
# FAILS, instead of carrying on with whatever answered on the port.
function Test-PersonalTlsAnswers { return $true }
function Get-PersonalCli { return "exasol-stub" }
function Get-PersonalAutoApproveFlag($Verb) { return "" }
function Invoke-ExakitLogged { return 0 }
Check "database answers, deploy reconciles -> recovered" $true (Wait-PersonalSlowFirstBoot)
function Invoke-ExakitLogged { return 1 }
Check "database answers, deploy fails -> NOT recovered" $false (Wait-PersonalSlowFirstBoot)
function Test-PersonalTlsAnswers { return $false }
Check "the foreign-database hint is empty when nothing completes a handshake" "" (Get-PersonalForeignDbHint)
function Test-PersonalTlsAnswers { return $true }
$hint = Get-PersonalForeignDbHint
Check "...and names WSL when something does" $true ($hint -like "*inside WSL*")

# ---------------------------------------------------------------------------
# PODMAN READINESS, SELF-HEAL AND THE REAL ERROR (Windows incident: DNS inside
# the machine, a rootless machine with no pids controller, a rootful machine
# the kit refused, a never-booted deployment it asked the wrong questions of).
#
# The modules are dot-sourced AGAIN so every stub above is replaced by the real
# function, then podman itself is a stub: Get-PersonalPodman answers with a
# fake executable, and Invoke-ExakitBounded / Invoke-ExakitLogged answer from a
# small model of the machine (rootful or not, which controllers, whether DNS
# works) and record every call, so ORDER can be asserted as well as outcome.
# ---------------------------------------------------------------------------
. (Join-Path $repo "setup/lib/exakit-common.ps1")
. (Join-Path $repo "setup/lib/runtime-personal.ps1")
$script:PersonalDeployDir = Join-Path $work "absent"
Initialize-ExakitManifest
$script:PersonalContainerLookEvery = 0
# Every wait in this section is one probe long: nothing here answers TLS.
$env:EXAKIT_PERSONAL_READY_TIMEOUT = "1"

$script:calls = New-Object System.Collections.Generic.List[string]
function Reset-Machine {
    $script:calls.Clear()
    $script:m = @{
        Rootful = $false; PidsRootless = $false; PidsRootful = $true; Dns = $true; DnsAfterTunnel = $true
        Containers = ""; StateError = ""; Server = "5.8.9"; InstallRc = 0; DeployRc = 0; StartRc = 0
        InstallSays = @()
    }
    $script:PersonalContainerError = ""
    $script:PersonalLauncherOutput = @()
    foreach ($v in @("EXAKIT_PODMAN_SELFHEAL", "EXAKIT_REPLACE_DB", "EXAKIT_REUSE_DB")) {
        Remove-Item "Env:$v" -ErrorAction SilentlyContinue
    }
    Set-PersonalFirstBootPending $false
}
function Get-PersonalPodman { return [pscustomobject]@{ Source = "podman-stub" } }
function Get-PersonalCli { return "exasol-stub" }
function Get-PersonalAutoApproveFlag($Verb) { return "" }
function Test-ExakitInteractive { return $false }
function Test-ExakitStdoutIsTerminal { return $false }
function Get-PersonalWindowsBuild { return 22631 }
function Test-PersonalTlsAnswers { return $false }
function Test-ExakitPortInUse { return $false }
function Get-PersonalLauncherVersion { return "2.3.0" }
function Set-PersonalManifest { param([string]$Status = "") $script:calls.Add("manifest: $Status") }
function Invoke-ExakitBounded {
    param([string]$FilePath, [string[]]$Arguments = @(), [string]$ArgumentString = "", [int]$TimeoutSeconds = 8)
    $key = $Arguments -join " "
    $script:calls.Add("bounded: $key")
    $m = $script:m
    switch -Wildcard ($key) {
        "info --format {{.Host.Arch}}" { return "amd64" }
        "info --format {{.Host.CgroupControllers}}" {
            $pids = $m.PidsRootless
            if ($m.Rootful) { $pids = $m.PidsRootful }
            if ($pids) { return "[cpu io memory pids]" }
            return "[]"
        }
        "machine inspect --format {{.Rootful}}" { if ($m.Rootful) { return "true" }; return "false" }
        "version --format *" { return "5.8.3|$($m.Server)" }
        "machine ssh getent hosts *" { if ($m.Dns) { return "1.2.3.4 registry-1.docker.io" }; return $null }
        "machine ssh true" { return "" }
        "ps -a --filter name=exasol-db *" { return $m.Containers }
        "inspect --format {{.State.Error}} *" { return $m.StateError }
        "machine stop" { return "" }
    }
    return $null
}
function Invoke-ExakitLogged {
    param([Parameter(Mandatory)][string]$Cmd, [Parameter(ValueFromRemainingArguments)]$CmdArgs)
    $line = ("$Cmd " + ($CmdArgs -join " ")).Trim()
    $script:calls.Add("logged: $line")
    $m = $script:m
    switch -Wildcard ($line) {
        "podman-stub machine set --rootful"       { $m.Rootful = $true; return 0 }
        "podman-stub machine set --rootful=false" { $m.Rootful = $false; return 0 }
        "wsl.exe --shutdown"                     { $m.Dns = $m.DnsAfterTunnel; return 0 }
        "exasol-stub install local*" {
            if ($script:LogFile) { foreach ($l in $m.InstallSays) { Add-Content -Path $script:LogFile -Value $l } }
            return $m.InstallRc
        }
        "exasol-stub deploy*" { return $m.DeployRc }
        "exasol-stub start*"  { return $m.StartRc }
    }
    return 0
}
function Show-Calls { return ($script:calls -join "`n") }
function Index-Of([string]$Needle) {
    for ($i = 0; $i -lt $script:calls.Count; $i++) { if ($script:calls[$i] -eq $Needle) { return $i } }
    return -1
}
function Invoke-Captured([scriptblock]$Body) {
    $script:threw = ""
    try { return ((& $Body 6>&1 | Out-String)) } catch { $script:threw = "$_"; return "" }
}

Write-Host "both machine modes pass the requirements gate, and the gate changes nothing:"
Reset-Machine
$script:m.Rootful = $true
function Get-ExakitHostArch { return "amd64" }
$out = Invoke-Captured { Test-PersonalRequirements }
Check "a rootful machine is not refused" "" $script:threw
Check "...the mode is reported" $true ($out -like "*Podman machine rootful*")
Check "...and nothing was stopped, set or started" $false ((Show-Calls) -match "machine (stop|set|start)")
$script:m.Rootful = $false
$out = Invoke-Captured { Test-PersonalRequirements }
Check "a rootless machine is reported too" $true ($out -like "*Podman machine rootless*")

Write-Host "the rootful port-forwarding regression is recognised by version:"
Check "6.0.2 is the regression" $true (Test-PersonalPodmanForwardingRegression "6.0.2")
Check "6.1.0 is the regression" $true (Test-PersonalPodmanForwardingRegression "v6.1.0")
Check "6.1.1 is fixed" $false (Test-PersonalPodmanForwardingRegression "6.1.1")
Check "5.8.9 forwards" $false (Test-PersonalPodmanForwardingRegression "5.8.9")
Check "6.10.0 is not 6.1.0" $false (Test-PersonalPodmanForwardingRegression "6.10.0")
Check "unknown is not evidence" $false (Test-PersonalPodmanForwardingRegression "")

Write-Host "known errors are named with their fix:"
Check "the pids error" "pids" ((Get-PersonalKnownCause "crun: controller ``pids`` is not available under /sys/fs/cgroup/non-systemd/x/cgroup.controllers: OCI runtime error").Kind)
Check "the DNS error" "dns" ((Get-PersonalKnownCause "pinging container registry registry-1.docker.io: Get https://registry-1.docker.io/v2/: dial tcp: lookup registry-1.docker.io: Temporary failure in name resolution").Kind)
Check "...whose fix on 22H2+ is DNS tunneling" $true ((Get-PersonalKnownCause "lookup registry-1.docker.io").Remedy -like "*dnsTunneling=true*")
function Get-PersonalWindowsBuild { return 19045 }
Check "...and before 22H2 user-mode networking" $true ((Get-PersonalKnownCause "lookup registry-1.docker.io").Remedy -like "*--user-mode-networking*")
function Get-PersonalWindowsBuild { return 22631 }
Check "anything else is not guessed at" $null (Get-PersonalKnownCause "exit status 125")

Write-Host "a machine that cannot resolve the registry stops a fresh deploy, with the fix:"
Reset-Machine
$script:m.Dns = $false
function Test-PersonalDeploymentExists { return $false }
function Test-PersonalDeploymentRunning { return $false }
$script:PersonalNoDatabase = $false
Set-ExakitFailureReason ""
$out = Invoke-Captured { Install-PersonalDeployment }
Check "no database, softly" $true $script:PersonalNoDatabase
Check "...the reason names the registry" $true ((Get-ExakitFailureReason) -like "*cannot resolve registry-1.docker.io*")
Check "...the fix is printed" $true ($out -like "*dnsTunneling=true*")
Check "...the unattended opt-in is spelled out" $true ($out -like "*EXAKIT_PODMAN_SELFHEAL=1*")
Check "...and nothing was deployed" -1 (Index-Of "logged: exasol-stub install local")
Check "...nor was WSL restarted without consent" -1 (Index-Of "logged: wsl.exe --shutdown")

Write-Host "...and with consent it is fixed and asked again:"
Reset-Machine
$script:m.Dns = $false
$env:EXAKIT_PODMAN_SELFHEAL = "1"
$savedProfile = $env:USERPROFILE
$env:USERPROFILE = Join-Path $work "profile"
New-Item -ItemType Directory -Force -Path $env:USERPROFILE | Out-Null
Check "the DNS check passes after the fix" $true (Test-PersonalPodmanDns)
Check "...wsl --shutdown ran" $true ((Index-Of "logged: wsl.exe --shutdown") -ge 0)
Check "...before the machine was started again" $true ((Index-Of "logged: podman-stub machine start") -gt (Index-Of "logged: wsl.exe --shutdown"))
Check "...and .wslconfig says so" $true ((Get-Content (Join-Path $env:USERPROFILE ".wslconfig") -Raw) -match '(?m)^dnsTunneling=true')

Write-Host ".wslconfig is edited, never replaced:"
$cfg = Join-Path $work "wslconfig-test"
Remove-Item $cfg -ErrorAction SilentlyContinue
Check "a missing file is created" $true (Set-PersonalWslDnsTunneling $cfg)
Check "...with the section and the key" "[wsl2]|dnsTunneling=true" ((Get-Content $cfg) -join "|")
[System.IO.File]::WriteAllText($cfg, "# mine`r`n[boot]`r`nsystemd=true`r`n`r`n[wsl2]`r`nmemory=8GB`r`n[experimental]`r`nautoMemoryReclaim=gradual`r`n")
[void](Set-PersonalWslDnsTunneling $cfg)
Check "an existing [wsl2] gets the key under its header, everything else kept" "# mine|[boot]|systemd=true||[wsl2]|dnsTunneling=true|memory=8GB|[experimental]|autoMemoryReclaim=gradual" ((Get-Content $cfg) -join "|")
$once = [System.IO.File]::ReadAllText($cfg)
[void](Set-PersonalWslDnsTunneling $cfg)
Check "a second run changes nothing" $true ($once -eq [System.IO.File]::ReadAllText($cfg))
[System.IO.File]::WriteAllText($cfg, "[wsl2]`ndnsTunneling = false`nnetworkingMode=nat`n")
[void](Set-PersonalWslDnsTunneling $cfg)
Check "a key set to false is set to true, in place" "[wsl2]|dnsTunneling=true|networkingMode=nat" ((Get-Content $cfg) -join "|")
Check "...and LF endings stay LF" $false ([System.IO.File]::ReadAllText($cfg) -match "`r")
[System.IO.File]::WriteAllText($cfg, "[boot]`r`nsystemd=true`r`n")
[void](Set-PersonalWslDnsTunneling $cfg)
Check "a file without [wsl2] gets it appended" "[boot]|systemd=true||[wsl2]|dnsTunneling=true" ((Get-Content $cfg) -join "|")
$env:USERPROFILE = $savedProfile

Write-Host "no pids controller, rootless, consent: switched to rootful in order, then asked again:"
Reset-Machine
$env:EXAKIT_PODMAN_SELFHEAL = "1"
Check "the pids check passes after the switch" $true (Test-PersonalPodmanPids)
$iStop = Index-Of "bounded: machine stop"
$iSet = Index-Of "logged: podman-stub machine set --rootful"
$iStart = Index-Of "logged: podman-stub machine start"
Check "stop, then set" $true ($iStop -ge 0 -and $iStop -lt $iSet)
Check "set, then start" $true ($iSet -ge 0 -and $iSet -lt $iStart)
$lastCtl = -1
for ($i = 0; $i -lt $script:calls.Count; $i++) { if ($script:calls[$i] -eq "bounded: info --format {{.Host.CgroupControllers}}") { $lastCtl = $i } }
Check "...and the controllers are asked again after the start" $true ($lastCtl -gt $iStart)
Check "...on a machine that is rootful now" $true $script:m.Rootful

Write-Host "no pids controller, no consent: no deploy that cannot succeed:"
Reset-Machine
$script:PersonalNoDatabase = $false
$out = Invoke-Captured { Install-PersonalDeployment }
Check "no database, softly" $true $script:PersonalNoDatabase
Check "...the reason names the cause and the issue" $true ((Get-ExakitFailureReason) -like "*'pids'*podman-container-tools/podman#29909*")
Check "...the machine was left alone" -1 (Index-Of "logged: podman-stub machine set --rootful")
Check "...the manual fix is printed" $true ($out -like "*podman machine set --rootful*")
Check "...and nothing was deployed" -1 (Index-Of "logged: exasol-stub install local")
Reset-Machine
$env:EXAKIT_PODMAN_SELFHEAL = "0"
function Test-ExakitInteractive { return $true }
Check "a terminal answer of no (EXAKIT_PODMAN_SELFHEAL=0) declines too" $false (Test-PersonalPodmanPids)
Check "...and leaves the machine alone" -1 (Index-Of "logged: podman-stub machine set --rootful")
function Test-ExakitInteractive { return $false }
Reset-Machine
$script:m.Rootful = $true
$script:m.PidsRootful = $false
$env:EXAKIT_PODMAN_SELFHEAL = "1"
Check "rootful and still no pids: nothing to switch, a named failure" $false (Test-PersonalPodmanPids)
Check "...without touching the machine" -1 (Index-Of "logged: podman-stub machine set --rootful=false")

Write-Host "exakit start checks Podman first:"
Reset-Machine
$out = Invoke-Captured { Start-Personal }
function Test-PersonalLauncherSupports($Token) { return $true }
$out = Invoke-Captured { Start-Personal }
Check "a machine with no pids controller fails the start" $true ($script:threw -like "*podman-container-tools/podman#29909*")
Check "...before the launcher was asked to start" -1 (Index-Of "logged: exasol-stub start")

Write-Host "a container that refused to start ends the wait at once, and is the reason:"
Reset-Machine
$script:m.PidsRootless = $true
$script:m.Containers = "exasol-db-abc created"
$script:m.StateError = "crun: controller ``pids`` is not available under /sys/fs/cgroup/non-systemd/x/cgroup.controllers: OCI runtime error"
$env:EXAKIT_PERSONAL_READY_TIMEOUT = "40"
$t0 = [DateTime]::UtcNow
Set-ExakitFailureReason ""
$out = Invoke-Captured { Wait-PersonalReadyOrDeploy }
$spent = ([DateTime]::UtcNow - $t0).TotalSeconds
Check "the wait ended early" $true ($spent -lt 20)
Check "...without deploying again into the same error" -1 (Index-Of "logged: exasol-stub deploy")
Check "...the container's error is the reason" $true ((Get-ExakitFailureReason) -like "*could not start (crun: controller*")
Check "...and its fix is named" $true ($out -like "*podman machine set --rootful*")
$script:m.Containers = "exasol-db-abc running"
Check "a running container is never blamed" "" (Get-PersonalContainerError)
$env:EXAKIT_PERSONAL_READY_TIMEOUT = "1"

Write-Host "a failed fresh deploy says what went wrong:"
Reset-Machine
$script:m.PidsRootless = $true
$script:m.InstallRc = 1
$script:m.InstallSays = @("Error: initializing source docker://exasol/nano: pinging container registry registry-1.docker.io: dial tcp: lookup registry-1.docker.io: Temporary failure in name resolution")
$script:LogFile = Join-Path $work "install.log"
Set-Content -Path $script:LogFile -Value "2026-10-23 10:00:00 INFO  start"
$script:PersonalNoDatabase = $false
$out = Invoke-Captured { Install-PersonalDeployment }
Check "no database, softly" $true $script:PersonalNoDatabase
Check "...the launcher's last lines are shown" $true ($out -like "*last lines from the exasol launcher*Temporary failure in name resolution*")
Check "...the cause is recognised in them" $true ((Get-ExakitFailureReason) -like "*could not deploy the database locally: Podman's machine cannot resolve registry-1.docker.io*")
Check "...the deployment is recorded as never booted" $true (Test-PersonalFirstBootPending)
$script:LogFile = $null

Write-Host "a deployment that never booted is offered for replacement, default yes:"
function Test-PersonalDeploymentExists { return $true }
function Get-PersonalLauncherState { return "deployment_failed" }
function Wait-PersonalSlowFirstBoot { return $false }
Reset-Machine
$script:m.PidsRootless = $true
$script:m.DeployRc = 1
Set-PersonalFirstBootPending $true
$script:PersonalNoDatabase = $false
$out = Invoke-Captured { Install-PersonalDeployment }
# Unattended, Confirm-ExakitEnvPrompt takes its default without printing the
# question, so what is asserted is the branch taken.
Check "the never-started branch is taken" $true ($out -like "*Removing the deployment that never started*")
Check "...not the keep-its-data ladder" $false ($out -like "*An Exasol deployment was found, not running*")
Check "...unattended, the default replaces it" $true ((Index-Of "logged: exasol-stub destroy --remove --auto-approve") -ge 0)
Check "...and deploys a fresh one" $true ((Index-Of "logged: exasol-stub install local") -gt (Index-Of "logged: exasol-stub destroy --remove --auto-approve"))
Reset-Machine
$script:m.PidsRootless = $true
$script:m.DeployRc = 1
Set-PersonalFirstBootPending $true
$env:EXAKIT_REPLACE_DB = "0"
$script:PersonalNoDatabase = $false
$out = Invoke-Captured { Install-PersonalDeployment }
Check "EXAKIT_REPLACE_DB=0 declines it" -1 (Index-Of "logged: exasol-stub destroy --remove --auto-approve")
Check "...softly, with a reason" $true ($script:PersonalNoDatabase -and ((Get-ExakitFailureReason) -like "*never started*declined*"))
Reset-Machine
$script:m.PidsRootless = $true
$script:m.DeployRc = 1
$script:m.StartRc = 1
$script:PersonalNoDatabase = $false
$out = Invoke-Captured { Install-PersonalDeployment }
Check "a deployment that ever answered keeps the old ladder" $true ($out -like "*An Exasol deployment was found, not running*")
Check "...whose start is tried" $true ((Index-Of "logged: exasol-stub start") -ge 0)
Check "...and whose DELETE still defaults to no" -1 (Index-Of "logged: exasol-stub destroy --remove --auto-approve")
Reset-Machine
$script:m.PidsRootless = $true
$script:m.DeployRc = 1
$script:m.StartRc = 1
Set-PersonalFirstBootPending $true
$env:EXAKIT_REUSE_DB = "1"
$out = Invoke-Captured { Install-PersonalDeployment }
Check "EXAKIT_REUSE_DB=1 keeps the old ladder even for a never-booted one" $true ($out -like "*An Exasol deployment was found, not running*")
Check "...and so deletes nothing" -1 (Index-Of "logged: exasol-stub destroy --remove --auto-approve")
Reset-Machine
Set-PersonalFirstBootPending $true
Set-ExakitManifestValue "runtime.status" "x"
function Set-PersonalManifest { param([string]$Status = "") if ($Status -eq "healthy") { Set-PersonalFirstBootPending $false } }
Set-PersonalManifest "healthy"
Check "a healthy record retires the never-booted mark" $false (Test-PersonalFirstBootPending)

Write-Host "a running container Windows cannot reach is diagnosed, not timed out:"
Reset-Machine
$script:m.Rootful = $true
$script:m.Server = "6.1.0"
$script:m.Containers = "exasol-db-abc running"
$out = Invoke-Captured { [void](Resolve-PersonalUnreachableDatabase) }
Check "Podman 6.1.0 rootful is named as the known regression" $true ($out -like "*6.0.0 to 6.1.0, fixed in 6.1.1*")
Check "...with the recreate fix" $true ($out -like "*podman machine rm; podman machine init*")
Check "...the cause is kept for the reason" $true ($script:PersonalUnreachableCause -like "*6.1.1*")
Check "...and the machine is not switched for it" -1 (Index-Of "logged: podman-stub machine set --rootful=false")
Reset-Machine
$script:m.Rootful = $true
$script:m.Containers = "exasol-db-abc running"
$out = Invoke-Captured { [void](Resolve-PersonalUnreachableDatabase) }
Check "on 5.x, without consent, rootless is only offered" -1 (Index-Of "logged: podman-stub machine set --rootful=false")
Check "...as one of the options" $true ($out -like "*podman machine set --rootful=false*")
Reset-Machine
$script:m.Rootful = $true
$script:m.Containers = "exasol-db-abc running"
$env:EXAKIT_PODMAN_SELFHEAL = "1"
$out = Invoke-Captured { [void](Resolve-PersonalUnreachableDatabase) }
Check "with consent it switches to rootless" $true ((Index-Of "logged: podman-stub machine set --rootful=false") -ge 0)
Check "...and back to rootful when rootless has no pids" $true ((Index-Of "logged: podman-stub machine set --rootful") -gt (Index-Of "logged: podman-stub machine set --rootful=false"))
Check "...without deploying into it" -1 (Index-Of "logged: exasol-stub deploy")
Reset-Machine
$script:m.Containers = "exasol-db-abc exited"
Check "no running container: no forwarding diagnosis" $false (Resolve-PersonalUnreachableDatabase)
Check "...and no question about the machine" -1 (Index-Of "bounded: machine inspect --format {{.Rootful}}")

Write-Host "repair-runtime consents to the deletion it just asked about:"
$xk = Get-Content -Raw (Join-Path $repo "setup/exakit.ps1")
Check "EXAKIT_REPLACE_DB=1 beside EXAKIT_REUSE_DB=0" $true ($xk -match '\$env:EXAKIT_REUSE_DB = "0"[\s\S]{0,800}\$env:EXAKIT_REPLACE_DB = "1"')
Check "...and --json claims repaired only when the runtime step completed" $true ($xk -match '\$repairCode -eq 0 -and \(Test-ExakitStepDone "runtime"\)')
Reset-Machine
Remove-Item Env:EXAKIT_PERSONAL_READY_TIMEOUT -ErrorAction SilentlyContinue

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "passed: $($script:PASS), failed: $($script:FAIL)"
if ($script:FAIL -gt 0) { exit 1 }
