#!/usr/bin/env pwsh
# persona-search-ps.ps1 - the persona question's search line on Windows: Get-ExakitFuzzyScore
# scores every case in tests/fuzzy-search-cases.json exactly as fuzzy_score (marketplace/ui.py)
# and _ui_fuzzy_score (common.sh) do, and Read-ExakitCheckboxMenu -Search types letters into the
# search, points at the closest row, and keeps Space, Enter and Esc. Runs under Windows
# PowerShell 5.1 and pwsh; the keys come from the test, so no console is needed.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0; $script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -ceq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$expected>, got <$actual>" }
}
. (Join-Path $repo "setup/lib/exakit-common.ps1") *> $null

Write-Host "== the same score as the Python and shell twins =="
$cases = (Get-Content -LiteralPath (Join-Path $repo "tests/fuzzy-search-cases.json") -Raw -Encoding UTF8 | ConvertFrom-Json).cases
foreach ($case in $cases) {
    $got = Get-ExakitFuzzyScore -Query $case.query -Text $case.text
    $want = if ($null -eq $case.score) { "none" } else { "$($case.score)" }
    $have = if ($null -eq $got) { "none" } else { "$got" }
    Check ("'{0}' in '{1}...'" -f $case.query, $case.text.Substring(0, 14)) $want $have
}

Write-Host "== the menu: letters search, the pointer follows =="
# The menus ask Test-ExakitMenuConsole whether they can; here the keys come from the test.
function Test-ExakitMenuConsole { return $true }
$script:Keys = New-Object 'System.Collections.Generic.Queue[object]'
function Read-ExakitMenuKey { return $script:Keys.Dequeue() }
function Send([string]$text) { foreach ($c in $text.ToCharArray()) { $script:Keys.Enqueue(@{ Name = 'Char'; Char = [string]$c }) } }
$options = @("Data Scientist - Explore data", "ML Engineer - Train models", "General - The kit's own samples")

Send "ml"; $script:Keys.Enqueue(@{ Name = 'Space' }); $script:Keys.Enqueue(@{ Name = 'Enter' })
$picked = @(Read-ExakitCheckboxMenu -Title "Personas" -Options $options -Defaults @(3) -Search 6> $null)
Check "typing 'ml' points at ML Engineer, Space ticks it" "2,3" ($picked -join ',')

Send "qajk"; $script:Keys.Enqueue(@{ Name = 'Escape' }); $script:Keys.Enqueue(@{ Name = 'Enter' })
$picked = @(Read-ExakitCheckboxMenu -Title "Personas" -Options $options -Defaults @(3) -Search 6> $null)
Check "q, a, j and k are typed, not cancel, tick-all or moves; Esc clears" "3" ($picked -join ',')

Send "gex"; $script:Keys.Enqueue(@{ Name = 'Char'; Char = [string][char]8 })
$script:Keys.Enqueue(@{ Name = 'Space' }); $script:Keys.Enqueue(@{ Name = 'Enter' })
$picked = @(Read-ExakitCheckboxMenu -Title "Personas" -Options $options -Defaults @(1) -Search 6> $null)
Check "Backspace takes the last letter back ('ge' is General)" "1,3" ($picked -join ',')

$script:Keys.Enqueue(@{ Name = 'Char'; Char = 'a' }); $script:Keys.Enqueue(@{ Name = 'Enter' })
$picked = @(Read-ExakitCheckboxMenu -Title "Datasets" -Options $options -Defaults @(3) 6> $null)
Check "without -Search, 'a' still ticks every row" "1,2,3" ($picked -join ',')

Write-Host ""
Write-Host "passed: $($script:PASS), failed: $($script:FAIL)"
if ($script:FAIL -gt 0) { exit 1 }
