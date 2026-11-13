# tui.ps1 - exakit's terminal view: the whole kit on five tabs (Status, Marketplace, AI clients, External sources,
# Personas), a Textual app in setup\tui\exakit_tui. Twin of tui.sh.
#
#   exakit                     in a console: the view (redirected, or EXAKIT_NO_TUI=1: the help, as before)
#   exakit tui [--tab T]       the view on a tab: status, marketplace, clients, sources, personas
#   exakit <persona-id>        the view on that persona's page (redirected: exakit persona show <id>)
#
# The view reads everything from the kit's own `exakit ... --json` answers and every button runs an `exakit` command.
# It runs on the kit's own Textual - the version marketplace\defaults.env pins, through the kit's uv
# (setup\tui\start.py), as the persona and marketplace questions do - and adds no environment of its own.

# Test-ExakitTuiWanted - should a bare `exakit` open the view? Only for a person at a console. Twin of
# exakit_tui_wanted.
function Test-ExakitTuiWanted {
    if ($env:EXAKIT_NO_TUI -eq "1") { return $false }
    if ($env:CI) { return $false }
    try {
        if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { return $false }
    } catch { return $false }
    return $true
}

# Invoke-CmdTui [--tab T] [--persona ID] - open the view. Twin of cmd_tui.
function Invoke-CmdTui {
    param([string[]]$CmdArgs = @())
    $tab = "status"
    $persona = ""
    $i = 0
    while ($i -lt $CmdArgs.Count) {
        $a = "$($CmdArgs[$i])"
        if ($a -eq "--tab") {
            if ($i + 1 -ge $CmdArgs.Count) { Deny-ExakitInput "--tab takes one of: status, marketplace, clients, sources, personas" }
            $tab = "$($CmdArgs[$i + 1])"; $i += 2; continue
        }
        if ($a.StartsWith("--tab=")) { $tab = $a.Substring(6); $i += 1; continue }
        if ($a -eq "--persona") {
            if ($i + 1 -ge $CmdArgs.Count) { Deny-ExakitInput "--persona takes a persona id: exakit persona list" }
            $persona = "$($CmdArgs[$i + 1])"; $i += 2; continue
        }
        if ($a.StartsWith("--persona=")) { $persona = $a.Substring(10); $i += 1; continue }
        Deny-ExakitInput "Unknown option for tui: $a (supported: --tab status|marketplace|clients|sources|personas, --persona ID)"
    }
    if (@("status", "marketplace", "clients", "sources", "personas") -notcontains $tab) {
        Deny-ExakitInput "--tab takes one of: status, marketplace, clients, sources, personas (not '$tab')"
    }
    $redirected = $true
    try { $redirected = ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) } catch { $redirected = $true }
    if ($redirected) {
        Deny-ExakitInput "The terminal view needs a console. For scripts: exakit status --json, exakit marketplace --list --json, exakit persona show <id> --json"
    }
    $root = Get-ExakitRepoRoot
    $hostExe = (Get-Process -Id $PID).Path
    $cli = Join-Path $root "setup\exakit.ps1"
    $start = Join-Path $root "setup\tui\start.py"
    $tuiArgs = @("--cli=$hostExe", "--cli=-NoProfile", "--cli=-ExecutionPolicy", "--cli=Bypass", "--cli=-File",
                 "--cli=$cli", "--tab=$tab")
    if ($persona) { $tuiArgs += "--persona=$persona" }
    $python = Get-ExakitPersonaPython
    if ($python) {
        & $python $start $root @tuiArgs
    } else {
        & (Install-ExakitUv) run --no-project --python $script:ManagedPythonVersion python $start $root @tuiArgs
    }
    $code = $LASTEXITCODE
    if ($code -eq 11) { Write-Host "exakit: the terminal view could not start here. Every command works: exakit help" -ForegroundColor Yellow }
    exit $code
}

# Test-ExakitTuiIsPersona <word> - is the word a persona id of this kit? Twin of exakit_tui_is_persona.
function Test-ExakitTuiIsPersona {
    param([string]$Word)
    if (-not $Word -or $Word.StartsWith("-")) { return $false }
    if (-not (Get-Command Get-ExakitPersonaIds -ErrorAction SilentlyContinue)) { return $false }
    try { return (@(Get-ExakitPersonaIds) -contains $Word) } catch { return $false }
}

# Invoke-ExakitTuiPersona <id> - `exakit data-scientist` at a console: the persona's page in the view (redirected,
# exakit.ps1 prints the persona as `exakit persona show <id>` does instead). Twin of exakit_tui_persona.
function Invoke-ExakitTuiPersona {
    param([Parameter(Mandatory)][string]$Id)
    Invoke-CmdTui -CmdArgs @("--tab", "personas", "--persona", $Id)
}
