# docker-stub.ps1 - a stand-in docker for tests/runtime-nano-ps.ps1. Records
# every call to calls.log under NANO_STUB_STATE and answers from small state
# files there: container (exists), running, image, cmd, restart, logs,
# repodigests, pull_rc, volume, secret_size. NANO_STUB_DOWN=1 makes `info`
# fail the way a stopped Docker Desktop does. No real engine is involved.
$state = $env:NANO_STUB_STATE
$a = @($args)
Add-Content -Path (Join-Path $state "calls.log") -Value ($a -join " ")
function Say($s) { [Console]::Out.WriteLine("$s") }
function StatePath($n) { return (Join-Path $state $n) }
# ReadState / StatePath: no two-letter names - `rd` is PowerShell's alias for
# Remove-Item, and a helper by that name deleted every state file it read.
function ReadState($n) {
    if (-not (Test-Path (StatePath $n))) { return "" }
    return ((Get-Content (StatePath $n) -Raw) -replace "[`r`n]+$", "")
}
if ($a.Count -eq 0) { exit 0 }
switch ($a[0]) {
    "info" {
        if ($env:NANO_STUB_DOWN -eq "1") { [Console]::Error.WriteLine("error during connect: this error may indicate that the docker daemon is not running"); exit 1 }
        Say "29.0.0"; exit 0
    }
    "container" {
        # container inspect -f <template> <name>
        $fmt = $a[3]; $name = $a[4]
        if (-not (Test-Path (StatePath "container"))) { [Console]::Error.WriteLine("Error: No such container: $name"); exit 1 }
        switch ($fmt) {
            "{{.Id}}" { Say "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }
            "{{.State.Running}}" { Say (ReadState "running") }
            "{{.State.StartedAt}}" { Say "2026-01-01T00:00:00Z" }
            "{{.Config.Cmd}}" { Say (ReadState "cmd") }
            "{{.Config.Image}}" { Say (ReadState "image") }
            "{{.HostConfig.RestartPolicy.Name}}" { Say (ReadState "restart") }
            "{{range .Mounts}}{{.Destination}} {{end}}" { Say "/exa /run/secrets/sys_password " }
            default { Say "" }
        }
        exit 0
    }
    "logs" { Say (ReadState "logs"); exit 0 }
    "pull" {
        $rc = 0
        if (Test-Path (StatePath "pull_rc")) { $rc = [int](ReadState "pull_rc") }
        exit $rc
    }
    "image" {
        if ($a[1] -eq "inspect") { Say (ReadState "repodigests"); exit 0 }
        if ($a[1] -eq "rm") { Set-Content -Path (StatePath "image_removed") -Value $a[-1]; exit 0 }
        exit 0
    }
    "run" {
        $i = 1; $image = ""; $cmd = @(); $restart = "no"
        while ($i -lt $a.Count) {
            $t = $a[$i]
            if ($image) { $cmd += $t; $i++; continue }
            if ($t -in @("--name", "-p", "-v", "--restart")) {
                if ($t -eq "--restart") { $restart = $a[$i + 1] }
                $i += 2; continue
            }
            if ($t.StartsWith("-")) { $i++; continue }
            $image = $t; $i++
        }
        Set-Content -Path (StatePath "container") -Value "1"
        Set-Content -Path (StatePath "running") -Value "true"
        Set-Content -Path (StatePath "image") -Value $image
        Set-Content -Path (StatePath "cmd") -Value ("[" + ($cmd -join " ") + "]")
        Set-Content -Path (StatePath "restart") -Value $restart
        exit 0
    }
    "start" {
        if (-not (Test-Path (StatePath "container"))) { exit 1 }
        Set-Content -Path (StatePath "running") -Value "true"; exit 0
    }
    "stop" { Set-Content -Path (StatePath "running") -Value "false"; exit 0 }
    "rm" { Remove-Item -Force (StatePath "container") -ErrorAction SilentlyContinue; exit 0 }
    "volume" {
        if ($a[1] -eq "inspect") { if (Test-Path (StatePath "volume")) { Say $a[-1]; exit 0 }; exit 1 }
        if ($a[1] -eq "rm") { Remove-Item -Force (StatePath "volume") -ErrorAction SilentlyContinue; exit 0 }
        exit 0
    }
    "update" { Set-Content -Path (StatePath "restart") -Value $a[2]; exit 0 }
    "exec" { Say (ReadState "secret_size"); exit 0 }
    default { exit 0 }
}
exit 0
