#!/usr/bin/env pwsh
# personas-ps.ps1 - the Windows twin of tests/personas.sh: setup/lib/persona.ps1
# reads every persona the way the shell reader does, an explicit answer wins
# per variable, several personas combine, the samples table ticks theirs, an
# unknown persona is refused, the persona is recorded. Runs
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
    Write-Host "the three personas the install question offers, each with its own data:"
    Check "the question offers AI Scientist, then ML Engineer" "data-scientist,ml-engineer" `
        ((@(Invoke-ExakitPersonaService "picker") | ForEach-Object { ("$_" -split '\|')[0] }) -join ",")
    Check "no persona: the kit's own samples (default=yes)" "tpch,energy,weather" (@(Invoke-ExakitPersonaService "default-datasets") -join "")
    Check "data-scientist: Pharma and Banking" "pharma_trials,banking_complaints" (Get-ExakitPersonaValue "data-scientist" "datasets")
    Check "ml-engineer: Pharma and Banking" "pharma_trials,banking_complaints" (Get-ExakitPersonaValue "ml-engineer" "datasets")
    Write-Host "several personas ticked together are combined by the service:"
    Check "the title names each" "AI Scientist + ML Engineer" (@(Invoke-ExakitPersonaService "title" "ml-engineer,data-scientist") -join "")
    Check "a known list reads back in the kit's order" "data-scientist,ml-engineer" (Get-ExakitPersona "ml-engineer,data-scientist")
    Check "one unknown among several is not known" "" "$(Get-ExakitPersona 'data-scientist,nope')"
    Clear-Answers; $env:EXAKIT_PERSONA = "data-scientist,ml-engineer"; Set-ExakitPersonaEnv
    Check "their datasets and add-ons together, each once" "pharma_trials,banking_complaints|all|notebook,udf-devkit" (Answers)
    Check "each dataset is named with the personas it is for" "AI Scientist, ML Engineer" ((Get-ExakitPersonaDatasetHints)["pharma_trials"])
    Write-Host "the samples table ticks the personas' datasets:"
    function Get-ExakitPendingDatasets { return @([pscustomobject]@{ Id = "tpch"; Label = "TPC-H retail benchmark (~175k rows)" },
                                                  [pscustomobject]@{ Id = "pharma_trials"; Label = "Pharma clinical trials (ClinicalTrials.gov, ~5k)" }) }
    $env:EXAKIT_DATASETS_PRESELECT = "pharma_trials"
    New-ExakitDataTable -FinalLabel "Skip" -NoLocal
    $labels = (@($script:UiTable.Rows | ForEach-Object { $_.Label }) -join ";")
    $for = (@($script:UiTable.Rows | ForEach-Object { $_.Col2 }) -join ";")
    Check "the persona's row ticked, no file row, each named for its persona in the For column" `
        "3~0~Select All;TPC-H retail benchmark;Pharma clinical trials;Skip~;;AI Scientist, ML Engineer;" `
        "$($script:ExakitTableDefaults -join ',')~$($script:ExakitTableRowLocal)~$labels~$for"
    $env:EXAKIT_DATASETS_PRESELECT = "tpch,pharma_trials"
    New-ExakitDataTable -FinalLabel "Skip" -NoLocal
    Check "datasets covering every row tick Select All too" "1,2,3" ($script:ExakitTableDefaults -join ",")
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
    Set-ExakitPersonaPreselect -Ids "data-scientist"
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
    Check "-NoRecord answers without recording (persona apply asks first)" "" "$(Get-ExakitManifestValue 'persona.id')"
    Write-Host "an unknown persona is refused; a known one is recorded:"
    Clear-Answers; $env:EXAKIT_PERSONA = "nope"
    $said = ""
    try { Set-ExakitPersonaEnv } catch { $said = "$_" }
    Check "unknown: refused, naming the ones there are" $true ($said -like "*data-scientist*")
    Clear-Answers; $env:EXAKIT_PERSONA = "data-scientist"; Set-ExakitPersonaEnv
    Check "the manifest records the persona" "data-scientist|install" "$(Get-ExakitManifestValue 'persona.id')|$(Get-ExakitManifestValue 'persona.source')"
} finally {
    Clear-Answers
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
Write-Host ""
Write-Host "personas-ps: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
