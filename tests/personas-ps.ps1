#!/usr/bin/env pwsh
# personas-ps.ps1 - the Windows twin of tests/personas.sh: setup/lib/persona.ps1
# reads every persona the way the shell reader does, an explicit answer wins
# per variable, several personas combine, the data table ticks theirs, an
# unknown persona is refused, the persona is recorded; `exakit persona add`
# asks nothing, records the union and hands each step only what is missing
# (the installer's tables, taken without asking, on a console). Runs
# under Windows PowerShell 5.1 and pwsh; a sandboxed kit home.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-persona-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:EXAKIT_HOME = Join-Path $work "home"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
. (Join-Path $repo "setup/lib/exakit-common.ps1")
. (Join-Path $repo "setup/lib/exapump.ps1")
. (Join-Path $repo "setup/lib/persona.ps1")
$script:LogFile = $null
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$expected>, got <$actual>" }
}
function Fail([string]$Msg) { throw "FAIL: $Msg" }
$vars = @("EXAKIT_PERSONA", "EXAKIT_PERSONA_ACTIVE", "EXAKIT_NOTEBOOK_FRONTENDS", "EXAKIT_DATASETS", "EXAKIT_MCP_CLIENTS", "EXAKIT_MARKETPLACE_ADDONS", "EXAKIT_LOAD_SAMPLE", "EXAKIT_SKIP_MCP", "EXAKIT_PERSONA_SOURCE")
function Clear-Answers { foreach ($v in $vars) { Remove-Item "Env:$v" -ErrorAction SilentlyContinue } }
function Answers { return "$($env:EXAKIT_DATASETS)|$($env:EXAKIT_MCP_CLIENTS)|$($env:EXAKIT_MARKETPLACE_ADDONS)" }

try {
    Initialize-ExakitManifest | Out-Null
    Write-Host "every persona reads as its JSON says:"
    foreach ($id in (Get-ExakitPersonaIds)) {
        $doc = Get-Content -Raw (Join-Path (Join-Path $repo "personas") "$id.json") | ConvertFrom-Json
        Check "$($id): the id is the file name" $id $doc.id
        Check "$($id): datasets" ((@($doc.datasets)) -join ",") (Get-ExakitPersonaValue $id "datasets")
        Check "$($id): add-ons" ((@($doc.addons)) -join ",") (Get-ExakitPersonaValue $id "addons")
    }
    Write-Host "the personas the install question offers (the ML Engineer is disabled on this branch, not removed):"
    $offered = @((Invoke-ExakitPersonaService "picker") | ForEach-Object { ("$_" -split '\|')[0] })
    Check "the question offers the Data Scientist and General" "data-scientist,general" ($offered -join ",")
    $mlDoc = Get-Content -Raw (Join-Path (Join-Path $repo "personas") "ml-engineer.json") | ConvertFrom-Json
    Check "ml-engineer: kept, hidden (visible: false)" $false $mlDoc.visible
    Clear-Answers; $env:EXAKIT_PERSONA = "ml-engineer"
    $said = ""
    try { Set-ExakitPersonaEnv } catch { $said = "$_" }
    Check "ml-engineer: asking for it by name is refused, nothing answered" $true (($said -like "*Persona 'ml-engineer' is disabled*") -and -not $env:EXAKIT_DATASETS)
    Check "no persona: the kit's own samples (default=yes)" "tpch,energy,weather" (@(Invoke-ExakitPersonaService "default-datasets") -join "")
    Check "data-scientist: the Walmart, Amazon and fraud datasets" "walmart_sales,amazon_sales,fraud_transactions" (Get-ExakitPersonaValue "data-scientist" "datasets")
    Check "ml-engineer: the Walmart and Amazon sales datasets" "walmart_sales,amazon_sales" (Get-ExakitPersonaValue "ml-engineer" "datasets")
    Check "data-scientist: Dash Server first, then the notebook" "dash-server,notebook" (Get-ExakitPersonaValue "data-scientist" "addons")
    Check "ml-engineer: BRD notebook and UDF baseline" "notebook,udf-devkit" (Get-ExakitPersonaValue "ml-engineer" "addons")
    Write-Host "several personas ticked together are combined by the service:"
    Check "the title names each" "Data Scientist + General" (@(Invoke-ExakitPersonaService "title" "general,data-scientist") -join "")
    Check "a known list reads back in the kit's order" "data-scientist,general" (Get-ExakitPersona "general,data-scientist")
    Check "one unknown among several is not known" "" "$(Get-ExakitPersona 'data-scientist,nope')"
    Clear-Answers; $env:EXAKIT_PERSONA = "data-scientist,general"; Set-ExakitPersonaEnv
    Check "their datasets and add-ons together, each once" "walmart_sales,amazon_sales,fraud_transactions,tpch,energy,weather|all|dash-server,notebook" (Answers)
    Check "each dataset is named with the personas it is for (a hidden one is not named)" "Data Scientist" ((Get-ExakitPersonaDatasetHints)["amazon_sales"])
    Write-Host "the data question (one table) ticks the personas' datasets:"
    function Get-ExakitPendingDatasets { return @([pscustomobject]@{ Id = "tpch"; Label = "TPC-H retail benchmark (~175k rows)"; Description = "Orders, customers, parts" },
                                                  [pscustomobject]@{ Id = "amazon_sales"; Label = "Amazon sales (Amazon.in fashion orders, Apr-Jun 2022, ~129k lines)"; Description = "Online orders" }) }
    $env:EXAKIT_DATASETS_PRESELECT = "amazon_sales"
    Remove-Item Env:EXAKIT_PERSONA_ACTIVE -ErrorAction SilentlyContinue   # no persona picked: every sample is listed
    New-ExakitDataTable -FinalLabel "Skip"
    $labels = (@($script:UiTable.Rows | ForEach-Object { $_.Label }) -join ";")
    $for = (@($script:UiTable.Rows | ForEach-Object { $_.Col2 }) -join ";")
    Check "the persona's row ticked, the file and external rows after the datasets, each described in the Description column" `
        "3~4~Sample datasets;TPC-H retail benchmark;Amazon sales;Upload a file or folder: CSV/Parquet/JSON;Connect an external source - coming soon;Skip~;Orders, customers, parts;Online orders;;;" `
        "$($script:ExakitTableDefaults -join ',')~$($script:ExakitTableRowLocal)~$labels~$for"
    $env:EXAKIT_PERSONA_ACTIVE = "1"
    New-ExakitDataTable -FinalLabel "Skip"
    Check "a persona picked: only its datasets under Sample datasets, then upload, external and Skip" `
        "Sample datasets;Amazon sales;Upload a file or folder: CSV/Parquet/JSON;Connect an external source - coming soon;Skip~1,2" `
        "$((@($script:UiTable.Rows | ForEach-Object { $_.Label })) -join ';')~$($script:ExakitTableDefaults -join ',')"
    Remove-Item Env:EXAKIT_PERSONA_ACTIVE -ErrorAction SilentlyContinue
    $env:EXAKIT_DATASETS_PRESELECT = "tpch,amazon_sales"
    New-ExakitDataTable -FinalLabel "Skip"
    Check "datasets covering every dataset row tick the Sample datasets parent too" "1,2,3" ($script:ExakitTableDefaults -join ",")
    $env:EXAKIT_DATASETS_PRESELECT = "none"
    New-ExakitDataTable -FinalLabel "Skip"
    Check "a persona that wants none: Skip is the default" "6~6" "$($script:ExakitTableDefaults -join ',')~$($script:ExakitTableRowSkip)"
    Remove-Item Env:EXAKIT_DATASETS_PRESELECT -ErrorAction SilentlyContinue
    Write-Host "an explicit answer wins, per variable:"
    Clear-Answers; $env:EXAKIT_PERSONA = "data-scientist"; Set-ExakitPersonaEnv
    Check "the persona answers everything left open" "walmart_sales,amazon_sales,fraud_transactions|all|dash-server,notebook" (Answers)
    Clear-Answers; $env:EXAKIT_PERSONA = "data-scientist"; $env:EXAKIT_DATASETS = "amazon_sales"; Set-ExakitPersonaEnv
    Check "EXAKIT_DATASETS wins, the rest stays the persona's" "amazon_sales|all|dash-server,notebook" (Answers)
    Clear-Answers; $env:EXAKIT_PERSONA = "data-scientist"; $env:EXAKIT_LOAD_SAMPLE = "0"; $env:EXAKIT_MARKETPLACE_ADDONS = "none"; Set-ExakitPersonaEnv
    Check "EXAKIT_LOAD_SAMPLE=0 and add-ons none win" "|all|none" (Answers)
    Clear-Answers; $env:EXAKIT_PERSONA = "data-scientist"; $env:EXAKIT_SKIP_MCP = "1"; Set-ExakitPersonaEnv
    Check "EXAKIT_SKIP_MCP=1 wins over the persona's clients" "" $env:EXAKIT_MCP_CLIENTS
    Write-Host "the persona service's word, not a guess:"
    Check "an unknown persona names the ones there are" $true (($null -eq (Get-ExakitPersona "nope")) -and ($script:ExakitPersonaProblem -like "*Unknown persona 'nope' (available: data-scientist general)*"))
    Check "two words are not two personas" $null (Get-ExakitPersona "ml-engineer ml-engineer")
    Write-Host "the install's persona section:"
    foreach ($v in @("EXAKIT_DATASETS_PRESELECT", "EXAKIT_MARKETPLACE_PRESELECT")) { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
    Clear-Answers
    function Test-ExakitInteractive { return $false }
    function Invoke-ExakitPersonaData { param($KitRoot) }
    Invoke-ExakitPersonaFlow -KitRoot $repo
    Check "no console, no persona: the default personas' datasets, nothing recorded" "tpch,energy,weather||" "$($env:EXAKIT_DATASETS_PRESELECT)|$($env:EXAKIT_MARKETPLACE_PRESELECT)|$($env:EXAKIT_PERSONA)"
    Remove-Item Env:EXAKIT_DATASETS_PRESELECT -ErrorAction SilentlyContinue
    $env:EXAKIT_PERSONA = "data-scientist"
    Invoke-ExakitPersonaFlow -KitRoot $repo -Phase selected
    Check "picked on screen: the persona's datasets and add-ons are ticked" "walmart_sales,amazon_sales,fraud_transactions|dash-server,notebook" "$($env:EXAKIT_DATASETS_PRESELECT)|$($env:EXAKIT_MARKETPLACE_PRESELECT)"
    foreach ($v in @("EXAKIT_DATASETS_PRESELECT", "EXAKIT_MARKETPLACE_PRESELECT")) { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
    $env:EXAKIT_PERSONA_ACTIVE = "1"
    $note = (Write-ExakitPersonaMarketplaceNote 6>&1 | Out-String)
    Check "no persona offer, no second marketplace pointer" "" $note.Trim()
    Remove-Item Env:EXAKIT_PERSONA_ACTIVE -ErrorAction SilentlyContinue
    Set-ExakitManifestValue "persona.id" "ml-engineer"
    $script:menuDefaults = $null
    function Read-ExakitCheckboxMenu { param($Title, $Options, $Defaults) $script:menuDefaults = ($Defaults -join ","); return @() }
    function Write-ExakitRule { }
    function Write-ExakitHeading { param($Text) }
    Read-ExakitPersonaQuestion
    Check "a re-run ticks the persona this kit was set up as" "2" $script:menuDefaults
    Write-Host "on Windows the question stays in the flow, drawn by the kit's own menu (Textual would go full screen):"
    $onWindows = $true
    if (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) { $onWindows = [bool]$IsWindows }
    Check "Textual draws inline only off Windows" (-not $onWindows) (Test-ExakitTextualInline)
    $script:menuDefaults = $null; $script:textualAsked = $false
    & {
        # Stubs in a scope of their own: they end with it, and the kit's functions they stand in for remain.
        function Test-ExakitInteractive { return $true }
        function Test-ExakitStdoutIsTerminal { return $true }
        function Test-ExakitTextualInline { return $false }
        # Only the Textual path turns the spinner ("Opening the question") before it starts.
        function Start-ExakitSpinner { param($Message) $script:textualAsked = $true; throw "Textual was asked for" }
        function Warn2 { param($Message) }
        Read-ExakitPersonaQuestion
    }
    Check "an interactive Windows terminal gets the kit's menu" "2" $script:menuDefaults
    Check "...and Textual is never started" $false $script:textualAsked
    Set-ExakitManifestValue "persona.id" ""
    Clear-Answers; $env:EXAKIT_PERSONA = "data-scientist"; Set-ExakitPersonaEnv -NoRecord
    Check "-NoRecord answers without recording" "" "$(Get-ExakitManifestValue 'persona.id')"
    Write-Host "an unknown persona is refused; a known one is recorded:"
    Clear-Answers; $env:EXAKIT_PERSONA = "nope"
    $said = ""
    try { Set-ExakitPersonaEnv } catch { $said = "$_" }
    Check "unknown: refused, naming the ones there are" $true ($said -like "*data-scientist*")
    Clear-Answers; $env:EXAKIT_PERSONA = "data-scientist"; Set-ExakitPersonaEnv
    Check "the manifest records the persona" "data-scientist|install" "$(Get-ExakitManifestValue 'persona.id')|$(Get-ExakitManifestValue 'persona.source')"
    Write-Host "the table menu, taken without asking (UI_TABLE_AUTO):"
    $env:EXAKIT_PERSONA_ACTIVE = "1"; $env:EXAKIT_DATASETS_PRESELECT = "amazon_sales"
    New-ExakitDataTable -FinalLabel "Skip"
    $env:UI_TABLE_AUTO = "1"
    $auto = @(Invoke-ExakitTableMenu -Defaults $script:ExakitTableDefaults -ExclusiveIndex $script:ExakitTableRowSkip)
    Remove-Item Env:UI_TABLE_AUTO -ErrorAction SilentlyContinue
    Check "the defaults are the answer, and it counts as confirmed" "1,2|True" "$($auto -join ',')|$($script:ExakitTableConfirmed)"
    $plain = @(Invoke-ExakitTableMenu -Defaults $script:ExakitTableDefaults -ExclusiveIndex $script:ExakitTableRowSkip)
    Check "...without it and without a console: the same defaults, not confirmed" "1,2|False" "$($plain -join ',')|$($script:ExakitTableConfirmed)"
    foreach ($v in @("EXAKIT_DATASETS_PRESELECT", "EXAKIT_PERSONA_ACTIVE")) { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }

    Write-Host "the data table's Description column is read from each dataset.conf, not stubbed (audit QAT-06):"
    $bundled = @(Get-ExakitBundledDatasets)
    foreach ($conf in (Get-ChildItem -Path (Join-Path $repo "data/datasets/*/dataset.conf"))) {
        $id = ((Get-Content $conf | Where-Object { $_ -like "id=*" } | Select-Object -First 1) -replace '^id=', '')
        $want = ((Get-Content $conf | Where-Object { $_ -like "description=*" } | Select-Object -First 1) -replace '^description=', '')
        if (-not $id) { continue }
        $row = $bundled | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        Check "$($id): the Windows reader carries its description" $want ("" + $row.Description)
    }

    Write-Host "add-on About text and GitHub names (audit SEC-10, SEC-11, SEC-18):"
    $c1 = [string][char]0x9B; $rlo = [string][char]0x202E; $fsi = [string][char]0x2068
    Check "C1 controls and bidi overrides are stripped" "Safe [31mred evil text" (Convert-ExakitAboutText "Safe$c1[31mred $($rlo)evil$fsi text")
    Check "a name ending in a newline is not a name" $false ("exasol`n" -match '^[A-Za-z0-9._-]+\z')
    $common = Get-Content -Raw (Join-Path $repo "setup/lib/exakit-common.ps1")
    Check "no owner/name or name check anchors with a bare dollar" $false $common.Contains("'^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'")
    $aboutDir = Get-ExakitAboutCacheDir
    New-Item -ItemType Directory -Force -Path $aboutDir | Out-Null
    $esc = [string][char]27
    Set-Content -Path (Join-Path $aboutDir "dash-server.txt") -Value @("planted$esc[2J text", "name", "https://github.com/a/b", "false", (Get-ExakitAddonRepo "dash-server")) -Encoding UTF8
    Check "a cached About is cleaned again when it is read" "planted text" (Get-ExakitMarketplaceAddonDescription "dash-server")
    Set-Content -Path (Join-Path $aboutDir "dash-server.txt") -Value @("Old repo About", "old-name", "https://github.com/someone/old-name", "false", "someone/old-name") -Encoding UTF8
    Check "a cache from the add-on's previous repository is not shown (DAY-05)" $false ((Get-ExakitMarketplaceAddonDescription "dash-server") -like "Old repo About*")

    Write-Host "exakit persona add with no id: the persona question, then the newly ticked:"
    $dispatch = Get-Content -Raw (Join-Path $repo "setup/exakit.ps1")
    Check "the dispatcher sends a bare add to the menu" $true $dispatch.Contains('if ($RestArgs.Count -eq 1 -and $RestArgs[0] -eq ''add'') {')
    function Test-ExakitInteractive { $true }
    function Get-ExakitManifestValue { param($Key) if ($Key -eq "persona.id") { "data-scientist" } }
    function Read-ExakitPersonaQuestion { $env:EXAKIT_PERSONA = $script:Ticked }
    function Invoke-ExakitMarketplaceCli { param($Script, $CmdArgs) $script:Added = "$Script $($CmdArgs[0]) $($CmdArgs[1])" }
    $script:Ticked = "data-scientist,general"; $script:Added = ""
    Invoke-ExakitPersonaAddMenu -Cli "exakit.ps1"
    Check "only the newly ticked persona is added" "persona_apply add general" $script:Added
    $script:Ticked = "data-scientist"; $script:Added = ""
    Invoke-ExakitPersonaAddMenu -Cli "exakit.ps1"
    Check "nothing new ticked adds nothing" "" $script:Added
    Remove-Item Env:EXAKIT_PERSONA -ErrorAction SilentlyContinue

} finally {
    Clear-Answers
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
Write-Host ""
Write-Host "personas-ps: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
