#!/usr/bin/env pwsh
# data-question-ps.ps1 - the Windows twin of tests/data-question.sh: the first
# data question keeps Skip on row 4 (the external source and, with every sample
# loaded, the samples row shown disabled), a persona that wants no samples or
# only loaded ones makes Skip the default of both questions, who each dataset is
# for is a "For" column, `exakit data-load` takes -Force and a dataset in either
# order, and a scripted add-on that does not run here is skipped rather than
# ending the answer. Runs under Windows PowerShell 5.1 and pwsh; a sandboxed kit
# home, nothing installed or loaded.
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
$script:LogFile = $null
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$expected>, got <$actual>" }
}
function Has($label, $needle, $haystack) {
    if (("" + $haystack).Contains("" + $needle)) { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected '$needle' in <$haystack>" }
}
function Lacks($label, $needle, $haystack) {
    if (-not ("" + $haystack).Contains("" + $needle)) { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): did not expect '$needle' in <$haystack>" }
}
function Fail([string]$Msg) { throw "FAIL: $Msg" }
function Set-Pending([string[]]$Ids) {
    $script:PendingIds = @($Ids)
}
function Get-ExakitPendingDatasets {
    return @($script:PendingIds | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Id = $_; Label = "$_ label (~1k rows)" } })
}
# The first question, as Read-ExakitCheckboxMenu is asked it.
function Read-ExakitCheckboxMenu {
    param([string]$Title, [string[]]$Options, [int[]]$Defaults = @(), [int]$ExclusiveIndex = 0)
    $script:Asked = @{ Options = $Options; Defaults = ($Defaults -join ","); Exclusive = $ExclusiveIndex }
    return @($script:Answer)
}

try {
    Initialize-ExakitManifest | Out-Null

    Write-Host "the first question's rows (Skip stays row 4):"
    Set-Pending @("tpch"); $script:Answer = @(1)
    [void](Select-ExakitDataSource)
    Check "four rows, external disabled, Skip exclusive" `
        "Sample datasets - 1 ready to load, picked next|Your own file or folder - CSV, Parquet or JSON|!Connect an external source - coming soon|Skip~1~4" `
        "$($script:Asked.Options -join '|')~$($script:Asked.Defaults)~$($script:Asked.Exclusive)"
    Set-Pending @(); $script:Answer = @(2)
    [void](Select-ExakitDataSource)
    Check "every sample loaded: the samples row is shown disabled, your own file the default" `
        "!Sample datasets - all of them are loaded already~2~4" "$($script:Asked.Options[0])~$($script:Asked.Defaults)~$($script:Asked.Exclusive)"
    Set-Pending @("tpch")
    $env:EXAKIT_DATASETS_PRESELECT = "none"; [void](Select-ExakitDataSource)
    Check "persona datasets none: Skip is the default" "4" $script:Asked.Defaults
    $env:EXAKIT_DATASETS_PRESELECT = "pharma_trials,energy"; [void](Select-ExakitDataSource)
    Check "persona datasets none of them pending: Skip is the default" "4" $script:Asked.Defaults
    $env:EXAKIT_DATASETS_PRESELECT = "TPCH"; [void](Select-ExakitDataSource)
    Check "dataset ids are matched case-sensitively, like the shell side" "4" $script:Asked.Defaults
    $env:EXAKIT_DATASETS_PRESELECT = "tpch"; [void](Select-ExakitDataSource)
    Check "persona datasets pending: the samples are the default" "1" $script:Asked.Defaults
    Set-Pending @(); [void](Select-ExakitDataSource)
    Check "persona datasets all loaded and nothing pending: Skip, not your own file" "4" $script:Asked.Defaults
    Remove-Item Env:EXAKIT_DATASETS_PRESELECT
    Set-Pending @("tpch")
    $script:Answer = @(4); Check "Skip answers none" "none" ((@(Select-ExakitDataSource)) -join ",")
    $script:Answer = @(1, 2); Check "samples and a file" "sample,local" ((@(Select-ExakitDataSource)) -join ",")
    $script:Answer = @(3); Check "the disabled row never answers anything" "none" ((@(Select-ExakitDataSource)) -join ",")

    Write-Host "the samples table: Skip when nothing on offer is wanted:"
    function Table([string[]]$Pending) {
        Set-Pending $Pending
        New-ExakitDataTable -FinalLabel "Skip" -NoLocal
        return "$($script:ExakitTableDefaults -join ',')~$($script:ExakitTableRowSkip)"
    }
    Check "no persona: every pending row ticked" "1,2,3~4" (Table @("tpch", "energy"))
    $env:EXAKIT_DATASETS_PRESELECT = "energy"
    Check "persona's dataset pending: that row" "3~4" (Table @("tpch", "energy"))
    $env:EXAKIT_DATASETS_PRESELECT = "pharma_trials"
    Check "persona's datasets loaded already: Skip" "4~4" (Table @("tpch", "energy"))
    $env:EXAKIT_DATASETS_PRESELECT = "none"
    Check "persona datasets none: Skip" "4~4" (Table @("tpch", "energy"))
    $env:EXAKIT_DATASETS_PRESELECT = "ENERGY"
    Check "case-sensitive, like the shell side" "4~4" (Table @("tpch", "energy"))
    Remove-Item Env:EXAKIT_DATASETS_PRESELECT
    Check "nothing pending and no file row: Skip" "1~1" (Table @())
    Set-Pending @(); New-ExakitDataTable -FinalLabel "Skip"
    Check "nothing pending with a file row: the file row, never Skip" "1~1~2" "$($script:ExakitTableDefaults -join ',')~$($script:ExakitTableRowLocal)~$($script:ExakitTableRowSkip)"

    Write-Host "who each dataset is for is a column, not a suffix:"
    Set-Pending @("tpch", "pharma_trials")
    New-ExakitDataTable -FinalLabel "Skip" -NoLocal
    Check "the names stay names" "Select All;tpch label;pharma_trials label;Skip" ((@($script:UiTable.Rows | ForEach-Object { $_.Label })) -join ";")
    Check "the personas go in column 2" ";;AI Scientist, ML Engineer;" ((@($script:UiTable.Rows | ForEach-Object { $_.Col2 })) -join ";")
    Check "the table knows it has them" "True" "$($script:ExakitTableHasFor)"
    function Select-ExakitDataSource { return @("sample") }
    function Invoke-ExakitTableMenu {
        param($Table = $null, [int[]]$Defaults = @(), [int]$ExclusiveIndex = 0, [int]$GroupParent = 0,
              [int]$GroupFirst = 0, [int]$GroupLast = 0, [string]$GroupMode = "any", [int]$OnScreen = 0)
        $script:Col2AtMenu = "" + $script:UiTable.Col2
        return @($Defaults)
    }
    $chosen = @(Select-ExakitDataLoad -FinalLabel "Skip")
    Check "the For column is up while the reader picks" "For" $script:Col2AtMenu
    Check "...and gone again before the progress display" "" ("" + $script:UiTable.Col2)
    Check "the picked rows still answer" "tpch,pharma_trials" ($chosen -join ",")

    Write-Host "Enter on the exclusive row answers it alone:"
    # The keypress loop needs a console; the rule is pinned by its text, and
    # behaviourally on the shell twin (tests/data-question.sh, a real pty).
    $cbText = (Get-Content -Raw (Join-Path $repo "setup/lib/exakit-common.ps1"))
    Has "Read-ExakitCheckboxMenu: Enter on the exclusive row clears the rest" `
        'if ($ExclusiveIndex -ge 1 -and $script:cbCur -eq $ExclusiveIndex) { $sel.Clear(); [void]$sel.Add($ExclusiveIndex) }' $cbText

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
    Has "-Force <dataset> reloads exactly that dataset" "LOAD pharma_trials True|" (DataLoad @("tpch") @("--force", "pharma_trials"))
    Has "<dataset> -Force, the other order, too" "LOAD pharma_trials True|" (DataLoad @("tpch") @("pharma_trials", "-Force"))
    Has "bare -Force still reloads the bundled sample" "LOAD tpch(sample) True|" (DataLoad @("tpch") @("-Force"))
    $env:EXAKIT_DATA_FILE = $work
    Has "a dataset id wins over EXAKIT_DATA_FILE in the environment" "LOAD pharma_trials False|" (DataLoad @("pharma_trials") @("pharma_trials"))
    $env:EXAKIT_DATASETS = "tpch"
    Has "...and over EXAKIT_DATASETS" "LOAD energy False|" (DataLoad @("tpch", "energy") @("energy"))
    Has "an id already loaded names the reload command for it" "exakit data-load --force pharma_trials" (DataLoad @("tpch") @("pharma_trials"))
    Has "two targets are refused" "REJECT: data-load takes one file, folder or dataset at a time" (DataLoad @("tpch") @("tpch", "energy"))
    Has "-Force with a file is refused, with the file's own answer" "EXAKIT_ON_EXISTING" (DataLoad @("tpch") @("-Force", $work))
    Has "an unknown option is refused" "REJECT: Unknown option '--nope'" (DataLoad @("tpch") @("--nope"))
    Has "a dataset id is matched case-sensitively" "No such file, folder or dataset: TPCH" (DataLoad @("tpch") @("TPCH"))
    Has "the one-argument form still works" "LOAD pharma_trials True|" ($(Set-Pending @("tpch"); $script:Did = @(); Invoke-CmdDataLoad -Argument "--force" -Arguments @("pharma_trials") 6>$null; "$($script:Did -join ';')|"))

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
    Has "an unknown id among them still refuses" "THREW FAIL: Unknown marketplace add-on" (Market "json-tables,not-a-tool")
    $offer = (Get-Content -Raw (Join-Path $repo "setup/lib/exakit-common.ps1"))
    Has "a persona's all is the whole marketplace, not a filter" 'if ($only -eq "all") {' $offer
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
Write-Host ""
Write-Host "data-question-ps.ps1: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
