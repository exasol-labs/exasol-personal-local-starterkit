# persona.ps1 - personas: a named set of the answers the installer already
# takes from the environment (EXAKIT_DATASETS, EXAKIT_MCP_CLIENTS,
# EXAKIT_MARKETPLACE_ADDONS). Files: personas\<id>.json (personas\README.md).
# Twin of setup/lib/persona.sh; read that header. An explicit answer always
# wins, per variable.

function Get-ExakitPersonaDir { return (Join-Path (Get-ExakitRepoRoot) "personas") }

function Get-ExakitPersonaIds {
    return @(Get-ChildItem -Path (Get-ExakitPersonaDir) -Filter "*.json" -File -ErrorAction SilentlyContinue |
        Sort-Object Name | ForEach-Object { $_.BaseName })
}

# Get-ExakitPersona - the persona file as an object, or $null.
function Get-ExakitPersona {
    param([string]$Id)
    if (-not $Id) { return $null }
    $path = Join-Path (Get-ExakitPersonaDir) "$Id.json"
    if (-not (Test-Path $path)) { return $null }
    return (Get-Content -Raw -Path $path | ConvertFrom-Json)
}

# Get-ExakitPersonaValue - a string as it is, a list as a comma-separated line.
# Twin of exakit_persona_value.
function Get-ExakitPersonaValue {
    param([string]$Id, [string]$Key)
    $persona = Get-ExakitPersona $Id
    if (-not $persona -or -not $persona.PSObject.Properties[$Key]) { return "" }
    $value = $persona.$Key
    if ($value -is [System.Array]) { return (@($value) -join ",") }
    return "$value"
}

# Set-ExakitPersonaEnv - with EXAKIT_PERSONA set, set the persona's answers for
# every variable the user did not set; Fail on an unknown persona, before
# anything is installed. Records the persona. Twin of exakit_persona_apply_env.
function Set-ExakitPersonaEnv {
    $id = $env:EXAKIT_PERSONA
    if (-not $id) { return }
    if (-not (Get-ExakitPersona $id)) { Fail "Unknown persona '$id' (available: $((Get-ExakitPersonaIds) -join ' '))." }
    $from = @()
    if (-not $env:EXAKIT_DATASETS -and -not $env:EXAKIT_LOAD_SAMPLE) {
        $datasets = Get-ExakitPersonaValue $id "datasets"
        if ($datasets -eq "none") { $env:EXAKIT_LOAD_SAMPLE = "0" }
        elseif ($datasets -eq "all") { $env:EXAKIT_DATASETS = (@(Get-ExakitBundledDatasets | ForEach-Object { $_.Id }) -join ",") }
        elseif ($datasets) { $env:EXAKIT_DATASETS = $datasets }
        $from += "datasets"
    }
    if (-not $env:EXAKIT_MCP_CLIENTS -and $env:EXAKIT_SKIP_MCP -ne "1") {
        $clients = Get-ExakitPersonaValue $id "mcp_clients"
        if ($clients) { $env:EXAKIT_MCP_CLIENTS = $clients; $from += "clients" }
    }
    if (-not $env:EXAKIT_MARKETPLACE_ADDONS) {
        $addons = Get-ExakitPersonaValue $id "addons"
        if ($addons) { $env:EXAKIT_MARKETPLACE_ADDONS = $addons; $from += "add-ons" }
    }
    $ds = if ($env:EXAKIT_DATASETS) { $env:EXAKIT_DATASETS } else { "none" }
    $cl = if ($env:EXAKIT_MCP_CLIENTS) { $env:EXAKIT_MCP_CLIENTS } else { "asked" }
    $ad = if ($env:EXAKIT_MARKETPLACE_ADDONS) { $env:EXAKIT_MARKETPLACE_ADDONS } else { "none" }
    Info "Persona: $(Get-ExakitPersonaValue $id 'title') - datasets $ds; AI clients $cl; add-ons $ad"
    $answered = if ($from.Count) { $from -join " " } else { "nothing (every answer was given explicitly)" }
    Write-ExakitLog "INFO" "persona $id answered: $answered"
    Set-ExakitManifestValue "persona.id" $id
    $source = if ($env:EXAKIT_PERSONA_SOURCE) { $env:EXAKIT_PERSONA_SOURCE } else { "install" }
    Set-ExakitManifestValue "persona.source" $source
    Set-ExakitManifestValue "persona.requested_at" ((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"))
    $env:EXAKIT_PERSONA_ACTIVE = "1"
}
