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
    Write-Host "the two BRD personas the install question offers, each with its own data:"
    $offered = @((Invoke-ExakitPersonaService "picker") | ForEach-Object { ("$_" -split '\|')[0] })
    Check "the question offers both BRD personas in order" $true `
        (($offered -contains 'data-scientist') -and ($offered -contains 'ml-engineer') -and
         ([array]::IndexOf($offered, 'data-scientist') -lt [array]::IndexOf($offered, 'ml-engineer')))
    Check "no persona: the kit's own samples (default=yes)" "tpch,energy,weather" (@(Invoke-ExakitPersonaService "default-datasets") -join "")
    Check "data-scientist: Pharma and Banking" "pharma_trials,banking_complaints" (Get-ExakitPersonaValue "data-scientist" "datasets")
    Check "ml-engineer: Pharma and Banking" "pharma_trials,banking_complaints" (Get-ExakitPersonaValue "ml-engineer" "datasets")
    Check "data-scientist: BRD notebook baseline" "notebook" (Get-ExakitPersonaValue "data-scientist" "addons")
    Check "ml-engineer: BRD notebook and UDF baseline" "notebook,udf-devkit" (Get-ExakitPersonaValue "ml-engineer" "addons")
    Write-Host "several personas ticked together are combined by the service:"
    Check "the title names each" "Data Scientist + ML Engineer" (@(Invoke-ExakitPersonaService "title" "ml-engineer,data-scientist") -join "")
    Check "a known list reads back in the kit's order" "data-scientist,ml-engineer" (Get-ExakitPersona "ml-engineer,data-scientist")
    Check "one unknown among several is not known" "" "$(Get-ExakitPersona 'data-scientist,nope')"
    Clear-Answers; $env:EXAKIT_PERSONA = "data-scientist,ml-engineer"; Set-ExakitPersonaEnv
    Check "their datasets and add-ons together, each once" "pharma_trials,banking_complaints|all|notebook,udf-devkit" (Answers)
    Check "each dataset is named with the personas it is for" "both personas" ((Get-ExakitPersonaDatasetHints)["pharma_trials"])
    Write-Host "the data question (one table) ticks the personas' datasets:"
    function Get-ExakitPendingDatasets { return @([pscustomobject]@{ Id = "tpch"; Label = "TPC-H retail benchmark (~175k rows)" },
                                                  [pscustomobject]@{ Id = "pharma_trials"; Label = "Pharma clinical trials (ClinicalTrials.gov, ~5k)" }) }
    $env:EXAKIT_DATASETS_PRESELECT = "pharma_trials"
    Remove-Item Env:EXAKIT_PERSONA_ACTIVE -ErrorAction SilentlyContinue   # no persona picked: every sample is listed
    New-ExakitDataTable -FinalLabel "Skip"
    $labels = (@($script:UiTable.Rows | ForEach-Object { $_.Label }) -join ";")
    $for = (@($script:UiTable.Rows | ForEach-Object { $_.Col2 }) -join ";")
    Check "the persona's row ticked, the file and external rows after the datasets, each named for its persona in the For column" `
        "3~4~Sample datasets;TPC-H retail benchmark;Pharma clinical trials;Upload a file or folder: CSV/Parquet/JSON;Connect an external source - coming soon;Skip~;;both personas;;;" `
        "$($script:ExakitTableDefaults -join ',')~$($script:ExakitTableRowLocal)~$labels~$for"
    $env:EXAKIT_PERSONA_ACTIVE = "1"
    New-ExakitDataTable -FinalLabel "Skip"
    Check "a persona picked: only its datasets under Sample datasets, then upload, external and Skip" `
        "Sample datasets;Pharma clinical trials;Upload a file or folder: CSV/Parquet/JSON;Connect an external source - coming soon;Skip~1,2" `
        "$((@($script:UiTable.Rows | ForEach-Object { $_.Label })) -join ';')~$($script:ExakitTableDefaults -join ',')"
    Remove-Item Env:EXAKIT_PERSONA_ACTIVE -ErrorAction SilentlyContinue
    $env:EXAKIT_DATASETS_PRESELECT = "tpch,pharma_trials"
    New-ExakitDataTable -FinalLabel "Skip"
    Check "datasets covering every dataset row tick the Sample datasets parent too" "1,2,3" ($script:ExakitTableDefaults -join ",")
    $env:EXAKIT_DATASETS_PRESELECT = "none"
    New-ExakitDataTable -FinalLabel "Skip"
    Check "a persona that wants none: Skip is the default" "6~6" "$($script:ExakitTableDefaults -join ',')~$($script:ExakitTableRowSkip)"
    Remove-Item Env:EXAKIT_DATASETS_PRESELECT -ErrorAction SilentlyContinue
    Write-Host "an explicit answer wins, per variable:"
    Clear-Answers; $env:EXAKIT_PERSONA = "ml-engineer"; Set-ExakitPersonaEnv
    Check "the persona answers everything left open" "pharma_trials,banking_complaints|all|notebook,udf-devkit" (Answers)
    Clear-Answers; $env:EXAKIT_PERSONA = "ml-engineer"; $env:EXAKIT_DATASETS = "pharma_trials"; Set-ExakitPersonaEnv
    Check "EXAKIT_DATASETS wins, the rest stays the persona's" "pharma_trials|all|notebook,udf-devkit" (Answers)
    Clear-Answers; $env:EXAKIT_PERSONA = "data-scientist"; $env:EXAKIT_LOAD_SAMPLE = "0"; $env:EXAKIT_MARKETPLACE_ADDONS = "none"; Set-ExakitPersonaEnv
    Check "EXAKIT_LOAD_SAMPLE=0 and add-ons none win" "|all|none" (Answers)
    Clear-Answers; $env:EXAKIT_PERSONA = "data-scientist"; $env:EXAKIT_SKIP_MCP = "1"; Set-ExakitPersonaEnv
    Check "EXAKIT_SKIP_MCP=1 wins over the persona's clients" "" $env:EXAKIT_MCP_CLIENTS
    Write-Host "the persona service's word, not a guess:"
    Check "an unknown persona names the ones there are" $true (($null -eq (Get-ExakitPersona "nope")) -and ($script:ExakitPersonaProblem -like "*Unknown persona 'nope' (available: data-scientist ml-engineer)*"))
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
    Check "picked on screen: the persona's datasets and add-ons are ticked" "pharma_trials,banking_complaints|notebook" "$($env:EXAKIT_DATASETS_PRESELECT)|$($env:EXAKIT_MARKETPLACE_PRESELECT)"
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
    Set-ExakitManifestValue "persona.id" ""
    Clear-Answers; $env:EXAKIT_PERSONA = "ml-engineer"; Set-ExakitPersonaEnv -NoRecord
    Check "-NoRecord answers without recording" "" "$(Get-ExakitManifestValue 'persona.id')"
    Write-Host "an unknown persona is refused; a known one is recorded:"
    Clear-Answers; $env:EXAKIT_PERSONA = "nope"
    $said = ""
    try { Set-ExakitPersonaEnv } catch { $said = "$_" }
    Check "unknown: refused, naming the ones there are" $true ($said -like "*data-scientist*")
    Clear-Answers; $env:EXAKIT_PERSONA = "data-scientist"; Set-ExakitPersonaEnv
    Check "the manifest records the persona" "data-scientist|install" "$(Get-ExakitManifestValue 'persona.id')|$(Get-ExakitManifestValue 'persona.source')"
    Write-Host "the table menu, taken without asking (UI_TABLE_AUTO):"
    $env:EXAKIT_PERSONA_ACTIVE = "1"; $env:EXAKIT_DATASETS_PRESELECT = "pharma_trials"
    New-ExakitDataTable -FinalLabel "Skip"
    $env:UI_TABLE_AUTO = "1"
    $auto = @(Invoke-ExakitTableMenu -Defaults $script:ExakitTableDefaults -ExclusiveIndex $script:ExakitTableRowSkip)
    Remove-Item Env:UI_TABLE_AUTO -ErrorAction SilentlyContinue
    Check "the defaults are the answer, and it counts as confirmed" "1,2|True" "$($auto -join ',')|$($script:ExakitTableConfirmed)"
    $plain = @(Invoke-ExakitTableMenu -Defaults $script:ExakitTableDefaults -ExclusiveIndex $script:ExakitTableRowSkip)
    Check "...without it and without a console: the same defaults, not confirmed" "1,2|False" "$($plain -join ',')|$($script:ExakitTableConfirmed)"
    foreach ($v in @("EXAKIT_DATASETS_PRESELECT", "EXAKIT_PERSONA_ACTIVE")) { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }

} finally {
    Clear-Answers
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
Write-Host ""
Write-Host "personas-ps: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
