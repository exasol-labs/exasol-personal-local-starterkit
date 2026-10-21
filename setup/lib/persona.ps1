# persona.ps1 - personas: a named set of the answers the installer already
# takes from the environment (EXAKIT_DATASETS, EXAKIT_MCP_CLIENTS,
# EXAKIT_MARKETPLACE_ADDONS). Files: personas\<id>.json (personas\README.md).
# Twin of setup/lib/persona.sh; read that header. The rules live in ONE Python
# service, setup\lib\persona_service.py, which both twins call. An explicit
# answer always wins, per variable.

function Get-ExakitPersonaDir { return (Join-Path (Get-ExakitRepoRoot) "personas") }

# Invoke-ExakitPersonaService - ask the persona service; its output lines, or
# $null when it failed (the reason is in the log). Twin of _exakit_persona_service.
function Invoke-ExakitPersonaService {
    param([Parameter(ValueFromRemainingArguments)]$ServiceArgs)
    $root = Get-ExakitRepoRoot
    $service = Join-Path (Join-Path (Join-Path $root "setup") "lib") "persona_service.py"
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        if (Test-ExakitSystemPython) {
            $out = & python $service $root @ServiceArgs 2>$null
        } else {
            $uv = Install-ExakitUv
            $out = & $uv run --python $script:ManagedPythonVersion --no-project python $service $root @ServiceArgs 2>$null
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($code -ne 0) {
        Write-ExakitLog "WARN" "persona service $($ServiceArgs -join ' ') exited $code"
        return $null
    }
    return @($out | ForEach-Object { "$_" })
}

function Get-ExakitPersonaIds {
    return @(Invoke-ExakitPersonaService "ids" | Where-Object { $_ })
}

# Get-ExakitPersona - the ids, in the kit's order, when every persona named
# exists; else $null. Twin of exakit_persona_known.
function Get-ExakitPersona {
    param([string]$Id)
    if (-not $Id) { return $null }
    $ids = @(Invoke-ExakitPersonaService "check" $Id | Where-Object { $_ })
    if ($ids.Count -eq 0) { return $null }
    return $ids[0]
}

# Get-ExakitPersonaValue - a string as it is, a list as a comma-separated line.
# Twin of exakit_persona_value.
function Get-ExakitPersonaValue {
    param([string]$Id, [string]$Key)
    $out = Invoke-ExakitPersonaService "value" $Id $Key
    if ($null -eq $out) { return "" }
    return (@($out) -join "")
}

# Get-ExakitPersonaDatasetHints - dataset id -> the persona titles it is for.
function Get-ExakitPersonaDatasetHints {
    $hints = @{}
    foreach ($line in @(Invoke-ExakitPersonaService "dataset-hints")) {
        $parts = "$line" -split '\|', 2
        if ($parts.Count -eq 2 -and $parts[0]) { $hints[$parts[0]] = $parts[1] }
    }
    return $hints
}

# Set-ExakitPersonaAnswers - set the service's KEY=value answers; only the
# installer's own variables are taken.
function Set-ExakitPersonaAnswers {
    param([string[]]$Lines)
    $allowed = @("EXAKIT_DATASETS", "EXAKIT_LOAD_SAMPLE", "EXAKIT_MCP_CLIENTS", "EXAKIT_MARKETPLACE_ADDONS", "EXAKIT_NOTEBOOK_FRONTENDS", "EXAKIT_PERSONA")
    foreach ($line in @($Lines)) {
        $parts = "$line" -split '=', 2
        if ($parts.Count -eq 2 -and ($allowed -contains $parts[0])) { Set-Item -Path "env:$($parts[0])" -Value $parts[1] }
    }
}

function Set-ExakitPersonaRecord {
    Set-ExakitManifestValue "persona.id" $env:EXAKIT_PERSONA
    $source = if ($env:EXAKIT_PERSONA_SOURCE) { $env:EXAKIT_PERSONA_SOURCE } else { "install" }
    Set-ExakitManifestValue "persona.source" $source
    Set-ExakitManifestValue "persona.requested_at" ((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"))
}

# Set-ExakitPersonaEnv - with EXAKIT_PERSONA set, set the personas' answers for
# every variable the user did not set; Fail on an unknown persona, before
# anything is installed. Records the persona. Twin of exakit_persona_apply_env.
function Set-ExakitPersonaEnv {
    $id = $env:EXAKIT_PERSONA
    if (-not $id) { return }
    if (-not (Get-ExakitPersona $id)) { Fail "Unknown persona '$id' (available: $((Get-ExakitPersonaIds) -join ' '))." }
    $answers = Invoke-ExakitPersonaService "answers" $id
    if ($null -eq $answers) { Fail "The persona files could not be read - re-run the installer to repair the kit copy." }
    Set-ExakitPersonaAnswers $answers
    $ds = if ($env:EXAKIT_DATASETS) { $env:EXAKIT_DATASETS } else { "none" }
    $cl = if ($env:EXAKIT_MCP_CLIENTS) { $env:EXAKIT_MCP_CLIENTS } else { "asked" }
    $ad = if ($env:EXAKIT_MARKETPLACE_ADDONS) { $env:EXAKIT_MARKETPLACE_ADDONS } else { "none" }
    Info "Persona: $(@(Invoke-ExakitPersonaService 'title' $id) -join '') - datasets $ds; AI clients $cl; add-ons $ad"
    Write-ExakitLog "INFO" "persona $id answered: $(@($answers) -join ' ')"
    Set-ExakitPersonaRecord
    $env:EXAKIT_PERSONA_ACTIVE = "1"
}

# Read-ExakitPersonaQuestion - "What will you use this machine for?": the
# personas the kit offers, the "default": true ones ticked, as many as wanted.
# Twin of exakit_persona_question. Sets $env:EXAKIT_PERSONA.
function Read-ExakitPersonaQuestion {
    $rows = @(Invoke-ExakitPersonaService "picker" | Where-Object { $_ })
    if ($rows.Count -eq 0) { Write-ExakitLog "WARN" "the persona service did not answer; no persona question"; return }
    $ids = New-Object 'System.Collections.Generic.List[string]'
    $labels = New-Object 'System.Collections.Generic.List[string]'
    $defaults = New-Object 'System.Collections.Generic.List[int]'   # the files that say "default": true
    foreach ($row in $rows) {
        $parts = "$row" -split '\|', 4
        [void]$ids.Add($parts[0])
        [void]$labels.Add("$($parts[1]) - $($parts[2])")
        if ($parts.Count -gt 3 -and $parts[3] -eq "1") { [void]$defaults.Add($ids.Count) }
    }
    if ($defaults.Count -eq 0) { [void]$defaults.Add(1) }
    Write-ExakitRule
    Write-ExakitHeading "What will you use this machine for?"
    $picked = @(Read-ExakitCheckboxMenu -Title "Personas - tick one or more" -Options $labels.ToArray() -Defaults $defaults.ToArray())
    $chosen = @($picked | Where-Object { $_ -ge 1 -and $_ -le $ids.Count } | ForEach-Object { $ids[$_ - 1] })
    if ($chosen.Count -eq 0) { $chosen = @($ids[$defaults[0] - 1]) }
    $env:EXAKIT_PERSONA = ($chosen -join ",")
}

# Invoke-ExakitPersonaFlow - the install's persona section, after the parts
# everyone needs: the personas (asked here unless EXAKIT_PERSONA answered it),
# then the data. Picked on screen, their datasets come TICKED in the data
# question and their add-ons ticked in the closing marketplace offer. Twin of
# exakit_persona_flow.
function Invoke-ExakitPersonaFlow {
    param([Parameter(Mandatory)][string]$KitRoot)
    # No database: nothing here can run, and the install already said so.
    if (Test-ExakitSoftFailed "runtime") { return }
    if (-not $env:EXAKIT_PERSONA -and $script:UiFancy -and (Test-ExakitInteractive)) {
        Read-ExakitPersonaQuestion
        if ($env:EXAKIT_PERSONA -and (Get-ExakitPersona $env:EXAKIT_PERSONA)) {
            $answers = @(Invoke-ExakitPersonaService "answers" $env:EXAKIT_PERSONA)
            $ds = ($answers | Where-Object { $_ -like "EXAKIT_DATASETS=*" } | ForEach-Object { $_.Substring(16) } | Select-Object -First 1)
            $ad = ($answers | Where-Object { $_ -like "EXAKIT_MARKETPLACE_ADDONS=*" } | ForEach-Object { $_.Substring(26) } | Select-Object -First 1)
            if ($ds -eq "all") { $ds = (@(Get-ExakitBundledDatasets | ForEach-Object { $_.Id }) -join ",") }
            if ($ds) { $env:EXAKIT_DATASETS_PRESELECT = $ds }
            if ($ad -and $ad -ne "none") { $env:EXAKIT_MARKETPLACE_PRESELECT = $ad }
            Ok "Persona: $(@(Invoke-ExakitPersonaService 'title' $env:EXAKIT_PERSONA) -join '')"
            Write-ExakitLog "INFO" "persona $($env:EXAKIT_PERSONA) picked on screen: datasets $ds; add-ons $ad"
            Set-ExakitPersonaRecord
            $env:EXAKIT_PERSONA_ACTIVE = "1"
        }
    }
    Invoke-ExakitPersonaData -KitRoot $KitRoot
}

# Invoke-ExakitPersonaData - the sample-data section, booked as a soft step.
# Twin of exakit_persona_data.
function Invoke-ExakitPersonaData {
    param([Parameter(Mandatory)][string]$KitRoot)
    if (Test-ExakitSoftFailed "runtime") { Info "Skipping the sample data - it needs the database, which is not installed"; return }
    if (Test-ExakitSoftFailed "exapump") { Info "Skipping the sample data - it is loaded with exapump, which is not installed"; return }
    # YOUR OWN DATA FIRST, THEN THE SAMPLE: the copy out of an old container
    # restores before the sample load can claim its tables.
    if (Get-Command Invoke-LegacyCrossingAfter -ErrorAction SilentlyContinue) { Invoke-LegacyCrossingAfter }
    [void](Invoke-ExakitBestEffort -Component "sample_data" -Repair "exakit data-load" `
        -Label "sample data" `
        -Warning "Sample data load did not finish cleanly." `
        -Body { Request-ExakitDataLoadOffer -KitRoot $KitRoot })
}

# Write-ExakitPersonaMarketplaceNote - after a persona install, the marketplace
# is named once. Twin of exakit_persona_marketplace_note.
function Write-ExakitPersonaMarketplaceNote {
    if (-not $env:EXAKIT_PERSONA_ACTIVE) { return }
    Info "More for any persona in the marketplace: exakit marketplace (dashboards, notebooks, dbt, the scheduler, Python UDFs, JSON tables)"
}
