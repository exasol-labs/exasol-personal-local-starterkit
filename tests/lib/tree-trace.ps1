# Driven by tests/lakehouse-picker.sh: the PowerShell twins of the tree group
# rules (Update-ExakitTreeGroup and the Get-ExakitTree* helpers in ui.ps1) on
# the same presses as the shell rules, printed in the same lines:
#   <row> <selection> [<hidden>] <missing>
# then one line per Left/Right case: arrow <dir>:<row>:<selection> -> <what>.
# TREE_SPECS, TREE_PICKABLE, TREE_PRESSES and TREE_ARROWS come from the caller.
param([string]$Root)
$ErrorActionPreference = "Stop"
. (Join-Path $Root "setup/lib/ui.ps1")
$specs = @(ConvertTo-ExakitGroupSpecs -Groups (("" + $env:TREE_SPECS) -split ' '))
$pickable = @(("" + $env:TREE_PICKABLE) -split ' ' | ForEach-Object { [int]$_ })
$radio = @(Get-ExakitTreeRadio -Specs $specs -Pickable $pickable)
$sel = New-Object 'System.Collections.Generic.List[int]'
foreach ($k in (("" + $env:TREE_PRESSES) -split ' ')) {
    $row = [int]$k
    # The menus' order: toggle, then the radio re-pick, then every spec in turn.
    if ($sel.Contains($row)) { [void]$sel.Remove($row) } else { [void]$sel.Add($row) }
    if (-not (Test-ExakitTreeRadioRepick -Selection $sel -Toggled $row -Radio $radio)) {
        foreach ($s in $specs) { Update-ExakitTreeGroup -Selection $sel -Toggled $row -Spec $s -Specs $specs -Pickable $pickable }
    }
    $shown = (@($sel | Sort-Object) -join ",")
    if (-not $shown) { $shown = "-" }
    $hidden = (@(Get-ExakitTreeHidden -Specs $specs -Selection $sel) | Sort-Object) -join " "
    $miss = Get-ExakitTreeMissing -Specs $specs -Selection $sel -Pickable $pickable
    $m = ""
    if ($miss -gt 0) { $m = "" + $miss }
    [Console]::Write(("{0} {1} [{2}] {3}" -f $row, $shown, $hidden, $m) + "`n")
}
foreach ($a in (("" + $env:TREE_ARROWS) -split ' ')) {
    if (-not $a) { continue }
    $parts = $a.Split(":")
    $dir = "Right"
    if ($parts[0] -eq "left") { $dir = "Left" }
    $at = @()
    if ($parts[2] -ne "-") { $at = @($parts[2].Split(",") | ForEach-Object { [int]$_ }) }
    $act = Get-ExakitTreeArrow -Direction $dir -Row ([int]$parts[1]) -Selection $at -Specs $specs -Pickable $pickable
    [Console]::Write(("arrow {0} -> {1}" -f $a, $act) + "`n")
}
