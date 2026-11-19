$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
# A kit home of its own: the add-ons table below reads component versions.
$env:EXAKIT_HOME = Join-Path ([IO.Path]::GetTempPath()) ("exakit-activity-" + [Guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $env:EXAKIT_HOME | Out-Null
$env:EXAKIT_ABOUT_OFFLINE = "1"
. (Join-Path $repo "setup/lib/exakit-common.ps1")
$realShowMenu = ${function:Show-ExakitMarketplaceMenu}
$realTableMenu = ${function:Invoke-ExakitTableMenu}
$script:UiFancy = $false
$script:ExakitAddonTable = New-ExakitTable -Title "Marketplace add-ons" -Col1 "Add-on"
$table = $script:ExakitAddonTable
$table.Cols = 80
$table.Activity = ""
[void](Add-ExakitTableRow -Kind "group" -Label "Select All" -Table $table)
[void](Add-ExakitTableRow -Kind "tee" -Label "json-tables" -Table $table)
[void](Add-ExakitTableRow -Kind "corner" -Label "dash-server" -Table $table)
$script:ExakitAddonTableRow = 2
Set-ExakitAddonProgress -Id "json-tables" -Pct 40 -Ceiling 65 -Secs 40 -Phase "installing"
$frame = Get-ExakitTableFrame -Table $table
$height = $table.Lines
Start-ExakitSpinner "Downloading the ingest engine"
Stop-ExakitSpinner
# By default the tables draw no activity line (ec6fd240); UI_TABLE_ACTIVITY=1 draws it.
$env:UI_TABLE_ACTIVITY = $null
$frame = Get-ExakitTableFrame -Table $table
if ($frame.Contains("Downloading the ingest engine")) { throw "activity drawn without UI_TABLE_ACTIVITY=1" }
$env:UI_TABLE_ACTIVITY = "1"
$frame = Get-ExakitTableFrame -Table $table
if (-not $frame.Contains("Downloading the ingest engine")) { throw "missing download activity" }
$lines = $frame -split "`r?`n"
$at = 0; while (-not $lines[$at].Contains("json-tables")) { $at++ }
if (-not $lines[$at - 1].Contains("Downloading the ingest engine")) { throw "phase is not directly above its bar" }
# The status cell starts with the row's step, then its bar: the activity sits above that cell's start.
if ($lines[$at - 1].IndexOf("Downloading") -ne $lines[$at].IndexOf("installing #")) { throw "activity is not aligned with the status cell" }
Set-ExakitAddonActivity -Message "Checking packages"
$frame = Get-ExakitTableFrame -Table $table
if (-not $frame.Contains("Checking packages") -or $frame.Contains("Downloading the Python")) { throw "stale activity" }
if ($table.Lines -ne ($height + 1) -or $table.Rows[1].Pct -ne 40) { throw "frame height or progress changed" }
Set-ExakitAddonActivity -Message ("x" * 120)
$frame = Get-ExakitTableFrame -Table $table
foreach ($line in ($frame -split "`r?`n")) { if ($line.Length -gt 80) { throw "activity wraps" } }
$script:ExakitAddonTableRow = 3
Set-ExakitAddonProgress -Id "dash-server" -Pct 40 -Ceiling 65 -Secs 40 -Phase "installing"
Set-ExakitAddonActivity -Message "Starting dashboard service"
$frame = Get-ExakitTableFrame -Table $table
$lines = $frame -split "`r?`n"
$at = 0; while (-not $lines[$at].Contains("dash-server")) { $at++ }
if (-not $lines[$at - 1].Contains("Starting dashboard service") -or $table.Lines -ne ($height + 2)) { throw "phase failed to follow active bar, one line per add-on" }
Write-Host "PASS no activity line by default; with UI_TABLE_ACTIVITY=1 the phase sits directly above the active bar, aligned, one line per add-on"

# THE ADD-ON OFFER'S SPINNER, handed to the table. The offer starts a spinner
# until its table is up; a nested Start taken on the way and never given back
# left Stop-ExakitSpinner only counting down, so the owner's last frame stayed
# frozen on its own line above the table (Windows re-test, a7ce624f and
# c3adec35). The stage that hands the line to the table now uses
# Stop-ExakitSpinnerAll: a real stop, line cleared, whatever is still out.
$script:UiFancy = $true
if (-not $script:UiEsc) { $script:UiEsc = [char]27 }
$prevOut = [Console]::Out
$sw = New-Object System.IO.StringWriter
[Console]::SetOut($sw)
try {
    Start-ExakitSpinner ""                      # the offer's (owner)
    Start-ExakitSpinner "Opening the add-ons"   # nested, never given back
    Start-Sleep -Milliseconds 300
    Stop-ExakitSpinner                          # what the stage used to do
    $leaked = ($null -ne $script:UiSpinFlag)
    Stop-ExakitSpinnerAll                       # what it does now
    $afterStop = $sw.ToString().Length
    Start-Sleep -Milliseconds 300
    $afterWait = $sw.ToString().Length
    $tail = $sw.ToString()
} finally {
    [Console]::SetOut($prevOut)
    $script:UiFancy = $false
}
if (-not $leaked) { throw "nesting theory: a single Stop after a nested Start should still leave the owner running" }
if ($null -ne $script:UiSpinFlag -or $script:UiSpinNested -ne 0) { throw "Stop-ExakitSpinnerAll left the spinner running or a reference out" }
if ($afterWait -ne $afterStop) { throw "frames written after Stop-ExakitSpinnerAll" }
if (-not $tail.EndsWith("`r$([char]27)[K$([char]27)[?25h")) { throw "the spinner's line was not cleared before the table" }
Write-Host "PASS a nested spinner reference no longer leaves the offer's frame above the add-ons table"

# NOBODY TO ASK (no console, an agent shell): the install's two are drawn in
# the same flat table as the interactive one - no Select All, Continue last -
# both ticked and installed. It drew the marketplace's tree with
# "[x] Select All" and "[ ] Skip". Twin of the check in tests/marketplace.sh.
function Test-ExakitMarketplaceAddonInstalled { param([string]$Id) return $false }
function Test-ExakitAddonSystemPresent { param([string]$Id) return $false }
function Test-ExakitMarketplaceAddonPresent { param([string]$Id) return $false }
$realApplyPython = ${function:Invoke-ExakitMarketplaceApplyPython}
function Invoke-ExakitMarketplaceApply { param([string[]]$Ids) Write-Host "APPLY $($Ids -join ',')" }
function Invoke-ExakitMarketplaceApplyPython { param([string[]]$Ids) Write-Host "APPLY $($Ids -join ',')" }
foreach ($a in Get-ExakitMarketplaceAddons) { if ($a.InstallFn) { Set-Item "function:global:$($a.InstallFn)" { } } }
$prevOut = [Console]::Out
$sw = New-Object System.IO.StringWriter
[Console]::SetOut($sw)
try { $autoSaid = (Install-ExakitAutoAddons -Ids @("dash-server", "json-tables") *>&1 | Out-String -Width 200) } finally { [Console]::SetOut($prevOut) }
$autoOut = $sw.ToString() + $autoSaid
if ($autoOut.Contains("Select All")) { throw "the no-console add-ons table drew Select All: $autoOut" }
if ($autoOut.Contains("Skip")) { throw "the no-console add-ons table ends on Skip, not Continue: $autoOut" }
if (-not $autoOut.Contains("Continue")) { throw "the no-console add-ons table has no Continue row: $autoOut" }
if (-not ($autoOut -match '\[x\] dash-server')) { throw "dash-server is not drawn ticked: $autoOut" }
if (-not $autoOut.Contains("APPLY dash-server,json-tables")) { throw "the two were not both installed: $autoOut" }
Write-Host "PASS no console: the install's two in the flat table, no Select All, Continue last, both ticked and installed"
Set-Item function:Invoke-ExakitMarketplaceApplyPython $realApplyPython

# THE INSTALL'S TABLE, ASKED (RAD-10): the two in before this run read
# "Installed <version>", not "Auto installed", and are drawn with no checkbox;
# the row under the cursor says what it is under the hint.
function Test-ExakitInteractive { return $true }
function Test-ExakitMenuConsole { return $true }
function Enable-ExakitMenuMouse { }
function Disable-ExakitMenuMouse { }
$script:MenuKeys = New-Object 'System.Collections.Generic.Queue[object]'
function Read-ExakitMenuKey {
    if ($script:MenuKeys.Count -eq 0) { throw "the menu asked for more keys than the test gave it" }
    return $script:MenuKeys.Dequeue()
}
function Test-ExakitMarketplaceAddonInstalled { param([string]$Id) return ($Id -eq "dash-server" -or $Id -eq "json-tables") }
function Get-ExakitComponentCurrent { param([string]$Id) return "0.2.1" }
$script:MenuKeys.Enqueue(@{ Name = 'Enter' })
$env:EXAKIT_MARKETPLACE_INSTALL_TABLE = "1"; $env:EXAKIT_MARKETPLACE_PRESELECT = "none"; $env:EXAKIT_MARKETPLACE_NO_TEXTUAL = "1"
$script:UiFancy = $true
$prevOut = [Console]::Out
$sw = New-Object System.IO.StringWriter
[Console]::SetOut($sw)
try { $askSaid = (& { try { Show-ExakitMarketplaceMenu } catch { "THREW $_" } } *>&1 | Out-String -Width 400) } finally {
    [Console]::SetOut($prevOut); $script:UiFancy = $false
    foreach ($name in @("EXAKIT_MARKETPLACE_INSTALL_TABLE", "EXAKIT_MARKETPLACE_PRESELECT", "EXAKIT_MARKETPLACE_NO_TEXTUAL")) { Remove-Item "env:$name" -ErrorAction SilentlyContinue }
}
$askOut = ($sw.ToString() + $askSaid) -replace "$([char]27)\[[0-9;?]*[A-Za-z]", ""
if ($askOut.Contains("THREW")) { throw "the install's table threw: $askOut" }
$dashLine = @($askOut -split "`r?`n" | Where-Object { $_.Contains("dash-server") -and $_.Contains("Installed") }) | Select-Object -First 1
if (-not $dashLine) { throw "dash-server's row does not say Installed: $askOut" }
if (-not $dashLine.Contains("Installed 0.2.1")) { throw "dash-server's row has no version: $dashLine" }
if ($dashLine.Contains("Auto installed")) { throw "a row in before this run says Auto installed: $dashLine" }
if ($dashLine -match '\[.\] ?dash-server') { throw "a row that is never a choice has a checkbox: $dashLine" }
if (-not $askOut.Contains("Data Build Tool")) { throw "no description of the row under the cursor: $askOut" }
Write-Host "PASS the install's table: the ones in already say Installed and their version, no checkbox, and the cursor row is described under the hint"

# A FAILED ADD-ON SAYS HOW TO RETRY (RAD-05): the line under the table names
# the reason, the command that retries it and the log; it said "did not
# finish: <reason>" and nothing else. Twin of the check in tests/marketplace.sh.
function Get-ExakitUvBin { return "Invoke-FakeUv" }
function Invoke-FakeUv { Write-Output '@@EXAKIT|json-tables|failed|fixture install failure.|0'; $global:LASTEXITCODE = 1 }
function Invoke-ExakitMarketplaceQuestions { param([string[]]$Ids) }
function Get-ExakitMarketplaceVersionsDoc { return "" }
$savedTable = $script:ExakitAddonTable
$script:ExakitAddonTable = $null
$script:LogFile = Join-Path $env:EXAKIT_HOME "install-test.log"
$prevOut = [Console]::Out
$sw = New-Object System.IO.StringWriter
[Console]::SetOut($sw)
try { $failSaid = (& { try { Invoke-ExakitMarketplaceApplyPython -Ids @("json-tables") } catch { "THREW $_" } } *>&1 | Out-String -Width 400) } finally { [Console]::SetOut($prevOut) }
$failOut = $sw.ToString() + $failSaid
$script:LogFile = $null
$script:ExakitAddonTable = $savedTable
$wantFail = "json-tables did not finish: fixture install failure. Retry: exakit marketplace json-tables. Log: " + (Join-Path $env:EXAKIT_HOME "install-test.log")
if (-not $failOut.Contains($wantFail)) { throw "the failed add-on's line does not name the retry and the log: $failOut" }
$psBody = Get-Content -Raw (Join-Path $repo "setup/lib/exakit-common.ps1")
if (-not $psBody.Contains("-Final 'did not finish - see below'")) { throw "the failed row does not point below the table" }
Write-Host "PASS a failed add-on's line names the reason, the retry command and the log; its row points below the table"

# THE INSTALL'S ADD-ONS TABLE DOES NOT WAIT. Windows has no early background
# install (macOS and Linux follow theirs: _exakit_addons_early_follow), so
# nothing stands between the heading and the one table: the offer hands it the
# two that are missing to install in it first, and an add-on not applicable
# here (json-tables on an older glibc, the shell's LNX-07) is not named.
function Test-ExakitInteractive { return $true }
function Test-ExakitSoftFailed { param([string]$Name) return $false }
function Test-ExakitAddonOfferable { param([string]$Id) return ($Id -ne "json-tables") }
function Test-ExakitMarketplaceAddonInstalled { param([string]$Id) return $false }
function Test-ExakitAddonSystemPresent { param([string]$Id) return $false }
function Test-ExakitMarketplaceHasPending { return $true }
function Get-ExakitMarketplaceAddons { return @([pscustomobject]@{ Id = "dash-server" }, [pscustomobject]@{ Id = "json-tables" }) }
function Get-ExakitMarketplaceCatalogAbout { param([string[]]$Ids) return @() }
function Write-ExakitHeading([string]$Msg) { }
$script:offerSeen = @()
function Show-ExakitMarketplaceMenu { $script:offerSeen += "FIRST=[$env:EXAKIT_MARKETPLACE_AUTO_FIRST] TABLE=[$env:EXAKIT_MARKETPLACE_INSTALL_TABLE]" }
Request-ExakitMarketplaceOffer | Out-Null
if (($script:offerSeen -join ';') -ne "FIRST=[dash-server] TABLE=[1]") { throw "the offer did not go straight to its table with the missing one: $($script:offerSeen -join ';')" }
if ($env:EXAKIT_MARKETPLACE_AUTO_FIRST) { throw "the offer left EXAKIT_MARKETPLACE_AUTO_FIRST set" }
Write-Host "PASS the Windows offer goes straight to its table, the missing auto add-ons installing in it first (no early run to wait for)"

# OUTSIDE THE INSTALL NOTHING IS PRE-TICKED (a real Windows run opened
# `exakit marketplace` as "[x] Select All / [x] dbt-exasol / [x] exasol-vscode",
# so a bare Enter installed them all). The table now starts with no add-on
# ticked and Skip as the answer to Enter; "all" still ticks every one.
# Twin of the check in tests/marketplace.sh.
Set-Item function:Show-ExakitMarketplaceMenu $realShowMenu
function Test-ExakitAddonOfferable { param([string]$Id) return $true }
function Test-ExakitMarketplaceAddonInstalled { param([string]$Id) return $false }
function Get-ExakitMarketplaceAddons { return @(
    [pscustomobject]@{ Id = "demo-alpha"; InstallFn = "Get-Date"; VersionFn = ""; DefaultVersion = "1.0" },
    [pscustomobject]@{ Id = "demo-beta"; InstallFn = "Get-Date"; VersionFn = ""; DefaultVersion = "1.0" }) }
function Get-ExakitAddonAdvertisedVersion { param([string]$Id, [string]$Fallback) return "1.0" }
function Get-ExakitMarketplaceAddonDescription { param([string]$Id) return "about $Id" }
function Get-ExakitMarketplaceAddonLabel { param([string]$Id) return $Id }
function Start-ExakitSpinner { param([string]$Label) $script:spinSeen += $Label }
function Stop-ExakitSpinnerAll { }
$script:seenDefaults = $null
function Invoke-ExakitTableMenu { param([hashtable]$Table, [int[]]$Defaults, [int]$ExclusiveIndex, [string[]]$Groups, [int]$GroupParent, [int]$GroupFirst, [int]$GroupLast, [string]$GroupMode, [int]$OnScreen)
    $script:seenDefaults = ($Defaults -join ','); $script:seenSkip = $ExclusiveIndex; $script:ExakitTableConfirmed = $true; return @($ExclusiveIndex) }
foreach ($preset in @("", "all")) {
    $script:spinSeen = @()
    if ($preset) { $env:EXAKIT_MARKETPLACE_PRESELECT = $preset } else { Remove-Item env:EXAKIT_MARKETPLACE_PRESELECT -ErrorAction SilentlyContinue }
    $env:EXAKIT_MARKETPLACE_NO_TEXTUAL = "1"
    $said = (& { Show-ExakitMarketplaceMenu } *>&1 | Out-String -Width 400)
    Remove-Item env:EXAKIT_MARKETPLACE_PRESELECT, env:EXAKIT_MARKETPLACE_NO_TEXTUAL -ErrorAction SilentlyContinue
    if ($preset -eq "") {
        if ($script:seenDefaults -ne "$($script:seenSkip)") { throw "a bare marketplace pre-ticked rows: defaults [$($script:seenDefaults)], Skip is row $($script:seenSkip)" }
        if (-not $said.Contains("Marketplace closed")) { throw "Enter on the default did not close without installing: $said" }
        if (($script:spinSeen -join ';') -ne "Reading the add-ons") { throw "a bare marketplace did not say what it reads from the first moment: $($script:spinSeen -join ';')" }
    } elseif ($script:seenDefaults -ne "1,2,3") { throw "EXAKIT_MARKETPLACE_PRESELECT=all did not tick every add-on: [$($script:seenDefaults)]" }
}
Write-Host "PASS outside the install nothing is pre-ticked (Skip answers Enter), all still ticks every add-on, and a spinner says what is read from the first moment"

# THE COVERED LIST LINES UP: names, states and versions in columns as wide as
# the longest ("exasol-scheduler" overflowed a fixed 14). Twin of the shell's.
function Test-ExakitMarketplaceAddonInstalled { param([string]$Id) return $true }
function Get-ExakitComponentCurrent { param([string]$Id) if ($Id -eq "exasol-scheduler") { return "0.4.1" } return "0.2.1" }
function Get-ExakitMarketplaceAddons { return @(
    [pscustomobject]@{ Id = "dbt"; InstallFn = "Get-Date"; VersionFn = "" },
    [pscustomobject]@{ Id = "exasol-scheduler"; InstallFn = "Get-Date"; VersionFn = "" }) }
$script:infoLines = @()
function Info { param([string]$Msg) $script:infoLines += $Msg }
Show-ExakitMarketplaceMenu | Out-Null
$rowsSaid = @($script:infoLines | Where-Object { $_ -match 'Installed' })
if ($rowsSaid.Count -ne 2) { throw "the covered list did not list both: $($script:infoLines -join ' | ')" }
$cols = @($rowsSaid | ForEach-Object { $_.IndexOf("Installed") } | Sort-Object -Unique)
$vers = @($rowsSaid | ForEach-Object { $_.IndexOf("0.") } | Sort-Object -Unique)
if ($cols.Count -ne 1 -or $vers.Count -ne 1) { throw "the covered list is out of line: $($rowsSaid -join ' | ')" }
Write-Host "PASS the covered list lines up its names, states and versions for the longest name"

# THE INSTALL'S TABLE ASKS WHILE ITS OWN TWO INSTALL (a Windows 11 run: the two
# installed first under "[ ]" with live bars, the table took no key for about
# 45 s, and after Enter the two showed "[ ]" again). Now they install behind
# the table, drawn checked and locked from the start; a row is ticked while
# they still install, and after Enter they stay checked. Twin of the pty check
# in tests/marketplace.sh.
Set-Item function:Invoke-ExakitTableMenu $realTableMenu
function Info { param([string]$Msg) }
function Test-ExakitMarketplaceAddonInstalled { param([string]$Id) return $false }
function Get-ExakitMarketplaceAddons { return @(
    [pscustomobject]@{ Id = "dash-server"; InstallFn = "Get-Date"; VersionFn = ""; DefaultVersion = "0.2.1" },
    [pscustomobject]@{ Id = "json-tables"; InstallFn = "Get-Date"; VersionFn = ""; DefaultVersion = "0.4.1" },
    [pscustomobject]@{ Id = "demo-gamma"; InstallFn = "Get-Date"; VersionFn = ""; DefaultVersion = "1.0" }) }
function Get-ExakitMarketplaceAddonName { param([string]$Id) return $Id }
$psExe = (Get-Process -Id $PID).Path
function Start-ExakitMarketplaceApplyProcess { param([string]$Uv, [string]$Runner, [string[]]$Ids)
    $script:behindIds = ($Ids -join ',')
    # A stand-in that starts fast: Windows PowerShell there, sh elsewhere (a
    # pwsh child under a fresh HOME takes most of a minute to start).
    if ($PSVersionTable.PSVersion.Major -le 5 -or $IsWindows) {
        $cmd = "'@@EXAKIT|dash-server|installing||0'; '@@EXAKIT|json-tables|installing||0'; Start-Sleep -Seconds 3; " +
            "'@@EXAKIT|dash-server|done|ok|3'; '@@EXAKIT|json-tables|done|ok|3'"
        return (Start-ExakitLineProcess -File $psExe -Arguments @('-NoProfile', '-NonInteractive', '-Command', $cmd))
    }
    $cmd = "echo '@@EXAKIT|dash-server|installing||0'; echo '@@EXAKIT|json-tables|installing||0'; sleep 3; " +
        "echo '@@EXAKIT|dash-server|done|ok|3'; echo '@@EXAKIT|json-tables|done|ok|3'"
    return (Start-ExakitLineProcess -File '/bin/sh' -Arguments @('-c', $cmd)) }
$script:applied = @()
function Invoke-ExakitMarketplaceApply { param([string[]]$Ids) $script:applied += ($Ids -join ',') }
$script:waits = 0
function Wait-ExakitMenuKey { param([int]$Milliseconds)
    $script:waits++
    if ($script:waits -gt 2400) { return $true }
    if ($script:ExakitAddonTable.Rows[0].State -ne 'running') { Start-Sleep -Milliseconds 25; return $false }
    return $true }
$script:MenuKeys = New-Object 'System.Collections.Generic.Queue[object]'
$script:MenuKeys.Enqueue(@{ Name = 'Space' }); $script:MenuKeys.Enqueue(@{ Name = 'Enter' })
$script:stateAtKey = @()
function Read-ExakitMenuKey {
    if ($script:MenuKeys.Count -eq 0) { throw "the menu asked for more keys than the test gave it" }
    $script:stateAtKey += $script:ExakitAddonTable.Rows[0].State
    return $script:MenuKeys.Dequeue()
}
$env:EXAKIT_MARKETPLACE_INSTALL_TABLE = "1"; $env:EXAKIT_MARKETPLACE_PRESELECT = "none"; $env:EXAKIT_MARKETPLACE_NO_TEXTUAL = "1"
$env:EXAKIT_MARKETPLACE_AUTO_FIRST = "dash-server,json-tables"
$script:UiFancy = $true
$prevOut = [Console]::Out
$sw = New-Object System.IO.StringWriter
[Console]::SetOut($sw)
try { $bhSaid = (& { try { Show-ExakitMarketplaceMenu } catch { "THREW $_" } } *>&1 | Out-String -Width 400) } finally {
    [Console]::SetOut($prevOut); $script:UiFancy = $false
    foreach ($name in @("EXAKIT_MARKETPLACE_INSTALL_TABLE", "EXAKIT_MARKETPLACE_PRESELECT", "EXAKIT_MARKETPLACE_NO_TEXTUAL", "EXAKIT_MARKETPLACE_AUTO_FIRST")) { Remove-Item "env:$name" -ErrorAction SilentlyContinue }
}
$bhOut = ($sw.ToString() + $bhSaid) -replace "$([char]27)\[[0-9;?]*[A-Za-z]", ""
if ($bhOut.Contains("THREW")) { throw "the install's table threw: $bhOut" }
if ($script:behindIds -ne "dash-server,json-tables") { throw "the two did not install behind the table: [$($script:behindIds)]" }
if ($script:stateAtKey.Count -lt 1 -or $script:stateAtKey[0] -ne 'running') { throw "the table did not ask while the two installed: $($script:stateAtKey -join ',')" }
if (($script:applied -join ';') -ne "demo-gamma") { throw "the row ticked meanwhile was not installed after them: $($script:applied -join ';')" }
$frames = @($bhOut -split "`r?`n")
$lastDash = @($frames | Where-Object { $_ -match 'dash-server' }) | Select-Object -Last 1
$lastJson = @($frames | Where-Object { $_ -match 'json-tables' }) | Select-Object -Last 1
foreach ($row in @($lastDash, $lastJson)) {
    if ($row -notmatch '\[.\] ?(dash-server|json-tables)' -or $row -match '\[ \]') { throw "an auto row is not checked after Enter: $row" }
    if (-not $row.Contains("Auto installed")) { throw "an auto row does not end Auto installed: $row" }
}
$firstDash = @($frames | Where-Object { $_ -match 'dash-server' }) | Select-Object -First 1
if ($firstDash -notmatch '\[.\] ?dash-server') { throw "dash-server is not drawn checked from the start: $firstDash" }
Write-Host "PASS the install's table asks while its own two install behind it, checked and locked from the start and after Enter"
Remove-Item -Recurse -Force $env:EXAKIT_HOME -ErrorAction SilentlyContinue
