#!/usr/bin/env pwsh
# table-menu-ps.ps1 - QAT-08: the Windows table menu (Invoke-ExakitTableMenu, the data-load, MCP and
# add-on tables) driven with real key sequences, so its behaviour is what is tested rather than the text
# of ui.ps1: where the cursor starts, rows nobody can pick, Select All, the exclusive Skip row, j/k, and
# Enter needing a selection. Commenting any of those arms out turns a check red. Runs under Windows
# PowerShell 5.1 and pwsh; the keys come from the test, so no console is needed.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0; $script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -ceq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$expected>, got <$actual>" }
}
. (Join-Path $repo "setup/lib/ui.ps1")

# The menus ask Test-ExakitMenuConsole whether they can; here the keys come from the test.
function Test-ExakitMenuConsole { return $true }
$script:UiFancy = $true
$script:Keys = New-Object 'System.Collections.Generic.Queue[object]'
function Read-ExakitMenuKey {
    if ($script:Keys.Count -eq 0) { throw "the menu asked for more keys than the test gave it" }
    return $script:Keys.Dequeue()
}
function Enable-ExakitMenuMouse { }
function Disable-ExakitMenuMouse { }
function Press([string[]]$Names) {
    foreach ($k in $Names) {
        if ($k.Length -eq 1) { $script:Keys.Enqueue(@{ Name = 'Char'; Char = $k }) }
        else { $script:Keys.Enqueue(@{ Name = $k }) }
    }
}
# Select All, three rows (the middle one cannot be picked), Skip.
function New-Fixture {
    $t = New-ExakitTable -Title "Datasets" -Col1 "Dataset" -Col2 "Rows"
    [void](Add-ExakitTableRow -Table $t -Kind group -Label "Select All")
    [void](Add-ExakitTableRow -Table $t -Kind tee -Label "tpch")
    [void](Add-ExakitTableRow -Table $t -Kind tee -Label "esophageal")
    $t.Rows[2].State = "disabled"
    [void](Add-ExakitTableRow -Table $t -Kind corner -Label "weather")
    [void](Add-ExakitTableRow -Table $t -Kind plain -Label "Skip")
    return $t
}
function Run-Menu([string[]]$Keys, [int[]]$Defaults = @(), [string]$Mode = "all") {
    $script:Keys.Clear(); Press $Keys
    $picked = @(Invoke-ExakitTableMenu -Table (New-Fixture) -Defaults $Defaults -ExclusiveIndex 5 `
        -GroupParent 1 -GroupFirst 2 -GroupLast 4 -GroupMode $Mode 6> $null)
    return ($picked -join ',')
}

Write-Host "== where the cursor starts, and what it steps over =="
Check "Space first ticks the first dataset, not Select All" "2" (Run-Menu @('Space', 'Enter'))
Check "Down steps over the row nobody can pick" "4" (Run-Menu @('Down', 'Space', 'Enter'))
Check "j and k move like Down and Up" "2" (Run-Menu @('j', 'k', 'Space', 'Enter'))
Check "Up from the first dataset reaches Select All, which ticks every pickable row" "1,2,4" (Run-Menu @('Up', 'Space', 'Enter'))

Write-Host "== the group and the exclusive row =="
Check "unticking a child releases Select All (all mode)" "4" (Run-Menu @('Space', 'Enter') -Defaults @(1, 2, 4))
Check "ticking every child claims Select All (all mode)" "1,2,4" (Run-Menu @('Space', 'Enter') -Defaults @(4))
Check "Enter on Skip answers Skip alone, whatever was ticked" "5" (Run-Menu @('Down', 'Down', 'Enter') -Defaults @(2, 4))
Check "ticking Skip clears the others" "5" (Run-Menu @('Down', 'Down', 'Space', 'Enter') -Defaults @(2, 4))
Check "ticking another row clears Skip" "2" (Run-Menu @('Space', 'Enter') -Defaults @(5))

Write-Host "== Enter needs a selection =="
Check "Enter with nothing ticked waits; Space then Enter answers" "2" (Run-Menu @('Enter', 'Space', 'Enter'))
[void](Run-Menu @('Space', 'Enter'))
Check "a human Enter marks the table confirmed" $true $script:ExakitTableConfirmed
$env:UI_TABLE_AUTO = "1"
$script:Keys.Clear()
$auto = @(Invoke-ExakitTableMenu -Table (New-Fixture) -Defaults @(2) 6> $null) -join ','
Remove-Item Env:UI_TABLE_AUTO
Check "UI_TABLE_AUTO keeps the defaults without asking" "2" $auto

Write-Host ""
Write-Host "passed: $($script:PASS), failed: $($script:FAIL)"
if ($script:FAIL -gt 0) { exit 1 }
