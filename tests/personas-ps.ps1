#!/usr/bin/env pwsh
# personas-ps.ps1 - the Windows twin of tests/personas.sh: setup/lib/persona.ps1
# reads every persona the way the shell reader does, an explicit answer wins
# per variable, an unknown persona is refused, the persona is recorded. Runs
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
$vars = @("EXAKIT_PERSONA", "EXAKIT_DATASETS", "EXAKIT_MCP_CLIENTS", "EXAKIT_MARKETPLACE_ADDONS", "EXAKIT_LOAD_SAMPLE", "EXAKIT_SKIP_MCP", "EXAKIT_PERSONA_SOURCE")
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
    Write-Host "an explicit answer wins, per variable:"
    Clear-Answers; $env:EXAKIT_PERSONA = "ml-engineer"; Set-ExakitPersonaEnv
    Check "the persona answers everything left open" "pharma_trials,banking_complaints|all|notebook,udf-devkit" (Answers)
    Clear-Answers; $env:EXAKIT_PERSONA = "ml-engineer"; $env:EXAKIT_DATASETS = "pharma_trials"; Set-ExakitPersonaEnv
    Check "EXAKIT_DATASETS wins, the rest stays the persona's" "pharma_trials|all|notebook,udf-devkit" (Answers)
    Clear-Answers; $env:EXAKIT_PERSONA = "data-scientist"; $env:EXAKIT_LOAD_SAMPLE = "0"; $env:EXAKIT_MARKETPLACE_ADDONS = "none"; Set-ExakitPersonaEnv
    Check "EXAKIT_LOAD_SAMPLE=0 and add-ons none win" "|all|none" (Answers)
    Clear-Answers; $env:EXAKIT_PERSONA = "data-scientist"; $env:EXAKIT_SKIP_MCP = "1"; Set-ExakitPersonaEnv
    Check "EXAKIT_SKIP_MCP=1 wins over the persona's clients" "" $env:EXAKIT_MCP_CLIENTS
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
