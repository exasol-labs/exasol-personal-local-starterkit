# json-tables.ps1 - JSON Tables (ingest, query and reshape JSON-shaped data in
# Exasol): Windows counterpart of json-tables.sh.
#
# A MARKETPLACE ADD-ON: never installed by the setup scripts.
#
# WHY THIS FILE USED TO ONLY GATE, AND WHAT CHANGED
#
# The kit's whole point with this add-on is that nobody needs a Rust toolchain:
# .github/workflows/pkg-json-tables.yml builds the ingest engine for every
# platform (Windows included) and the wheel, and publishes both as ONE
# IMMUTABLE RELEASE PER BUILD, tagged json-tables-<version>; versions.json
# names that release and pins the digest of every asset, and a published
# release is never rewritten. On macOS and Linux the kit then puts a tiny
# 'cargo' shim in front of the CLI, because upstream runs the engine with
# exactly one call shape and no prebuilt-binary escape hatch:
#
#     subprocess.run(["cargo", "run", "--manifest-path", <crate>/Cargo.toml,
#                     "--", "--input", ...])          python/exasol_json_tables/cli.py
#
# A SHELL shim cannot work on Windows. subprocess.run with an argument list
# goes to CreateProcess, and CreateProcess resolves a bare name by appending
# .exe only - it never consults PATHEXT - so a cargo.cmd or cargo.bat placed on
# PATH is simply not found. That is why this add-on reported itself
# unavailable here.
#
# The answer is the one the old comment named: a compiled launcher. The shim is
# now a real Windows executable, built from setup/shim/json-tables-cargo by the
# same workflow that assembles the engines and published beside them. The toolchain
# requirement moves to OUR build machine, which is exactly the trade this
# add-on exists to make - the user still installs nothing but prebuilt bytes.
#
#   - venv:     $EXAKIT_HOME\json-tables-venv
#   - engine:   $EXAKIT_HOME\json-tables\libexec\json_to_parquet.exe
#   - shim:     $EXAKIT_HOME\json-tables\shim\cargo.exe
#   - launcher: $BinDir\exasol-json-tables.cmd

$script:JsonTablesVersionFallback = if ($env:EXAKIT_JSON_TABLES_VERSION_FALLBACK) { $env:EXAKIT_JSON_TABLES_VERSION_FALLBACK } else { "v0.3.2" }
$script:JsonTablesVersion = if ($env:EXAKIT_JSON_TABLES_VERSION) { $env:EXAKIT_JSON_TABLES_VERSION } else { "" }
# An explicit release tag (tests, or pointing an install at one specific build);
# empty means the tag versions.json names - see Get-JsonTablesReleaseTag.
$script:JsonTablesMirrorTag = if ($env:EXAKIT_JSON_TABLES_MIRROR_TAG) { $env:EXAKIT_JSON_TABLES_MIRROR_TAG } else { "" }
$script:JsonTablesPackage = if ($env:EXAKIT_JSON_TABLES_PACKAGE) { $env:EXAKIT_JSON_TABLES_PACKAGE } else { "exasol-json-tables" }
$script:JsonTablesVenv = if ($env:EXAKIT_JSON_TABLES_VENV) { $env:EXAKIT_JSON_TABLES_VENV } else { Join-Path $script:ExakitHome "json-tables-venv" }
$script:JsonTablesHome = if ($env:EXAKIT_JSON_TABLES_HOME) { $env:EXAKIT_JSON_TABLES_HOME } else { Join-Path $script:ExakitHome "json-tables" }

function Get-JsonTablesLogPath {
    return (Join-Path $script:LogDir "json-tables.log")
}

# Invoke-JsonTablesLogged <exe> <args...> - run an engine invocation with its
# own words ALSO kept in the add-on's log. Error messages and the help
# document say "see: exakit logs json-tables", and for that command to have an
# answer, something has to write the file - nothing ever did. Returns the
# exit code, like Invoke-ExakitLogged. Twin of _json_tables_logged.
function Invoke-JsonTablesLogged {
    param([Parameter(Mandatory)][string]$Exe, [string[]]$Arguments = @())
    $log = Get-JsonTablesLogPath
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $log) | Out-Null
        Add-Content -Path $log -Value ("=== " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " " + $Exe + " " + ($Arguments -join " "))
    } catch { }
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $out = @(& $Exe @Arguments 2>&1) -join "`n"
        $code = $LASTEXITCODE
    } catch {
        $out = "$_"
        $code = 1
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    try { if ($out) { Add-Content -Path $log -Value $out } } catch { }
    if ($out) { Write-ExakitLog "INFO" $out }
    return $code
}

function Get-JsonTablesVenvPython {
    return (Join-Path $script:JsonTablesVenv "Scripts\python.exe")
}

function Get-JsonTablesEnginePath {
    return (Join-Path $script:JsonTablesHome "libexec\json_to_parquet.exe")
}

function Get-JsonTablesShimDir {
    return (Join-Path $script:JsonTablesHome "shim")
}

function Get-JsonTablesBin {
    if ($env:EXAKIT_JSON_TABLES_BIN) { return $env:EXAKIT_JSON_TABLES_BIN }
    return (Join-Path $script:BinDir "exasol-json-tables.cmd")
}

# Twin of json_tables_mirror_repo: the prebuilt artifacts come from the
# repository THIS KIT WAS INSTALLED FROM, so a fork that runs the packaging
# workflow serves its own users with no configuration.
function Get-JsonTablesMirrorRepo {
    if ($env:EXAKIT_JSON_TABLES_MIRROR_REPO) { return $env:EXAKIT_JSON_TABLES_MIRROR_REPO }
    $src = Get-ExakitManifestValue "kit.source"
    if ($src -and $src -match '^([^@]+/[^@]+)@') { return $Matches[1] }
    return $script:KitRepo
}

# Twin of _json_tables_target_version: the build this run installs - an
# explicit EXAKIT_JSON_TABLES_VERSION, else the version versions.json
# advertises, else the module's fallback constant.
function Get-JsonTablesTargetVersion {
    if ($script:JsonTablesVersion) { return $script:JsonTablesVersion }
    return (Get-ExakitAddonAdvertisedVersion -Id "json-tables" -Fallback $script:JsonTablesVersionFallback)
}

# Twin of _json_tables_pin_applies: true when the build being installed is the
# one versions.json describes, so its release tag, wheel name and digests may
# be taken from that document. Any other build has no pin and is resolved from
# its own release - never from the pins of a different build.
function Test-JsonTablesPinApplies {
    $pin = Get-ExakitVersionsValue "components.json-tables.version"
    if (-not $pin) { return $false }
    return ($pin -eq (Get-JsonTablesTargetVersion))
}

# Twin of json_tables_release_tag: one immutable release per build,
# json-tables-<version>. versions.json may name it outright
# (components.json-tables.release, which also carries a rebuild suffix such as
# json-tables-v0.3-2); otherwise the tag is derived from the version.
# EXAKIT_JSON_TABLES_MIRROR_TAG overrides everything.
function Get-JsonTablesReleaseTag {
    if ($script:JsonTablesMirrorTag) { return $script:JsonTablesMirrorTag }
    if (Test-JsonTablesPinApplies) {
        $pin = Get-ExakitVersionsValue "components.json-tables.release"
        if ($pin) { return $pin }
    }
    return ("json-tables-" + (Get-JsonTablesTargetVersion))
}

# Twin of json_tables_engine_asset. The workflow builds a Windows engine, and
# x64 is the distribution it publishes.
function Get-JsonTablesEngineAsset {
    if (Get-ExakitHostArch) {
        if ((Get-ExakitHostArch) -eq "arm64") { return "" }
    }
    if (-not [System.Environment]::Is64BitOperatingSystem) { return "" }
    return "exasol-json-tables-ingest-windows-x86_64.exe"
}

# The compiled cargo stand-in, built from setup/shim/json-tables-cargo. Without
# it a prebuilt engine is unreachable on Windows, so it is as much a required
# artifact as the engine itself.
function Get-JsonTablesShimAsset {
    if ((Get-JsonTablesEngineAsset) -eq "") { return "" }
    return "exakit-json-tables-cargo-windows-x86_64.exe"
}

# Twin of json_tables_applicable. Windows x64 is supported now; anything else
# still says so rather than being silently omitted.
function Test-JsonTablesApplicable {
    return ((Get-JsonTablesEngineAsset) -ne "")
}

function Get-JsonTablesApplicableReason {
    return "no prebuilt ingest engine is published for this platform (windows/$(if ((Get-ExakitHostArch) -eq 'arm64') { 'arm64' } else { 'x86' })). Windows x86_64 is supported; ARM64 is not built yet."
}

# Twin of json_tables_system_present: a copy the user installed themselves
# (pip, pipx, uv tool) counts as "already on this machine". The kit does not
# offer a second one and never manages or removes theirs.
function Get-JsonTablesSystemPresent {
    $own = Get-JsonTablesBin
    $found = Get-Command "exasol-json-tables" -ErrorAction SilentlyContinue
    if ($found -and $found.Source) {
        if ($found.Source -ne $own) { return $true }
    }
    # Only the ambient interpreter, never the kit's own venv: importing it
    # there is a KIT install, which is a different thing entirely.
    $python = Get-Command "python" -ErrorAction SilentlyContinue
    if (-not $python -or -not $python.Source) { return $false }
    if ($python.Source.StartsWith($script:JsonTablesVenv, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if ($python.Source.StartsWith($script:ExakitHome, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    # 2>$null IS NOT ENOUGH, and this line is why `exakit version` and
    # `exakit marketplace` died with a bare "Traceback (most recent call
    # last):" on any Windows machine with a stock python on PATH.
    #
    # The subprocess is doing exactly its job: python exits 1 and prints a
    # ModuleNotFoundError to stderr, which is the "not present" answer. But
    # under $ErrorActionPreference = "Stop" - set globally in exakit.ps1 and
    # exakit-common.ps1 - Windows PowerShell turns a native command's stderr
    # into a TERMINATING RemoteException before $LASTEXITCODE is ever read. So
    # the false answer escaped as an exception, through the marketplace list
    # and the version table, into the top-level catch.
    #
    # Invoke-ExakitLogged already carries this defence and a long comment
    # describing the quirk; this probe simply never used it. The bash twin
    # (json_tables_system_present) has no equivalent problem because a shell
    # does not promote stderr to an error.
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $python.Source -c "import exasol_json_tables" 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        # An interpreter that cannot be launched at all is also "not present".
        return $false
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

# Twin of json_tables_installed_version: both halves must really be here. The
# manifest record alone is not evidence - it may have been written by another
# machine, or the files removed since.
function Get-JsonTablesInstalledVersion {
    $recorded = Get-ExakitManifestValue "components.json_tables.version"
    if (-not $recorded) { return "" }
    if (-not (Test-Path (Get-JsonTablesVenvPython))) { return "" }
    if (-not (Test-Path (Get-JsonTablesEnginePath))) { return "" }
    return $recorded
}

function Write-JsonTablesNotInstalled {
    param([Parameter(Mandatory)][string]$Reason)
    Warn2 "JSON Tables was not installed: $Reason"
    Warn2 "Everything else in the kit is unaffected. Retry with: exakit update"
    if (Get-Command Set-ExakitFailureReason -ErrorAction SilentlyContinue) {
        Set-ExakitFailureReason $Reason
    }
    Set-ExakitManifestValue "components.json_tables.validated" $false
    return $false
}

# ---------------------------------------------------------------------------
# The mirror release - twins of the _json_tables_mirror_* helpers
# ---------------------------------------------------------------------------
# $script:JsonTablesMirrorHttp - the status GitHub answered with, so the caller
# can tell "this release does not exist" from "GitHub would not say". Without it
# a 403 read exactly like a 404 and the install told the reader to publish a
# release that already existed; the real answer was that the unauthenticated API
# allows 60 calls an hour and a full install had spent all sixty. Twin of
# EXAKIT_JSON_TABLES_MIRROR_HTTP in json-tables.sh.
$script:JsonTablesMirrorHttp = ""
function Get-JsonTablesMirrorRelease {
    # Cached per TAG: a lookup for one build must never answer for another.
    $tag = Get-JsonTablesReleaseTag
    if ($script:JsonTablesMirrorCache -and ($script:JsonTablesMirrorCacheTag -eq $tag)) { return $script:JsonTablesMirrorCache }
    try {
        $uri = "https://api.github.com/repos/$(Get-JsonTablesMirrorRepo)/releases/tags/$tag"
        # A token when one is present lifts the same limit from 60 an hour to
        # 5000. Unauthenticated stays the default; nothing here requires a token.
        $headers = @{}
        if ($env:GITHUB_TOKEN) { $headers["Authorization"] = "Bearer $($env:GITHUB_TOKEN)" }
        $script:JsonTablesMirrorCache = Invoke-RestMethod -Uri $uri -UseBasicParsing -TimeoutSec 20 -Headers $headers
        $script:JsonTablesMirrorCacheTag = $tag
        $script:JsonTablesMirrorHttp = "200"
        return $script:JsonTablesMirrorCache
    } catch {
        $script:JsonTablesMirrorHttp = ""
        try {
            if ($_.Exception.Response) {
                $script:JsonTablesMirrorHttp = [string][int]$_.Exception.Response.StatusCode
            }
        } catch { }
        return $null
    }
}

function Get-JsonTablesMirrorAssetUrl {
    param([Parameter(Mandatory)][string]$Asset)
    return "https://github.com/$(Get-JsonTablesMirrorRepo)/releases/download/$(Get-JsonTablesReleaseTag)/$Asset"
}

# The wheel's real filename: its version comes from upstream's pyproject, not
# from ours, so it is read off the release rather than constructed.
function Get-JsonTablesMirrorWheelName {
    # PINNED FIRST, network second - twin of the same order in json-tables.sh.
    # exapump and exasol-vscode both carry their artefact digests in
    # versions.json and never ask an API for them; this one asked, so every
    # install depended on GitHub answering, and GitHub allows sixty requests an
    # hour per IP without a token. The download is a plain release URL needing
    # no API budget, so a pinned name and digest take the API off the install
    # path entirely. The pin describes the ADVERTISED build only; a build chosen
    # by hand reads its own release.
    if (Test-JsonTablesPinApplies) {
        $pin = Get-ExakitVersionsValue "components.json-tables.wheel"
        if ($pin) { return $pin }
    }
    $release = Get-JsonTablesMirrorRelease
    if (-not $release) { return "" }
    # NEWEST wheel, not the first one listed. The mirror release is rolling and
    # accumulates assets across runs, so it can hold several wheels at once -
    # taking the first would install an old one while recording the version of
    # the current build, a mismatch no update could ever close. The most
    # recently uploaded asset is the one this build published.
    $wheels = @($release.assets | Where-Object { $_.name -and $_.name.EndsWith(".whl") })
    if ($wheels.Count -eq 0) { return "" }
    $newest = $wheels | Sort-Object { [datetime]$_.created_at } -Descending | Select-Object -First 1
    return $newest.name
}

# The sha256 for a release asset: from versions.json for the advertised build,
# and from the release API for any other. Releases are immutable, so a pin can
# only disagree with its asset if the document was edited by hand - and CI
# refuses that edit.
#
# Keyed by PLATFORM, not by asset name. The versions lookup walks a DOTTED path
# and an asset name carries a version - "...-0.2.0-..." - whose dots split into
# path segments that do not exist, so a name-keyed lookup returns nothing and
# falls through to the network it was meant to avoid.
function Get-JsonTablesMirrorDigest {
    param([Parameter(Mandatory)][string]$Asset)
    $key = ""
    if ($Asset.EndsWith(".whl")) { $key = "wheel" }
    elseif ($Asset.StartsWith("exakit-json-tables-cargo-")) {
        $key = "cargo-" + ($Asset.Substring("exakit-json-tables-cargo-".Length) -replace "\.exe$", "")
    } elseif ($Asset.StartsWith("exasol-json-tables-ingest-")) {
        $key = ($Asset.Substring("exasol-json-tables-ingest-".Length) -replace "\.exe$", "")
    }
    if ($key -and (Test-JsonTablesPinApplies)) {
        $pin = Get-ExakitVersionsValue "components.json-tables.sha256.$key"
        if ($pin) { return $pin }
    }
    $release = Get-JsonTablesMirrorRelease
    if (-not $release) { return "" }
    # The loop variable must NOT be spelled $asset: PowerShell identifiers are
    # case-insensitive, so it would be the same variable as the $Asset
    # parameter and would overwrite the very name being searched for. Every
    # digest then came back empty, and an empty digest means the download is
    # refused as unverifiable - the add-on could never install.
    foreach ($candidate in @($release.assets)) {
        if ($candidate.name -eq $Asset -and $candidate.digest -and ("" + $candidate.digest).StartsWith("sha256:")) {
            return ("" + $candidate.digest).Substring(7)
        }
    }
    return ""
}

# The generic <id>_latest hook; twin of json_tables_latest. "Latest" deliberately
# means what versions.json ADVERTISES: the packaging workflow publishes an
# immutable json-tables-<version> release first and only then advertises it, so
# the advertised build is the one whose artifacts are guaranteed to exist. No
# network call is needed to answer.
function Get-JsonTablesLatest {
    $advertised = Get-ExakitVersionsValue "components.json-tables.version"
    if ($advertised) { return $advertised }
    return $script:JsonTablesVersionFallback
}

# Download one mirror asset and verify it against the digest the release
# publishes. Same bar as exapump and the VS Code extension: an artifact that
# cannot be verified is not installed.
function Get-JsonTablesVerifiedAsset {
    param([Parameter(Mandatory)][string]$Asset, [Parameter(Mandatory)][string]$Destination)
    $url = Get-JsonTablesMirrorAssetUrl -Asset $Asset
    Info "Downloading $Asset"
    try {
        # Animated: the download is the longest silent stretch of this install.
        # Twin of fetch_quiet on the shell side.
        [void](Invoke-ExakitWithSpinner -Label "Downloading $Asset" -Body {
            Invoke-WebRequest -UseBasicParsing -TimeoutSec 300 -Uri $url -OutFile $Destination
        })
    } catch {
        Warn2 "Download failed: $url ($_)"
        return $false
    }
    $expected = Get-JsonTablesMirrorDigest -Asset $Asset
    if ($expected) {
        $actual = Get-ExakitSha256 $Destination
        if ($actual -ne $expected) {
            Remove-Item -Force -ErrorAction SilentlyContinue $Destination
            Warn2 "Checksum mismatch for $Asset (expected $expected, got $actual)"
            return $false
        }
        Ok "Checksum verified: $Asset"
        return $true
    }
    if ($env:EXAKIT_ALLOW_UNVERIFIED_JSON_TABLES -eq "1") {
        Warn2 "No digest available for $Asset - proceeding WITHOUT checksum verification (EXAKIT_ALLOW_UNVERIFIED_JSON_TABLES=1)."
        return $true
    }
    Remove-Item -Force -ErrorAction SilentlyContinue $Destination
    Warn2 "No checksum is available for $Asset; refusing an unverified artifact. Usually the release is still publishing or the GitHub API was unreachable - retry with: exakit update json-tables. Add its digest to versions.json (components.json-tables.sha256) or, at your own risk, override with EXAKIT_ALLOW_UNVERIFIED_JSON_TABLES=1."
    return $false
}

# Test-JsonTablesAppControl - is this machine refusing to run unsigned
# executables?
#
# The kit's prebuilt engine and cargo shim are not code-signed, and a Windows
# box with Windows Defender Application Control in ENFORCED mode (or Smart App
# Control on) refuses to start them with a bare "Access is denied" - the same
# symptom a corrupt download or a wrong-architecture binary produces. Observed
# on a managed corporate machine: a signed executable copied into the very same
# directory ran fine while the engine did not, with the digest matching the
# published artifact byte for byte.
#
# Answering this before blaming the artifact is what turns a dead end into a
# next step the user can actually take.
function Test-JsonTablesAppControl {
    try {
        $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction Stop
        if ($dg.CodeIntegrityPolicyEnforcementStatus -ge 2) { return $true }
        if ($dg.UsermodeCodeIntegrityPolicyEnforcementStatus -ge 2) { return $true }
    } catch { }
    try {
        $ci = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy" -ErrorAction Stop
        # 1 = Smart App Control on, 2 = evaluation mode.
        if ($ci.VerifiedAndReputablePolicyState -eq 1) { return $true }
    } catch { }
    return $false
}

function Install-JsonTables {
    if (-not (Test-JsonTablesApplicable)) {
        return (Write-JsonTablesNotInstalled (Get-JsonTablesApplicableReason))
    }

    # versions.json decides what gets installed - version, release tag, wheel
    # and digests all come from that one document, so the version recorded here
    # is the version of the artifacts on disk. Twin of the same block in
    # json_tables_install.
    if (-not $script:JsonTablesVersion) {
        $script:JsonTablesVersion = Get-JsonTablesTargetVersion
    }

    $engineAsset = Get-JsonTablesEngineAsset
    $shimAsset = Get-JsonTablesShimAsset

    $wheelName = Get-JsonTablesMirrorWheelName
    if (-not $wheelName) {
        # The status decides the sentence. Reporting "not found" for every
        # failure sent a reader off to publish a release that already existed.
        if ($script:JsonTablesMirrorHttp -eq "403" -or $script:JsonTablesMirrorHttp -eq "429") {
            $tok = ""
            if (-not $env:GITHUB_TOKEN) { $tok = " (or set GITHUB_TOKEN, which raises the limit to 5000)" }
            return (Write-JsonTablesNotInstalled "GitHub refused the lookup - its API allows 60 requests an hour without a token and this install has used them. Wait for the hour to turn over, then run: exakit marketplace$tok")
        }
        if ($script:JsonTablesMirrorHttp -eq "404") {
            return (Write-JsonTablesNotInstalled "the prebuilt release '$(Get-JsonTablesReleaseTag)' was not found in $(Get-JsonTablesMirrorRepo). Run the 'pkg / json-tables' workflow to publish it (it assembles the engine and the cargo shim for every platform - fetching what upstream prebuilds, building the rest - so nobody needs Rust).")
        }
        $extra = ""
        if ($script:JsonTablesMirrorHttp) { $extra = " (HTTP $($script:JsonTablesMirrorHttp))" }
        return (Write-JsonTablesNotInstalled "GitHub could not be reached to find the prebuilt engine$extra. Check the network, then run: exakit marketplace")
    }

    try {
        $uv = Install-ExakitUv
    } catch {
        return (Write-JsonTablesNotInstalled "uv (the Python tool runner) is not available - install it from https://docs.astral.sh/uv/ and re-run")
    }
    if (-not $uv) {
        return (Write-JsonTablesNotInstalled "uv (the Python tool runner) is not available - install it from https://docs.astral.sh/uv/ and re-run")
    }

    Info "Installing JSON Tables $($script:JsonTablesVersion) (prebuilt)"
    $python = Get-JsonTablesVenvPython
    if (-not (Test-Path $python)) {
        $code = Invoke-ExakitLogged $uv "venv" "--seed" "--python" $script:ManagedPythonVersion $script:JsonTablesVenv
        if ($code -ne 0) {
            return (Write-JsonTablesNotInstalled "the virtual environment at $($script:JsonTablesVenv) could not be created (see log)")
        }
    }

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-json-tables-" + [guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        # 1. the Python package
        $wheelPath = Join-Path $tmp $wheelName
        if (-not (Get-JsonTablesVerifiedAsset -Asset $wheelName -Destination $wheelPath)) {
            return (Write-JsonTablesNotInstalled "the prebuilt wheel could not be downloaded or verified (see log)")
        }
        $code = Invoke-ExakitLogged $uv "pip" "install" "--python" $python $wheelPath
        if ($code -ne 0) {
            return (Write-JsonTablesNotInstalled "installing $wheelName failed (see log)")
        }
        Restore-JsonTablesPackageData

        # 2. the ingest engine, prebuilt for this platform
        $enginePath = Get-JsonTablesEnginePath
        $engineTmp = Join-Path $tmp "engine.exe"
        if (-not (Get-JsonTablesVerifiedAsset -Asset $engineAsset -Destination $engineTmp)) {
            return (Write-JsonTablesNotInstalled "the prebuilt ingest engine ($engineAsset) could not be downloaded or verified (see log)")
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $enginePath) | Out-Null
        Move-Item -Force -Path $engineTmp -Destination $enginePath

        # 3. the compiled cargo shim - the piece that makes a prebuilt engine
        #    reachable at all on Windows.
        $shimDir = Get-JsonTablesShimDir
        $shimPath = Join-Path $shimDir "cargo.exe"
        $shimTmp = Join-Path $tmp "cargo.exe"
        if (-not (Get-JsonTablesVerifiedAsset -Asset $shimAsset -Destination $shimTmp)) {
            return (Write-JsonTablesNotInstalled "the cargo shim ($shimAsset) could not be downloaded or verified. Without it the CLI cannot reach the prebuilt engine on Windows (see log)")
        }
        New-Item -ItemType Directory -Force -Path $shimDir | Out-Null
        Move-Item -Force -Path $shimTmp -Destination $shimPath
    } finally {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmp
    }

    # The engine must actually run HERE: a binary for the wrong arch would
    # otherwise surface much later, in the middle of someone's ingest.
    $code = Invoke-ExakitLogged (Get-JsonTablesEnginePath) "--help"
    if ($code -ne 0) {
        if (Test-JsonTablesAppControl) {
            return (Write-JsonTablesNotInstalled "the prebuilt ingest engine was downloaded and its checksum verified, but this machine refuses to run it: Windows application control (WDAC / Smart App Control) is enforcing, and the engine is not code-signed. This is a policy on the machine, not a fault in the download. Ask whoever manages this device to allow $(Get-JsonTablesEnginePath), or use WSL, where the same add-on installs and runs unrestricted.")
        }
        return (Write-JsonTablesNotInstalled "the prebuilt ingest engine does not run on this machine (see log)")
    }

    if (-not (Write-JsonTablesLauncher)) { return $false }

    Set-ExakitManifestValue "components.json_tables.version" $script:JsonTablesVersion
    Set-ExakitManifestValue "components.json_tables.venv" $script:JsonTablesVenv
    Set-ExakitManifestValue "components.json_tables.python" (Get-JsonTablesVenvPython)
    Set-ExakitManifestValue "components.json_tables.engine" (Get-JsonTablesEnginePath)
    Set-ExakitManifestValue "components.json_tables.shim" (Join-Path (Get-JsonTablesShimDir) "cargo.exe")
    Set-ExakitManifestValue "components.json_tables.command" (Get-JsonTablesBin)
    Ok "JSON Tables installed: $($script:JsonTablesVenv)"
    return $true
}

# Twin of _json_tables_restore_package_data.
#
# UPSTREAM PACKAGING GAP: pyproject covers the .py modules under
# python/exasol_json_tables but not preprocessor_assets/jvs_preprocessor_lib.lua,
# so every prebuilt wheel is missing it. `ingest` is unaffected;
# `ingest-and-wrap` and `wrap` fail with FILE-NOT-FOUND when they reach the
# step that installs the preprocessor into Exasol. Nothing is overwritten, so a
# fixed upstream release simply makes this a no-op.
function Restore-JsonTablesPackageData {
    $python = Get-JsonTablesVenvPython
    if (-not (Test-Path $python)) { return }
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $site = & $python -c "import exasol_json_tables, os; print(os.path.dirname(exasol_json_tables.__file__))" 2>$null
    } catch {
        $site = $null
    } finally { $ErrorActionPreference = $prevEap }
    if (-not $site -or -not (Test-Path $site)) { return }
    $asset = Join-Path $site "preprocessor_assets\jvs_preprocessor_lib.lua"
    if (Test-Path $asset) { return }
    $repo = if ($env:EXAKIT_JSON_TABLES_REPO) { $env:EXAKIT_JSON_TABLES_REPO } else { "exasol-labs/exasol-json-tables" }
    $url = "https://raw.githubusercontent.com/$repo/main/python/exasol_json_tables/preprocessor_assets/jvs_preprocessor_lib.lua"
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $asset) | Out-Null
        [void](Invoke-ExakitWithSpinner -Label "Restoring the JSON Tables preprocessor asset" -Body {
            Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri $url -OutFile $asset
        })
        Info "Restored 1 data file the release does not declare as package data (upstream packaging gap; ingest-and-wrap needs it)"
    } catch {
        # Not fatal: plain `ingest` works without it.
    }
}

# Write-JsonTablesLauncher - the command a user runs.
#
# It puts the shim dir at the FRONT of PATH for this process only, so the CLI's
# `cargo` call reaches our cargo.exe while the user's real cargo stays untouched
# everywhere else, and names the engine in the environment so the shim does not
# have to guess.
function Write-JsonTablesLauncher {
    New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null
    $launcher = Get-JsonTablesBin
    $venvBin = Join-Path $script:JsonTablesVenv "Scripts\exasol-json-tables.exe"
    $lines = @(
        '@echo off',
        'rem exasol-json-tables launcher - generated by the Exasol Personal Local',
        'rem Starter Kit. Runs the CLI from its kit-managed venv with the prebuilt',
        'rem ingest engine reachable through the compiled cargo shim, so no Rust',
        'rem toolchain is needed. Regenerated by: exakit update',
        # setlocal: without it this wrapper permanently prepended its fake-cargo
        # shim directory to the CALLER's PATH - shadowing a real Rust toolchain
        # for the rest of that console, and growing PATH by one entry on every
        # invocation. The shim is an implementation detail of this launcher and
        # has no business outliving it.
        'setlocal',
        ('set "PATH=' + (Get-JsonTablesShimDir) + ';%PATH%"'),
        ('set "EXAKIT_JSON_TABLES_ENGINE=' + (Get-JsonTablesEnginePath) + '"'),
        ('"' + $venvBin + '" %*')
    )
    try {
    # In the code page cmd.exe reads a batch file in, not ASCII. `-Encoding Ascii`
    # turns every byte above 0x7F into a literal "?", so a profile path like
    # C:\Users\Wojcik with an accent silently produced a launcher pointing at a
    # directory that does not exist - while the install printed "launcher
    # written". Same approach as Set-ExakitCmdShim, including its fallback: a
    # machine whose OEM code page cannot be resolved keeps the old behaviour
    # rather than losing the file.
    $oemEnc = Get-ExakitOemEncoding
    if ($oemEnc) { [System.IO.File]::WriteAllText($launcher, ($lines -join "`r`n"), $oemEnc) }
    else { Set-Content -Path $launcher -Value ($lines -join "`r`n") -Encoding Ascii }
    } catch {
        return (Write-JsonTablesNotInstalled "could not write the launcher at $launcher")
    }
    Ok "JSON Tables launcher written: $launcher"
    if (Get-Command Confirm-ExakitOnPath -ErrorAction SilentlyContinue) {
        Confirm-ExakitOnPath $script:BinDir
    }
    return $true
}

# Prove the whole path, not just that files exist: the package imports, and a
# real JSON file goes through the prebuilt engine and comes out as Parquet.
# That round trip is the only evidence the no-Rust story holds on this machine.
function Test-JsonTables {
    $python = Get-JsonTablesVenvPython
    if (-not (Test-Path $python)) { return }

    # Same stderr-promotion trap as Get-JsonTablesSystemPresent: an import that
    # fails writes to stderr, and under $ErrorActionPreference = "Stop" that is
    # a terminating exception rather than a non-zero exit code. Here it would
    # turn "installed but broken", which this branch exists to report, into an
    # unhandled crash.
    $importCode = 1
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $python -c "import exasol_json_tables" 2>&1 | Out-Null
        $importCode = $LASTEXITCODE
    } catch {
        $importCode = 1
    } finally {
        $ErrorActionPreference = $prevEap
    }
    if ($importCode -ne 0) {
        Warn2 "JSON Tables is installed but cannot be imported from $($script:JsonTablesVenv). Why: exakit logs setup. Recorded validated=false; retry with: exakit update"
        Set-ExakitManifestValue "components.json_tables.validated" $false
        return
    }

    Info "Validating JSON Tables (a real JSON file through the prebuilt engine)"
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-jt-check-" + [guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $sample = Join-Path $tmp "sample.json"
        Set-Content -Path $sample -Value '[{"id":1,"name":"alpha"},{"id":2,"name":"beta"}]' -Encoding ASCII
        $outDir = Join-Path $tmp "out"
        $code = Invoke-JsonTablesLogged -Exe (Get-JsonTablesEnginePath) -Arguments @("--input", $sample, "--output-dir", $outDir)
        $parquet = @()
        if (Test-Path $outDir) {
            $parquet = @(Get-ChildItem -Path $outDir -Filter *.parquet -Recurse -ErrorAction SilentlyContinue)
        }
        if ($code -eq 0 -and $parquet.Count -gt 0) {
            Ok "Ingest works: JSON in, Parquet out"
            Set-ExakitManifestValue "components.json_tables.validated" $true
            # See the note on Write-DashServerUsagePanel: a marketplace
            # install is not where a reference card belongs.
            if ($script:ExakitQuietDetail) {
                Write-ExakitLog "DATA" "json-tables: exasol-json-tables ingest --input <file.json>"
                return
            }
            Start-ExakitPanel "JSON Tables"
            Write-ExakitPanelLine "Run it          exasol-json-tables --help"
            Write-ExakitPanelLine "Ingest JSON     exasol-json-tables ingest --input <file.json>"
            Write-ExakitPanelLine "Engine          $(Get-JsonTablesEnginePath)"
            Write-ExakitPanelLine "Update          exakit update"
            Complete-ExakitPanel
            return
        }
    } finally {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmp
    }
    Warn2 "The ingest round trip did not produce Parquet (see: exakit logs json-tables). Recorded validated=false; retry with: exakit update"
    Set-ExakitManifestValue "components.json_tables.validated" $false
}

# The venv, the engine, the shim, the launcher and the manifest record.
# Get-JsonTablesSummary - the one fact worth a place on the result line.
# Optional registry hook (SummaryFn); twin of json_tables_summary.
function Get-JsonTablesSummary {
    # 31 characters: the finished cell truncates at 33 in the plain palette.
    return "ingest JSON: exasol-json-tables"
}

function Uninstall-JsonTables {
    param([switch]$DryRun)
    foreach ($path in @($script:JsonTablesVenv, $script:JsonTablesHome, (Get-JsonTablesBin))) {
        if (-not (Test-Path $path)) { continue }
        if ($DryRun) {
            Info "  will remove: $path"
        } else {
            Info "Removing $path"
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $path
        }
    }
    if (-not $DryRun) {
        Remove-ExakitManifestValue "components.json_tables"
        Remove-ExakitManifestValue "desired.json_tables"
        OkStep "JSON Tables removed - reinstall any time with: exakit marketplace"
    }
    return $true
}

# Install the advertised build. Doubles as the repair command (it re-downloads
# the engine and the shim and rewrites the launcher), so an explicit
# `exakit update json-tables` is always worth running.
function Update-JsonTables {
    if (-not (Test-JsonTablesApplicable)) {
        Warn2 "JSON Tables is not available on this machine: $(Get-JsonTablesApplicableReason)"
        return $false
    }
    # versions.json is the authority on what can be installed: the packaging
    # workflow publishes the release before the version is ever advertised.
    $available = Get-ExakitAddonAdvertisedVersion -Id "json-tables" -Fallback $script:JsonTablesVersionFallback
    if (-not $available) { Fail "Could not resolve the advertised json-tables version." }
    $current = Get-JsonTablesInstalledVersion
    # Same build, and every downloaded piece still on disk: rewrite the
    # launcher so a newer kit's improvements reach an existing install, then
    # stop. Without this, `exakit update` re-downloaded the wheel, the ingest
    # engine AND the compiled cargo shim on every single run - three release
    # assets for no change - while macOS and Linux did nothing and said
    # "already current". A missing engine or shim falls through to the full
    # install, which is the repair path. Twin of the early return in
    # json_tables_update.
    $shimPath = Join-Path (Get-JsonTablesShimDir) "cargo.exe"
    if ($current -and $current -eq $available -and
        (Test-Path (Get-JsonTablesEnginePath)) -and (Test-Path $shimPath)) {
        [void](Write-JsonTablesLauncher)
        Ok "JSON Tables is already current ($current)"
        return $true
    }
    if ($current) { Info "Updating JSON Tables $current -> $available" }
    else { Info "Installing JSON Tables $available" }
    $script:JsonTablesVersion = $available
    if (-not (Install-JsonTables)) {
        Fail "JSON Tables could not be installed - see the warning above and the log."
    }
    Test-JsonTables
    Set-ExakitManifestValue "desired.json_tables" $script:JsonTablesVersion
    Ok "JSON Tables updated; database data was not changed"
    return $true
}
