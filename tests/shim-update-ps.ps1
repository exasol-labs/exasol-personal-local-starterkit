#!/usr/bin/env pwsh
# shim-update-ps.ps1 - exakit.cmd is never rewritten in place under a running
# exakit.cmd.
#
# cmd.exe re-opens a batch file after each command and resumes at the byte
# offset it had reached. `exakit update` (and `exakit repair-runtime`, which
# re-runs setup-windows.ps1) run under exakit.cmd; rewriting it in place made
# cmd.exe resume inside the NEW shim's self-cleaning line, which deleted the
# shim it had just been given. Set-ExakitCmdShim now stages exakit.cmd.new and
# a detached helper swaps it in after the launcher chain exits.
#
#   pwsh -NoProfile -File tests/shim-update-ps.ps1
# Every write lands in a temp sandbox; the real ~\.local\bin is never touched.

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label = $actual" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected $expected, got $actual" }
}

$commonPath = Join-Path $repo "setup/lib/exakit-common.ps1"
$cErr = $null; $cTok = $null
$cAst = [System.Management.Automation.Language.Parser]::ParseFile($commonPath, [ref]$cTok, [ref]$cErr)
$names = @("Get-ExakitCmdShimContent", "Get-ExakitOemEncoding", "Set-ExakitCmdShim",
           "Test-ExakitCmdShimCurrent", "Write-ExakitCmdShimFile", "Get-ExakitShimLauncherPids",
           "Write-ExakitCmdShimDeferred", "Start-ExakitDetachedPowerShell", "Get-ExakitLauncherRunningPids",
           "Get-ExakitKitScriptRunningPids", "Invoke-ExakitFileReplace")
$defs = @{}
foreach ($name in $names) {
    $def = $cAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1
    if (-not $def) { throw "$name not found in exakit-common.ps1" }
    $defs[$name] = $def.Extent.Text
}
function Import-ShimFunctions { foreach ($n in $names) { Invoke-Expression $defs[$n] } }
. Import-ShimFunctions
function Write-ExakitLog { param($Level, $Message) }

# --- static: the only writer defers under the shim -------------------------
Write-Host "static"
$setBody = $defs["Set-ExakitCmdShim"]
Check "Set-ExakitCmdShim asks whether it runs under the shim" "True" ($setBody.Contains("Get-ExakitShimLauncherPids"))
Check "Set-ExakitCmdShim defers under the shim" "True" ($setBody.Contains("Write-ExakitCmdShimDeferred"))
Check "the deferred writer stages exakit.cmd.new" "True" ($defs["Write-ExakitCmdShimDeferred"].Contains('$newPath = "$ShimPath.new"'))
Check "the deferred writer drops .new when no helper starts" "True" ($defs["Write-ExakitCmdShimDeferred"] -match 'Remove-Item -Force -LiteralPath \$newPath')
$commonText = Get-Content -Raw $commonPath
$writes = ([regex]::Matches($commonText, 'WriteAllText\(\$shimPath')).Count
Check "nothing else writes exakit.cmd directly" "0" $writes

# --- sandbox ---------------------------------------------------------------
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-shimupd-" + [guid]::NewGuid())
$script:BinDir = Join-Path $sandbox "bin"
New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null
$target = Join-Path $sandbox "kit\setup\exakit.ps1"
New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
Set-Content -Path $target -Value "exit 0"
$shimPath = Join-Path $script:BinDir "exakit.cmd"
$newPath = "$shimPath.new"
$oldShim = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$target`" %*`r`n"
function Write-OldShim { [System.IO.File]::WriteAllText($shimPath, $oldShim, [System.Text.Encoding]::ASCII) }
$newShim = Get-ExakitCmdShimContent -PsTarget $target

# --- pure logic: what cmd.exe would read on resume -------------------------
Write-Host ""
Write-Host "resume offset"
$tail = $newShim.Substring([Math]::Min($oldShim.Length, $newShim.Length))
Check "the hazard is real: the new shim's bytes past the old offset delete it" "True" ($tail.Contains("del "))

# Under the shim, helper started.
Write-Host ""
Write-Host "under exakit.cmd"
$script:helperScript = $null
$script:helperOk = $true
function Get-ExakitShimLauncherPids { param([string]$ShimPath) return @(2147483000) }
function Start-ExakitDetachedPowerShell { param([string]$Script) $script:helperScript = $Script; return $script:helperOk }
Write-OldShim
[void](Set-ExakitCmdShim -PsTarget $target)
$onDisk = [System.IO.File]::ReadAllText($shimPath)
Check "exakit.cmd is not rewritten in place" "True" ($onDisk -eq $oldShim)
$resume = ""
if ($onDisk.Length -gt $oldShim.Length) { $resume = $onDisk.Substring($oldShim.Length) }
Check "what cmd.exe resumes into holds no del" "False" ($resume.Contains("del"))
Check "exakit.cmd.new carries the new shim" "True" ((Test-Path -LiteralPath $newPath) -and ([System.IO.File]::ReadAllText($newPath) -eq $newShim))
Check "the helper waits for the launcher pid" "True" ("$script:helperScript".Contains("2147483000"))
# Run the helper's script here: it must move .new over exakit.cmd.
& ([scriptblock]::Create($script:helperScript))
Check "helper: exakit.cmd now has the new content" "True" ([System.IO.File]::ReadAllText($shimPath) -eq $newShim)
Check "helper: exakit.cmd.new is gone" "False" (Test-Path -LiteralPath $newPath)

# Helper could not start: old shim kept, no .new left.
Write-OldShim
$script:helperOk = $false
[void](Set-ExakitCmdShim -PsTarget $target)
Check "no helper: the old shim is kept" "True" ([System.IO.File]::ReadAllText($shimPath) -eq $oldShim)
Check "no helper: no exakit.cmd.new is left" "False" (Test-Path -LiteralPath $newPath)
$script:helperOk = $true

# A current shim is left alone even under the shim.
$script:helperScript = $null
[System.IO.File]::WriteAllText($shimPath, $newShim, [System.Text.Encoding]::ASCII)
[void](Set-ExakitCmdShim -PsTarget $target)
Check "a current shim starts no helper" "True" ($null -eq $script:helperScript)

# Outside the shim (install.ps1): in place, and a leftover .new is dropped.
Write-Host ""
Write-Host "outside exakit.cmd"
function Get-ExakitShimLauncherPids { param([string]$ShimPath) return @() }
Write-OldShim
Set-Content -Path $newPath -Value "stale"
[void](Set-ExakitCmdShim -PsTarget $target)
Check "install: written in place" "True" ([System.IO.File]::ReadAllText($shimPath) -eq $newShim)
Check "install: a leftover exakit.cmd.new is removed" "False" (Test-Path -LiteralPath $newPath)

# --- fail safe: an unreadable chain defers; another running exakit.cmd defers
Write-Host ""
Write-Host "fail safe"
. Import-ShimFunctions
function Get-CimInstance { throw "WMI unavailable" }
$lp = @(Get-ExakitShimLauncherPids -ShimPath $shimPath)
Check "WMI fails: the chain counts as under the shim" "$PID" ($lp -join ",")
Remove-Item Function:\Get-CimInstance
# The parent chain, from a fixed table: only a chain that reaches a cmd.exe is
# under the shim. exakit.ps1 started directly (a scheduled task, an agent) has
# no cmd.exe above it and is never made to wait on explorer.exe.
$script:fakeChain = @{}
function Get-CimInstance {
    param([string]$ClassName, [string]$Filter, $ErrorAction)
    $id = [int]($Filter -replace '^ProcessId=', '')
    return $script:fakeChain[$id]
}
function Set-FakeChain([object[]]$Procs) {
    $script:fakeChain = @{}
    foreach ($p in $Procs) { $script:fakeChain[[int]$p.ProcessId] = $p }
}
$selfCl = "powershell.exe -NoProfile -File C:\kit\setup\exakit.ps1 update"
Set-FakeChain @(
    [pscustomobject]@{ ProcessId = $PID; ParentProcessId = 9001; Name = "powershell.exe"; CommandLine = $selfCl },
    [pscustomobject]@{ ProcessId = 9001; ParentProcessId = 9002; Name = "node.exe"; CommandLine = "node.exe agent.js" },
    [pscustomobject]@{ ProcessId = 9002; ParentProcessId = 0; Name = "explorer.exe"; CommandLine = "C:\Windows\Explorer.EXE" })
Check "no cmd.exe in the chain: not under the shim" "" ((@(Get-ExakitShimLauncherPids -ShimPath $shimPath)) -join ",")
Set-FakeChain @(
    [pscustomobject]@{ ProcessId = $PID; ParentProcessId = 9010; Name = "powershell.exe"; CommandLine = $selfCl },
    [pscustomobject]@{ ProcessId = 9010; ParentProcessId = 9002; Name = "cmd.exe"; CommandLine = "C:\Windows\system32\cmd.exe /c `"`"$shimPath`" update`"" },
    [pscustomobject]@{ ProcessId = 9002; ParentProcessId = 0; Name = "explorer.exe"; CommandLine = "C:\Windows\Explorer.EXE" })
$want = (@($PID, 9010) | Sort-Object) -join ","
Check "cmd /c exakit.cmd: waits on itself and that cmd.exe, not above" $want ((@(Get-ExakitShimLauncherPids -ShimPath $shimPath)) -join ",")
Set-FakeChain @(
    [pscustomobject]@{ ProcessId = $PID; ParentProcessId = 9020; Name = "powershell.exe"; CommandLine = $selfCl },
    [pscustomobject]@{ ProcessId = 9020; ParentProcessId = 9002; Name = "cmd.exe"; CommandLine = "C:\Windows\system32\cmd.exe" },
    [pscustomobject]@{ ProcessId = 9002; ParentProcessId = 0; Name = "explorer.exe"; CommandLine = "C:\Windows\Explorer.EXE" })
Check "interactive cmd.exe: waits on itself only" "$PID" ((@(Get-ExakitShimLauncherPids -ShimPath $shimPath)) -join ",")
Remove-Item Function:\Get-CimInstance
function Get-ExakitShimLauncherPids { param([string]$ShimPath) return @() }
function Get-ExakitLauncherRunningPids { param([string]$Path) return @(2147483001) }
function Start-ExakitDetachedPowerShell { param([string]$Script) $script:helperScript = $Script; return $true }
$script:helperScript = $null
Write-OldShim
[void](Set-ExakitCmdShim -PsTarget $target)
Check "another process runs exakit.cmd: not rewritten in place" "True" ([System.IO.File]::ReadAllText($shimPath) -eq $oldShim)
Check "another process runs exakit.cmd: the helper waits for it" "True" ("$script:helperScript".Contains("2147483001"))
Check "the shim helper rechecks for a fresh exakit.cmd run" "True" ("$script:helperScript".Contains("Get-CimInstance Win32_Process"))
Remove-Item -Force -LiteralPath $newPath -ErrorAction SilentlyContinue

# An `exakit` typed at an interactive cmd.exe prompt: that cmd.exe's command
# line is just "cmd.exe"; only its PowerShell child names the kit's exakit.ps1.
# That PowerShell is waited for (never stopped); a near miss or an editor is not.
. Import-ShimFunctions
function Get-ExakitShimLauncherPids { param([string]$ShimPath) return @() }
function Get-ExakitLauncherRunningPids { param([string]$Path) return @() }
function Start-ExakitDetachedPowerShell { param([string]$Script) $script:helperScript = $Script; return $true }
function Get-CimInstance {
    param([string]$ClassName, [string]$Filter, $ErrorAction)
    @([pscustomobject]@{ ProcessId = 2147483101; Name = "cmd.exe"; CommandLine = "C:\Windows\system32\cmd.exe" },
      [pscustomobject]@{ ProcessId = 2147483102; Name = "powershell.exe"; CommandLine = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$target`" start" },
      [pscustomobject]@{ ProcessId = 2147483103; Name = "PWSH.EXE"; CommandLine = "pwsh -File $target status" },
      [pscustomobject]@{ ProcessId = 2147483104; Name = "powershell.exe"; CommandLine = "powershell -File `"$target.bak`"" },
      [pscustomobject]@{ ProcessId = 2147483105; Name = "notepad.exe"; CommandLine = "notepad.exe `"$target`"" },
      [pscustomobject]@{ ProcessId = $PID; Name = "pwsh.exe"; CommandLine = "pwsh -File `"$target`" update" })
}
Check "a PowerShell running the kit's exakit.ps1 is found (never this one)" "2147483102,2147483103" ((@(Get-ExakitKitScriptRunningPids -Path $target)) -join ",")
$script:helperScript = $null
Write-OldShim
[void](Set-ExakitCmdShim -PsTarget $target)
Check "interactive-cmd run: exakit.cmd not rewritten in place" "True" ([System.IO.File]::ReadAllText($shimPath) -eq $oldShim)
Check "interactive-cmd run: the helper waits for its PowerShell" "True" ("$script:helperScript".Contains("2147483102"))
Check "interactive-cmd run: the helper does not wait for an editor" "False" ("$script:helperScript".Contains("2147483105"))
Check "the helper's recheck also looks for the kit's exakit.ps1" "True" ("$script:helperScript".Contains([regex]::Escape($target)))
Check "the helper never stops what it finds" "False" ("$script:helperScript" -match 'Stop-Process|taskkill')
Remove-Item Function:\Get-CimInstance
Remove-Item -Force -LiteralPath $newPath -ErrorAction SilentlyContinue
. Import-ShimFunctions
function Start-ExakitDetachedPowerShell { param([string]$Script) $script:helperScript = $Script; return $script:helperOk }

# --- the helper never moves under a live waited process or onto a removed target
Write-Host ""
Write-Host "deferred helper guards"
$sig = [System.Management.Automation.Language.Parser]::ParseInput($defs["Write-ExakitCmdShimDeferred"], [ref]$null, [ref]$null)
$toParam = $sig.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] -and $n.Name.VariablePath.UserPath -eq "WaitTimeoutSeconds" }, $true) | Select-Object -First 1
Check "the deferred writer's wait limit defaults to 0 (no limit)" "0" ("" + $toParam.DefaultValue.Extent.Text)
Check "Set-ExakitCmdShim passes no positive wait limit" "False" ($setBody -match '-WaitTimeoutSeconds\s+[1-9]')
$selfExe = (Get-Process -Id $PID).Path
function Invoke-HelperChild {
    # The helper ends with `exit`; run it in its own PowerShell so that exit
    # does not end this test.
    $f = Join-Path $sandbox ("helper-" + [guid]::NewGuid() + ".ps1")
    Set-Content -Path $f -Value $script:helperScript
    & $selfExe -NoProfile -File $f | Out-Null
    Remove-Item -Force -LiteralPath $f -ErrorAction SilentlyContinue
}
$sleepArgs = @{ FilePath = $selfExe; ArgumentList = @("-NoProfile", "-Command", "Start-Sleep -Seconds 60"); PassThru = $true }
if ($env:OS -eq "Windows_NT") { $sleepArgs.WindowStyle = "Hidden" }
$sleeper = Start-Process @sleepArgs
Write-OldShim
Remove-Item -Force -LiteralPath $newPath -ErrorAction SilentlyContinue
$script:helperScript = $null
[void](Write-ExakitCmdShimDeferred -ShimPath $shimPath -Content $newShim -WaitPids @($sleeper.Id) -WaitTimeoutSeconds 1)
Check "bounded wait: helper script carries the limit" "True" ("$script:helperScript".Contains("-Timeout 1"))
Invoke-HelperChild
Check "waited pid still alive after the limit: exakit.cmd untouched" "True" ([System.IO.File]::ReadAllText($shimPath) -eq $oldShim)
Check "waited pid still alive after the limit: exakit.cmd.new removed" "False" (Test-Path -LiteralPath $newPath)
Check "the sleeper was still running (the case was real)" "False" ($sleeper.HasExited)
try { Stop-Process -Id $sleeper.Id -Force -ErrorAction SilentlyContinue } catch { }

Write-OldShim
$script:helperScript = $null
[void](Write-ExakitCmdShimDeferred -ShimPath $shimPath -Content $newShim -WaitPids @(2147483000))
Remove-Item -Force -LiteralPath $shimPath
Invoke-HelperChild
Check "target removed before the move: exakit.cmd not recreated" "False" (Test-Path -LiteralPath $shimPath)
Check "target removed before the move: exakit.cmd.new removed" "False" (Test-Path -LiteralPath $newPath)

# The swap is one File.Replace: a .new that cannot be applied (here a directory
# in its place, as a stand-in for a file a scanner holds) leaves the old
# exakit.cmd in place and the .new where it is - never no exakit.cmd at all.
Check "the helper swaps with File.Replace" "True" ($defs["Invoke-ExakitFileReplace"].Contains('[System.IO.File]::Replace(') -and $defs["Write-ExakitCmdShimDeferred"].Contains('Invoke-ExakitFileReplace -New'))
Check "the helper moves .new only after a failed Replace left the target gone" "1" ([regex]::Matches($defs["Write-ExakitCmdShimDeferred"], 'Move-Item').Count)
Write-OldShim
Remove-Item -Force -Recurse -LiteralPath $newPath -ErrorAction SilentlyContinue
$script:helperScript = $null
[void](Write-ExakitCmdShimDeferred -ShimPath $shimPath -Content $newShim -WaitPids @(2147483000))
Remove-Item -Force -LiteralPath $newPath
New-Item -ItemType Directory -Force -Path $newPath | Out-Null
Set-Content -Path (Join-Path $newPath "held") -Value "x"
Invoke-HelperChild
Check "a .new that cannot be applied: exakit.cmd is still the old one" "True" ((Test-Path -LiteralPath $shimPath -PathType Leaf) -and ([System.IO.File]::ReadAllText($shimPath) -eq $oldShim))
Check "a .new that cannot be applied: the .new stays" "True" (Test-Path -LiteralPath $newPath)
Remove-Item -Force -Recurse -LiteralPath $newPath -ErrorAction SilentlyContinue

# ReplaceFile's half failure (1176/1177): Replace throws after the target is
# gone, with .new still under its own name. exakit.cmd existed before the
# Replace, so .new becomes exakit.cmd; .new is never dropped there.
function Invoke-ExakitFileReplace { param([string]$New, [string]$Target) Remove-Item -Force -LiteralPath $Target; throw "unable to move the replacement file (1176)" }
Write-OldShim
$script:helperScript = $null
[void](Write-ExakitCmdShimDeferred -ShimPath $shimPath -Content $newShim -WaitPids @(2147483000))
Check "half-failed Replace: the helper carries the replace it was given" "True" ("$script:helperScript".Contains("unable to move the replacement file"))
Invoke-HelperChild
Check "half-failed Replace: .new becomes exakit.cmd" "True" ((Test-Path -LiteralPath $shimPath -PathType Leaf) -and ([System.IO.File]::ReadAllText($shimPath) -eq $newShim))
Check "half-failed Replace: no .new is left" "False" (Test-Path -LiteralPath $newPath)
Invoke-Expression $defs["Invoke-ExakitFileReplace"]

# The helper's recheck: a PowerShell running the kit's exakit.ps1 that starts
# after the staged swap (an `exakit` typed at an interactive cmd.exe prompt) is
# waited for before the move. The child gets a process table naming a real,
# short-lived sleeper as that PowerShell.
$sleep2Args = @{ FilePath = $selfExe; ArgumentList = @("-NoProfile", "-Command", "Start-Sleep -Seconds 6"); PassThru = $true }
if ($env:OS -eq "Windows_NT") { $sleep2Args.WindowStyle = "Hidden" }
$sleeper2 = Start-Process @sleep2Args
Write-OldShim
Remove-Item -Force -LiteralPath $newPath -ErrorAction SilentlyContinue
$script:helperScript = $null
[void](Write-ExakitCmdShimDeferred -ShimPath $shimPath -Content $newShim -WaitPids @(2147483000) -Recheck -RecheckScript $target)
$tQ2 = [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($target)
$stubTable = @"
function Get-CimInstance { param([string]`$ClassName, [string]`$Filter, `$ErrorAction)
    if (Get-Process -Id $($sleeper2.Id) -ErrorAction SilentlyContinue) {
        [pscustomobject]@{ ProcessId = $($sleeper2.Id); Name = 'powershell.exe'; CommandLine = 'powershell -NoProfile -File "' + '$tQ2' + '" start' }
    }
}
"@
$f2 = Join-Path $sandbox ("helper-" + [guid]::NewGuid() + ".ps1")
[System.IO.File]::WriteAllText($f2, $stubTable + "`r`n" + $script:helperScript, (New-Object System.Text.UTF8Encoding $true))
$helper2 = Start-Process -FilePath $selfExe -ArgumentList @("-NoProfile", "-File", $f2) -PassThru
Start-Sleep -Seconds 3
Check "recheck: while that PowerShell runs, exakit.cmd is untouched" "True" ([System.IO.File]::ReadAllText($shimPath) -eq $oldShim)
Check "recheck: and the sleeper was still running (the case was real)" "False" ($sleeper2.HasExited)
[void]$helper2.WaitForExit(30000)
Check "recheck: once it exits, the new shim lands" "True" ([System.IO.File]::ReadAllText($shimPath) -eq $newShim)
Remove-Item -Force -LiteralPath $f2 -ErrorAction SilentlyContinue
try { Stop-Process -Id $sleeper2.Id -Force -ErrorAction SilentlyContinue } catch { }

# A path with a typographic apostrophe (U+2019, which PowerShell also reads as
# a single quote) must not end the quoted path in the helper: escaping only the
# ASCII quote broke the script ("missing the terminator") or let the path run
# as code. Built with [char] so this file stays ASCII.
$qDir = Join-Path $sandbox ("O" + [char]0x2019 + "Brien; Write-Output INJECTED; " + [char]0x2019 + "x")
New-Item -ItemType Directory -Force -Path $qDir | Out-Null
$qShimPath = Join-Path $qDir "exakit.cmd"
[System.IO.File]::WriteAllText($qShimPath, $oldShim, [System.Text.Encoding]::ASCII)
$script:helperScript = $null
[void](Write-ExakitCmdShimDeferred -ShimPath $qShimPath -Content $newShim -WaitPids @(2147483000))
$qErr = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($script:helperScript, [ref]$null, [ref]$qErr)
Check "U+2019 in the path: the helper script parses" "0" (@($qErr).Count)
$prevOut = $null
$f = Join-Path $sandbox ("helper-" + [guid]::NewGuid() + ".ps1")
[System.IO.File]::WriteAllText($f, $script:helperScript, (New-Object System.Text.UTF8Encoding $true))
$prevEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$prevOut = & $selfExe -NoProfile -File $f 2>&1 | Out-String -Width 4096
$ErrorActionPreference = $prevEap
Remove-Item -Force -LiteralPath $f -ErrorAction SilentlyContinue
Check "U+2019 in the path: nothing in it runs as code" "False" ($prevOut -match 'INJECTED')
Check "U+2019 in the path: the path round-trips and the new shim lands" "True" ((Test-Path -LiteralPath $qShimPath) -and ([System.IO.File]::ReadAllText($qShimPath) -eq $newShim))
Check "U+2019 in the path: exakit.cmd.new is gone" "False" (Test-Path -LiteralPath "$qShimPath.new")

# --- behavioral (Windows only): a real update from an old-format shim -------
Write-Host ""
Write-Host "cmd.exe (Windows only)"
$cmdExe = Get-Command cmd.exe -ErrorAction SilentlyContinue
if ($cmdExe) {
    . Import-ShimFunctions
    $fnFile = Join-Path $sandbox "shimfns.ps1"
    ($names | ForEach-Object { $defs[$_] }) -join "`r`n" | Set-Content -Path $fnFile
    $binQ = $script:BinDir -replace "'", "''"
    $fnQ = $fnFile -replace "'", "''"
    $tQ = $target -replace "'", "''"
    # The kit's exakit.ps1 stand-in: loads the real shim functions and runs the
    # same call the update path makes, then exits - as `exakit update` does.
    Set-Content -Path $target -Value @"
`$script:BinDir = '$binQ'
function Write-ExakitLog { param(`$Level, `$Message) }
. '$fnQ'
[void](Set-ExakitCmdShim -PsTarget '$tQ')
exit 0
"@
    $newShim = Get-ExakitCmdShimContent -PsTarget $target
    Write-OldShim
    Remove-Item -Force -LiteralPath $newPath -ErrorAction SilentlyContinue
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $out = & cmd.exe /d /c "`"$shimPath`"" 2>&1 | Out-String -Width 4096
    $ErrorActionPreference = $prevEap
    for ($i = 0; $i -lt 40 -and (Test-Path -LiteralPath $newPath); $i++) { Start-Sleep -Milliseconds 500 }
    Check "cmd.exe: no 'is not recognized' fragment ran" "False" ($out -match 'is not recognized')
    Check "cmd.exe: no leftover message" "False" ($out -match 'leftover launcher')
    Check "cmd.exe: exakit.cmd still exists" "True" (Test-Path -LiteralPath $shimPath)
    Check "cmd.exe: exakit.cmd has the new content" "True" ((Test-Path -LiteralPath $shimPath) -and ([System.IO.File]::ReadAllText($shimPath) -eq $newShim))
    Check "cmd.exe: exakit.cmd.new is gone" "False" (Test-Path -LiteralPath $newPath)
} else {
    Write-Host "  skip cmd.exe: not on Windows"
}

Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "PASS=$($script:PASS) FAIL=$($script:FAIL)"
if ($script:FAIL -ne 0) { exit 1 }
