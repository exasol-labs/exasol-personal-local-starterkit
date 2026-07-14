# exapump.ps1 - exapump installation, connection, and guided data-loading
# module (Windows / PowerShell path).
#
# Dot-sourced by setup-windows-docker.ps1 and setup/exakit.ps1 after
# exakit-common.ps1. Mirrors setup/lib/exapump.sh function-for-function.
#
# exapump facts:
#   - release assets: exapump-<ver>-{macos,linux}-{aarch64,x86_64},
#     exapump-<ver>-windows-x86_64.exe (no Windows ARM64 build published)
#   - profiles: %USERPROFILE%\.exapump\config.toml (TOML, one section/profile)
#   - SQL from a file: exapump sql -p <profile> < file.sql
#   - CSV/Parquet load: exapump upload <file> --table <schema.table>

$script:ExapumpProfile = if ($env:EXAKIT_EXAPUMP_PROFILE) { $env:EXAKIT_EXAPUMP_PROFILE } else { "starter-kit" }
$script:ExapumpBinPath = Join-Path $script:BinDir "exapump.exe"
$script:ExapumpConfigPath = Join-Path $HOME ".exapump\config.toml"

# Test-ExapumpSucceeded - decide whether an exapump invocation succeeded.
#
# The Windows exapump.exe build can return a NON-ZERO exit code even when the
# statement executed successfully (observed: `SELECT 1` returns "[1/1]
# SELECT 1 1 rows" and exits non-zero), so exit code alone is not a reliable
# success signal on Windows. macOS/Linux exapump exits 0 on success, so exit
# code 0 is still trusted as the fast path; a non-zero exit is only treated
# as failure when the *output* actually looks like an error. This keeps
# behavior identical where exit codes are reliable and recovers correctly
# where they are not, while still catching genuine failures (auth, refused
# connection, syntax errors) which always print error text.
function Test-ExapumpSucceeded {
    param([int]$ExitCode, [AllowEmptyString()][string]$Output)
    $text = "$Output"
    # exapump prints an authoritative per-run summary: "<n> statement(s)
    # executed, <m> failed". Trust it FIRST - the exit code is unreliable on
    # Windows (non-zero even on success), and that summary line itself contains
    # the word "failed" ("0 failed"), which the generic error scan below would
    # otherwise treat as a failure. m == 0 means every statement succeeded.
    if ($text -match '(?im)(\d+)\s+statements?\s+executed,\s*(\d+)\s+failed') {
        return ([int]$Matches[2] -eq 0)
    }
    if ($ExitCode -eq 0) { return $true }
    if ($text -match '(?im)\b(error|exception|failed|failure|denied|refused|unable|cannot|could not|not found|no such|timeout|timed out|syntax error|invalid|unauthorized|authentication)\b') {
        return $false
    }
    if ($text -match '\[\d+/\d+\]' -or $text -match '(?im)\b\d+\s+rows?\b') {
        return $true
    }
    return $false
}

# Write-ExapumpOutput - print captured exapump output indented under a header,
# skipping empty output. Centralizes the "yellow header + indented lines" block
# that several loaders used to inline so the presentation stays consistent.
function Write-ExapumpOutput {
    param([AllowEmptyString()][string]$Output, [string]$Header = "exapump output:")
    if (-not "$Output".Trim()) { return }
    # Tool output: warn-style header on the gutter, lines in the dim | gutter
    # (same contained shape the verify step uses).
    Write-Host "      ! $Header" -ForegroundColor Yellow
    "$Output".Trim() -split "`n" | ForEach-Object {
        if ($script:UiFancy) { Write-Host ("      {0}{1} {2}{3}" -f $script:UiDim, $script:UiVB, $_, $script:UiReset) }
        else { Write-Host ("      | {0}" -f $_) }
    }
}

# Invoke-Exapump - run one exapump invocation, capturing combined output and
# the (unreliable-on-Windows) exit code, and return a structured result whose
# .Success is computed by Test-ExapumpSucceeded. Every exapump call site goes
# through this so success detection is consistent and the exit-code quirk is
# handled in exactly one place.
#
# Arguments are passed as an explicit array (NOT ValueFromRemainingArguments):
# exapump's own flags include "-p", which PowerShell's parameter binder would
# otherwise try to resolve against this function's common parameters
# (-ProgressAction / -PipelineVariable) and fail with an "ambiguous parameter"
# error before the args ever reach exapump.
function Invoke-Exapump {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $out = ""
    $code = 1
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # exapump writes its progress/summary lines to stderr on Windows. Under
        # the module-global $ErrorActionPreference = 'Stop', 2>&1 turns that very
        # first stderr write into a terminating error, so the catch below would
        # capture ONLY that first line and discard the actual result grid and the
        # "N statements executed" summary. That silently broke every caller that
        # reads query results back (the DDL-readiness probe, Test-ExapumpSchemaPresent,
        # row counts) - they saw a truncated output and concluded the schema was
        # missing / the database was not ready, spinning or failing on a database
        # that was in fact fine. Switch to 'Continue' for the native call so the
        # whole output is captured, exactly as Invoke-ExapumpAdminSql already does.
        $ErrorActionPreference = "Continue"
        $out = & (Get-ExapumpCli) @Arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
    } catch {
        $out = "$_"
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($script:LogFile) { "exapump $($Arguments -join ' ')" | Add-Content -Path $script:LogFile; $out | Add-Content -Path $script:LogFile }
    return @{ Output = $out; ExitCode = $code; Success = (Test-ExapumpSucceeded -ExitCode $code -Output $out) }
}

function Get-ExapumpAssetName {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        "AMD64" { return "exapump-$($script:ExapumpVersion)-windows-x86_64.exe" }
        default { return $null }  # no Windows ARM64 build published
    }
}

# Digest of the pinned release (published by the release API). When the
# version is overridden the digest is fetched from the API instead.
function Get-ExapumpPinnedSha256 {
    param([Parameter(Mandatory)][string]$AssetName)
    switch ($AssetName) {
        "exapump-0.11.2-windows-x86_64.exe" { return "8a2e8199a94f1b21782e4c68179948bfa43217c82c9b9b2a25eaec4532305237" }
        default { return $null }
    }
}

function Get-ExapumpDigestFromApi {
    param([Parameter(Mandatory)][string]$AssetName)
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$($script:ExapumpRepo)/releases/tags/v$($script:ExapumpVersion)" -UseBasicParsing
    } catch {
        return $null
    }
    $asset = $release.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
    if (-not $asset -or -not $asset.digest) { return $null }
    if ($asset.digest -notlike "sha256:*") { return $null }
    return $asset.digest.Substring(7)
}

function Get-ExapumpCli {
    $cmd = Get-Command exapump -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $script:ExapumpBinPath
}

function Install-Exapump {
    $asset = Get-ExapumpAssetName
    if (-not $asset) {
        Fail "Unsupported CPU architecture: $($env:PROCESSOR_ARCHITECTURE). exapump publishes a Windows build for x86_64 only."
    }

    $existing = Get-ExapumpCli
    if (Test-Path $existing) {
        # Trust the existing binary only if it actually runs - an interrupted
        # earlier download can leave a broken file at the same path. Wrapped:
        # a broken binary's stderr write must mean "reinstall", not an
        # uncaught exception under $ErrorActionPreference = 'Stop'.
        $existingWorks = $false
        $previousEAP = $ErrorActionPreference
        try {
            # Continue (not the global Stop) so a working binary that writes an
            # incidental line to stderr isn't turned into a terminating error on
            # Windows PowerShell 5.1 and needlessly reinstalled - the exit code
            # is the real signal. Same fix as Get-NanoEngine / Invoke-ExakitLogged.
            $ErrorActionPreference = "Continue"
            & $existing --version *> $null
            $existingWorks = ($LASTEXITCODE -eq 0)
        } catch { } finally {
            $ErrorActionPreference = $previousEAP
        }
        if ($existingWorks) {
            Ok "exapump already installed: $existing"
            Set-ExapumpManifest
            return
        }
        Warn2 "Existing exapump binary does not run (interrupted download?) - reinstalling"
        Remove-Item -Force $existing -ErrorAction SilentlyContinue
    }

    $url = "https://github.com/$($script:ExapumpRepo)/releases/download/v$($script:ExapumpVersion)/$asset"
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-exapump-$([guid]::NewGuid().ToString('N')).exe"

    Info "Downloading exapump v$($script:ExapumpVersion) ($asset)"
    Get-ExakitFile -Url $url -Dest $tmp

    $expected = Get-ExapumpPinnedSha256 $asset
    if (-not $expected) { $expected = Get-ExapumpDigestFromApi $asset }
    if ($expected) {
        Test-ExakitSha256 -Path $tmp -Expected $expected
    } elseif ($env:EXAKIT_ALLOW_UNVERIFIED_EXAPUMP -eq "1") {
        Warn2 "No digest available for $asset - proceeding WITHOUT checksum verification (EXAKIT_ALLOW_UNVERIFIED_EXAPUMP=1)."
    } else {
        # Match the launcher's bar (and the bash twin in exapump.sh): never
        # install a downloaded-and-executed binary we could not verify. For a
        # released version the pinned digest always resolves, so this only
        # fires on an un-pinned version bump or an unreachable release API.
        Remove-Item -Force $tmp -ErrorAction SilentlyContinue
        Fail "No checksum available for $asset; refusing to install an unverified exapump binary. Add its digest to the pinned list (version bump?) or check network access to the release API. Override at your own risk with EXAKIT_ALLOW_UNVERIFIED_EXAPUMP=1."
    }

    New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null
    Move-Item -Force $tmp $script:ExapumpBinPath
    Confirm-ExakitOnPath $script:BinDir
    Ok "exapump installed: $script:ExapumpBinPath"
    Set-ExapumpManifest
}

function Set-ExapumpManifest {
    Set-ExakitManifestValue "components.exapump.version" $script:ExapumpVersion
    Set-ExakitManifestValue "components.exapump.path" (Get-ExapumpCli)
}

# New-ExapumpProfile - write the kit's connection profile from the manifest.
# Managed section, safe to re-run; other profiles in the same file untouched.
function New-ExapumpProfile {
    $dsn = Get-ExakitManifestValue "runtime.dsn"
    if (-not $dsn) { Fail "No runtime DSN in the manifest - install the database first." }
    $host_, $port = $dsn -split ":", 2
    $user = Get-ExakitManifestValue "runtime.user"
    if (-not $user) { $user = "sys" }

    $pwFile = Get-ExakitManifestValue "runtime.password_file"
    $password = ""
    if ($pwFile -and (Test-Path $pwFile)) {
        $password = (Get-Content $pwFile -Raw).TrimEnd("`r", "`n")
    }
    if (-not $password) {
        $password = Read-ExakitPrompt "Database password for user $user (leave blank to skip profile creation)" ""
    }
    if (-not $password) {
        Warn2 "No database password available - create the profile manually with: exapump profile init $($script:ExapumpProfile)"
        return
    }

    # If the runtime password wasn't already on file (mirrors exapump.sh: an
    # adopted deployment with unreadable secrets, so the password came from the
    # prompt above), remember it so Test-ExapumpConnection can persist it AFTER
    # confirming it works. The MCP step needs runtime.password_file, but saving
    # a mistyped password before validation would make the next run reuse it
    # instead of re-prompting.
    if (-not $pwFile -or -not (Test-Path $pwFile)) {
        $script:PendingRuntimePassword = $password
    }

    New-Item -ItemType Directory -Force -Path (Split-Path $script:ExapumpConfigPath -Parent) | Out-Null
    Set-ExapumpTomlSection -ConfigPath $script:ExapumpConfigPath -Profile $script:ExapumpProfile -Host_ $host_ -Port $port -User $user -Password $password
    Protect-ExakitFile $script:ExapumpConfigPath
    Set-ExakitManifestValue "components.exapump.profile" $script:ExapumpProfile
    Ok "Connection profile written: [$($script:ExapumpProfile)] in $script:ExapumpConfigPath"
}

function Format-TomlString {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $escaped = $Value.Replace("\", "\\").Replace('"', '\"')
    return "`"$escaped`""
}

# Set-ExapumpTomlSection - replace/append a [profile] section in a TOML file,
# preserving every other section. Atomic write (temp file + rename) so an
# interrupted run never truncates a config that may hold other profiles.
function Set-ExapumpTomlSection {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][string]$Host_,
        [Parameter(Mandatory)][string]$Port,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Password,
        [string]$Schema = ""
    )
    $content = ""
    if (Test-Path $ConfigPath) { $content = Get-Content $ConfigPath -Raw }
    if (-not $content) { $content = "" }

    $lines = @(
        "[$Profile]",
        "host = $(Format-TomlString $Host_)",
        "port = $Port",
        "user = $(Format-TomlString $User)",
        "password = $(Format-TomlString $Password)"
    )
    if ($Schema) { $lines += "schema = $(Format-TomlString $Schema)" }
    $lines += "tls = true"
    $lines += "validate_certificate = false"
    $section = ($lines -join "`n") + "`n"

    $escapedProfile = [regex]::Escape($Profile)
    $pattern = "(?s)\[$escapedProfile\][^\[]*"
    if ($content -match $pattern) {
        $content = [regex]::Replace($content, $pattern, ($section + "`n"))
        $content = $content.TrimEnd("`n") + "`n"
    } else {
        if ($content -and -not $content.EndsWith("`n`n")) {
            $content = $content.TrimEnd("`n") + "`n`n"
        }
        $content += $section
    }

    $tmp = "$ConfigPath.tmp"
    Set-Content -Path $tmp -Value $content -NoNewline
    Move-Item -Force $tmp $ConfigPath
}

# Test-ExapumpDdlRoundtrip - one DDL write-readback round through the profile.
# Returns $true ONLY if a freshly created schema+table is durably persisted and
# visible from SUBSEQUENT connections (each exapump invocation reconnects).
#
# This is the real readiness signal. Right after first boot the Nano database
# accepts a connection and answers SELECT 1 while still stabilizing, and in that
# window it can ACKNOWLEDGE a DDL batch ("N statements executed, 0 failed")
# without durably persisting it - so the schema-creation step "succeeds" but the
# very next `exapump upload` fails with "schema STARTER_KIT not found". The probe
# reproduces exactly that sequence (create schema in one connection, reference it
# from the next) so we only proceed once the database really is ready.
function Test-ExapumpDdlRoundtrip {
    $probe = "EXAKIT_READY_PROBE"
    # Best-effort clean slate - a probe schema left by an interrupted earlier
    # attempt must not make this one look like a success. Result ignored.
    Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "DROP SCHEMA IF EXISTS $probe CASCADE") | Out-Null
    if (-not (Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "CREATE SCHEMA $probe")).Success) { return $false }
    # A NEW connection must see the just-created schema (this is the exact
    # cross-connection visibility that failed during install) and persist a table.
    $tableOk = (Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "CREATE TABLE $probe.READY_PROBE (n DECIMAL(9,0))")).Success `
        -and (Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "INSERT INTO $probe.READY_PROBE VALUES (42)")).Success
    $readBack = $false
    if ($tableOk) {
        # Confirm from yet another fresh connection that the row is durably
        # visible. Judge this on exapump's OWN signals - statement success plus
        # its "<n> rows" progress line - NOT by scraping the rendered result grid
        # for a data token. When exapump's stdout is a pipe (as it is here, and
        # as every install runs it) it omits the result grid and the "N
        # statements executed" summary entirely, so a token like EXAKIT_DDL[42]
        # never appears in the captured output. Keying the probe on that token
        # made it spin until EXAKIT_DDL_READY_TIMEOUT and fail the install even
        # though every statement had succeeded and the database was fully ready.
        # A missing schema/table instead makes the SELECT error (Success=false)
        # and a lost row makes it return "0 rows", so both real failures are
        # still caught.
        $read = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "SELECT n FROM $probe.READY_PROBE WHERE n = 42")
        $readBack = ($read.Success -and "$($read.Output)" -match '(?im)\b1\s+rows?\b')
    }
    Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "DROP SCHEMA IF EXISTS $probe CASCADE") | Out-Null
    return $readBack
}

# Confirm-ExapumpDatabaseReady - block until the database can durably persist a
# schema, not merely answer SELECT 1. Polls Test-ExapumpDdlRoundtrip with a
# bounded budget (EXAKIT_DDL_READY_TIMEOUT, default 180s) so the sample-data and
# MCP steps that follow can trust that CREATE SCHEMA/TABLE will stick.
function Confirm-ExapumpDatabaseReady {
    $timeout = if ($env:EXAKIT_DDL_READY_TIMEOUT) { [int]$env:EXAKIT_DDL_READY_TIMEOUT } else { 180 }
    Info "Confirming the database can persist schema changes"
    $waited = 0
    while ($true) {
        if (Test-ExapumpDdlRoundtrip) {
            if ($waited -eq 0) { Ok "Database is ready for schema changes" }
            else { Ok "Database is ready for schema changes (after ~${waited}s)" }
            return
        }
        if ($waited -ge $timeout) { break }
        Start-Sleep -Seconds 5
        $waited += 5
        if ($waited % 30 -eq 0) { Info "Database still stabilizing... (${waited}s)" }
    }
    Fail "The database accepts connections but could not durably persist a schema within ${timeout}s (first-boot stabilization window). Wait a moment, then retry: exakit data-load"
}

# Test-ExapumpConnection - validate the profile with SELECT 1, then confirm the
# database can durably persist DDL (Confirm-ExapumpDatabaseReady) before any
# caller relies on CREATE SCHEMA sticking.
function Test-ExapumpConnection {
    if (-not (Get-ExakitManifestValue "components.exapump.profile")) {
        Fail "No connection profile exists (no database password was available to write one). Create it manually with 'exapump profile init $($script:ExapumpProfile)', then re-run this script."
    }
    Info "Validating the database connection (SELECT 1)"
    $connected = $false
    $lastOutput = ""
    for ($tries = 0; $tries -lt 6; $tries++) {
        $result = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "SELECT 1")
        $lastOutput = $result.Output
        if ($result.Success) { $connected = $true; break }
        Start-Sleep -Seconds 5
    }
    if (-not $connected) {
        # Surface the actual error inline instead of only in the log file - the
        # exapump/database error text (auth failure vs. connection refused vs.
        # TLS handshake error) is exactly what's needed to diagnose this, and
        # making someone go dig through a log file for it is not production-grade.
        Write-ExapumpOutput -Output $lastOutput -Header "Last attempt's output:"
        Fail "SELECT 1 failed via profile '$($script:ExapumpProfile)' after 6 attempts. Try: exapump sql -p $($script:ExapumpProfile) 'SELECT 1'"
    }
    Ok "Connection works"

    # A working connection is NOT proof the database can persist schema changes
    # yet - see Test-ExapumpDdlRoundtrip. Gate here so both the data-load and MCP
    # steps that follow run against a database that is genuinely ready.
    Confirm-ExapumpDatabaseReady

    Set-ExakitManifestValue "components.exapump.validated" $true
    # Now that the password is proven to work, persist it as the runtime
    # password if the runtime step could not (adopted deployment with
    # unreadable secrets) - the MCP step needs runtime.password_file.
    if ($script:PendingRuntimePassword) {
        Set-ExakitCredential "runtime_sys_password" $script:PendingRuntimePassword
        Set-ExakitManifestValue "runtime.password_file" (Join-Path $script:CredsDir "runtime_sys_password")
        $script:PendingRuntimePassword = $null
    }
}

# Invoke-ExapumpSqlFile <file> [description] - execute a SQL file, logged.
# Returns $true/$false instead of dying so callers (Invoke-ExakitSampleDataLoad)
# can decide whether a missing/empty file is fatal.
# Invoke-ExapumpSqlFileCapture <file> - feed a SQL file to exapump's stdin and
# return a structured result ({ Output; ExitCode; Success }) matching
# Invoke-Exapump's shape, logging the invocation. Shared by
# Invoke-ExapumpSqlFile (needs only pass/fail) and the sample-data verification
# step (also scans output for FAIL rows), so the stdin feed + quirk-aware
# success detection lives in one place.
#
# The file's RAW BYTES are handed to exapump via System.Diagnostics.Process,
# NOT a PowerShell pipeline (Get-Content -Raw | exapump 2>&1). Two independent
# Windows PowerShell 5.1 behaviors made the pipeline form silently destroy the
# sample-data load:
#   1. Under the module-global $ErrorActionPreference = 'Stop', 2>&1 turned
#      exapump's first stderr progress line into a terminating error that tore
#      the pipeline down - killing exapump at statement 1 of the batch - while
#      the lone captured "[1/10] ..." line satisfied Test-ExapumpSucceeded's
#      [n/m] marker, so schema creation reported "done" without CREATE SCHEMA
#      ever running.
#   2. Under the system-wide UTF-8 codepage (65001), a UTF-8 BOM gets
#      prepended to whatever reaches exapump's stdin, and Exasol rejects the
#      batch's first statement: "'<U+FEFF>' character is not allowed within
#      unquoted identifier". PowerShell's own pipe writer adds one (even with
#      $OutputEncoding set to ASCII or BOM-less UTF-8), and on .NET Framework
#      Process.StandardInput adds another: merely accessing that property
#      builds a StreamWriter over Console.InputEncoding (BOM-emitting UTF-8
#      under CP 65001) with AutoFlush = $true, whose setter flushes the
#      encoder preamble into the pipe before any payload byte. Verified: with
#      Console.InputEncoding left alone the probe payload arrives as
#      EF BB BF + bytes on 5.1; with a BOM-less UTF-8 InputEncoding it
#      arrives byte-exact (and PowerShell 7 is byte-exact either way).
# Raw-byte stdin bypasses every re-encoding layer, and keeping exapump's
# stderr out of PowerShell's error stream sidesteps the 'Stop' teardown too.
# stdout/stderr reads start BEFORE stdin is written to avoid the classic
# full-pipe deadlock.
function Invoke-ExapumpSqlFileCapture {
    param([Parameter(Mandatory)][string]$Path)
    $out = ""
    $code = 1
    $previousInputEncoding = $null
    try {
        # Best-effort (throws when the process has no console): see BOM note
        # above. Restored in finally.
        try {
            $previousInputEncoding = [Console]::InputEncoding
            [Console]::InputEncoding = New-Object System.Text.UTF8Encoding $false
        } catch { $previousInputEncoding = $null }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = Get-ExapumpCli
        $psi.Arguments = "sql -p `"$($script:ExapumpProfile)`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $proc.StandardInput.Close()
        $proc.WaitForExit()
        $out = $stdoutTask.Result + $stderrTask.Result
        $code = $proc.ExitCode
    } catch {
        $out = "$_"
    } finally {
        if ($previousInputEncoding) {
            try { [Console]::InputEncoding = $previousInputEncoding } catch { }
        }
    }
    if ($script:LogFile) { "exapump sql -p $($script:ExapumpProfile) < $Path" | Add-Content -Path $script:LogFile; $out | Add-Content -Path $script:LogFile }
    return @{ Output = $out; ExitCode = $code; Success = (Test-ExapumpSucceeded -ExitCode $code -Output $out) }
}

function Invoke-ExapumpSqlFile {
    param([Parameter(Mandatory)][string]$Path, [string]$Description = "")
    if (-not $Description) { $Description = Split-Path $Path -Leaf }
    if (-not (Test-Path $Path) -or (Get-Item $Path).Length -eq 0) {
        Warn2 "SQL file missing or empty: $Path"
        return $false
    }
    Info "Running $Description"
    $result = Invoke-ExapumpSqlFileCapture $Path
    if (-not $result.Success) {
        Write-ExapumpOutput -Output $result.Output
        Fail "SQL file failed: $Path (see log)"
    }
    Ok "$Description done"
    return $true
}

# Invoke-ExapumpUpload <file> <schema.table> - load a CSV/Parquet file, logged.
function Invoke-ExapumpUpload {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Target)
    if (-not (Test-Path $Path) -or (Get-Item $Path).Length -eq 0) {
        Warn2 "Data file missing or empty: $Path"
        return $false
    }
    Info "Loading $(Split-Path $Path -Leaf) into $Target"
    $result = Invoke-Exapump @("upload", $Path, "--table", $Target, "-p", $script:ExapumpProfile)
    if (-not $result.Success) {
        Write-ExapumpOutput -Output $result.Output
        Fail "Upload failed: $Path -> $Target (see log)"
    }
    Ok "$(Split-Path $Path -Leaf) loaded"
    return $true
}

# Get-ExapumpRowCount <schema.table> - row count, or $null if it could not be
# read. Best-effort only: the row-count summary it feeds is cosmetic (shows
# "?" on failure) and the real load validation is 03_verify_setup.sql.
# Get-ExapumpProfilePassword <profile> - the password stored in an exapump
# profile ($script:ExapumpConfigPath), or $null. Symmetric with the writer in
# Set-ExapumpTomlSection. Lets the MCP step recover the admin password when the
# runtime step could not record runtime.password_file.
function Get-ExapumpProfilePassword {
    param([Parameter(Mandatory)][string]$Profile)
    if (-not (Test-Path $script:ExapumpConfigPath)) { return $null }
    $content = Get-Content $script:ExapumpConfigPath -Raw
    $section = [regex]::Match($content, "(?s)\[$([regex]::Escape($Profile))\](.*?)(?:\n\[|\z)")
    if (-not $section.Success) { return $null }
    $pw = [regex]::Match($section.Groups[1].Value, '(?m)^\s*password\s*=\s*"(.*)"\s*$')
    if (-not $pw.Success) { return $null }
    return $pw.Groups[1].Value
}

function Get-ExapumpRowCount {
    param([Parameter(Mandatory)][string]$Target)
    # Wrap the count in a unique delimited token (EXAKIT_RC[<n>]) so it can be
    # recovered from exapump's output no matter how the value is laid out - grid
    # vs compact, interactive TTY vs the piped, non-TTY install run. Scraping the
    # bare number was unreliable: during install exapump prints only a
    # "[1/1] ... 1 rows" status line, and the old digit-stripping fallback
    # collapsed that to "111" for EVERY table (from "[1/1]" + the single row a
    # COUNT(*) always returns). The token can't collide with that status line,
    # and the echoed query literal ("EXAKIT_RC[' || ...") never forms
    # "EXAKIT_RC[<digits>]", so only the actual result value matches.
    $sql = "SELECT 'EXAKIT_RC[' || CAST(COUNT(*) AS VARCHAR(40)) || ']' AS EXAKIT_RC FROM $Target"
    $result = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, $sql)
    if (-not $result.Success) { return $null }
    $m = [regex]::Match("$($result.Output)", 'EXAKIT_RC\[(\d+)\]')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Get-ExakitTableName {
    param([Parameter(Mandatory)][string]$Path)
    $base = (Split-Path $Path -Leaf) -replace '\?.*$', ''
    $base = [System.IO.Path]::GetFileNameWithoutExtension($base)
    # Parentheses required: without them "-replace" binds as a parameter of
    # ConvertTo-UpperInvariantString instead of acting as the operator.
    $table = ((ConvertTo-UpperInvariantString $base) -replace '[^A-Z0-9_]', '_')
    $table = ($table -replace '^_+', '') -replace '_+$', ''
    $table = $table -replace '_{2,}', '_'
    if (-not $table) { return "MY_TABLE" }
    return $table
}

function Get-ExakitNormalizedPath {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -eq "~") { return $HOME }
    if ($Path.StartsWith("~/") -or $Path.StartsWith("~\")) { return Join-Path $HOME $Path.Substring(2) }
    return $Path
}

function Test-ExakitTableTarget {
    param([Parameter(Mandatory)][string]$Target)
    if ($Target -notmatch '^[A-Za-z0-9_]+\.[A-Za-z0-9_]+$') { return $false }
    return $true
}

function Get-ExakitTargetSchema {
    param([Parameter(Mandatory)][string]$Target)
    return ConvertTo-UpperInvariantString (($Target -split '\.', 2)[0])
}

function Get-ExakitUpperTableTarget {
    param([Parameter(Mandatory)][string]$Target)
    $parts = $Target -split '\.', 2
    return "$(ConvertTo-UpperInvariantString $parts[0]).$(ConvertTo-UpperInvariantString $parts[1])"
}

# Test-ExapumpSchemaPresent - read-only check that a schema exists, from a fresh
# connection. Distinct from Confirm-ExakitSchemaExists, which also creates it.
function Test-ExapumpSchemaPresent {
    param([Parameter(Mandatory)][string]$Schema)
    $schemaUc = ConvertTo-UpperInvariantString $Schema
    if (-not $schemaUc) { return $false }
    # Decide presence from the ROW COUNT of a row-returning query, not by
    # scraping a sentinel token out of the rendered result grid. When exapump's
    # stdout is a pipe (every install runs it that way) it omits the result grid
    # entirely, so a sentinel like EXAKIT_SCHEMA_PRESENT never reaches the
    # captured output and this check always reported the schema missing - which
    # aborted the sample-data load even though the schema existed. The "<n> rows"
    # count on exapump's progress line IS reliably captured: a present schema
    # yields "1 rows", an absent one "0 rows".
    $sql = "SELECT 1 FROM EXA_ALL_SCHEMAS WHERE SCHEMA_NAME = '$schemaUc'"
    $check = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, $sql)
    return ($check.Success -and "$($check.Output)" -match '(?im)\b[1-9]\d*\s+rows?\b')
}

function Confirm-ExakitSchemaExists {
    param([Parameter(Mandatory)][string]$Schema)
    $schemaUc = ConvertTo-UpperInvariantString $Schema
    if (-not $schemaUc) { return $false }
    if (Test-ExapumpSchemaPresent $schemaUc) { return $true }
    Info "Creating schema $schemaUc"
    $create = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "CREATE SCHEMA $schemaUc")
    if (-not $create.Success) { Fail "Could not create schema $schemaUc" }
    return $true
}

function Confirm-ExakitLoadedTable {
    param([Parameter(Mandatory)][string]$Target)
    $rows = Get-ExapumpRowCount $Target
    if ($null -eq $rows) { Fail "Could not verify row count for $Target." }
    if ($rows -eq "0") {
        Warn2 "Verified $Target, but it currently has 0 rows."
    } else {
        Ok "Verified $Target ($rows rows)"
    }
    Set-ExakitManifestValue "data.last_load.verified_table" $Target
    Set-ExakitManifestValue "data.last_load.verified_rows" $rows
}

function Request-ExakitOptionalVerification {
    param([string]$Default = "")
    $target = Read-ExakitPrompt "Verify table after script/import (SCHEMA.TABLE, blank to skip)" $Default
    if (-not $target) { Info "Skipping table verification for this script/import."; return }
    if (-not (Test-ExakitTableTarget $target)) {
        Fail "Verification table must look like SCHEMA.TABLE and use letters, numbers, or underscores."
    }
    Confirm-ExakitLoadedTable (Get-ExakitUpperTableTarget $target)
}

function Import-ExakitLocalFile {
    while ($true) {
        $rawPath = Read-ExakitPrompt "Local CSV/Parquet file path (type back to return)" ""
        if ($rawPath -match '^(b|back)$') {
            Info "Returning to data loading options."
            return "back"
        }
        if (-not $rawPath) {
            Warn2 "Please enter a local CSV/Parquet file path, or type back to return."
            continue
        }
        $path = Get-ExakitNormalizedPath $rawPath
        if ((Test-Path $path) -and (Get-Item $path).Length -gt 0) { break }
        Warn2 "File not found or empty: $path"
    }
    $schema = if ($env:EXAKIT_SCHEMA) { $env:EXAKIT_SCHEMA } else { "STARTER_KIT" }
    $defaultTable = "$schema.$(Get-ExakitTableName $path)"
    while ($true) {
        $target = Read-ExakitPrompt "Target table (SCHEMA.TABLE, back to return)" $defaultTable
        if ($target -match '^(b|back)$') {
            Info "Returning to data loading options."
            return "back"
        }
        if (Test-ExakitTableTarget $target) { break }
        Warn2 "Target table must look like SCHEMA.TABLE and use letters, numbers, or underscores."
    }
    $target = Get-ExakitUpperTableTarget $target
    Confirm-ExakitSchemaExists (Get-ExakitTargetSchema $target) | Out-Null
    Invoke-ExapumpUpload $path $target | Out-Null
    Set-ExakitManifestValue "data.last_load.type" "local_file"
    Set-ExakitManifestValue "data.last_load.target" $target
    Set-ExakitManifestValue "data.last_load.source" $path
    Confirm-ExakitLoadedTable $target
    Ok "Loaded $path into $target"
}

function Import-ExakitRemoteFile {
    $url = Read-ExakitPrompt "Remote CSV/Parquet URL" ""
    if (-not $url) { Fail "Remote URL is required." }
    $name = Split-Path ($url -replace '\?.*$', '') -Leaf
    if (-not $name) { $name = "remote-data.csv" }
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-remote-data-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    $tmpFile = Join-Path $tmpDir $name
    Info "Downloading remote data file"
    Get-ExakitFile -Url $url -Dest $tmpFile
    $schema = if ($env:EXAKIT_SCHEMA) { $env:EXAKIT_SCHEMA } else { "STARTER_KIT" }
    $defaultTable = "$schema.$(Get-ExakitTableName $name)"
    $target = Read-ExakitPrompt "Target table (SCHEMA.TABLE)" $defaultTable
    if (-not (Test-ExakitTableTarget $target)) {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        Fail "Target table must look like SCHEMA.TABLE and use letters, numbers, or underscores."
    }
    $target = Get-ExakitUpperTableTarget $target
    Confirm-ExakitSchemaExists (Get-ExakitTargetSchema $target) | Out-Null
    Invoke-ExapumpUpload $tmpFile $target | Out-Null
    Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
    Set-ExakitManifestValue "data.last_load.type" "remote_file"
    Set-ExakitManifestValue "data.last_load.target" $target
    Set-ExakitManifestValue "data.last_load.source" $url
    Confirm-ExakitLoadedTable $target
    Ok "Loaded $url into $target"
}

function Invoke-ExakitSqlScript {
    $rawPath = Read-ExakitPrompt "SQL script path" ""
    $path = Get-ExakitNormalizedPath $rawPath
    if (-not (Test-Path $path) -or (Get-Item $path).Length -eq 0) { Fail "SQL script not found or empty: $path" }
    Invoke-ExapumpSqlFile $path "SQL script ($(Split-Path $path -Leaf))" | Out-Null
    Set-ExakitManifestValue "data.last_load.type" "sql_script"
    Set-ExakitManifestValue "data.last_load.source" $path
    Request-ExakitOptionalVerification ""
    Ok "SQL script completed"
}

# --- bundled dataset registry (mirrors exapump.sh) --------------------------
# TPC-H is the original flat-layout dataset; every additional dataset is a
# self-contained directory data/datasets/<id>/ with a dataset.conf (id=,
# label=, markers=, schema=), a schema script, optional bulk CSVs, an optional
# transform, and an optional verify script. Each dataset loads into its own
# schema (schema=, default the id uppercased); the read-only MCP user has
# database-wide read (USE ANY SCHEMA + SELECT ANY TABLE), so it sees every
# dataset schema with no per-schema grant.
function Get-ExakitBundledDatasets {
    # Every dataset (TPC-H included) is discovered from its dataset.conf;
    # nothing is hardcoded. A conf may set flag= to override the default
    # manifest key (TPC-H keeps the historical data.loaded) and schema= to name
    # the schema it loads into (default: the id, uppercased).
    $datasets = @()
    $kitRoot = Get-ExakitRepoRoot
    if ($kitRoot) {
        foreach ($conf in (Get-ChildItem -Path (Join-Path $kitRoot "data\datasets\*\dataset.conf") -ErrorAction SilentlyContinue)) {
            $kv = @{}
            foreach ($line in (Get-Content $conf)) {
                if ($line -match '^([a-z_]+)=(.*)$') { $kv[$Matches[1]] = $Matches[2] }
            }
            if (-not $kv.id -or -not $kv.label) { continue }
            $markers = @(($kv.markers -split ',') | Where-Object { $_ })
            $flag = if ($kv.flag) { $kv.flag } else { "data.datasets.$($kv.id).loaded" }
            $schema = if ($kv.schema) { $kv.schema } else { $kv.id.ToUpper() }
            $order = 50
            if ($kv.order -match '^[0-9]+$') { $order = [int]$kv.order }
            $datasets += @{ Id = $kv.id; Label = $kv.label; Flag = $flag; Markers = $markers; Schema = $schema; Order = $order }
        }
    }
    return @($datasets | Sort-Object { $_.Order }, { $_.Id })
}

# Test-ExakitDbReachable - one cached probe per run: can we run SQL right now?
$script:ExakitDbReachable = $null
function Test-ExakitDbReachable {
    if ($null -eq $script:ExakitDbReachable) {
        $script:ExakitDbReachable = $false
        if (Get-ExakitManifestValue "components.exapump.profile") {
            $result = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "SELECT 1")
            $script:ExakitDbReachable = [bool]$result.Success
        }
    }
    return $script:ExakitDbReachable
}

# Test-ExakitTablePresent <table> [schema] - does the table exist in the given
# schema (default STARTER_KIT / $EXAKIT_SCHEMA)?
function Test-ExakitTablePresent {
    param([Parameter(Mandatory)][string]$Table, [string]$Schema)
    $schema = if ($Schema) { $Schema.ToUpper() } elseif ($env:EXAKIT_SCHEMA) { $env:EXAKIT_SCHEMA.ToUpper() } else { "STARTER_KIT" }
    $tableUc = $Table.ToUpper()
    $sql = "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_ALL_TABLES WHERE TABLE_SCHEMA = '$schema' AND TABLE_NAME = '$tableUc') THEN 'EXAKIT_TABLE_PRESENT' ELSE 'EXAKIT_TABLE_MISSING' END AS STATUS"
    $result = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, $sql)
    return ($result.Success -and $result.Output -match "EXAKIT_TABLE_PRESENT")
}

# Test-ExakitDatasetLoaded - the DATABASE is the source of truth: when it is
# reachable, every marker table must exist (and the manifest flag is synced to
# what was observed, so a destroy+redeploy that left a stale "loaded" flag
# self-heals). Only when the database is unreachable do we fall back to the
# manifest flag alone.
function Test-ExakitDatasetLoaded {
    param([Parameter(Mandatory)][hashtable]$Dataset)
    if ((Test-ExakitDbReachable) -and $Dataset.Markers.Count -gt 0) {
        foreach ($table in $Dataset.Markers) {
            if (-not (Test-ExakitTablePresent $table $Dataset.Schema)) {
                if ((Get-ExakitManifestValue $Dataset.Flag) -eq $true) { Set-ExakitManifestValue $Dataset.Flag $false }
                return $false
            }
        }
        if ((Get-ExakitManifestValue $Dataset.Flag) -ne $true) { Set-ExakitManifestValue $Dataset.Flag $true }
        return $true
    }
    return ((Get-ExakitManifestValue $Dataset.Flag) -eq $true)
}

# Datasets that are NOT loaded yet - drives the dynamic data menus.
function Get-ExakitPendingDatasets {
    return @(Get-ExakitBundledDatasets | Where-Object { -not (Test-ExakitDatasetLoaded $_) })
}

function Invoke-ExakitDatasetLoad {
    param([Parameter(Mandatory)][string]$KitRoot, [Parameter(Mandatory)][string]$Id, [switch]$Force)
    switch ($Id) {
        "tpch" { Invoke-ExakitSampleDataLoad -KitRoot $KitRoot -Force:$Force }
        default { Invoke-ExakitDatasetDirLoad -KitRoot $KitRoot -Id $Id -Force:$Force }
    }
}

# Invoke-ExakitDatasetDirLoad - generic pipeline for a directory-based bundled
# dataset: schema script, bulk files, optional transform, optional verify,
# then record the manifest flag. Mirrors exakit_load_dataset_dir in exapump.sh.
function Invoke-ExakitDatasetDirLoad {
    param([Parameter(Mandatory)][string]$KitRoot, [Parameter(Mandatory)][string]$Id, [switch]$Force)
    $dir = Join-Path $KitRoot "data\datasets\$Id"
    $flag = "data.datasets.$Id.loaded"
    # Each dataset loads into its own schema (schema= in dataset.conf, default
    # the id uppercased); the dataset's SQL scripts create and OPEN that schema.
    $schema = $Id.ToUpper()
    $confPath = Join-Path $dir "dataset.conf"
    if (Test-Path $confPath) {
        foreach ($line in (Get-Content $confPath)) {
            if ($line -match '^flag=(.+)$') { $flag = $Matches[1] }
            if ($line -match '^schema=(.+)$') { $schema = $Matches[1] }
        }
    }
    if (-not (Test-Path $dir)) { Fail "Unknown bundled dataset: $Id (no $dir)" }
    if (-not (Get-ExakitManifestValue "components.exapump.profile")) {
        Fail "No exapump connection profile is recorded - the exapump setup step has not completed. Re-run the installer, then retry."
    }
    if ((Get-ExakitManifestValue $flag) -eq $true -and -not $Force) {
        Ok "Dataset '$Id' already loaded"
        return
    }
    Info "Loading the '$Id' dataset into schema $schema"

    # Schema script is OPTIONAL: exapump infers column types and creates the
    # table itself when none exists; the script exists to pin exact types and
    # primary keys. Verify the DDL really landed and re-run once if not.
    $schemaSql = Join-Path $dir "01_create_schema.sql"
    if ((Test-Path $schemaSql) -and (Get-Item $schemaSql).Length -gt 0) {
        Invoke-ExapumpSqlFile $schemaSql "$Id schema (01_create_schema.sql)" | Out-Null
        if (-not (Test-ExapumpSchemaPresent $schema.ToUpper())) {
            Warn2 "Schema $schema is not present after creation - re-running the schema script"
            Invoke-ExapumpSqlFile $schemaSql "$Id schema (re-run)" | Out-Null
            if (-not (Test-ExapumpSchemaPresent $schema.ToUpper())) {
                Fail "Schema $schema was reported created but does not exist. The database may still be stabilizing; wait a moment and retry: exakit data-load"
            }
        }
    } else {
        $result = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "CREATE SCHEMA IF NOT EXISTS $($schema.ToUpper())")
        if (-not $result.Success) { Fail "Could not create schema $schema." }
    }

    foreach ($csv in (Get-ChildItem -Path (Join-Path $dir "data\*.csv") -ErrorAction SilentlyContinue)) {
        if ($csv.Length -eq 0) { continue }
        $table = [System.IO.Path]::GetFileNameWithoutExtension($csv.Name).ToUpper()
        Invoke-ExapumpUpload $csv.FullName "$schema.$table" | Out-Null
    }

    $loadSql = Join-Path $dir "02_load_data.sql"
    if ((Test-Path $loadSql) -and (Get-Item $loadSql).Length -gt 0) {
        Invoke-ExapumpSqlFile $loadSql "$Id load statements (02_load_data.sql)" | Out-Null
    }

    $verifySql = Join-Path $dir "03_verify_setup.sql"
    if ((Test-Path $verifySql) -and (Get-Item $verifySql).Length -gt 0) {
        Info "Verification ($Id 03_verify_setup.sql):"
        $result = Invoke-ExapumpSqlFileCapture $verifySql
        Write-ExapumpOutput -Output $result.Output
        # Grade on the STATUS *column value* ",FAIL," - not the bare word. The
        # verify SQL is full of the literal string (the header comment "a 'FAIL'
        # row means..." and 17 "CASE ... ELSE 'FAIL' END" clauses), and exapump
        # echoes that text back, so matching bare "FAIL" fails a dataset even
        # when every row reads OK. A real failing check emits an unquoted STATUS
        # column (check_name,FAIL,detail); OK rows and the echoed SQL never do.
        if (-not $result.Success -or $result.Output -match ",FAIL,") {
            Fail "Verification failed for dataset '$Id' - see the log. Data is loaded but not marked ready; fix the underlying issue and re-run with -Force."
        }
    }

    # Row-count summary over the dataset's tables (uploaded CSVs + markers).
    $tables = New-Object 'System.Collections.Generic.List[string]'
    foreach ($csv in (Get-ChildItem -Path (Join-Path $dir "data\*.csv") -ErrorAction SilentlyContinue)) {
        $t = [System.IO.Path]::GetFileNameWithoutExtension($csv.Name).ToUpper()
        if (-not $tables.Contains($t)) { [void]$tables.Add($t) }
    }
    if (Test-Path $confPath) {
        foreach ($line in (Get-Content $confPath)) {
            if ($line -match '^markers=(.+)$') {
                foreach ($t in ($Matches[1] -split ',')) {
                    $tu = $t.Trim().ToUpper()
                    if ($tu -and -not $tables.Contains($tu)) { [void]$tables.Add($tu) }
                }
            }
        }
    }
    if ($tables.Count -gt 0) {
        Start-ExakitPanel "Row counts"
        foreach ($t in $tables) {
            $rows = Get-ExapumpRowCount "$schema.$t"
            $line = "{0,-30} {1} rows" -f "$schema.$t", $(if ($rows) { $rows } else { "?" })
            Write-ExakitPanelLine $line
            if ($script:LogFile) { "DATA  $line" | Add-Content -Path $script:LogFile }
        }
        Complete-ExakitPanel
    }

    Set-ExakitManifestValue $flag $true
    # Also record the canonical per-dataset key so data.datasets is a complete
    # map even for datasets that keep a legacy flag (TPC-H uses data.loaded for
    # backward compatibility). data.loaded is left untouched for existing installs.
    $canonicalFlag = "data.datasets.$Id.loaded"
    if ($flag -ne $canonicalFlag) { Set-ExakitManifestValue $canonicalFlag $true }
    Set-ExakitManifestValue "data.last_load.source" "dataset:$Id"
    Ok "Dataset '$Id' loaded and verified"
}

# Select-ExakitDataLoad <final_label> - dynamic checkbox over the data
# sources: every bundled dataset that is not loaded yet, then the local-file
# option, then <final_label> as the mutually exclusive opt-out (Cancel/Skip).
# When every bundled dataset is already loaded, only the local-file and
# opt-out choices are shown, with the opt-out as the safe default. Returns a
# string array of ids ("tpch", "local") or @("none").
function Select-ExakitDataLoad {
    param([Parameter(Mandatory)][string]$FinalLabel)
    # Three top-level choices, with the pending datasets shown upfront as a
    # small tree under a "Sample datasets" group header (see exapump.sh twin).
    $labels = New-Object 'System.Collections.Generic.List[string]'
    $ids = New-Object 'System.Collections.Generic.List[string]'
    $pending = @(Get-ExakitPendingDatasets)
    if ($pending.Count -gt 0) {
        # The group row is itself a checkbox: pre-selected with every dataset;
        # unchecking it clears all datasets, after which the user can pick
        # them individually. Each dataset hangs off it with a tree connector
        # (UiTee/UiCorner from the ui palette; ASCII in plain mode) so the
        # parent-child relationship is visible, not just implied by indent.
        # The connectors must come from the palette, never as literals here:
        # this file has no BOM, so Windows PowerShell 5.1 reads it as ANSI and
        # raw glyph bytes break the parse of the whole script.
        $tee = $script:UiTee; $corner = $script:UiCorner
        [void]$labels.Add("Sample datasets"); [void]$ids.Add("__group__")
        for ($i = 0; $i -lt $pending.Count; $i++) {
            if ($i -eq $pending.Count - 1) { $conn = $corner } else { $conn = $tee }
            [void]$labels.Add("$conn $($pending[$i].Label)")
            [void]$ids.Add($pending[$i].Id)
        }
    }
    [void]$labels.Add("A local CSV/Parquet file"); [void]$ids.Add("local")
    [void]$labels.Add($FinalLabel);                [void]$ids.Add("none")
    $finalIdx = $labels.Count
    if ($pending.Count -gt 0) {
        $defaults = @(1..($pending.Count + 1))   # group row + every dataset
        $selection = Read-ExakitCheckboxMenu -Title "Select data to load" -Options $labels.ToArray() `
            -Defaults $defaults -ExclusiveIndex $finalIdx `
            -GroupParent 1 -GroupFirst 2 -GroupLast ($pending.Count + 1)
    } else {
        Info "Every bundled dataset is already loaded (reload with: exakit data-load -Force)."
        $selection = Read-ExakitCheckboxMenu -Title "Select data to load" -Options $labels.ToArray() `
            -Defaults @($finalIdx) -ExclusiveIndex $finalIdx
    }
    if ($selection -contains $finalIdx) { return @("none") }
    $chosen = @($selection | Where-Object { $_ -lt $finalIdx } | ForEach-Object { $ids[$_ - 1] } | Where-Object { $_ -ne "__group__" })
    if ($chosen.Count -eq 0) { return @("none") }
    return $chosen
}

function Show-ExakitDataLoadMenu {
    if (-not (Get-ExakitManifestValue "components.exapump.profile")) {
        Fail "No exapump connection profile is recorded - re-run the installer, then retry."
    }
    $chosen = Select-ExakitDataLoad -FinalLabel "Cancel (load nothing)"
    if ($chosen -contains "none") {
        Info "Data loading cancelled."
        return
    }
    foreach ($id in $chosen) {
        if ($id -eq "local") {
            $result = Import-ExakitLocalFile
            if ($result -eq "back") { Info "Local file load skipped. Run it any time with: exakit data-load" }
        } else {
            $kitRoot = Get-ExakitRepoRoot
            if (-not $kitRoot) { Fail "Could not find the kit's sql/ and data/ files to load." }
            Invoke-ExakitDatasetLoad -KitRoot $kitRoot -Id $id
        }
    }
}

# Invoke-ExakitSampleDataLoad <kit_root> [-Force] - the TPC-H sample-data
# entry point, kept for its long-standing callers (the installer offer,
# `exakit data-load -Force`, and setup-windows-docker.ps1). TPC-H now lives in
# data\datasets\tpch like every other bundled dataset, so this simply
# delegates to the generic directory pipeline.
function Invoke-ExakitSampleDataLoad {
    param([Parameter(Mandatory)][string]$KitRoot, [switch]$Force)
    Invoke-ExakitDatasetDirLoad -KitRoot $KitRoot -Id "tpch" -Force:$Force
}

# Request-ExakitDataLoadOffer <kit_root> - interactively offer the guided
# data loading menu during install. Non-interactive installs print the
# follow-up command and continue. Runs in a try/catch so a Fail() inside the
# loading flow (which calls exit) is still contained by the caller... note:
# unlike bash's subshell isolation, PowerShell's exit terminates the whole
# process, so callers that must survive a failed load run this in a child
# pwsh process instead (see setup-windows-docker.ps1).
function Request-ExakitDataLoadOffer {
    param([Parameter(Mandatory)][string]$KitRoot)

    # EXAKIT_DATASETS names bundled datasets directly (csv of ids from
    # data\datasets\<id>\, e.g. "tpch,weather") so an agent-driven or scripted
    # install picks an exact selection without a tty. Unknown ids warn and are
    # skipped; if none are valid the load fails. EXAKIT_DATASETS takes
    # precedence over EXAKIT_LOAD_SAMPLE. Twin of exakit_maybe_offer_data_load
    # in common.sh - the .ps1 path used to ignore these documented vars.
    if ($env:EXAKIT_DATASETS) {
        $knownIds = @(Get-ExakitBundledDatasets | ForEach-Object { $_.Id })
        $validAny = $false
        foreach ($envId in ($env:EXAKIT_DATASETS -split ',')) {
            $envId = $envId.Trim()
            if (-not $envId) { continue }
            if ($knownIds -contains $envId) {
                $validAny = $true
                Info "Loading dataset '$envId' (EXAKIT_DATASETS)."
                Invoke-ExakitDatasetLoad -KitRoot $KitRoot -Id $envId
            } else {
                Warn2 "Unknown dataset id '$envId' in EXAKIT_DATASETS (available: $($knownIds -join ', '))."
            }
        }
        if (-not $validAny) { Fail "EXAKIT_DATASETS='$($env:EXAKIT_DATASETS)' matched no bundled dataset - nothing was loaded." }
        return
    }

    # EXAKIT_LOAD_SAMPLE decides up front: =0 skips data loading entirely, =1
    # loads the bundled TPC-H sample without asking. Twin of common.sh.
    if ($env:EXAKIT_LOAD_SAMPLE -eq "0") {
        Info "Skipping data loading (EXAKIT_LOAD_SAMPLE=0). Run it any time with: exakit data-load"
        return
    }
    if ($env:EXAKIT_LOAD_SAMPLE -eq "1") {
        Info "Loading the bundled sample data (EXAKIT_LOAD_SAMPLE=1)."
        Invoke-ExakitSampleDataLoad -KitRoot $KitRoot
        return
    }

    # Dynamic dataset checkbox (shared with `exakit data-load`): only bundled
    # datasets that are not loaded yet are offered, pre-selected, plus the
    # local-file option and an explicit skip. Non-interactive installs keep
    # the pre-selected defaults.
    Info "The database is ready for data. Loading data now lets MCP validate against real tables."
    $chosen = Select-ExakitDataLoad -FinalLabel "Skip for now (no data loading)"
    if ($chosen -contains "none") {
        Info "Skipping data loading. Run it any time with: exakit data-load"
        return
    }
    foreach ($id in $chosen) {
        if ($id -eq "local") {
            $result = Import-ExakitLocalFile
            if ($result -eq "back") { Info "Local file load skipped. Run it any time with: exakit data-load" }
        } else {
            Invoke-ExakitDatasetLoad -KitRoot $KitRoot -Id $id
        }
    }
}
