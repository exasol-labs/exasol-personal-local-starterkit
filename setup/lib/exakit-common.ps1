# exakit-common.ps1 - shared helpers for the Exasol Personal Local Starter Kit
# (Windows / PowerShell path).
#
# Dot-sourced by setup-windows-docker.ps1 and setup/exakit.ps1. Not meant to
# be executed directly. Targets Windows PowerShell 5.1 (built into every
# Windows 10/11 machine) as well as PowerShell 7+ - no version-7-only syntax
# (no ternary, no null-coalescing, no -AsHashtable on ConvertFrom-Json).
#
# Mirrors setup/lib/common.sh function-for-function so the two platforms
# cannot drift apart in behavior. Where bash shells out to a Python one-liner
# for JSON, this file uses native PowerShell JSON handling instead.

$ErrorActionPreference = "Stop"

# Suppress the progress stream for the whole kit. Two reasons: (1) it removes
# the "TCP connect to ..."-style progress banners that cmdlets like
# Test-NetConnection / Invoke-WebRequest pin to the top of the console, which
# users found noisy; (2) on Windows PowerShell 5.1 a visible progress bar makes
# Invoke-WebRequest an order of magnitude slower, so silencing it speeds up
# every download step. Callers that genuinely want progress can override.
$ProgressPreference = "SilentlyContinue"

# ---------------------------------------------------------------------------
# Shared visual layer (banner, boxes, spinner, colour palette)
# ---------------------------------------------------------------------------
# ui.ps1 owns how the installer LOOKS (twin of setup/lib/ui.sh). Dot-source it
# first so Info/Ok/Begin-ExakitStep/Show-ExakitConnectionPanel below can use
# its palette and glyphs. If it is somehow absent, install no-op stubs and an
# empty palette so nothing here breaks.
try { . (Join-Path $PSScriptRoot "ui.ps1") } catch { }
if (-not (Get-Command Start-ExakitSpinner -ErrorAction SilentlyContinue)) {
    $script:UiFancy = $false
    foreach ($v in 'UiReset','UiBold','UiDim','UiAccent','UiOk','UiWarn','UiErr','UiInfo','UiAsk') {
        Set-Variable -Scope script -Name $v -Value ""
    }
    $script:UiTick = "+"; $script:UiCross = "x"; $script:UiArrow = ">"; $script:UiBullet = "-"; $script:UiVB = "|"
    $script:UiTee = "|-"; $script:UiCorner = '`-'
    function Start-ExakitSpinner([string]$Label) { }
    function Stop-ExakitSpinner { }
    function Restore-ExakitCursor { }
    function Get-ExakitTilde([string]$Path) { return $Path }
    function Write-ExakitBanner {
        param([string]$Title = "Exasol Personal Local Starter Kit", [string]$Subtitle = "")
        Write-Host ""; Write-Host "  $Title"; if ($Subtitle) { Write-Host "  $Subtitle" }; Write-Host ""
    }
    function Start-ExakitPanel([string]$Title) { Write-Host ""; Write-Host "  -- $Title --" }
    function Write-ExakitPanelLine([string]$Text) { Write-Host "   $Text" }
    function Complete-ExakitPanel { Write-Host "" }
}

# ---------------------------------------------------------------------------
# State locations
# ---------------------------------------------------------------------------
$script:ExakitHome   = if ($env:EXAKIT_HOME) { $env:EXAKIT_HOME } else { Join-Path $HOME ".exasol-starter-kit" }
$script:LogDir       = Join-Path $script:ExakitHome "logs"
$script:CredsDir     = Join-Path $script:ExakitHome "credentials"
$script:ManifestPath = Join-Path $script:ExakitHome "manifest.json"
$script:McpDir       = Join-Path $script:ExakitHome "mcp"
$script:BinDir       = if ($env:EXAKIT_BIN_DIR) { $env:EXAKIT_BIN_DIR } else { Join-Path $HOME ".local\bin" }
$script:ManagedPythonVersion = if ($env:EXAKIT_MANAGED_PYTHON_VERSION) { $env:EXAKIT_MANAGED_PYTHON_VERSION } else { "3.12" }
$script:McpReadonlyUser    = if ($env:EXAKIT_MCP_READONLY_USER) { $env:EXAKIT_MCP_READONLY_USER } else { "mcp_readonly" }
$script:McpReadonlySchemas = if ($env:EXAKIT_MCP_READONLY_SCHEMAS) { $env:EXAKIT_MCP_READONLY_SCHEMAS } else { "STARTER_KIT" }

# ---------------------------------------------------------------------------
# Component version policy
# ---------------------------------------------------------------------------
$script:VersionPolicy = if ($env:EXAKIT_VERSION_POLICY) { $env:EXAKIT_VERSION_POLICY } else { "latest" }
$script:NanoImage       = "exasol/nano"
$script:NanoTagFallback = if ($env:EXAKIT_NANO_TAG_FALLBACK) { $env:EXAKIT_NANO_TAG_FALLBACK } else { "2026.2.0-nano.2" }
$script:ExapumpVersionFallback = if ($env:EXAKIT_EXAPUMP_VERSION_FALLBACK) { $env:EXAKIT_EXAPUMP_VERSION_FALLBACK } else { "0.11.2" }
$script:McpVersionFallback = if ($env:EXAKIT_MCP_VERSION_FALLBACK) { $env:EXAKIT_MCP_VERSION_FALLBACK } else { "1.10.1" }
$script:NanoTag         = if ($env:EXAKIT_NANO_TAG) { $env:EXAKIT_NANO_TAG } else { "" }
$script:ExapumpVersion  = if ($env:EXAKIT_EXAPUMP_VERSION) { $env:EXAKIT_EXAPUMP_VERSION } else { "" }
$script:ExapumpRepo     = "exasol-labs/exapump"
$script:McpPackage      = if ($env:EXAKIT_MCP_PACKAGE) { $env:EXAKIT_MCP_PACKAGE } else { "exasol-mcp-server" }
$script:McpVersion      = if ($env:EXAKIT_MCP_VERSION) { $env:EXAKIT_MCP_VERSION } else { "" }
$script:PyexasolPackage = if ($env:EXAKIT_PYEXASOL_PACKAGE) { $env:EXAKIT_PYEXASOL_PACKAGE } else { "pyexasol" }
$script:PyexasolVersionFallback = if ($env:EXAKIT_PYEXASOL_VERSION_FALLBACK) { $env:EXAKIT_PYEXASOL_VERSION_FALLBACK } else { "2.2.2" }
$script:PyexasolVersion = if ($env:EXAKIT_PYEXASOL_VERSION) { $env:EXAKIT_PYEXASOL_VERSION } else { "" }
$script:DbPort          = if ($env:EXAKIT_DB_PORT) { $env:EXAKIT_DB_PORT } else { "8563" }

New-Item -ItemType Directory -Force -Path $script:ExakitHome, $script:LogDir, $script:CredsDir, $script:BinDir | Out-Null

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# One log file per process by default (mirrors bash's exakit_init_logging);
# callers that want a distinct log (load-data, exakit CLI) set $script:LogFile
# themselves before calling Initialize-ExakitLogging.
function Initialize-ExakitLogging {
    if (-not $script:LogFile) {
        $script:LogFile = Join-Path $script:LogDir ("install-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    }
    New-Item -ItemType File -Force -Path $script:LogFile | Out-Null
    try { Protect-ExakitFile $script:LogFile } catch { }
}

function Write-ExakitLog([string]$Level, [string]$Msg) {
    if (-not $script:LogFile) { return }
    try {
        "{0} {1,-5} {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Msg | Add-Content -Path $script:LogFile -ErrorAction Stop
    } catch {
        # The log directory can disappear mid-run - uninstall removes the kit
        # home (which contains logs/) while later status lines are still being
        # logged. Stop logging rather than surfacing a spurious "Unexpected
        # error" after the work has already succeeded.
        $script:LogFile = $null
    }
}
# Glyphs/colours come from the shared palette (ui.ps1) when a fancy terminal
# is available; otherwise fall back to Write-Host -ForegroundColor so basic
# colour still works even if ANSI/VT could not be enabled.
# One gutter under a step header: actions/results indent to the same column, so
# a step's children read as one group (mirrors ui.sh's info/ok/warn/error).
function Info([string]$Msg) {
    if ($script:UiFancy) { Write-Host ("    {0}{1}{2} {3}" -f $script:UiDim, $script:UiBullet, $script:UiReset, $Msg) }
    else { Write-Host ("    {0} {1}" -f $script:UiBullet, $Msg) }
    Write-ExakitLog "INFO" $Msg
}
function Ok([string]$Msg) {
    if ($script:UiFancy) { Write-Host ("      {0}{1}{2} {3}" -f $script:UiOk, $script:UiTick, $script:UiReset, $Msg) }
    else { Write-Host ("      {0} {1}" -f $script:UiTick, $Msg) -ForegroundColor Green }
    Write-ExakitLog "OK" $Msg
}
function Warn2([string]$Msg) {
    if ($script:UiFancy) { Write-Host ("      {0}!{1} {2}" -f $script:UiWarn, $script:UiReset, $Msg) }
    else { Write-Host "      ! $Msg" -ForegroundColor Yellow }
    Write-ExakitLog "WARN" $Msg
}
# Menu rendering (mirrors ui.sh's ui_menu_option/ui_menu_hint): options nest
# under the "Choose ..." action line with the number in the accent colour; the
# how-to-answer hint is a dim afterthought.
function Write-ExakitMenuOption([int]$Number, [string]$Label) {
    if ($script:UiFancy) { Write-Host ("      {0}{1}.{2} {3}" -f $script:UiAccent, $Number, $script:UiReset, $Label) }
    else { Write-Host ("      {0}. {1}" -f $Number, $Label) }
}
function Write-ExakitMenuHint([string]$Text) {
    if ($script:UiFancy) { Write-Host ("      {0}{1}{2}" -f $script:UiDim, $Text, $script:UiReset) }
    else { Write-Host ("      {0}" -f $Text) }
}
# Read-ExakitCheckboxMenu (mirrors ui.sh's ui_checkbox_menu): multi-select
# rendered as checkboxes with a movable cursor - Up/Down (or j/k) move, Space
# toggles the highlighted option, Enter confirms and moves to the next step
# ("a" selects all). At least one option must stay selected (Enter on an
# empty selection re-asks). In fancy mode the block redraws in place so
# toggling feels live. Non-interactive runs keep the defaults and say so.
# Returns the selected 1-based indices, ascending.
function Read-ExakitCheckboxMenu {
    param(
        [string]$Title, [string[]]$Options, [int[]]$Defaults = @(), [int]$ExclusiveIndex = 0,
        [int]$GroupParent = 0, [int]$GroupFirst = 0, [int]$GroupLast = 0
    )
    # $ExclusiveIndex (1-based, 0 = none): an option that cannot be combined
    # with the others - think "Skip for now". Selecting it clears every other
    # choice; selecting any other choice clears it.
    # $GroupParent/$GroupFirst/$GroupLast (optional): row $GroupParent is a
    # group checkbox whose children are rows $GroupFirst..$GroupLast. Toggling
    # the parent ON selects every child; OFF clears them all. Toggling a child
    # re-derives the parent (checked while ANY child is checked).
    Info $Title
    $sel = New-Object 'System.Collections.Generic.List[int]'
    foreach ($d in $Defaults) {
        if ($d -ge 1 -and $d -le $Options.Count -and -not $sel.Contains($d)) { [void]$sel.Add($d) }
    }
    $applyGroup = {
        param($toggled)
        if ($GroupParent -lt 1) { return }
        if ($toggled -eq $GroupParent) {
            $parentOn = $sel.Contains($GroupParent)
            for ($c = $GroupFirst; $c -le $GroupLast; $c++) {
                if ($parentOn) { if (-not $sel.Contains($c)) { [void]$sel.Add($c) } }
                else { [void]$sel.Remove($c) }
            }
        } elseif ($toggled -ge $GroupFirst -and $toggled -le $GroupLast) {
            $any = $false
            for ($c = $GroupFirst; $c -le $GroupLast; $c++) { if ($sel.Contains($c)) { $any = $true; break } }
            if ($any) { if (-not $sel.Contains($GroupParent)) { [void]$sel.Add($GroupParent) } }
            else { [void]$sel.Remove($GroupParent) }
        }
    }
    $applyExclusive = {
        param($toggled)
        if ($ExclusiveIndex -lt 1) { return }
        if ($toggled -eq $ExclusiveIndex) {
            if ($sel.Contains($ExclusiveIndex)) { $sel.Clear(); [void]$sel.Add($ExclusiveIndex) }
        } elseif ($sel.Contains($ExclusiveIndex)) {
            [void]$sel.Remove($ExclusiveIndex)
        }
    }
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        foreach ($i in @($sel | Sort-Object)) { Ok ("{0} (selected by default)" -f $Options[$i - 1]) }
        return @($sel | Sort-Object)
    }
    # A label starting with "#" is a GROUP HEADER: rendered as a plain caption
    # (no checkbox), never selectable, and skipped by the cursor.
    # A label starting with "!" is a DISABLED row: rendered as a dimmed,
    # unchecked checkbox (the label should say why - e.g. "not installed"),
    # never selectable, skipped by the cursor, and excluded from "a".
    $isHeader = { param($i) $Options[$i - 1].StartsWith("#") }
    $isDisabled = { param($i) $Options[$i - 1].StartsWith("!") }
    $step = {
        param($dir)
        for ($s = 0; $s -lt $Options.Count; $s++) {
            $script:cbCur += $dir
            if ($script:cbCur -lt 1) { $script:cbCur = $Options.Count }
            if ($script:cbCur -gt $Options.Count) { $script:cbCur = 1 }
            if (-not (& $isHeader $script:cbCur) -and -not (& $isDisabled $script:cbCur)) { return }
        }
    }
    $script:cbCur = 0
    & $step 1
    $firstDraw = $true
    while ($true) {
        if (-not $firstDraw -and $script:UiFancy) {
            # redraw the block in place: options + hint line
            Write-Host ("{0}[{1}A{0}[0J" -f $script:UiEsc, ($Options.Count + 1)) -NoNewline
        }
        $firstDraw = $false
        for ($i = 1; $i -le $Options.Count; $i++) {
            if (& $isHeader $i) {
                Write-Host ("    {0}" -f $Options[$i - 1].Substring(1)) -ForegroundColor Cyan
                continue
            }
            if (& $isDisabled $i) {
                if ($script:UiFancy) { Write-Host ("      {0}[ ] {1}{2}" -f $script:UiDim, $Options[$i - 1].Substring(1), $script:UiReset) }
                else { Write-Host ("      [ ] {0}" -f $Options[$i - 1].Substring(1)) }
                continue
            }
            $ptr = if ($i -eq $script:cbCur) { ">" } else { " " }
            if ($sel.Contains($i)) {
                if ($script:UiFancy) { Write-Host ("    {0} {1}[{2}]{3} {4}" -f $ptr, $script:UiOk, $script:UiTick, $script:UiReset, $Options[$i - 1]) }
                else { Write-Host ("    {0} [x] {1}" -f $ptr, $Options[$i - 1]) }
            } else {
                Write-Host ("    {0} [ ] {1}" -f $ptr, $Options[$i - 1])
            }
        }
        Write-ExakitMenuHint "Up/Down to move - Space to toggle - Enter to confirm"
        $key = [Console]::ReadKey($true)
        $handled = $true
        switch ($key.Key) {
            "Enter"     { if ($sel.Count -gt 0) { return @($sel | Sort-Object) } }
            "Spacebar"  {
                if ($sel.Contains($script:cbCur)) { [void]$sel.Remove($script:cbCur) } else { [void]$sel.Add($script:cbCur) }
                & $applyGroup $script:cbCur
                & $applyExclusive $script:cbCur
            }
            "UpArrow"   { & $step -1 }
            "DownArrow" { & $step 1 }
            default     { $handled = $false }
        }
        if ($handled) { continue }
        switch -Regex ([string]$key.KeyChar) {
            '^[kK]$' { & $step -1 }
            '^[jJ]$' { & $step 1 }
            '^[aA]$' {
                # "all" means all real choices: never headers, never disabled
                # rows, never the exclusive option.
                $sel.Clear()
                for ($i = 1; $i -le $Options.Count; $i++) {
                    if ($i -ne $ExclusiveIndex -and -not (& $isHeader $i) -and -not (& $isDisabled $i)) { [void]$sel.Add($i) }
                }
            }
        }
    }
}
# Show-ExakitNoAiPanel - shown when the user skips MCP client setup: the
# database is still fully usable without an AI assistant, and this says how.
function Show-ExakitNoAiPanel {
    $dsn = Get-ExakitManifestValue "runtime.dsn"
    $hostName = "127.0.0.1"; $port = "8563"
    if ($dsn -match '^(.+):(\d+)$') { $hostName = $Matches[1]; $port = $Matches[2] }
    Write-Host ""
    Start-ExakitPanel "Using your database without an AI client"
    Write-ExakitPanelLine "Your database works great on its own - three easy ways in:"
    Write-ExakitPanelLine "GUI client:  DBeaver (recommended) - https://dbeaver.io/download/"
    Write-ExakitPanelLine "             New Connection > Exasol > Host $hostName Port $port"
    Write-ExakitPanelLine "Python:      pyexasol is preinstalled in its own environment:"
    Write-ExakitPanelLine "             $(Get-ExakitTilde (Join-Path $script:ExakitHome 'pyexasol-venv'))"
    Write-ExakitPanelLine "Terminal:    exapump interactive -p starter-kit   (SQL shell)"
    Write-ExakitPanelLine "Step-by-step (credentials, TLS setting, first query):  exakit guide"
    Write-ExakitPanelLine "Changed your mind about AI? Any time:  exakit mcp-setup"
    Complete-ExakitPanel
    Write-Host ""
}

# Show-ExakitGuide - friendly how-to-connect walkthrough (mirrors exakit_guide
# in common.sh): AI clients over MCP, GUI SQL clients (DBeaver), and Python.
function Show-ExakitGuide {
    if (-not (Test-Path $script:ManifestPath)) { Warn2 "No installation found. Run the installer first."; return }
    $dsn = Get-ExakitManifestValue "runtime.dsn"
    $hostName = "127.0.0.1"; $port = "8563"
    if ($dsn -match '^(.+):(\d+)$') { $hostName = $Matches[1]; $port = $Matches[2] }
    $user = Get-ExakitManifestValue "runtime.user"; if (-not $user) { $user = "sys" }
    $pwfile = Get-ExakitManifestValue "runtime.password_file"
    $mcpUser = Get-ExakitManifestValue "components.mcp_server.connection.user"

    Write-ExakitBanner "How to connect" "AI clients, SQL clients, Python - pick your door"

    Start-ExakitPanel "1 - Ask questions with an AI client (MCP)"
    Write-ExakitPanelLine "Connect one or more AI clients in a single guided step:"
    Write-ExakitPanelLine "  exakit mcp-setup"
    Write-ExakitPanelLine "Supported: Claude, Claude Code, Codex, Cursor, GitHub Copilot, Gemini CLI, OpenCode, Continue"
    Write-ExakitPanelLine "Then restart/reload the client and look for the MCP server 'exasol'."
    Write-ExakitPanelLine "First thing to ask it:"
    Write-ExakitPanelLine "  'List the schemas and tables in my Exasol database, then answer my"
    Write-ExakitPanelLine "   questions with read-only SQL - show me the SQL before you run it.'"
    Write-ExakitPanelLine "14 ready-made questions: data\example-questions.md (in the kit)"
    Complete-ExakitPanel

    Start-ExakitPanel "2 - Browse and query with a SQL client (GUI)"
    Write-ExakitPanelLine "DBeaver (recommended, free): https://dbeaver.io/download/"
    Write-ExakitPanelLine "In DBeaver: Database > New Database Connection > search 'Exasol'"
    Write-ExakitPanelLine "  Host:      $hostName"
    Write-ExakitPanelLine "  Port:      $port"
    Write-ExakitPanelLine "  User:      $user"
    if ($pwfile) { Write-ExakitPanelLine "  Password:  Get-Content $(Get-ExakitTilde $pwfile)" }
    if ($mcpUser) { Write-ExakitPanelLine "  (read-only alternative: user $mcpUser)" }
    Write-ExakitPanelLine "  TLS:       local self-signed certificate - in Driver properties set"
    Write-ExakitPanelLine "             validateservercertificate = 0, then Test Connection > Finish."
    Write-ExakitPanelLine "Each bundled dataset has its own schema (TPCH, ENERGY, WEATHER);"
    Write-ExakitPanelLine "your own uploads default to STARTER_KIT."
    Complete-ExakitPanel

    Start-ExakitPanel "3 - Terminal and Python"
    Write-ExakitPanelLine "Interactive SQL shell:   exapump interactive -p starter-kit"
    Write-ExakitPanelLine "One-off query:           exapump sql -p starter-kit 'SELECT 42'"
    Write-ExakitPanelLine "Python (pyexasol preinstalled in its own environment):"
    Write-ExakitPanelLine "  $(Get-ExakitTilde (Join-Path $script:ExakitHome 'pyexasol-venv'))"
    Complete-ExakitPanel

    Start-ExakitPanel "Everything else"
    Write-ExakitPanelLine "Connection summary:   exakit info"
    Write-ExakitPanelLine "Load more data:       exakit data-load"
    Write-ExakitPanelLine "Health check:         exakit status - exakit mcp-doctor"
    Complete-ExakitPanel
    Write-Host ""
}

# ExakitFailException - a distinct exception type so callers can tell a
# deliberate Fail() apart from an unexpected error. Bash's die() only halts
# the current subshell (kit_shared_steps runs risky steps in one so a
# failure there cannot abort the whole install); PowerShell's `exit` has no
# such boundary within a single process, so Fail() throws instead. Top-level
# entry points (setup-windows-docker.ps1, exakit.ps1) catch it there and
# exit 1; interactive offers catch it locally and continue with a warning,
# matching bash's `|| true` pattern around exakit_maybe_offer_*.
class ExakitFailException : System.Exception {
    ExakitFailException([string]$Msg) : base($Msg) {}
}

function Fail([string]$Msg) {
    Stop-ExakitSpinner
    Restore-ExakitCursor
    # Rendered as a small "card": prominent cross header, then a dim gutter
    # line to the log - the same shape as ui.sh's die().
    Write-Host ""
    if ($script:UiFancy) {
        Write-Host ("  {0}{1} {2}{3}{4}" -f $script:UiErr, $script:UiCross, $script:UiBold, $Msg, $script:UiReset)
        if ($script:LogFile) { Write-Host ("    {0}{1} Log: {2}{3}" -f $script:UiDim, $script:UiVB, $script:LogFile, $script:UiReset) }
    } else {
        Write-Host ("  {0} {1}" -f $script:UiCross, $Msg) -ForegroundColor Red
        if ($script:LogFile) { Write-Host ("    | Log: {0}" -f $script:LogFile) }
    }
    Write-ExakitLog "FATAL" $Msg
    throw [ExakitFailException]::new($Msg)
}

# Run a command, sending its output to the log file only. $Cmd is invoked via
# the call operator; args come from $Args (positional after $Cmd).
#
# A native command that writes to stderr can, under $ErrorActionPreference =
# 'Stop' (set globally by every entry point), surface as an uncaught
# terminating exception instead of just a non-zero exit code - this is a
# real, well-documented PowerShell quirk (worse on Windows PowerShell 5.1
# than on 7+) and is exactly what happened when Docker Desktop wasn't
# running: the friendly "Docker is installed but not running" message never
# ran because the underlying `docker info` call threw past it. Every caller
# of this function already checks the *returned exit code* and calls Fail()
# itself with a proper message, so any exception here is converted to a
# synthetic non-zero code instead of being allowed to escape - Fail() still
# happens, just from the caller, with the message it was meant to show.
function Invoke-ExakitLogged {
    param([Parameter(Mandatory)][string]$Cmd, [Parameter(ValueFromRemainingArguments)]$CmdArgs)
    Write-ExakitLog "CMD" "$Cmd $($CmdArgs -join ' ')"
    $previousErrorActionPreference = $ErrorActionPreference
    # Animate a spinner (in a background runspace) while the command runs. Its
    # output goes to the log, not the console, so the spinner is the only
    # console writer during the spin. The command execution below is unchanged.
    $spinLabel = if ($script:ExakitActiveLabel) { $script:ExakitActiveLabel } else { "working" }
    Start-ExakitSpinner $spinLabel
    try {
        # Native tools such as uvx and Docker can write progress/status to
        # stderr while still succeeding. With ErrorActionPreference = Stop,
        # Windows PowerShell can turn that stderr into a terminating error
        # before we can inspect the real process exit code.
        $ErrorActionPreference = "Continue"
        if ($script:LogFile) {
            & $Cmd @CmdArgs *>> $script:LogFile
        } else {
            & $Cmd @CmdArgs | Out-Null
        }
        return $LASTEXITCODE
    } catch {
        Write-ExakitLog "ERROR" "$Cmd threw instead of returning an exit code: $_"
        return 1
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
        Stop-ExakitSpinner
    }
}
# Confirm-ExakitPrompt "Question?" [DefaultYes] - non-interactive runs
# (no console input available, e.g. piped install) take the default.
function Confirm-ExakitPrompt {
    param([string]$Question, [bool]$DefaultYes = $true)
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        return $DefaultYes
    }
    $hint = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    if ($script:UiFancy) {
        Write-Host ("    {0}?{1} {2} {3}{4}{5} " -f $script:UiAsk, $script:UiReset, $Question, $script:UiDim, $hint, $script:UiReset) -NoNewline
    } else {
        Write-Host "    ? $Question $hint " -ForegroundColor Cyan -NoNewline
    }
    $answer = Read-Host
    if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultYes }
    return $answer -match '^(y|yes)$'
}

# Read-ExakitPrompt "Question" ["default"] - non-interactive runs return the
# default immediately (mirrors bash's prompt_text over /dev/tty).
function Read-ExakitPrompt {
    param([string]$Question, [string]$Default = "")
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        return $Default
    }
    if ($script:UiFancy) {
        if ($Default) {
            Write-Host ("    {0}?{1} {2} {3}[{4}]{5} " -f $script:UiAsk, $script:UiReset, $Question, $script:UiDim, $Default, $script:UiReset) -NoNewline
        } else {
            Write-Host ("    {0}?{1} {2} " -f $script:UiAsk, $script:UiReset, $Question) -NoNewline
        }
    } elseif ($Default) {
        Write-Host "    ? $Question [$Default] " -ForegroundColor Cyan -NoNewline
    } else {
        Write-Host "    ? $Question " -ForegroundColor Cyan -NoNewline
    }
    $answer = Read-Host
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer
}

# Test-ExakitPortInUse <port> [host] - fast, quiet "is this TCP port already
# accepting connections?" check. Replaces Test-NetConnection, which is slow
# (it also does ICMP/traceroute work) and pins a "TCP connect to ..." progress
# banner to the top of the console. A raw TcpClient with a short timeout is
# sub-second and silent. Returns $true only if something is listening.
function Test-ExakitPortInUse {
    param([Parameter(Mandatory)][int]$Port, [string]$ComputerName = "127.0.0.1", [int]$TimeoutMs = 700)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# ---------------------------------------------------------------------------
# Python / uv (mirrors require_python3 / run_python: prefer a system python,
# fall back to a uv-managed one so the kit never hard-requires a system
# Python install)
# ---------------------------------------------------------------------------
function Test-ExakitSystemPython {
    if ($env:EXAKIT_DISABLE_SYSTEM_PYTHON -eq "1") { return $false }
    return [bool](Get-Command python -ErrorAction SilentlyContinue)
}

function Get-ExakitUvBin {
    if ($script:UvBin -and (Test-Path $script:UvBin)) { return $script:UvBin }
    $cmd = Get-Command uv -ErrorAction SilentlyContinue
    if ($cmd) { $script:UvBin = $cmd.Source; return $script:UvBin }
    $candidate = Join-Path $script:BinDir "uv.exe"
    if (Test-Path $candidate) { $script:UvBin = $candidate; return $script:UvBin }
    $candidate = Join-Path $HOME ".local\bin\uv.exe"
    if (Test-Path $candidate) { $script:UvBin = $candidate; return $script:UvBin }
    return $null
}

function Install-ExakitUv {
    $existing = Get-ExakitUvBin
    if ($existing) { return $existing }
    Info "Installing the managed Python bootstrapper (uv)"
    try {
        $env:UV_NO_MODIFY_PATH = "1"
        $env:INSTALLER_NO_MODIFY_PATH = "1"
        # HARDENING (eval-report): this fetches and executes the uv installer
        # unpinned/unverified, unlike the kit's checksum-verified artifacts.
        # Pin/verify to match the bash twin's chosen approach (keep both sides
        # identical). Behavior intentionally unchanged here pending that fix.
        Invoke-Expression (Invoke-RestMethod -Uri "https://astral.sh/uv/install.ps1") *>> $script:LogFile
    } catch {
        Fail "uv installation failed (see log): $_"
    }
    $bin = Get-ExakitUvBin
    if (-not $bin) {
        $candidate = Join-Path $HOME ".local\bin\uv.exe"
        if (Test-Path $candidate) { $bin = $candidate; $script:UvBin = $bin }
    }
    if (-not $bin) { Fail "uv installed but its binary was not found in $HOME\.local\bin." }
    Ok "uv installed at $bin"
    return $bin
}

function Assert-ExakitPython {
    if (Test-ExakitSystemPython) { return }
    if (-not (Install-ExakitUv)) { Fail "A Python runtime is required, and the automatic uv bootstrap failed." }
}

# Invoke-ExakitPython <script-text> <args...> - runs Python via the system
# interpreter if present, otherwise via a uv-managed one. Returns stdout as a
# single string; throws on a non-zero exit so callers can Fail() with context.
function Invoke-ExakitPython {
    param([Parameter(Mandatory)][string]$Script, [Parameter(ValueFromRemainingArguments)]$PyArgs)
    $tmp = [System.IO.Path]::GetTempFileName() + ".py"
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        Set-Content -Path $tmp -Value $Script -Encoding UTF8
        # Under the module-global $ErrorActionPreference = 'Stop', 2>&1 turns
        # the interpreter's FIRST stderr write into a terminating error that
        # tears the pipeline down - killing Python mid-run and surfacing only
        # that first line instead of the intended "Python exited with code N"
        # diagnostic. A script that merely warns on stderr while succeeding
        # would abort the caller outright. 'Continue' captures the full
        # output; the exit-code check below stays the real failure signal.
        # Same fix as Invoke-Exapump / Invoke-ExakitLogged.
        $ErrorActionPreference = "Continue"
        if (Test-ExakitSystemPython) {
            $out = & python $tmp @PyArgs 2>&1
        } else {
            $uv = Install-ExakitUv
            $out = & $uv run --python $script:ManagedPythonVersion --no-project python $tmp @PyArgs 2>&1
        }
        $code = $LASTEXITCODE
        $ErrorActionPreference = $previousErrorActionPreference
        if ($code -ne 0) { throw "Python exited with code ${code}: $out" }
        return ($out -join "`n")
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
        Remove-Item -Force $tmp -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Manifest (native PowerShell JSON, no Python dependency for read/write)
# ---------------------------------------------------------------------------
function Initialize-ExakitManifest {
    if (Test-Path $script:ManifestPath) {
        try {
            Get-Content $script:ManifestPath -Raw | ConvertFrom-Json | Out-Null
            return
        } catch {
            Warn2 "The install manifest is corrupted (interrupted run?) - rebuilding it; existing components will be re-detected"
            Move-Item -Force $script:ManifestPath "$script:ManifestPath.corrupt-$(Get-Date -Format 'yyyyMMddHHmmss')"
        }
    }
    $doc = [pscustomobject]@{
        manifest_version = 1
        kit_level        = 1
        installed_at     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        os               = "windows"
        arch             = $env:PROCESSOR_ARCHITECTURE
        runtime          = [pscustomobject]@{}
        components       = [pscustomobject]@{}
        data             = [pscustomobject]@{ loaded = $false }
        steps_completed  = @()
        log_dir          = $script:LogDir
    }
    Save-ExakitManifest $doc
}

function Read-ExakitManifest {
    if (-not (Test-Path $script:ManifestPath)) { return $null }
    return (Get-Content $script:ManifestPath -Raw | ConvertFrom-Json)
}

# Atomic write: an interrupted run must never leave a truncated manifest.
function Save-ExakitManifest($Manifest) {
    $tmp = "$script:ManifestPath.tmp"
    $Manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $tmp
    Move-Item -Force $tmp $script:ManifestPath
    try { Protect-ExakitFile $script:ManifestPath } catch { }
}

function Get-ManifestValue {
    param($Manifest, [Parameter(Mandatory)][string]$Path)
    $node = $Manifest
    foreach ($part in ($Path -split '\.')) {
        if ($null -eq $node) { return $null }
        $prop = $node.PSObject.Properties[$part]
        if ($null -eq $prop) { return $null }
        $node = $prop.Value
    }
    return $node
}

function Set-ManifestValue {
    param($Manifest, [Parameter(Mandatory)][string]$Path, $Value)
    $parts = $Path -split '\.'
    $node = $Manifest
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $part = $parts[$i]
        $prop = $node.PSObject.Properties[$part]
        if ($null -eq $prop -or $null -eq $prop.Value) {
            $child = [pscustomobject]@{}
            $node | Add-Member -NotePropertyName $part -NotePropertyValue $child -Force
            $node = $child
        } else {
            $node = $prop.Value
        }
    }
    $node | Add-Member -NotePropertyName $parts[-1] -NotePropertyValue $Value -Force
}

# manifest_get equivalent: reads from disk fresh every call, like bash.
function Get-ExakitManifestValue {
    param([Parameter(Mandatory)][string]$Path)
    $doc = Read-ExakitManifest
    if ($null -eq $doc) { return $null }
    return (Get-ManifestValue -Manifest $doc -Path $Path)
}

# manifest_set equivalent: reads, mutates, writes atomically, every call.
function Set-ExakitManifestValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $doc = Read-ExakitManifest
    if ($null -eq $doc) { Fail "Failed to update manifest ($Path): no manifest at $script:ManifestPath" }
    Set-ManifestValue -Manifest $doc -Path $Path -Value $Value
    Save-ExakitManifest $doc
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

# Return the docker image arch token for THIS machine: "amd64" or "arm64".
# Prefer the true hardware arch (WMI) so an x64-emulated PowerShell on an ARM
# device is not misread as amd64; fall back to the environment.
function Get-ExakitHostArch {
    try {
        $a = (Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1).Architecture
        if ($a -eq 12 -or $a -eq 5) { return "arm64" }
        if ($a -eq 9 -or $a -eq 0) { return "amd64" }
    } catch { }
    $p = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    if ($p -match 'ARM') { return "arm64" }
    return "amd64"
}

function Get-ExakitLatestDockerTag {
    try {
        $doc = Invoke-RestMethod -Uri "https://hub.docker.com/v2/repositories/$($script:NanoImage)/tags?page_size=100&ordering=last_updated" -UseBasicParsing -TimeoutSec 12
        # Keep the plain (multi-arch) tags plus this host's own arch, and drop
        # the other architecture's suffixed tags - otherwise the sort lands on
        # -arm64 (it sorts after -amd64) and an x86_64 host would pull an arm64
        # image that only runs under slow emulation.
        $arch = Get-ExakitHostArch
        if ($arch -eq "arm64") { $wrong = @("amd64", "x86_64", "x86-64") } else { $wrong = @("arm64", "aarch64") }
        $candidates = @($doc.results | ForEach-Object { $_.name } | Where-Object {
            ($_ -match '^\d+(\.\d+)+[-._A-Za-z0-9]*$') -and ($_ -notmatch 'latest') -and
            (-not (($_.ToLower() -split '[-._]') | Where-Object { $wrong -contains $_ }))
        })
        if ($candidates.Count -eq 0) { return "" }
        return ($candidates | Sort-Object { [regex]::Replace($_, '\d+', { param($m) $m.Value.PadLeft(12, '0') }) } | Select-Object -Last 1)
    } catch { return "" }
}

function Set-ExakitDesiredVersions {
    Set-ExakitManifestValue "version_policy" $script:VersionPolicy
    Set-ExakitManifestValue "desired.runtime.nano" $script:NanoTag
    Set-ExakitManifestValue "desired.exapump" $script:ExapumpVersion
    Set-ExakitManifestValue "desired.mcp" $script:McpVersion
    Set-ExakitManifestValue "desired.pyexasol" $script:PyexasolVersion
}

function Resolve-ExakitInstallVersions {
    if ($script:VersionPolicy -ne "latest") {
        if (-not $script:NanoTag) { $script:NanoTag = $script:NanoTagFallback }
        if (-not $script:ExapumpVersion) { $script:ExapumpVersion = $script:ExapumpVersionFallback }
        if (-not $script:McpVersion) { $script:McpVersion = $script:McpVersionFallback }
        if (-not $script:PyexasolVersion) { $script:PyexasolVersion = $script:PyexasolVersionFallback }
        Set-ExakitDesiredVersions
        return
    }

    if (-not $script:NanoTag) {
        $script:NanoTag = Get-ExakitLatestDockerTag
        if (-not $script:NanoTag) { $script:NanoTag = $script:NanoTagFallback }
    }
    if (-not $script:ExapumpVersion) {
        $script:ExapumpVersion = Get-ExakitLatestGithubRelease $script:ExapumpRepo
        if (-not $script:ExapumpVersion) { $script:ExapumpVersion = $script:ExapumpVersionFallback }
    }
    if (-not $script:McpVersion) {
        $script:McpVersion = Get-ExakitLatestPypiVersion $script:McpPackage
        if (-not $script:McpVersion) { $script:McpVersion = $script:McpVersionFallback }
    }
    if (-not $script:PyexasolVersion) {
        $script:PyexasolVersion = Get-ExakitLatestPypiVersion $script:PyexasolPackage
        if (-not $script:PyexasolVersion) { $script:PyexasolVersion = $script:PyexasolVersionFallback }
    }
    Set-ExakitDesiredVersions
}

function Test-ExakitStepDone {
    param([Parameter(Mandatory)][string]$Step)
    $doc = Read-ExakitManifest
    if ($null -eq $doc) { return $false }
    $steps = Get-ManifestValue -Manifest $doc -Path "steps_completed"
    if ($null -eq $steps) { return $false }
    return ([array]$steps) -contains $Step
}

# mark_step equivalent (idempotent; does not touch a rollback stack - Windows
# path has no equivalent to bash's rollback registration).
function Set-ExakitStepDone {
    param([Parameter(Mandatory)][string]$Step)
    $doc = Read-ExakitManifest
    if ($null -eq $doc) { Fail "Failed to record step ${Step}: no manifest at $script:ManifestPath" }
    $steps = Get-ManifestValue -Manifest $doc -Path "steps_completed"
    $steps = [array]$steps
    if ($steps -notcontains $Step) { $steps += $Step }
    Set-ManifestValue -Manifest $doc -Path "steps_completed" -Value $steps
    Save-ExakitManifest $doc
    Write-ExakitLog "STEP" "completed: $Step"
}

# Begin-ExakitStep <name> <description> - announces a step, returns $false
# (caller should skip) if already done.
function Begin-ExakitStep {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Description)
    $script:ExakitActiveLabel = $Description   # spinner label for Invoke-ExakitLogged in this step
    if (Test-ExakitStepDone $Name) {
        Ok "$Description - already done, skipping"
        return $false
    }
    Write-Host ""
    if ($script:UiFancy) {
        Write-Host ("  {0}{1}{2} {3}{4}{5}" -f $script:UiAccent, $script:UiArrow, $script:UiReset, $script:UiBold, $Description, $script:UiReset)
    } else {
        Write-Host ("  {0} {1}" -f $script:UiArrow, $Description) -ForegroundColor Blue
    }
    Write-ExakitLog "STEP" $Description
    return $true
}

# ---------------------------------------------------------------------------
# Downloads and verification
# ---------------------------------------------------------------------------
function Get-ExakitFile {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Dest)
    New-Item -ItemType Directory -Force -Path (Split-Path $Dest -Parent) | Out-Null
    Write-ExakitLog "GET" "$Url -> $Dest"
    # Retry transient failures, mirroring the bash side's curl --retry 3
    # --connect-timeout policy: one network blip must not abort the install.
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 120
            break
        } catch {
            Remove-Item -Force $Dest -ErrorAction SilentlyContinue
            if ($attempt -ge 3) {
                Fail "Download failed after $attempt attempts: $Url ($_)"
            }
            Warn2 "Download attempt $attempt failed - retrying in $(5 * $attempt)s"
            Start-Sleep -Seconds (5 * $attempt)
        }
    }
}

function Get-ExakitSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function ConvertTo-UpperInvariantString {
    param([Parameter(Mandatory)]$Value)
    return ([string]$Value).ToUpperInvariant()
}

function Test-ExakitSha256 {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Expected)
    $actual = Get-ExakitSha256 $Path
    if ($actual -ne $Expected.ToLowerInvariant()) {
        Write-Host ("      {0}{1}{2} Checksum mismatch for {3}" -f $script:UiErr, $script:UiCross, $script:UiReset, (Split-Path $Path -Leaf))
        Write-Host ("      {0}{1} expected: {2}{3}" -f $script:UiDim, $script:UiVB, $Expected, $script:UiReset)
        Write-Host ("      {0}{1} actual:   {2}{3}" -f $script:UiDim, $script:UiVB, $actual, $script:UiReset)
        Fail "Refusing to continue with an unverified artifact"
    }
    Ok "Checksum verified: $(Split-Path $Path -Leaf)"
}

# ---------------------------------------------------------------------------
# Credentials (NTFS ACL is the Windows equivalent of chmod 600: strip
# inherited permissions and grant only the current user).
# ---------------------------------------------------------------------------
function Protect-ExakitFile {
    param([Parameter(Mandatory)][string]$Path)
    # ACL APIs are Windows-only; this script only ships for the Windows path,
    # but the guard keeps it from throwing under cross-platform PowerShell 7
    # (e.g. running this file's tests on macOS/Linux during development).
    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) { return }
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().User,
        "FullControl", "Allow")
    $acl.AddAccessRule($rule)
    Set-Acl -Path $Path -AclObject $acl
}

function New-ExakitPassword {
    $chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".ToCharArray()
    $bytes = New-Object byte[] 24
    # RandomNumberGenerator's static Fill() is .NET 6+/Core-only. Windows
    # PowerShell 5.1 runs on .NET Framework, which only has the classic
    # instance-based Create()+GetBytes() API - use that instead so this
    # works on both.
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

# Written atomically (temp file + rename) so an interrupted run can never
# leave a truncated secret.
function Set-ExakitCredential {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Value)
    New-Item -ItemType Directory -Force -Path $script:CredsDir | Out-Null
    $target = Join-Path $script:CredsDir $Name
    $tmp = "$target.tmp"
    [System.IO.File]::WriteAllText($tmp, $Value)
    Protect-ExakitFile $tmp
    Move-Item -Force $tmp $target
}

function Get-ExakitCredential {
    param([Parameter(Mandatory)][string]$Name)
    $path = Join-Path $script:CredsDir $Name
    if (-not (Test-Path $path)) { return "" }
    return (Get-Content $path -Raw -ErrorAction SilentlyContinue)
}

# Copy-ExakitAsset - copy a file or directory to $Destination, but skip the
# copy entirely when the source already IS the destination. The Windows
# installer (install.ps1) downloads the kit straight into
# ~\.exasol-starter-kit\kit and runs setup from there, so the "keep a copy of
# the kit next to the state" step would otherwise try to copy a directory
# onto itself and crash ("Cannot overwrite the item ... with itself"). When
# the paths differ (a standalone checkout elsewhere), any stale destination
# is removed first so a re-run can't produce a nested lib\lib copy.
function Copy-ExakitAsset {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    if (-not (Test-Path $Source)) { return }
    $srcFull = (Resolve-Path $Source).Path.TrimEnd('\', '/')
    $dstFull = $Destination.TrimEnd('\', '/')
    if (Test-Path $Destination) { $dstFull = (Resolve-Path $Destination).Path.TrimEnd('\', '/') }
    if ([string]::Equals($srcFull, $dstFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return  # already in place (installer ran from the kit copy itself)
    }
    if (Test-Path $Destination) { Remove-Item -Recurse -Force $Destination }
    Copy-Item -Recurse -Force $Source $Destination
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
function Ensure-ExakitOnPath {
    param([Parameter(Mandatory)][string]$Dir)
    $path = $env:Path -split ";"
    if ($path -notcontains $Dir) {
        # Update current session
        $env:Path = "$Dir;$env:Path"
        # Update permanent user-level environment variable
        $userPath = [System.Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::User)
        if ($userPath -notlike "$Dir;*" -and $userPath -notlike "*;$Dir;*" -and $userPath -notlike "*;$Dir") {
            $newPath = "$Dir;$userPath"
            [System.Environment]::SetEnvironmentVariable("PATH", $newPath, [System.EnvironmentVariableTarget]::User)
            Ok "Added $Dir to PATH (user environment variable - permanent)"
        } else {
            Ok "Added $Dir to current session PATH"
        }
    }
}

function Confirm-ExakitOnPath {
    param([Parameter(Mandatory)][string]$Dir)
    # Unlike macOS/Linux, %USERPROFILE%\.local\bin is never on the Windows
    # PATH by default, so a hint alone leaves exakit unreachable in every
    # new terminal. Add the directory to the USER PATH (no admin needed,
    # idempotent) the way other user-scope installers (uv, cargo) do.
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $userEntries = ($userPath -split ";") | Where-Object { $_ }
    if ($userEntries -notcontains $Dir) {
        try {
            $newUserPath = if ($userPath) { "$userPath;$Dir" } else { $Dir }
            [Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
            Ok "Added $Dir to your user PATH (new terminals pick it up automatically)"
        } catch {
            Warn2 "$Dir could not be added to your PATH automatically."
            Write-Host "    Add it in Settings -> System -> About -> Advanced system settings -> Environment Variables,"
            Write-Host "    or run: `$env:Path += `";$Dir`" (current session only)"
        }
    }
    # Make it work in THIS session too (the machine-wide change only
    # affects newly started processes).
    if (($env:Path -split ";") -notcontains $Dir) {
        $env:Path += ";$Dir"
    }
}

# exakit_repo_root equivalent: prefer the copy under EXAKIT_HOME/kit (survives
# the original checkout moving/disappearing), fall back to this script's own
# checkout.
function Get-ExakitRepoRoot {
    $kitCopy = Join-Path $script:ExakitHome "kit"
    if (Test-Path (Join-Path $kitCopy "mcp")) { return $kitCopy }
    $commonDir = Split-Path -Parent $PSCommandPath
    $repoRoot = (Resolve-Path (Join-Path $commonDir "..\..")).Path
    if (Test-Path (Join-Path $repoRoot "mcp")) { return $repoRoot }
    return $null
}

# Install-ExakitSkills - copy the kit's AI skills into the per-user discovery
# folders so CLI agents auto-load them. Idempotent: each run replaces the
# managed copy of every skill, so edits and deletions propagate cleanly.
# Mirrors exakit_install_skills in setup/lib/common.sh.
#   $HOME\.claude\skills\<name>\   - Claude Code
#   $HOME\.agents\skills\<name>\   - Codex, Cursor, other open-standard agents
function Install-ExakitSkills {
    $repoRoot = Get-ExakitRepoRoot
    if (-not $repoRoot) { Warn2 "Could not locate the kit to find its skills\ directory."; return $false }
    $skillsSrc = Join-Path $repoRoot "skills"
    if (-not (Test-Path $skillsSrc)) { Warn2 "No skills\ directory in this kit build yet - nothing to install."; return $false }

    $installed = 0
    foreach ($skillDir in (Get-ChildItem -Path $skillsSrc -Directory -ErrorAction SilentlyContinue)) {
        if (-not (Test-Path (Join-Path $skillDir.FullName "SKILL.md"))) { continue }
        $name = $skillDir.Name
        foreach ($destRoot in @((Join-Path $HOME ".claude\skills"), (Join-Path $HOME ".agents\skills"))) {
            $dest = Join-Path $destRoot $name
            if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
            Copy-Item -Recurse -Force -Path (Join-Path $skillDir.FullName "*") -Destination $dest
        }
        Ok "Installed skill: $name"
        $installed++
    }
    if ($installed -eq 0) { Warn2 "No SKILL.md files found under $skillsSrc - nothing to install."; return $false }
    Info "Skills installed for Claude Code (~\.claude\skills) and open-standard agents (~\.agents\skills)."
    Info "Restart or reload your AI client to pick them up."
    return $true
}

# Request-ExakitSkillsInstallOffer - after setup, place the skills where CLI
# agents can find them. Mirrors exakit_maybe_offer_skills_install. Always
# installs - no prompt - so the skills are present without requiring
# interactive confirmation, on both interactive and non-interactive runs.
function Request-ExakitSkillsInstallOffer {
    $repoRoot = Get-ExakitRepoRoot
    if (-not $repoRoot) { return }
    $skillsSrc = Join-Path $repoRoot "skills"
    if (-not (Test-Path $skillsSrc)) { return }
    $hasSkill = Get-ChildItem -Path $skillsSrc -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName "SKILL.md") }
    if (-not $hasSkill) { return }
    if (-not (Install-ExakitSkills)) {
        Warn2 "Skills install did not finish cleanly. Retry any time with: exakit skills-install"
    }
}

# connection_panel equivalent - printed at the end of setup and via `exakit info`.
function Show-ExakitConnectionPanel {
    if (-not (Test-Path $script:ManifestPath)) { Warn2 "No installation found ($script:ManifestPath missing)"; return }
    $type    = Get-ExakitManifestValue "runtime.type"
    $dsn     = Get-ExakitManifestValue "runtime.dsn"
    $user    = Get-ExakitManifestValue "runtime.user"
    $pwFile  = Get-ExakitManifestValue "runtime.password_file"
    $mcpUser = Get-ExakitManifestValue "components.mcp_server.connection.user"
    $mcpPwf  = Get-ExakitManifestValue "components.mcp_server.connection.password_file"
    $exapumpPath    = Get-ExakitManifestValue "components.exapump.path"
    $exapumpProfile = Get-ExakitManifestValue "components.exapump.profile"
    $mcpConfigs     = Get-ExakitManifestValue "components.mcp_server.configs"

    Write-Host ""
    Start-ExakitPanel "Connection details"
    Write-ExakitPanelLine ("Runtime:      {0}" -f $(if ($type) { $type } else { 'unknown' }))
    Write-ExakitPanelLine ("DSN:          {0}" -f $(if ($dsn) { $dsn } else { 'unknown' }))
    Write-ExakitPanelLine ("Admin user:   {0}" -f $(if ($user) { $user } else { 'sys' }))
    if ($pwFile) { Write-ExakitPanelLine "Admin pass:   stored in $(Get-ExakitTilde $pwFile)" }
    if ($mcpUser) { Write-ExakitPanelLine "MCP user:     $mcpUser" }
    if ($mcpPwf)  { Write-ExakitPanelLine "MCP pass:     stored in $(Get-ExakitTilde $mcpPwf)" }
    Write-ExakitPanelLine "TLS:          enabled (self-signed certificate)"
    if ($exapumpPath) { Write-ExakitPanelLine "exapump:      $(Get-ExakitTilde $exapumpPath) (profile: $exapumpProfile)" }
    # Stdio MCP configs live inside each AI client's own config file, not in
    # the kit's mcp/ dir (that holds only pre-edit backups) - mirrors common.sh.
    if ($mcpConfigs) {
        Write-ExakitPanelLine "MCP configs:  in each AI client's config (list: exakit mcp-status)"
        Write-ExakitPanelLine "MCP backups:  $(Get-ExakitTilde $script:McpDir)"
    }
    Write-ExakitPanelLine "Manifest:     $(Get-ExakitTilde $script:ManifestPath)"
    Write-ExakitPanelLine "Logs:         $(Get-ExakitTilde $script:LogDir)"
    Complete-ExakitPanel
    Write-Host ""
}
