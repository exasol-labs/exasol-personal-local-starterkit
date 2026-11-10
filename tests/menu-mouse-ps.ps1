#!/usr/bin/env pwsh
# menu-mouse-ps.ps1 - the PowerShell menus take a click, as the shell menus do (ui.sh):
# the escape sequences a Windows
# console sends in virtual-terminal input mode are read as the keys and clicks they
# are, the wheel is handed back, a click maps to the row under it (the table frame
# records the line each row starts on), the mouse stays off where it cannot work,
# and both menus read their keys through Read-ExakitMenuKey and give the console
# its mode back however they end. Runs under Windows PowerShell 5.1 and pwsh.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0; $script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -ceq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$expected>, got <$actual>" }
}
. (Join-Path $repo "setup/lib/ui.ps1")

Write-Host "== what follows ESC =="
Check "an arrow up (CSI and SS3)" "Up|Up" "$((ConvertFrom-ExakitMenuSequence '[A').Name)|$((ConvertFrom-ExakitMenuSequence 'OA').Name)"
Check "an arrow down" "Down" (ConvertFrom-ExakitMenuSequence '[B').Name
$click = ConvertFrom-ExakitMenuSequence '[<0;12;7M'
Check "a left-button press is a click, with its screen row" "Click|7" "$($click.Name)|$($click.Y)"
Check "its release is ignored" "Ignore" (ConvertFrom-ExakitMenuSequence '[<0;12;7m').Name
Check "a right or middle press is ignored" "Ignore|Ignore" "$((ConvertFrom-ExakitMenuSequence '[<2;12;7M').Name)|$((ConvertFrom-ExakitMenuSequence '[<1;12;7M').Name)"
Check "the wheel, both ways" "Wheel|Wheel" "$((ConvertFrom-ExakitMenuSequence '[<64;1;1M').Name)|$((ConvertFrom-ExakitMenuSequence '[<65;1;1M').Name)"
Check "a lone Escape" "Escape" (ConvertFrom-ExakitMenuSequence '').Name
Check "a key the menus do not use" "Ignore" (ConvertFrom-ExakitMenuSequence '[3~').Name

Write-Host "== a click lands on the row under it =="
# Three options and the hint: the cursor is on row 20 of the buffer after drawing,
# so the menu's four lines are rows 16-19; the window starts at buffer row 10.
$starts = @(0, 1, 2, 3)
Check "the first option" 1 (Get-ExakitMenuClickRow -Y 7 -Drawn 4 -Starts $starts -CursorTop 20 -WindowTop 10)
Check "the third option" 3 (Get-ExakitMenuClickRow -Y 9 -Drawn 4 -Starts $starts -CursorTop 20 -WindowTop 10)
Check "the hint is no row" 0 (Get-ExakitMenuClickRow -Y 10 -Drawn 4 -Starts $starts -CursorTop 20 -WindowTop 10)
Check "above the menu is no row" 0 (Get-ExakitMenuClickRow -Y 6 -Drawn 4 -Starts $starts -CursorTop 20 -WindowTop 10)
Check "a scrolled window moves the rows with it" 2 (Get-ExakitMenuClickRow -Y 3 -Drawn 4 -Starts $starts -CursorTop 20 -WindowTop 15)

Write-Host "== the table frame records where each row starts =="
$script:UiFancy = $true
$table = New-ExakitTable -Title "Marketplace add-ons" -Col1 "Add-on" -Col2 "Version" -Col3 "Description"
Add-ExakitTableRow -Table $table -Kind group -Label "Select All" -Ticked
Add-ExakitTableRow -Table $table -Kind tee -Label "notebook" -Col2 "3.1.0" -Col3 ("A description long enough to wrap " * 4) -Ticked
Add-ExakitTableRow -Table $table -Kind corner -Label "udf-devkit" -Col2 "0.1.0" -Col3 "UDFs" -Ticked
Add-ExakitTableRow -Table $table -Kind plain -Label "Skip"
$frame = (Get-ExakitTableFrame -Table $table -Cursor 2) -split "`r`n"
$at = @($table.RowAt)
Check "one start per row, and the end" 5 $at.Count
Check "the first row is under the border and the heading" 2 $at[0]
Check "each row starts where its name is drawn" "Select All|notebook|udf-devkit|Skip" `
    ((0..3 | ForEach-Object { if ($frame[$at[$_]] -match 'Select All|notebook|udf-devkit|Skip') { $Matches[0] } }) -join '|')
Check "a wrapped description stays with its row" $true ($at[2] - $at[1] -gt 1)
Check "the end is the bottom border" $true ($frame[$at[4]] -match [regex]::Escape($script:UiBL))

Write-Host "== where it is off, and how it ends =="
$script:UiMouse = $null
if ($PSVersionTable.PSVersion.Major -gt 5 -and -not $IsWindows) {
    Enable-ExakitMenuMouse
    Check "off the Windows console nothing is switched on" $true ($null -eq $script:UiMouse)
}
$env:EXAKIT_NO_MOUSE = '1'
Enable-ExakitMenuMouse
Check "EXAKIT_NO_MOUSE=1 keeps it off" $true ($null -eq $script:UiMouse)
Remove-Item Env:EXAKIT_NO_MOUSE
$ui = Get-Content -LiteralPath (Join-Path $repo "setup/lib/ui.ps1") -Raw
$common = Get-Content -LiteralPath (Join-Path $repo "setup/lib/exakit-common.ps1") -Raw
$table = $ui.Substring($ui.IndexOf("function Invoke-ExakitTableMenu"))
$checkbox = $common.Substring($common.IndexOf("function Read-ExakitCheckboxMenu"))
$checkbox = $checkbox.Substring(0, $checkbox.IndexOf("`nfunction ", 10))
Check "the table menu reads keys and clicks through Read-ExakitMenuKey" $true ($table -match 'Read-ExakitMenuKey' -and $table -notmatch '\[Console\]::ReadKey')
Check "...and gives the console its mode back however it ends" $true ($table -match 'finally \{ Disable-ExakitMenuMouse \}')
Check "the checkbox menu reads keys and clicks through Read-ExakitMenuKey" $true ($checkbox -match 'Read-ExakitMenuKey' -and $checkbox -notmatch '\[Console\]::ReadKey')
Check "...and gives the console its mode back however it ends" $true ($checkbox -match 'finally \{[^}]*Disable-ExakitMenuMouse')
Check "a failed run gives it back too (Restore-ExakitCursor)" $true ($ui -match 'function Restore-ExakitCursor \{ Disable-ExakitMenuMouse')

Write-Host ""
Write-Host "menu-mouse-ps: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
