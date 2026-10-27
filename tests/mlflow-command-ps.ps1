# mlflow-command-ps.ps1 - the Windows twin of tests/mlflow-command.sh: the
# PowerShell layer of exakit mlflow in setup/lib/mlflow.ps1. Runs under Windows
# PowerShell 5.1 and pwsh.
#
# The shared lifecycle (mlflow_service.py) is proven end to end by the sh twin
# and tests/test_mlflow_service.py; here the service is stubbed at its seam
# (Invoke-MlflowService) so the PowerShell decisions are checked on every
# platform without spawning a server: what start/stop/disable record, that
# exakit start (Start-UdfDevkit) honours the wish, the status words, and the
# refusals. Two read-only calls go through the real service first.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-mlflow-$([guid]::NewGuid().ToString('N'))"
$oldHome = $env:HOME; $oldKit = $env:EXAKIT_HOME
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$expected>, got <$actual>" }
}
function Contains($label, $needle, $haystack) {
    if ("$haystack".Contains($needle)) { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): <$needle> not in <$haystack>" }
}
try {
    $env:HOME = Join-Path $work "user"
    $env:EXAKIT_HOME = Join-Path $work "kit"
    New-Item -ItemType Directory -Force $env:HOME, $env:EXAKIT_HOME | Out-Null
    . (Join-Path $root "setup/lib/exakit-common.ps1")
    . (Join-Path $root "setup/lib/persona.ps1")
    . (Join-Path $root "setup/lib/notebook.ps1")
    . (Join-Path $root "setup/lib/mlflow.ps1")

    Write-Host "nothing running: the real service is read-only:"
    $doc = Invoke-MlflowService -ServiceArgs @("status", "--json") | ConvertFrom-Json
    Check "status says stopped" "stopped" $doc.status
    Check "...and names the remedy" "exakit mlflow start" $doc.remedy
    Check "status writes nothing" $false (Test-Path (Join-Path $env:EXAKIT_HOME "mlflow"))
    Check "url prints nothing" "" ("" + (Invoke-MlflowService -ServiceArgs @("url")))

    # From here on: the machine stubbed at the module's seams.
    function Fail([string]$Msg) { throw "FAIL: $Msg" }
    function Deny-ExakitInput([string]$Msg) { throw "DENY: $Msg" }
    function Info([string]$Msg) { [void]$script:said.Add($Msg) }
    $script:said = New-Object System.Collections.ArrayList
    $script:calls = New-Object System.Collections.ArrayList
    $script:serviceRc = 0
    $script:running = $false
    $venv = Join-Path $work "venv"
    New-Item -ItemType Directory -Force $venv | Out-Null
    $venvPython = Join-Path $venv "python"
    Set-Content -Path $venvPython -Value "stub"
    function Get-NotebookVenvPython { return $venvPython }
    function Assert-MlflowServer { [void]$script:calls.Add("assert") }
    function Invoke-MlflowService {
        param([string[]]$ServiceArgs = @())
        [void]$script:calls.Add("service " + ($ServiceArgs -join " "))
        $script:PendingExitCode = $script:serviceRc
        if ($script:serviceRc -ne 0) { return }
        if ($ServiceArgs[0] -eq "start") { $script:running = $true }
        if ($ServiceArgs[0] -eq "stop") { $script:running = $false }
        $state = "stopped"
        if ($script:running) { $state = "running" }
        if ($ServiceArgs -contains "--json") { return ('{"ok": true, "status": "' + $state + '"}') }
    }
    function Reset-Calls { $script:calls.Clear(); $script:said.Clear() }
    function Get-Wish { return ("" + (Get-ExakitManifestValue "components.udf_devkit.mlflow.enabled")).ToLower() }

    Initialize-ExakitManifest | Out-Null

    Write-Host "start records the wish; a failed start does not:"
    $script:serviceRc = 1
    Invoke-CmdMlflow -CmdArgs @("start")
    Check "a failed start wants nothing" "" (Get-Wish)
    $script:serviceRc = 0
    Reset-Calls
    Invoke-CmdMlflow -CmdArgs @("start", "--port", "5123", "--json")
    Check "start asserts the server, then hands the port through" "assert|service start --executable $(Get-MlflowExecutable) --port 5123 --json" ($script:calls -join "|")
    Check "the wish is recorded" "true" (Get-Wish)
    Check "the hook says running" "running" (Get-UdfDevkitStatus)

    Write-Host "stop is for the session; exakit start brings it back:"
    Reset-Calls
    Invoke-CmdMlflow -CmdArgs @("stop")
    Check "stop calls the service's stop" "service stop" ($script:calls -join "|")
    Check "the wish is kept" "true" (Get-Wish)
    Check "the hook says plain stopped" "stopped" (Get-UdfDevkitStatus)
    Reset-Calls
    Start-UdfDevkit
    Contains "exakit start (the hook) starts it" "service start" ($script:calls -join "|")

    Write-Host "disable clears the wish; exakit start then starts nothing:"
    Reset-Calls
    Invoke-CmdMlflow -CmdArgs @("stop", "--disable")
    Check "stop --disable: the service's stop" "service stop" ($script:calls -join "|")
    Check "...the wish is cleared" "false" (Get-Wish)
    Contains "...and it says how to want it again" "until: exakit mlflow start" ($script:said -join "|")
    Reset-Calls
    Start-UdfDevkit
    Check "exakit start (the hook) starts nothing" "" ($script:calls -join "|")
    Check "status says it is not enabled" "stopped (not enabled: exakit mlflow start)" (Get-UdfDevkitStatus)
    Invoke-CmdMlflow -CmdArgs @("start")
    Check "start wants it again" "true" (Get-Wish)
    Reset-Calls
    Invoke-CmdMlflow -CmdArgs @("disable", "--json")
    Check "disable --json: the service's stop with --json" "service stop --json" ($script:calls -join "|")
    Check "disable clears the wish" "false" (Get-Wish)
    Check "...and says nothing in JSON mode" "" ($script:said -join "|")
    $script:serviceRc = 1
    Invoke-CmdMlflow -CmdArgs @("start")
    Invoke-CmdMlflow -CmdArgs @("disable")
    Check "a failed stop leaves the wish as it was" "false" (Get-Wish)
    $script:serviceRc = 0

    Write-Host "arguments:"
    foreach ($case in @(@{ Args = @("frob"); Needle = "replay, disable" },
                        @{ Args = @("stop", "--frob"); Needle = "--disable" },
                        @{ Args = @("status", "--port", "1"); Needle = "Only --json" })) {
        $said = ""
        try { Invoke-CmdMlflow -CmdArgs $case.Args } catch { $said = "$_" }
        Contains "exakit mlflow $($case.Args -join ' ')" $case.Needle $said
    }
    Check "the log target is udf-devkit-mlflow" "udf-devkit-mlflow|MLflow server|$(Join-Path $env:EXAKIT_HOME 'mlflow/server.log')" (Get-UdfDevkitLogPath)
} finally {
    $env:HOME = $oldHome; $env:EXAKIT_HOME = $oldKit
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "mlflow-command-ps: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
