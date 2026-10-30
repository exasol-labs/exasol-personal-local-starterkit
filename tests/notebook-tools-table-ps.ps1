#!/usr/bin/env pwsh
# notebook-tools-table-ps.ps1 - the Windows twin of tests/notebook-tools-table.sh:
# the notebook add-on's tools (JupyterLab, Marimo, Positron) are CHILD ROWS of
# its row in the marketplace's add-ons table, one level deeper, ticked right
# there; each says before anything installs what will become of it, and then
# how the install settled it. The table menu is mocked, as the other PS tests
# mock it: what it was asked with is recorded, and it answers the rows given.
# Runs under Windows PowerShell 5.1 and pwsh; a sandboxed kit home, no network,
# nothing installed.
#
#   pwsh -NoProfile -File tests/notebook-tools-table-ps.ps1
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-nbt-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:EXAKIT_HOME = Join-Path $work "home"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
New-Item -ItemType Directory -Force -Path $env:EXAKIT_HOME, $env:EXAKIT_BIN_DIR | Out-Null
[System.IO.File]::WriteAllText((Join-Path $env:EXAKIT_HOME 'manifest.json'), '{}', (New-Object System.Text.UTF8Encoding($false)))
$env:EXAKIT_VERSION_POLICY = 'pinned'
foreach ($v in "EXAKIT_MARKETPLACE_ADDONS", "EXAKIT_MARKETPLACE_ONLY", "EXAKIT_NOTEBOOK_FRONTENDS",
               "EXAKIT_NOTEBOOK_JUPYTER", "EXAKIT_NOTEBOOK_MARIMO") {
    Remove-Item "Env:$v" -ErrorAction SilentlyContinue
}
. (Join-Path $repo "setup/lib/exakit-common.ps1")
. (Join-Path $repo "setup/lib/persona.ps1")
Initialize-ExakitMarketplacePythonHooks
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

# The add-ons on offer: the notebook and one other, in the registry's order.
$script:Offer = @("notebook", "udf-devkit")
function Test-ExakitAddonOfferable([string]$Id) { return ($script:Offer -contains $Id) }
function Test-ExakitMarketplaceAddonInstalled([string]$Id) { return $false }
function Test-ExakitAddonSystemPresent([string]$Id) { return $false }
function Get-ExakitMarketplaceAddonDescription([string]$Id) { return "About $Id" }
function Get-ExakitAddonAdvertisedVersion { param([string]$Id, [string]$Fallback) return "1.0.0" }
function Test-ExakitInteractive { return $true }
# The other add-on's module, as far as the menu looks: it ships in this copy.
function Install-UdfDevkit { return $true }
$script:Recorded = $null
# The table menu: records what it was asked with, answers $script:Answer (the
# defaults when that is $null).
$script:Answer = $null
function Invoke-ExakitTableMenu {
    param($Table = $null, [int[]]$Defaults = @(), [int]$ExclusiveIndex = 0, [string[]]$Groups = @(),
          [int]$GroupParent = 0, [int]$GroupFirst = 0, [int]$GroupLast = 0, [string]$GroupMode = "any",
          [int]$OnScreen = 0)
    $script:MenuAsked = "$($Defaults -join ',')~$ExclusiveIndex~$($Groups -join ' ')~$GroupParent~$GroupFirst~$GroupLast~$GroupMode"
    $script:MenuRows = @($Table.Rows | ForEach-Object { "$($_.Kind)|$($_.Label)|$($_.Col2)|$($_.Col3)" })
    $script:ExakitTableConfirmed = $true
    if ($null -eq $script:Answer) { return @($Defaults) }
    return @($script:Answer)
}
# The install: records the add-ons and the answer it was handed, and whether
# the question hook was asked.
function Invoke-ExakitMarketplaceApply {
    param([string[]]$Ids)
    Invoke-ExakitMarketplaceQuestions -Ids $Ids
    $script:Applied = "$($Ids -join ',')|$($env:EXAKIT_NOTEBOOK_FRONTENDS)"
}
function Read-NotebookQuestions { $script:Asked = "asked" }
function Menu($Answer) {
    $script:Answer = $Answer
    $script:Applied = ""; $script:Asked = ""
    Remove-Item Env:EXAKIT_NOTEBOOK_FRONTENDS -ErrorAction SilentlyContinue
    $receipt = if ($script:Recorded) { @{ components = @{ notebook = @{ front_ends = $script:Recorded } } } } else { @{} }
    [System.IO.File]::WriteAllText((Join-Path $env:EXAKIT_HOME 'manifest.json'), ($receipt | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    Show-ExakitMarketplaceMenu 6>$null
    $script:Answer = $null
}

try {
    $versions = Get-Content -Raw (Join-Path $repo "versions.json") | ConvertFrom-Json
    $pinJ = $versions.components.notebook.frontends.jupyterlab
    $pinM = $versions.components.notebook.frontends.marimo

    Write-Host "the rows: the notebook's tools hang off its row:"
    Menu $null
    Check "the kinds and labels" `
        "group|Select All;tee|notebook;tee-tee|JupyterLab;tee-tee|Marimo;tee-corner|Positron;corner|udf-devkit;plain|Skip" `
        (@($script:MenuRows | ForEach-Object { ($_ -split '\|')[0..1] -join '|' }) -join ';')
    Check "child ids are <id>:<key>" ",notebook,notebook:jupyterlab,notebook:marimo,notebook:positron,udf-devkit," `
        ($script:ExakitAddonTableIds -join ',')
    Check "asked: everything ticked, Skip exclusive, the notebook a claim parent inside Select All" `
        "1,2,3,4,5,6~7~2:3:5:claim~1~2~6~all" $script:MenuAsked
    Check "the JupyterLab row: its pin, and the kit installs one" "$pinJ|not on this machine: installed into the kit's notebook environment" `
        ((($script:MenuRows[2] -split '\|')[2..3]) -join '|')
    Check "the Marimo row: its pin" $pinM (($script:MenuRows[3] -split '\|')[2])
    Check "the Positron row: no version, the folder prepared" "|not on this machine: the notebooks folder is prepared for it (positron.posit.co)" `
        ((($script:MenuRows[4] -split '\|')[2..3]) -join '|')
    Check "Enter keeps all three, the question not asked" "notebook,udf-devkit|jupyterlab,marimo,positron" $script:Applied
    Check "...no question hook" "" $script:Asked

    Write-Host "the ticks are the answer:"
    Menu @(2, 3, 5, 6)
    Check "Marimo unticked: the other two" "notebook,udf-devkit|jupyterlab,positron" $script:Applied
    Menu @(6)
    Check "the notebook unticked: not installed" "udf-devkit|" $script:Applied
    Menu @(2)
    Check "the notebook with no tool: none" "notebook|none" $script:Applied
    Menu @(2, 3)
    Check "one tool" "notebook|jupyterlab" $script:Applied

    Write-Host "the default ticks come from the record, or the variable:"
    $script:Recorded = "jupyterlab,positron"
    Menu $null
    Check "a recorded choice without Marimo: its row and Select All unticked" "2,3,5,6~7~2:3:5:claim~1~2~6~all" $script:MenuAsked
    $script:Recorded = $null
    $env:EXAKIT_NOTEBOOK_FRONTENDS = "marimo"
    Check "EXAKIT_NOTEBOOK_FRONTENDS decides them" "False|True|False" `
        (@(Get-NotebookTableChildren | ForEach-Object { $_.Ticked }) -join '|')
    Remove-Item Env:EXAKIT_NOTEBOOK_FRONTENDS
    $env:EXAKIT_NOTEBOOK_MARIMO = "skip"
    [System.IO.File]::WriteAllText((Join-Path $env:EXAKIT_HOME 'manifest.json'), '{}', (New-Object System.Text.UTF8Encoding($false)))
    Check "the default helper does not ask" "jupyterlab,positron" (Invoke-ExakitNotebookChoice -Kind 'notebook-default')
    Remove-Item Env:EXAKIT_NOTEBOOK_MARIMO

    Write-Host "the persona closing offer shows the same children, under a corner:"
    $env:EXAKIT_MARKETPLACE_ONLY = "notebook"
    Menu $null
    Check "the kinds" "group;corner;corner-tee;corner-tee;corner-corner;plain" `
        (@($script:MenuRows | ForEach-Object { ($_ -split '\|')[0] }) -join ';')
    Check "asked with the children in Select All" "1,2,3,4,5~6~2:3:5:claim~1~2~5~all" $script:MenuAsked
    Remove-Item Env:EXAKIT_MARKETPLACE_ONLY

    Write-Host "the drawn frame, at 80 columns:"
    $script:UiFancy = $true
    Set-ExakitPalette
    $t = New-ExakitTable -Title "Marketplace add-ons" -Col1 "Add-on" -Col2 "Version" -Col3 "Description"
    $t.Cols = 80
    [void](Add-ExakitTableRow -Kind "group" -Label "Select All" -Table $t)
    [void](Add-ExakitTableRow -Kind "tee" -Label "notebook" -Col2 "3.1.0" -Col3 "Notebooks connected to the local Exasol database" -Table $t)
    $kids = @(Get-NotebookTableChildren)
    [void](Add-ExakitTableRow -Kind "tee-tee" -Label $kids[0].Label -Col2 $kids[0].Version -Col3 $kids[0].Description -Table $t)
    [void](Add-ExakitTableRow -Kind "tee-tee" -Label $kids[1].Label -Col2 $kids[1].Version -Col3 $kids[1].Description -Table $t)
    [void](Add-ExakitTableRow -Kind "tee-corner" -Label $kids[2].Label -Col2 $kids[2].Version -Col3 $kids[2].Description -Table $t)
    [void](Add-ExakitTableRow -Kind "corner" -Label "dash-server" -Col2 "1.0.0" -Col3 "About dash-server" -Table $t)
    [void](Add-ExakitTableRow -Kind "plain" -Label "Skip" -Table $t)
    $frame = (Get-ExakitTableFrame -Table $t -Cursor 0) -replace "$([char]27)\[[0-9;]*m", ""
    $lines = @($frame -split "`r`n")
    $vb = $script:UiVB; $tee = $script:UiTee; $corner = $script:UiCorner
    Has "the notebook row is a tee" "$tee notebook" $frame
    Has "JupyterLab hangs off it, its spine carried on" "$vb  $tee JupyterLab" $frame
    Has "Marimo too" "$vb  $tee Marimo" $frame
    Has "Positron is the last of them" "$vb  $corner Positron" $frame
    Has "the notebook's wrapped description starts its children's spine" "     $vb  $vb " $frame
    Lacks "nothing cut short" $script:UiEllipsis $frame
    $widest = 0
    foreach ($l in $lines) { if ($l.Length -gt $widest) { $widest = $l.Length } }
    Check "nothing past 80 columns" $true ($widest -le 80)

    Write-Host "the table records each tool's final status:"
    $script:ExakitAddonTable = $t
    $script:ExakitAddonTableIds = @("", "notebook", "notebook:jupyterlab", "notebook:marimo", "notebook:positron", "dash-server", "")
    $script:ExakitAddonTableLive = $true
    $script:ExakitAddonTableChildRows = Get-ExakitAddonTableChildRows -Id "notebook"
    Check "the child rows are found by key" "3|4|5" "$($script:ExakitAddonTableChildRows['jupyterlab'])|$($script:ExakitAddonTableChildRows['marimo'])|$($script:ExakitAddonTableChildRows['positron'])"
    [void](Set-ExakitAddonTableChild -Key 'jupyterlab' -State 'done' -Final "installed $pinJ")
    [void](Set-ExakitAddonTableChild -Key 'marimo' -State 'skipped' -Final 'skipped')
    Check "JupyterLab final status stays on its row" "done|installed $pinJ" "$($t.Rows[2].State)|$($t.Rows[2].Final)"
    Check "Marimo final status stays on its row" "skipped|skipped" "$($t.Rows[3].State)|$($t.Rows[3].Final)"
    $done = (Get-ExakitTableFrame -Table $t -Cursor 0) -replace "$([char]27)\[[0-9;]*m", ""
    Has "a skipped row reads skipped" "skipped" $done
    $script:ExakitAddonTableLive = $false
    Check "no live table: the caller's line is the record" $false (Set-ExakitAddonTableChild -Key "marimo" -State "done" -Final "x")
    Reset-ExakitAddonTable

    Write-Host "no table: the question hook is still asked:"
    $script:Asked = ""
    Invoke-ExakitMarketplaceQuestions -Ids @("notebook")
    Check "a scripted run asks it" "asked" $script:Asked
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
Write-Host ""
Write-Host "notebook-tools-table-ps.ps1: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
