# legacy-fault-engine.ps1 - the PowerShell twin of legacy-fault-engine.sh.
#
# Same contract, same control files, same log (engine.calls): a container
# engine that answers version, inspect, start and stop and misbehaves on
# request. Driven by tests/legacy-crossing-ps.ps1, through a .cmd wrapper on
# Windows and a #!/bin/sh wrapper elsewhere, so the PowerShell module meets one
# stub on every host it is tested on. See the .sh twin for what each control
# file means.
$dir = $env:EXAKIT_FAULT_DIR
if (-not $dir) { [Console]::Error.WriteLine("EXAKIT_FAULT_DIR must point at the scenario's control directory"); exit 2 }
function Read-Knob([string]$Name, [string]$Default) {
    $p = Join-Path $dir $Name
    if (Test-Path $p) { return (Get-Content $p -Raw).Trim() }
    return $Default
}
Add-Content -Path (Join-Path $dir "engine.calls") -Value ($args -join " ")

$state = Read-Knob "engine.state" "running"
$verb = "" + $args[0]; $noun = "" + $args[1]
# down: the CLI is there, the daemon or machine is not (Docker Desktop stopped).
if ($verb -eq "version") {
    if ($state -eq "down") { exit 1 }
    Write-Output "1.0"; exit 0
}
if ($verb -eq "container" -and $noun -eq "inspect") {
    if ($state -eq "hang")   { Start-Sleep -Seconds ([int](Read-Knob "engine.hang_seconds" "30")); exit 0 }
    if ($state -eq "absent" -or $state -eq "down") { exit 1 }
    if ($state -eq "noformat") { if ($args -contains "-f") { exit 1 }; exit 0 }
    if ($args -contains "-f") {
        switch ($state) {
            "running" { Write-Output "true" }
            "stopped" { Write-Output "false" }
            default   { Write-Output "weird" }
        }
    }
    exit 0
}
if ($verb -eq "start") {
    $rc = [int](Read-Knob "engine.start_rc" "0")
    if ($rc -eq 0) { Set-Content -Path (Join-Path $dir "engine.state") -Value "running" -NoNewline }
    exit $rc
}
if ($verb -eq "stop") {
    $rc = [int](Read-Knob "engine.stop_rc" "0")
    if ($rc -eq 0) { Set-Content -Path (Join-Path $dir "engine.state") -Value "stopped" -NoNewline }
    exit $rc
}
# Anything else - rm, volume, destroy - is logged above and answered politely.
# The suite's invariants fail the run if such a line ever appears.
exit 0
