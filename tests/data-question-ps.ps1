#!/usr/bin/env pwsh
# data-question-ps.ps1 - the Windows twin of tests/data-question.sh: the data
# question is ONE "Data to load" table (the "Sample datasets" parent with the
# pending datasets under it, your own file or folder, an external source -
# pickable where virtual schemas can run, else disabled with the reason - and
# Skip), with every sample loaded the parent is a disabled row and your
# own file the default, a persona's datasets are the rows ticked and one that
# wants no samples or only loaded ones makes Skip the default, Skip answers none
# and the file row with the samples answers "<ids>,local", who each dataset is
# for is a "For" column, `exakit data-load` takes -Force and a dataset in either
# order, a scripted add-on that does not run here is skipped rather than
# ending the answer, and the external row runs `exakit connect` (the real
# wizard entry point, a stub command) after the file, in both entry points,
# never stopping the load and never started without a person at the table.
# Runs under Windows PowerShell 5.1 and pwsh; a sandboxed kit home, nothing
# installed or loaded.
#
#   pwsh -NoProfile -File tests/data-question-ps.ps1
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-dq-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:EXAKIT_HOME = Join-Path $work "home"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
foreach ($v in "EXAKIT_PERSONA", "EXAKIT_DATASETS", "EXAKIT_DATA_FILE", "EXAKIT_DATASETS_PRESELECT",
               "EXAKIT_LOAD_SAMPLE", "EXAKIT_MARKETPLACE_ADDONS", "EXAKIT_MARKETPLACE_ONLY", "EXAKIT_MARKETPLACE_PRESELECT") {
    Remove-Item "Env:$v" -ErrorAction SilentlyContinue
}
. (Join-Path $repo "setup/lib/exakit-common.ps1")
. (Join-Path $repo "setup/lib/exapump.ps1")
. (Join-Path $repo "setup/lib/persona.ps1")
foreach ($m in "dash-server", "json-tables", "notebook", "udf-devkit", "exasol-scheduler", "exasol-vscode", "dbt-exasol") {
    $p = Join-Path $repo "setup/lib/$m.ps1"
    if (Test-Path $p) { . $p }
}
Initialize-ExakitMarketplacePythonHooks
$script:LogFile = $null
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$expected>, got <$actual>" }
}
# The kit wraps a long line at the console's width (the Windows runner's is narrow), so a
# phrase is looked for with its whitespace, line breaks included, collapsed to one space.
function Flat($text) { return (("" + $text) -replace '\s+', ' ') }
function Has($label, $needle, $haystack) {
    if ((Flat $haystack).Contains((Flat $needle))) { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected '$needle' in <$haystack>" }
}
function Lacks($label, $needle, $haystack) {
    if (-not ("" + $haystack).Contains("" + $needle)) { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): did not expect '$needle' in <$haystack>" }
}
function Fail([string]$Msg) { throw "FAIL: $Msg" }
function Deny-ExakitInput([string]$Message, $Remedy = $null) { throw "REJECT: $Message" }
function Set-Pending([string[]]$Ids) {
    $script:PendingIds = @($Ids)
}
function Get-ExakitPendingDatasets {
    return @($script:PendingIds | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Id = $_; Label = "$_ label (~1k rows)"; Description = "$_ about" } })
}
# The data question is ONE table: no checkbox menu is asked before it.
function Read-ExakitCheckboxMenu {
    param([string]$Title, [string[]]$Options, [int[]]$Defaults = @(), [int]$ExclusiveIndex = 0)
    $script:CheckboxAsked = $Title
    return @()
}
# The table menu, as Select-ExakitDataLoad asks it: records what it was asked
# with and answers $script:Answer (the defaults when that is $null).
function Invoke-ExakitTableMenu {
    param($Table = $null, [int[]]$Defaults = @(), [int]$ExclusiveIndex = 0, [int]$GroupParent = 0,
          [int]$GroupFirst = 0, [int]$GroupLast = 0, [string]$GroupMode = "any", [int]$OnScreen = 0)
    $script:MenuAsked = "$($Defaults -join ',')~$ExclusiveIndex~$GroupParent~$GroupFirst~$GroupLast~$GroupMode"
    $script:Col2AtMenu = "" + $script:UiTable.Col2
    # A person pressed Enter ($script:MenuConfirmed), or nobody was at the table.
    $script:ExakitTableConfirmed = [bool]$script:MenuConfirmed
    if ($null -eq $script:Answer) { return @($Defaults) }
    return @($script:Answer)
}
function Rows {
    $parts = @($script:UiTable.Rows | ForEach-Object { "$($_.Kind)|$($_.Label)|$($_.State)" })
    return "$($parts -join ';')~$($script:ExakitTableIds -join ',')"
}
function Table([string[]]$Pending) {
    Set-Pending $Pending
    New-ExakitDataTable -FinalLabel "Skip"
    return "$($script:ExakitTableDefaults -join ',')~$($script:ExakitTableRowLocal)~$($script:ExakitTableRowSkip)"
}
function Answer([string[]]$Pending, $Rows) {
    Set-Pending $Pending
    $script:Answer = $Rows
    $script:CheckboxAsked = ""
    $said = (@(Select-ExakitDataLoad -FinalLabel "Skip" 6>$null) -join ",")
    $script:Answer = $null
    return $said
}

try {
    Initialize-ExakitManifest | Out-Null

    Write-Host "the table's rows:"
    [void](Table @("tpch", "energy"))
    Check "parent, datasets, your file, external (disabled), Skip" `
        "group|Sample datasets|idle;tee|tpch label|idle;corner|energy label|idle;plain|Upload a file or folder: CSV/Parquet/JSON|idle;plain|Connect an external source - unavailable|disabled;plain|Skip|idle~,tpch,energy,local,," `
        (Rows)
    Check "the parent spans the datasets" "2~3" "$($script:ExakitTableGroupFirst)~$($script:ExakitTableGroupLast)"
    Check "a dataset and the file row know their rows" "3~4" "$(Get-ExakitDataTableRow -Id 'energy')~$(Get-ExakitDataTableRow -Id 'local')"
    [void](Table @())
    Check "every sample loaded: the parent is a disabled row that says so" `
        "plain|Sample datasets - all of them are loaded already|disabled;plain|Upload a file or folder: CSV/Parquet/JSON|idle;plain|Connect an external source - unavailable|disabled;plain|Skip|idle~,local,," `
        (Rows)
    Check "...and no group" "0~0" "$($script:ExakitTableGroupFirst)~$($script:ExakitTableGroupLast)"
    Check "one screen: no separate source question" "False" "$($null -ne (Get-Command Select-ExakitDataSource -ErrorAction SilentlyContinue))"

    Write-Host "the defaults: Skip when nothing on offer is wanted:"
    Check "no persona: the parent and every pending row ticked" "1,2,3~4~6" (Table @("tpch", "energy"))
    $env:EXAKIT_DATASETS_PRESELECT = "energy"
    Check "persona's dataset pending: that row only" "3~4~6" (Table @("tpch", "energy"))
    $env:EXAKIT_DATASETS_PRESELECT = "tpch,energy"
    Check "persona's datasets are every one: the parent too" "1,2,3~4~6" (Table @("tpch", "energy"))
    $env:EXAKIT_DATASETS_PRESELECT = "amazon_sales"
    Check "persona's datasets loaded already: Skip" "6~4~6" (Table @("tpch", "energy"))
    $env:EXAKIT_DATASETS_PRESELECT = "none"
    Check "persona datasets none: Skip" "6~4~6" (Table @("tpch", "energy"))
    $env:EXAKIT_DATASETS_PRESELECT = "ENERGY"
    Check "case-sensitive, like the shell side" "6~4~6" (Table @("tpch", "energy"))
    $env:EXAKIT_DATASETS_PRESELECT = "tpch"
    # With every sample in, the file row is the only thing the screen can still
    # do, whoever the persona is. Twin of tests/data-question.sh.
    Check "nothing pending, a persona: Skip (nothing it asked for is left)" "4~2~4" (Table @())
    Remove-Item Env:EXAKIT_DATASETS_PRESELECT
    Check "nothing pending: your own file, never Skip" "2~2~4" (Table @())
    Set-Pending @(); New-ExakitDataTable -FinalLabel "Skip" -NoLocal
    Check "nothing pending and no file row: Skip, never row 0" "2~0~2" "$($script:ExakitTableDefaults -join ',')~$($script:ExakitTableRowLocal)~$($script:ExakitTableRowSkip)"

    Write-Host "one table answers the data question:"
    $script:Answer = $null
    Check "the defaults: every pending dataset" "tpch,energy" (Answer @("tpch", "energy") $null)
    Check "...asked once, with Skip exclusive and the parent spanning the datasets" "1,2,3~6~1~2~3~all" $script:MenuAsked
    Check "...and no checkbox question before it" "" $script:CheckboxAsked
    Check "Skip answers none" "none" (Answer @("tpch", "energy") @(6))
    Check "Skip wins over anything ticked with it" "none" (Answer @("tpch", "energy") @(2, 6))
    Check "the file row picked with the samples: <ids>,local" "tpch,energy,local" (Answer @("tpch", "energy") @(1, 2, 3, 4))
    Check "the file row alone" "local" (Answer @("tpch", "energy") @(4))
    Check "the disabled external row never answers anything" "none" (Answer @("tpch", "energy") @(5))
    Check "nothing picked is none" "none" (Answer @("tpch", "energy") @())
    # Every sample in: the file row is the default, but only a person can answer
    # the path question it leads to. Nobody at the table answers none (and says
    # how to name a file unattended); Enter pressed on it answers the file row.
    Check "every sample loaded, nobody at the table: none" "none" (Answer @() $null)
    Check "...asked with no parent and Skip as row 4" "2~4~0~0~0~all" $script:MenuAsked
    $script:MenuConfirmed = $true
    Check "every sample loaded, Enter pressed: your own file is the default answer" "local" (Answer @() $null)
    $script:MenuConfirmed = $false
    $env:EXAKIT_DATASETS_PRESELECT = "none"
    Check "persona datasets none: the default answer is none" "none" (Answer @("tpch", "energy") $null)
    $env:EXAKIT_DATASETS_PRESELECT = "energy"
    Check "persona's datasets: the default answer is theirs" "energy" (Answer @("tpch", "energy") $null)
    Remove-Item Env:EXAKIT_DATASETS_PRESELECT
    $env:EXAKIT_DATA_FILE = $work
    $script:MenuAsked = ""
    Check "EXAKIT_DATA_FILE bypasses the table" "local~~" "$(Answer @('tpch') $null)~$($script:MenuAsked)~$($script:ExakitTableIds -join ',')"
    Remove-Item Env:EXAKIT_DATA_FILE

    Write-Host "what each dataset is goes in a column, not on the name:"
    Set-Pending @("tpch", "amazon_sales")
    New-ExakitDataTable -FinalLabel "Skip"
    Check "the names stay names" "Sample datasets;tpch label;amazon_sales label;Upload a file or folder: CSV/Parquet/JSON;Connect an external source - unavailable;Skip" ((@($script:UiTable.Rows | ForEach-Object { $_.Label })) -join ";")
    Check "the descriptions go in column 2" ";tpch about;amazon_sales about;;;" ((@($script:UiTable.Rows | ForEach-Object { $_.Col2 })) -join ";")
    Check "the table knows it has them" "True" "$($script:ExakitTableHasDesc)"
    $chosen = @(Select-ExakitDataLoad -FinalLabel "Skip")
    Check "the Description column is up while the reader picks" "Description" $script:Col2AtMenu
    Check "...and gone again before the progress display" "" ("" + $script:UiTable.Col2)
    Check "the picked rows still answer" "tpch,amazon_sales" ($chosen -join ",")

    Write-Host "Enter on the exclusive row answers it alone:"
    # The keypress loop needs a console; the rule is pinned by its text, and
    # behaviourally on the shell twin (tests/data-question.sh, a real pty).
    $cbText = (Get-Content -Raw (Join-Path $repo "setup/lib/exakit-common.ps1"))
    Has "Read-ExakitCheckboxMenu: Enter on the exclusive row clears the rest" `
        'if ($ExclusiveIndex -ge 1 -and $script:cbCur -eq $ExclusiveIndex) { $sel.Clear(); [void]$sel.Add($ExclusiveIndex) }' $cbText
    # The data question is a table: its Enter on Skip, and its cursor stepping
    # over the disabled rows (the external source, the parent once every sample
    # is in).
    $tmText = (Get-Content -Raw (Join-Path $repo "setup/lib/ui.ps1"))
    Has "Invoke-ExakitTableMenu: Enter on Skip answers Skip alone" `
        'if ($ExclusiveIndex -ge 1 -and $cur -eq $ExclusiveIndex) { $sel.Clear(); [void]$sel.Add($ExclusiveIndex) }' $tmText
    Has "...a disabled row is not pickable" 'if ($Table.Rows[$i - 1].State -ne "disabled") { [void]$pickable.Add($i) }' $tmText
    Has "...and the cursor starts on a pickable row" 'if (-not $pickable.Contains($cur)) { $cur = [int](& $step $cur 1) }' $tmText

    Write-Host "exakit data-load [-Force] [<file-or-folder>|<dataset>]:"
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo "setup/exakit.ps1"), [ref]$null, [ref]$null)
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Invoke-CmdDataLoad" }, $true)
    Check "Invoke-CmdDataLoad is found in setup/exakit.ps1" "True" "$($null -ne $fn)"
    . ([scriptblock]::Create($fn.Extent.Text))
    Has "the dispatcher passes every argument" '"data-load"    { Invoke-CmdDataLoad -Arguments @($RestArgs) }' `
        (Get-Content -Raw (Join-Path $repo "setup/exakit.ps1"))
    function Assert-ExakitInstalled { }
    function Initialize-ExakitLogging { }
    function Confirm-ExakitRuntimeRunning { param([switch]$Deploy) }
    function Get-ExakitRepoRoot { return $repo }
    function Stop-ExakitBadOption([string]$Msg) { throw "REJECT: $Msg" }
    function Invoke-ExakitDatasetLoad { param($KitRoot, $Id, [switch]$Force) $script:Did += "LOAD $Id $([bool]$Force)" }
    function Invoke-ExakitSampleDataLoad { param($KitRoot, [switch]$Force) $script:Did += "LOAD tpch(sample) $([bool]$Force)" }
    function Show-ExakitDataLoadMenu { $script:Did += "MENU $($env:EXAKIT_DATA_FILE)" }
    function DataLoad([string[]]$Pending, [string[]]$Arguments) {
        Set-Pending $Pending
        $script:Did = @()
        $said = ""
        try { $said = (& { Invoke-CmdDataLoad -Arguments $Arguments } 6>&1 | Out-String) } catch { $said = "$_" }
        Remove-Item Env:EXAKIT_DATASETS, Env:EXAKIT_DATA_FILE -ErrorAction SilentlyContinue
        return "$($script:Did -join ';')|$said"
    }
    Has "-Force <dataset> reloads exactly that dataset" "LOAD amazon_sales True|" (DataLoad @("tpch") @("--force", "amazon_sales"))
    Has "<dataset> -Force, the other order, too" "LOAD amazon_sales True|" (DataLoad @("tpch") @("amazon_sales", "-Force"))
    Has "bare -Force still reloads the bundled sample" "LOAD tpch(sample) True|" (DataLoad @("tpch") @("-Force"))
    $env:EXAKIT_DATA_FILE = $work
    Has "a dataset id wins over EXAKIT_DATA_FILE in the environment" "LOAD amazon_sales False|" (DataLoad @("amazon_sales") @("amazon_sales"))
    $env:EXAKIT_DATASETS = "tpch"
    Has "...and over EXAKIT_DATASETS" "LOAD energy False|" (DataLoad @("tpch", "energy") @("energy"))
    Has "an id already loaded names the reload command for it" "exakit data-load --force amazon_sales" (DataLoad @("tpch") @("amazon_sales"))
    Has "two targets are refused" "REJECT: data-load takes one file, folder or dataset at a time" (DataLoad @("tpch") @("tpch", "energy"))
    Has "-Force with a file is refused, with the file's own answer" "EXAKIT_ON_EXISTING" (DataLoad @("tpch") @("-Force", $work))
    Has "an unknown option is refused" "REJECT: Unknown option '--nope'" (DataLoad @("tpch") @("--nope"))
    Has "a dataset id is matched case-sensitively" "No such file, folder or dataset: TPCH" (DataLoad @("tpch") @("TPCH"))
    Has "the one-argument form still works" "LOAD amazon_sales True|" ($(Set-Pending @("tpch"); $script:Did = @(); Invoke-CmdDataLoad -Argument "--force" -Arguments @("amazon_sales") 6>$null; "$($script:Did -join ';')|"))
    $env:EXAKIT_DATASETS = "tpch,external"
    $out = DataLoad @("tpch") @()
    Has "EXAKIT_DATASETS names the external row: the dataset loads" "LOAD tpch False|" $out
    Has "...and the external row is only the command to run" "needs a terminal. Connect one any time with: exakit connect" $out
    Lacks "...it is not an unknown id" "Unknown dataset id 'external'" $out
    $env:EXAKIT_DATASETS = "external"
    $out = DataLoad @("tpch") @()
    Lacks "external alone is an answer, not 'matched no bundled dataset'" "matched no bundled dataset" $out
    Lacks "...and loads nothing" "LOAD" $out

    Write-Host "a scripted add-on that does not run here is skipped, the rest install:"
    function Get-ExakitMarketplaceAddonDescription { return "desc" }
    function Test-ExakitMarketplaceAddonInstalled { param([string]$Id) return $false }
    function Test-ExakitAddonSystemPresent { param([string]$Id) return $false }
    function Test-ExakitMarketplaceAddonPresent { param([string]$Id) return $false }
    function Test-ExakitAddonApplicable { param([string]$Id) return ($Id -ne "dash-server") }
    function Get-ExakitAddonApplicableReason { param([string]$Id) return "not on this platform (test)" }
    function Invoke-ExakitMarketplaceApply { param([string[]]$Ids) $script:Installed = $Ids -join "," }
    function Market([string]$Answer) {
        $script:Installed = ""
        $env:EXAKIT_MARKETPLACE_ADDONS = $Answer
        $said = ""
        try { $said = (& { Show-ExakitMarketplaceMenu } 6>&1 | Out-String) } catch { $said = "THREW $_" }
        Remove-Item Env:EXAKIT_MARKETPLACE_ADDONS -ErrorAction SilentlyContinue
        return "$($script:Installed)|$said"
    }
    $out = Market "dash-server,json-tables"
    Has "the rest are installed" "json-tables|" $out
    Lacks "the inapplicable one is not" "dash-server|" $out
    Has "it is named, with the reason" "Skipping dash-server - it is not available on this machine: not on this platform (test)" $out
    Lacks "and the answer does not stop" "THREW" $out
    $out = Market "dash-server"
    Has "nothing applicable: it says so, not 'already present'" "Nothing to install on this machine" $out
    Lacks "...and it is not an error" "THREW" $out
    Has "an unknown id among them still refuses" "THREW REJECT: Unknown marketplace add-on" (Market "json-tables,not-a-tool")
    $offer = (Get-Content -Raw (Join-Path $repo "setup/lib/exakit-common.ps1"))
    Has "a persona's all is the whole marketplace, not a filter" 'if ($only -eq "all") {' $offer

    Write-Host "after the table: your own file, then the external source:"
    # Picked in any order, the file's question comes first and the connect
    # wizard second, as in the shell twin (exakit_data_load_menu). The wizard is
    # the real Invoke-ExakitVsConnectWizard from a kit copy laid out as the
    # installer has it - setup\lib\virtual-schemas.ps1 and, beside the library,
    # the command: here a stub that logs what it was asked and exits STUB_RC.
    $orderFile = Join-Path $work "order.txt"
    $fake = Join-Path $work "fakekit"
    New-Item -ItemType Directory -Force -Path (Join-Path $fake "setup/lib") | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo "setup/lib/virtual-schemas.ps1") -Destination (Join-Path $fake "setup/lib/")
    @(
        'param([string]$Command)',
        '$said = (@("exakit", $Command) + @($args)) -join " "',
        'Add-Content -LiteralPath $env:STUB_LOG -Value $said',
        'exit ([int]$env:STUB_RC)'
    ) | Set-Content -Path (Join-Path $fake "setup/exakit.ps1") -Encoding ascii
    $env:STUB_LOG = $orderFile
    # The modules the CLI and the installer load before it (Join-ExakitCorePath).
    . (Join-Path $repo "setup/lib/core-setup.ps1")
    . (Join-Path $fake "setup/lib/virtual-schemas.ps1")
    Check "the wizard is the command beside the library" (Join-Path $fake "setup/exakit.ps1") (Get-ExakitVsCli)
    function Get-ExakitManifestValue([string]$Key) { return "admin" }
    function Start-ExakitDataTableRun { }
    function Stop-ExakitDataTableRun { }
    function Test-ExakitInteractive { return $true }
    $script:LocalThrows = $false
    function Import-ExakitLocalFile {
        Add-Content -LiteralPath $orderFile -Value "local"
        if ($script:LocalThrows) { throw "the file was refused" }
        return "loaded"
    }
    $script:Said = New-Object System.Collections.ArrayList
    function Info([string]$M) { [void]$script:Said.Add("INFO $M") }
    function Warn2([string]$M) { [void]$script:Said.Add("WARN $M") }
    # The real menu again: the data-load dispatch checks above stood it in.
    $menuAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo "setup/lib/exapump.ps1"), [ref]$null, [ref]$null)
    $menuDef = $menuAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Show-ExakitDataLoadMenu" }, $true)
    . ([scriptblock]::Create($menuDef.Extent.Text))
    function Ext([string]$Entry, [int]$Rc, [bool]$Confirmed = $true) {
        Remove-Item -LiteralPath $orderFile -ErrorAction SilentlyContinue
        $script:Said.Clear()
        $env:STUB_RC = "$Rc"
        $script:PickConfirmed = $Confirmed
        $threw = ""
        try {
            if ($Entry -eq "menu") { Show-ExakitDataLoadMenu } else { Request-ExakitDataLoadOffer -KitRoot $repo }
        } catch { $threw = "THREW $_" }
        $ran = (@(Get-Content -LiteralPath $orderFile -ErrorAction SilentlyContinue) -join "|")
        return "$ran~$threw~$($script:Said -join ' / ')"
    }
    function Select-ExakitDataLoad { param([string]$FinalLabel) $script:ExakitTableConfirmed = $script:PickConfirmed; return @("external", "local") }
    foreach ($entry in @("menu", "offer")) {
        $out = Ext $entry 0
        Check "$($entry): the file, then exakit connect with nothing after it" "local|exakit connect~" (($out -split '~')[0..1] -join '~')
        $out = Ext $entry 1
        Check "$($entry): a connect that fails does not fail the load" "local|exakit connect~" (($out -split '~')[0..1] -join '~')
        Has "$($entry): ...it is said, with the command" "WARN Connecting the external source did not finish (see above). Retry any time with: exakit connect" $out
        $out = Ext $entry 5
        Has "$($entry): a connect cancelled in the wizard (exit 5) is said" "INFO No external source was connected. Connect one any time with: exakit connect" $out
        Lacks "$($entry): ...and nothing throws" "THREW" $out
        $out = Ext $entry 0 $false
        Check "$($entry): nobody pressed Enter on the table: the wizard is never started" "local~" (($out -split '~')[0..1] -join '~')
        Has "$($entry): ...the command is named instead" "needs a terminal. Connect one any time with: exakit connect" $out
    }
    $script:LocalThrows = $true
    $out = Ext "offer" 0
    Check "the installer: a refused file still lets the external source have its turn, then the step fails" "local|exakit connect~THREW the file was refused" (($out -split '~')[0..1] -join '~')
    $script:LocalThrows = $false
    $menuText = (Get-Command Show-ExakitDataLoadMenu).Definition
    Lacks "...and the wizard is not piped" "connect | Out-Host" $menuText
    Lacks "...nor run through the shim on PATH" "exakit.cmd" $menuText

    Write-Host "the external row: picked where virtual schemas can run, else disabled with the reason:"
    $existing = Join-Path $work "python-here"
    Set-Content -LiteralPath $existing -Value "" -Encoding ascii
    function Get-PyexasolVenvPython { return $script:VenvPython }
    function ExternalRow {
        Set-Pending @("tpch")
        New-ExakitDataTable -FinalLabel "Skip"
        $row = $script:UiTable.Rows[3]
        return "$($row.Label)|$($row.State)~$($script:ExakitTableIds[3])"
    }
    $script:VenvPython = $existing
    Check "the module and the kit's pyexasol: pickable, under its own name" "Connect an external source|idle~external" (ExternalRow)
    $script:VenvPython = (Join-Path $work "no-such-python")
    Check "no pyexasol: disabled, and says so" "Connect an external source - no pyexasol|disabled~" (ExternalRow)
    function Get-ExakitVsDefs { return $null }
    Check "no definitions in this kit copy: disabled, and says so" "Connect an external source - unavailable|disabled~" (ExternalRow)
    Has "the installer loads the module, so its table can offer the row" '. (Join-Path $LibDir "virtual-schemas.ps1")' (Get-Content -Raw (Join-Path $repo "setup/setup-windows.ps1"))
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
Write-Host ""
Write-Host "data-question-ps.ps1: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
