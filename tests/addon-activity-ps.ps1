$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo "setup/lib/exakit-common.ps1")
$script:UiFancy = $false
$script:ExakitAddonTable = New-ExakitTable -Title "Marketplace add-ons" -Col1 "Add-on"
$table = $script:ExakitAddonTable
$table.Cols = 80
$table.Activity = ""
[void](Add-ExakitTableRow -Kind "group" -Label "Select All" -Table $table)
[void](Add-ExakitTableRow -Kind "tee" -Label "udf-devkit" -Table $table)
[void](Add-ExakitTableRow -Kind "corner" -Label "dash-server" -Table $table)
$script:ExakitAddonTableRow = 2
Set-ExakitAddonProgress -Id "udf-devkit" -Pct 40 -Ceiling 65 -Secs 40 -Phase "installing"
$frame = Get-ExakitTableFrame -Table $table
$height = $table.Lines
Start-ExakitSpinner "Downloading the Python ML container"
Stop-ExakitSpinner
$frame = Get-ExakitTableFrame -Table $table
if (-not $frame.Contains("Downloading the Python ML container")) { throw "missing download activity" }
$lines = $frame -split "`r?`n"
$at = 0; while (-not $lines[$at].Contains("udf-devkit")) { $at++ }
if (-not $lines[$at - 1].Contains("Downloading the Python ML container")) { throw "phase is not directly above UDF bar" }
if ($lines[$at - 1].IndexOf("Downloading") -ne $lines[$at].IndexOf("#")) { throw "phase is not aligned with bar" }
Set-ExakitAddonActivity -Message "Checking packages"
$frame = Get-ExakitTableFrame -Table $table
if (-not $frame.Contains("Checking packages") -or $frame.Contains("Downloading the Python")) { throw "stale activity" }
if ($table.Lines -ne $height -or $table.Rows[1].Pct -ne 40) { throw "frame height or progress changed" }
Set-ExakitAddonActivity -Message ("x" * 120)
$frame = Get-ExakitTableFrame -Table $table
foreach ($line in ($frame -split "`r?`n")) { if ($line.Length -gt 80) { throw "activity wraps" } }
$script:ExakitAddonTableRow = 3
Set-ExakitAddonProgress -Id "dash-server" -Pct 40 -Ceiling 65 -Secs 40 -Phase "installing"
Set-ExakitAddonActivity -Message "Starting dashboard service"
$frame = Get-ExakitTableFrame -Table $table
$lines = $frame -split "`r?`n"
$at = 0; while (-not $lines[$at].Contains("dash-server")) { $at++ }
if (-not $lines[$at - 1].Contains("Starting dashboard service") -or $table.Lines -ne $height) { throw "phase failed to follow active bar at constant height" }
Write-Host "PASS phase directly above the active bar, aligned, moves between rows, constant height"
