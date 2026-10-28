$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo "setup/lib/exakit-common.ps1")
$script:UiFancy = $false
$script:ExakitAddonTable = New-ExakitTable -Title "Marketplace add-ons" -Col1 "Add-on"
$table = $script:ExakitAddonTable
$table.Cols = 80
$table.Activity = ""
[void](Add-ExakitTableRow -Kind "group" -Label "Select All" -Table $table)
[void](Add-ExakitTableRow -Kind "corner" -Label "udf-devkit" -Table $table)
$script:ExakitAddonTableRow = 2
Set-ExakitAddonProgress -Id "udf-devkit" -Pct 40 -Ceiling 65 -Secs 40 -Phase "installing"
$frame = Get-ExakitTableFrame -Table $table
$height = $table.Lines
Start-ExakitSpinner "Downloading the Python ML container"
Stop-ExakitSpinner
$frame = Get-ExakitTableFrame -Table $table
if (-not $frame.Contains("Downloading the Python ML container")) { throw "missing download activity" }
Set-ExakitAddonActivity -Message "Checking packages"
$frame = Get-ExakitTableFrame -Table $table
if (-not $frame.Contains("Checking packages") -or $frame.Contains("Downloading the Python")) { throw "stale activity" }
if ($table.Lines -ne $height -or $table.Rows[1].Pct -ne 40) { throw "frame height or progress changed" }
Set-ExakitAddonActivity -Message ("x" * 120)
$frame = Get-ExakitTableFrame -Table $table
foreach ($line in ($frame -split "`r?`n")) { if ($line.Length -gt 80) { throw "activity wraps" } }
Write-Host "PASS activity changes, frame height and progress retained, long text fits"
