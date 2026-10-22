# persona.ps1 - personas: a named set of the answers the installer already
# takes from the environment (EXAKIT_DATASETS, EXAKIT_MCP_CLIENTS,
# EXAKIT_MARKETPLACE_ADDONS). Files: personas\<id>.json (personas\README.md).
# Twin of setup/lib/persona.sh; read that header. The rules live in ONE Python
# service, setup\lib\persona_service.py, which both twins call. An explicit
# answer always wins, per variable.

function Get-ExakitPersonaDir { return (Join-Path (Get-ExakitRepoRoot) "personas") }

# Get-ExakitPersonaPython - the Python 3.9+ on PATH the service runs on, or
# $null (then uv's managed one is used). The service is standard library only.
$script:ExakitPersonaPython = $null
function Get-ExakitPersonaPython {
    if ($null -ne $script:ExakitPersonaPython) { return $script:ExakitPersonaPython }
    $script:ExakitPersonaPython = ""
    if (Get-Command python -ErrorAction SilentlyContinue) {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $ok = & python -c "import sys; print(sys.version_info[:2] >= (3, 9))" 2>$null
            if ($LASTEXITCODE -eq 0 -and ("$ok").Trim() -eq "True") { $script:ExakitPersonaPython = "python" }
        } catch {
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
    }
    return $script:ExakitPersonaPython
}

# Invoke-ExakitPersonaService - ask the persona service; its output lines, or
# $null when it failed. Why it failed (its own message: an unknown or invalid
# persona) is in $script:ExakitPersonaServiceError. Read as UTF-8, whatever the
# console's code page. Twin of _exakit_persona_service.
function Invoke-ExakitPersonaService {
    param([Parameter(ValueFromRemainingArguments)]$ServiceArgs)
    $root = Get-ExakitRepoRoot
    $service = Join-Path (Join-Path (Join-Path $root "setup") "lib") "persona_service.py"
    $previousErrorActionPreference = $ErrorActionPreference
    $previousEncoding = [Console]::OutputEncoding
    $script:ExakitPersonaServiceError = ""
    $code = 1
    $out = @()
    try {
        $ErrorActionPreference = "Continue"
        try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
        $python = Get-ExakitPersonaPython
        if ($python) {
            $raw = @(& $python $service $root @ServiceArgs 2>&1)
        } else {
            $uv = Install-ExakitUv
            $raw = @(& $uv run --python $script:ManagedPythonVersion --no-project python $service $root @ServiceArgs 2>&1)
        }
        $code = $LASTEXITCODE
        $out = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
        $errs = @($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" } |
            Where-Object { $_ -and -not $_.StartsWith("Ignored persona file") })
        if ($errs.Count) { $script:ExakitPersonaServiceError = $errs[-1] }
    } catch {
        $script:ExakitPersonaServiceError = "$_"
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
        try { [Console]::OutputEncoding = $previousEncoding } catch { }
    }
    if ($code -ne 0) {
        Write-ExakitLog "WARN" "persona service $($ServiceArgs -join ' ') exited $($code): $($script:ExakitPersonaServiceError)"
        return $null
    }
    return $out
}

function Get-ExakitPersonaIds {
    return @(Invoke-ExakitPersonaService "ids" | Where-Object { $_ })
}

# Get-ExakitPersona - the ids, in the kit's order, when every persona named
# exists and its file is valid; else $null, with why in
# $script:ExakitPersonaProblem (the service's words). Twin of exakit_persona_known.
function Get-ExakitPersona {
    param([string]$Id)
    $script:ExakitPersonaProblem = ""
    if (-not $Id) {
        $script:ExakitPersonaProblem = "Name a persona: $((Get-ExakitPersonaIds) -join ' ')"
        return $null
    }
    $ids = @(Invoke-ExakitPersonaService "check" $Id | Where-Object { $_ })
    if ($ids.Count -gt 0) { return $ids[0] }
    $script:ExakitPersonaProblem = $script:ExakitPersonaServiceError
    if (-not $script:ExakitPersonaProblem) { $script:ExakitPersonaProblem = "The persona files could not be read - the kit needs Python 3 for them (see the log)" }
    return $null
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

# Set-ExakitPersonaEnv [-NoRecord] - with EXAKIT_PERSONA set, set the personas'
# answers for every variable the user did not set; Fail on an unknown or invalid
# persona, before anything is installed. Records the persona unless -NoRecord.
# Twin of exakit_persona_apply_env.
function Set-ExakitPersonaEnv {
    param([switch]$NoRecord)
    $id = $env:EXAKIT_PERSONA
    if (-not $id) { return }
    if (-not (Get-ExakitPersona $id)) { Fail $script:ExakitPersonaProblem }
    $answers = Invoke-ExakitPersonaService "answers" $id
    if ($null -eq $answers) { Fail "The persona files could not be read - re-run the installer to repair the kit copy." }
    Set-ExakitPersonaAnswers $answers
    $ds = if ($env:EXAKIT_DATASETS) { $env:EXAKIT_DATASETS } else { "none" }
    $cl = if ($env:EXAKIT_MCP_CLIENTS) { $env:EXAKIT_MCP_CLIENTS } else { "asked" }
    $ad = if ($env:EXAKIT_MARKETPLACE_ADDONS) { $env:EXAKIT_MARKETPLACE_ADDONS } else { "none" }
    Info "Persona: $(@(Invoke-ExakitPersonaService 'title' $id) -join '') - datasets $ds; AI clients $cl; add-ons $ad"
    Write-ExakitLog "INFO" "persona $id answered: $(@($answers) -join ' ')"
    if (-not $NoRecord) { Set-ExakitPersonaRecord }
    $env:EXAKIT_PERSONA_ACTIVE = "1"
}

# Read-ExakitPersonaQuestion - "What will you use this machine for?": the
# personas the kit offers, as many as wanted, or None. Ticked to begin with: the
# ones this kit was set up as (a re-run), else the "default": true ones, else
# None.
# Twin of exakit_persona_question. Sets $env:EXAKIT_PERSONA.
function Read-ExakitPersonaQuestion {
    $rows = @(Invoke-ExakitPersonaService "picker" | Where-Object { $_ })
    if ($rows.Count -eq 0) { Write-ExakitLog "WARN" "the persona service did not answer; no persona question"; return }
    $ids = New-Object 'System.Collections.Generic.List[string]'
    $labels = New-Object 'System.Collections.Generic.List[string]'
    $defaults = New-Object 'System.Collections.Generic.List[int]'   # the files that say "default": true
    $recorded = New-Object 'System.Collections.Generic.List[int]'   # ...or the ones a previous run recorded
    $was = @("$(Get-ExakitManifestValue 'persona.id')" -split ',')
    foreach ($row in $rows) {
        $parts = "$row" -split '\|', 4
        [void]$ids.Add($parts[0])
        [void]$labels.Add("$($parts[1]) - $($parts[2])")
        if ($parts.Count -gt 3 -and $parts[3] -eq "1") { [void]$defaults.Add($ids.Count) }
        if ($was -ccontains $parts[0]) { [void]$recorded.Add($ids.Count) }
    }
    # The last row is the kit on its own, no persona - exclusive, and ticked to
    # begin with unless a file says "default": true or a previous run recorded one.
    $none = $ids.Count + 1
    [void]$labels.Add("None - just the kit, with the TPC-H, energy and weather samples")
    if ($recorded.Count -gt 0) { $defaults = $recorded }
    if ($defaults.Count -eq 0) { [void]$defaults.Add($none) }
    Write-ExakitRule
    Write-ExakitHeading "What will you use this machine for?"
    $picked = @(Read-ExakitCheckboxMenu -Title "Personas - tick one or more, or None" -Options $labels.ToArray() -Defaults $defaults.ToArray() -ExclusiveIndex $none)
    $chosen = @($picked | Where-Object { $_ -ge 1 -and $_ -le $ids.Count } | ForEach-Object { $ids[$_ - 1] })
    if ($chosen.Count -eq 0) { Remove-Item Env:EXAKIT_PERSONA -ErrorAction SilentlyContinue; return }
    $env:EXAKIT_PERSONA = ($chosen -join ",")
}

# Invoke-ExakitPersonaFlow - the install's persona section, after the parts
# everyone needs: the personas (asked here unless EXAKIT_PERSONA answered it),
# then the data. Picked on screen, their datasets come TICKED in the data
# question and their add-ons ticked in the closing marketplace offer. No
# persona (None picked, or nobody to ask): the kit's own default datasets.
# Twin of exakit_persona_flow.
function Invoke-ExakitPersonaFlow {
    param([Parameter(Mandatory)][string]$KitRoot)
    # No database or no exapump: nothing here can run, so nobody is asked.
    if (Test-ExakitSoftFailed "runtime") { return }
    if (Test-ExakitSoftFailed "exapump") { Invoke-ExakitPersonaData -KitRoot $KitRoot; return }
    if (-not $env:EXAKIT_PERSONA) {
        if ($script:UiFancy -and (Test-ExakitInteractive) -and -not (Test-ExakitPersonaAllAnswered)) {
            Read-ExakitPersonaQuestion
            if ($env:EXAKIT_PERSONA -and (Get-ExakitPersona $env:EXAKIT_PERSONA)) {
                Set-ExakitPersonaPreselect -Ids $env:EXAKIT_PERSONA
                Ok "Persona: $(@(Invoke-ExakitPersonaService 'title' $env:EXAKIT_PERSONA) -join '')"
                Write-ExakitLog "INFO" "persona $($env:EXAKIT_PERSONA) picked on screen: datasets $($env:EXAKIT_DATASETS_PRESELECT); add-ons $($env:EXAKIT_MARKETPLACE_PRESELECT)"
                Set-ExakitPersonaRecord
                $env:EXAKIT_PERSONA_ACTIVE = "1"
            } elseif ($env:EXAKIT_PERSONA) {
                Warn2 "$($script:ExakitPersonaProblem) - carrying on without a persona"
                Remove-Item Env:EXAKIT_PERSONA -ErrorAction SilentlyContinue
            }
        } else {
            Set-ExakitPersonaKitDefaults
        }
    }
    # Asked, and the answer was None: the kit's own default datasets.
    if (-not $env:EXAKIT_PERSONA -and -not $env:EXAKIT_DATASETS_PRESELECT) { Set-ExakitPersonaKitDefaults }
    Invoke-ExakitPersonaData -KitRoot $KitRoot
}

# Set-ExakitPersonaKitDefaults - no persona: the data question ticks the
# datasets the kit loads on its own (default=yes in their dataset.conf).
# Nothing is recorded. Twin of _exakit_persona_kit_defaults.
function Set-ExakitPersonaKitDefaults {
    $ds = (@(Invoke-ExakitPersonaService "default-datasets") -join "").Trim()
    if ($ds) { $env:EXAKIT_DATASETS_PRESELECT = $ds }
}

# Test-ExakitPersonaAllAnswered - everything the persona question would answer
# was answered in the environment already. Twin of _exakit_persona_all_answered.
function Test-ExakitPersonaAllAnswered {
    $data = ($env:EXAKIT_DATASETS -or $env:EXAKIT_LOAD_SAMPLE -eq "0" -or $env:EXAKIT_LOAD_SAMPLE -eq "1")
    return [bool]($data -and $env:EXAKIT_MARKETPLACE_ADDONS)
}

# Set-ExakitPersonaPreselect - what the menus tick for these personas:
# EXAKIT_DATASETS_PRESELECT (dataset ids, or "none") and, unless -DatasetsOnly,
# EXAKIT_MARKETPLACE_PRESELECT (add-on ids, or "all"). Twin of
# _exakit_persona_preselect.
function Set-ExakitPersonaPreselect {
    param([Parameter(Mandatory)][string]$Ids, [switch]$DatasetsOnly)
    $answers = @(Invoke-ExakitPersonaService "answers" $Ids)
    $ds = ($answers | Where-Object { $_ -like "EXAKIT_DATASETS=*" } | ForEach-Object { $_.Substring(16) } | Select-Object -First 1)
    if ($answers -contains "EXAKIT_LOAD_SAMPLE=0") { $ds = "none" }
    $ad = ($answers | Where-Object { $_ -like "EXAKIT_MARKETPLACE_ADDONS=*" } | ForEach-Object { $_.Substring(26) } | Select-Object -First 1)
    if ($ds) { $env:EXAKIT_DATASETS_PRESELECT = $ds }
    if ($DatasetsOnly) { return }
    if ($ad -and $ad -ne "none") { $env:EXAKIT_MARKETPLACE_PRESELECT = $ad }
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

# Write-ExakitPersonaMarketplaceNote - after the closing offer showed only the
# personas' add-ons, the rest of the marketplace is named once. Twin of
# exakit_persona_marketplace_note.
function Write-ExakitPersonaMarketplaceNote {
    if (-not $env:EXAKIT_PERSONA_ACTIVE -or -not $env:EXAKIT_MARKETPLACE_PRESELECT) { return }
    Info "More for any persona in the marketplace: exakit marketplace (dashboards, notebooks, dbt, the scheduler, Python UDFs, JSON tables)"
}

# Show-ExakitPersonaPlan - what these personas bring and what of it is still
# pending here: their datasets (loaded or not) and add-ons (installed or not).
# Read-only. Twin of exakit_persona_plan.
function Show-ExakitPersonaPlan {
    param([Parameter(Mandatory)][string]$Ids, [switch]$Json)
    # The personas' own answers, not this process's: what they bring, whatever was set.
    $names = @("EXAKIT_DATASETS", "EXAKIT_LOAD_SAMPLE", "EXAKIT_MARKETPLACE_ADDONS", "EXAKIT_MCP_CLIENTS", "EXAKIT_NOTEBOOK_FRONTENDS", "EXAKIT_SKIP_MCP")
    $saved = @{}
    foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n, "Process"); [Environment]::SetEnvironmentVariable($n, $null, "Process") }
    try { $answers = @(Invoke-ExakitPersonaService "answers" $Ids) }
    finally { foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n], "Process") } }
    $ds = @($answers | Where-Object { $_ -like "EXAKIT_DATASETS=*" } | ForEach-Object { $_.Substring(16) -split ',' } | Where-Object { $_ })
    $ad = ($answers | Where-Object { $_ -like "EXAKIT_MARKETPLACE_ADDONS=*" } | ForEach-Object { $_.Substring(26) } | Select-Object -First 1)
    if (-not $ad -or $ad -eq "none") { $addons = @() }
    elseif ($ad -eq "all") { $addons = @(Get-ExakitMarketplaceAddons | ForEach-Object { $_.Id }) }
    else { $addons = @($ad -split ',' | Where-Object { $_ }) }
    $pendingIds = @(Get-ExakitPendingDatasets | ForEach-Object { $_.Id })
    $installed = @(Get-ExakitMarketplaceInstalledAddons)
    $plan = [ordered]@{
        persona  = $Ids
        datasets = [ordered]@{ loaded = @($ds | Where-Object { $pendingIds -cnotcontains $_ }); pending = @($ds | Where-Object { $pendingIds -ccontains $_ }) }
        addons   = [ordered]@{ installed = @($addons | Where-Object { $installed -ccontains $_ }); pending = @($addons | Where-Object { $installed -cnotcontains $_ }) }
    }
    $plan.nothing_pending = ($plan.datasets.pending.Count -eq 0 -and $plan.addons.pending.Count -eq 0)
    if ($Json) { Write-Output ($plan | ConvertTo-Json -Depth 4); return }
    $none = "none"
    Write-Host "$(@(Invoke-ExakitPersonaService 'title' $Ids) -join '') ($Ids)"
    Write-Host ("  {0,-12} loaded: {1}   pending: {2}" -f "Datasets", $(if ($plan.datasets.loaded.Count) { $plan.datasets.loaded -join ' ' } else { $none }), $(if ($plan.datasets.pending.Count) { $plan.datasets.pending -join ' ' } else { $none }))
    Write-Host ("  {0,-12} installed: {1}   pending: {2}" -f "Add-ons", $(if ($plan.addons.installed.Count) { $plan.addons.installed -join ' ' } else { $none }), $(if ($plan.addons.pending.Count) { $plan.addons.pending -join ' ' } else { $none }))
    if ($plan.nothing_pending) { Ok "Nothing pending for $Ids" } else { Info "Pending - bring it in with: exakit persona apply $Ids" }
}
