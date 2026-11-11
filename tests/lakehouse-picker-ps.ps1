#!/usr/bin/env pwsh
# lakehouse-picker-ps.ps1 - the PowerShell twin of tests/lakehouse-picker.sh:
# the tree group modes (collapse, one, first) in Read-ExakitCheckboxMenu and
# Invoke-ExakitTableMenu, and the `exakit connect` source menu built on them
# (Invoke-ExakitVsPick): every one of the 9 catalog x files paths, the refused
# Enter, the branch that closes, the disabled rows the cursor skips, the menu's
# 11 entries. Real key sequences, shipping code; the keys come from the test,
# so no console is needed. Runs under Windows PowerShell 5.1 and pwsh.
#
#   pwsh -NoProfile -File tests/lakehouse-picker-ps.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\lakehouse-picker-ps.ps1
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0; $script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -ceq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$expected>, got <$actual>" }
}
. (Join-Path $repo "setup/lib/exakit-common.ps1")
. (Join-Path $repo "setup/lib/virtual-schemas.ps1")

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
# Keys as one string, the replay's letters: j k Space (" ") Enter ("E").
function Press([string]$Keys) {
    $script:Keys.Clear()
    foreach ($c in $Keys.ToCharArray()) {
        if ($c -eq ' ') { $script:Keys.Enqueue(@{ Name = 'Space' }) }
        elseif ($c -eq 'E') { $script:Keys.Enqueue(@{ Name = 'Enter' }) }
        else { $script:Keys.Enqueue(@{ Name = 'Char'; Char = [string]$c }) }
    }
}

Write-Host "== Read-ExakitCheckboxMenu with tree specs =="
# Rows: 1 Alpha, 2 Lake (collapse+one over 3..9), 3 Cat A (collapse+one+first
# over 4..6: 4 a1, 5 a2, 6 a3 disabled), 7 Cat B (collapse over 8, a disabled
# note), 9 Cat C, 10 Skip. Twin of tests/lib/tree-checkbox-scenario.sh.
$cbOptions = @("Alpha", "Lake", "Cat A", "a1", "a2", "!a3 - not yet", "Cat B", "!note: automatic", "Cat C", "Skip")
$cbGroups = @("3:4:6:collapse+one+first", "7:8:8:collapse", "2:3:9:collapse+one")
function Run-Checkbox([string]$Keys) {
    Press $Keys
    $out = @(Read-ExakitCheckboxMenu -Title "Pick" -Options $cbOptions -ExclusiveIndex 10 -Groups $cbGroups 6> $null)
    return ($out -join ',')
}
Check "the first option is pre-picked, and Space on it keeps it" "2,3,4" (Run-Checkbox "j j j E")
Check "Enter with an open group and nothing picked is refused; the cursor skips the hidden rows" "2,7" (Run-Checkbox "j Ejj E")
Check "picking another option moves the radio" "2,3,5" (Run-Checkbox "j j jj E")
Check "unticking the parent clears its subtree" "1" (Run-Checkbox " j  E")
Press " E"
Check "the any/all modes are what they were: ticking an all-parent ticks every child" "1,2,3" `
    ((@(Read-ExakitCheckboxMenu -Title "t" -Options @("All", "x", "y") -GroupParent 1 -GroupFirst 2 -GroupLast 3 -GroupMode all 6> $null)) -join ',')

Write-Host "== exakit connect: the source menu (Invoke-ExakitVsPick) =="
$script:OldCatalog = $false
function Get-ExakitVsCatalog {
    $ids = @(@("postgresql", "PostgreSQL"), @("mysql", "MySQL"), @("sqlserver", "SQL Server"), @("oracle", "Oracle"),
             @("snowflake", "Snowflake"), @("bigquery", "Google BigQuery"), @("s3", "Amazon S3"),
             @("azure-blob", "Azure Blob Storage"), @("databricks", "Databricks"),
             @("lakehouse", "Lakehouse (Iceberg / Delta)"))
    if ($script:OldCatalog) { $ids += , @("iceberg-rest", "Iceberg REST catalog"); $ids += , @("unity", "Unity Catalog (lakehouse engine)") }
    $ids += , @("mongodb", "MongoDB")
    $list = @()
    foreach ($p in $ids) { $list += [pscustomobject]@{ id = $p[0]; name = $p[1]; status = "candidate" } }
    return [pscustomobject]@{ connectors = $list }
}
function Show-ExakitVsClockCheck { }
function Info([string]$M) { }
# The table the menu built, for what it shows.
$script:LastTable = $null
$script:RealTableMenu = ${function:Invoke-ExakitTableMenu}
function Invoke-ExakitTableMenu {
    param([hashtable]$Table = $null, [int[]]$Defaults = @(), [int]$ExclusiveIndex = 0, [string[]]$Groups = @(), [int]$StartRow = 0)
    $script:LastTable = $Table
    $script:LastGroups = $Groups
    return (& $script:RealTableMenu -Table $Table -Defaults $Defaults -ExclusiveIndex $ExclusiveIndex -Groups $Groups -StartRow $StartRow)
}
function Run-Pick([string]$Keys) {
    Press $Keys
    $picked = @(Invoke-ExakitVsPick 6> $null)
    return ("PICKED={0} CATALOG={1} FILES={2}" -f ($picked -join ' '), $script:ExakitVsLakehouseCatalog, $script:ExakitVsLakehouseFiles)
}
$lake = "jjjjjjjjj "
$paths = @(
    @("Iceberg REST + vended (pre-selected)", "j ", "iceberg-rest", "vended"),
    @("Iceberg REST + S3", "j jj ", "iceberg-rest", "s3"),
    @("Iceberg REST + Azure", "j jjj ", "iceberg-rest", "azure"),
    @("Unity + vended (pre-selected)", "jj ", "unity", "vended"),
    @("Unity + S3", "jj jj ", "unity", "s3"),
    @("Unity + Azure", "jj jjj ", "unity", "azure"),
    @("Glue (files automatic: S3)", "jjj ", "glue", "s3"),
    @("No catalog + S3 (the first valid option, pre-selected)", "jjjj ", "none", "s3"),
    @("No catalog + Azure", "jjjj jj ", "none", "azure"))
foreach ($p in $paths) {
    Check $p[0] ("PICKED=lakehouse CATALOG={0} FILES={1}" -f $p[2], $p[3]) (Run-Pick ($lake + $p[1] + "E"))
}
Check "Enter with no catalog is refused; then a catalog answers" "PICKED=lakehouse CATALOG=glue FILES=s3" (Run-Pick ($lake + "Ejjj E"))
Check "the cursor steps over the Google Cloud Storage row to the next catalog" "PICKED=lakehouse CATALOG=unity FILES=vended" (Run-Pick ($lake + "j jjjj E"))
Check "picking another catalog closes the old branch" "PICKED=lakehouse CATALOG=none FILES=s3" (Run-Pick ($lake + "j jjjjjj E"))
Check "unticking Lakehouse drops its catalog and files with it" "PICKED=databricks CATALOG= FILES=" (Run-Pick ($lake + "j k k E"))
Check "Lakehouse goes with other sources" "PICKED=postgresql lakehouse CATALOG=glue FILES=s3" (Run-Pick (" jjjjjjjjj jjj E"))
Check "Enter on Skip picks nothing" "PICKED= CATALOG= FILES=" (Run-Pick "kE")

Write-Host "== the pick reaches the form as presets (Add-ExakitVsPreset) =="
function Run-Preset([string]$Keys) {
    [void](Run-Pick $Keys)
    $script:ExakitVsPreset = @()
    Add-ExakitVsLakehouseHandoff
    return ((@($script:ExakitVsPreset) | ForEach-Object { $_[0] + " " + $_[1] }) -join ';')
}
Check "Unity + Azure" "lakehouse catalog=unity;lakehouse files=azure" (Run-Preset ($lake + "jj jjj E"))
Check "...Glue's implied files too" "lakehouse catalog=glue;lakehouse files=s3" (Run-Preset ($lake + "jjj E"))
Check "...and nothing for a source without a subtree" "" (Run-Preset "jjjjjjjj E")

Write-Host "== the subtree is the lakehouse connector's own settings =="
$st = (Get-Content -Raw -LiteralPath (Join-Path $repo "setup/virtual-schemas/connectors/lakehouse/connector.json") | ConvertFrom-Json).settings
$tree = Get-ExakitVsLakehouseTree
Check "built from connectors/lakehouse/connector.json" ((@($st.catalog.choices) | ForEach-Object { $_.value }) -join ' ') ((@($tree.catalogs) | ForEach-Object { $_.id }) -join ' ')
Check "...a catalog with one valid store (Glue) gets it as automatic" "s3" ((@($tree.catalogs) | Where-Object { $_.id -eq "glue" }).auto)
Check "...a store the engine marks disabled is never picked" "False" ((@($tree.files) | Where-Object { $_.id -eq "gcs" }).supported)

[void](Run-Pick "kE")
$rows = @($script:LastTable.Rows.ToArray())
$top = @($rows | Where-Object { $_.Kind -eq "tee" -or $_.Kind -eq "corner" })
Check "the menu has 11 sources" "11" $top.Count
Check "the subtree's group specs, innermost first" `
    "11:12:15:collapse+one+first 16:17:20:collapse+one+first 21:22:22:collapse 23:24:26:collapse+one+first 10:11:26:collapse+one" `
    ($script:LastGroups -join ' ')
Check "Glue's files are a note nobody can pick" "files: Amazon S3 (automatic)|disabled" ($rows[21].Label + "|" + $rows[21].State)
Check "Google Cloud Storage is a row nobody can pick" "Google Cloud Storage - not supported yet|disabled" ($rows[14].Label + "|" + $rows[14].State)
Check "No catalog offers no vended access" "Amazon S3 / S3-compatible" $rows[23].Label
Check "the files hang three levels deep" "tee-tee-tee|tee-corner-corner" ($rows[11].Kind + "|" + $rows[25].Kind)
$script:OldCatalog = $true
[void](Run-Pick "kE")
$script:OldCatalog = $false
$top = @(@($script:LastTable.Rows.ToArray()) | Where-Object { $_.Kind -eq "tee" -or $_.Kind -eq "corner" })
Check "...also while the catalog still lists iceberg-rest and unity: the one Lakehouse row folds them" "11" $top.Count

Write-Host "== the frame: hidden rows, radio rows, three levels =="
$t = $script:LastTable
$t.Hidden = @(); $t.Radio = @(11, 16, 21, 23, 12, 13, 14)
Set-ExakitTableTicks -Rows @(10, 11, 12) -Table $t
$frame = Get-ExakitTableFrame -Table $t -Cursor 0
$plain = $frame -replace "$([char]27)\[[0-9;]*m", ""
Check "a picked radio row shows its bullet after the connector" $true ($plain.Contains("(" + $script:UiBullet + ") Iceberg REST catalog"))
Check "an unpicked one shows ( )" $true ($plain.Contains("( ) Unity Catalog"))
Check "a third-level row carries both spines" $true ($plain.Contains($script:UiVB + "  " + $script:UiVB + "  " + $script:UiTee + " (" + $script:UiBullet + ") Let the catalog give access"))
$t.Hidden = @(11..26)
$less = ((Get-ExakitTableFrame -Table $t -Cursor 0) -replace "$([char]27)\[[0-9;]*m", "")
Check "a hidden row is not drawn" $false ($less.Contains("Iceberg REST catalog"))
Check "...and takes no line" ($plain.Split("`n").Count - 16) ($less.Split("`n").Count)
$t.Remove("Hidden"); $t.Remove("Radio")

Write-Host ""
Write-Host "passed: $($script:PASS), failed: $($script:FAIL)"
if ($script:FAIL -gt 0) { exit 1 }
