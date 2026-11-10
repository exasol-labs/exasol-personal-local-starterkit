# core-setup.ps1 - core setup tasks: work a kit release adds that only the
# installer can do.
#
# Dot-sourced after exakit-common.ps1 (and exapump.ps1, runtime-personal.ps1)
# by setup-windows.ps1 and by exakit.ps1. Twin of core-setup.sh: the same
# Python coordinators under setup\core and setup\preprocessor do the work, so
# the two platforms cannot disagree about what is pending or how the framework
# is installed.
#
# Three files hold the whole contract:
#   setup\core\tasks.json      the task names a kit release asks for
#   manifest.json              core_tasks.completed: names whose checks passed
#   setup\core\manage.py       compares the two, records completions

# Task name -> the function that installs and verifies it. A task with no
# entry here is reported as "not part of this kit copy", never skipped silently.
$script:ExakitCoreTaskHandlers = @{
    "preprocessor" = "Invoke-ExakitCoreTaskPreprocessor"
}

# Join-ExakitCorePath <base> <part>... - a path built one segment at a time.
# The parts reach Python verbatim, so a "setup\core" literal would only ever
# work on Windows; segment by segment it also runs under pwsh on macOS and
# Linux, where the suites for this module run too.
function Join-ExakitCorePath {
    param([Parameter(Mandatory)][string]$Base, [Parameter(ValueFromRemainingArguments)][string[]]$Parts)
    $path = $Base
    foreach ($part in $Parts) { $path = Join-Path $path $part }
    return $path
}

# Test-ExakitCoreRerunActive - true inside an installer that `exakit update`
# started to finish pending core tasks. Twin of exakit_core_rerun_active.
function Test-ExakitCoreRerunActive {
    return ($env:EXAKIT_CORE_RERUN -eq "1")
}

function Invoke-ExakitCoreManage {
    param([Parameter(Mandatory)][string]$KitRoot, [Parameter(Mandatory)][string]$Command, [string[]]$Arguments = @())
    $manage = Join-ExakitCorePath $KitRoot "setup" "core" "manage.py"
    $tasks = Join-ExakitCorePath $KitRoot "setup" "core" "tasks.json"
    if (-not (Test-Path -LiteralPath $manage)) { return [pscustomobject]@{ Code = 2; Lines = @() } }
    $argv = @($Command, "--tasks", $tasks)
    if ($Command -ne "tasks") { $argv += @("--manifest", $script:ManifestPath) }
    return (Invoke-ExakitPythonFile -Path $manage -Arguments (@($argv) + @($Arguments)))
}

# Get-ExakitCoreTasks / Get-ExakitCorePending - task names, in tasks.json
# order. $null when the list cannot be read. Twins of exakit_core_tasks and
# exakit_core_pending.
function Get-ExakitCoreTasks {
    param([Parameter(Mandatory)][string]$KitRoot, [string]$Scope = "")
    $extra = @()
    if ($Scope) { $extra = @("--scope", $Scope) }
    $result = Invoke-ExakitCoreManage -KitRoot $KitRoot -Command "tasks" -Arguments $extra
    if ($result.Code -ne 0) { return $null }
    return ,@($result.Lines | Where-Object { "$_".Trim() })
}

function Get-ExakitCorePending {
    param([Parameter(Mandatory)][string]$KitRoot, [string]$Scope = "")
    $extra = @()
    if ($Scope) { $extra = @("--scope", $Scope) }
    $result = Invoke-ExakitCoreManage -KitRoot $KitRoot -Command "pending" -Arguments $extra
    if ($result.Code -ne 0) { return $null }
    return ,@($result.Lines | Where-Object { "$_".Trim() })
}

# Complete-ExakitCoreTask - record a task whose checks passed.
function Complete-ExakitCoreTask {
    param([Parameter(Mandatory)][string]$KitRoot, [Parameter(Mandatory)][string]$Name)
    $result = Invoke-ExakitCoreManage -KitRoot $KitRoot -Command "complete" -Arguments @($Name)
    if ($result.Code -eq 0) { return $true }
    Warn2 "The completed setup task $Name could not be recorded in $script:ManifestPath (exit $($result.Code)) - the next installer run checks it again"
    return $false
}

function Get-ExakitCoreTaskLabel {
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -eq "preprocessor") { return "the SQL preprocessor framework" }
    return $Name
}

# Invoke-ExakitCoreDatabaseStep - the installer's "Configure database
# features" step. Never recorded in steps_completed, so it runs on every pass:
# the core-task record skips the install, never the check. Twin of
# exakit_core_database_step.
function Invoke-ExakitCoreDatabaseStep {
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][string]$KitRoot)
    if (-not (Begin-ExakitStep "db_features" $Label)) { return }
    $tasks = Get-ExakitCoreTasks -KitRoot $KitRoot -Scope "database"
    if ($null -eq $tasks) {
        Register-ExakitSoftFailure -Component "db_features" -Repair "exakit update" `
            -Reason "the kit's task list (setup\core\tasks.json) could not be read" -Label "database features"
        Warn2 "The database feature list could not be read - carrying on so the rest of the install completes"
        return
    }
    if ($tasks.Count -eq 0) {
        OkStep "No database features to configure"
        return
    }
    foreach ($task in $tasks) {
        $label = Get-ExakitCoreTaskLabel $task
        $handler = $script:ExakitCoreTaskHandlers[$task]
        if (-not $handler -or -not (Get-Command $handler -ErrorAction SilentlyContinue)) {
            Register-ExakitSoftFailure -Component $task -Repair "exakit update" `
                -Reason "this kit copy has no setup for it" -Label $label
            Warn2 "$label is not part of this kit copy - carrying on"
            continue
        }
        $ok = Invoke-ExakitSoftStep -Component $task -Repair "exakit update" -Label $label -Body {
            # The handler's LAST output is its verdict; anything a cmdlet
            # leaked onto the pipeline before it must not read as success.
            $verdict = @(& $handler -KitRoot $KitRoot)
            return ($verdict.Count -gt 0 -and $verdict[-1] -eq $true)
        }
        if ($ok) { [void](Complete-ExakitCoreTask -KitRoot $KitRoot -Name $task) }
    }
}

# Get-ExakitCorePreprocessorPin - version, ref, asset, repo and SHA-256 of the
# framework package: the advertised manifest first, the pin this kit copy
# shipped with when the advertised one needs a newer kit. Twin of
# exakit_core_preprocessor_pin.
function Get-ExakitCorePreprocessorPin {
    param([Parameter(Mandatory)][string]$KitRoot)
    $baked = Join-Path $KitRoot "versions.json"
    foreach ($doc in @("", $baked)) {
        if ($doc -and -not (Test-Path -LiteralPath $doc)) { continue }
        $pin = [ordered]@{}
        foreach ($field in @("version", "release", "asset", "repo", "sha256.release-sql", "sha256.core-only", "min_kit_version")) {
            if ($doc) { $value = Get-ExakitVersionsValue -Path "components.preprocessor.$field" -DocPath $doc }
            else { $value = Get-ExakitVersionsValue -Path "components.preprocessor.$field" }
            $pin[$field] = "$value"
        }
        if (-not ($pin["version"] -and $pin["release"] -and $pin["asset"] -and $pin["repo"] -and $pin["sha256.release-sql"] -and $pin["sha256.core-only"])) { continue }
        $minKit = $pin["min_kit_version"]
        if ($minKit) {
            $kit = Get-ExakitComponentCurrent "exakit"
            if ($kit -and $kit -ne "unknown" -and $kit -ne $minKit -and -not (Test-ExakitVersionNewer -Latest $kit -Current $minKit)) {
                Write-ExakitLog "INFO" "preprocessor $($pin['version']) needs kit >= $minKit; using the pin this kit copy shipped with"
                continue
            }
        }
        return [pscustomobject]@{
            Version = $pin["version"]; Ref = $pin["release"]; Asset = $pin["asset"]
            Repo = $pin["repo"]; Sha256 = $pin["sha256.release-sql"].ToLowerInvariant()
            CoreSha256 = $pin["sha256.core-only"].ToLowerInvariant()
        }
    }
    return $null
}

# Invoke-ExakitCoreTaskPreprocessor - install, activate and verify the SQL
# preprocessor framework. Returns $true or $false; the reason for $false is in
# Set-ExakitFailureReason, which the soft step puts in the closing summary.
# Twin of exakit_core_task_preprocessor.
function Invoke-ExakitCoreTaskPreprocessor {
    param([Parameter(Mandatory)][string]$KitRoot)
    $py = Join-ExakitCorePath $KitRoot "setup" "preprocessor" "manage.py"
    if (-not (Test-Path -LiteralPath $py)) {
        Set-ExakitFailureReason "setup\preprocessor\manage.py is missing from this kit copy"
        return $false
    }
    $pin = Get-ExakitCorePreprocessorPin -KitRoot $KitRoot
    if ($null -eq $pin) {
        Set-ExakitFailureReason "no framework version is pinned in versions.json"
        return $false
    }
    $user = Get-ExakitManifestValue "runtime.user"
    if (-not $user) { $user = "sys" }
    $package = Join-ExakitCorePath $script:ExakitHome "cache" "preprocessor" $pin.Sha256 $pin.Asset
    $result = $null
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $argv = @("ensure", "--exapump", (Get-ExapumpCli), "--profile", $script:ExapumpProfile,
            "--manifest", $script:ManifestPath, "--admin-user", $user,
            "--pin-version", $pin.Version, "--pin-ref", $pin.Ref, "--pin-sha256", $pin.Sha256,
            "--pin-core-sha256", $pin.CoreSha256)
        if ($script:LogFile) { $argv += @("--log", $script:LogFile) }
        if (Test-Path -LiteralPath $package) { $argv += @("--package", $package) }
        $result = Invoke-ExakitWithSpinner -Label "Configuring the SQL preprocessor framework" -Body {
            Invoke-ExakitPythonFile -Path $py -Arguments $argv
        }
        $result = @($result)[-1]
        foreach ($line in @($result.Lines)) {
            if ($line -like "OK *") { OkStep $line.Substring(3) }
            elseif ($line -like "INFO *") { Info $line.Substring(5) }
            elseif ($line -like "WARN *") { Warn2 $line.Substring(5) }
            elseif ($line -like "FAIL *") {
                Write-ExakitLog "ERROR" $line.Substring(5)
                Set-ExakitFailureReason $line.Substring(5)
            } elseif ("$line".Trim()) { Write-ExakitLog "PREPROC" $line }
        }
        # 10: a fresh install needs the package, and only then is it fetched,
        # so a rerun over an installed framework never needs the network.
        if ($result.Code -ne 10 -or $attempt -ne 1) { break }
        # Downloaded under its own name in a staging folder: the checksum line
        # names the file it checked. Twin of the bash side.
        $partial = Join-ExakitCorePath (Split-Path -Parent $package) ".incoming" $pin.Asset
        $script:ExakitActiveLabel = "Downloading the SQL preprocessor framework $($pin.Version)"
        [void](Get-ExakitFile -Url ("https://github.com/" + $pin.Repo + "/releases/download/" + $pin.Ref + "/" + $pin.Asset) -Dest $partial)
        Test-ExakitSha256 -Path $partial -Expected $pin.Sha256
        Move-Item -Force -LiteralPath $partial -Destination $package
        Remove-Item -LiteralPath (Split-Path -Parent $partial) -ErrorAction SilentlyContinue
    }
    if ($result.Code -eq 0) { return $true }
    if ($result.Code -eq 10) {
        Set-ExakitFailureReason "the framework package was fetched but the install still could not find it"
    }
    return $false
}

# Invoke-ExakitCoreRerunInstaller - run the downloaded installer once, every
# component pinned to the version installed now and the kit's source passed
# through. Returns the installer's exit code. Twin of exakit_core_rerun_installer.
function Invoke-ExakitCoreRerunInstaller {
    param([Parameter(Mandatory)][string]$KitRoot)
    $saved = @{}
    $names = @("EXAKIT_KIT_SOURCE", "EXAKIT_PERSONAL_VERSION", "EXAKIT_EXAPUMP_VERSION", "EXAKIT_MCP_VERSION", "EXAKIT_PYEXASOL_VERSION")
    foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, "Process") }
    try {
        $source = Get-ExakitManifestValue "kit.source"
        if ($source) { $env:EXAKIT_KIT_SOURCE = "$source" }
        foreach ($pair in @(@("personal", "EXAKIT_PERSONAL_VERSION"), @("exapump", "EXAKIT_EXAPUMP_VERSION"),
                            @("mcp", "EXAKIT_MCP_VERSION"), @("pyexasol", "EXAKIT_PYEXASOL_VERSION"))) {
            if ([Environment]::GetEnvironmentVariable($pair[1], "Process")) { continue }
            $have = "" + (Get-ExakitComponentCurrent $pair[0])
            if ($have -match '^[A-Za-z0-9._+-]+$' -and $have -ne "unknown") {
                [Environment]::SetEnvironmentVariable($pair[1], $have, "Process")
            }
        }
        $argv = @("--platform", "windows", "--kit-root", $KitRoot,
                  "--powershell", ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName))
        if ("$source" -like "checkout:*") { $argv += @("--fallback-root", "$source".Substring(9)) }
        $rerun = Join-ExakitCorePath $KitRoot "setup" "core" "rerun-installer.py"
        if ($script:ExakitUpdateJson) {
            # Nothing may reach stdout under --json, and Out-Host would get past
            # the caller's redirection: the installer's lines go to the log.
            $argv += "--no-stdin"
            $result = Invoke-ExakitPythonFile -Path $rerun -Arguments $argv
            foreach ($line in @($result.Lines)) { Write-ExakitLog "RERUN" $line }
        } else {
            $result = Invoke-ExakitPythonFile -Path $rerun -Arguments $argv -Live
        }
        return $result.Code
    } finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], "Process") }
    }
}

# Invoke-ExakitCoreUpdateCheck - `exakit update`'s second check: when this kit
# asks for setup this machine has not completed, rerun the downloaded installer
# once. Only for a whole-kit update; never inside a rerun; a database task
# with the database stopped is deferred rather than started behind the user's
# back. Returns $false only when the rerun left work unfinished.
# $script:ExakitCoreUpdateActed says whether it did anything. Twin of
# exakit_core_update_check.
function Invoke-ExakitCoreUpdateCheck {
    param([string]$Target = "all")
    $script:ExakitCoreUpdateActed = $false
    if ($Target -ne "all" -and $Target -ne "exakit") { return $true }
    if (Test-ExakitCoreRerunActive) { return $true }
    $root = Get-ExakitRepoRoot
    if (-not $root -or -not (Test-Path -LiteralPath (Join-ExakitCorePath $root "setup" "core" "tasks.json"))) { return $true }
    $pending = Get-ExakitCorePending -KitRoot $root
    if ($null -eq $pending) {
        Warn2 "The kit's setup task list could not be compared with this machine - skipping that check. Details: exakit logs"
        return $true
    }
    if ($pending.Count -eq 0) { return $true }
    $list = ($pending -join " ")
    $script:ExakitCoreUpdateActed = $true
    $database = Get-ExakitCorePending -KitRoot $root -Scope "database"
    if ($database -and $database.Count -gt 0 -and -not (Test-PersonalDeploymentRunning)) {
        Info "This kit has new setup to finish ($list), and it needs the database running."
        Info "Start the database, then update again: exakit start, then exakit update"
        Add-ExakitUpdateNote -Component "core-setup" -Outcome "deferred" -To $list -Remedy "exakit start && exakit update"
        return $true
    }
    Info "This kit has new setup to finish ($list) - running the installer once to complete it"
    $code = Invoke-ExakitCoreRerunInstaller -KitRoot $root
    $left = Get-ExakitCorePending -KitRoot $root
    if ($null -eq $left) { $left = $pending }
    $leftList = ($left -join " ")
    if ($code -eq 0 -and $left.Count -eq 0) {
        Ok "New setup completed: $list"
        Add-ExakitUpdateNote -Component "core-setup" -Outcome "updated" -To $list
        return $true
    }
    if (-not $leftList) { $leftList = $list }
    Warn2 "New setup did not complete: $leftList. Retry with: exakit update"
    Add-ExakitUpdateNote -Component "core-setup" -Outcome "failed" -To $leftList -Remedy "exakit update"
    return $false
}

# Invoke-ExakitUpdateHandover - `exakit update`'s first check: this run just
# downloaded a newer kit, so the NEW exakit.ps1 finishes it (the remaining
# components and its own task list). Under --json the new run is a --json run
# too (each failure a row, the rest still tried) and writes its rows to a file
# this run merges back, so the caller still prints ONE object;
# EXAKIT_UPDATE_ROW_FIELDS=7 tells it this reader takes the error and hint
# fields. Returns the new run's exit code, or $null when there is no new
# command to hand over to - decided before anything runs, never read off an
# exit code. Twin of exakit_update_handover.
function Invoke-ExakitUpdateHandover {
    param([string]$Target = "all", [bool]$AssumeYes = $false)
    $newPs1 = Join-ExakitCorePath $script:ExakitHome "kit" "setup" "exakit.ps1"
    if (-not (Test-Path -LiteralPath $newPs1)) { return $null }
    Info "Continuing with the updated kit"
    $resultsFile = $null
    $previousHandover = $env:EXAKIT_UPDATE_HANDOVER
    $previousResults = $env:EXAKIT_UPDATE_RESULTS_FILE
    $previousRowFields = $env:EXAKIT_UPDATE_ROW_FIELDS
    $previous = $ErrorActionPreference
    try {
        $env:EXAKIT_UPDATE_HANDOVER = "1"
        $env:EXAKIT_UPDATE_ROW_FIELDS = "7"
        if ($script:ExakitUpdateJson) {
            $resultsFile = [System.IO.Path]::GetTempFileName()
            $env:EXAKIT_UPDATE_RESULTS_FILE = $resultsFile
        }
        $argv = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $newPs1, "update", $Target)
        if ($AssumeYes) { $argv += "--yes" }
        if ($script:ExakitUpdateJson) { $argv += "--json" }
        $ErrorActionPreference = "Continue"
        $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($script:ExakitUpdateJson) {
            # Out-Host would get past the --json run's redirection; the new
            # run's screen lines are in the log, its rows in the results file.
            & $exe @argv *> $null
        } else {
            & $exe @argv | Out-Host
        }
        $code = $LASTEXITCODE
        $ErrorActionPreference = $previous
        # $null, not truthiness: an EMPTY ArrayList is falsy in PowerShell.
        if ($resultsFile -and $null -ne $script:ExakitUpdateResults) {
            foreach ($line in @(Get-Content -LiteralPath $resultsFile -ErrorAction SilentlyContinue)) {
                # component|outcome|from|to|remedy|error|hint - the last two
                # optional, so a row from a kit that wrote five still reads.
                # A failed row with no component is the new run's own reason
                # for ending outside every component (Invoke-CmdUpdate's
                # catch); Write-ExakitUpdateJsonReport makes it the run entry.
                $parts = @("$line" -split '\|', 7)
                if ($parts.Count -ge 5 -and ($parts[0] -or $parts[1] -eq "failed")) {
                    $rowError = $(if ($parts.Count -ge 6) { $parts[5] } else { "" })
                    $rowHint = $(if ($parts.Count -ge 7) { $parts[6] } else { "" })
                    [void]$script:ExakitUpdateResults.Add([pscustomobject]@{
                        component = $parts[0]; outcome = $parts[1]; from = $parts[2]; to = $parts[3]; remedy = $parts[4]
                        error = $rowError; hint = $rowHint
                    })
                }
            }
        }
        return $code
    } finally {
        $ErrorActionPreference = $previous
        $env:EXAKIT_UPDATE_HANDOVER = $previousHandover
        $env:EXAKIT_UPDATE_RESULTS_FILE = $previousResults
        $env:EXAKIT_UPDATE_ROW_FIELDS = $previousRowFields
        if ($resultsFile) { Remove-Item -Force -LiteralPath $resultsFile -ErrorAction SilentlyContinue }
    }
}
