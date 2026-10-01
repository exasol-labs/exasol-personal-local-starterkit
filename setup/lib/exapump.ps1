# exapump.ps1 - exapump installation, connection, and guided data-loading
# module (Windows / PowerShell path).
#
# Dot-sourced by setup-windows.ps1 and setup/exakit.ps1 after
# exakit-common.ps1. Mirrors setup/lib/exapump.sh function-for-function.
#
# exapump facts:
#   - release assets: exapump-<ver>-{macos,linux}-{aarch64,x86_64},
#     exapump-<ver>-windows-x86_64.exe (no Windows ARM64 build published)
#   - profiles: %USERPROFILE%\.exapump\config.toml (TOML, one section/profile)
#   - SQL from a file: exapump sql -p <profile> < file.sql
#   - CSV/Parquet load: exapump upload <file> --table <schema.table>

$script:ExapumpProfile = if ($env:EXAKIT_EXAPUMP_PROFILE) { $env:EXAKIT_EXAPUMP_PROFILE } else { "starter-kit" }
# Overridable, and the ORDER in Get-ExapumpCli matters with it: an explicit
# EXAKIT_EXAPUMP_BIN is the one the caller means, so it outranks whatever
# `exapump` happens to be on PATH. Twin of the same rule in exapump.sh, where
# an unconditional assignment let a sandboxed test reach the developer's real
# binary and real database.
$script:ExapumpBinPath = if ($env:EXAKIT_EXAPUMP_BIN) { $env:EXAKIT_EXAPUMP_BIN } else { Join-Path $script:BinDir "exapump.exe" }
# %USERPROFILE%, not PowerShell's $HOME - exapump.exe resolves its profile from
# the former and nothing passes --config or EXAPUMP_CONFIG, so on a domain
# machine with a redirected home the kit wrote H:\.exapump\config.toml while the
# binary read C:\Users\<you>\.exapump\config.toml and reported no such profile.
$script:ExapumpConfigPath = Join-Path (Get-ExakitProfileHome) ".exapump\config.toml"

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
        # Each stderr line as its TEXT, not as a formatted ErrorRecord: Out-String
        # rendered exapump's progress line as a seven-line red NativeCommandError
        # block ("At ...exapump.ps1 char:16", CategoryInfo, ...) that reached the
        # screen on every `exakit sql`, success or failure, and every log.
        # Escaped for the 5.1 command-line rules, which drop an unescaped
        # double quote: every quoted identifier in a statement went over
        # unquoted, and Exasol upper-cases what is not quoted. See
        # ConvertTo-ExakitNativeArgs.
        $nativeArgs = ConvertTo-ExakitNativeArgs $Arguments
        $out = (@(& (Get-ExapumpCli) @nativeArgs 2>&1) | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { "$($_.Exception.Message)" } else { "$_" }
        }) -join "`n"
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
    # Get-ExakitHostArch, not $env:PROCESSOR_ARCHITECTURE: under an x64-emulated
    # PowerShell on ARM64 the env var says AMD64, and this function would offer
    # a build the machine runs only under emulation while json-tables and the
    # scheduler (which ask the hardware via WMI) refuse theirs - the kit
    # disagreeing with itself about what machine it is on.
    switch (Get-ExakitHostArch) {
        "amd64" { return "exapump-$($script:ExapumpVersion)-windows-x86_64.exe" }
        default { return $null }  # no Windows ARM64 build published
    }
}

# Get-ExapumpExpectedSha256 <asset> - the digest the download is verified
# against:
#
#   1. versions.json, but ONLY when the version being installed is the advertised
#      one. An env override must never borrow another release's digest - that
#      would either fail confusingly or, worse, match the wrong artifact.
#   2. the pinned digests of the fallback releases (below).
#   3. the release API for the version in question.
#
# $null means "no digest available"; the caller decides what to do with that (it
# refuses to install unless explicitly overridden).
# Twin of exapump_expected_sha256 in exapump.sh.
function Get-ExapumpExpectedSha256 {
    param([Parameter(Mandatory)][string]$AssetName)
    $advertised = Get-ExakitVersionsValue -Path "components.exapump.version"
    if ($advertised -and $advertised -eq $script:ExapumpVersion) {
        # The asset name is exapump-<version>-<os>-<arch>.exe, and versions.json
        # keys its digests by that same <os>-<arch> token.
        $platform = $AssetName
        $prefix = "exapump-$($script:ExapumpVersion)-"
        if ($platform.StartsWith($prefix)) { $platform = $platform.Substring($prefix.Length) }
        if ($platform.EndsWith(".exe")) { $platform = $platform.Substring(0, $platform.Length - 4) }
        $digest = Get-ExakitVersionsValue -Path "components.exapump.sha256.$platform"
        if ($digest -and $digest -match '^[0-9a-f]{64}$') { return $digest }
    }
    $digest = Get-ExapumpPinnedSha256 $AssetName
    if ($digest) { return $digest }
    return (Get-ExapumpDigestFromApi $AssetName)
}

# Digests of the fallback releases (published by the release API), consulted by
# Get-ExapumpExpectedSha256 after versions.json and before the release API. The
# current fallback MUST be listed here: it is what Install-Exapump verifies
# against when the release API cannot supply a digest for the requested version.
function Get-ExapumpPinnedSha256 {
    param([Parameter(Mandatory)][string]$AssetName)
    switch ($AssetName) {
        "exapump-0.13.0-windows-x86_64.exe" { return "b6eccf50732f4f2d3d4f6edb34789e6e24e94d9c6dbd50f5f080104b375aa838" }
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
    # An explicit override first: see the note on $script:ExapumpBinPath.
    if ($env:EXAKIT_EXAPUMP_BIN) { return $env:EXAKIT_EXAPUMP_BIN }
    $cmd = Get-Command exapump -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $script:ExapumpBinPath
}

function Install-Exapump {
    $exiT0 = Get-Date
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
            # is the real signal. Same fix as Invoke-ExakitLogged.
            $ErrorActionPreference = "Continue"
            & $existing --version *> $null
            $existingWorks = ($LASTEXITCODE -eq 0)
        } catch { } finally {
            $ErrorActionPreference = $previousEAP
        }
        if ($existingWorks) {
            # THE VERSION IS CHECKED, NOT JUST THAT IT RUNS. A kit-managed
            # binary left by an earlier install answered --version, was called
            # "already installed", and the manifest then recorded the version
            # this kit PINS - 0.13.0 on paper, 0.12.0 on disk, and every
            # exapump fix in between missing. Only the kit's own path is
            # replaced; a binary the user put elsewhere is theirs. Twin of the
            # same check in exapump_install.
            $have = ""
            try {
                $ErrorActionPreference = "Continue"
                $versionOut = (& $existing --version 2>&1 | Out-String -Width 4096)
                if ($versionOut -match '(\d+\.\d+\.\d+)') { $have = $Matches[1] }
            } catch { } finally {
                $ErrorActionPreference = $previousEAP
            }
            if ($have -and $have -ne $script:ExapumpVersion -and $existing -eq $script:ExapumpBinPath) {
                Info "exapump $have is installed; this kit ships $($script:ExapumpVersion) - replacing it"
                Remove-Item -Force $existing -ErrorAction SilentlyContinue
            } else {
                Ok "exapump already installed: $existing"
                Set-ExapumpManifest
                return
            }
        } else {
            Warn2 "Existing exapump binary does not run (interrupted download?) - reinstalling"
            Remove-Item -Force $existing -ErrorAction SilentlyContinue
        }
    }

    $url = "https://github.com/$($script:ExapumpRepo)/releases/download/v$($script:ExapumpVersion)/$asset"
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-exapump-$([guid]::NewGuid().ToString('N')).exe"

    # Named per phase so the one animated line says what is happening now. The
    # checksum has no phase of its own: it is sub-second on a 20 MB binary, and
    # its own tick is gone - it named a temp path, never the asset. The
    # verification itself is untouched.
    $script:ExakitActiveLabel = "Downloading exapump v$($script:ExapumpVersion)"
    Info "Downloading exapump v$($script:ExapumpVersion) ($asset)"
    Get-ExakitFile -Url $url -Dest $tmp

    $expected = Get-ExapumpExpectedSha256 $asset
    # No digest for the requested version (an un-pinned latest, and the release
    # API unreachable or rate-limited): install the fallback release instead,
    # verified against its pinned digest, rather than failing the install.
    # Ported from the production hotfix (exasol-labs PR #24); twin of the same
    # block in exapump_install.
    if (-not $expected -and $env:EXAKIT_ALLOW_UNVERIFIED_EXAPUMP -ne "1" -and $script:ExapumpVersion -ne $script:ExapumpVersionFallback) {
        Warn2 "No checksum available for $asset - installing the fallback exapump v$($script:ExapumpVersionFallback) instead."
        $script:ExapumpVersion = $script:ExapumpVersionFallback
        $asset = Get-ExapumpAssetName
        $url = "https://github.com/$($script:ExapumpRepo)/releases/download/v$($script:ExapumpVersion)/$asset"
        Remove-Item -Force $tmp -ErrorAction SilentlyContinue
        $script:ExakitActiveLabel = "Downloading exapump v$($script:ExapumpVersion)"
        Info "Downloading exapump v$($script:ExapumpVersion) ($asset)"
        Get-ExakitFile -Url $url -Dest $tmp
        $expected = Get-ExapumpExpectedSha256 $asset
    }
    if ($expected) {
        Test-ExakitSha256 -Path $tmp -Expected $expected
    } elseif ($env:EXAKIT_ALLOW_UNVERIFIED_EXAPUMP -eq "1") {
        Warn2 "No digest available for $asset - proceeding WITHOUT checksum verification (EXAKIT_ALLOW_UNVERIFIED_EXAPUMP=1)."
    } else {
        # Match the launcher's bar (and the bash twin in exapump.sh): never
        # install a downloaded-and-executed binary we could not verify. An
        # unknown version with no reachable release API was already swapped for
        # the fallback above, so this only fires when even the fallback release
        # has no digest - a pinned table that was not updated with the fallback.
        Remove-Item -Force $tmp -ErrorAction SilentlyContinue
        Fail "No checksum available for $asset; refusing to install an unverified exapump binary. Add its digest to versions.json (components.exapump.sha256) or check network access to the release API. Override at your own risk with EXAKIT_ALLOW_UNVERIFIED_EXAPUMP=1."
    }

    New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null
    Move-Item -Force $tmp $script:ExapumpBinPath
    Confirm-ExakitOnPath $script:BinDir
    # Smoke-test the freshly installed binary BEFORE reporting success - the twin
    # of exapump_verify_runs, which the sh side has always had and this side
    # never did. A checksum proves the download is intact, not that the machine
    # will let it start; without this the failure surfaced three minutes later
    # as "SELECT 1 failed", blaming a database that was healthy all along.
    Test-ExapumpRuns
    OkStep "exapump v$($script:ExapumpVersion) installed to $(Get-ExakitTilde $script:ExapumpBinPath) ($([int]((Get-Date) - $exiT0).TotalSeconds)s)"
    Set-ExapumpManifest
}

# Test-ExakitBinaryNotRunnableYet - is this the error of a binary that cannot
# start YET, rather than one that cannot start at all?
#
# A freshly written, unsigned 20 MB executable is held open by Windows Defender
# and by corporate EDR agents while they scan it, and every attempt to run it
# meanwhile fails with "Access is denied". Measured on a managed Windows laptop:
# three and a half minutes, during which all six SELECT 1 attempts failed and
# the install reported a database fault - with the database perfectly healthy
# and the same binary running fine a minute later. Twin of
# exakit_binary_not_runnable_yet.
function Test-ExakitBinaryNotRunnableYet([string]$Output) {
    return ("$Output" -match 'Access is denied|failed to run|being used by another process|cannot access the file|contains a virus')
}

# Test-ExapumpRuns - the freshly installed binary must actually start. Twin of
# exapump_verify_runs: it waits out a scanner that is still holding the file
# (and only that error), then reports what is really wrong.
function Test-ExapumpRuns {
    $budget = 180
    if ($env:EXAKIT_EXAPUMP_READY_TIMEOUT) { $budget = [int]$env:EXAKIT_EXAPUMP_READY_TIMEOUT }
    $t0 = [DateTime]::UtcNow
    $said = $false
    $out = ""
    while ($true) {
        $previousEAP = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $out = (@(& $script:ExapumpBinPath --version 2>&1) | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) { "$($_.Exception.Message)" } else { "$_" }
            }) -join "`n"
            $code = $LASTEXITCODE
        } catch {
            $out = "$_"
            $code = 1
        } finally {
            $ErrorActionPreference = $previousEAP
        }
        if ($code -eq 0) { return }
        if (-not (Test-ExakitBinaryNotRunnableYet -Output $out)) { break }
        if (([DateTime]::UtcNow - $t0).TotalSeconds -ge $budget) { break }
        if (-not $said) {
            Info "The new exapump cannot start yet (a virus scanner still holds it) - waiting up to ${budget}s"
            $said = $true
        }
        Start-Sleep -Seconds 5
    }
    Write-ExakitLog "ERR" "exapump --version failed: $out"
    $first = ("$out" -split "`n")[0]
    if (Test-ExakitBinaryNotRunnableYet -Output $out) {
        Fail "exapump was installed and verified, but this machine will not let it run: $first. A virus scanner or endpoint-security agent is holding it. Allow $($script:ExapumpBinPath) (or wait for the scan to finish), then: exakit update"
    }
    Fail "exapump was installed but does not run: $first. See the log and https://github.com/$($script:ExapumpRepo)/issues"
}

function Set-ExapumpManifest {
    Set-ExakitManifestValue "components.exapump.version" $script:ExapumpVersion
    Set-ExakitManifestValue "components.exapump.path" (Get-ExapumpCli)
}

# Confirm-ExapumpInstalledVersion - ask the binary what it is, now that this run has
# installed one, and make the record agree with the answer. Set-ExapumpManifest
# writes the version the run INTENDED to install; only the binary can say what is
# actually there. Returns $false when they disagree, so the caller does not announce
# a move that did not happen.
#
# Silence is left alone deliberately: Get-ExakitComponentCurrent answers nothing only
# when there is no binary at all, and a correction invented from silence would be
# worse than the record. That reader lives in setup/exakit.ps1, which the installer
# entry point. That skip is gone: Get-ExakitComponentCurrent is in the shared
# layer now, so the confirmation runs during an install too - which is where a
# version that does not match what was just installed is most worth hearing
# about.
# Twin of exapump_confirm_installed_version in setup/lib/exapump.sh.
function Confirm-ExapumpInstalledVersion {
    $live = Get-ExakitComponentCurrent "exapump"
    if (-not $live) { return $true }
    if ($live -eq $script:ExapumpVersion) { return $true }
    Warn2 "The exapump on disk reports $live, not the $($script:ExapumpVersion) this update installed - recording what is there"
    Set-ExakitManifestValue "components.exapump.version" $live
    return $false
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
    OkStep "Connection profile [$($script:ExapumpProfile)] written to $(Get-ExakitTilde $script:ExapumpConfigPath)"
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

    # LOCKED BEFORE THE SECRET GOES IN, not after. $content carries plaintext
    # database passwords, and this staging file used to be created by
    # Set-Content at whatever ACL the directory handed down - so between the
    # write and the Move there was a readable copy of the admin credential on
    # disk. Protect-ExakitFile $ConfigPath at the caller locked only the final
    # name. The kit's own Python half states the rule it is following here
    # (mcp/runtime/filesystem.py): on Windows it is protect_path() on the temp
    # file, BEFORE the replace, that provides the guarantee. A rename keeps the
    # file's explicit DACL, so the destination arrives already locked.
    $tmp = "$ConfigPath.tmp"
    New-Item -ItemType File -Path $tmp -Force | Out-Null
    if (Get-Command Protect-ExakitFile -ErrorAction SilentlyContinue) { Protect-ExakitFile $tmp }
    Set-Content -Path $tmp -Value $content -NoNewline
    Move-Item -Force $tmp $ConfigPath
}

# Test-ExapumpDdlRoundtrip - one DDL write-readback round through the profile.
# Returns $true ONLY if a freshly created schema+table is durably persisted and
# visible from SUBSEQUENT connections (each exapump invocation reconnects).
#
# This is the real readiness signal. Right after first boot the database
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
    # Announced by the caller, not here: answering SELECT 1 and persisting a
    # schema are one fact to the reader - the database is ready - and two ticks
    # for it read as two things to keep track of. This one stays in the logfile;
    # Test-ExapumpConnection prints the merged line.
    # Twin of exapump_confirm_database_ready (exapump.sh).
    Start-ExakitSpinner "Confirming the database can persist schema changes"
    $waited = 0
    while ($true) {
        if (Test-ExapumpDdlRoundtrip) {
            Stop-ExakitSpinner
            if ($waited -eq 0) { Ok "Database is ready for schema changes" }
            else { Ok "Database is ready for schema changes (after ~${waited}s)" }
            return
        }
        if ($waited -ge $timeout) { break }
        Start-Sleep -Seconds 5
        $waited += 5
        if ($waited % 30 -eq 0) {
            # Only where the spinner is not already counting - a line printed
            # under a live animator is erased by its next frame.
            if ($script:UiFancy) { Write-ExakitLog "INFO" "Database still stabilizing... (${waited}s)" }
            else { Info "Database still stabilizing... (${waited}s)" }
        }
    }
    Stop-ExakitSpinner
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
    $evcT0 = Get-Date
    $script:ExakitActiveLabel = "Validating the database connection"
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
        # NAME THE REAL FAULT. When the binary cannot start, every attempt says
        # "Access is denied" and nothing was ever asked of the database -
        # reporting "SELECT 1 failed" sent the reader to diagnose a healthy
        # database. See Test-ExakitBinaryNotRunnableYet.
        if (Test-ExakitBinaryNotRunnableYet -Output $lastOutput) {
            Fail "exapump is installed but this machine will not let it run (a virus scanner or endpoint-security agent is holding it) - the database was never asked. Allow $($script:ExapumpBinPath), then: exakit update"
        }
        Write-ExapumpOutput -Output $lastOutput -Header "Last attempt's output:"
        Fail "SELECT 1 failed via profile '$($script:ExapumpProfile)' after 6 attempts. Try: exapump sql -p $($script:ExapumpProfile) 'SELECT 1'"
    }
    Ok "Connection works"

    # A working connection is NOT proof the database can persist schema changes
    # yet - see Test-ExapumpDdlRoundtrip. Gate here so both the data-load and MCP
    # steps that follow run against a database that is genuinely ready.
    Confirm-ExapumpDatabaseReady

    # One line for both checks. Reaching here means SELECT 1 answered AND a
    # schema round-tripped durably; either failing fails with its own message.
    OkStep "Database ready - connection and schema changes verified ($([int]((Get-Date) - $evcT0).TotalSeconds)s)"

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
    # ExakitUploadQuiet covers this the same way it covers Invoke-ExapumpUpload:
    # a caller narrating a whole job on one line does not want "Running x" / "x
    # done" for each of its scripts underneath. The failure path is never quiet.
    if (-not $script:ExakitUploadQuiet) { Info "Running $Description" }
    $result = Invoke-ExapumpSqlFileCapture $Path
    if (-not $result.Success) {
        Write-ExapumpOutput -Output $result.Output
        # Translate the common faults into their remedy before dying, so
        # "Connection refused" arrives WITH "exakit start" instead of leaving the
        # reader to map one to the other.
        Show-ExakitDbErrorRemedy $result.Output
        Fail "The SQL in $(Split-Path -Leaf $Path) did not run. The database's own message: exakit logs setup. Check the database is up with: exakit status"
    }
    if (-not $script:ExakitUploadQuiet) { Ok "$Description done" }
    return $true
}

# Invoke-ExapumpUpload <file> <schema.table> - load a CSV/Parquet file, logged.
# $script:ExakitUploadQuiet - twin of EXAKIT_UPLOAD_QUIET in exapump.sh.
# `exakit data-load` narrates the whole job with a single "Loading your data"
# spinner, so per-file chatter is noise there. The installer leaves it false
# and keeps its step-by-step narration.
$script:ExakitUploadQuiet = $false

# The reason the last -Soft upload failed, in one short line. Twin of
# exakit_upload_failure_reason in exapump.sh.
$script:ExakitUploadReason = ""

# Get-ExakitUploadFailureReason - why an upload failed, in words.
#
# The engine says something genuinely useful and the kit was throwing it away,
# leaving "could not be loaded (see log)" and a reader four directories from the
# answer. Only the shapes worth translating are translated; anything else is
# passed through trimmed, because a slightly long engine message beats none.
function Get-ExakitUploadFailureReason {
    param([string[]]$Output = @())
    $line = @($Output | Where-Object { $_ -like "Error: *" } | Select-Object -Last 1)
    if ($line.Count -eq 0) { return "" }
    $text = [string]$line[0]
    # A JSON value quoted by the engine stays in the log. Twin of the same
    # step in exakit_upload_failure_reason.
    $text = ($text -replace '\{.*\}', '<JSON value>') -replace '\{.*$', '<JSON value>'
    $row = ""
    $m = [regex]::Match($text, "row=(\d+)")
    if ($m.Success) { $row = $m.Groups[1].Value }
    if ($text -like "*not enclosed field*") {
        if (-not $row) { $row = "?" }
        return "row $row has a line break or an unescaped comma inside a quoted field"
    }
    if ($text -like "*<CR>*") {
        # The engine names the byte itself.
        return "the file has Windows line endings (CRLF), which exapump does not yet pass to the database correctly - re-save it with LF line endings and load again"
    }
    # The DETAIL after the code, up to the session id. The first version
    # stopped at the first "[" - exactly where every Exasol import message
    # begins its detail - so the screen said "ETL-3051" and nothing else.
    $e = [regex]::Match($text, "(ETL-\d+: .*)$")
    if ($e.Success) {
        $out = ($e.Groups[1].Value -replace " \(Session: .*$", "").Trim()
        if ($out.Length -gt 160) {
            # At a word, not mid-word.
            $out = $out.Substring(0, 160)
            $sp = $out.LastIndexOf(" ")
            if ($sp -gt 0) { $out = $out.Substring(0, $sp) }
            $out = "$out..."
        }
        # A cast or parse failure on a file the inspector flagged as CRLF is
        # that flag, nine times in ten: the engine reports the symptom, the
        # kit adds the cause it saw in the header.
        if (("," + $script:ExakitCsvFlags + ",") -like "*,crlf,*") {
            $out = "$out - the file has Windows line endings (CRLF), which exapump does not yet pass to the database correctly; re-save it with LF line endings and load again"
        }
        return $out
    }
    # THE FALLBACK TRIMMED WORSE THAN THE BRANCH ABOVE IT, and the fallback is
    # what an unrecognised engine error lands in - the ones a reader most needs
    # whole. 160 at a word boundary with an ellipsis up there; a bare 100-character
    # chop down here, mid-word, no ellipsis, and the "(Session: ...)" noise left in.
    # Observed on a real load:
    #     duplicate column name: name [line 4, column 5] (Session: 187
    #     Failed to infer CSV schema from '/Users/me/Desktop/stress-lo
    # Both stop mid-token, and the second loses the path it was about to name.
    $out = ($text -replace "^Error: ", "") -replace " \(Session: \d+\)", ""
    if ($out.Length -gt 160) {
        $out = $out.Substring(0, 160)
        $sp = $out.LastIndexOf(" ")
        if ($sp -gt 0) { $out = $out.Substring(0, $sp) }
        $out = "$out..."
    }
    return $out
}

function Invoke-ExapumpUpload {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Target, [switch]$Soft)
    if (-not (Test-Path -LiteralPath $Path) -or (Get-Item -LiteralPath $Path).Length -eq 0) {
        Warn2 "Data file missing or empty: $Path"
        return $false
    }
    if (-not $script:ExakitUploadQuiet) { Info "Loading $(Split-Path $Path -Leaf) into $Target" }
    # The file goes over AS IT IS (see Get-ExakitCsvInspection). The header's
    # delimiter is passed on as exapump's own option; what the engine will
    # object to is remembered so the failure reason can name it.
    $uploadArgs = @("upload", $Path, "--table", $Target, "-p", $script:ExapumpProfile)
    $script:ExakitCsvFlags = ""
    if ((Get-ExakitDataFileKind $Path) -eq "csv") {
        $look = Get-ExakitCsvInspection -Path $Path
        if ($look.HeaderOnly) {
            Warn2 "$(Split-Path $Path -Leaf) has a header and no rows - nothing to load"
            return $false
        }
        $script:ExakitCsvFlags = $look.Flags
        if ($look.Flags) { Write-ExakitLog "INFO" "$(Split-Path $Path -Leaf) has: $($look.Flags)" }
        if ($look.Delimiter -ne ",") { $uploadArgs += @("--delimiter", $look.Delimiter) }
    }
    $result = Invoke-Exapump $uploadArgs
    if (-not $result.Success -and (Test-ExakitUploadCutShort -Output $result.Output)) {
        # A cut transfer is recovered here too, not only in the dataset batch:
        # a user's own file crosses the same import connection. Only a cut the
        # output SAYS, as in the twin, which reads this attempt from the log.
        $delim = ","
        if ($uploadArgs -contains "--delimiter") { $delim = $uploadArgs[[array]::IndexOf($uploadArgs, "--delimiter") + 1] }
        $rec = Invoke-ExakitUploadRecovery -Path $Path -Target $Target -Delimiter $delim `
            -ExitCode $result.ExitCode -Output $result.Output
        $result = @{ Output = $rec.Output; ExitCode = $result.ExitCode; Success = [bool]$rec.Success }
    }
    if (-not $result.Success) {
        # -Soft: a bulk folder load must not lose the other thirty-nine files to
        # one bad one. Fail() exits the whole PROCESS here - PowerShell has no
        # subshell to contain it, which is how the bash twin keeps this soft - so
        # a caller that means to carry on asks for a return value instead.
        #
        # The engine's raw output and the remedy banner are held back too, not
        # just the Fail: a caller reporting each file itself would say the same
        # news twice, the loud way first. The REASON is kept, so that caller can
        # put it in its own line instead of sending the reader to a logfile.
        if ($Soft) {
            $script:ExakitUploadReason = Get-ExakitUploadFailureReason -Output $result.Output
            return $false
        }
        Write-ExapumpOutput -Output $result.Output
        Show-ExakitDbErrorRemedy $result.Output
        # Show-ExakitDbErrorRemedy only knows connection, LIMIT and privilege
        # faults, so a malformed CSV - the commonest upload failure there is -
        # matched none of them and arrived as "(see log)". The translator that
        # does know that fault is the one the soft path above already calls, so
        # the FATAL outcome was the one getting the worse message. Same reason,
        # same words, on both paths. Twin of exapump_upload in exapump.sh.
        $uploadWhy = Get-ExakitUploadFailureReason -Output $result.Output
        if ($uploadWhy) { Fail "Could not load $(Split-Path $Path -Leaf) into $Target - $uploadWhy" }
        # "Upload failed:" on purpose - the "Could not load X into Y" form on
        # the line above is reserved for the branch that HAS the reason and
        # appends it. Same distinction as the shell twin.
        Fail "Upload failed: $Path -> $Target. What exapump said is in the log: exakit logs setup. Check the database is up with: exakit status"
    }
    if (-not $script:ExakitUploadQuiet) { Ok "$(Split-Path $Path -Leaf) loaded" }
    # A CRLF file whose last column is text LOADS - with a carriage return on
    # every value in that column, because exapump set no row separator and the
    # database took the CR as data. A bridge that will not rewrite the file
    # says so. Twin of the same warning in exapump_upload.
    if (("," + $script:ExakitCsvFlags + ",") -like "*,crlf,*") {
        Warn2 "$(Split-Path $Path -Leaf) has Windows line endings (CRLF), which exapump passes through: every value in the last column of $Target ends in a carriage return. Re-save the file with LF endings and load again, or trim it in SQL with RTRIM(col, CHR(13))."
    }
    return $true
}

# Get-ExakitUploadParallel - how many uploads may run at once.
#
# WHY UPLOADS RUN CONCURRENTLY AT ALL: an exapump call is a process launch, and
# on a fresh Windows install each one measured ~4.4s against 185ms once warm.
# A dataset load is dominated by that, not by row throughput - weather (10,970
# rows) took as long as energy (108,050) because both made the same number of
# launches. The uploads cannot be merged into one call: exapump upload takes
# many FILES but only one --table, and IMPORT ... FROM LOCAL CSV FILE is
# refused by the server over this protocol ("only supported via JDBC or
# EXAplus"). So the launches have to overlap instead.
#
# Verified against a local deployment before building this: four concurrent
# exapump sessions all succeeded, 302ms against 723ms for the same four run
# one after another.
#
# EXAKIT_UPLOAD_PARALLEL=1 restores exactly the old serial behaviour, and is
# the escape hatch if a database ever objects to the concurrency.
function Get-ExakitUploadParallel {
    $n = 4
    if ($env:EXAKIT_UPLOAD_PARALLEL) {
        $parsed = 0
        if ([int]::TryParse($env:EXAKIT_UPLOAD_PARALLEL, [ref]$parsed)) { $n = $parsed }
    }
    if ($n -lt 1) { $n = 1 }
    if ($n -gt 8) { $n = 8 }
    return $n
}

# ConvertTo-ExapumpArgumentLine - quote an argument vector into the single
# string ProcessStartInfo.Arguments expects.
#
# ProcessStartInfo.ArgumentList, which would do this properly, is .NET Core
# only - PowerShell 5.1 runs on .NET Framework, where Arguments is one string.
# Every argument is quoted unconditionally rather than only those containing a
# space, so there is no rule to get wrong; backslashes immediately before the
# closing quote are doubled, or they would escape it.
function ConvertTo-ExapumpArgumentLine {
    param([Parameter(Mandatory)][string[]]$Argv)
    $quoted = @()
    foreach ($a in $Argv) {
        $v = "$a"
        $v = [regex]::Replace($v, '(\\+)$', '$1$1')
        $v = $v.Replace('"', '\"')
        $quoted += ('"' + $v + '"')
    }
    return ($quoted -join " ")
}

# Collected by Invoke-ExapumpUploadMany. A script-scoped list rather than a
# return value on purpose: PowerShell unrolls collections into the pipeline,
# and this function is called inside a spinner body whose output the caller
# discards, so a returned list would be lost or flattened without warning.
$script:ExakitUploadFailures = @()

# Invoke-ExapumpUploadMany - upload several files CONCURRENTLY, one exapump
# process each, at most Get-ExakitUploadParallel at a time.
#
# Every file still gets its own launch, its own log lines and its own entry in
# the progress bar; what changes is that up to four of them are in flight at
# once. The bar advances as each finishes, so it names the file that JUST
# COMPLETED rather than the one being started - with several running there is
# no single "current" file to name.
#
# Failures are collected, not thrown: with several processes in flight, dying
# on the first would leave the others running and unreaped. The caller decides
# what to do once every process has been waited for.
# Test-ExakitUploadCutShort - did the import connection die mid-transfer? The
# database reads the file through its own import proxy, and when the client
# side of that connection closes before the last byte the engine says
# ETL-5105 "transfer closed with outstanding read data remaining". Seen on
# Windows with exapump 0.12: one or two of eight files per run, a different
# file each time, the same file loading fine a moment later - so the remedy is
# a second attempt, not a message. A malformed file, a missing table or a
# refused login is not this and is never retried. Twin of
# exakit_upload_cut_short.
function Test-ExakitUploadCutShort([string]$Output) {
    return ("$Output" -match 'ETL-5105|transfer closed with outstanding read data|Transferred a partial file|Connection reset by peer|connection was aborted')
}

# Get-ExakitUploadRetries - how many more attempts a cut-short upload gets
# (EXAKIT_UPLOAD_RETRIES, default 2; 0 disables). Twin of exakit_upload_retries.
function Get-ExakitUploadRetries {
    $n = 2
    if ($env:EXAKIT_UPLOAD_RETRIES) {
        $parsed = 0
        if ([int]::TryParse($env:EXAKIT_UPLOAD_RETRIES, [ref]$parsed) -and $parsed -ge 0) { $n = $parsed }
    }
    return $n
}

# Test-ExakitUploadRetryable - is this failed upload worth another attempt? A
# cut transfer (Test-ExakitUploadCutShort) is, and so is a non-zero exit that
# printed NOTHING: seen on Windows in the same runs as the cuts, five files in
# a row - a 415-byte one among them - that the same command loaded a moment
# later. A failure that says what is wrong (a bad row, a missing table, a
# refused login) is never retried. Twin of exakit_upload_retryable.
function Test-ExakitUploadRetryable([int]$ExitCode, [AllowEmptyString()][string]$Output) {
    if (Test-ExakitUploadCutShort -Output $Output) { return $true }
    return ($ExitCode -ne 0 -and -not "$Output".Trim())
}

# Get-ExakitUploadPieceBytes - how big each piece of a re-sent file is
# (EXAKIT_UPLOAD_PIECE_KB, default 128; 0 turns piecing off).
#
# WHY PIECES: the cut is not random. Against Exasol Personal on Windows (the
# database inside the Podman WSL machine) the engine loses the LAST 10-90 KB of
# the file - "failed after 393216 bytes" of a 475 KB file, every time, while a
# 390 KB file never failed. Retrying the same file mostly repeats the same cut
# (customer.csv needed nine attempts), so the file is re-sent in pieces small
# enough to arrive whole: measured 54 of 54 at 128 KB, 3 of 72 failing at 256
# KB. Twin of exakit_upload_piece_bytes.
function Get-ExakitUploadPieceBytes {
    $kb = 128
    if ($null -ne $env:EXAKIT_UPLOAD_PIECE_KB -and "$env:EXAKIT_UPLOAD_PIECE_KB" -ne "") {
        $parsed = 0
        if ([int]::TryParse($env:EXAKIT_UPLOAD_PIECE_KB, [ref]$parsed) -and $parsed -ge 0) { $kb = $parsed }
    }
    return ($kb * 1024)
}

# Test-ExakitUploadPieceable <path> - can this file be re-sent in pieces? A
# plain (uncompressed) delimited text file, bigger than one piece, and no
# bigger than 64 MB - past that the piece count, one exapump launch each,
# costs more than the retry is worth. Twin of exakit_upload_pieceable.
function Test-ExakitUploadPieceable([string]$Path) {
    $piece = Get-ExakitUploadPieceBytes
    if ($piece -le 0) { return $false }
    if ((Split-Path $Path -Leaf) -notmatch '\.(csv|tsv|txt)$') { return $false }
    if (-not (Test-Path $Path)) { return $false }
    $size = (Get-Item $Path).Length
    return ($size -gt $piece -and $size -le 64MB)
}

# Split-ExakitCsvPieces <path> <dir> <bytes> - cut a CSV into pieces of about
# <bytes>, each carrying the header, and return their paths in order.
#
# Byte for byte: a piece is a slice of the original file, so line endings, a
# BOM and every quote survive exactly as they were. Cuts only fall after a
# newline where the double quotes seen so far in the piece are even - a
# newline inside a quoted field is data, not a row boundary. Twin of
# exakit_split_csv_pieces.
function Split-ExakitCsvPieces {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][int]$PieceBytes)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $len = $bytes.Length
    $headEnd = [Array]::IndexOf($bytes, [byte]10)
    if ($headEnd -lt 0 -or $headEnd -ge $len - 1) { return @() }
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $ext = [System.IO.Path]::GetExtension($Path)
    $pieces = @()
    $pos = $headEnd + 1
    $n = 0
    while ($pos -lt $len) {
        $end = $len
        if ($pos + $PieceBytes -lt $len) {
            $cut = [Array]::IndexOf($bytes, [byte]10, $pos + $PieceBytes - 1)
            if ($cut -lt 0) { $cut = $len - 1 }
            $quotes = 0
            $q = [Array]::IndexOf($bytes, [byte]34, $pos, $cut - $pos + 1)
            while ($q -ge 0) { $quotes++; if ($q -ge $cut) { break }; $q = [Array]::IndexOf($bytes, [byte]34, $q + 1, $cut - $q) }
            while (($quotes % 2) -ne 0 -and $cut -lt $len - 1) {
                $next = [Array]::IndexOf($bytes, [byte]10, $cut + 1)
                if ($next -lt 0) { $next = $len - 1 }
                $q = [Array]::IndexOf($bytes, [byte]34, $cut + 1, $next - $cut)
                while ($q -ge 0) { $quotes++; if ($q -ge $next) { break }; $q = [Array]::IndexOf($bytes, [byte]34, $q + 1, $next - $q) }
                $cut = $next
            }
            $end = $cut + 1
        }
        $n++
        $piece = Join-Path $Dir ("{0}.piece{1:D4}{2}" -f $stem, $n, $ext)
        $fs = [System.IO.File]::Create($piece)
        try {
            $fs.Write($bytes, 0, $headEnd + 1)
            $fs.Write($bytes, $pos, $end - $pos)
        } finally { $fs.Dispose() }
        $pieces += $piece
        $pos = $end
    }
    return $pieces
}

# The output of the attempt that sank Invoke-ExakitUploadPieces, for the
# caller's failure message. Script-scoped for the same reason as the failure
# list above.
$script:ExakitUploadPiecesOutput = ""
$script:ExakitUploadRetried = 0

# Invoke-ExakitUploadPieces <path> <schema.table> [delimiter] - re-send a file
# in pieces, ALL OR NOTHING.
#
# The pieces are separate exapump calls, so separate commits: loading them
# straight into the target would leave a half-loaded table behind the one
# piece that never made it - and for a user appending to a table they already
# had, no safe way back. So they go into a staging copy of the target (CREATE
# TABLE ... LIKE), and only once every piece is in does ONE INSERT ... SELECT
# move them across. Any failure drops the staging table; the target is
# exactly as it was. Needs the target to exist - it always does here, because
# a cut import has already created it (the dataset scripts create theirs up
# front, and exapump keeps the table it inferred when the data fails).
# Twin of exakit_upload_pieces.
function Invoke-ExakitUploadPieces {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Target, [string]$Delimiter = ",")
    $script:ExakitUploadPiecesOutput = ""
    $leaf = Split-Path $Path -Leaf
    $stage = "${Target}__EXAKIT_PIECES"
    $max = Get-ExakitUploadRetries
    $extra = @()
    if ($Delimiter -and $Delimiter -ne ",") { $extra = @("--delimiter", $Delimiter) }
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-pieces-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    try {
        $pieces = @(Split-ExakitCsvPieces -Path $Path -Dir $dir -PieceBytes (Get-ExakitUploadPieceBytes))
        if ($pieces.Count -eq 0) { return $false }
        Write-ExakitLog "WARN" "${leaf}: re-sending it as $($pieces.Count) smaller pieces through $stage"
        $r = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "DROP TABLE IF EXISTS $stage; CREATE TABLE $stage LIKE $Target")
        if (-not $r.Success) { $script:ExakitUploadPiecesOutput = "" + $r.Output; return $false }
        foreach ($p in $pieces) {
            $try = 0
            while ($true) {
                $u = Invoke-Exapump (@("upload", $p, "--table", $stage, "-p", $script:ExapumpProfile) + $extra)
                if ($u.Success) { break }
                if ($try -ge $max -or -not (Test-ExakitUploadRetryable -ExitCode $u.ExitCode -Output $u.Output)) {
                    $script:ExakitUploadPiecesOutput = "" + $u.Output
                    $null = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "DROP TABLE IF EXISTS $stage")
                    return $false
                }
                $try++
                Start-Sleep -Seconds $try
            }
        }
        $m = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "INSERT INTO $Target SELECT * FROM $stage; DROP TABLE $stage")
        if (-not $m.Success) {
            $script:ExakitUploadPiecesOutput = "" + $m.Output
            $null = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "DROP TABLE IF EXISTS $stage")
            return $false
        }
        return $true
    } finally {
        Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
    }
}

# Invoke-ExakitUploadRecovery - what every failed upload goes through before
# anyone hears about it. A failure that is not retryable (see
# Test-ExakitUploadRetryable) comes straight back. A retryable one is re-sent
# in pieces when the file allows (Test-ExakitUploadPieceable), otherwise tried
# again whole, with a short pause between attempts. The log keeps every
# attempt; the screen only ever sees the outcome. Returns @{ Success; Output },
# Output being the last attempt's. Twin of exakit_upload_recover.
function Invoke-ExakitUploadRecovery {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Target,
        [string]$Delimiter = ",",
        [int]$ExitCode = 1,
        [AllowEmptyString()][string]$Output = ""
    )
    $leaf = Split-Path $Path -Leaf
    $out = "$Output"
    # Nothing on screen and nothing in the log is what made the Windows
    # failures above impossible to read afterwards. The exit code is all there
    # is, so it is kept.
    if (-not $out.Trim()) { Write-ExakitLog "WARN" "${leaf}: exapump exited with code $ExitCode and printed nothing" }
    $max = Get-ExakitUploadRetries
    if ($max -lt 1 -or -not (Test-ExakitUploadRetryable -ExitCode $ExitCode -Output $out)) {
        return @{ Success = $false; Output = $out }
    }
    if (Test-ExakitUploadPieceable $Path) {
        $script:ExakitUploadRetried++
        if (Invoke-ExakitUploadPieces -Path $Path -Target $Target -Delimiter $Delimiter) {
            return @{ Success = $true; Output = "" }
        }
        return @{ Success = $false; Output = $script:ExakitUploadPiecesOutput }
    }
    $extra = @()
    if ($Delimiter -and $Delimiter -ne ",") { $extra = @("--delimiter", $Delimiter) }
    $try = 0
    while ($try -lt $max) {
        $try++
        $script:ExakitUploadRetried++
        if (Test-ExakitUploadCutShort -Output $out) { $why = "the import connection was cut mid-transfer" } else { $why = "exapump failed without saying why" }
        Write-ExakitLog "WARN" "${leaf}: $why - attempt $($try + 1) of $($max + 1)"
        if ($try -gt 1) { Start-Sleep -Seconds ($try - 1) }
        $again = Invoke-Exapump (@("upload", $Path, "--table", $Target, "-p", $script:ExapumpProfile) + $extra)
        $out = "" + $again.Output
        if ($again.Success) { return @{ Success = $true; Output = $out } }
        if (-not (Test-ExakitUploadRetryable -ExitCode $again.ExitCode -Output $out)) { break }
    }
    return @{ Success = $false; Output = $out }
}

function Invoke-ExapumpUploadMany {
    param(
        [Parameter(Mandatory)][object[]]$Files,
        [Parameter(Mandatory)][string]$Id
    )
    $script:ExakitUploadFailures = @()
    $script:ExakitUploadRetried = 0
    $cli = Get-ExapumpCli
    $cap = Get-ExakitUploadParallel
    $queue = New-Object System.Collections.Queue
    foreach ($f in $Files) { [void]$queue.Enqueue($f) }
    $running = New-Object 'System.Collections.Generic.List[object]'
    $done = 0
    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        while ($queue.Count -gt 0 -and $running.Count -lt $cap) {
            $f = $queue.Dequeue()
            if (-not (Test-Path -LiteralPath $f.Path) -or (Get-Item -LiteralPath $f.Path).Length -eq 0) {
                Warn2 "Data file missing or empty: $($f.Path)"
                $script:ExakitUploadFailures += "$($f.Path) (missing or empty)"
                $done++
                continue
            }
            # NOT Start-Process: it does not retain the process handle, so
            # .ExitCode comes back EMPTY even after HasExited and WaitForExit().
            # Measured here - a deliberately failing exapump call reported an
            # empty exit code, which Test-ExapumpSucceeded would then have had
            # to judge on output alone. System.Diagnostics.Process reports it
            # properly (the same failing call gives 2).
            #
            # Both streams are drained with ReadToEndAsync BEFORE waiting: a
            # redirected pipe that nobody reads fills up and blocks the child
            # forever, and with several uploads in flight that would hang the
            # install rather than slow it.
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $cli
            $psi.Arguments = ConvertTo-ExapumpArgumentLine @("upload", $f.Path, "--table", $f.Target, "-p", $script:ExapumpProfile)
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            $proc = [System.Diagnostics.Process]::Start($psi)
            [void]$running.Add(@{
                File = $f; Proc = $proc
                Out  = $proc.StandardOutput.ReadToEndAsync()
                Err  = $proc.StandardError.ReadToEndAsync()
            })
        }
        if ($running.Count -eq 0) { continue }
        Start-Sleep -Milliseconds 100
        $still = New-Object 'System.Collections.Generic.List[object]'
        foreach ($r in $running) {
            if (-not $r.Proc.HasExited) { [void]$still.Add($r); continue }
            $done++
            # Settles the exit code and guarantees both async reads completed.
            $r.Proc.WaitForExit()
            $out = ""
            try { $out = "$($r.Out.Result)$($r.Err.Result)" } catch { }
            # Logged per file, after that file finishes, so the log still reads
            # as one block per upload instead of interleaved fragments.
            if ($script:LogFile) {
                "exapump upload $($r.File.Path) --table $($r.File.Target) -p $($script:ExapumpProfile)" |
                    Add-Content -Path $script:LogFile
                $out | Add-Content -Path $script:LogFile
            }
            if (Test-ExapumpSucceeded -ExitCode $r.Proc.ExitCode -Output $out) {
                if (-not $script:ExakitUploadQuiet) { Ok "$($r.File.Name) loaded" }
            } else {
                # A CUT TRANSFER IS RECOVERED, one file at a time, before anyone
                # hears about it - re-sent in pieces or tried again whole. See
                # Invoke-ExakitUploadRecovery.
                $rec = Invoke-ExakitUploadRecovery -Path $r.File.Path -Target $r.File.Target `
                    -ExitCode $r.Proc.ExitCode -Output $out
                $out = "" + $rec.Output
                $recovered = [bool]$rec.Success
                if ($recovered) {
                    if (-not $script:ExakitUploadQuiet) { Ok "$($r.File.Name) loaded" }
                } else {
                    Write-ExapumpOutput -Output $out
                    Show-ExakitDbErrorRemedy $out
                    $script:ExakitUploadFailures += "$($r.File.Path) -> $($r.File.Target)"
                }
            }
            # No position to report: the whole upload is ONE segment of the
            # caller's bar, precisely because concurrent waves have no "current"
            # file. What each landing DOES refine is the phase text, so the
            # reader can see the batch draining.
            Set-ExakitProgressPhase "$Id - loaded $done of $($Files.Count) data files"
        }
        $running = $still
    }
}

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

# Get-ExapumpRowCount <schema.table> - row count, or $null if it could not be
# read. Best-effort only: the row-count summary it feeds is cosmetic (shows
# "?" on failure) and the real load validation is 03_verify_setup.sql.
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

# Get-ExapumpRowCountMany <schema> <tables> - count EVERY table in ONE exapump
# invocation instead of one per table. Returns a hashtable of table -> count,
# or $null if any table did not come back.
#
# WHY THIS EXISTS: every exapump call is a separate PROCESS LAUNCH, and on
# Windows a freshly downloaded, unsigned exapump.exe is re-scanned by Defender
# on each one - measured at ~4.4s per launch during an install, against 88ms
# once the scan is cached. A tpch load made 20 launches, 8 of them nothing but
# one COUNT(*) per table. That is why loading weather (10,970 rows) took as
# long as energy (108,050 rows): both made 7 launches. The row counts never
# mattered; the launch count did.
#
# $null is deliberately all-or-nothing: a UNION ALL fails as a whole, so a
# partial read must send the caller back to counting one at a time rather than
# let it report a total that is quietly short.
#
# The token carries the table name (EXAKIT_RC[CUSTOMER=1500]) because one
# result set now holds every count and they have to be told apart. As with
# Get-ExapumpRowCount the echoed query literal cannot match: after "=" it has
# a quote, not a digit.
function Get-ExapumpRowCountMany {
    param(
        [Parameter(Mandatory)][string]$Schema,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Tables
    )
    if ($Tables.Count -eq 0) { return @{} }
    $parts = @()
    foreach ($t in $Tables) {
        $parts += "SELECT 'EXAKIT_RC[$t=' || CAST(COUNT(*) AS VARCHAR(40)) || ']' AS EXAKIT_RC FROM $Schema.$t"
    }
    $result = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, ($parts -join " UNION ALL "))
    if (-not $result.Success) { return $null }
    $counts = @{}
    foreach ($m in [regex]::Matches("$($result.Output)", 'EXAKIT_RC\[([A-Za-z0-9_]+)=(\d+)\]')) {
        $counts[$m.Groups[1].Value] = $m.Groups[2].Value
    }
    foreach ($t in $Tables) {
        if (-not $counts.ContainsKey($t)) { return $null }
    }
    return $counts
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

# THE PROFILE, NOT $HOME - the same distinction Get-ExakitProfileHome exists to
# make. cmd.exe does not expand ~ itself, so the literal reaches the kit and
# this function is the only expansion there is. On a domain machine $HOME is
# the account's home-directory attribute (H:\, \\server\share\user) while the
# user's Downloads are under %USERPROFILE%, so `exakit data-load ~/Downloads/
# sales.csv` - the spelling every doc, skill and agent emits - resolved against
# the network share and reported the file missing while it sat in plain sight.
function Get-ExakitNormalizedPath {
    param([Parameter(Mandatory)][string]$Path)
    $home_ = if (Get-Command Get-ExakitProfileHome -ErrorAction SilentlyContinue) {
        Get-ExakitProfileHome
    } else { $HOME }
    if (-not $home_) { $home_ = $HOME }
    if ($Path -eq "~") { return $home_ }
    if ($Path.StartsWith("~/") -or $Path.StartsWith("~\")) { return Join-Path $home_ $Path.Substring(2) }
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
    if (-not $script:ExakitUploadQuiet) { Info "Creating schema $schemaUc" }
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
        if (-not $script:ExakitUploadQuiet) { Ok "Verified $Target ($rows rows)" }
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

# Get-ExakitDataFileKind <path> - csv | parquet | json | unknown, from the
# name. Twin of exakit_data_file_kind in exapump.sh. A JSON file needs the
# ingest engine rather than exapump, which is why it is named separately:
# Windows x86_64 runs that engine (see Get-JsonTablesEngineAsset), so the kind
# routes the file, and only a machine with no published engine refuses it.
function Get-ExakitDataFileKind {
    param([Parameter(Mandatory)][string]$Path)
    $name = (Split-Path $Path -Leaf).ToLowerInvariant()
    if ($name -match '\.(gz|bz2|zst|xz)$') { $name = $name -replace '\.(gz|bz2|zst|xz)$', '' }
    # .geojson IS json: a FeatureCollection is one document like any other,
    # and every geoportal exports under that name. Twin of the same arm in
    # exakit_data_file_kind.
    if ($name -match '\.(json|geojson|ndjson|jsonl)$')  { return "json" }
    if ($name -match '\.(parquet|pq)$')         { return "parquet" }
    if ($name -match '\.(csv|tsv|txt)$')        { return "csv" }
    return "unknown"
}

# Test-ExakitTxtLooksTabular <path> - does this .txt hold delimited rows? A
# GTFS feed is eleven CSV files all called .txt; a README.txt is not a table.
# The first two lines tell them apart. Twin of _exakit_txt_looks_tabular.
function Test-ExakitTxtLooksTabular {
    param([Parameter(Mandatory)][string]$Path)
    $lines = @()
    try { $lines = @(Get-Content -Path $Path -TotalCount 2 -ErrorAction Stop) } catch { return $false }
    if ($lines.Count -lt 2 -or -not $lines[1]) { return $false }
    return ("" + $lines[0]) -match '[,;\t]'
}

# Get-ExakitCsvInspection <path> - what exapump is about to be handed, looked
# at, not touched: @{ Delimiter; Flags; HeaderOnly }. Delimiter is what the
# header uses (',' ';' or a tab); Flags names what the engine will object to
# ("bom", "crlf"); HeaderOnly is a file with no row under its header.
#
# THE KIT IS A BRIDGE. It hands files to exapump and says what exapump says
# back; it does not rewrite them. What is read from the header is passed on
# as exapump's OWN --delimiter; what exapump cannot take is named before or
# after the attempt; the file goes over as it is. exapump builds its IMPORT
# without a row separator, so a Windows-ended file - on this platform, every
# file - fails with "7.4<CR>" style casts; that fix belongs in exapump
# (one row_separator call), and until it lands the failure reason names the
# cause. Twin of exakit_csv_inspect in exapump.sh.
function Get-ExakitCsvInspection {
    param([Parameter(Mandatory)][string]$Path)
    $result = @{ Delimiter = ","; Flags = ""; HeaderOnly = $false }
    $name = [System.IO.Path]::GetFileName($Path).ToLowerInvariant()
    if ($name -match '\.(gz|bz2|zst|xz)$') { return $result }
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $buffer = New-Object byte[] 3
        $got = $stream.Read($buffer, 0, 3)
        $bom = ($got -eq 3 -and $buffer[0] -eq 0xEF -and $buffer[1] -eq 0xBB -and $buffer[2] -eq 0xBF)
        $stream.Position = 0
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
        # The raw first line, for its ending; then the line under it.
        $raw = New-Object System.Text.StringBuilder
        while (-not $reader.EndOfStream) {
            $c = [char]$reader.Read()
            if ($c -eq "`n") { break }
            [void]$raw.Append($c)
            if ($raw.Length -gt 1048576) { break }
        }
        $first = $raw.ToString()
        $crlf = $first.EndsWith("`r")
        $head = $first.TrimEnd("`r")
        $second = $null
        if (-not $reader.EndOfStream) { $second = $reader.ReadLine() }
    } finally { $stream.Dispose() }
    if (-not $second) { $result.HeaderOnly = $true; return $result }
    if ("$head" -notmatch ',') {
        if ("$head" -match ';') { $result.Delimiter = ";" }
        elseif ("$head" -match "`t") { $result.Delimiter = "`t" }
    }
    $flags = @()
    if ($bom) { $flags += "bom" }
    if ($crlf) { $flags += "crlf" }
    $result.Flags = ($flags -join ",")
    return $result
}

# A .tsv or a tabular .txt is data exapump will not take BY NAME: it picks the
# format from the extension and reads .csv and .parquet only. The kit does not
# rename files behind the user's back, so these are reported with the one
# action that loads them. Twin of _exakit_csv_extension_refused.
function Test-ExakitCsvExtensionRefused {
    param([Parameter(Mandatory)][string]$Path)
    return ([System.IO.Path]::GetFileName($Path).ToLowerInvariant() -match '\.(tsv|txt)(\.gz)?$')
}

# Show-ExakitJsonUnsupported - one honest explanation, with the reason the
# add-on itself gives, instead of a load that fails at the first ingest.
function Show-ExakitJsonUnsupported {
    $why = ""
    if (Get-Command Get-JsonTablesApplicableReason -ErrorAction SilentlyContinue) {
        $why = Get-JsonTablesApplicableReason
    }
    if ($why) {
        Warn2 "JSON files need an engine that is not available on this machine: $why"
    } else {
        Warn2 "JSON files need an engine that is not available on this machine."
    }
    Info "CSV and Parquet load without it. Convert the file, or load it from a supported machine."
}

# --- JSON loading ------------------------------------------------------------
# Windows x86_64 CAN run the ingest engine - Get-JsonTablesEngineAsset publishes
# a build for it, which is why the add-on is offered and installable here - but
# this side had no twin of the shell's JSON load path at all, so every .json
# file was refused on every Windows machine. The refusal even contradicted
# itself, ending "Windows x86_64 is supported; ARM64 is not built yet."
#
# These are the twins of _exakit_json_tables_ready, _exakit_json_tables_ensure
# and exakit_load_local_json in exapump.sh.

# Test-ExakitJsonTablesReady - is the add-on installed AND usable right now?
# Twin of _exakit_json_tables_ready.
function Test-ExakitJsonTablesReady {
    if (-not (Get-Command Get-JsonTablesInstalledVersion -ErrorAction SilentlyContinue)) { return $false }
    if (-not (Get-JsonTablesInstalledVersion)) { return $false }
    $bin = Get-JsonTablesBin
    if (-not $bin) { return $false }
    return (Test-Path $bin)
}

# Test-ExakitJsonTablesApplicable - can this machine have the engine at all?
# Defensive about the module being absent: a kit copy without it cannot install
# the add-on either, so "no" is the honest answer in both cases.
function Test-ExakitJsonTablesApplicable {
    if (-not (Get-Command Test-JsonTablesApplicable -ErrorAction SilentlyContinue)) { return $false }
    return [bool](Test-JsonTablesApplicable)
}

# Confirm-ExakitJsonTablesReady - make the JSON engine usable, saying nothing.
# Twin of _exakit_json_tables_ensure.
#
# A JSON file is just data the user asked to load, so the engine it needs is an
# implementation detail: it installs with its output in the log, under the same
# "Loading your data" spinner as the load itself. No question is asked and no
# install STEP is announced - but the fact that an add-on arrived is, on one
# line, once it has.
#
# Returns $true when the engine is ready, $false when this machine cannot have
# it - that case still speaks up, because a silent failure is worse than a loud
# one.
# ONE ATTEMPT PER RUN, AND THAT IS NOT AN OPTIMISATION. This is called per FILE,
# so a folder of ten JSON files whose engine cannot install downloaded the same
# failing wheel ten times and printed the same three lines ten times - measured
# at 95 seconds to load nothing, of which almost all was re-downloading a wheel
# that had already failed its checksum. Whatever stops the engine installing is
# the same on the second file as on the first. Per-process, so the next
# `exakit data-load` tries again. Twin of $_EXAKIT_JSON_TABLES_BLOCKED.
$script:JsonTablesBlocked = ""
function Confirm-ExakitJsonTablesReady {
    if (Test-ExakitJsonTablesReady) { return $true }
    if ($script:JsonTablesBlocked) {
        Warn2 $script:JsonTablesBlocked
        return $false
    }

    # No dot-sourcing fallback here, unlike the shell: a dot-sourced module
    # inside a function loads into THAT function's scope and is gone on return.
    # Both entry points (setup/exakit.ps1 and setup-windows.ps1) source
    # every add-on module at the top, so a missing one means an old kit copy.
    if (-not (Get-Command Install-JsonTables -ErrorAction SilentlyContinue)) {
        $script:JsonTablesBlocked = "This kit copy does not carry the JSON engine - update the kit first: exakit update"
        Warn2 $script:JsonTablesBlocked
        return $false
    }
    if (-not (Test-ExakitJsonTablesApplicable)) {
        Show-ExakitJsonUnsupported
        return $false
    }
    if (-not (Get-Command Invoke-ExakitMarketplaceApply -ErrorAction SilentlyContinue)) {
        $script:JsonTablesBlocked = "The marketplace installer is not available in this kit build."
        Warn2 $script:JsonTablesBlocked
        return $false
    }
    # The marketplace's own installer, so the add-on arrives exactly as it would
    # from `exakit marketplace`: validated, its skills placed, registered for
    # boot if that is on. It quiets its own detail into the logfile. The shell
    # calls the singular _exakit_marketplace_install_one; this side has only the
    # plural, and one id is the same work.
    try { Invoke-ExakitMarketplaceApply -Ids @("json-tables") | Out-Null } catch { }
    if (-not (Test-ExakitJsonTablesReady)) {
        $script:JsonTablesBlocked = "The JSON engine could not be installed, so this file was not loaded (details: exakit logs setup)."
        Warn2 "The JSON engine could not be installed, so this file was not loaded."
        Info "Everything already in the database is untouched. Details: exakit logs"
        return $false
    }
    # Said once, and only when this run actually installed it - the readiness
    # check above returns before reaching here, so a machine that already has
    # the add-on stays quiet.
    #
    # OkStep rather than Ok: the load narrates on one line, which gates plain Ok
    # to the logfile, and OkStep also hands the spinner's line back before
    # printing so this lands on a row of its own.
    # Nothing on screen - twin of the same silence in exapump.sh. This runs in
    # the middle of a folder load, where the one-line progress bar owns the row
    # and rewrites it continuously, so the line landed inside the bar.
    Write-ExakitLog "OK" "JSON Tables installed - the add-on that loads JSON into Exasol"
    return $true
}

# The ingest engine is LINE-ORIENTED: it reads one complete JSON document per
# line. A pretty-printed file - which is what almost every API, export and
# hand-written fixture actually looks like - fails on its first line with
# "EOF while parsing an object", because line 1 is just an opening brace.
#
# Re-flowing that onto one line changes whitespace, not data, so the kit does
# it rather than telling someone to reformat a file it can read perfectly well.
# A file that is ALREADY line-delimited is passed through untouched; one that is
# not JSON at all is reported as that, instead of as a parse error pointing at a
# line number nobody wrote.
#
# The shell reads the verdict off the exit code. Invoke-ExakitPython THROWS on a
# non-zero exit, with the code buried in the message, so this side prints the
# verdict and always exits 0 - the same three answers, read from stdout.
$script:ExakitJsonNormaliseScript = @'
import json, sys

source, target = sys.argv[1], sys.argv[2]
with open(source, encoding="utf-8-sig") as handle:
    raw = handle.read()

try:
    document = json.loads(raw)
except ValueError:
    # Not one whole document. It may already be NDJSON - every non-empty line a
    # document of its own - which is exactly what the engine wants.
    for line in raw.splitlines():
        if not line.strip():
            continue
        try:
            json.loads(line)
        except ValueError:
            print("invalid")
            raise SystemExit(0)
    print("ndjson")
    raise SystemExit(0)

with open(target, "w", encoding="utf-8") as out:
    if isinstance(document, list):
        # A top-level array is a list of records: one per line.
        for item in document:
            out.write(json.dumps(item) + "\n")
    else:
        out.write(json.dumps(document) + "\n")
print("normalised")
'@

# Import-ExakitLocalJson - ingest a JSON file and load what comes out of it.
# Twin of exakit_load_local_json. The target is decided by the CALLER, before
# anything runs, so JSON asks exactly what CSV and Parquet ask: one
# SCHEMA.TABLE, then it loads. Nothing here prompts.
#
# Nested JSON legitimately yields SEVERAL tables. One table lands on the target
# exactly; several keep it as their shared prefix, so the name the user typed
# still describes every table the document produced.
function Import-ExakitLocalJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Target)
    $schema = Get-ExakitTargetSchema $Target
    $base = ($Target -split "\.", 2)[1]

    if (-not (Confirm-ExakitJsonTablesReady)) { return $false }

    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-json-load-$([guid]::NewGuid().ToString("N"))"
    try {
        New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    } catch {
        Warn2 "Could not create a temporary directory for the JSON ingest."
        return $false
    }
    try {
        $ingestInput = $Path
        $normalised = Join-Path $tmpDir "normalised.json"
        $verdict = ""
        try {
            $verdict = (Invoke-ExakitPython $script:ExakitJsonNormaliseScript $Path $normalised).Trim()
        } catch {
            # No Python, or an unreadable file: let the engine have its say.
            $verdict = ""
        }
        if ($verdict -eq "normalised") { $ingestInput = $normalised }
        if ($verdict -eq "invalid") {
            Warn2 "$(Get-ExakitTilde $Path) is not valid JSON."
            Info "It must be one JSON document, or NDJSON with one document per line."
            Info "Nothing was loaded; the database is unchanged."
            return $false
        }

        $outDir = Join-Path $tmpDir "out"
        $engine = Get-JsonTablesBin
        # Through Invoke-JsonTablesLogged so the engine's own words land in the
        # add-on's log too - the very file the failure message below points at.
        if ((Invoke-JsonTablesLogged -Exe $engine -Arguments @("ingest", "--input", $ingestInput, "--output-dir", $outDir)) -ne 0) {
            Warn2 "This JSON file could not be read - see: exakit logs json-tables"
            Info "It must be one JSON document, or NDJSON with one document per line."
            Info "Nothing was loaded; the database is unchanged."
            return $false
        }

        $files = @()
        if (Test-Path $outDir) {
            $files = @(Get-ChildItem -Path $outDir -Filter "*.parquet" -Recurse -File |
                Sort-Object FullName | ForEach-Object { $_.FullName })
        }
        if ($files.Count -eq 0) {
            Warn2 "No tables came out of $(Get-ExakitTilde $Path)."
            Info "Check the file is JSON or NDJSON, then retry: exakit data-load"
            return $false
        }

        Confirm-ExakitSchemaExists $schema | Out-Null
        $loaded = @()
        if ($files.Count -eq 1) {
            Invoke-ExapumpUpload $files[0] $Target | Out-Null
            Confirm-ExakitLoadedTable $Target
            $loaded = @($Target)
        } else {
            foreach ($file in $files) {
                $table = Get-ExakitUpperTableTarget "$schema.$($base)_$(Get-ExakitTableName $file)"
                Invoke-ExapumpUpload $file $table | Out-Null
                Confirm-ExakitLoadedTable $table
                $loaded += $table
            }
        }

        Set-ExakitManifestValue "data.last_load.type" "local_json"
        Set-ExakitManifestValue "data.last_load.target" ($loaded -join ", ")
        Set-ExakitManifestValue "data.last_load.source" $Path
        $script:ExakitLastLoadTarget = ($loaded -join ", ")
        return $true
    } finally {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
    }
}

function Import-ExakitLocalFile {
    $defaultPath = if ($env:EXAKIT_DATA_FILE) { $env:EXAKIT_DATA_FILE } else { "" }
    while ($true) {
        $rawPath = Read-ExakitPrompt "Local CSV / Parquet / JSON file - or a folder of them (type back to return)" $defaultPath
        if ($rawPath -match '^(b|back)$') {
            Info "Returning to data loading options."
            return "back"
        }
        if (-not $rawPath) {
            Warn2 "Please enter a local CSV, Parquet or JSON file, a folder of them, or type back to return."
            # No console means Read-ExakitPrompt returns the same default
            # forever, so a bad or missing EXAKIT_DATA_FILE must fail here
            # instead of looping.
            if (-not (Test-ExakitInteractive)) {
                Fail "No local file to load - set EXAKIT_DATA_FILE to a readable CSV, Parquet or JSON file."
            }
            continue
        }
        $path = Get-ExakitNormalizedPath $rawPath
        # A FOLDER is a bulk load: every data file in it, one table each. It is
        # answered by the same prompt (and the same EXAKIT_DATA_FILE) as a single
        # file, because "here is my data" is the same request either way.
        if (Test-Path -LiteralPath $path -PathType Container) { return (Import-ExakitLocalFolder -Path $path) }
        if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 0) {
            # Refuse what the loader cannot take BEFORE it runs. Twin of the same
            # check in exakit_load_local_file: an unsupported file used to die
            # inside the loader and be recorded as a failed step.
            $llfKind = Get-ExakitDataFileKind $path
            $llfName = [System.IO.Path]::GetFileName($path).ToLowerInvariant()
            # A .tsv or .txt is data exapump refuses BY NAME; the kit says so
            # and does not rename it behind the user's back.
            if ($llfKind -eq "csv" -and (Test-ExakitCsvExtensionRefused $path)) {
                Warn2 "$llfName looks tabular, but exapump reads .csv and .parquet only - rename it to .csv and load that."
                if (-not (Test-ExakitInteractive)) { exit 2 }
                continue
            }
            if ($llfKind -eq "unknown") {
                if (-not (Test-ExakitInteractive)) {
                    Write-Host ""; Write-Host "  [x] Cannot load '$llfName': only .csv and .parquet (and .json / .geojson with the JSON Tables add-on) are supported - rename or convert the file first."
                    exit 2
                }
                Warn2 "Only .csv and .parquet (and .json / .geojson with the JSON Tables add-on) can be loaded: $llfName"
                continue
            }
            if ($llfKind -eq "csv") {
                # The delimiter is read from the header now, so the only thing
                # left to say is which one was found.
                $llfHead = ""
                try { $llfHead = (Get-Content -Path $path -TotalCount 1 -ErrorAction Stop) } catch { }
                if ("$llfHead" -notmatch ',') {
                    if ("$llfHead" -match ';') { Info "$llfName is semicolon-separated - loading it as such." }
                    elseif ("$llfHead" -match "`t") { Info "$llfName is tab-separated - loading it as such." }
                }
            }
            break
        }
        Warn2 "File not found or empty: $path"
        if (-not (Test-ExakitInteractive)) {
            Write-Host ""; Write-Host "  [x] File not found or empty: $path"; exit 2
        }
    }
    $kind = Get-ExakitDataFileKind $path
    # A JSON file this machine can never load is refused HERE, before the user
    # picks a table for a load that cannot happen. What is NOT settled here is
    # whether the engine is INSTALLED: that is this command's problem, and
    # Import-ExakitLocalJson installs it once the target is known - so nobody
    # acquires an add-on for a load they then back out of.
    if ($kind -eq "json" -and -not (Test-ExakitJsonTablesApplicable)) {
        Show-ExakitJsonUnsupported
        # An unattended run (EXAKIT_DATA_FILE) has nobody to read that advice:
        # it must FAIL, or the agent reads success off a load that never ran.
        if (-not (Test-ExakitInteractive)) {
            Fail "JSON files cannot be loaded on this machine - convert $path to CSV/Parquet, or load it from a supported machine."
        }
        return "back"
    }
    $schema = if ($env:EXAKIT_SCHEMA) { $env:EXAKIT_SCHEMA } else { "STARTER_KIT" }
    $defaultTable = "$schema.$(Get-ExakitTableName $path)"
    # EXAKIT_DATA_TABLE pre-answers the target the same way the path is
    # pre-answered - as the prompt's default, which a no-console run keeps.
    if ($env:EXAKIT_DATA_TABLE) { $defaultTable = $env:EXAKIT_DATA_TABLE }
    while ($true) {
        $target = Read-ExakitPrompt "Target table (SCHEMA.TABLE, back to return)" $defaultTable
        if ($target -match '^(b|back)$') {
            Info "Returning to data loading options."
            return "back"
        }
        if (Test-ExakitTableTarget $target) { break }
        Warn2 "Target table must look like SCHEMA.TABLE and use letters, numbers, or underscores."
        if (-not (Test-ExakitInteractive)) {
            Fail "EXAKIT_DATA_TABLE must look like SCHEMA.TABLE and use letters, numbers, or underscores."
        }
    }
    $target = Get-ExakitUpperTableTarget $target

    # Every file kind is asked the same two things, in the same order, before
    # any work starts: the file, then SCHEMA.TABLE. What has to happen after
    # that - an engine to install, a conversion to run - is this command's
    # problem, not the user's, so none of it reaches the screen.
    if ($kind -eq "json") {
        $script:ExakitUploadQuiet = $true
        $script:ExakitActiveLabel = "Loading your data"
        try {
            if (-not (Import-ExakitLocalJson -Path $path -Target $target)) { return "back" }
        } finally {
            $script:ExakitUploadQuiet = $false
            $script:ExakitActiveLabel = ""
        }
        $into = $target
        if ($script:ExakitLastLoadTarget) { $into = $script:ExakitLastLoadTarget }
        Ok "Loaded $path into $into"
        return
    }

    # One label, one spinner, for the whole job - the twin of what exapump.sh
    # does with EXAKIT_UPLOAD_QUIET and EXAKIT_ACTIVE_LABEL.
    $script:ExakitUploadQuiet = $true
    $script:ExakitActiveLabel = "Loading your data"
    try {
        Confirm-ExakitSchemaExists (Get-ExakitTargetSchema $target) | Out-Null
        Invoke-ExapumpUpload $path $target | Out-Null
        Set-ExakitManifestValue "data.last_load.type" "local_file"
        Set-ExakitManifestValue "data.last_load.target" $target
        Set-ExakitManifestValue "data.last_load.source" $path
        Confirm-ExakitLoadedTable $target
    } finally {
        $script:ExakitUploadQuiet = $false
        $script:ExakitActiveLabel = ""
    }
    Ok "Loaded $path into $target"
}

# --- bulk folder load --------------------------------------------------------
# Twin of the bulk folder load in exapump.sh. One folder in, every data file in
# it loaded, one table per file. The folder is read at its TOP LEVEL only:
# subfolders are never descended into and hidden files are left alone, so a
# directory of exports loads without dragging in a nested archive\, the images
# beside the data, or a desktop.ini.

# Get-ExakitBulkFileKind - Get-ExakitDataFileKind, minus .txt.
#
# Naming one file says "this is my data, whatever it is called", and .txt is a
# reasonable CSV there. Scanning a folder says nothing of the kind: a README.txt
# beside the exports is not a table, and loading one as CSV would be a silent
# surprise rather than a service. Twin of exakit_bulk_file_kind.
# A .txt is decided by its CONTENT: a GTFS feed is eleven CSV files all called
# .txt, a README.txt is not a table. Twin of exakit_bulk_file_kind.
# --- load receipts -------------------------------------------------------
#
# What a repeated folder load needs to know, and could not ask anything for:
# "are the rows already in that table MINE?". exapump's upload APPENDS -- a
# folder loaded twice ends with every row in it twice, silently, which is the
# one outcome a data tool must never produce by accident. The database can say
# a table holds 1,204 rows; it cannot say they came from sales.csv. So each
# file that lands writes a line here, and a later run compares.
# Twins of exakit_load_receipt_* in exapump.sh.
function Get-ExakitLoadReceiptsPath { return (Join-Path $script:CacheDir "load-receipts.tsv") }
function Get-ExakitLoadInflightPath { return (Join-Path $script:CacheDir "load-inflight") }

function Write-ExakitLoadReceipt {
    param([Parameter(Mandatory)][string]$Target,
          [Parameter(Mandatory)][string]$File,
          $Rows)
    try {
        $path = Get-ExakitLoadReceiptsPath
        $dir = Split-Path $path -Parent
        if (-not (Test-Path $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        $bytes = (Get-Item -LiteralPath $File).Length
        $rowText = "0"
        if ($null -ne $Rows) { $rowText = "$Rows" }
        $epoch = [int][double]::Parse((Get-Date -UFormat %s))
        $line = "{0}`t{1}`t{2}`t{3}`t{4}`t{5}" -f $Target.ToUpper(), $bytes,
            (Get-ExakitSha256 -Path $File), $rowText, $epoch, (Split-Path $File -Leaf)
        Add-Content -LiteralPath $path -Value $line -Encoding UTF8
    } catch {
        # Bookkeeping must never fail a load that worked.
    }
}

# Get-ExakitLoadReceipt <target> <file> - the remembered row count when THIS
# file already landed in THAT table, otherwise $null.
#
# Size first, hash only on a size match: the hash of a 2 GB parquet is seconds
# of reading to answer a question its byte count settles for free almost every
# time. Same trick the in-folder duplicate check uses.
function Get-ExakitLoadReceipt {
    param([Parameter(Mandatory)][string]$Target, [Parameter(Mandatory)][string]$File)
    try {
        $path = Get-ExakitLoadReceiptsPath
        if (-not (Test-Path $path)) { return $null }
        $bytes = (Get-Item -LiteralPath $File).Length
        $prefix = "{0}`t{1}`t" -f $Target.ToUpper(), $bytes
        # Newest last: a table loaded, replaced and loaded again has several
        # lines, and the last written is the one describing what is in there now.
        $hit = $null
        foreach ($line in @(Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
            if ($line.StartsWith($prefix)) { $hit = $line }
        }
        if ($null -eq $hit) { return $null }
        $parts = $hit -split "`t"
        if ($parts.Count -lt 4) { return $null }
        if ($parts[2] -ne (Get-ExakitSha256 -Path $File)) { return $null }
        return [long]$parts[3]
    } catch {
        return $null
    }
}

# Get-ExakitFileAlreadyLanded <schema> <file> - has this exact file already been
# loaded into this schema, and is every table it made still holding exactly what
# it held? The total rows across them, or $null. Twin of
# exakit_file_already_landed: a JSON document never lands in the table the plan
# named, so its own receipts are the only way to tell it was loaded.
function Get-ExakitFileAlreadyLanded {
    param([Parameter(Mandatory)][string]$Schema, [Parameter(Mandatory)][string]$File)
    try {
        $path = Get-ExakitLoadReceiptsPath
        if (-not (Test-Path $path)) { return $null }
        $bytes = "" + (Get-Item -LiteralPath $File).Length
        $pfx = $Schema.ToUpper() + "."
        # Size before hash: no point reading a 2 GB file to answer a question
        # its byte count settles.
        $lines = @(Get-Content -LiteralPath $path -ErrorAction SilentlyContinue | Where-Object {
            $f = $_ -split "`t"; $f.Count -ge 4 -and $f[0].StartsWith($pfx) -and $f[1] -eq $bytes })
        if ($lines.Count -eq 0) { return $null }
        $sha = Get-ExakitSha256 -Path $File
        # Newest last wins, per table.
        $seen = [ordered]@{}
        foreach ($line in $lines) {
            $f = $line -split "`t"
            if ($f[2] -eq $sha) { $seen[$f[0]] = $f[3] }
        }
        if ($seen.Count -eq 0) { return $null }
        $total = [long]0
        foreach ($t in $seen.Keys) {
            # Every one of them, not just the first: a document that shredded
            # into four tables and lost one is a load to redo, not one to skip.
            $n = Get-ExakitTableRowCount $t
            if ($null -eq $n -or $n -eq "absent" -or "$n" -ne "$($seen[$t])") { return $null }
            $total += [long]$n
        }
        if ($total -le 0) { return $null }
        return $total
    } catch {
        return $null
    }
}

function Remove-ExakitLoadReceipt {
    param([Parameter(Mandatory)][string]$Target)
    try {
        $path = Get-ExakitLoadReceiptsPath
        if (-not (Test-Path $path)) { return }
        $prefix = $Target.ToUpper() + "`t"
        $keep = @(Get-Content -LiteralPath $path | Where-Object { -not $_.StartsWith($prefix) })
        Set-Content -LiteralPath $path -Value $keep -Encoding UTF8
    } catch {
    }
}

# A crumb dropped before an upload and swept after it. A folder load killed
# mid-file leaves the target holding PART of that file and no receipt, which is
# indistinguishable from a table the reader filled themselves -- unless we said,
# before starting, that we were about to write to it. That is the whole
# difference between "resume this" and "ask before touching the reader's data".
function Set-ExakitLoadInflight {
    param([Parameter(Mandatory)][string]$Target)
    try {
        $path = Get-ExakitLoadInflightPath
        $dir = Split-Path $path -Parent
        if (-not (Test-Path $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        Set-Content -LiteralPath $path -Value $Target.ToUpper() -Encoding UTF8
    } catch {
    }
}
function Clear-ExakitLoadInflight {
    try { Remove-Item -LiteralPath (Get-ExakitLoadInflightPath) -Force -ErrorAction SilentlyContinue } catch {}
}
function Get-ExakitLoadInflight {
    try {
        $path = Get-ExakitLoadInflightPath
        if (-not (Test-Path $path)) { return "" }
        return ("" + (Get-Content -LiteralPath $path -First 1)).Trim().ToUpper()
    } catch {
        return ""
    }
}

# Get-ExakitBulkDecisions <chosen> <schema> - one object per planned file with
# an Action of load / done / resume / clash. Twin of exakit_bulk_decide.
#
# This is the answer to "I ran it again after it stopped". exapump's upload
# APPENDS, so without this every re-run doubles the rows of every file that had
# already made it - no error, no warning, just twice the data.
function Get-ExakitBulkDecisions {
    param([Parameter(Mandatory)][string[]]$Chosen, [Parameter(Mandatory)][string]$Schema)
    $inflight = Get-ExakitLoadInflight
    $out = @()
    foreach ($row in $Chosen) {
        $parts = $row.Split('|', 3)
        $file = $parts[2]
        $target = ("{0}.{1}" -f $Schema, $parts[1]).ToUpper()
        $rows = Get-ExakitTableRowCount $target
        $action = "load"
        $had = $null
        # $null is a database that could not be asked - not an empty one. Load
        # is the honest move: refusing because we could not look would turn an
        # unreachable listing into a failed job.
        if ($null -ne $rows -and $rows -ne "absent" -and [long]$rows -gt 0) {
            $had = [long]$rows
            $seen = Get-ExakitLoadReceipt $target $file
            # The receipt alone is not enough. It says what WE put there; the
            # table can have been dropped and rebuilt, truncated or added to
            # since, and a receipt that outlives its rows would skip a file the
            # schema no longer holds.
            if ($null -ne $seen -and $seen -eq $had) {
                $action = "done"
            } elseif ($inflight -eq $target) {
                $action = "resume"
            } else {
                $action = "clash"
            }
        } elseif ($null -ne $rows -and $parts[0] -eq "json") {
            # The named target holds nothing - but a JSON document does not land
            # in the table the plan named, so "nothing there" is not the same as
            # "never loaded". Ask what this FILE has landed.
            $landedRows = Get-ExakitFileAlreadyLanded $Schema $file
            if ($null -ne $landedRows) { $action = "done"; $had = $landedRows }
        }
        $out +=[pscustomobject]@{ Action = $action; File = $file; Target = $target; Table = $parts[1]; Kind = $parts[0]; Had = $had }
    }
    return $out
}

# Read-ExakitBulkClashAnswer - what to do about target tables that already hold
# rows this kit did not put there. Asked ONCE for the whole set, not once per
# file: eight files into a schema someone has been using is one decision, and
# asking it eight times is how a reader ends up answering "yes" to the one they
# meant to refuse.
#
# Skip is the default, and the default without a terminal. Appending by accident
# is unrecoverable without knowing which rows were new; skipping costs a re-run.
function Read-ExakitBulkClashAnswer {
    param([Parameter(Mandatory)]$Decisions, [Parameter(Mandatory)][string]$Schema)
    $clashes = @($Decisions | Where-Object { $_.Action -eq "clash" })
    if ($clashes.Count -eq 0) { return "skip" }
    Write-Host ""
    Warn2 "$(Get-ExakitPlural $clashes.Count 'table') in $Schema already holding rows this kit did not load:"
    foreach ($c in $clashes) {
        Write-Host ("      {0}{1}{2} {3} {4}->{5} {6} already" -f $script:UiDim, $script:UiBullet, $script:UiReset,
            (Split-Path $c.File -Leaf), $script:UiDim, $script:UiReset, (Get-ExakitRowsLabel $c.Had))
    }
    if (-not (Test-ExakitInteractive)) {
        Info "Skipping those files. Re-run with EXAKIT_ON_EXISTING=replace or =append to decide otherwise."
        return "skip"
    }
    while ($true) {
        $answer = Read-ExakitPrompt "Those files: (s)kip, (r)eplace what is there, or (a)ppend to it" "s"
        switch -Regex ($answer) {
            '^[sS]' { return "skip" }
            '^[rR]' { return "replace" }
            '^[aA]' { return "append" }
            default { Warn2 "Answer s, r or a." }
        }
    }
}

# Get-ExakitRowsLabel <rows> - "339 rows" from a count, or "" when the database
# could not be asked. Never "0 rows" dressed up as a success.
function Get-ExakitRowsLabel {
    param($Rows)
    if ($null -eq $Rows -or $Rows -eq "absent") { return "" }
    return (Get-ExakitPlural ([long]$Rows) 'row')
}

# Show-ExakitBulkResume - said BEFORE the bar starts, because "why is it only
# loading three of my eight files?" is a question a reader should never have to
# ask a progress bar.
function Show-ExakitBulkResume {
    param([Parameter(Mandatory)]$Decisions, [Parameter(Mandatory)][string]$Clash)
    $done = @($Decisions | Where-Object { $_.Action -eq "done" }).Count
    $res  = @($Decisions | Where-Object { $_.Action -eq "resume" }).Count
    if ($done -gt 0) {
        $it = "them"
        if ($done -eq 1) { $it = "it" }
        Info "$(Get-ExakitPlural $done 'file') already loaded from this folder - skipping $it."
    }
    if ($res -gt 0) {
        Info "$(Get-ExakitPlural $res 'file') was left half-loaded by an interrupted run - reloading from scratch."
    }
    if ($Clash -eq "replace") { Info "Replacing what is in the tables that already held rows." }
    if ($Clash -eq "append")  { Warn2 "Appending to the tables that already held rows - those rows stay, and these go on top." }
}

# Show-ExakitBulkOutcomes - what happened, per file, on screen, after the bar.
#
# The count alone ("Loaded 7 of 8") does not say WHICH seven, and the one line
# that named the failure was printed INSIDE a live progress bar forty lines
# earlier. A reader who looks away for the ten seconds that matters is left with
# a number and a pointer to a log. This is the table they actually needed.
function Show-ExakitBulkOutcomes {
    param([Parameter(Mandatory)]$Outcomes, [Parameter(Mandatory)][string]$Schema)
    if (@($Outcomes).Count -eq 0) { return }
    # ONE width for the name column and ONE for the mark, measured from what is
    # actually in this table. The marks are not all the same length without
    # colour ("[ok]", "[x]", "-"), and padding only the names put every target
    # in a different column - a list whose whole job is to be scanned down.
    $markOk = $script:UiTick; $markSkip = $script:UiBullet; $markFail = $script:UiCross
    $markWidth = @($markOk.Length, $markSkip.Length, $markFail.Length | Measure-Object -Maximum).Maximum
    $nameWidth = 0
    foreach ($o in $Outcomes) {
        $n = (Split-Path $o.File -Leaf).Length
        if ($n -gt $nameWidth) { $nameWidth = $n }
    }
    if ($nameWidth -gt 44) { $nameWidth = 44 }
    Write-Host ""
    Write-Host ("   {0}into {1}{2}" -f $script:UiDim, $Schema, $script:UiReset)
    foreach ($o in $Outcomes) {
        $mark = $markFail; $colour = $script:UiErr
        if ($o.Status -eq "ok")   { $mark = $markOk;   $colour = $script:UiOk }
        if ($o.Status -eq "skip") { $mark = $markSkip; $colour = $script:UiDim }
        $pad = " " * ($markWidth - $mark.Length)
        Write-Host ("   {0}{1}{2}{3} {4} {5}->{6} {7}  {8}" -f $colour, $mark, $script:UiReset, $pad,
            (Split-Path $o.File -Leaf).PadRight($nameWidth), $script:UiDim, $script:UiReset, $o.Table, $o.Detail)
        # The reason under the row it belongs to, not forty lines up the screen
        # inside a progress bar that has since been overwritten.
        if ($o.Why) { Write-Host ("     {0}{1}{2}" -f $script:UiDim, $o.Why, $script:UiReset) }
    }
    Write-Host ""
}

function Get-ExakitBulkFileKind {
    param([Parameter(Mandatory)][string]$Path)
    $name = (Split-Path $Path -Leaf).ToLowerInvariant()
    if ($name -match '\.txt\.(gz|bz2|zst|xz)$') { return "unknown" }
    if ($name -match '\.txt$') { if (Test-ExakitTxtLooksTabular $Path) { return "csv" } else { return "unknown" } }
    return (Get-ExakitDataFileKind $Path)
}

# Get-ExakitBulkFolderPlan <dir> - the plan for a folder, one string per
# top-level file, in the order the files will load:
#
#   load|<kind>|<table>|<path>          kind: csv | parquet | json
#   skip|<reason>|<detail>|<path>       reason: unsupported | empty | json-unsupported
#                                             | duplicate-content | duplicate-table
#
# For a skipped duplicate, <detail> names the file it duplicates. Two kinds of
# duplicate are refused, because both silently lose data: byte-identical files
# would load the same rows into two tables, and two names that resolve to the
# SAME table would have the second overwrite the first.
#
# JSON is planned as load|json on a machine that can have the JSON Tables engine
# (Windows x86_64) and loaded through Import-ExakitLocalJson, as a single JSON
# file is. Elsewhere (ARM64) it is reported as json-unsupported with
# Get-JsonTablesApplicableReason - the same answer a single JSON file gets.
#
# Files are ordered by ORDINAL bytes, not by the machine's culture, so which of
# two duplicates wins is the same answer on every machine - the twin sorts with
# LC_ALL=C for exactly that reason.
function Get-ExakitBulkFolderPlan {
    param([Parameter(Mandatory)][string]$Path)
    $names = @(Get-ChildItem -Path $Path -File -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name })
    if ($names.Count -gt 1) { [Array]::Sort($names, [StringComparer]::Ordinal) }

    $plan = New-Object 'System.Collections.Generic.List[string]'
    $keptPaths  = New-Object 'System.Collections.Generic.List[string]'
    $keptTables = New-Object 'System.Collections.Generic.List[string]'
    $keptSizes  = New-Object 'System.Collections.Generic.List[long]'
    $keptHashes = New-Object 'System.Collections.Generic.List[string]'
    # Asked once per folder: the answer is the machine's, not the file's.
    $jsonOk = Test-ExakitJsonTablesApplicable

    foreach ($name in $names) {
        $full = Join-Path $Path $name
        $table = Get-ExakitTableName $full
        $kind = Get-ExakitBulkFileKind $full
        if ($kind -eq "unknown") { [void]$plan.Add("skip|unsupported||$full"); continue }
        if ($kind -eq "json" -and -not $jsonOk) { [void]$plan.Add("skip|json-unsupported||$full"); continue }
        $size = (Get-Item $full).Length
        if ($size -le 0) { [void]$plan.Add("skip|empty||$full"); continue }
        # A CSV whose only line is its header has no table in it (GTFS ships
        # shapes.txt that way when a feed has no shapes). Named as such rather
        # than failing later inside exapump's schema inference.
        if ($kind -eq "csv") {
            $two = @(Get-Content -Path $full -TotalCount 2 -ErrorAction SilentlyContinue)
            if ($two.Count -lt 2 -or -not $two[1]) { [void]$plan.Add("skip|header-only||$full"); continue }
            if (Test-ExakitCsvExtensionRefused $full) { [void]$plan.Add("skip|extension||$full"); continue }
        }

        $hash = ""
        $dupe = ""
        $reason = ""
        for ($i = 0; $i -lt $keptPaths.Count; $i++) {
            if ($keptTables[$i] -eq $table) {
                $dupe = $keptPaths[$i]; $reason = "duplicate-table"; break
            }
            if ($keptSizes[$i] -eq $size) {
                # Hash only what could actually match: same-size files are the
                # only candidates, so a folder of differently sized exports is
                # never read twice just to prove they differ.
                if (-not $hash) { $hash = Get-ExakitSha256 $full }
                if (-not $keptHashes[$i]) {
                    $keptHashes[$i] = Get-ExakitSha256 $keptPaths[$i]
                }
                if ($keptHashes[$i] -eq $hash) {
                    $dupe = $keptPaths[$i]; $reason = "duplicate-content"; break
                }
            }
        }
        if ($dupe) {
            [void]$plan.Add("skip|$reason|$(Split-Path $dupe -Leaf)|$full")
            continue
        }
        [void]$keptPaths.Add($full)
        [void]$keptTables.Add($table)
        [void]$keptSizes.Add($size)
        [void]$keptHashes.Add($hash)
        [void]$plan.Add("load|$kind|$table|$full")
    }
    return $plan.ToArray()
}

# Get-ExakitBulkKindsPresent <plan> - the loadable kinds in the plan, in the
# order the format menu shows them.
# Get-ExakitPlural <n> <noun> - "1 file", "2 files". Twin of exakit_plural in
# exapump.sh: "file(s)" is a form nobody says out loud, and it read as
# unfinished on the count that is most common of all.
function Get-ExakitPlural {
    param([int]$N, [string]$Noun)
    if ($N -eq 1) { return "$N $Noun" }
    return "$N ${Noun}s"
}

function Get-ExakitBulkKindsPresent {
    param([string[]]$Plan)
    $found = New-Object 'System.Collections.Generic.List[string]'
    foreach ($kind in @("csv", "parquet", "json")) {
        if ($Plan | Where-Object { $_.StartsWith("load|$kind|") }) { [void]$found.Add($kind) }
    }
    return $found.ToArray()
}

# Get-ExakitBulkLabel <kind> - the format's name as the menu says it.
function Get-ExakitBulkLabel {
    param([Parameter(Mandatory)][string]$Kind)
    switch ($Kind) {
        "csv"     { return "CSV" }
        "parquet" { return "Parquet" }
        "json"    { return "JSON" }
        default   { return $Kind }
    }
}

# Show-ExakitBulkPlan - what is about to happen, and what will not. Duplicates
# are named one by one, because being skipped is a surprise worth explaining;
# files of other kinds are counted, because a folder of exports beside two
# hundred images should not print two hundred lines.
function Show-ExakitBulkPlan {
    param([string[]]$Plan, [string[]]$Chosen, [string]$Schema, [string]$Path)
    # No header line - the question underneath names the count, the folder and
    # the schema in one sentence. Twin of exakit_bulk_print_plan in exapump.sh.
    foreach ($row in $Chosen) {
        $parts = $row.Split('|', 3)
        # Table name only: the schema is the same for every row and is said
        # once, in the question underneath.
        Write-Host ("      {0}{1}{2} {3} {4}->{5} {6}" -f $script:UiDim, $script:UiBullet, $script:UiReset,
            (Split-Path $parts[2] -Leaf), $script:UiDim, $script:UiReset, $parts[1])
    }
    foreach ($row in ($Plan | Where-Object { $_.StartsWith("skip|duplicate") })) {
        $parts = $row.Split('|', 4)
        if ($parts[1] -eq "duplicate-content") { $why = "identical to $($parts[2])" }
        else { $why = "same target table as $($parts[2])" }
        Write-Host ("      {0}! {1} skipped ({2}){3}" -f $script:UiDim,
            (Split-Path $parts[3] -Leaf), $why, $script:UiReset)
    }
    $json = @($Plan | Where-Object { $_.StartsWith("skip|json-unsupported|") }).Count
    if ($json -gt 0) {
        $why = ""
        if (Get-Command Get-JsonTablesApplicableReason -ErrorAction SilentlyContinue) {
            $why = Get-JsonTablesApplicableReason
        }
        if ($why) { Warn2 "$(Get-ExakitPlural $json 'JSON file') skipped: $why" }
        else { Warn2 "$(Get-ExakitPlural $json 'JSON file') skipped: no ingest engine is available on this machine." }
        Info "CSV and Parquet load without it. Load the JSON files from macOS, Linux or WSL."
    }
    # The two counts on ONE line when both happen, each with its own plural. Two
    # near-identical sentences stacked under a three-file plan was more lines
    # about what is NOT being loaded than about what is.
    $ignored = ""
    $other = @($Plan | Where-Object { $_.StartsWith("skip|unsupported|") }).Count
    if ($other -gt 0) { $ignored = "$other of other kinds" }
    $empty = @($Plan | Where-Object { $_.StartsWith("skip|empty|") }).Count
    if ($empty -gt 0) {
        if ($ignored) { $ignored = "$ignored, $empty empty" } else { $ignored = "$empty empty" }
    }
    $headerOnly = @($Plan | Where-Object { $_.StartsWith("skip|header-only|") }).Count
    if ($headerOnly -gt 0) {
        $phrase = "$headerOnly with a header and no rows"
        if ($ignored) { $ignored = "$ignored, $phrase" } else { $ignored = $phrase }
    }
    # Not folded into "ignored": these hold data, and one rename loads them.
    $ext = @($Plan | Where-Object { $_.StartsWith("skip|extension|") }).Count
    if ($ext -gt 0) {
        Write-Host ("      {0}! {1} tabular but named .txt/.tsv - exapump reads .csv and .parquet only; rename to .csv to load{2}" -f $script:UiDim, (Get-ExakitPlural $ext 'file'), $script:UiReset)
    }
    if ($ignored) {
        Write-Host ("      {0}ignored: {1}{2}" -f $script:UiDim, $ignored, $script:UiReset)
    }
}

# Import-ExakitLocalFolder <dir> - load every data file in one folder.
#
# The schema is asked once, not once per file: a folder is one job, and its
# tables are named after the files (sales.csv -> SALES). Returns "back" when the
# user backs out, "failed" when something failed, "" when everything asked for
# was loaded. Twin of exakit_load_local_folder.
function Import-ExakitLocalFolder {
    param([Parameter(Mandatory)][string]$Path)
    $plan = @(Get-ExakitBulkFolderPlan -Path $Path)
    $loadable = @($plan | Where-Object { $_.StartsWith("load|") })
    if ($loadable.Count -eq 0) {
        $json = @($plan | Where-Object { $_.StartsWith("skip|json-unsupported|") }).Count
        $ext = @($plan | Where-Object { $_.StartsWith("skip|extension|") }).Count
        if ($json -gt 0) {
            Show-ExakitBulkPlan -Plan $plan -Chosen @() -Schema "" -Path $Path
        } elseif ($ext -gt 0) {
            # A GTFS feed is eleven tables all called .txt: nothing exapump
            # takes by name, everything the user came to load. Twin of the
            # same branch in exakit_load_local_folder.
            Warn2 "$(Get-ExakitPlural $ext 'file') in $Path are tabular but named .txt/.tsv - exapump reads .csv and .parquet only. Rename them to .csv and load the folder again."
            Info "Only the folder itself is read - subfolders and files of other kinds are left alone."
        } else {
            Warn2 "No CSV, Parquet or JSON files in $Path."
            Info "Only the folder itself is read - subfolders and files of other kinds are left alone."
        }
        return "failed"
    }

    # EVERY loadable file, whatever its kind. A folder means "here is my data",
    # and asking which of CSV, Parquet and JSON to take is asking the reader to
    # do the sorting the kit exists to do. Anything unreadable is already listed
    # as skipped with its reason. Twin of the same change in exapump.sh.
    $chosen = @($loadable | ForEach-Object { $_.Substring(5) })
    if ($chosen.Count -eq 0) {
        Info "Nothing selected - no files were loaded."
        return "back"
    }

    # One schema for the whole folder, asked once.
    if ($env:EXAKIT_SCHEMA) { $schema = $env:EXAKIT_SCHEMA } else { $schema = "STARTER_KIT" }
    while ($true) {
        $schema = Read-ExakitPrompt "Target schema (back to return)" $schema
        if ($schema -match '^(b|back)$') {
            Info "Returning to data loading options."
            return "back"
        }
        if ($schema -match '^[A-Za-z0-9_]+$') { break }
        Warn2 "Schema must use letters, numbers or underscores."
        if (-not (Test-ExakitInteractive)) { return "failed" }
    }
    $schema = $schema.ToUpperInvariant()

    # No confirmation - twin of the same silence in exapump.sh. The folder and
    # the schema are the two answers; the plan above is what they produced.
    Show-ExakitBulkPlan -Plan $plan -Chosen $chosen -Schema $schema -Path $Path

    # Quiet BEFORE the schema call: creating it is plumbing, not a step.
    $script:ExakitUploadQuiet = $true
    Confirm-ExakitSchemaExists $schema | Out-Null
    # Weighted by BYTES, like a bundled dataset: a folder is usually one big
    # export and a handful of small ones, and counting files would put the bar at
    # 90% while the only file that matters is still going.
    $totalWeight = [long]0
    foreach ($row in $chosen) { $totalWeight += (Get-ExakitLoadWeight $row.Split('|', 3)[2]) }
    $doneWeight = [long]0
    $done = 0
    $failed = 0
    $skipped = 0
    $i = 0
    # BEFORE a single byte goes over: what is already in those tables? The
    # schema was just created, so the listing has to be taken after that, and it
    # is one query for the whole folder.
    Clear-ExakitTableListing
    $decisions = @(Get-ExakitBulkDecisions -Chosen $chosen -Schema $schema)
    # EXAKIT_ON_EXISTING answers the clash question without a terminal, which is
    # what a script or an agent driving this needs; an unusable value is a
    # refusal, not a silent fallback to the most destructive reading.
    $onExisting = "" + $env:EXAKIT_ON_EXISTING
    if ($onExisting -eq "") {
        $clashAnswer = Read-ExakitBulkClashAnswer -Decisions $decisions -Schema $schema
    } elseif (@("skip", "replace", "append") -contains $onExisting) {
        $clashAnswer = $onExisting
    } else {
        Warn2 "EXAKIT_ON_EXISTING must be skip, replace or append (got '$onExisting')."
        return "failed"
    }
    Show-ExakitBulkResume -Decisions $decisions -Clash $clashAnswer
    # Every file's fate, collected as it happens and printed as a table once the
    # bar is gone.
    $outcomes = @()
    # What landed where, for the ONE listing taken after the loop. Row counts and
    # receipts both need it.
    $landed = @()
    [void](Start-ExakitProgress -Pct 0 -Ceiling 1 -Secs 2 -Phase "reading $(Get-ExakitPlural $chosen.Count 'file')")
    try {
        foreach ($d in $decisions) {
            $i++
            $file = $d.File
            $target = $d.Target
            $w = Get-ExakitLoadWeight $file
            # Already there, put there by this very file: the whole point of the
            # exercise. Weight still counts towards the bar, or a resumed run
            # would crawl to 100% in one jump at the end.
            if ($d.Action -eq "done") {
                $skipped++
                $doneWeight += $w
                Write-ExakitLog "SKIP" "$(Split-Path $file -Leaf) -> $target (already loaded, $($d.Had) rows)"
                $outcomes += [pscustomobject]@{ Status = "skip"; File = $file; Table = $d.Table
                    Detail = (Get-ExakitRowsLabel $d.Had); Why = "already loaded from this file - left as it is" }
                continue
            }
            if ($d.Action -eq "clash" -and $clashAnswer -eq "skip") {
                $skipped++
                $doneWeight += $w
                Write-ExakitLog "SKIP" "$(Split-Path $file -Leaf) -> $target (holds $($d.Had) rows this kit did not load)"
                $outcomes += [pscustomobject]@{ Status = "skip"; File = $file; Table = $d.Table
                    Detail = (Get-ExakitRowsLabel $d.Had)
                    Why = "not loaded: the table already holds rows this kit did not put there" }
                continue
            }
            # An interrupted write leaves PART of a file in the table, and a
            # clash the reader chose to replace is the same situation by
            # consent: in both the rows there are not wanted, and appending on
            # top of them would mix a half-file with a whole one.
            if ($d.Action -eq "resume" -or ($d.Action -eq "clash" -and $clashAnswer -eq "replace")) {
                [void](Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "DROP TABLE IF EXISTS $target"))
                Remove-ExakitLoadReceipt $target
                Write-ExakitLog "RESET" "$target dropped before reloading $(Split-Path $file -Leaf)"
            }
            # The spinner names the file it is actually on, and how far through
            # the folder it is - a forty-file load must never animate under one
            # label.
            Set-ExakitLoadStep -DoneWeight $doneWeight -StepWeight $w -TotalWeight $totalWeight `
                -Seconds (Get-ExakitLoadSeconds $w) `
                -Phase "$(Split-Path $file -Leaf) ($i/$($chosen.Count))"
            # Was the table there BEFORE we touched it? A failure that leaves
            # behind a table we created and never filled is a phantom: it answers
            # "yes" to every "is it loaded?" check the kit has, while holding
            # nothing.
            # From the decision taken before the loop - and from the DROP just
            # above, when there was one - rather than from a fresh listing per
            # file, which on a forty-file folder was forty extra round trips.
            $before = "absent"
            if ($null -ne $d.Had -and $d.Action -eq "load") { $before = $d.Had }
            Set-ExakitLoadInflight $target
            # @(...)[-1]: the function writes its progress with Write-Host, but
            # taking the LAST emitted value keeps the boolean even if a helper
            # underneath it ever starts writing to the pipeline.
            $uploaded = $false
            $script:ExakitLastLoadTarget = ""
            try {
                if ($d.Kind -eq "json") {
                    # Through the JSON Tables engine, installed on first use -
                    # exapump cannot read JSON. Twin of the json branch in
                    # exakit_load_local_folder.
                    $uploaded = [bool](@(Import-ExakitLocalJson -Path $file -Target $target)[-1])
                } else {
                    $uploaded = [bool](@(Invoke-ExapumpUpload $file $target -Soft)[-1])
                }
            } catch {
                $uploaded = $false
                # A throw is a failure too, and it must say why - a bare catch
                # once turned a script bug into "not loaded" with no reason.
                $script:ExakitUploadReason = "$($_.Exception.Message)"
                Write-ExakitLog "ERROR" "$(Split-Path $file -Leaf) -> ${target}: $($_.Exception.Message)"
            }
            Clear-ExakitLoadInflight
            if ($uploaded) {
                # To the logfile: the plan above the confirm already listed every
                # file and its target, and a redrawing bar cannot share the row.
                # A JSON document shreds into tables of its own choosing - it is
                # where they landed that gets counted, not the name planned for
                # it. Twin of _blf_land in exakit_load_local_folder.
                $targets = @($target)
                if ($d.Kind -eq "json" -and $script:ExakitLastLoadTarget) {
                    $targets = @($script:ExakitLastLoadTarget -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                }
                Write-ExakitLog "OK" "$(Split-Path $file -Leaf) -> $($targets -join ', ')"
                $done++
                $doneWeight += $w
                # The row count is filled in by ONE listing after the loop, not
                # one per file: each listing is a process start, a TLS handshake
                # and an authentication.
                $landed += [pscustomobject]@{ File = $file; Targets = $targets }
                $outcomes += [pscustomobject]@{ Status = "ok"; File = $file
                    Table = (@($targets | ForEach-Object { $_.Split('.', 2)[-1] }) -join ", ")
                    Detail = $null; Why = "" }
            } else {
                $why = ""
                if ($script:ExakitUploadReason) { $why = $script:ExakitUploadReason }
                $gone = Remove-ExakitPhantomTable -Target $target -RowsBefore $before
                $failed++
                $outcomes += [pscustomobject]@{ Status = "fail"; File = $file; Table = $d.Table
                    Detail = "not loaded$gone"; Why = $why }
            }
        }
    } finally {
        Stop-ExakitProgress
        $script:ExakitUploadQuiet = $false
        $script:ExakitActiveLabel = ""
    }

    # One listing, taken once, that turns every pending count into a real one and
    # writes a receipt for every table that took rows.
    if ($landed.Count -gt 0) {
        Clear-ExakitTableListing
        foreach ($l in $landed) {
            # Summed across every table the file made, with a receipt for each,
            # so a later run can tell rows it put there from rows it did not.
            $total = [long]0
            foreach ($t in $l.Targets) {
                $n = Get-ExakitTableRowCount $t
                if ($null -eq $n -or $n -eq "absent") { $n = 0 }
                $total += [long]$n
                Write-ExakitLoadReceipt -Target $t -File $l.File -Rows $n
            }
            foreach ($o in $outcomes) {
                if ($o.Status -eq "ok" -and $o.File -eq $l.File -and $null -eq $o.Detail) {
                    $o.Detail = Get-ExakitRowsLabel $total
                }
            }
        }
    }
    # Anything the listing could not answer for must not print a marker at the
    # reader. It loaded; we simply cannot say how much.
    foreach ($o in $outcomes) { if ($null -eq $o.Detail) { $o.Detail = "" } }

    # The table, before the sentence about it. A reader who reads nothing else
    # has already been told which file went where and which one did not.
    Show-ExakitBulkOutcomes -Outcomes $outcomes -Schema $schema

    Set-ExakitManifestValue "data.last_load.type" "local_folder"
    Set-ExakitManifestValue "data.last_load.source" $Path
    Set-ExakitManifestValue "data.last_load.target" $schema
    Set-ExakitManifestValue "data.last_load.files" $done

    # Every outcome that happened, named once, in one sentence. "Loaded 0 of 3"
    # was what a fully-resumed run used to say about a schema holding every row
    # it asked for - a true count of a number nobody wanted, reading as total
    # failure. Each clause appears only when its count is non-zero.
    $say = "$(Get-ExakitPlural $done 'file') loaded"
    if ($skipped -gt 0) { $say = "$say, $skipped already there and left alone" }
    if ($failed -gt 0) { $say = "$say, $failed not loaded" }
    if ($failed -gt 0) {
        # NOT "exakit logs". That command lists the log TARGETS and shows none of
        # them, so a reader following it lands on a chooser and still does not
        # know what went wrong. Name the log that holds the answer.
        Warn2 "${schema}: $say (each file's reason is against it above; full detail: exakit logs setup)."
        return "failed"
    }
    if ($done -eq 0 -and $skipped -gt 0) {
        Ok "$schema already holds every file in that folder - nothing to load."
        return ""
    }
    Ok "${schema}: $say"
    return ""
}

# Remove-ExakitPhantomTable - clean up after a failed upload, and say so.
#
# exapump infers the schema and CREATES the table before it imports a single
# row, so a file the engine then refuses leaves an EMPTY TABLE standing. That
# table is worse than nothing: exakit status counts it, the schema listing shows
# it, and the next reader sees a name promising data it does not have. Drop it -
# but only when we are the ones who created it. A table that was already there
# is the reader's, failed import or not. Twin of exakit_drop_phantom_table.
function Remove-ExakitPhantomTable {
    param([Parameter(Mandatory)][string]$Target, $RowsBefore)
    if ($RowsBefore -ne "absent") { return "" }
    Clear-ExakitTableListing
    $now = Get-ExakitTableRowCount $Target
    if ($null -eq $now -or $now -eq "absent" -or [long]$now -ne 0) { return "" }
    $res = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "DROP TABLE IF EXISTS $Target")
    if (-not $res.Success) { return "" }
    Clear-ExakitTableListing
    Write-ExakitLog "CLEAN" "dropped empty $Target left by the failed import"
    return ", no empty table left behind"
}

function Import-ExakitRemoteFile {
    $url = Read-ExakitPrompt "Remote CSV / Parquet / JSON URL" ""
    if (-not $url) { Fail "Remote URL is required." }
    $name = Split-Path ($url -replace '\?.*$', '') -Leaf
    if (-not $name) { $name = "remote-data.csv" }
    $kind = Get-ExakitDataFileKind $name
    # Refused only where the engine can never exist. Where it can, the download
    # is handed to the same JSON path a local file takes.
    if ($kind -eq "json" -and -not (Test-ExakitJsonTablesApplicable)) {
        Show-ExakitJsonUnsupported
        return
    }
    # Both questions are asked before the download starts, so the whole job is
    # one uninterrupted "Loading your data" from here on.
    $schema = if ($env:EXAKIT_SCHEMA) { $env:EXAKIT_SCHEMA } else { "STARTER_KIT" }
    $defaultTable = "$schema.$(Get-ExakitTableName $name)"
    $target = Read-ExakitPrompt "Target table (SCHEMA.TABLE)" $defaultTable
    if (-not (Test-ExakitTableTarget $target)) {
        Fail "Target table must look like SCHEMA.TABLE and use letters, numbers, or underscores."
    }
    $target = Get-ExakitUpperTableTarget $target

    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-remote-data-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    $tmpFile = Join-Path $tmpDir $name

    $script:ExakitUploadQuiet = $true
    $script:ExakitActiveLabel = "Loading your data"
    try {
        # Get-ExakitFile draws nothing of its own, so the dot loader is started
        # here: a download is part of loading your data, not a step of its own.
        Start-ExakitSpinner "Loading your data"
        try {
            Get-ExakitFile -Url $url -Dest $tmpFile
        } finally {
            Stop-ExakitSpinner
        }
        # The downloaded file decides, not the URL: a link with no extension
        # is only known for what it is once it is on disk.
        if ((Get-ExakitDataFileKind $tmpFile) -eq "json") {
            if (-not (Import-ExakitLocalJson -Path $tmpFile -Target $target)) { return }
            Set-ExakitManifestValue "data.last_load.type" "remote_file"
            Set-ExakitManifestValue "data.last_load.source" $url
            if ($script:ExakitLastLoadTarget) { $target = $script:ExakitLastLoadTarget }
        } else {
            Confirm-ExakitSchemaExists (Get-ExakitTargetSchema $target) | Out-Null
            Invoke-ExapumpUpload $tmpFile $target | Out-Null
            Set-ExakitManifestValue "data.last_load.type" "remote_file"
            Set-ExakitManifestValue "data.last_load.target" $target
            Set-ExakitManifestValue "data.last_load.source" $url
            Confirm-ExakitLoadedTable $target
        }
    } finally {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        $script:ExakitUploadQuiet = $false
        $script:ExakitActiveLabel = ""
    }
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

# Test-ExakitDbReachable - can we run SQL right now?
#
# ONLY A "YES" IS CACHED. Caching the "no" too is what let one installer run
# report a full database while looking at an empty one: the probe ran before the
# runtime step, the deployment was down (or being replaced), and that answer was
# still cached when the data step asked afterwards. Every dataset then fell
# through to the manifest flag and printed "already loaded" against a database
# with no schemas in it. A "yes" cannot go stale the same way - nothing in a kit
# run takes the database down without going through Stop-Personal, and that
# calls Clear-ExakitDbReachable.
# twin: exakit_db_reachable in setup/lib/exapump.sh.
$script:ExakitDbReachable = $null
function Test-ExakitDbReachable {
    if ($script:ExakitDbReachable -ne $true) {
        $script:ExakitDbReachable = $false
        if (Get-ExakitManifestValue "components.exapump.profile") {
            $result = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "SELECT 1")
            $script:ExakitDbReachable = [bool]$result.Success
        }
    }
    return $script:ExakitDbReachable
}

# Clear-ExakitDbReachable - drop the cached "yes" after the kit itself takes the
# database down, so a later check re-probes instead of trusting a state this run
# has just ended.
# twin: exakit_forget_db_reachable in setup/lib/exapump.sh.
function Clear-ExakitDbReachable {
    $script:ExakitDbReachable = $null
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

# Sync-ExakitDatasetFlag - write one manifest flag only when it disagrees with
# what was observed.
function Sync-ExakitDatasetFlag {
    param([string]$Key, [bool]$Value)
    if (-not $Key) { return }
    if ((Get-ExakitManifestValue $Key) -ne $Value) { Set-ExakitManifestValue $Key $Value }
}

# Test-ExakitDatasetLoaded - the DATABASE is the source of truth: when it is
# reachable, every marker table must exist, and BOTH manifest keys are synced to
# what was observed, so a destroy+redeploy that left a stale "loaded" flag
# self-heals. Only when the database is unreachable do we fall back to the
# manifest.
#
# TWO KEYS, on purpose. A dataset.conf may set flag= to override the manifest key
# (TPC-H keeps the historical data.loaded so older installs stay recognized),
# while `exakit status` reads the canonical data.datasets.<id>.loaded for every
# dataset alike. Syncing only the override is what let status keep listing tpch
# as loaded against a database with no schemas in it.
# twin: exakit_dataset_loaded in setup/lib/exapump.sh.
# ONE LISTING, NOT A REACHABILITY PROBE PLUS A QUERY PER MARKER.
#
# This used to ask Test-ExakitDbReachable (a SELECT 1) and then run one
# EXA_ALL_TABLES query PER MARKER TABLE - four exapump launches for tpch, eight
# across the three bundled datasets. Every launch is a process start, a TLS
# handshake and an authentication, ~2.5s warm, which is why
# Invoke-ExakitDatasetLoad measured 11.5s to do nothing but print
# "already loaded".
#
# Get-ExakitVerifiedDatasets already learned exactly this - "THE TABLE LISTING
# IS THE REACHABILITY PROBE ... asking SELECT 1 first bought no information the
# listing does not already give, and doubled the cost" - but this function was
# never brought along. It is now: one listing answers reachability AND every
# marker at once.
#
# Cached for the process and dropped whenever a dataset finishes loading, so a
# second dataset checked in the same run does not pay for it again, and nothing
# can read a listing taken before its own tables landed.
$script:ExakitTableListing = $null
$script:ExakitTableRowListing = $null

function Clear-ExakitTableListing {
    $script:ExakitTableListing = $null
    $script:ExakitTableRowListing = $null
}

function Get-ExakitTableRowListing {
    if ($null -eq $script:ExakitTableRowListing) {
        $script:ExakitTableRowListing = Get-ExakitQualifiedTableRows
    }
    return $script:ExakitTableRowListing
}

function Get-ExakitTableListing {
    if ($null -eq $script:ExakitTableListing) {
        $script:ExakitTableListing = Get-ExakitQualifiedTables
    }
    return $script:ExakitTableListing
}

function Test-ExakitDatasetLoaded {
    param([Parameter(Mandatory)][hashtable]$Dataset)
    $canonical = "data.datasets.$($Dataset.Id).loaded"
    if ($canonical -eq $Dataset.Flag) { $canonical = "" }
    if ($Dataset.Markers.Count -gt 0) {
        $present = Get-ExakitTableListing
        # $null means the database could not be ASKED - not that it is empty.
        # Falling through to the manifest is what stops an unreachable database
        # from being reported as one with no data in it.
        if ($null -ne $present) {
            foreach ($table in $Dataset.Markers) {
                if (-not $present.ContainsKey("$($Dataset.Schema).$table".ToUpper())) {
                    Sync-ExakitDatasetFlag $Dataset.Flag $false
                    Sync-ExakitDatasetFlag $canonical $false
                    return $false
                }
            }
            Sync-ExakitDatasetFlag $Dataset.Flag $true
            Sync-ExakitDatasetFlag $canonical $true
            return $true
        }
    }
    return ((Get-ExakitManifestValue $Dataset.Flag) -eq $true)
}

# Get-ExakitVerifiedDatasets - the ids of bundled datasets whose marker tables
# are ACTUALLY in the database right now, with the manifest flags healed to
# match. Returns $null when the database cannot be asked, so the caller keeps
# the manifest's answer instead of reporting an empty database.
# twin: exakit_verified_datasets in setup/lib/exapump.sh.
# Get-ExakitQualifiedTables - every table in the database as SCHEMA.TABLE, in
# ONE query.
#
# `exakit status` verifies the bundled datasets against their marker tables.
# Asking per table meant one exapump process per marker - process start, TLS
# handshake, auth, query - and the bundled datasets carry seven markers between
# them, so status took 27 SECONDS on a healthy machine. The shell side has
# always asked once; this is the missing twin of that.
# Returns $null when the query itself fails, which the caller must not confuse
# with "the database has no tables".
# Twin of the single SELECT in exakit_verified_datasets (exapump.sh).
# Get-ExakitQualifiedTables - every table THAT HOLDS ROWS, as an upper-case
# SCHEMA.TABLE set; $null when the database could not be asked.
#
# Rows, not existence. A dataset's DDL creates its tables before a single file
# is uploaded, so an upload that failed left eight empty tables that the marker
# check counted as "loaded": exakit data-load then answered "already loaded -
# nothing to do" over ORDERS and PART with 0 rows in them (Windows, the
# database fetching two of eight files over a NAT that cut them off). A marker
# table with no rows is a dataset that did not land. TABLE_ROW_COUNT is exact
# in EXA_ALL_TABLES (checked against COUNT(*) on a real database). Twin of
# exakit_table_listing; the sentinel row is what the sh side needs to tell an
# answered-but-empty listing from one that never came, and the same query
# keeps the pair identical.
# ONE query answers both questions. "Does this table exist?" and "how many rows
# has it?" used to be a listing of the non-empty tables plus a probe per table,
# and the difference between the two answers is the whole bug a folder load ran
# into: a table that EXISTS WITH NO ROWS is not absent and is not loaded, and
# reporting it as either one is what let a failed upload pass for a loaded one.
# Twin of exakit_table_rows_listing.
function Get-ExakitQualifiedTableRows {
    $result = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile,
        "SELECT 'EXAKIT.LISTING_ANSWERED|1' AS QUALIFIED FROM DUAL UNION ALL SELECT TABLE_SCHEMA || '.' || TABLE_NAME || '|' || TABLE_ROW_COUNT FROM SYS.EXA_ALL_TABLES")
    if (-not $result.Success) { return $null }
    $map = @{}
    foreach ($line in (("" + $result.Output) -split "`r?`n")) {
        $t = $line.Trim()
        if ($t -match '^([A-Za-z0-9_$]+\.[A-Za-z0-9_$]+)\|([0-9]+)$') {
            $map[$Matches[1].ToUpper()] = [long]$Matches[2]
        }
    }
    return $map
}

# Get-ExakitTableRowCount <SCHEMA.TABLE> - the row count, "absent" when the
# table is not there, or $null when the database could not be asked. THREE
# answers, because the caller acts differently on each one.
function Get-ExakitTableRowCount {
    param([Parameter(Mandatory)][string]$Target)
    $map = Get-ExakitTableRowListing
    if ($null -eq $map) { return $null }
    $key = $Target.ToUpper()
    if ($map.ContainsKey($key)) { return $map[$key] }
    return "absent"
}

function Get-ExakitQualifiedTables {
    $map = Get-ExakitQualifiedTableRows
    if ($null -eq $map) { return $null }
    $set = @{}
    foreach ($k in $map.Keys) {
        # The sentinel carries |1, not |0, ON PURPOSE: it has to survive this
        # rows-greater-than-zero filter, or a database whose tables merely
        # happen to be empty hands every caller an empty listing - which they
        # all read as "unreachable".
        if ($k -eq "EXAKIT.LISTING_ANSWERED") { continue }
        if ($map[$k] -gt 0) { $set[$k] = $true }
    }
    $set["EXAKIT.LISTING_ANSWERED"] = $true
    return $set
}

function Get-ExakitVerifiedDatasets {
    $datasets = @(Get-ExakitBundledDatasets)
    # THE TABLE LISTING IS THE REACHABILITY PROBE. Asking SELECT 1 first bought
    # no information the listing does not already give, and doubled the cost:
    # every exapump call is a process start, a TLS handshake and an
    # authentication, about 2.5s on a warm machine, so `exakit status` paid ~5s
    # where ~2.5s answers the same question. A listing that comes back proves
    # the database is up, so the cached flag is set from here.
    $present = Get-ExakitQualifiedTables
    if ($null -ne $present) { $script:ExakitDbReachable = $true }
    if ($null -eq $present) {
        # Could not list: unreachable, or the query failed. Ask properly before
        # reporting anything - an empty answer must never be mistaken for an
        # empty database.
        if (-not (Test-ExakitDbReachable)) { return $null }
        # The one query failed. Fall back to the per-table path rather than
        # reporting an empty database off a failed lookup.
        $loaded = @()
        foreach ($dataset in $datasets) {
            if (Test-ExakitDatasetLoaded $dataset) { $loaded += $dataset.Id }
        }
        return ,@($loaded)
    }
    $loaded = @()
    foreach ($dataset in $datasets) {
        $canonical = "data.datasets.$($dataset.Id).loaded"
        if ($canonical -eq $dataset.Flag) { $canonical = "" }
        # No markers declared means nothing to verify - keep the manifest's word
        # rather than silently demoting the dataset to "not loaded".
        if ($dataset.Markers.Count -eq 0) {
            if ((Get-ExakitManifestValue $dataset.Flag) -eq $true) { $loaded += $dataset.Id }
            continue
        }
        $schema = if ($dataset.Schema) { $dataset.Schema } elseif ($env:EXAKIT_SCHEMA) { $env:EXAKIT_SCHEMA } else { "STARTER_KIT" }
        $all = $true
        foreach ($table in $dataset.Markers) {
            if (-not $present.ContainsKey(("$schema.$table").ToUpper())) { $all = $false; break }
        }
        # Same healing the per-table path did: BOTH keys, always, so a
        # destroy+redeploy that left a stale "loaded" flag corrects itself.
        Sync-ExakitDatasetFlag $dataset.Flag $all
        Sync-ExakitDatasetFlag $canonical $all
        if ($all) { $loaded += $dataset.Id }
    }
    return ,@($loaded)
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
# Get-ExakitGroupedDigits <n> - 173745 -> 173,745. Worth doing: the row total is
# the one number in a dataset's result line that a reader compares against what
# they were expecting. Invariant culture, so the separator does not follow the
# machine's locale. Twin of exakit_group_digits in exapump.sh.
function Get-ExakitGroupedDigits {
    param([Parameter(Mandatory)][long]$Value)
    return $Value.ToString("N0", [System.Globalization.CultureInfo]::InvariantCulture)
}

# --- weighting a load by what it actually costs ------------------------------
# A dataset is a dozen steps and one of them is most of the wall clock: TPC-H's
# lineitem.csv is fifteen megabytes of twenty-one, so counted as steps the bar
# reached 25% while the file that is 63% of the job was still going.
#
# So the denominator is BYTES. The steps that move no bytes (a schema script,
# the load statements, the verification, the row counts) are worth a nominal
# share each, measured on the same scale.
# Twin of the same block in exapump.sh.
$script:ExakitLoadStepShare = 5          # percent of the byte total, per byteless step
$script:ExakitLoadBytesPerSec = 1048576

function Get-ExakitLoadWeight {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return 0 }
    try { return [long](Get-Item -LiteralPath $Path).Length } catch { return 0 }
}

# How long that much weight usually takes, for the creep to fill in with. Only
# ever an estimate, and a safe one: the creep is capped below the next stage, so
# guessing short makes the bar wait and guessing long makes it move slowly.
function Get-ExakitLoadSeconds {
    param([long]$Weight)
    $s = [int]($Weight / $script:ExakitLoadBytesPerSec)
    if ($s -lt 2) { $s = 2 }
    return $s
}

# Set-ExakitLoadStep - the load has reached a new stage: where it is, and where
# this stage ends. Prints nothing; the progress animator is what draws.
function Set-ExakitLoadStep {
    param(
        [long]$DoneWeight, [long]$StepWeight, [long]$TotalWeight,
        [int]$Seconds, [string]$Phase
    )
    $pct = 0; $ceil = 0
    if ($TotalWeight -gt 0) {
        $pct = [int]($DoneWeight * 100 / $TotalWeight)
        $ceil = [int](($DoneWeight + $StepWeight) * 100 / $TotalWeight)
    }
    if ($ceil -gt 100) { $ceil = 100 }
    if ($pct -gt 100) { $pct = 100 }
    # A dataset being loaded from the table reports into its ROW; anything else
    # (a folder, a single named file) still owns the one-line bar.
    if ($script:ExakitTableRow -gt 0) {
        Set-ExakitTableRow -Row $script:ExakitTableRow -State "running" `
            -Pct $pct -Ceiling $ceil -Secs $Seconds -Phase $Phase
        return
    }
    Set-ExakitProgress -Pct $pct -Ceiling $ceil -Secs $Seconds -Phase $Phase
}

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
    # Ask the DATABASE, not the manifest. Reading the flag directly here is what
    # let an install that had just replaced the deployment print "already loaded"
    # into a database with no schemas in it, and exit 0.
    $markers = @()
    if (Test-Path $confPath) {
        foreach ($line in (Get-Content $confPath)) {
            if ($line -match '^markers=(.+)$') {
                $markers = @($Matches[1].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            }
        }
    }
    $probe = @{ Id = $Id; Flag = $flag; Markers = $markers; Schema = $schema }
    if ((-not $Force) -and (Test-ExakitDatasetLoaded $probe)) {
        Ok "Dataset '$Id' already loaded"
        return
    }
    # The table already names the dataset in its own row, so announcing it again
    # would be the same fact twice - and the line would scroll the table.
    if ($script:ExakitTableLive) {
        Write-ExakitLog "INFO" "Loading the '$Id' dataset into schema $schema"
    } else {
        Info "Loading the '$Id' dataset into schema $schema"
    }

    # ONE line for the whole dataset, not one line per file. Loading three
    # bundled datasets used to print about a hundred and thirty lines - every
    # CSV twice, every script twice, eighteen rows of verification CSV and a
    # row-count panel per dataset - and none of it is something the person
    # waiting for a database can act on.
    #
    # The steps are counted up front, so the percentage is a real fraction of
    # the work rather than a guess: the schema script, one per CSV, the load
    # statements, the verification, and the row count at the end.
    # ExakitUploadQuiet silences the narration underneath; the progress line IS
    # the narration now (see Set-ExakitLoadStep). Nothing is lost - every
    # suppressed line still goes to the logfile, including the per-table row
    # counts, and a FAILED verification still prints in full.
    $schemaSql = Join-Path $dir "01_create_schema.sql"
    $loadSql = Join-Path $dir "02_load_data.sql"
    $verifySql = Join-Path $dir "03_verify_setup.sql"
    $csvFiles = @(Get-ChildItem -Path (Join-Path $dir "data\*.csv") -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt 0 })
    $bytes = [long]0
    foreach ($csv in $csvFiles) { $bytes += [long]$csv.Length }
    $nominal = [long]($bytes * $script:ExakitLoadStepShare / 100)
    if ($nominal -lt 1) { $nominal = 1 }
    $totalWeight = $bytes + $nominal + $nominal          # + schema + row counts
    if ((Test-Path $loadSql) -and (Get-Item $loadSql).Length -gt 0) { $totalWeight += $nominal }
    if ((Test-Path $verifySql) -and (Get-Item $verifySql).Length -gt 0) { $totalWeight += $nominal }
    $doneWeight = [long]0
    $started = Get-Date
    # Which row of the table this dataset owns, if a table is on screen. Zero
    # means there is none, and the single-line bar takes over.
    $script:ExakitTableRow = 0
    if ($script:ExakitTableLive) { $script:ExakitTableRow = Get-ExakitDataTableRow -Id $Id }
    if ($script:ExakitTableRow -gt 0) {
        Set-ExakitTableRow -Row $script:ExakitTableRow -State "running" `
            -Pct 0 -Ceiling 1 -Secs 2 -Phase "$Id - reading the dataset"
    } else {
        [void](Start-ExakitProgress -Pct 0 -Ceiling 1 -Secs 2 -Phase "$Id - reading the dataset")
    }
    $script:ExakitUploadQuiet = $true
    $tableCount = 0
    $rowTotal = [long]0
    $rowsKnown = $true
    try {

    # Schema script is OPTIONAL: exapump infers column types and creates the
    # table itself when none exists; the script exists to pin exact types and
    # primary keys. Verify the DDL really landed and re-run once if not.
    if ((Test-Path $schemaSql) -and (Get-Item $schemaSql).Length -gt 0) {
        Set-ExakitLoadStep -DoneWeight $doneWeight -StepWeight $nominal -TotalWeight $totalWeight `
            -Seconds 2 -Phase "$Id - creating schema $schema"
        Invoke-ExapumpSqlFile $schemaSql "$Id schema (01_create_schema.sql)" | Out-Null
        if (-not (Test-ExapumpSchemaPresent $schema.ToUpper())) {
            Warn2 "Schema $schema is not present after creation - re-running the schema script"
            Invoke-ExapumpSqlFile $schemaSql "$Id schema (re-run)" | Out-Null
            if (-not (Test-ExapumpSchemaPresent $schema.ToUpper())) {
                Fail "Schema $schema was reported created but does not exist. The database may still be stabilizing; wait a moment and retry: exakit data-load"
            }
        }
    } else {
        Set-ExakitLoadStep -DoneWeight $doneWeight -StepWeight $nominal -TotalWeight $totalWeight `
            -Seconds 2 -Phase "$Id - creating schema $schema"
        $r = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "CREATE SCHEMA IF NOT EXISTS $($schema.ToUpper())")
        if (-not $r.Success) { Fail "Could not create schema $schema." }
    }

    $doneWeight += $nominal
    # Uploads run CONCURRENTLY (see Invoke-ExapumpUploadMany). One launch per
    # file either way - what changes is how many are in flight at once, which is
    # the only lever left: exapump upload cannot target more than one table per
    # call, and the server refuses IMPORT of local files over this protocol.
    if ($csvFiles.Count -gt 0) {
        $uploadFiles = @()
        foreach ($csv in $csvFiles) {
            $uploadFiles += @{
                Path   = $csv.FullName
                Target = "$schema." + [System.IO.Path]::GetFileNameWithoutExtension($csv.Name).ToUpper()
                Name   = $csv.Name
            }
        }
        # ONE segment for the whole upload. The files go up concurrently, so
        # there is no per-file position to report any more - which is fine,
        # because the bytes were never the interesting part of the position. They
        # still set the PACE: the segment spans every byte of the dataset and is
        # expected to take as long as those bytes usually take, so the bar moves
        # across it instead of parking until the last wave lands. The ceiling is
        # where the upload ends, so it cannot overrun into the load statements
        # however long the waves take.
        if ($csvFiles.Count -eq 1) { $unit = "file" } else { $unit = "files" }
        Set-ExakitLoadStep -DoneWeight $doneWeight -StepWeight $bytes -TotalWeight $totalWeight `
            -Seconds (Get-ExakitLoadSeconds $bytes) `
            -Phase "$Id - loading $($csvFiles.Count) data $unit"
        Invoke-ExapumpUploadMany -Files $uploadFiles -Id $Id | Out-Null
        if ($script:ExakitUploadFailures.Count -gt 0) {
            Fail "Could not load $($script:ExakitUploadFailures -join '; '). The reason: exakit logs setup. Retry this step with: exakit update"
        }
        $doneWeight += $bytes
    }

    if ((Test-Path $loadSql) -and (Get-Item $loadSql).Length -gt 0) {
        Set-ExakitLoadStep -DoneWeight $doneWeight -StepWeight $nominal -TotalWeight $totalWeight `
            -Seconds 3 -Phase "$Id - running load statements"
        Invoke-ExapumpSqlFile $loadSql "$Id load statements (02_load_data.sql)" | Out-Null
        $doneWeight += $nominal
    }

    if ((Test-Path $verifySql) -and (Get-Item $verifySql).Length -gt 0) {
        Set-ExakitLoadStep -DoneWeight $doneWeight -StepWeight $nominal -TotalWeight $totalWeight `
            -Seconds 3 -Phase "$Id - verifying"
        $result = Invoke-ExapumpSqlFileCapture $verifySql
        $doneWeight += $nominal
        # Grade on the STATUS *column value* ",FAIL," - not the bare word. The
        # verify SQL is full of the literal string (the header comment "a 'FAIL'
        # row means..." and 17 "CASE ... ELSE 'FAIL' END" clauses), and exapump
        # echoes that text back, so matching bare "FAIL" fails a dataset even
        # when every row reads OK. A real failing check emits an unquoted STATUS
        # column (check_name,FAIL,detail); OK rows and the echoed SQL never do.
        #
        # Every check is in the logfile whatever the outcome (the capture writes
        # it there); they reach the SCREEN only when one of them failed.
        # Eighteen rows of "OK, 0 orphaned row(s)" say nothing the result line
        # does not already say - a FAIL row says everything.
        if (-not $result.Success -or $result.Output -match ",FAIL,") {
            Stop-ExakitProgress
            if ($script:ExakitTableRow -gt 0) {
                Set-ExakitTableRow -Row $script:ExakitTableRow -State "failed" `
                    -Final "failed $($script:UiMidDot) verification (see log)"
                $script:ExakitTableRow = 0
            }
            # The table has to stop animating before anything is printed over it,
            # or the checks scroll under a repainting frame. Stopped AFTER the row
            # was marked failed, so the frame left on screen says which one it was.
            Stop-ExakitDataTableRun
            $script:ExakitUploadQuiet = $false
            $script:ExakitActiveLabel = ""
            Write-ExapumpOutput -Output $result.Output -Header "Verification failed for dataset '$Id':"
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
    # The per-table numbers still go to the logfile, exactly as before; what
    # changed is that they no longer take a ten-line panel on screen per
    # dataset. Their totals land in the result line instead, which is the part a
    # reader actually checks against what they expected.
    if ($tables.Count -gt 0) {
        $tableList = $tables
        $schemaName = $schema
        Set-ExakitLoadStep -DoneWeight $doneWeight -StepWeight $nominal -TotalWeight $totalWeight `
            -Seconds 2 -Phase "$Id - counting rows"
        $counted = & {
            $acc = New-Object 'System.Collections.Generic.List[string]'
            # ONE invocation for every table. $batch is $null unless all of
            # them came back, and that sends the loop to the per-table call -
            # so a batch that cannot run costs correctness nothing, only the
            # speed it was meant to buy.
            $batch = Get-ExapumpRowCountMany -Schema $schemaName -Tables $tableList
            foreach ($t in $tableList) {
                if ($null -ne $batch) { $rows = $batch[$t] }
                else { $rows = Get-ExapumpRowCount "$schemaName.$t" }
                if ($rows) { $shown = $rows } else { $shown = "?" }
                $line = "{0,-30} {1} rows" -f "$schemaName.$t", $shown
                if ($script:LogFile) { "DATA  $line" | Add-Content -Path $script:LogFile }
                [void]$acc.Add("$shown")
            }
            return $acc.ToArray()
        }
        foreach ($value in @($counted)) {
            $tableCount++
            if ($value -eq "?") { $rowsKnown = $false } else { $rowTotal += [long]$value }
        }
    }

    } finally {
        # Only the one-line bar is stopped here. A row of the table is not an
        # animation of its own - the table owns the animation and outlives this
        # dataset, because the next one fills in the row underneath.
        if ($script:ExakitTableRow -le 0) { Stop-ExakitProgress }
        $script:ExakitUploadQuiet = $false
        $script:ExakitActiveLabel = ""
    }

    Set-ExakitManifestValue $flag $true
    # Also record the canonical per-dataset key so data.datasets is a complete
    # map even for datasets that keep a legacy flag (TPC-H uses data.loaded for
    # backward compatibility). data.loaded is left untouched for existing installs.
    $canonicalFlag = "data.datasets.$Id.loaded"
    if ($flag -ne $canonicalFlag) { Set-ExakitManifestValue $canonicalFlag $true }
    # RECORDED HERE BECAUSE THEY ARE ALREADY COMPUTED for the result line
    # below. `exakit status` shows a dataset's shape without asking the
    # database at all, which is what keeps that screen instant - counting three
    # datasets live would put two more exapump launches on every status, and
    # process launches are exactly what made the old status slow.
    #
    # They describe the state AS OF THIS LOAD. Anyone who changes these tables
    # behind the kit's back will read stale numbers, which is the price of not
    # querying; `exakit data-load` rewrites them.
    Set-ExakitManifestValue "data.datasets.$Id.schema" $schema
    Set-ExakitManifestValue "data.datasets.$Id.tables" $tableCount
    if ($rowsKnown) { Set-ExakitManifestValue "data.datasets.$Id.rows" $rowTotal }
    Set-ExakitManifestValue "data.last_load.source" "dataset:$Id"
    if (Get-Command Clear-ExakitSoftFailure -ErrorAction SilentlyContinue) { Clear-ExakitSoftFailure -Component "sample_data" }
    # This dataset's tables exist now, so any listing taken before it is stale.
    Clear-ExakitTableListing
    $elapsed = [int]((Get-Date) - $started).TotalSeconds
    if ($elapsed -lt 0) { $elapsed = 0 }
    $resultLine = "Dataset '$Id' loaded and verified"
    if ($tableCount -eq 1) { $unit = "table" } else { $unit = "tables" }
    if ($tableCount -gt 0) {
        $resultLine = "$resultLine - $tableCount $unit"
        if ($rowsKnown) { $resultLine = "$resultLine, $(Get-ExakitGroupedDigits $rowTotal) rows" }
    }
    if ($script:ExakitTableRow -gt 0) {
        # Built for the COLUMN, not for a sentence: the row already says which
        # dataset it is, so the prefix goes, and the two numbers are padded to a
        # fixed width so they line up down the table instead of wandering with the
        # length of the text in front of them.
        #
        #   completed - 8 tables, 173,745 rows  (23s)
        #   completed - 2 tables, 108,050 rows   (4s)
        #   completed - 2 tables,  10,970 rows   (2s)
        $cell = "completed $($script:UiMidDot) $tableCount $unit"
        if ($rowsKnown) {
            $cell = "$cell, $((Get-ExakitGroupedDigits $rowTotal).PadLeft(7)) rows"
        }
        $stamp = "({0}s)" -f $elapsed
        $cell = "$cell $($stamp.PadLeft(5))"
        Set-ExakitTableRow -Row $script:ExakitTableRow -State "done" -Final $cell
        Write-ExakitLog "OK" "$resultLine (${elapsed}s)"
        $script:ExakitTableRow = 0
    } else {
        Ok "$resultLine (${elapsed}s)"
    }
}

# --- the datasets table -------------------------------------------------------
# One table for the whole job: the rows you tick are the rows that fill in. See
# the ui_table_* / *-ExakitTable* family in ui.ps1 for the mechanism; what lives
# here is which rows there are and what their Status column says.
# Twin of the same block in exapump.sh.
$script:ExakitTableIds = @()          # the dataset id per row ("" for the rest)
$script:ExakitTableRowLocal = 0
$script:ExakitTableRowSkip = 0
$script:ExakitTableDefaults = @()
$script:ExakitTableGroupFirst = 0
$script:ExakitTableGroupLast = 0
$script:ExakitTableLive = $false      # is the table animating right now
$script:ExakitTableRow = 0            # the row the dataset being loaded owns

# New-ExakitDataTable <final_label> - build the rows, in the order they are
# drawn, and record the defaults / group range / exclusive row the way the
# selection layer expects. Twin of exakit_data_table_build in exapump.sh.
function New-ExakitDataTable {
    param([Parameter(Mandatory)][string]$FinalLabel)
    [void](New-ExakitTable -Title "Datasets to load")
    $ids = New-Object 'System.Collections.Generic.List[string]'
    $defaults = New-Object 'System.Collections.Generic.List[int]'
    $script:ExakitTableGroupFirst = 0
    $script:ExakitTableGroupLast = 0
    $pending = @(Get-ExakitPendingDatasets)
    if ($pending.Count -gt 0) {
        # The group row is itself a checkbox: pre-selected with every dataset;
        # unchecking it clears them all, after which they can be picked
        # individually. Each dataset hangs off it with a tree connector, which the
        # table draws from the palette - the connectors must never be literals in
        # this file, which has no BOM and would be misread byte for byte by
        # Windows PowerShell 5.1 (see tests/ps-encoding-guard.sh).
        [void](Add-ExakitTableRow -Kind "group" -Label "Select All" -Ticked)
        [void]$ids.Add("")
        for ($i = 0; $i -lt $pending.Count; $i++) {
            if ($i -eq $pending.Count - 1) { $kind = "corner" } else { $kind = "tee" }
            # The label loses its trailing "(~175k rows)": the Status column
            # carries the real count when the row finishes, and an estimate beside
            # a measurement is the same fact twice, worse. Only a TRAILING
            # parenthetical goes - "Orders (EU) by quarter" keeps its brackets.
            $label = [regex]::Replace($pending[$i].Label, ' *\([^()]*\)$', '')
            [void](Add-ExakitTableRow -Kind $kind -Label $label -Ticked)
            [void]$ids.Add($pending[$i].Id)
        }
        $script:ExakitTableGroupFirst = 2
        $script:ExakitTableGroupLast = $pending.Count + 1
        for ($i = 1; $i -le ($pending.Count + 1); $i++) { [void]$defaults.Add($i) }
    }
    # The label is NARROWER than the shell twin's on purpose: exapump.ps1 does not
    # route a .json file to the JSON Tables add-on the way exapump.sh does, so
    # naming JSON here would offer what this side cannot do. When that routing
    # lands, widen the label and the assertion in tests/test_sample_data_schema.py
    # together - never the label alone.
    [void](Add-ExakitTableRow -Kind "plain" -Label "A local CSV / Parquet / JSON file, or a folder of them")
    [void]$ids.Add("local")
    $script:ExakitTableRowLocal = $ids.Count
    [void](Add-ExakitTableRow -Kind "plain" -Label $FinalLabel)
    [void]$ids.Add("")
    $script:ExakitTableRowSkip = $ids.Count
    # With every bundled dataset already loaded there is nothing to tick but the
    # local-file row, which is the only thing this screen can still do. Enter must
    # never be a no-op.
    if ($pending.Count -eq 0) {
        $defaults.Clear()
        [void]$defaults.Add($script:ExakitTableRowLocal)
    }
    $script:ExakitTableIds = $ids.ToArray()
    $script:ExakitTableDefaults = $defaults.ToArray()
}

# Get-ExakitDataTableRow <dataset-id> - which row that dataset is on, or 0.
# Twin of exakit_data_table_row in exapump.sh.
function Get-ExakitDataTableRow {
    param([Parameter(Mandatory)][string]$Id)
    for ($i = 0; $i -lt $script:ExakitTableIds.Count; $i++) {
        if ($script:ExakitTableIds[$i] -eq $Id) { return $i + 1 }
    }
    return 0
}

# Select-ExakitDataLoad <final_label> - the data-source choice, made in the
# TABLE that will show the progress: every bundled dataset that is not loaded yet
# under a "Select All" group row, then the local-file option, then <final_label>
# as the mutually exclusive opt-out (Cancel/Skip). When every bundled dataset is
# already loaded the group disappears and the local-file row is the default, so
# Enter still does something. Returns a string array of ids ("tpch", "local") or
# @("none"). Twin of exakit_data_load_select in exapump.sh.
function Select-ExakitDataLoad {
    param([Parameter(Mandatory)][string]$FinalLabel)
    # EXAKIT_DATA_FILE mirrors the EXAKIT_DATASETS contract: naming a file IS
    # choosing the local-file option, so the table never draws. The path (and
    # EXAKIT_DATA_TABLE) are consumed by Import-ExakitLocalFile as its answers.
    if ($env:EXAKIT_DATA_FILE) {
        Info "Loading a local file (EXAKIT_DATA_FILE)."
        # No table was built, so nothing may animate one. The row ids ARE that
        # signal, the way an empty EXAKIT_TABLE_STATE is on the shell side.
        $script:ExakitTableIds = @()
        return @("local")
    }
    New-ExakitDataTable -FinalLabel $FinalLabel
    # The local-file row being row 1 means there was no group above it, which
    # means nothing is pending.
    # Nothing said about it - twin of the same silence in exapump.sh. The table
    # below shows what is on offer, and their absence from it is the message.
    if ($script:ExakitTableRowLocal -eq 1) {
        Write-ExakitLog "INFO" "Every bundled dataset is already loaded (reload with: exakit data-load -Force)."
    }
    $groupParent = 0
    if ($script:ExakitTableGroupFirst -gt 0) { $groupParent = 1 }
    Write-Host ""
    $selection = @(Invoke-ExakitTableMenu -Defaults $script:ExakitTableDefaults `
        -ExclusiveIndex $script:ExakitTableRowSkip `
        -GroupParent $groupParent -GroupFirst $script:ExakitTableGroupFirst `
        -GroupLast $script:ExakitTableGroupLast -GroupMode "all")
    if ($selection -contains $script:ExakitTableRowSkip) { return @("none") }
    $chosen = New-Object 'System.Collections.Generic.List[string]'
    foreach ($row in $selection) {
        if ($row -lt 1 -or $row -gt $script:ExakitTableIds.Count) { continue }
        $id = $script:ExakitTableIds[$row - 1]
        # The group row and the opt-out carry no id: they are answers about the
        # other rows, not data sources of their own.
        if ($id -and -not $chosen.Contains($id)) { [void]$chosen.Add($id) }
    }
    if ($chosen.Count -eq 0) { return @("none") }
    return $chosen.ToArray()
}

function Show-ExakitDataLoadMenu {
    if (-not (Get-ExakitManifestValue "components.exapump.profile")) {
        Fail "No exapump connection profile is recorded - re-run the installer, then retry."
    }
    $chosen = Select-ExakitDataLoad -FinalLabel "Skip"
    if ($chosen -contains "none") {
        Info "Data loading cancelled."
        return
    }
    Start-ExakitDataTableRun
    try {
        foreach ($id in $chosen) {
            if ($id -eq "local") {
                Stop-ExakitDataTableRun
                $result = Import-ExakitLocalFile
                if ($result -eq "back") { Info "Local file load skipped. Run it any time with: exakit data-load" }
            } else {
                $kitRoot = Get-ExakitRepoRoot
                if (-not $kitRoot) { Fail "Could not find the kit's sql/ and data/ files to load." }
                Invoke-ExakitDatasetLoad -KitRoot $kitRoot -Id $id
            }
        }
    } finally {
        Stop-ExakitDataTableRun
    }
}

# Start-ExakitDataTableRun / Stop-ExakitDataTableRun - the same table the
# selection was made in now becomes the progress display: the rows do not move,
# so nobody has to map one screen onto another. It animates only where there is a
# console to animate on; everywhere else the loaders narrate in plain lines
# exactly as they did before.
#
# Both entry points into a load - the standalone `exakit data-load` and the
# installer's offer - have to drive it. That is the gap the shell side shipped
# with: only the standalone command started the table, so during an install it
# drew, stayed empty, and every dataset fell back to the single-line bar.
function Start-ExakitDataTableRun {
    $script:ExakitTableRow = 0
    $script:ExakitTableLive = $false
    # No rows means no table was built for this run (EXAKIT_DATA_FILE answers the
    # screen without drawing one), and an empty box animating over nothing is
    # worse than no box. Twin of the `[ -n "$EXAKIT_TABLE_STATE" ]` guard.
    if ($script:ExakitTableIds.Count -lt 1) { return }
    $script:ExakitTableLive = [bool](Start-ExakitTable)
}
function Stop-ExakitDataTableRun {
    # A prompt cannot share the screen with a repainting frame, so the local-file
    # branch stops the table before it asks anything - which is also why this is
    # safe to call more than once.
    if (-not $script:ExakitTableLive) { return }
    Stop-ExakitTable
    $script:ExakitTableLive = $false
    $script:ExakitTableRow = 0
}

# Invoke-ExakitSampleDataLoad <kit_root> [-Force] - the TPC-H sample-data
# entry point, kept for its long-standing callers (the installer offer,
# `exakit data-load -Force`, and setup-windows.ps1). TPC-H now lives in
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
# pwsh process instead (see setup-windows.ps1).
function Request-ExakitDataLoadOffer {
    param([Parameter(Mandatory)][string]$KitRoot)
    # One dataset's failure must not cost the others: a thrown load used to leave
    # the rest of the list unattempted, and the closing summary then said "sample
    # data is not installed" about a TPCH that was fully in. Failures are
    # collected and reported once, with the exact retry.
    $failedIds = @()
    $failedReason = ""

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
                try {
                    Invoke-ExakitDatasetLoad -KitRoot $KitRoot -Id $envId
                } catch {
                    $reason = Get-ExakitFailureReason
                    if (-not $reason) { $reason = "$_" }
                    # ONE TELLING. Fail already put the reason on screen with
                    # the log path under it; repeating it here and again in
                    # the closing line printed the same failure three times.
                    Write-ExakitLog "WARN" "Dataset '$envId' did not load: $reason"
                    $failedIds += $envId
                    $failedReason = $reason
                }
            } else {
                Warn2 "Unknown dataset id '$envId' in EXAKIT_DATASETS (available: $($knownIds -join ', '))."
            }
        }
        if (-not $validAny) { Fail "EXAKIT_DATASETS='$($env:EXAKIT_DATASETS)' matched no bundled dataset - nothing was loaded." }
        if ($failedIds.Count -gt 0) {
            Fail "Dataset(s) $($failedIds -join ', ') did not load. Retry with: `$env:EXAKIT_DATASETS = '$($failedIds -join ',')'; exakit data-load"
        }
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

    # No lead-in sentence: the checkbox below names every dataset on offer and
    # the skip, which is the whole of what this line was explaining.
    # Dynamic dataset checkbox (shared with `exakit data-load`): only bundled
    # datasets that are not loaded yet are offered, pre-selected, plus the
    # local-file option and an explicit skip. Non-interactive installs keep
    # the pre-selected defaults.
    $chosen = Select-ExakitDataLoad -FinalLabel "Skip"
    if ($chosen -contains "none") {
        Info "Skipping data loading. Run it any time with: exakit data-load"
        return
    }
    Start-ExakitDataTableRun
    try {
        foreach ($id in $chosen) {
            if ($id -eq "local") {
                Stop-ExakitDataTableRun
                $result = Import-ExakitLocalFile
                if ($result -eq "back") { Info "Local file load skipped. Run it any time with: exakit data-load" }
            } else {
                try {
                    Invoke-ExakitDatasetLoad -KitRoot $KitRoot -Id $id
                } catch {
                    $reason = Get-ExakitFailureReason
                    if (-not $reason) { $reason = "$_" }
                    Write-ExakitLog "WARN" "Dataset '$id' did not load: $reason"
                    $failedIds += $id
                    $failedReason = $reason
                }
            }
        }
    } finally {
        Stop-ExakitDataTableRun
    }
    if ($failedIds.Count -gt 0) {
        Fail "Dataset(s) $($failedIds -join ', ') did not load. Retry with: `$env:EXAKIT_DATASETS = '$($failedIds -join ',')'; exakit data-load"
    }
}
