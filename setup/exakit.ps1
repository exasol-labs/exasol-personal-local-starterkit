# exakit.ps1 - lifecycle helper for the Exasol Personal Local Starter Kit
# (Windows / PowerShell path). Mirrors setup/exakit function-for-function.
#
# usage: exakit <command> [args]
#
#   preflight            check this machine's requirements, install nothing
#   status                show what is installed and whether it is healthy
#   version               kit source, install date, component versions
#   update-check [what]   check latest versions (all, runtime, exakit, exapump, mcp)
#   update [what]         update all or one component without deleting database data
#   info                  print the connection details panel
#   guide                 friendly walkthrough: connect AI clients (MCP), SQL
#                         clients (DBeaver), and Python (pyexasol)
#   start                 start the local database
#   stop                  stop the local database
#   data-load [-Force]    open focused data loading options; -Force reloads bundled sample data
#   mcp-setup             permanently configure MCP in supported AI clients
#   mcp-doctor [clients]  check MCP config, connectivity, and managed state
#   mcp-status [clients]  show managed MCP state for the supported AI clients
#   mcp-validate [clients] validate managed MCP configs and test connectivity
#   mcp-repair [clients]  repair managed MCP config drift
#   mcp-remove [clients]  remove managed MCP config from the supported clients
#   mcp-restore [snapshot] restore the latest (or a chosen) MCP snapshot
#   skills-install        install the kit's AI skills for CLI agents
#                         (~\.claude\skills, ~\.agents\skills)
#   uninstall [-Yes] [-DryRun]
#                         remove EVERYTHING the kit installed: database + all
#                         data, MCP client configs, skills, exapump, the kit
#                         home and the CLI binaries. -DryRun previews; -Yes
#                         skips the typed confirmation
#   logs                  print the path of the latest setup log
#   catalog [search]      browse/search every exakit, exapump & exasol command
#   help                  this text
#
# Installed to %USERPROFILE%\.local\bin by setup-windows-docker.ps1; also
# runs straight from a repo checkout (setup\exakit.ps1).

param(
    [Parameter(Position = 0)][string]$Command = "help",
    [Parameter(Position = 1, ValueFromRemainingArguments)][string[]]$RestArgs = @()
)

$ErrorActionPreference = "Stop"

# --- locate the kit's lib directory -----------------------------------------
$scriptDir = Split-Path -Parent $PSCommandPath
if (Test-Path (Join-Path $scriptDir "lib\exakit-common.ps1")) {
    $libDir = Join-Path $scriptDir "lib"
} else {
    $fallbackHome = if ($env:EXAKIT_HOME) { $env:EXAKIT_HOME } else { Join-Path $HOME ".exasol-starter-kit" }
    $fallbackLib = Join-Path $fallbackHome "kit\setup\lib"
    if (Test-Path (Join-Path $fallbackLib "exakit-common.ps1")) {
        $libDir = $fallbackLib
    } else {
        Write-Host "exakit: cannot find the kit library (looked in $scriptDir\lib and $fallbackHome\kit)" -ForegroundColor Red
        exit 1
    }
}

. (Join-Path $libDir "exakit-common.ps1")
. (Join-Path $libDir "nano.ps1")
. (Join-Path $libDir "exapump.ps1")
. (Join-Path $libDir "mcp.ps1")

function Get-RuntimeType { return (Get-ExakitManifestValue "runtime.type") }

function Assert-ExakitInstalled {
    if (-not (Test-Path $script:ManifestPath)) { Fail "No installation found. Run the installer first." }
    if (-not (Get-RuntimeType)) { Fail "No runtime recorded in the manifest yet." }
}

function Invoke-CmdStatus {
    if (-not (Test-Path $script:ManifestPath)) {
        Write-Host "Not installed (no manifest at $script:ManifestPath)"
        return
    }
    $type = Get-RuntimeType
    Write-Host "Kit level:  $(Get-ExakitManifestValue 'kit_level')"
    Write-Host "Runtime:    $(if ($type) { $type } else { 'none' })"
    $status = switch ($type) { "nano" { Get-NanoStatus } default { "unknown" } }
    Write-Host "Status:     $status"
    $steps = @(Get-ExakitManifestValue "steps_completed")
    Write-Host "Steps done: $($steps -join ', ')"
    Write-Host "Manifest:   $script:ManifestPath"
}

function Invoke-CmdStart {
    Assert-ExakitInstalled
    switch (Get-RuntimeType) { "nano" { Start-Nano } }
}

function Invoke-CmdStop {
    Assert-ExakitInstalled
    switch (Get-RuntimeType) { "nano" { Stop-Nano } }
}

# Invoke-ExakitUninstallRun -DryRun - remove every artifact the kit installs, in
# dependency order: the local database and ALL its data, the managed MCP client
# configs, the installed AI skills, the exapump profile, the kit home, and the
# CLI binaries. With -DryRun it prints the plan and changes nothing. Mirrors
# exakit_uninstall_run in setup/lib/common.sh. uv/uvx (a shared tool) and the
# PATH entry are intentionally left in place and only reported.
function Invoke-ExakitUninstallRun {
    param([switch]$DryRun)

    # 1) Database + all data (the Windows runtime is Nano).
    $type = Get-RuntimeType
    if ($type) {
        if ($DryRun) {
            Info "  will remove: local Exasol $type deployment and ALL its data"
        } else {
            Info "Removing the local Exasol $type deployment and all data"
            switch ($type) {
                "nano" { try { Remove-Nano -Data } catch { Warn2 "Database removal reported errors (continuing uninstall)" } }
                default { Warn2 "Unknown runtime type '$type'; skipping database removal" }
            }
        }
    }

    # 2) Managed MCP configuration in the AI clients. Best-effort.
    if (Get-Command Invoke-McpOperation -ErrorAction SilentlyContinue) {
        if ($DryRun) {
            Info "  will remove: managed MCP configuration in Claude (desktop + Claude Code CLI), Cursor, and Codex"
        } else {
            Info "Removing managed MCP configuration from AI clients"
            try { [void](Invoke-McpOperation -Operation "uninstall" -InputArgs @()) }
            catch { Warn2 "Removing the managed MCP client config reported issues (continuing uninstall)" }
        }
    }

    # 3) Installed AI skills. Prefer the live list from the kit's skills dir;
    #    fall back to the known names when the checkout is already gone.
    $skillNames = @()
    try {
        $repoRoot = Get-ExakitRepoRoot
        if ($repoRoot -and (Test-Path (Join-Path $repoRoot "skills"))) {
            $skillNames = Get-ChildItem -Directory (Join-Path $repoRoot "skills") -ErrorAction SilentlyContinue |
                Where-Object { Test-Path (Join-Path $_.FullName "SKILL.md") } |
                ForEach-Object { $_.Name }
        }
    } catch { $skillNames = @() }
    if (-not $skillNames -or $skillNames.Count -eq 0) {
        $skillNames = @("local-agent-ready-starter", "trusted-ai-workflow")
    }
    foreach ($root in @((Join-Path $HOME ".claude\skills"), (Join-Path $HOME ".agents\skills"))) {
        foreach ($name in $skillNames) {
            $p = Join-Path $root $name
            if (Test-Path $p) {
                if ($DryRun) { Info "  will remove: AI skill $p" }
                else { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $p }
            }
        }
    }

    # 4) exapump profile store (the kit created it; the binary goes in step 6).
    $exapumpDir = Join-Path $HOME ".exapump"
    if (Test-Path $exapumpDir) {
        if ($DryRun) { Info "  will remove: exapump profiles at $exapumpDir" }
        else { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $exapumpDir }
    }

    # 5) Kit home: credentials, logs, manifest, cached kit copy, MCP snapshots.
    if (Test-Path $script:ExakitHome) {
        if ($DryRun) { Info "  will remove: kit home $script:ExakitHome (credentials, logs, manifest, snapshots)" }
        else { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $script:ExakitHome }
    }

    # 6) CLI binaries. Removed last so earlier steps can still call them.
    #    exakit.cmd is the wrapper cmd.exe is still executing right now; deleting
    #    it in-process makes cmd.exe print "The batch file cannot be found." when
    #    it re-reads the file after we exit. So collect the binaries and hand
    #    their removal to a detached process that waits for us to exit first.
    $binPaths = @()
    foreach ($bin in @("exakit.cmd", "exapump.exe", "exasol.exe", "exakit.ps1")) {
        $p = Join-Path $script:BinDir $bin
        if (Test-Path $p) {
            if ($DryRun) { Info "  will remove: CLI binary $p" }
            else { $binPaths += $p }
        }
    }
    if (-not $DryRun -and $binPaths.Count -gt 0) {
        Remove-ExakitBinariesDeferred -Paths $binPaths
    }
}

# Delete the CLI binaries from a short-lived detached PowerShell that first
# waits for this process (and the cmd.exe running exakit.cmd) to exit. Deleting
# exakit.cmd while cmd.exe is still executing it is what makes the shell print
# "The batch file cannot be found."; deferring avoids that entirely.
function Remove-ExakitBinariesDeferred {
    param([string[]]$Paths)
    $waitPids = @($PID)
    try {
        $me = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop
        # The parent is the cmd.exe running exakit.cmd - the one that re-reads
        # the batch file after we return. Wait for it too, but not its parent
        # (the user's interactive shell, which never exits).
        if ($me.ParentProcessId) { $waitPids += [int]$me.ParentProcessId }
    } catch { }
    $waitPids = @($waitPids | Sort-Object -Unique)
    $pidList = $waitPids -join ','
    $quoted  = ($Paths | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
    $deferred = @"
foreach (`$id in @($pidList)) { try { Wait-Process -Id `$id -Timeout 60 -ErrorAction SilentlyContinue } catch {} }
Start-Sleep -Milliseconds 250
foreach (`$f in @($quoted)) { try { Remove-Item -Force -ErrorAction SilentlyContinue `$f } catch {} }
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($deferred))
    try {
        Start-Process -FilePath "powershell.exe" `
            -ArgumentList @("-NoProfile", "-WindowStyle", "Hidden", "-EncodedCommand", $encoded) `
            -WindowStyle Hidden | Out-Null
    } catch {
        # If we cannot spawn the detached cleaner, fall back to deleting inline.
        # The batch-file message may reappear, but the binaries are still gone.
        foreach ($f in $Paths) { Remove-Item -Force -ErrorAction SilentlyContinue $f }
    }
}

function Invoke-CmdUninstall {
    param([switch]$AssumeYes, [switch]$DryRun)
    Initialize-ExakitLogging

    if (-not (Test-Path $script:ManifestPath) -and
        -not (Test-Path (Join-Path $script:BinDir "exakit.cmd")) -and
        -not (Test-Path $script:ExakitHome)) {
        Info "Nothing to uninstall - no manifest, kit home, or installed binaries were found."
        return
    }

    Write-Host ""
    Warn2 "exakit uninstall PERMANENTLY removes the Exasol Personal Local Starter Kit."
    Info "The following will be removed:"
    Invoke-ExakitUninstallRun -DryRun
    Write-Host ""
    Warn2 "This is IRREVERSIBLE - all local database data will be lost."
    Info "Not touched: uv/uvx (shared tool) and any PATH entry in your profile."

    if ($DryRun) { Write-Host ""; Info "Dry run only - nothing was removed."; return }

    if (-not $AssumeYes) {
        if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
            Fail "uninstall needs an interactive terminal to confirm; re-run with -Yes to proceed non-interactively."
        }
        Write-Host "  ! Type " -ForegroundColor Red -NoNewline
        Write-Host "UNINSTALL" -ForegroundColor White -NoNewline
        Write-Host " to confirm (anything else cancels): " -ForegroundColor Red -NoNewline
        $answer = Read-Host
        if ($answer -cne "UNINSTALL") { Info "Uninstall cancelled."; return }
    }

    Write-Host ""
    Invoke-ExakitUninstallRun
    Write-Host ""
    Ok "Uninstall complete - the Exasol Personal Local Starter Kit has been removed."
    Info "If a PATH entry for $script:BinDir remains in your profile, remove it manually if you no longer need it."
}

function Invoke-CmdVersion {
    if (-not (Test-Path $script:ManifestPath)) { Write-Host "Not installed (no manifest at $script:ManifestPath)"; return }
    Write-Host "Kit level:      $(Get-ExakitManifestValue 'kit_level')"
    Write-Host "Kit source:     $(Get-ExakitManifestValue 'kit.source')"
    Write-Host "Installed at:   $(Get-ExakitManifestValue 'installed_at')"
    $runtimeVersion = Get-ExakitManifestValue "runtime.version"
    if (-not $runtimeVersion) { $runtimeVersion = Get-ExakitManifestValue "runtime.image" }
    Write-Host "Runtime:        $(Get-RuntimeType) $runtimeVersion"
    Write-Host "exapump:        $(Get-ExakitManifestValue 'components.exapump.version')"
    Write-Host "MCP server:     $(Get-ExakitManifestValue 'components.mcp_server.package') $(Get-ExakitManifestValue 'components.mcp_server.version')"
    Write-Host "pyexasol:       $(Get-ExakitManifestValue 'components.pyexasol.version')"
    Invoke-CmdUpdateCheck -Target "all"
}

function Get-ExakitUpdateTargets {
    param([string]$Target = "all")
    switch ($Target) {
        "all" { return @("exakit", "runtime", "exapump", "mcp") }
        { $_ -in @("runtime", "database", "db") } { return @("runtime") }
        { $_ -in @("nano", "personal", "exakit", "exapump", "mcp") } { return @($Target) }
        default { Fail "Unknown update target: $Target" }
    }
}

function Get-ExakitLatestGithubRelease {
    param([Parameter(Mandatory)][string]$Repo)
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -UseBasicParsing -TimeoutSec 12
        return ("" + $release.tag_name).TrimStart("v")
    } catch { return "" }
}

function Get-ExakitLatestPypiVersion {
    param([Parameter(Mandatory)][string]$Package)
    try {
        $doc = Invoke-RestMethod -Uri "https://pypi.org/pypi/$Package/json" -UseBasicParsing -TimeoutSec 12
        return "" + $doc.info.version
    } catch { return "" }
}

function Get-ExakitLatestDockerTag {
    try {
        $doc = Invoke-RestMethod -Uri "https://hub.docker.com/v2/repositories/$($script:NanoImage)/tags?page_size=100&ordering=last_updated" -UseBasicParsing -TimeoutSec 12
        $candidates = @($doc.results | ForEach-Object { $_.name } | Where-Object { $_ -match '^\d+(\.\d+)+[-._A-Za-z0-9]*$' -and $_ -notmatch 'latest' })
        if ($candidates.Count -eq 0) { return "" }
        return ($candidates | Sort-Object { [regex]::Replace($_, '\d+', { param($m) $m.Value.PadLeft(12, '0') }) } | Select-Object -Last 1)
    } catch { return "" }
}

function Test-ExakitVersionNewer {
    param([string]$Latest, [string]$Current)
    if (-not $Latest -or -not $Current -or $Latest -eq $Current) { return $false }
    $lk = [regex]::Replace($Latest.TrimStart("v"), '\d+', { param($m) $m.Value.PadLeft(12, '0') })
    $ck = [regex]::Replace($Current.TrimStart("v"), '\d+', { param($m) $m.Value.PadLeft(12, '0') })
    return ([string]::CompareOrdinal($lk, $ck) -gt 0)
}

function Get-ExakitComponentCurrent {
    param([string]$Component)
    switch ($Component) {
        "exakit" {
            $src = Get-ExakitManifestValue "kit.source"
            if ($src -and $src.Contains("@")) { return ($src -split "@")[-1] }
            return "unknown"
        }
        "exapump" { return (Get-ExakitManifestValue "components.exapump.version") }
        "mcp" { return (Get-ExakitManifestValue "components.mcp_server.version") }
        "nano" {
            $image = Get-ExakitManifestValue "runtime.image"
            if ($image -and $image.Contains(":")) { return ($image -split ":")[-1] }
            return ""
        }
        "runtime" {
            if ((Get-RuntimeType) -eq "nano") { return (Get-ExakitComponentCurrent "nano") }
            if ((Get-RuntimeType) -eq "personal") { return (Get-ExakitComponentCurrent "personal") }
            return ""
        }
        "personal" {
            if ((Get-RuntimeType) -eq "personal") { return (Get-ExakitManifestValue "runtime.version") }
            return "not installed"
        }
    }
}

function Get-ExakitComponentLatest {
    param([string]$Component)
    switch ($Component) {
        "exakit" { return (Get-ExakitLatestGithubRelease $(if ($env:EXAKIT_KIT_REPO) { $env:EXAKIT_KIT_REPO } elseif ($env:EXAKIT_REPO) { $env:EXAKIT_REPO } else { "exasol-labs/exasol-personal-local-starterkit" })) }
        "exapump" { return (Get-ExakitLatestGithubRelease $script:ExapumpRepo) }
        "mcp" { return (Get-ExakitLatestPypiVersion $script:McpPackage) }
        "nano" { return (Get-ExakitLatestDockerTag) }
        "personal" { return (Get-ExakitLatestGithubRelease "exasol/exasol-personal") }
        "runtime" {
            if ((Get-RuntimeType) -eq "nano") { return (Get-ExakitComponentLatest "nano") }
            if ((Get-RuntimeType) -eq "personal") { return (Get-ExakitComponentLatest "personal") }
            return ""
        }
    }
}

function Invoke-CmdUpdateCheck {
    param([string]$Target = "all")
    if (-not (Test-Path $script:ManifestPath)) { Write-Host "Not installed (no manifest at $script:ManifestPath)"; return }
    $targets = Get-ExakitUpdateTargets -Target $Target
    Write-Host ""
    Write-Host "  Component update check"
    Write-Host "  ----------------------"
    "{0,-12} {1,-18} {2,-18} {3}" -f "Component", "Installed", "Latest", "Action" | Write-Host
    $updates = 0
    foreach ($component in $targets) {
        $actual = if ($component -eq "runtime" -and (Get-RuntimeType)) { Get-RuntimeType } else { $component }
        $current = Get-ExakitComponentCurrent $actual
        if (-not $current) { $current = "not installed" }
        $latest = Get-ExakitComponentLatest $actual
        if (-not $latest) { $latest = "unknown" }
        $action = "current"
        if ($latest -eq "unknown" -or $current -eq "unknown" -or $current -eq "not installed") {
            $action = "inspect"
        } elseif (Test-ExakitVersionNewer -Latest $latest -Current $current) {
            $action = "exakit update $component"
            $updates += 1
        }
        "{0,-12} {1,-18} {2,-18} {3}" -f $actual, $current, $latest, $action | Write-Host
    }
    Write-Host ""
    if ($updates -gt 1) { Info "Update everything with: exakit update all" }
}

function Invoke-CmdUpdate {
    param([string]$Target = "all")
    Assert-ExakitInstalled
    Initialize-ExakitLogging
    Invoke-CmdUpdateCheck -Target $Target
    foreach ($component in (Get-ExakitUpdateTargets -Target $Target)) {
        switch ($component) {
            "exakit" {
                Warn2 "Starter-kit self-update is not automated on the Windows PowerShell path yet. Re-run install.ps1 with the desired tag to refresh the kit scripts."
            }
            "runtime" {
                if ((Get-RuntimeType) -eq "nano") {
                    $latest = Get-ExakitComponentLatest "nano"
                    if ($latest) { Update-Nano -LatestTag $latest }
                }
            }
            "nano" {
                $latest = Get-ExakitComponentLatest "nano"
                if ($latest) { Update-Nano -LatestTag $latest }
            }
            "personal" {
                Warn2 "Exasol Personal local deployments are macOS-only in this kit. On Windows this target is reported for catalog parity but cannot be applied."
            }
            "exapump" {
                $latest = Get-ExakitComponentLatest "exapump"
                if ($latest) {
                    $script:ExapumpVersion = $latest
                    Remove-Item -Force (Get-ExapumpCli) -ErrorAction SilentlyContinue
                    Install-Exapump
                    New-ExapumpProfile
                    Set-ExakitManifestValue "desired.exapump" $script:ExapumpVersion
                }
            }
            "mcp" {
                $latest = Get-ExakitComponentLatest "mcp"
                if ($latest) {
                    New-McpUpdateSnapshot | Out-Null
                    $script:McpVersion = $latest
                    Install-Mcp
                    Test-McpServer
                    Warn2 "Run exakit mcp-setup to refresh AI client configs with the new MCP version."
                    Set-ExakitManifestValue "desired.mcp" $script:McpVersion
                }
            }
        }
    }
}

function Invoke-CmdLogs {
    $latest = Get-ChildItem -Path $script:LogDir -Filter "*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) { Write-Host $latest.FullName } else { Write-Host "No logs found in $script:LogDir" -ForegroundColor Red; exit 1 }
}

function Invoke-CmdDataLoad {
    param([string]$ForceFlag = "")
    Assert-ExakitInstalled
    if ($ForceFlag -and $ForceFlag -ne "-Force" -and $ForceFlag -ne "--force") {
        Fail "Unknown option '$ForceFlag' for data-load (only -Force/--force is supported)."
    }
    Initialize-ExakitLogging
    if ($ForceFlag) {
        $kitRoot = Get-ExakitRepoRoot
        if (-not $kitRoot) { Fail "Could not find the kit's sql/ and data/ files to load." }
        Info "Reloading the bundled sample dataset (log: $script:LogFile)"
        Invoke-ExakitSampleDataLoad -KitRoot $kitRoot -Force
    } else {
        Show-ExakitDataLoadMenu
    }
}

function Invoke-CmdMcpSetup {
    Assert-ExakitInstalled
    Initialize-ExakitLogging
    if (-not (Invoke-McpSetup)) { Fail "Could not complete MCP client setup" }
}

function Invoke-CmdMcpOperation {
    param([Parameter(Mandatory)][string]$Operation, [string[]]$OpArgs = @())
    Assert-ExakitInstalled
    Initialize-ExakitLogging
    if (-not (Invoke-McpOperation -Operation $Operation -InputArgs $OpArgs)) {
        Fail "Could not complete MCP $Operation"
    }
}

function Invoke-CmdMcpRestore {
    param([string]$SnapshotId = "")
    Assert-ExakitInstalled
    Initialize-ExakitLogging
    if (-not (Invoke-McpRestore -SnapshotId $SnapshotId)) { Fail "Could not restore managed MCP configuration" }
}

function Invoke-CmdCatalog {
    param([string]$Search = "")
    $catalogPath = Join-Path $libDir "catalog.tsv"
    if (-not (Test-Path $catalogPath)) { Fail "Catalog data not found: $catalogPath" }

    # Let the box-drawing / bullet glyphs render on the Windows console, which
    # defaults to a non-UTF-8 code page; restore the previous encoding after.
    $prevEnc = [Console]::OutputEncoding
    try {
        try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

        $q = $Search.ToLowerInvariant()
        $rule = "$([char]0x2501)" * 49   # heavy horizontal line

        Write-Host ""
        Write-Host "  $rule" -ForegroundColor Cyan
        Write-Host "   $([char]0x25B8) EXASOL" -ForegroundColor Cyan -NoNewline
        Write-Host "  $([char]0x00B7)  starter kit"
        if ($q) {
            Write-Host "     command catalog - results for `"$q`"" -ForegroundColor DarkGray
        } else {
            Write-Host "     command catalog $([char]0x00B7) exakit $([char]0x00B7) exapump $([char]0x00B7) exasol" -ForegroundColor DarkGray
        }
        Write-Host "  $rule" -ForegroundColor Cyan
        Write-Host ""

        $rows = Import-Csv -Path $catalogPath -Delimiter "`t"
        $labels = [ordered]@{
            exakit  = "exakit   - kit lifecycle & MCP management"
            exapump = "exapump  - data loading CLI"
            exasol  = "exasol   - database & AI (MCP) bridge"
        }
        $found = $false
        foreach ($tool in $labels.Keys) {
            $entries = @($rows | Where-Object {
                $_.tool -eq $tool -and (
                    -not $q -or "$($_.tool) $($_.command) $($_.options) $($_.description)".ToLowerInvariant().Contains($q)
                )
            })
            if ($entries.Count -eq 0) { continue }
            $found = $true
            Write-Host "  $($labels[$tool])" -ForegroundColor Green
            foreach ($e in $entries) {
                $name = if ($tool -eq "exasol") { $e.command } else { "$tool $($e.command)" }
                if ($e.options) {
                    Write-Host "    $name " -ForegroundColor White -NoNewline
                    Write-Host $e.options -ForegroundColor DarkGray
                } else {
                    Write-Host "    $name" -ForegroundColor White
                }
                Write-Host "        $($e.description)"
            }
            Write-Host ""
        }

        if (-not $found) {
            Write-Host "  No commands match `"$q`".  Try: exakit catalog mcp" -ForegroundColor DarkGray
            Write-Host ""
            return
        }
        Write-Host "  Tip: " -ForegroundColor DarkGray -NoNewline
        Write-Host "exakit catalog <search>   e.g. exakit catalog data $([char]0x00B7) exakit catalog mcp"
    } finally {
        try { [Console]::OutputEncoding = $prevEnc } catch { }
    }
}

function Invoke-CmdSkillsInstall {
    Initialize-ExakitLogging
    if (-not (Install-ExakitSkills)) { Fail "Could not install the kit's AI skills" }
}

function Show-ExakitUsage {
    param([switch]$All)
    # `exakit help --all` prints the full command reference: every leading
    # comment line (from line 2 on) up to the first non-comment line - avoids
    # a hard-coded line count going stale whenever the header comment above is
    # edited. Plain `exakit help` (and a bare `exakit`) prints only the short
    # everyday list, so a first-time user sees a handful of commands, not the
    # whole surface. Mirrors the bash usage() tiering.
    #
    # Uses a real `foreach` statement (not ForEach-Object): `break` inside a
    # ForEach-Object script block with no enclosing loop terminates the whole
    # calling scope, not just the loop.
    if ($All) {
        foreach ($line in (Get-Content $PSCommandPath | Select-Object -Skip 1)) {
            if (-not $line.StartsWith("#")) { break }
            Write-Host ($line -replace '^# ?', '')
        }
        return
    }
    @(
        "exakit - Exasol Personal Local Starter Kit"
        ""
        "Get started:"
        "  exakit mcp-setup     connect your AI assistant (Claude, Cursor, Codex)"
        ""
        "Everyday commands:"
        "  status               is the database up and healthy?"
        "  info                 show your connection details"
        "  start | stop         run or pause the local database"
        "  data-load            load the sample data or your own CSV / Parquet"
        "  mcp-doctor           check the AI (MCP) connection"
    ) | ForEach-Object { Write-Host $_ }
}

try {
    switch ($Command) {
        "preflight"    { Test-NanoRequirements }
        "status"       { Invoke-CmdStatus }
        "version"      { Invoke-CmdVersion }
        "--version"    { Invoke-CmdVersion }
        "-v"           { Invoke-CmdVersion }
        "update-check"  { Invoke-CmdUpdateCheck -Target ($RestArgs | Select-Object -First 1) }
        "update"        { Invoke-CmdUpdate -Target ($RestArgs | Select-Object -First 1) }
        "info"         { Show-ExakitConnectionPanel }
        "guide"        { Show-ExakitGuide }
        "start"        { Invoke-CmdStart }
        "stop"         { Invoke-CmdStop }
        "data-load"    { Invoke-CmdDataLoad -ForceFlag ($RestArgs | Select-Object -First 1) }
        "mcp-setup"    { Invoke-CmdMcpSetup }
        "mcp-repair"   { Invoke-CmdMcpOperation -Operation "repair" -OpArgs $RestArgs }
        "mcp-doctor"   { Invoke-CmdMcpOperation -Operation "doctor" -OpArgs $RestArgs }
        "mcp-status"   { Invoke-CmdMcpOperation -Operation "status" -OpArgs $RestArgs }
        "mcp-validate" { Invoke-CmdMcpOperation -Operation "validate" -OpArgs $RestArgs }
        "mcp-remove"   { Invoke-CmdMcpOperation -Operation "uninstall" -OpArgs $RestArgs }
        "mcp-restore"  { Invoke-CmdMcpRestore -SnapshotId ($RestArgs | Select-Object -First 1) }
        "skills-install" { Invoke-CmdSkillsInstall }
        "uninstall"    { Invoke-CmdUninstall -AssumeYes:($RestArgs -contains "-Yes" -or $RestArgs -contains "--yes" -or $RestArgs -contains "-y") -DryRun:($RestArgs -contains "-DryRun" -or $RestArgs -contains "--dry-run" -or $RestArgs -contains "-n") }
        "logs"         { Invoke-CmdLogs }
        "catalog"      { Invoke-CmdCatalog -Search ($RestArgs | Select-Object -First 1) }
        { $_ -in @("help", "-h", "--help") } { Show-ExakitUsage -All:($RestArgs -contains "--all" -or $RestArgs -contains "-a") }
        default {
            Write-Host "exakit: unknown command '$Command'" -ForegroundColor Red
            Show-ExakitUsage
            exit 2
        }
    }
} catch [ExakitFailException] {
    # Fail() already printed the error and the log path; just set the exit code.
    exit 1
} catch {
    Write-Host "  x Unexpected error: $_" -ForegroundColor Red
    exit 1
}
