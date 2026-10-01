# legacy-fault-personal.ps1 - the PowerShell twin of legacy-fault-personal.sh.
#
# Dot-sourced by tests/legacy-crossing-ps.ps1 in place of
# setup/lib/runtime-personal.ps1: the five functions the migrate road calls to
# stop and start the deployment around the copy, driven by the same knob files
# (personal.port, personal.state, personal.stop_rc, personal.start_rc) and
# logging every stop, start and wait to personal.calls, in order.
function Read-PersonalKnob([string]$Name, [string]$Default) {
    $p = Join-Path $env:EXAKIT_FAULT_DIR $Name
    if (Test-Path $p) { return ("" + (Get-Content $p -Raw)).Trim() }
    return $Default
}
function Get-PersonalDbPort { return [int](Read-PersonalKnob "personal.port" "8563") }
function Test-PersonalDeploymentRunning { return ((Read-PersonalKnob "personal.state" "running") -eq "running") }
function Stop-Personal {
    Add-Content -Path (Join-Path $env:EXAKIT_FAULT_DIR "personal.calls") -Value "stop"
    if ((Read-PersonalKnob "personal.stop_rc" "0") -ne "0") { throw "personal_stop refused" }
    Set-Content -Path (Join-Path $env:EXAKIT_FAULT_DIR "personal.state") -Value "stopped" -NoNewline
}
function Start-Personal {
    Add-Content -Path (Join-Path $env:EXAKIT_FAULT_DIR "personal.calls") -Value "start"
    if ((Read-PersonalKnob "personal.start_rc" "0") -ne "0") { throw "personal_start refused" }
    Set-Content -Path (Join-Path $env:EXAKIT_FAULT_DIR "personal.state") -Value "running" -NoNewline
}
function Wait-PersonalReady {
    Add-Content -Path (Join-Path $env:EXAKIT_FAULT_DIR "personal.calls") -Value "wait"
}
# The port question is answered by the knob, never by the developer's machine.
function Test-ExakitPortInUse {
    param([int]$Port, [string]$ComputerName = "127.0.0.1", [int]$TimeoutMs = 700)
    return ((Read-PersonalKnob "personal.port_busy" "0") -eq "1")
}
