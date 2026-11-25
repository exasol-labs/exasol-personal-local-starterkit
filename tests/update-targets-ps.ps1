#!/usr/bin/env pwsh
# update-targets-ps.ps1 - `exakit update` takes several component ids, as `exakit marketplace` does (#47). The
# real Invoke-CmdUpdate from setup/exakit.ps1 runs with the run itself stood in, so what it would update is
# visible without updating anything. Twin of the #47 checks in update-command-surface.sh. Runs under Windows
# PowerShell 5.1 and pwsh.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0; $script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -ceq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$expected>, got <$actual>" }
}

$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo "setup/exakit.ps1"), [ref]$tokens, [ref]$errors)
foreach ($name in @("Invoke-CmdUpdate", "Invoke-CmdUpdateLocked", "Enter-ExakitUpdateLock", "Exit-ExakitUpdateLock")) {
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    Invoke-Expression $definition.Extent.Text
}
# The update lock lives in a scratch kit home, never the real one.
$script:ExakitHome = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-ulock-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $script:ExakitHome | Out-Null
$updateLock = Join-Path $script:ExakitHome ".update.lock"
$script:ExakitUpdateLockHeld = $false
function Write-ExakitLog { param([string]$Level, [string]$Message) }

function Assert-ExakitInstalled { }
function Initialize-ExakitLogging { }
function Confirm-ExakitTlsPinned { }   # the TLS pin (SEC-14) has its own suite: tls-pin-ps.ps1
# Which words are update targets is the REAL answer (setup/lib/exakit-common.ps1): a stand-in list here once
# carried uv while the real predicate did not, which hid that `exakit update uv` - the status remedy for uv - was
# refused on Windows. Only the add-on registry under it is stood in.
$commonAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo "setup/lib/exakit-common.ps1"), [ref]$tokens, [ref]$errors)
foreach ($name in @("Test-ExakitUpdateTarget", "Get-ExakitUpdateTargets")) {
    $definition = $commonAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    Invoke-Expression $definition.Extent.Text
}
function Get-ExakitMarketplaceAddon([string]$Id) { if (@("dbt-exasol", "dash-server") -contains $Id) { return [pscustomobject]@{ Id = $Id } } return $null }
function Get-ExakitMarketplaceInstalledAddons { return @("dbt-exasol", "dash-server") }
function Get-ExakitSkillsDir { return "skills" }
function Fail([string]$Message) { throw "FAIL: $Message" }
function Deny-ExakitInput([string]$Message) { throw "DENIED: $Message" }
function Invoke-ExakitUpdateRun { param([string]$Target, $Components, [bool]$AssumeYes)
    $script:ran = "target=$Target|components=$(@($Components) -join ',')" }

function Run([string]$Target, [string[]]$More) {
    $script:ran = ""
    try { Invoke-CmdUpdate -Target $Target -More $More; return $script:ran } catch { return "$($_.Exception.Message)" }
}

Write-Host "== several ids =="
Check "two ids update both" "target=exapump dbt-exasol|components=exapump,dbt-exasol" (Run "exapump" @("dbt-exasol"))
Check "a repeated id is updated once" "target=exapump dbt-exasol exapump|components=exapump,dbt-exasol" (Run "exapump" @("dbt-exasol", "exapump"))
Check "one id still updates just that one" "target=exapump|components=" (Run "exapump" @())

Check "the run took the update lock and gave it back" "False" (Test-Path -LiteralPath $updateLock)

Write-Host "== one exakit update at a time =="
# A person and an agent ran `exakit update` in the same minute, and neither run knew of the other. A second run
# now waits with a line naming the first, or stops with exit 1 and the reason. Twin of the lock checks in
# versions-manifest.sh.
$holderArgs = @("-NoProfile", "-Command", "Start-Sleep -Seconds 60")
$holder = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $holderArgs -PassThru
Start-Sleep -Milliseconds 500
Set-Content -LiteralPath $updateLock -Value "$($holder.Id)`n$($holder.StartTime.ToString('o'))"
$env:EXAKIT_UPDATE_LOCK_WAIT = "1"
$busy = @(Enter-ExakitUpdateLock -Json $false)
Check "a live holder: the second run stops when the wait runs out" "False" $busy[-1]
Check "...and leaves the other run's lock alone" "$($holder.Id)" "$(@(Get-Content -LiteralPath $updateLock)[0])"
$busyJson = @(Enter-ExakitUpdateLock -Json $true)
$busyObject = ($busyJson[0..($busyJson.Count - 2)] -join "`n") | ConvertFrom-Json
Check "--json: one object, ok false, the reason named" "False|failed|True" "$($busyObject.ok)|$($busyObject.status)|$($busyObject.remedy_hint -like "*pid $($holder.Id)*still running*")"
Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
$holder.WaitForExit(10000) | Out-Null
$takeOver = @(Enter-ExakitUpdateLock -Json $false)
Check "a dead run's lock is taken over" "True|$PID" "$($takeOver[-1])|$(@(Get-Content -LiteralPath $updateLock)[0])"
Exit-ExakitUpdateLock
Check "...and given back" "False" (Test-Path -LiteralPath $updateLock)
# The holder finishes while the second run waits under its spinner (measured on Windows: the finished line was
# printed while the spinner still owned the line, and landed on the end of its last frame). The spinner stands
# in on stderr: a frame with no newline, and a stop that returns to column 0 and clears the line. The screen is
# read the way a terminal shows it, so a line printed before the stop shares the frame's line.
$esc = [char]27
function Start-ExakitSpinner([string]$Label) { [Console]::Error.Write("<frame $Label (3s)>") }
function Stop-ExakitSpinner { [Console]::Error.Write("<stop>`r$esc[K") }
# The bullet ui.ps1 sets on a Unicode console, so the lines are seen to be Info's, not hand-written.
$script:UiBullet = [string][char]0x2022
$holder = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @("-NoProfile", "-Command", "Start-Sleep -Seconds 2") -PassThru
Start-Sleep -Milliseconds 500
Set-Content -LiteralPath $updateLock -Value "$($holder.Id)`n$($holder.StartTime.ToString('o'))"
$env:EXAKIT_UPDATE_LOCK_WAIT = "30"
$errWas = [Console]::Error
$errCapture = New-Object System.IO.StringWriter
[Console]::SetError($errCapture)
try { $waited = @(Enter-ExakitUpdateLock -Json $false) } finally { [Console]::SetError($errWas) }
$raw = $errCapture.ToString()
$screen = @(($raw -replace "`r`n", "`n") -split "`n" | ForEach-Object { (($_ -split "`r")[-1]) -replace [regex]::Escape("$esc[K"), "" })
$finished = "    $($script:UiBullet) The other update finished - continuing"
Check "a waiting run carries on once the other finishes" "True" "$($waited[-1])"
Check "...the waiting line is an info line" "True" ($screen -contains "    $($script:UiBullet) Another exakit update is running (pid $($holder.Id)) - waiting for it to finish")
Check "...the spinner is stopped before the finished line" "True" ($raw.IndexOf("<stop>") -ge 0 -and $raw.IndexOf("<stop>") -lt $raw.IndexOf("The other update finished"))
Check "...which is a line of its own, not the end of the spinner's frame" "True" ($screen -contains $finished)
Check "...and the spinner is stopped once" "1" "$(([regex]::Matches($raw, '<stop>')).Count)"
Remove-Item Function:\Start-ExakitSpinner, Function:\Stop-ExakitSpinner
$script:UiBullet = $null
$holder.WaitForExit(10000) | Out-Null
Exit-ExakitUpdateLock
$env:EXAKIT_UPDATE_HANDOVER = "1"
Set-Content -LiteralPath $updateLock -Value "$PID"
Check "a handed-over run takes no lock and does not wait" "True" (@(Enter-ExakitUpdateLock -Json $false)[-1])
Remove-Item -Force -LiteralPath $updateLock -ErrorAction SilentlyContinue
$env:EXAKIT_UPDATE_HANDOVER = $null
$env:EXAKIT_UPDATE_LOCK_WAIT = $null

Write-Host "== refusals =="
Check "an unknown second id is named" "True" ((Run "exapump" @("nonsense")) -match "Unknown update target 'nonsense'")
Check "'all' beside other ids is refused" "True" ((Run "exapump" @("all")) -match "cannot be named beside other components")
Check "ids after 'all' are refused" "True" ((Run "all" @("exapump")) -match "updates everything")

Write-Host "== the dispatcher's update arm hands every id on (#47) =="
# The real "update" arm of the command switch in setup/exakit.ps1, run as written with Invoke-CmdUpdate stood in.
# The #47 bug was in that arm: it passed the first id and dropped the rest, and a test that called Invoke-CmdUpdate
# directly stayed green with it restored (QAT-02).
$updateSwitch = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.SwitchStatementAst] -and
    @($node.Clauses | Where-Object { "$($_.Item1.Value)" -eq "update" }).Count -eq 1 -and
    @($node.Clauses | Where-Object { "$($_.Item1.Value)" -eq "info" }).Count -eq 1 }, $true)
$updateArmText = (@($updateSwitch.Clauses | Where-Object { "$($_.Item1.Value)" -eq "update" })[0].Item2.Extent.Text).Trim()
$updateArmBlock = [scriptblock]::Create($updateArmText.Substring(1, $updateArmText.Length - 2))   # the arm's body, not its braces
$knownOptionsAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Assert-ExakitKnownOptions" }, $true)
Invoke-Expression $knownOptionsAst.Extent.Text
function Invoke-UpdateArm([string[]]$Words) {
    $RestArgs = @($Words)
    function Invoke-CmdUpdate { param([string]$Target = "all", [string[]]$More = @(), [bool]$AssumeYes = $false, [bool]$Json = $false)
        $script:armCall = "target=$Target|bound=$($PSBoundParameters.ContainsKey('Target'))|more=$(@($More).Count):$(@($More) -join ',')|yes=$AssumeYes|json=$Json" }
    $script:armCall = ""
    try { & $updateArmBlock } catch { return "$($_.Exception.Message)" }
    return $script:armCall
}
Check "two ids: both reach Invoke-CmdUpdate" "target=exapump|bound=True|more=1:dbt-exasol|yes=False|json=False" (Invoke-UpdateArm @("exapump", "dbt-exasol"))
Check "three ids with options anywhere" "target=runtime|bound=True|more=2:dash-server,uv|yes=True|json=True" (Invoke-UpdateArm @("--yes", "runtime", "dash-server", "--json", "uv"))
Check "no id: the default target, not an empty one" "target=all|bound=False|more=0:|yes=False|json=False" (Invoke-UpdateArm @())
Check "an empty second id is handed on, so it is refused" "target=dash-server|bound=True|more=1:|yes=False|json=False" (Invoke-UpdateArm @("dash-server", ""))
Check "an empty first id is handed on as an explicit target" "target=|bound=True|more=0:|yes=False|json=False" (Invoke-UpdateArm @(""))
Check "the staged-upgrade flags are refused on Windows" "True" ((Invoke-UpdateArm @("personal", "--plan")) -like "DENIED: --plan is part of the staged major-upgrade route*")
# A "tell me" flag never changes anything: refused before the update runs at
# all, on every arm of the personal row (the sh twin says what it would do
# instead, review H1). Nothing reaches Invoke-CmdUpdate.
foreach ($tellMe in @("--plan", "--backup")) {
    $refused = Invoke-UpdateArm @("personal", $tellMe, "--yes")
    Check "personal $tellMe --yes: refused before anything runs, the update never called" "True|" "$($refused -like "DENIED: $tellMe is part of the staged major-upgrade route*")|$($script:armCall)"
}

Write-Host "== every target the shell takes, in any order (#47) =="
Check "uv is an update target (the status remedy for uv)" "target=uv|components=" (Run "uv" @())
Check "uv beside another id" "target=exapump uv|components=exapump,uv" (Run "exapump" @("uv"))
Check "runtime first, then an add-on: both are updated" "target=runtime dash-server|components=runtime,dash-server" (Run "runtime" @("dash-server"))
Check "personal first, then an id: both are updated" "target=personal exapump|components=personal,exapump" (Run "personal" @("exapump"))
Check "database first: the runtime and exapump, the runtime once" "target=database exapump db|components=runtime,exapump" (Run "database" @("exapump", "db"))
Check "no id at all is everything" "target=all|components=" $(try { $script:ran = ""; Invoke-CmdUpdate; $script:ran } catch { "$($_.Exception.Message)" })

Write-Host "== an empty id is refused, never read as everything =="
$emptyText = "is empty. Name each component to update, or run 'exakit update' alone to update everything."
Check "an empty second id is refused, naming it" "DENIED: Component id 2 of 'exakit update' $emptyText" (Run "dash-server" @(""))
Check "an empty first id is refused, naming it" "DENIED: Component id 1 of 'exakit update' $emptyText" (Run "" @("dash-server"))
Check "an empty id alone is refused" "DENIED: Component id 1 of 'exakit update' $emptyText" (Run "" @())

Write-Host "== the kit moves first, then the new kit finishes the run (#45) =="
# The real Invoke-ExakitUpdateRun with the updaters stood in: after the kit's own update this process holds the
# old code and manifest, so it updates nothing else and hands the run to the new kit (core-setup.ps1's
# Invoke-ExakitUpdateHandover, stood in here; tests/core-setup.ps1 runs the real one). "all" stays all, named ids
# hand over the kit and the ids after it, and the run uses the ids -Components holds - never the joined -Target
# string, which once failed as "Unknown update target: exapump dbt-exasol". Twin of the #45 checks in
# update-command-surface.sh.
$run = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Invoke-ExakitUpdateRun" }, $true)
Invoke-Expression $run.Extent.Text
$hoTarget = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Get-ExakitHandoverTarget" }, $true)
Invoke-Expression $hoTarget.Extent.Text
# The version comparison the run asks is the real one (setup/lib/exakit-common.ps1).
$cmpAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo "setup/lib/exakit-common.ps1"), [ref]$tokens, [ref]$errors)
foreach ($fnName in @("Get-ExakitVersionPlain", "Test-ExakitVersionSame", "Test-ExakitVersionNewer", "Get-ExakitNoticeStillBehind")) {
    $fnAst = $cmpAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $fnName }, $true)
    Invoke-Expression $fnAst.Extent.Text
}
$script:VersionPolicy = "pinned"
$script:kit = "0.2.0"
$script:log = New-Object System.Collections.ArrayList
function Write-ExakitVersionsSourceLine { }
function Get-ExakitActualTarget([string]$Name) { return $Name }
function Get-ExakitComponentCurrent([string]$Name) { if ($Name -eq "exakit") { return $script:kit } return "1.0" }
function Get-ExakitComponentAvailable([string]$Name) { if ($Name -eq "exakit") { return "0.2.3" } return "2.0" }
function Get-ExakitManifestValue([string]$Key) { if ($Key -eq "kit.version") { return $script:kit } return "" }
function Test-ExakitComponentManaged { return $true }
function Test-ExakitComponentSupported { return $true }
function Test-ExakitComponentAhead { return $false }
function Test-ExakitComponentHeavy { return $false }
function Get-ExakitComponentMinKit { return "" }
function Test-ExakitMinKitSatisfied { return $true }
function Info([string]$Message) { [void]$script:log.Add("info:$Message") }
function Ok([string]$Message) { [void]$script:log.Add("ok:$Message") }
function Warn2([string]$Message) { [void]$script:log.Add("warn:$Message") }
$script:notes = New-Object System.Collections.ArrayList
$script:noteErrors = New-Object System.Collections.ArrayList
function Add-ExakitUpdateNote { param([string]$Component, [string]$Outcome, [string]$From, [string]$To, [string]$Remedy,
        [string]$ErrorText = "", [string]$Hint = "")
    [void]$script:notes.Add("$Component|$Outcome|$Remedy")
    if ($ErrorText -or $Hint) { [void]$script:noteErrors.Add("$Component|$ErrorText|$Hint") } }
function Update-ExakitSelf { [void]$script:log.Add("this-process:exakit"); $script:kit = "0.2.3"; $script:ExakitKitSwapped = $true }
function Get-ExakitMarketplaceAddon([string]$Id) { return [pscustomobject]@{ UpdateFn = "Update-StandIn-$Id" } }
function Update-StandIn-dbt-exasol { [void]$script:log.Add("this-process:dbt-exasol") }
function Update-StandIn-exasol-scheduler { [void]$script:log.Add("this-process:exasol-scheduler") }
$script:handedOver = $null
$script:handoverAnswer = 0
function Invoke-ExakitUpdateHandover { param([string]$Target = "all", [bool]$AssumeYes = $false)
    $script:handedOver = $Target
    # Under --json the new run's rows come back into this run's results (Invoke-ExakitUpdateHandover merges them).
    if ($null -ne $script:handoverAnswer -and $script:ExakitUpdateJson) {
        foreach ($id in @($Target -split ' ' | Where-Object { $_ -and $_ -ne "exakit" })) {
            if ($id -eq "all") { foreach ($one in @("exasol-scheduler", "dbt-exasol")) { [void]$script:notes.Add("$one|updated|") } }
            else { [void]$script:notes.Add("$id|updated|") }
        }
    }
    return $script:handoverAnswer
}
function Reset-Run { $script:kit = "0.2.0"; $script:log.Clear(); $script:notes.Clear(); $script:handedOver = $null; $script:handoverAnswer = 0 }

$script:ExakitUpdateJson = $false
Invoke-ExakitUpdateRun -Target "all" -Components @("exakit", "exasol-scheduler", "dbt-exasol")
Check "the kit is updated in this process" "True" ($script:log -contains "this-process:exakit")
Check "...and no add-on with the old code" "False" (($script:log -contains "this-process:exasol-scheduler") -or ($script:log -contains "this-process:dbt-exasol"))
Check "the new kit is handed the run: all stays all" "all" $script:handedOver

Reset-Run
$script:ExakitUpdateJson = $true
Invoke-ExakitUpdateRun -Target "all" -Components @("exakit", "exasol-scheduler", "dbt-exasol")
Check "under --json the handed-over run's rows are the answer" "exasol-scheduler|updated|;dbt-exasol|updated|" (@($script:notes | Where-Object { $_ -notlike "exakit|*" }) -join ";")
Check "...and nothing is deferred" "" (@($script:notes | Where-Object { $_ -like "*|deferred|*" }) -join ";")
$script:ExakitUpdateJson = $false

Reset-Run
Invoke-ExakitUpdateRun -Target "exasol-scheduler exakit dbt-exasol" -Components @("exasol-scheduler", "exakit", "dbt-exasol")
Check "several ids run from -Components, not the joined -Target" "this-process:exasol-scheduler|this-process:exakit" (@($script:log | Where-Object { $_ -like "this-process:*" }) -join "|")
Check "...the kit and the ids after it are handed over" "exakit dbt-exasol" $script:handedOver

Reset-Run
Invoke-ExakitUpdateRun -Target "exasol-scheduler dbt-exasol" -Components @("exasol-scheduler", "dbt-exasol")
Check "several ids without the kit: each is updated here, nothing is handed over" "this-process:exasol-scheduler|this-process:dbt-exasol|" ((@($script:log | Where-Object { $_ -like "this-process:*" }) -join "|") + "|" + $script:handedOver)

Reset-Run
$script:handoverAnswer = $null
$script:ExakitUpdateJson = $true
Invoke-ExakitUpdateRun -Target "all" -Components @("exakit", "exasol-scheduler", "dbt-exasol")
Check "no new command to hand over to: the rest is deferred to the next run" "exasol-scheduler|deferred|exakit update;dbt-exasol|deferred|exakit update" (@($script:notes | Where-Object { $_ -like "*|deferred|*" }) -join ";")
$script:ExakitUpdateJson = $false

Write-Host "== every update run ends with a line that says how it ended =="
# Seen on a Mac: the run reinstalled an add-on, printed its own last line and gave the prompt back with nothing
# after it. Twin of the closing-line checks in versions-manifest.sh.
Reset-Run
Invoke-ExakitUpdateRun -Target "exasol-scheduler dbt-exasol" -Components @("exasol-scheduler", "dbt-exasol")
Check "a run that updated something says it finished, and what" "ok:Update finished - updated: exasol-scheduler, dbt-exasol" `
    (@($script:log | Where-Object { $_ -like "ok:Update finished*" }) -join "|")

Write-Host "== a named add-on that is not installed: the remedy is the install =="
# Its module refused with "not kit-owned; its owner manages updates" and the failed row's remedy was the same
# command, so an agent obeying remedy looped. No kit receipt and nothing of the user's: the module never runs,
# and the screen, the row and the closing line name the install. Twin of the same checks in
# update-command-surface.sh.
$ownKeyAst = $cmpAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Get-ExakitOwnershipKey" }, $true)
Invoke-Expression $ownKeyAst.Extent.Text
function Test-ExakitAddonSystemPresent([string]$Id) { return $false }
function Get-ExakitComponentCurrent([string]$Name) { if ($Name -eq "exakit") { return $script:kit } if ($Name -eq "dbt-exasol") { return "" } return "1.0" }
Reset-Run
$script:noteErrors.Clear()
$script:ExakitUpdateJson = $true
Invoke-ExakitUpdateRun -Target "exasol-scheduler dbt-exasol" -Components @("exasol-scheduler", "dbt-exasol")
$script:ExakitUpdateJson = $false
Check "its module never runs, the others do" "this-process:exasol-scheduler" (@($script:log | Where-Object { $_ -like "this-process:*" }) -join "|")
Check "it says it is not installed and names the install" "warn:dbt-exasol is not installed, so there is nothing to update. Install it with: exakit marketplace dbt-exasol" `
    (@($script:log | Where-Object { $_ -like "warn:dbt-exasol*" }) -join "|")
Check "the row is failed, its remedy the install, its reason not installed" `
    "dbt-exasol|failed|exakit marketplace dbt-exasol;dbt-exasol|dbt-exasol is not installed, so there is nothing to update.|Install it with: exakit marketplace dbt-exasol" `
    ((@($script:notes | Where-Object { $_ -like "dbt-exasol|*" }) + @($script:noteErrors)) -join ";")
# On the screen the run ends with exit 1, so the closing line is read from a child process of the same engine.
$missingChild = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-missing-" + [guid]::NewGuid().ToString("N") + ".ps1")
Set-Content -LiteralPath $missingChild -Encoding ASCII -Value @'
param([string]$Repo)
$ErrorActionPreference = "Stop"
$t = $null; $e = $null
$cliAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo "setup/exakit.ps1"), [ref]$t, [ref]$e)
$libAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo "setup/lib/exakit-common.ps1"), [ref]$t, [ref]$e)
foreach ($pair in @(@($cliAst, "Invoke-ExakitUpdateRun"), @($libAst, "Get-ExakitOwnershipKey"), @($libAst, "Get-ExakitVersionPlain"), @($libAst, "Test-ExakitVersionSame"))) {
    $wanted = $pair[1]
    $node = $pair[0].Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $wanted }, $true)
    Invoke-Expression $node.Extent.Text
}
$script:VersionPolicy = "pinned"
function Write-ExakitVersionsSourceLine { }
function Add-ExakitUpdateNote { }
function Info([string]$Message) { Write-Host "info: $Message" }
function Ok([string]$Message) { Write-Host "ok: $Message" }
function Warn2([string]$Message) { Write-Host "warn: $Message" }
function Get-ExakitActualTarget([string]$Name) { return $Name }
function Get-ExakitComponentCurrent([string]$Name) { if ($Name -eq "dbt-exasol") { return "" } return "1.0" }
function Get-ExakitComponentAvailable([string]$Name) { return "2.0" }
function Get-ExakitManifestValue([string]$Key) { return $null }
function Test-ExakitComponentManaged { return $true }
function Test-ExakitComponentSupported { return $true }
function Test-ExakitComponentAhead { return $false }
function Test-ExakitComponentHeavy { return $false }
function Test-ExakitAddonNeedsUpdate { return $false }
function Test-ExakitAddonSystemPresent { return $false }
function Get-ExakitComponentMinKit { return "" }
function Get-ExakitMarketplaceAddon([string]$Id) { return [pscustomobject]@{ UpdateFn = "Update-StandIn" } }
function Update-StandIn { Write-Host "module ran" }
$script:ExakitUpdateJson = $false
Invoke-ExakitUpdateRun -Target "exasol-scheduler dbt-exasol" -Components @("exasol-scheduler", "dbt-exasol")
exit 0
'@
$missingEngine = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$previousPref = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$missingOut = @(& $missingEngine -NoProfile -ExecutionPolicy Bypass -File $missingChild -Repo $repo 2>&1 | ForEach-Object { "$_" })
$missingRc = $LASTEXITCODE
$ErrorActionPreference = $previousPref
Remove-Item -Force -LiteralPath $missingChild -ErrorAction SilentlyContinue
Check "on the screen the closing line names the install, not a retry, and the run exits 1" `
    "1|warn: Update finished with problems (updated: exasol-scheduler). Install what is missing with: exakit marketplace dbt-exasol|1" `
    ("$missingRc|" + (@($missingOut | Where-Object { $_ -like "*Update finished*" }) -join ";") + "|" + @($missingOut | Where-Object { $_ -eq "module ran" }).Count)
function Get-ExakitComponentCurrent([string]$Name) { if ($Name -eq "exakit") { return $script:kit } return "1.0" }

Write-Host "== a component the kit did not install is updated through its owner, or kept =="
# Product owner, 0.3.0: a uv or pyexasol the kit did not install is updated THROUGH THE TOOL THAT OWNS IT (winget,
# scoop, pipx, the uv installer, that Python's pip), never by writing its files. No owner it can name, or an owner
# update that did not work, keeps it with one line naming the command (a warning row). Equal or newer: nothing
# runs. The owner commands are stand-ins that record their argv, so no real winget, scoop, pipx, uv or pip is
# reached. Twin of the same checks in update-command-surface.sh.
& {
    foreach ($fnName in @("Write-ExakitPreservedComponent", "Resolve-ExakitLinkTarget", "Test-ExakitPathUnder", "Get-ExakitForeignOwner", "Update-ExakitForeignComponent")) {
        $fnAst = $cmpAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $fnName }, $true)
        Invoke-Expression $fnAst.Extent.Text
    }
    $ownRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-own-" + [guid]::NewGuid().ToString("N"))
    $wingetUv = Join-Path $ownRoot "Microsoft\WinGet\Packages\astral-sh.uv_Microsoft.Winget.Source_8wekyb3d8bbwe\uv.exe"
    $plainUv = Join-Path $ownRoot "elsewhere\uv.exe"
    $userPython = Join-Path $ownRoot "venv\python.exe"
    foreach ($f in @($wingetUv, $plainUv, $userPython)) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $f) | Out-Null
        Set-Content -LiteralPath $f -Value "stand-in"
    }
    $localWas = $env:LOCALAPPDATA; $appWas = $env:APPDATA; $xdgWas = $env:XDG_CONFIG_HOME
    $env:LOCALAPPDATA = $ownRoot; $env:APPDATA = Join-Path $ownRoot "roaming"; $env:XDG_CONFIG_HOME = $null
    $script:fv = @{}
    $script:ownerCalls = New-Object System.Collections.ArrayList
    $script:ownerFails = $false
    $script:uvAt = $wingetUv
    $script:pyWord = "venv"
    function Get-ExakitUvReport { return @{ Verdict = "ok"; Path = $script:uvAt; Version = $script:fv["uv"]; Min = "0.13.4" } }
    function Get-ExakitManifestValue([string]$Key) { if ($Key -eq "components.pyexasol.python") { return $userPython } return "" }
    function Get-ExakitPipProbeWord([string]$Python) { return $script:pyWord }
    function Get-ExakitTilde([string]$Path) { return $Path }
    # Stand-ins shadow any real winget, scoop or pipx on the runner (GitHub's Windows images carry pipx).
    function winget { }
    function scoop { }
    function pipx { }
    function Get-ExakitProfileHome { return $ownRoot }
    function Invoke-ExakitLogged { param([string]$Cmd, [Parameter(ValueFromRemainingArguments)]$CmdArgs)
        $name = Split-Path -Leaf $Cmd
        [void]$script:ownerCalls.Add("$name $($CmdArgs -join ' ')")
        if ($script:ownerFails) { return 1 }
        if ($name -eq "python.exe") { $script:fv["pyexasol"] = "2.5.0" } else { $script:fv["uv"] = "0.13.8" }
        return 0 }
    function Get-ExakitComponentCurrent([string]$Name) { return $script:fv[$Name] }
    function Get-ExakitComponentAvailable([string]$Name) { if ($Name -eq "pyexasol") { return "2.4.1" } return "0.13.8" }
    function Test-ExakitComponentManaged { param([string]$Id) return $false }
    function Add-ExakitUpdateNote { param([string]$Component, [string]$Outcome, [string]$From, [string]$To, [string]$Remedy, [string]$ErrorText, [string]$Hint)
        [void]$script:notes.Add("$Component|$Outcome|$From|$To|$Remedy|$Hint") }
    function Own([string]$Id, [string]$Installed) {
        Reset-Run
        $script:ownerCalls.Clear()
        $script:fv[$Id] = $Installed
        Invoke-ExakitUpdateRun -Target $Id -Components @($Id)
    }
    $wingetCmd = "winget upgrade --id astral-sh.uv --exact --silent --accept-source-agreements --accept-package-agreements"

    Own "uv" "0.13.2"
    Check "a winget uv behind the advertised version is updated with winget upgrade" "winget upgrade --id astral-sh.uv --exact --silent --accept-source-agreements --accept-package-agreements" ($script:ownerCalls -join ";")
    Check "...the screen says which owner and which command" "True" ($script:log -contains "info:uv was installed with winget. Updating it with: $wingetCmd")
    Check "...and the version it reached" "True" ($script:log -contains "ok:uv updated to 0.13.8 (winget)")
    Check "...the --json row is updated, with the owner" "uv|updated|0.13.2|0.13.8||updated through its owner, winget: $wingetCmd" ($script:notes -join ";")
    Check "...and it counts in the closing line" "True" ($script:log -contains "ok:Update finished - updated: uv")

    Own "uv" "0.13.8"
    Check "an equal uv runs nothing and is current" "|uv|current|0.13.8|0.13.8||" (($script:ownerCalls -join ";") + "|" + ($script:notes -join ";"))
    Own "uv" "0.14.0"
    Check "a newer uv runs nothing and is never moved back" "|uv|ahead|0.14.0|0.13.8||" (($script:ownerCalls -join ";") + "|" + ($script:notes -join ";"))

    $script:ownerFails = $true
    Own "uv" "0.13.2"
    Check "an owner update that fails is a warning row with the command as the remedy" "True|uv|skipped|0.13.2|0.13.8|$wingetCmd|kept as it is: updating it with winget did not work. Run the remedy yourself" `
        ("" + ($script:log -contains "warn:Updating uv with winget did not work, so uv 0.13.2 stays as it is. Run it yourself: $wingetCmd") + "|" + ($script:notes -join ";"))
    $script:ownerFails = $false

    $script:uvAt = $plainUv
    Own "uv" "0.13.2"
    Check "a uv whose owner cannot be found is kept, and nothing runs" "|True" (($script:ownerCalls -join ";") + "|" + ($script:log -contains "info:Leaving uv 0.13.2 as it is. The kit did not install it and could not tell which tool did, so update it with the tool you installed it with."))
    Check "...its --json row says why" "uv|skipped|0.13.2|0.13.8||kept as it is: installed outside the kit, and the tool that installed it could not be found. Update it with that tool" ($script:notes -join ";")
    New-Item -ItemType Directory -Force -Path (Join-Path $ownRoot "uv") | Out-Null
    Set-Content -LiteralPath (Join-Path $ownRoot "uv\uv-receipt.json") -Value ('{"install_prefix":' + (ConvertTo-Json (Split-Path -Parent $plainUv)) + '}')
    Own "uv" "0.13.2"
    Check "a uv from the uv installer is updated with uv self update <advertised>" "uv.exe self update 0.13.8|True" (($script:ownerCalls -join ";") + "|" + ($script:log -contains "ok:uv updated to 0.13.8 (the uv installer)"))

    $script:uvAt = Join-Path $ownRoot "scoop\apps\uv\current\uv.exe"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:uvAt) | Out-Null
    Set-Content -LiteralPath $script:uvAt -Value "stand-in"
    Own "uv" "0.13.2"
    Check "a scoop uv is updated with scoop update uv" "scoop update uv|True" (($script:ownerCalls -join ";") + "|" + ($script:log -contains "ok:uv updated to 0.13.8 (scoop)"))

    Own "pyexasol" "2.3.0"
    Check "a user pyexasol in a venv is updated with that Python's pip" "python.exe -m pip install --upgrade pyexasol|True" (($script:ownerCalls -join ";") + "|" + ($script:log -contains "ok:pyexasol updated to 2.5.0 (pip)"))
    $script:pyWord = "managed"
    Own "pyexasol" "2.3.0"
    Check "a PEP 668 (externally managed) Python is kept: no pip, no --break-system-packages" "|True" (($script:ownerCalls -join ";") + "|" + ($script:log -contains "info:Leaving pyexasol 2.3.0 as it is. Its Python ($userPython) is managed by the operating system or a package manager (PEP 668), so the kit does not install into it. Update it with that package manager."))
    $script:pyWord = "readonly"
    Own "pyexasol" "2.3.0"
    Check "a Python the user cannot write to is kept, and nothing runs" "|pyexasol|skipped|2.3.0|2.4.1||kept as it is: the kit cannot update it safely in that Python environment. Update it the way you installed it" (($script:ownerCalls -join ";") + "|" + ($script:notes -join ";"))

    $script:fv["exapump"] = "0.13.0"
    Reset-Run
    Invoke-ExakitUpdateRun -Target "exapump" -Components @("exapump")
    Check "a user exapump keeps the line it always had" "True|exapump|skipped|0.13.0|0.13.8||kept as it is: the kit did not install it, or has no record that it did" `
        ("" + ($script:log -contains "info:Leaving exapump as it is (the kit did not install it, or has no record that it did).") + "|" + ($script:notes -join ";"))
    $env:LOCALAPPDATA = $localWas; $env:APPDATA = $appWas; $env:XDG_CONFIG_HOME = $xdgWas
    Remove-Item -Recurse -Force -LiteralPath $ownRoot -ErrorAction SilentlyContinue
}

Write-Host "== a v-prefixed pin is the same version as the bare one it installed =="
# versions.json pins semantic-views v0.6.1 (a git tag) and its probe answers 0.6.1. Compared with -eq, every
# `exakit update` "updated" it 0.6.1 -> v0.6.1 (retiring and re-registering its module), never said everything
# was current, and the update notice returned after every command (Windows 11 upgrade re-run). Twin of the same
# checks in update-command-surface.sh.
Reset-Run
$script:vCurrent = @{ "semantic-views" = "0.6.1"; "json-tables" = "v0.4.1"; "exapump" = "0.13.0"; "mcp" = "2.4.0" }
$script:vAvailable = @{ "semantic-views" = "v0.6.1"; "json-tables" = "0.4.1"; "exapump" = "v0.14.0" }
function Get-ExakitComponentCurrent([string]$Name) { return $script:vCurrent[$Name] }
function Get-ExakitComponentAvailable([string]$Name) { return $script:vAvailable[$Name] }
function Test-ExakitAddonNeedsUpdate([string]$Id) { return $false }
function Update-StandIn-semantic-views { [void]$script:log.Add("this-process:semantic-views") }
function Update-StandIn-json-tables { [void]$script:log.Add("this-process:json-tables") }
Invoke-ExakitUpdateRun -Target "all" -Components @("semantic-views", "json-tables")
Check "0.6.1 against v0.6.1 (and v0.4.1 against 0.4.1) is current" "semantic-views|current|;json-tables|current|" ($script:notes -join ";")
Check "...and nothing is updated" "" (@($script:log | Where-Object { $_ -like "this-process:*" }) -join "|")
# (The cached notice re-reads only the cheap components, never an add-on's module: mcp stands in here.)
Check "the cached update notice drops a v-spelled match and keeps a real one" "exapump" ((Get-ExakitNoticeStillBehind "mcp:v2.4.0,exapump:v0.14.0") -join ",")
$same = ""
foreach ($pair in @(@("0.6.1", "v0.6.1"), @("v0.6.1", "0.6.1"), @("v0.6.1", "v0.6.1"), @("0.6.1", "0.6.2"), @("vNext", "Next"), @("0.6.1", ""))) {
    if (Test-ExakitVersionSame $pair[0] $pair[1]) { $same += "y" } else { $same += "n" }
}
Check "Test-ExakitVersionSame ignores a leading v before a digit, and nothing else" "yyynnn" $same

Write-Host "== the versions check: curl.exe first, Invoke-WebRequest when it is missing or fails =="
# Measured on a Windows 11 machine: one of raw.githubusercontent.com's addresses did not answer, .NET
# Framework (Invoke-WebRequest) tried it first in every process and waited out the ~21 s SYN retry, and
# the 5 s budget failed every `exakit update`, which then said "Everything is already current." from the
# manifest the kit shipped with. curl.exe on the same machine took 0.05 s. A stub stands in for curl.exe
# and a function for Invoke-WebRequest, so every branch runs without a network on both engines.
$commonAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo "setup/lib/exakit-common.ps1"), [ref]$tokens, [ref]$errors)
foreach ($fnName in @("Get-ExakitCurlExe", "Get-ExakitCurlFailureReason", "Invoke-ExakitCurlFetch", "Get-ExakitWebErrorReason",
                      "Get-ExakitVersionsCheckError", "Get-ExakitVersionsCheckFailedText", "Get-ExakitVersionsKnownText",
                      "Format-ExakitManifestDate", "Update-ExakitVersionsCache")) {
    $fnAst = $commonAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $fnName }, $true)
    Invoke-Expression $fnAst.Extent.Text
}
$vfWork = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-vfetch-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path (Join-Path $vfWork "cache") | Out-Null
$script:VersionsUrl = "https://raw.githubusercontent.com/example/starter-kit/main/versions.json"
$script:VersionsCachePath = Join-Path $vfWork "cache/versions.json"
$script:VersionsDocPath = ""; $script:VersionsSource = ""; $script:VersionsCheckError = ""
function Write-ExakitLog { param([string]$Level, [string]$Message) }
function Test-ExakitVersionsCacheFresh { return $false }
function Test-ExakitVersionsAttemptRecent { return $false }
function Get-ExakitVersionsAttemptStamp { return (Join-Path $vfWork "cache/.versions.json.attempt") }
function Get-ExakitVersionsUserAgent { return "exakit-update-check/0.0.0 (windows; AMD64)" }
function Test-ExakitVersionsDoc { param([string]$Path) if ((Get-Content -LiteralPath $Path -Raw) -match "GOOD") { return 0 } return 1 }
function Get-ExakitVersionsValue { param([string]$Path) if ($Path -eq "updated") { return "2026-07-29" } return "" }
# The curl.exe stand-in: logs its arguments, writes the -o file on success, prints what -w asks for, and
# exits with $env:EXAKIT_TEST_CURL_RC.
$curlStub = Join-Path $vfWork "curl-stub.ps1"
$curlLog = Join-Path $vfWork "curl.log"
Set-Content -LiteralPath $curlStub -Encoding ASCII -Value @'
$out = ""
for ($i = 0; $i -lt $args.Count; $i++) { if ("$($args[$i])" -eq "-o") { $out = "" + $args[$i + 1] } }
Add-Content -LiteralPath $env:EXAKIT_TEST_CURL_LOG -Value ($args -join " ")
$rc = [int]$env:EXAKIT_TEST_CURL_RC
if ($rc -eq 0) { Set-Content -LiteralPath $out -Value '{"GOOD": true}'; Write-Output "200"; exit 0 }
if ($rc -eq 22) { Write-Output "404"; exit 22 }
Write-Output "000"
exit $rc
'@
$env:EXAKIT_TEST_CURL_LOG = $curlLog
$script:iwrCalls = New-Object System.Collections.ArrayList
$script:iwrFail = $false
function Invoke-WebRequest { [CmdletBinding()] param([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing, [int]$TimeoutSec, [string]$UserAgent, [int]$MaximumRedirection = -1)
    [void]$script:iwrCalls.Add("timeout=$TimeoutSec")
    $script:iwrRedirects = $MaximumRedirection
    if ($script:iwrFail) { throw "The operation has timed out." }
    Set-Content -LiteralPath $OutFile -Value '{"GOOD": true}' }
function Reset-Fetch([string]$Curl, [int]$CurlRc, [bool]$IwrFail) {
    $script:ExakitCurlExe = $Curl
    $env:EXAKIT_TEST_CURL_RC = "$CurlRc"
    $script:iwrFail = $IwrFail
    $script:iwrCalls.Clear()
    Remove-Item -Force -LiteralPath $curlLog, $script:VersionsCachePath -ErrorAction SilentlyContinue
    $script:VersionsCheckError = "stale"
}
function Get-CurlArgs { if (Test-Path -LiteralPath $curlLog) { return (Get-Content -LiteralPath $curlLog -Raw).Trim() } return "" }

Reset-Fetch $curlStub 0 $false
$rc = Update-ExakitVersionsCache -Force
$curlArgs = Get-CurlArgs
Check "curl.exe present: the manifest is fetched with it" "0|0|True|" "$rc|$($script:iwrCalls.Count)|$(Test-Path -LiteralPath $script:VersionsCachePath)|$(Get-ExakitVersionsCheckError)"
Check "...HTTPS only, -fsSL, the shell twin's 5 s connect and 12 s overall budget" "True" `
    ($curlArgs -match '^-fsSL --proto =https --retry 1 --connect-timeout 5 --max-time 12 ')
Check "...with the kit's User-Agent, into the temporary file, not the cache" "True" `
    (($curlArgs -match '-A exakit-update-check/0\.0\.0 \(windows; AMD64\)') -and ($curlArgs -match [regex]::Escape("-o $($script:VersionsCachePath).tmp.")))

Reset-Fetch "none" 0 $false
$rc = Update-ExakitVersionsCache -Force
Check "curl.exe missing: Invoke-WebRequest fetches it, with a 25 s budget" "0|timeout=25|" "$rc|$($script:iwrCalls -join ',')|$(Get-CurlArgs)"

Reset-Fetch (Join-Path $vfWork "no-such-curl.exe") 0 $false
Check "a curl.exe that is not there is no curl.exe" "" "$(Get-ExakitCurlExe)"

Reset-Fetch $curlStub 28 $false
$rc = Update-ExakitVersionsCache -Force
Check "curl.exe fails: Invoke-WebRequest is tried next and its answer stands" "0|timeout=25|" "$rc|$($script:iwrCalls -join ',')|$(Get-ExakitVersionsCheckError)"

# SCR-02. curl.exe refuses a redirect to http:// (exit 1); the fallback that runs after it must not follow it.
Reset-Fetch $curlStub 1 $false
$script:iwrRedirects = -1
$rc = Update-ExakitVersionsCache -Force
Check "curl.exe refused (a redirect to http://): Invoke-WebRequest follows no redirect" "0" "$($script:iwrRedirects)"

Reset-Fetch $curlStub 7 $true
$rc = Update-ExakitVersionsCache -Force
Check "both fail: 1, curl's reason kept, the cache untouched" "1|could not connect to raw.githubusercontent.com|False" `
    "$rc|$(Get-ExakitVersionsCheckError)|$(Test-Path -LiteralPath $script:VersionsCachePath)"
Check "...and no temporary file is left behind" "0" "$(@(Get-ChildItem -LiteralPath (Join-Path $vfWork 'cache') -Filter 'versions.json.tmp.*').Count)"
Check "...and the sentence the screens print says so" `
    "Could not check for updates: could not connect to raw.githubusercontent.com. Check your internet connection or proxy. Showing the versions this kit already knows (updated July 29, 2026). Then run the same command again." `
    (Get-ExakitVersionsCheckFailedText)

Reset-Fetch "none" 0 $true
$rc = Update-ExakitVersionsCache -Force
Check "curl.exe missing and Invoke-WebRequest failing: its reason, one line" "1|The operation has timed out" "$rc|$(Get-ExakitVersionsCheckError)"

Reset-Fetch $curlStub 22 $true
$rc = Update-ExakitVersionsCache -Force
Check "an HTTP error names the status curl reported" "1|raw.githubusercontent.com answered HTTP 404" "$rc|$(Get-ExakitVersionsCheckError)"

Reset-Fetch $curlStub 28 $true
$rc = Update-ExakitVersionsCache -TimeoutSec 2
Check "a caller's smaller budget (the notice) caps both tools" "1|True|timeout=2" `
    "$rc|$((Get-CurlArgs) -match '--connect-timeout 2 --max-time 2 ')|$($script:iwrCalls -join ',')"

$script:VersionsUrl = "http://raw.githubusercontent.com/example/starter-kit/main/versions.json"
Reset-Fetch $curlStub 0 $false
$rc = Update-ExakitVersionsCache -Force
Check "a non-HTTPS URL is still refused before either tool runs" "1||0" "$rc|$(Get-CurlArgs)|$($script:iwrCalls.Count)"
$script:VersionsUrl = "https://raw.githubusercontent.com/example/starter-kit/main/versions.json"

Write-Host "== a check that could not reach the manifest never says everything is current =="
# The real Invoke-ExakitUpdateRun, Write-ExakitVersionsSourceLine and Write-ExakitUpdateJsonReport in a
# child process of the same engine (the run exits 1 on the screen path), with the fetch stood in.
$childScript = Join-Path $vfWork "update-check-child.ps1"
Set-Content -LiteralPath $childScript -Encoding ASCII -Value @'
param([string]$Repo, [string]$Mode, [string]$CheckError)
$ErrorActionPreference = "Stop"
# "none", not "": Windows PowerShell 5.1 drops an empty argument to a native command.
if ($CheckError -eq "none") { $CheckError = "" }
$t = $null; $e = $null
$cliAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo "setup/exakit.ps1"), [ref]$t, [ref]$e)
$libAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo "setup/lib/exakit-common.ps1"), [ref]$t, [ref]$e)
foreach ($pair in @(@($cliAst, "Invoke-ExakitUpdateRun"), @($cliAst, "Write-ExakitVersionsSourceLine"), @($cliAst, "Write-ExakitUpdateJsonReport"),
                    @($cliAst, "Get-ExakitUpdateFailureRemedy"), @($libAst, "Add-ExakitUpdateNote"), @($libAst, "Get-ExakitVersionsCheckError"),
                    @($libAst, "Get-ExakitVersionsCheckFailedText"), @($libAst, "Get-ExakitVersionsKnownText"), @($libAst, "Format-ExakitManifestDate"),
                    @($libAst, "Get-ExakitVersionPlain"), @($libAst, "Test-ExakitVersionSame"))) {
    $wanted = $pair[1]
    $node = $pair[0].Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $wanted }, $true)
    Invoke-Expression $node.Extent.Text
}
$script:VersionPolicy = "manifest"
$script:VersionsCheckError = ""
function Invoke-ExakitWithSpinner { param([string]$Label, [scriptblock]$Body) & $Body }
function Update-ExakitVersionsCache { param([switch]$Force) $script:VersionsCheckError = $CheckError; if ($CheckError) { return 1 } return 0 }
function Resolve-ExakitVersionsDoc { }
function Get-ExakitVersionsSource { if ($CheckError) { return "baked" } return "fetched" }
function Get-ExakitVersionsValue { param([string]$Path) if ($Path -eq "updated") { return "2026-07-29" } return "" }
function Test-ExakitVersionsSchemaAhead { return $false }
function Write-ExakitOverrideLine { }
function Write-ExakitPinnedLine { }
function Info([string]$Message) { Write-Host "info: $Message" }
function Ok([string]$Message) { Write-Host "ok: $Message" }
function Warn2([string]$Message) { Write-Host "warn: $Message" }
function Get-ExakitUpdateTargets { return @("exapump") }
function Get-ExakitActualTarget([string]$Name) { return $Name }
function Get-ExakitComponentCurrent([string]$Name) { return "1.0" }
function Get-ExakitComponentAvailable([string]$Name) { return "1.0" }
function Get-ExakitManifestValue([string]$Key) { return "" }
function Test-ExakitComponentManaged { return $true }
function Test-ExakitComponentSupported { return $true }
function Test-ExakitComponentAhead { return $false }
function Test-ExakitComponentHeavy { return $false }
function Test-ExakitAddonNeedsUpdate { return $false }
if ($Mode -eq "json" -or $Mode -eq "jsonfail") {
    $script:ExakitUpdateJson = $true
    $script:ExakitUpdateResults = New-Object System.Collections.ArrayList
    & { Invoke-ExakitUpdateRun -Target "all" } *> $null
    # jsonfail: a component's update failed in the same run (offline breaks downloads too).
    if ($Mode -eq "jsonfail") {
        [void]$script:ExakitUpdateResults.Add([pscustomobject]@{ component = "exapump"; outcome = "failed"; from = "1.0"; to = "9.9"
            remedy = "exakit update exapump"; error = "download failed"; hint = "" })
    }
    Write-ExakitUpdateJsonReport
    exit 0
}
$script:ExakitUpdateJson = $false
Invoke-ExakitUpdateRun -Target "all"
exit 0
'@
$engine = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
function Invoke-Child([string]$Mode, [string]$CheckError) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $engine -NoProfile -ExecutionPolicy Bypass -File $childScript -Repo $repo -Mode $Mode -CheckError $CheckError 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    return [pscustomobject]@{ Out = $out; Code = $code }
}
$failed = Invoke-Child "screen" "timed out reaching raw.githubusercontent.com"
Check "a failed check says it could not check, why, and which versions it showed" "True" `
    ($failed.Out -match [regex]::Escape("warn: Could not check for updates: timed out reaching raw.githubusercontent.com. Check your internet connection or proxy. Showing the versions this kit already knows (updated July 29, 2026). Then run the same command again."))
Check "...never that everything is current" "False" ($failed.Out -match "Everything is already current")
Check "...and exits 1" "1" "$($failed.Code)"
$reached = Invoke-Child "screen" "none"
Check "a check that reached the manifest still says everything is current, exit 0" "True|0" `
    "$($reached.Out -match 'ok: Everything is already current\.')|$($reached.Code)"
$failedJson = Invoke-Child "json" "timed out reaching raw.githubusercontent.com"
try { $doc = $failedJson.Out | ConvertFrom-Json } catch { $doc = $null }
Check "--json: a failed check is a failed run, exit 1" "False|failed|True|baked|1" `
    "$(if ($doc) { "$($doc.ok)|$($doc.status)|$($doc.check_failed)|$($doc.manifest_source)" } else { $failedJson.Out })|$($failedJson.Code)"
Check "...whose row carries the reason, the remedy and the versions shown" `
    "could not check for updates (network): timed out reaching raw.githubusercontent.com|exakit update|Check your internet connection or proxy. Showing the versions this kit already knows (updated July 29, 2026). Then run the same command again." `
    "$(if ($doc) { "$(@($doc.failed)[0].error)|$($doc.remedy)|$($doc.remedy_hint)" })"
$bothJson = Invoke-Child "jsonfail" "timed out reaching raw.githubusercontent.com"
try { $doc = $bothJson.Out | ConvertFrom-Json } catch { $doc = $null }
Check "--json: a failed check with a failed component still names the network failure first" `
    "failed|True|,exapump|could not check for updates (network): timed out reaching raw.githubusercontent.com|exakit update" `
    "$(if ($doc) { "$($doc.status)|$($doc.check_failed)|$((@($doc.failed) | ForEach-Object { $_.component }) -join ',')|$(@($doc.failed)[0].error)|$($doc.remedy)" } else { $bothJson.Out })"
$reachedJson = Invoke-Child "json" "none"
try { $doc = $reachedJson.Out | ConvertFrom-Json } catch { $doc = $null }
Check "--json: a check that reached the manifest is current, check_failed false, exit 0" "True|current|False|fetched|0" `
    "$(if ($doc) { "$($doc.ok)|$($doc.status)|$($doc.check_failed)|$($doc.manifest_source)" } else { $reachedJson.Out })|$($reachedJson.Code)"
Remove-Item -Recurse -Force -LiteralPath $vfWork -ErrorAction SilentlyContinue

Write-Host "== an add-on that needs an update at its version is updated =="
# The 0.2.5 -> 0.3.0 upgrade: JSON Tables at v0.4.1 with the launcher kit 0.2.5 wrote is installed and needs an
# update (its module's needs_update), so a plain `exakit update` updates it although the version matches; at its
# version without that it stays current. The real Test-ExakitAddonNeedsUpdate from exakit-common.ps1 asks the
# module's hook. Twin of the same section in tests/marketplace.sh.
$commonAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo "setup/lib/exakit-common.ps1"), [ref]$tokens, [ref]$errors)
$needs = $commonAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Test-ExakitAddonNeedsUpdate" }, $true)
Invoke-Expression $needs.Extent.Text
$script:stale = $true
function Get-ExakitComponentCurrent([string]$Name) { return "v0.4.1" }
function Get-ExakitComponentAvailable([string]$Name) { return "v0.4.1" }
function Get-ExakitMarketplaceAddon([string]$Id) {
    if ($Id -ne "json-tables") { return $null }
    return [pscustomobject]@{ UpdateFn = "Update-StandIn-json-tables"; NeedsUpdateFn = "NeedsUpdate-StandIn-json-tables" } }
function NeedsUpdate-StandIn-json-tables { return $script:stale }
function Update-StandIn-json-tables { [void]$script:log.Add("this-process:json-tables") }
Reset-Run
$script:ExakitUpdateJson = $true
Invoke-ExakitUpdateRun -Target "all" -Components @("json-tables")
Check "a stale json-tables is updated by a plain update" "True" ($script:log -contains "this-process:json-tables")
Check "...and listed as updated" "json-tables|updated|" (@($script:notes) -join ";")
Reset-Run
$script:stale = $false
Invoke-ExakitUpdateRun -Target "all" -Components @("json-tables")
Check "a current one is left alone" "False" ($script:log -contains "this-process:json-tables")
Check "...and listed as current" "json-tables|current|" (@($script:notes) -join ";")
Check "a component that is no add-on never needs one" "False" (Test-ExakitAddonNeedsUpdate "exapump")

Write-Host "== an add-on named explicitly runs its update step at the same version (its repair path) =="
# `exakit update json-tables` with json-tables current: the update step is also the add-on's repair command, so
# naming it runs it (Windows skipped it as current from 0.2.0 on, where bash always ran it). The --json row still
# says current, as bash's does. A named component that is no add-on, and a plain update, stay skipped. Twin of
# the "update repair path" section in tests/marketplace.sh.
Reset-Run
Invoke-ExakitUpdateRun -Target "json-tables"
Check "a named current add-on runs its update step" "True" ($script:log -contains "this-process:json-tables")
Check "...and its row says current, as bash's does" "json-tables|current|" (@($script:notes) -join ";")
Reset-Run
Invoke-ExakitUpdateRun -Target "exapump json-tables" -Components @("exapump", "json-tables")
Check "named beside another id it runs too; the named non-add-on stays current" "exapump|current|;json-tables|current|" (@($script:notes) -join ";")
Check "...and only the add-on's step ran" "this-process:json-tables" (@($script:log | Where-Object { $_ -like "this-process:*" }) -join "|")
Reset-Run
Invoke-ExakitUpdateRun -Target "all" -Components @("json-tables")
Check "a plain update still skips it" "False|json-tables|current|" "$($script:log -contains 'this-process:json-tables')|$(@($script:notes) -join ';')"
$script:ExakitUpdateJson = $false

Write-Host "== a 0.2.5 kit's Claude Code rules are replaced by this kit's, once (UGR-01) =="
# 0.2.5's own update ends in its skills install over this kit copy: it writes 0.2.5's list (the repairing
# mcp-doctor:* in all three spellings) and records this copy's skills version, so the next update reads the skills
# as current and never reached the merge. The update applies this kit's list when no rule record exists, which the
# apply then writes. Twin of the UGR-01 block in tests/agent-operability.sh (which runs the real merge).
$script:ManifestPath = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-ugr01-$([guid]::NewGuid().ToString('N')).json"
Set-Content -LiteralPath $script:ManifestPath -Value "{}"
$script:skillsRecord = $null
function Read-ExakitManifest { return [pscustomobject]@{ components = [pscustomobject]@{ skills = $script:skillsRecord } } }
function Write-ExakitReadonlyAllowlistReport { [void]$script:log.Add("allowlist-applied") }
function Get-ExakitComponentCurrent([string]$Name) { if ($Name -eq "exakit") { return $script:kit } return "1.0" }
function Get-ExakitComponentAvailable([string]$Name) { if ($Name -eq "exakit") { return "0.2.3" } return "1.0" }
function Allowlisted([string]$Target, $Components) {
    Reset-Run
    $script:handoverAnswer = $null     # no new command to hand over to: this process goes on, swapped
    Invoke-ExakitUpdateRun -Target $Target -Components $Components
    return ($script:log -contains "allowlist-applied")
}
$script:skillsRecord = [pscustomobject]@{ version = "1.0"; installed = @("exakit-lifecycle", "exasol-mcp") }
Check "skills placed by 0.2.5, no rule record: the update applies this kit's list" "True" (Allowlisted "all" @("json-tables"))
$script:skillsRecord = [pscustomobject]@{ version = "1.0"; installed = @("exakit-lifecycle"); claude_rules = @("Bash(exakit status:*)") }
Check "...once: with the record it does not (a rule the user took out stays out)" "False" (Allowlisted "all" @("json-tables"))
$script:skillsRecord = [pscustomobject]@{ version = "1.0"; installed = @() }
Check "...nor where no skill was ever placed" "False" (Allowlisted "all" @("json-tables"))
$script:skillsRecord = [pscustomobject]@{ version = "1.0"; installed = @("exakit-lifecycle") }
Check "...nor on an update of one named component" "False" (Allowlisted "json-tables" $null)
Check "...nor on the old code after the kit was swapped" "False" (Allowlisted "all" @("exakit", "json-tables"))
Remove-Item -LiteralPath $script:ManifestPath -Force -ErrorAction SilentlyContinue

Write-Host "update-targets-ps: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
