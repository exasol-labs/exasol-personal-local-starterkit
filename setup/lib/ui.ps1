# ui.ps1 - shared visual layer for the installer (Windows / PowerShell path).
#
# Function-for-function twin of setup/lib/ui.sh: the EXASOL wordmark banner,
# colour palette, status glyphs, an animated braille spinner with elapsed
# timing, a progress bar, and auto-width panels. The wordmark lines and glyphs
# are byte-identical to ui.sh so the banner is the same on macOS, Linux/WSL,
# and Windows.
#
# Targets Windows PowerShell 5.1 and PowerShell 7+ (no ternary, no ??). Dot-
# sourced by exakit-common.ps1 and by install.ps1.
#
# Design rules mirror ui.sh:
#   * Fancy output (colour + Unicode + animation) is used ONLY on an
#     interactive terminal with VT/ANSI enabled; redirected / non-interactive
#     output falls back to plain ASCII with no escapes.
#   * The command execution in Invoke-ExakitLogged is NOT restructured to add
#     the spinner - the spinner animates in a background runspace, so a broken
#     spinner can never break an install.

$script:UiEsc = [char]27

# --- console + capability detection -----------------------------------------
# Force UTF-8 output so the wordmark/box glyphs render, and try to turn on
# ANSI/VT processing (needed for colour on Windows PowerShell 5.1 conhost).
# Sets $script:UiFancy. Safe to call more than once.
function Initialize-ExakitConsole {
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    # $OutputEncoding encodes what PowerShell pipes INTO native commands'
    # stdin, so it must be a BOM-LESS UTF-8: the static [Text.Encoding]::UTF8
    # instance emits a U+FEFF preamble, which Windows PowerShell 5.1's pipe
    # writer prepends to the piped stream. Exasol rejects U+FEFF in SQL text
    # ("character is not allowed within unquoted identifier"). Note this alone
    # does NOT make stdin-piping SQL safe on 5.1 - its pipe writer adds a
    # second BOM of its own regardless of $OutputEncoding (observed under the
    # system-wide UTF-8 codepage 65001) - which is why SQL files are fed to
    # exapump as raw bytes instead (see Invoke-ExapumpSqlFileCapture).
    try { $global:OutputEncoding    = New-Object System.Text.UTF8Encoding $false } catch { }

    $vt = $false
    try {
        if (-not ("Exakit.Vt" -as [type])) {
            Add-Type -Namespace Exakit -Name Vt -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern System.IntPtr GetStdHandle(int nStdHandle);
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern bool GetConsoleMode(System.IntPtr h, out uint mode);
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern bool SetConsoleMode(System.IntPtr h, uint mode);
'@ | Out-Null
        }
        $h = [Exakit.Vt]::GetStdHandle(-11)   # STD_OUTPUT_HANDLE
        $mode = [uint32]0
        if ([Exakit.Vt]::GetConsoleMode($h, [ref]$mode)) {
            $mode = $mode -bor 0x0004          # ENABLE_VIRTUAL_TERMINAL_PROCESSING
            $vt = [Exakit.Vt]::SetConsoleMode($h, $mode)
        }
    } catch { $vt = $false }

    $script:UiVt = $vt
    $redirected = $false
    try { $redirected = [Console]::IsOutputRedirected } catch { $redirected = $false }
    $script:UiFancy = ($vt -and -not $redirected -and -not $env:NO_COLOR -and $env:EXAKIT_NO_FANCY -ne "1")
    Set-ExakitPalette
}

# --- palette & glyphs -------------------------------------------------------
function Set-ExakitPalette {
    $e = $script:UiEsc
    if ($script:UiFancy) {
        $script:UiReset="${e}[0m"; $script:UiBold="${e}[1m"; $script:UiDim="${e}[2m"
        $script:UiAccent="${e}[38;5;35m"
        $script:UiGreen="${e}[38;5;77m"; $script:UiFg="${e}[39m"
        $script:UiOk="${e}[1;32m"; $script:UiWarn="${e}[1;33m"; $script:UiErr="${e}[1;31m"
        $script:UiInfo="${e}[1;34m"; $script:UiAsk="${e}[1;36m"
    } else {
        $script:UiReset=""; $script:UiBold=""; $script:UiDim=""; $script:UiAccent=""
        $script:UiGreen=""; $script:UiFg=""
        $script:UiOk=""; $script:UiWarn=""; $script:UiErr=""; $script:UiInfo=""; $script:UiAsk=""
    }
    # Glyphs rely on the UTF-8 console set above; fall back to ASCII when we
    # could not establish a fancy terminal at all.
    if ($script:UiFancy) {
        $script:UiTick="✓"; $script:UiCross="✗"; $script:UiBullet="•"; $script:UiArrow="▸"
        $script:UiHr="─"; $script:UiTL="╭"; $script:UiTR="╮"; $script:UiBL="╰"; $script:UiBR="╯"; $script:UiVB="│"
        $script:UiTee="├─"; $script:UiCorner="└─"
        $script:UiBarFull="█"; $script:UiBarEmpty="░"
        # Eighths of a block: the frontier cell of a progress bar, so a forty-cell
        # bar has 320 positions instead of 40 and every percent shows on screen.
        # Index 0 is a space - an empty frontier when there is no fraction to
        # draw, which keeps the dim remainder unbroken. Twin of
        # UI_PROGRESS_EIGHTHS in ui.sh; the glyphs live HERE because this is the
        # one .ps1 with a BOM (see ps-encoding-guard).
        $script:UiProgressEighths = @(' ','▏','▎','▍','▌','▋','▊','▉')
        # The separator ui.sh types inline, as in "completed · 8 tables, 173,745
        # rows". It lives in the palette because every other .ps1 has to stay pure
        # ASCII (see tests/ps-encoding-guard.sh), so a caller that wants the same
        # glyph has to be handed it rather than type it.
        $script:UiMidDot = "·"
        # The truncation marker, for the same reason: a caller that has to cut a
        # cell to the column (the add-on Status cell) cannot type this byte in its
        # own file. Its LENGTH differs between the palettes, so every user of it
        # measures rather than assumes.
        $script:UiEllipsis = "…"
    } else {
        $script:UiTick="+"; $script:UiCross="x"; $script:UiBullet="-"; $script:UiArrow=">"
        $script:UiHr="-"; $script:UiTL="+"; $script:UiTR="+"; $script:UiBL="+"; $script:UiBR="+"; $script:UiVB="|"
        $script:UiTee="|-"; $script:UiCorner='`-'
        $script:UiBarFull="#"; $script:UiBarEmpty="."
        $script:UiProgressEighths = @(' ',' ',' ',' ',' ',' ',' ',' ')
        $script:UiMidDot = "-"
        $script:UiEllipsis = "..."
    }
}

# EXASOL wordmark (ANSI Shadow) - segments mirror ui.sh's UI_WM_* so the "X"
# gets the logo's two-tone look (green left strokes + crossing peak; the rest
# in the terminal's default colour).
$script:UiWmE  = @('███████╗','██╔════╝','█████╗  ','██╔══╝  ','███████╗','╚══════╝')
$script:UiWmXL = @('██╗ ','╚██╗',' ╚███',' ██╔','██╔╝','╚═╝ ')
$script:UiWmXR = @(' ██╗','██╔╝','╔╝ ','██╗ ',' ██╗',' ╚═╝')
$script:UiWmR  = @(
' █████╗ ███████╗ ██████╗ ██╗',
'██╔══██╗██╔════╝██╔═══██╗██║',
'███████║███████╗██║   ██║██║',
'██╔══██║╚════██║██║   ██║██║',
'██║  ██║███████║╚██████╔╝███████╗',
'╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚══════╝'
)

$script:UiBoxW = 58

# Initialise on load so callers can use the palette immediately.
Initialize-ExakitConsole

# --- primitive helpers ------------------------------------------------------
# Both roots, longest match wins, compared ordinally.
#
# Two bugs in one line, and they cancelled out into "the shortening just stops
# working". Every path the kit prints is built from %USERPROFILE%, so on a
# domain machine nothing ever matched $HOME and users saw the full path
# everywhere. And String.StartsWith(string) is culture-sensitive AND
# case-sensitive, so even on a single-profile machine a path that differs only
# in case - routine on a case-insensitive filesystem - did not match either.
function Get-ExakitTilde([string]$Path) {
    if (-not $Path) { return $Path }
    $roots = @()
    if ($env:USERPROFILE) { $roots += $env:USERPROFILE }
    if ($HOME) { $roots += $HOME }
    $best = ""
    foreach ($r in $roots) {
        if ($r -and $Path.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase) -and
            $r.Length -gt $best.Length) { $best = $r }
    }
    if ($best) { return "~" + $Path.Substring($best.Length) }
    return $Path
}

# Write-ExakitBanner <title> <subtitle>
function Write-ExakitBanner {
    param([string]$Title = "Exasol Personal Local Starter Kit", [string]$Subtitle = "")
    Write-Host ""
    if ($script:UiFancy) {
        for ($i = 0; $i -lt 6; $i++) {
            Write-Host ("  {0}{1}{2}{3}{4}{5}{6}" -f `
                ($script:UiBold + $script:UiFg), $script:UiWmE[$i], `
                $script:UiGreen, $script:UiWmXL[$i], `
                $script:UiFg, ($script:UiWmXR[$i] + $script:UiWmR[$i]), `
                $script:UiReset)
        }
        Write-Host ""
    }
    Write-Host ("  {0}{1}{2}" -f $script:UiBold, $Title, $script:UiReset)
    if ($Subtitle) { Write-Host ("  {0}{1}{2}" -f $script:UiDim, $Subtitle, $script:UiReset) }
    Write-Host ""
}

# --- fixed-width box --------------------------------------------------------
function Write-ExakitBoxTop([string]$Title) {
    $t = " $Title "
    $fill = $script:UiBoxW - $t.Length - 1
    if ($fill -lt 0) { $fill = 0 }
    Write-Host ("  {0}{1}{2}{3}{4}{5}{6}" -f `
        $script:UiAccent, ($script:UiTL + $script:UiHr), ($script:UiReset + $script:UiBold + $t + $script:UiReset), `
        $script:UiAccent, ($script:UiHr * $fill), $script:UiTR, $script:UiReset)
}
function Write-ExakitBoxLine([string]$Text) {
    $pad = $script:UiBoxW - $Text.Length - 2
    if ($pad -lt 0) { $pad = 0 }
    Write-Host ("  {0} {1}{2} {3}" -f `
        ($script:UiAccent + $script:UiVB + $script:UiReset), $Text, (" " * $pad), `
        ($script:UiAccent + $script:UiVB + $script:UiReset))
}
function Write-ExakitBoxBottom {
    Write-Host ("  {0}{1}{2}{3}" -f $script:UiAccent, $script:UiBL, ($script:UiHr * $script:UiBoxW), ($script:UiBR + $script:UiReset))
}

# --- auto-width panel (sizes to the longest line) ---------------------------
$script:UiPanelTitle = ""
# Write-ExakitLink <url> [text] - a terminal hyperlink (OSC 8): clickable text
# that opens <url>. Falls back to plain text when the session is not rendering
# rich output. Windows Terminal, VS Code's terminal, and modern PowerShell
# hosts render it; older consoles show the visible text.
function Write-ExakitLink {
    param([Parameter(Mandatory)][string]$Url, [string]$Text = "")
    if (-not $Text) { $Text = $Url }
    if ($script:UiFancy) {
        return ([char]27 + "]8;;" + $Url + [char]27 + "\" + $Text + [char]27 + "]8;;" + [char]27 + "\")
    }
    return $Text
}

# Get-ExakitVisibleLength <string> - character length ignoring escape sequences
# (CSI colour + OSC 8 hyperlink), so a panel line carrying either still lines up.
function Get-ExakitVisibleLength {
    param([AllowEmptyString()][string]$Text)
    $esc = [char]27
    $clean = [regex]::Replace($Text, [regex]::Escape($esc) + "\[[0-9;]*m", "")
    $clean = [regex]::Replace($clean, [regex]::Escape($esc) + "\]8;;[^" + [regex]::Escape($esc) + [char]7 + "]*(" + [char]7 + "|" + [regex]::Escape($esc) + "\\)", "")
    return $clean.Length
}

$script:UiPanelLines = @()
function Start-ExakitPanel([string]$Title) { $script:UiPanelTitle = $Title; $script:UiPanelLines = @() }
function Write-ExakitPanelLine([string]$Text) { $script:UiPanelLines += $Text }
function Complete-ExakitPanel {
    $w = $script:UiPanelTitle.Length + 1
    foreach ($l in $script:UiPanelLines) { $ll = Get-ExakitVisibleLength $l; if ($ll -gt $w) { $w = $ll } }
    $w = $w + 2
    $t = " $($script:UiPanelTitle) "
    $fill = $w - $t.Length - 1
    if ($fill -lt 0) { $fill = 0 }
    Write-Host ("  {0}{1}{2}{3}{4}{5}{6}" -f `
        $script:UiAccent, ($script:UiTL + $script:UiHr), ($script:UiReset + $script:UiBold + $t + $script:UiReset), `
        $script:UiAccent, ($script:UiHr * $fill), $script:UiTR, $script:UiReset)
    foreach ($l in $script:UiPanelLines) {
        $pad = $w - (Get-ExakitVisibleLength $l) - 2
        if ($pad -lt 0) { $pad = 0 }
        Write-Host ("  {0} {1}{2} {3}" -f `
            ($script:UiAccent + $script:UiVB + $script:UiReset), $l, (" " * $pad), `
            ($script:UiAccent + $script:UiVB + $script:UiReset))
    }
    Write-Host ("  {0}{1}{2}{3}" -f $script:UiAccent, $script:UiBL, ($script:UiHr * $w), ($script:UiBR + $script:UiReset))
}

# --- spinner (background runspace) ------------------------------------------
# The spinner animates in a separate runspace writing directly to the console.
# The foreground keeps running the real command (its output goes to the log,
# not the console), so there is a single console writer during the spin. If
# anything about the runspace misbehaves it is swallowed - never fatal.
$script:UiSpinPs = $null
$script:UiSpinRs = $null
$script:UiSpinFlag = $null

# Write-ExakitRule - a dim full-width divider, with a blank line either side.
#
# For the seam between two parts of a run: the install is finished and something
# else is being asked. Sized to the console so it reads as a break rather than as
# content. Twin of ui_rule in ui.sh.
function Write-ExakitRule {
    $width = 76
    try { $width = [Console]::WindowWidth - 4 } catch { $width = 76 }
    if ($width -gt 76) { $width = 76 }
    if ($width -lt 8) { $width = 8 }
    Write-Host ""
    Write-Host ("  {0}{1}{2}" -f $script:UiDim, ($script:UiHr * $width), $script:UiReset)
    Write-Host ""
}

# ONE animation at a time. There is a single line being redrawn, so a second
# request to animate is a no-op rather than a second painter. This is what lets a
# progress line survive the work underneath it: a dataset load paints its own bar
# and then calls exapump through Invoke-ExakitLogged, which asks for a spinner of
# its own; without the counter that call's Stop would kill the bar after the
# first file. Twin of _UI_SPIN_NESTED in ui.sh.
$script:UiSpinNested = 0
# Declared HERE, next to the counter it participates in, and again with the rest
# of the table state further down: the two Start- functions below read it, so it
# has to exist before the table section is reached.
$script:UiTableLive = $false

function Start-ExakitSpinner([string]$Label) {
    # A live table is the same single slot: it is already redrawing these rows, so
    # a spinner underneath it takes a reference and draws nothing. Without this a
    # dataset load's first Invoke-ExakitLogged would paint a spinner over the
    # table, and its Stop would then tear the table down.
    if ($null -ne $script:UiSpinFlag -or $script:UiTableLive) { $script:UiSpinNested++; return }
    if (-not $script:UiFancy) { return }
    try {
        $script:UiSpinFlag = [hashtable]::Synchronized(@{ Run = $true; Label = $Label; T0 = (Get-Date) })
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('flag', $script:UiSpinFlag)
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            $frames = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
            $e = [char]27
            $i = 0
            while ($flag.Run) {
                $el = [int]((Get-Date) - $flag.T0).TotalSeconds
                [Console]::Write("`r  ${e}[38;5;35m$($frames[$i])${e}[0m $($flag.Label) ${e}[2m(${el}s)${e}[0m${e}[K")
                $i = ($i + 1) % 10
                Start-Sleep -Milliseconds 90
            }
        })
        [Console]::Write("$($script:UiEsc)[?25l")   # hide cursor
        $script:UiSpinPs = $ps
        $script:UiSpinRs = $rs
        [void]$ps.BeginInvoke()
    } catch {
        $script:UiSpinFlag = $null; $script:UiSpinPs = $null; $script:UiSpinRs = $null
    }
}

function Stop-ExakitSpinner {
    # Give back a reference taken while something else owned the line; only the
    # call that actually started the animation stops it.
    if ($script:UiSpinNested -gt 0) { $script:UiSpinNested--; return }
    if ($null -eq $script:UiSpinFlag) { return }
    try { $script:UiSpinFlag.Run = $false; Start-Sleep -Milliseconds 110 } catch { }
    try { if ($script:UiSpinPs) { $script:UiSpinPs.Stop(); $script:UiSpinPs.Dispose() } } catch { }
    try { if ($script:UiSpinRs) { $script:UiSpinRs.Close(); $script:UiSpinRs.Dispose() } } catch { }
    $script:UiSpinPs = $null; $script:UiSpinRs = $null; $script:UiSpinFlag = $null
    try { [Console]::Write("`r$($script:UiEsc)[K$($script:UiEsc)[?25h") } catch { }  # clear line, restore cursor
}

# Suspend-ExakitSpinner / Resume-ExakitSpinner - print a line without losing the
# spinner. Twins of ui_spin_pause / ui_spin_resume in ui.sh.
#
# A spinner OWNS its line and rewrites it every 90ms, so anything printed while
# it runs lands in the middle of that line rather than on a row of its own. The
# uninstall showed it plainly: three add-on outcomes appended themselves to
# "Removing the kit (4s)" instead of standing under it.
#
# Resuming restores the ORIGINAL start time, so the elapsed counter carries on
# instead of restarting at (0s) every time something prints. The runspace reads
# Label and T0 out of the synchronized hashtable while it runs, so putting T0
# back after the restart is enough. Only the owner pauses, and only when nothing
# else holds a reference -- a nested caller is not this one's to stop.
$script:UiSpinPaused = $false
$script:UiSpinPausedLabel = ""
$script:UiSpinPausedT0 = $null
function Suspend-ExakitSpinner {
    $script:UiSpinPaused = $false
    if ($script:UiSpinNested -gt 0) { return }
    if ($null -eq $script:UiSpinFlag) { return }
    $script:UiSpinPausedLabel = [string]$script:UiSpinFlag.Label
    $script:UiSpinPausedT0 = $script:UiSpinFlag.T0
    $script:UiSpinPaused = $true
    Stop-ExakitSpinner
}
function Resume-ExakitSpinner {
    if (-not $script:UiSpinPaused) { return }
    $script:UiSpinPaused = $false
    Start-ExakitSpinner $script:UiSpinPausedLabel
    if ($null -ne $script:UiSpinFlag -and $null -ne $script:UiSpinPausedT0) {
        try { $script:UiSpinFlag.T0 = $script:UiSpinPausedT0 } catch { }
    }
}

function Restore-ExakitCursor { if ($script:UiFancy) { try { [Console]::Write("$($script:UiEsc)[?25h") } catch { } } }

# --- progress bar (determinate) ---------------------------------------------
function Write-ExakitProgress([int]$Current, [int]$Total, [string]$Label = "") {
    if ($Total -le 0) { $Total = 1 }
    $wide = 20
    $filled = [int]($Current * $wide / $Total)
    if ($filled -gt $wide) { $filled = $wide }
    $pct = [int]($Current * 100 / $Total)
    if ($script:UiFancy) {
        [Console]::Write(("`r  {0}{1}{2}{3} {4}{5,3}%{6} {7}{8}" -f `
            $script:UiAccent, ($script:UiBarFull * $filled), $script:UiDim, `
            (($script:UiBarEmpty * ($wide - $filled)) + $script:UiReset), `
            $script:UiBold, $pct, $script:UiReset, $Label, "$($script:UiEsc)[K"))
    } else {
        Write-Host ("  [{0}{1}] {2}%  {3}" -f ($script:UiBarFull * $filled), ($script:UiBarEmpty * ($wide - $filled)), $pct, $Label)
    }
}

# Start-ExakitProgress / Set-ExakitProgress / Stop-ExakitProgress - the bar that
# every long job the kit runs drives.
#
# The spinner's runspace already reads its state live out of a synchronized
# hashtable, so the state goes in there rather than into a file the way the bash
# twin needs. Milestones are the truth - Pct is where the job actually is - and
# the runspace fills the gap to Ceiling at the pace Secs says the stage takes,
# capped one point below it. A stage that overruns waits rather than walking into
# the next one's territory. Twin of ui_progress_begin / ui_progress_state /
# ui_progress_end in ui.sh.
function Start-ExakitProgress {
    param([int]$Pct = 0, [int]$Ceiling = 1, [int]$Secs = 2, [string]$Phase = "")
    # Same single slot as the spinner, and a live table holds it: a bar drawn
    # under a repainting frame lands inside the box. The caller reads $false as
    # "narrate in plain lines" - or, for a dataset with a row of its own, reports
    # into that row instead (see Set-ExakitLoadStep).
    if ($null -ne $script:UiSpinFlag -or $script:UiTableLive) { $script:UiSpinNested++; return $false }
    if (-not $script:UiFancy) { return $false }
    try {
        $now = Get-Date
        $script:UiSpinFlag = [hashtable]::Synchronized(@{
            Run = $true; Label = $Phase; T0 = $now
            Pct = $Pct; Ceiling = $Ceiling; Secs = $Secs; SegT0 = $now; Shown = 0
            Cols = 80
        })
        try { $script:UiSpinFlag.Cols = [Console]::WindowWidth } catch { }
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('flag', $script:UiSpinFlag)
        $rs.SessionStateProxy.SetVariable('pal', @{
            Accent = $script:UiAccent; Dim = $script:UiDim; Reset = $script:UiReset
            Bold = $script:UiBold; Full = $script:UiBarFull; Empty = $script:UiBarEmpty
            Eighths = $script:UiProgressEighths; Esc = $script:UiEsc
        })
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            $frames = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
            $i = 0
            while ($flag.Run) {
                $avail = $flag.Cols - 9
                if ($avail -gt 112) { $avail = 112 }
                if ($avail -lt 24) { $avail = 24 }
                $tw = [int]($avail * 30 / 100); $bw = [int]($avail * 40 / 100)
                $nw = [int]($avail * 10 / 100); $ew = [int]($avail * 10 / 100)
                $gap = $avail - $tw - $bw - $nw - $ew
                if ($gap -lt 1) { $gap = 1 }
                if ($nw -lt 5) { $tw -= (5 - $nw); $nw = 5 }
                if ($ew -lt 7) { $tw -= (7 - $ew); $ew = 7 }
                if ($bw -lt 8) { $bw = 8 }
                if ($tw -lt 8) { $tw = 8 }

                # Where the bar sits right now: the milestone, plus as much of
                # the way to the next one as the clock has earned.
                $pct = $flag.Pct
                $span = $flag.Ceiling - $pct
                if ($span -gt 0 -and $flag.Secs -gt 0) {
                    $inSeg = [int]((Get-Date) - $flag.SegT0).TotalSeconds
                    $step = [int]($span * $inSeg / $flag.Secs)
                    if ($step -gt ($span - 1)) { $step = $span - 1 }
                    if ($step -lt 0) { $step = 0 }
                    $pct = $pct + $step
                }
                if ($pct -lt $flag.Shown) { $pct = $flag.Shown }
                $flag.Shown = $pct

                $text = "$($flag.Label)"
                if ($text.Length -gt ($tw - 1)) { $text = $text.Substring(0, $tw - 2) + "…" }
                $text = $text.PadRight($tw + $gap)
                $units = [int]($pct * $bw * 8 / 100)
                $full = [int]($units / 8); $rem = $units % 8
                if ($full -gt $bw) { $full = $bw; $rem = 0 }
                $head = ""
                if ($full -lt $bw -and $rem -gt 0) { $head = $pal.Eighths[$rem] }
                $empty = $bw - $full - $head.Length
                if ($empty -lt 0) { $empty = 0 }
                $bar = $pal.Accent + ($pal.Full * $full) + $pal.Dim + $head + ($pal.Empty * $empty) + $pal.Reset
                $el = [int]((Get-Date) - $flag.T0).TotalSeconds
                [Console]::Write("`r      $($pal.Accent)$($frames[$i])$($pal.Reset) $text$bar$($pal.Bold)$(("$pct%").PadLeft($nw))$($pal.Reset)$($pal.Dim)$(("($el" + "s)").PadLeft($ew))$($pal.Reset)$($pal.Esc)[K")
                $i = ($i + 1) % 10
                Start-Sleep -Milliseconds 200
            }
        })
        [Console]::Write("$($script:UiEsc)[?25l")
        $script:UiSpinPs = $ps
        $script:UiSpinRs = $rs
        [void]$ps.BeginInvoke()
        return $true
    } catch {
        $script:UiSpinFlag = $null; $script:UiSpinPs = $null; $script:UiSpinRs = $null
        return $false
    }
}

# Set-ExakitProgress - the job has reached a new stage. The segment's clock
# starts now, which is what the creep measures against.
function Set-ExakitProgress {
    param([int]$Pct, [int]$Ceiling, [int]$Secs, [string]$Phase)
    if ($null -eq $script:UiSpinFlag) { return }
    try {
        $script:UiSpinFlag.Pct = $Pct
        $script:UiSpinFlag.Ceiling = $Ceiling
        $script:UiSpinFlag.Secs = $Secs
        $script:UiSpinFlag.SegT0 = Get-Date
        $script:UiSpinFlag.Label = $Phase
    } catch { }
}

# Set-ExakitProgressPhase - change the words without touching the position or
# restarting the segment's clock. For a stage that reports what it has finished
# while the bar keeps creeping on its own (concurrent uploads landing one by
# one). Twin of ui_progress_phase in ui.sh.
function Set-ExakitProgressPhase {
    param([string]$Phase)
    if ($null -eq $script:UiSpinFlag) { return }
    try { $script:UiSpinFlag.Label = $Phase } catch { }
}

function Stop-ExakitProgress { Stop-ExakitSpinner }

# Write-ExakitProgressLine <pct> <phase> <elapsed> <frame> <cols> - the progress
# line every long job the kit runs shares.
#
# Four cells across the console's own width:
#
#   30% phase - 40% bar - 10% percentage - 10% elapsed, and a tenth as the gap
#
# The phase leads because it is what a reader is actually reading; the numbers
# trail because they are what they glance at. The bar starts at the same column
# whatever the phase is called. One column is left unwritten: a line that fills
# the last cell sets the terminal's pending-wrap flag and the next carriage
# return lands a row lower. Capped, because the cells are proportions and a very
# wide console turns the phase cell into dead air.
# Twin of ui_progress_line in ui.sh.
function Write-ExakitProgressLine {
    param(
        [int]$Pct, [string]$Phase, [int]$Elapsed, [int]$Frame = 0, [int]$Cols = 80
    )
    $avail = $Cols - 6 - 2 - 1
    if ($avail -gt 112) { $avail = 112 }
    if ($avail -lt 24) { $avail = 24 }
    $tw = [int]($avail * 30 / 100)
    $bw = [int]($avail * 40 / 100)
    $nw = [int]($avail * 10 / 100)
    $ew = [int]($avail * 10 / 100)
    $gap = $avail - $tw - $bw - $nw - $ew
    if ($gap -lt 1) { $gap = 1 }
    # Floors: a cell that cannot hold "100%" or "(120s)" is worse than a
    # narrower neighbour, and the phase is the only cell that can be shortened
    # without losing something the others carry exactly.
    if ($nw -lt 5) { $tw -= (5 - $nw); $nw = 5 }
    if ($ew -lt 7) { $tw -= (7 - $ew); $ew = 7 }
    if ($bw -lt 8) { $bw = 8 }
    if ($tw -lt 8) { $tw = 8 }

    # Truncated to its cell MINUS ONE, so a long phase keeps a gap before the bar.
    $text = $Phase
    if ($text.Length -gt ($tw - 1)) { $text = $text.Substring(0, $tw - 2) + "…" }
    $text = $text.PadRight($tw + $gap)

    if ($script:UiFancy) {
        $units = [int]($Pct * $bw * 8 / 100)
        $full = [int]($units / 8)
        $rem = $units % 8
        if ($full -gt $bw) { $full = $bw; $rem = 0 }
        $head = ""
        if ($full -lt $bw -and $rem -gt 0) { $head = $script:UiProgressEighths[$rem] }
        $empty = $bw - $full - $head.Length
        if ($empty -lt 0) { $empty = 0 }
        $bar = $script:UiAccent + ($script:UiBarFull * $full) + $script:UiDim + $head +
               ($script:UiBarEmpty * $empty) + $script:UiReset
        $frames = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
        $spin = $frames[$Frame % 10]
    } else {
        $full = [int]($Pct * $bw / 100)
        if ($full -gt $bw) { $full = $bw }
        $bar = ($script:UiBarFull * $full) + ($script:UiBarEmpty * ($bw - $full))
        $spin = ">"
    }
    $num = ("{0}%" -f $Pct).PadLeft($nw)
    $el = ("({0}s)" -f $Elapsed).PadLeft($ew)
    [Console]::Write("`r      {0}{1}{2} {3}{4}{5}{6}{7}{8}{9}{10}{11}[K" -f
        $script:UiAccent, $spin, $script:UiReset, $text, $bar,
        $script:UiBold, $num, $script:UiReset, $script:UiDim, $el, $script:UiReset,
        $script:UiEsc)
}

# Get-ExakitBar <pct> [width] - the bar on its own, as a STRING.
#
# Write-ExakitProgress above owns a whole line and redraws it. This one owns
# nothing: it is for embedding a bar inside a label somebody else paints - the
# dataset load hands it to the spinner, so the animation, the bar, the
# percentage and the current file are one line instead of four competing for it.
# Twin of ui_bar in ui.sh.
function Get-ExakitBar {
    param([int]$Pct, [int]$Width = 20)
    $filled = [int]($Pct * $Width / 100)
    if ($filled -gt $Width) { $filled = $Width }
    if ($filled -lt 0) { $filled = 0 }
    return ("{0}{1}{2}{3}{4}" -f $script:UiAccent, ($script:UiBarFull * $filled),
        $script:UiDim, ($script:UiBarEmpty * ($Width - $filled)), $script:UiReset)
}

# --- the live table ----------------------------------------------------------
# One table that is both the menu and the progress display: you tick rows in it,
# it fills its Status column in place as the work runs, and what is left on
# screen at the end is the record of what happened. Nothing scrolls past.
# Twin of the ui_table_* family in ui.sh.
#
# The state is ONE synchronized hashtable, not a file: the bash side needs a file
# because the thing doing the work is usually in a subshell that cannot reach the
# animator's variables, and PowerShell has no such split - the animator reads the
# very object the foreground mutates. The shape is otherwise the bash one:
#
#   Title    what the top border says
#   Col1     what the first column is called (datasets, clients, add-ons)
#   Col2     heading for an optional second column, "" when there is none
#   Col3     heading for an optional third column, "" when there is none
#   Cols     the console width, measured once
#   Lines    how many lines the last frame really occupied
#   Width    how wide the last frame's box was - see Update-ExakitTable, which
#            overwrites in place rather than clearing while both are unchanged
#   Rows     one hashtable per row:
#              Kind    group | tee | corner | plain   - the tree connector
#              Tick    $true while the row is selected
#              State   idle | waiting | running | done | failed | disabled
#              Final   what the Status column says once the row is finished
#
# A "disabled" row is one the reader can look at but never pick - an AI client
# that is not installed on this machine. It is drawn by Get-ExakitTableFrame
# itself (dim, no checkbox, its note reading on from the label) and never reaches
# Get-ExakitTableCell, because it has no Status of its own to report. See
# Disable-ExakitTableRow.
#
# The redraw is Read-ExakitCheckboxMenu's: count the lines the last frame REALLY
# occupied (a wrapped row is two), go up by that many, and clear from there.
# Anything else stacks stale rows with every keypress.
$script:UiTable = $null
$script:UiTableLive = $false
$script:UiTablePs = $null
$script:UiTableRs = $null
$script:UiTableHandle = $null

# The animator runs in a runspace, and a runspace inherits no functions - so it
# needs this file's own frame builder, which means this file's own SOURCE. Read
# as text and re-created as a scriptblock rather than dot-sourced by path: a
# script FILE is subject to the execution policy, a scriptblock built from a
# string is not, and the alternative - a second copy of the frame builder inlined
# into the animator - is the drift this file exists to prevent.
$script:UiTableSrc = ""
if ($PSCommandPath) { $script:UiTableSrc = $PSCommandPath }
elseif ($PSScriptRoot) { $script:UiTableSrc = Join-Path $PSScriptRoot "ui.ps1" }
# Read ONCE, now, while the file is certainly there - not when the first table
# starts. A table starts minutes later, at the end of an install, and on Windows
# that install had just cleared and re-staged kit\setup\lib: the read threw,
# Start-ExakitTable answered $false, and the marketplace install fell back to
# plain lines and a one-line bar under a table that never animated. Whatever
# happens to the file afterwards, the animator has the source this session was
# loaded from - which is also the only source that matches the functions in it.
$script:UiTableSrcText = ""
if ($script:UiTableSrc) {
    try { $script:UiTableSrcText = [System.IO.File]::ReadAllText($script:UiTableSrc) } catch { }
}

# New-ExakitTable [-Title] [-Col1] [-Col2] [-Col3] - a fresh, empty table. Returns it,
# and also parks it as the module's current one so every other call can default
# to it.
#
# Col1 travels ON the table, not in a module variable the way ui.sh's
# UI_TABLE_COL1 does: three screens in one run build a table each (clients,
# datasets, add-ons), and a heading left behind in module state is how the second
# one ends up wearing the first one's column name.
function New-ExakitTable {
    param([string]$Title = "Progress", [string]$Col1 = "Dataset",
          [string]$Col2 = "", [string]$Col3 = "")
    $t = [hashtable]::Synchronized(@{
        Title   = $Title
        Col1    = $Col1
        Col2    = $Col2
        Col3    = $Col3
        Cols    = 80
        Lines   = 0
        Width   = 0
        Rows    = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        Run     = $false
        Stop    = $false
        Alive   = $false
    })
    try { $t.Cols = [Console]::WindowWidth } catch { }
    $script:UiTable = $t
    return $t
}

# Add-ExakitTableRow -Kind <group|tee|corner|plain> -Label <text> [-Ticked]
# One row, appended in the order it will be drawn. Returns its 1-based number,
# which is how every later call names it.
function Add-ExakitTableRow {
    param(
        [ValidateSet("group", "tee", "corner", "plain")][string]$Kind = "plain",
        [Parameter(Mandatory)][string]$Label,
        [string]$Col2 = "",
        [string]$Col3 = "",
        [switch]$Ticked,
        [hashtable]$Table = $null
    )
    if ($null -eq $Table) { $Table = $script:UiTable }
    if ($null -eq $Table) { return 0 }
    $row = [hashtable]::Synchronized(@{
        Kind = $Kind; Label = $Label; Tick = [bool]$Ticked
        State = "idle"; Pct = 0; Ceiling = 0; Secs = 0
        SegT0 = $null; Phase = ""; Final = ""
        Col2 = $Col2; Col3 = $Col3
    })
    [void]$Table.Rows.Add($row)
    return $Table.Rows.Count
}

# $script:UiTableCol3Fixed - the Description column's width, FIXED rather than
# measured. Measured, it would size to the longest About and change the table's
# width whenever a fetch landed a longer one; fixed, the same description reads
# the same here as it does in `exakit help`, which wraps to the same 44.
$script:UiTableCol3Fixed = 44

# $script:UiTableCol3Max - how wide the Description may GROW into slack the
# console has going spare. The Status column reserves a 44-column floor for
# statuses that only arrive once rows finish, so on a wide console the selection
# screen showed a 44-wide description wrapped to five lines next to an empty
# 44-wide column: a wall of text beside a void. Growing the description into the
# slack spends that width on the only cell that has anything to say yet. Capped,
# because past about 90 columns a line of prose stops being easy to track back
# to the next one. Still fixed for the life of the menu - it derives from a
# console width measured once - so a row's height cannot change under the
# animator. Twin of UI_TABLE_COL3_MAX in ui.sh.
$script:UiTableCol3Max = 90

# Split-ExakitWrap <text> <width> - greedy word wrap, returned as an array of
# lines. A word longer than the cell is BROKEN, not allowed to overhang: that is
# the one place this differs from Format-ExakitAboutWrap, which prints into open
# space where an overhang costs nothing; here it would print straight through
# the table's right border. Twin of _ui_wrap in ui.sh.
function Split-ExakitWrap {
    param([string]$Text = "", [int]$Width = 44)
    $out = New-Object 'System.Collections.Generic.List[string]'
    if ($Width -le 0 -or -not $Text) { return @() }
    $line = ""
    foreach ($word in ($Text -split '\s+' | Where-Object { $_ })) {
        $w = $word
        while ($w.Length -gt $Width) {
            if ($line) { [void]$out.Add($line); $line = "" }
            [void]$out.Add($w.Substring(0, $Width))
            $w = $w.Substring($Width)
        }
        if (-not $line) { $line = $w }
        elseif (($line.Length + 1 + $w.Length) -le $Width) { $line = "$line $w" }
        else { [void]$out.Add($line); $line = $w }
    }
    if ($line) { [void]$out.Add($line) }
    return $out.ToArray()
}

# Get-ExakitTableWidths <table> - how wide the two columns want to be, capped to
# what the console has. The name column is the widest label, the status column is
# the widest finished status, and neither is allowed to push the table past the
# screen: the name gives way first, because a truncated label is still
# recognisable while a truncated row count is a lie.
# Twin of ui_table_widths in ui.sh.
function Get-ExakitTableWidths {
    param([Parameter(Mandatory)][hashtable]$Table)
    $nameW = 10
    # A FLOOR, not a starting guess. The status column is measured from the
    # finished statuses, and while the work is still running there are none - so a
    # column sized to what it holds today would be twenty wide during the load and
    # forty when it finished, and the whole table would change width as the last
    # row completed. Wide enough for a bar worth looking at, and for
    # "completed - 8 tables, 173,745 rows (23s)".
    # The FLOOR is only reserved once the table has something to report, and
    # only for a table with OTHER columns to carry the width. While every row is
    # idle - the selection screen, before a single install has started - there
    # is no status to hold room for, and holding it anyway put a 44-column void
    # beside a description squeezed to fit around it. A name-and-status menu has
    # nothing else holding the width, so it keeps its floor: withhold Status
    # there and the box shrinks to barely wider than the longest name, then
    # doubles the moment the first row starts.
    # Twin of the same block in ui_table_widths (ui.sh).
    $statW = 44
    if ($Table.Col2 -or $Table.Col3) {
        $statW = 0
        foreach ($r in $Table.Rows.ToArray()) {
            if ($r.State -and $r.State -ne "idle" -and $r.State -ne "disabled") { $statW = 44; break }
        }
    }
    # Zero unless a heading names the column, so a table that asks for neither
    # is measured, and drawn, exactly as it was before they existed.
    $col2W = 0; $col3W = 0
    if ($Table.Col2) { $col2W = ([string]$Table.Col2).Length }
    # FIXED, never measured: the Description column wraps to fill it rather than
    # growing to fit the longest About.
    if ($Table.Col3) { $col3W = $script:UiTableCol3Fixed }
    foreach ($row in $Table.Rows.ToArray()) {
        $len = $row.Label.Length
        if ($col2W -gt 0 -and ("" + $row.Col2).Length -gt $col2W) { $col2W = ("" + $row.Col2).Length }
        # The tree connector plus its space is 3 columns of the name cell.
        if ($row.Kind -eq "tee" -or $row.Kind -eq "corner") { $len += 3 }
        if ($len -gt $nameW) { $nameW = $len }
        # Measured the way Get-ExakitTableCell RENDERS it, not as stored: a
        # finished cell is "<tick> <final>", so a column sized to the bare string
        # is short by the glyph and its space. Short means a row wider than the
        # box, which wraps, which makes the frame one line taller than the height
        # the animator moves the cursor up by.
        # Only for a row that HAS a status; an idle row's final is empty and
        # measuring it would reintroduce the column withheld above.
        if ($row.Final -and $row.State -and $row.State -ne "idle" -and $row.State -ne "disabled") {
            $finalLen = $row.Final.Length + $script:UiTick.Length + 1
            if ($finalLen -gt $statW) { $statW = $finalLen }
        }
    }
    $cols = 80
    if ([int]$Table.Cols -gt 0) { $cols = [int]$Table.Cols }
    # 2 border + 1 space + 4 checkbox + name + 2 gap + status + 1 space + 1 border
    # = 11, PLUS the two-column left margin every row is built with below and one
    # column left unwritten at the right. The margin was missing, so a table sized
    # to fit "exactly" wrote the console's last column - which wraps the row, and
    # a wrapped row is two lines where the frame counted one, so the next
    # cursor-up lands inside the frame before it and strands its top border on
    # screen. The one-line progress bar reserves its last column for this reason.
    # Columns are separated by a plain two-space gap, whatever they hold. A
    # drawn rule between them was tried here and taken out: alignment already
    # tells the eye where a column starts, and the ONE vertical the table needs
    # is the tree spine in the name column, which is a different line entirely.
    $sepW = 2
    # ONE decomposition, and the same one Write-ExakitTableFrame uses: the fixed
    # chrome, the name, then every column that follows preceded by its gap.
    # Written as "11 + name + status" with the gap folded into the 11, an extra
    # column had to add its gap AND unpick that fold - which is how the
    # no-extras table came out two columns wider than it had been.
    #
    # 9 is the chrome without that fold: 2 border + 1 space + 4 checkbox + 1
    # space + 1 border. 3 is the two-column left margin every row is drawn with
    # plus the one column left unwritten at the right.
    $statSep = 0
    if ($statW -gt 0) { $statSep = $sepW }
    $total = 9 + $nameW + 3
    if ($col2W -gt 0) { $total += $sepW + $col2W }
    if ($col3W -gt 0) { $total += $sepW + $col3W }
    $total += $statSep + $statW
    $over = $total - $cols
    # Slack, not overflow: spend it on the Description rather than leave it as a
    # gap beside an empty Status column.
    if ($over -lt 0 -and $col3W -gt 0) {
        $grow = $script:UiTableCol3Max - $col3W
        if ($grow -lt 0) { $grow = 0 }
        if ((-$over) -lt $grow) { $grow = -$over }
        $col3W += $grow
        $over += $grow
    }
    # The description gives way FIRST, and can give way entirely. It is the one
    # cell whose absence costs nothing that is not recoverable - `exakit help
    # <add-on>` is one command away - while a truncated add-on id is a name the
    # reader cannot match to anything and a squeezed bar stops reading as
    # progress. On an 80-column console this column is the first thing to go,
    # which is the intended outcome, not a failure of the layout.
    if ($over -gt 0 -and $col3W -gt 0) {
        if ($over -ge ($col3W + 2)) {
            $over -= ($col3W + 2)
            $col3W = 0
        } else {
            $col3W -= $over
            $over = 0
            if ($col3W -lt 8) { $over = 8 - $col3W; $col3W = 8 }
        }
    }
    if ($over -gt 0) {
        $nameW -= $over
        if ($nameW -lt 12) {
            # The name column has given all it can. Take the rest off the status
            # column rather than overflow: a narrow bar still reads, a wrapped row
            # does not.
            $rest = 12 - $nameW
            $nameW = 12
            $statW -= $rest
            if ($statW -lt 12) { $statW = 12 }
        }
    }
    return @{ Name = $nameW; Status = $statW; Col2 = $col2W; Col3 = $col3W; Sep = $sepW }
}

# Get-ExakitTableCell <row> <status-width> <now> - the Status column for one row,
# as ONE line. Returns the text AND how wide it reads, because only the builder
# can tell those apart once colour is in the string.
#
# A running row used to get a second line underneath carrying the phase on the
# left and an elapsed "(Ns)" on the right; it is gone, and with it the reserved
# blank line that kept the frame a constant height while no row was running. The
# bar still creeps with the clock, so the row goes on saying "alive" without a
# counter to read it off. Twin of _ui_table_cell in ui.sh.
function Get-ExakitTableCell {
    param(
        [Parameter(Mandatory)][hashtable]$Row,
        [int]$StatusWidth = 44,
        [datetime]$Now = (Get-Date)
    )
    $num = 7
    $barw = $StatusWidth - $num
    if ($barw -lt 8) { $barw = 8 }
    $cell = @{ Text = ""; Len = 0 }
    switch ($Row.State) {
        "running" {
            # The creep, inline: where the bar sits between the stage the job last
            # reported and the one it will report next, capped one point below the
            # next milestone so arriving at it is still something you see happen.
            $at = [int]$Row.Pct
            $inSeg = 0
            if ($null -ne $Row.SegT0) { $inSeg = [int]($Now - $Row.SegT0).TotalSeconds }
            if ($inSeg -lt 0) { $inSeg = 0 }
            $span = [int]$Row.Ceiling - $at
            if ($span -gt 0 -and [int]$Row.Secs -gt 0) {
                $stepped = [int][Math]::Floor($span * $inSeg / [int]$Row.Secs)
                if ($stepped -gt ($span - 1)) { $stepped = $span - 1 }
                if ($stepped -lt 0) { $stepped = 0 }
                $at = $at + $stepped
            }
            if ($at -gt 100) { $at = 100 }
            if ($at -lt 0) { $at = 0 }
            # Eighths across the whole bar, from integer percent: at forty cells
            # one percent is three eighths, so every step of the creep moves
            # something on screen.
            #
            # Floor, not [int]: a PowerShell cast ROUNDS (and rounds .5 to even),
            # so 12 eighths became 2 whole cells plus a 4/8 frontier - a bar one
            # cell ahead of the number beside it. The shell twin divides in
            # integers, and this has to agree with it cell for cell.
            $units = [int][Math]::Floor($at * $barw * 8 / 100)
            $full = [int][Math]::Floor($units / 8)
            $rem = $units % 8
            if ($full -gt $barw) { $full = $barw; $rem = 0 }
            $head = ""
            if ($script:UiFancy -and $full -lt $barw -and $rem -gt 0) { $head = $script:UiProgressEighths[$rem] }
            $empty = $barw - $full - $head.Length
            if ($empty -lt 0) { $empty = 0 }
            $pctText = "$at%"
            $cell.Text = $script:UiAccent + ($script:UiBarFull * $full) + $script:UiDim + $head +
                ($script:UiBarEmpty * $empty) + $script:UiReset + $pctText.PadLeft($num)
            $cell.Len = $barw + $num
        }
        "waiting" {
            $cell.Text = $script:UiDim + "waiting" + $script:UiReset
            $cell.Len = 7
        }
        "done" {
            $cell.Text = $script:UiOk + $script:UiTick + $script:UiReset + " " + $Row.Final
            $cell.Len = $script:UiTick.Length + 1 + ("" + $Row.Final).Length
        }
        "failed" {
            $cell.Text = $script:UiErr + $script:UiCross + $script:UiReset + " " + $Row.Final
            $cell.Len = $script:UiCross.Length + 1 + ("" + $Row.Final).Length
        }
        "disabled" {
            # No glyph: not an outcome of anything that ran, a standing fact
            # about the row. ONLY where a Status column exists - a disabled row
            # does not count as a status for width purposes, which is what lets
            # the selection screen drop the column, so filling the cell there
            # drew into a column of width zero and pushed the row past its own
            # border. On that screen the same word is in Description.
            if ($StatusWidth -gt 0) {
                $cell.Text = $script:UiDim + $Row.Final + $script:UiReset
                $cell.Len = ("" + $Row.Final).Length
            }
        }
    }
    return $cell
}

# Get-ExakitTableFrame <table> [cursor] - the whole table as ONE string, with its
# height left in $Table.Lines. One write is what keeps a redraw from flickering,
# and a string is what lets the caller do the clear and the draw in that one
# write. Twin of ui_table_frame in ui.sh.
function Get-ExakitTableFrame {
    param([Parameter(Mandatory)][hashtable]$Table, [int]$Cursor = 0)
    $w = Get-ExakitTableWidths -Table $Table
    $nameW = [int]$w.Name
    $statW = [int]$w.Status
    $col2W = [int]$w.Col2
    $col3W = [int]$w.Col3
    # A plain gap between columns. Rules were drawn here once and removed: they
    # boxed every wrapped description into a cage, and they competed with the
    # one line that carries meaning -- the tree spine down the name column.
    $sepW = [int]$w.Sep
    if ($sepW -lt 2) { $sepW = 2 }
    $sep = "  "
    # No Status column at all while nothing has a status: no heading, no rule,
    # no reserved width. $statSep is the rule before it, which goes with it.
    $statSep = ""
    $statSepW = 0
    if ($statW -gt 0) { $statSep = $sep; $statSepW = $sepW }
    # The same decomposition Get-ExakitTableWidths uses: 5 of chrome, the name,
    # then every column that follows preceded by its rule, and one trailing.
    $inner = 5 + $nameW + 1
    if ($col2W -gt 0) { $inner += $sepW + $col2W }
    if ($col3W -gt 0) { $inner += $sepW + $col3W }
    $inner += $statSepW + $statW
    $lines = New-Object 'System.Collections.Generic.List[string]'

    $title = " " + $Table.Title + " "
    $fill = $inner - $title.Length - 1
    if ($fill -lt 0) { $fill = 0 }
    [void]$lines.Add("  " + $script:UiAccent + $script:UiTL + $script:UiHr + $script:UiReset +
        $script:UiBold + $title + $script:UiReset + $script:UiAccent + ($script:UiHr * $fill) +
        $script:UiTR + $script:UiReset)

    # The first column is named by its caller: the dataset load fills it with
    # datasets, the MCP step with AI clients, the marketplace with add-ons. Its
    # width is $nameW, whose floor is 10, so any short heading pads without going
    # negative. A table built before Col1 existed still says "Dataset".
    $col1 = "" + $Table.Col1
    if (-not $col1) { $col1 = "Dataset" }
    $headPad = $nameW - $col1.Length
    if ($headPad -lt 0) { $headPad = 0 }
    $head = "     " + $col1 + (" " * $headPad)
    $headLen = 5 + $nameW
    # Headings are clamped the same way their cells are, so a column squeezed by
    # a narrow console never prints a heading wider than the column under it.
    if ($col2W -gt 0) {
        $h2 = "" + $Table.Col2
        if ($h2.Length -gt $col2W) { $h2 = $h2.Substring(0, $col2W) }
        $head += $sep + $h2 + (" " * ($col2W - $h2.Length))
        $headLen += $sepW + $col2W
    }
    if ($col3W -gt 0) {
        $h3 = "" + $Table.Col3
        if ($h3.Length -gt $col3W) { $h3 = $h3.Substring(0, $col3W) }
        $head += $sep + $h3 + (" " * ($col3W - $h3.Length))
        $headLen += $sepW + $col3W
    }
    if ($statW -gt 0) {
        $head += $statSep + "Status"
        $headLen += $statSepW + 6
    }
    # Padded from the LENGTH COUNTED ABOVE, never from $head.Length: the rules
    # carry colour escapes, so the string is longer than it reads.
    $headTail = $inner - $headLen
    if ($headTail -lt 0) { $headTail = 0 }
    [void]$lines.Add("  " + $script:UiAccent + $script:UiVB + $script:UiReset + $head +
        (" " * $headTail) + $script:UiAccent + $script:UiVB + $script:UiReset)

    $now = Get-Date
    $i = 0
    foreach ($row in $Table.Rows.ToArray()) {
        $i++
        $conn = ""
        $spine = $false
        if ($row.Kind -eq "tee") { $conn = $script:UiTee + " "; $spine = $true }
        elseif ($row.Kind -eq "corner") { $conn = $script:UiCorner + " " }
        # A row nobody can pick: no checkbox at all (an empty one invites the
        # reader to try), and the note reads straight on from the label -
        # "Cursor - not installed" is one sentence. Putting the note in the Status
        # column instead would size that column, and the columns would then be
        # measured for text that is neither a name nor a status. The 5-space
        # indent is the width of the pointer and checkbox it replaces, so the tree
        # connectors still line up. Twin of the same branch in ui_table_frame.
        # A row nobody can pick keeps its COLUMNS. It used to merge into one
        # sentence - "json-tables - Installed (0.2)" - which put a version in the
        # middle of a name while the Version column beside it sat empty. Three
        # spaces stand in for "[ ]" so the tree connectors still line up.
        if ($row.Tick) {
            # A plain "x", not the palette tick, when there is no colour: the
            # plain-palette tick is itself a marker and a checkbox is already
            # brackets. Read-ExakitCheckboxMenu makes the same substitution.
            if ($script:UiFancy) { $mark = $script:UiTick } else { $mark = "x" }
            $box = $script:UiOk + "[" + $mark + "]" + $script:UiReset
            $boxLen = 2 + $mark.Length
        } else {
            $box = "[ ]"
            $boxLen = 3
        }
        if ($row.State -eq "disabled") { $box = "   "; $boxLen = 3 }
        if ($i -eq $Cursor) {
            if ($script:UiFancy) { $ptr = $script:UiAccent + "❯" + $script:UiReset } else { $ptr = ">" }
        } else {
            $ptr = " "
        }
        # A row nobody can pick never takes the cursor either.
        if ($row.State -eq "disabled") { $ptr = " " }
        # MEASURED plain, PRINTED possibly dim: a disabled row's name carries
        # colour escapes, and .Length would count those as width.
        $plain = $conn + $row.Label
        if ($plain.Length -gt $nameW) { $plain = $plain.Substring(0, $nameW - 1) + "…" }
        $nameLen = $plain.Length
        if ($row.State -eq "disabled") { $name = $script:UiDim + $plain + $script:UiReset }
        else { $name = $plain }
        $namePad = $nameW - $nameLen
        if ($namePad -lt 0) { $namePad = 0 }
        $cell = Get-ExakitTableCell -Row $row -StatusWidth $statW -Now $now
        # The optional cells, dim so the eye still lands on the name and the
        # status. Truncated to their own column; every string here is one this
        # file assembled, so its width is arithmetic, never measured.
        $mid = ""
        $used = 1 + $boxLen + 1 + $nameW + $statSepW + [int]$cell.Len
        if ($col2W -gt 0) {
            $v2 = "" + $row.Col2
            if ($v2.Length -gt $col2W) { $v2 = $v2.Substring(0, $col2W - 1) + "…" }
            $mid += $sep + $script:UiDim + $v2 + $script:UiReset + (" " * ($col2W - $v2.Length))
            $used += $col2W + $sepW
        }
        # The Description is never truncated. It wraps to as many lines as it
        # needs; the first sits on the row, the rest follow underneath with every
        # other cell blank, so the column stays a column. An About is written for
        # a repository page, and an ellipsis throws away the half that says what
        # the tool is for.
        $wrapped = @()
        if ($col3W -gt 0) {
            $wrapped = @(Split-ExakitWrap -Text ("" + $row.Col3) -Width $col3W)
            $v3 = ""
            if ($wrapped.Count -gt 0) { $v3 = $wrapped[0] }
            $mid += $sep + $script:UiDim + $v3 + $script:UiReset + (" " * ($col3W - $v3.Length))
            $used += $col3W + $sepW
        }
        $tail = $inner - $used
        if ($tail -lt 0) { $tail = 0 }
        [void]$lines.Add("  " + $script:UiAccent + $script:UiVB + $script:UiReset + $ptr + $box + " " +
            $name + (" " * $namePad) + $mid + $statSep + $cell.Text + (" " * $tail) +
            $script:UiAccent + $script:UiVB + $script:UiReset)
        # The rest of a wrapped description. Only the Description cell carries
        # anything: the checkbox, the name and the version belong to the row
        # above, and repeating them would read as more rows than there are.
        #
        # These lines make the frame taller than one line per row, which the
        # redraw can afford because the height is still the SAME on every
        # redraw: an About and the column it wraps to are both fixed for the life
        # of the menu, so a row's height cannot change under it. That is exactly
        # what the phase sub-line could not promise - it appeared and vanished as
        # a row started and stopped running, which is why it needed a reserved
        # blank line and why it is gone.
        if ($wrapped.Count -gt 1) {
            # The TREE SPINE carries down the continuation lines. Without it the
            # connector column goes blank for as long as a description wraps, and
            # the line joining the add-ons snaps in half -- the same menu draws
            # an unbroken spine while it installs, where every row is one line,
            # so a description must not be what breaks it. Only a tee continues:
            # after the corner the tree has ended and a spine below it would
            # point at nothing. Built cell by cell and MEASURED as it goes, so
            # the width is arithmetic rather than a count of escape bytes.
            if ($spine) {
                $wleft = (" " * 5) + $script:UiVB + (" " * ($nameW - 1))
            } else {
                $wleft = " " * (5 + $nameW)
            }
            $wlen = 5 + $nameW
            if ($col2W -gt 0) {
                $wleft += $sep + (" " * $col2W)
                $wlen += $sepW + $col2W
            }
            $wlen += $sepW + $col3W + $statSepW
            $wpad = $inner - $wlen
            if ($wpad -lt 0) { $wpad = 0 }
            for ($k = 1; $k -lt $wrapped.Count; $k++) {
                $wl = $wrapped[$k]
                [void]$lines.Add("  " + $script:UiAccent + $script:UiVB + $script:UiReset +
                    $wleft + $sep + $script:UiDim + $wl + $script:UiReset +
                    (" " * ($col3W - $wl.Length)) + $statSep + (" " * $wpad) +
                    $script:UiAccent + $script:UiVB + $script:UiReset)
            }
        }
    }

    # The frame is still ONE height in every state, and now structurally so
    # rather than by arrangement: every row is exactly one line whatever it is
    # doing, so there is nothing left to reserve. That property is what the
    # redraw depends on - a frame that grows by a line pushes the console to
    # scroll, and once the screen has scrolled a cursor-up by the frame height no
    # longer lands at the frame's top. Every redraw after that is off by one and
    # the error accumulates, which is what strands the top of an old frame above
    # the new one near the bottom of a screen.
    [void]$lines.Add("  " + $script:UiAccent + $script:UiBL + ($script:UiHr * $inner) +
        $script:UiBR + $script:UiReset)

    $Table.Lines = $lines.Count
    # Recorded for Update-ExakitTable: while the geometry is unchanged it can
    # overwrite the frame in place instead of erasing the region first, and the
    # only two things that can make an overwrite leave something stale behind are
    # a change in height or a change in width.
    $Table.Width = $inner
    return ($lines -join "`r`n")
}

# Show-ExakitTable [-Table] [-Cursor] - the frame, printed. CRLF between rows on
# purpose: with VT processing on, a bare LF is a strict line feed that keeps the
# column, so a frame joined with "`n" would draw itself down a staircase.
# Twin of ui_table_render in ui.sh.
function Show-ExakitTable {
    param([hashtable]$Table = $null, [int]$Cursor = 0)
    if ($null -eq $Table) { $Table = $script:UiTable }
    if ($null -eq $Table) { return }
    $frame = Get-ExakitTableFrame -Table $Table -Cursor $Cursor
    # Every frame in this file starts with a carriage return - see
    # Update-ExakitTable for why an indented frame is not a cosmetic problem.
    try { [Console]::Write("`r" + $frame + "`r`n") } catch { }
}

# Update-ExakitTable [-Table] [-Cursor] - replace the frame already on screen
# with a new one, in ONE write. Twin of ui_table_redraw in ui.sh.
#
# OVERWRITTEN, not cleared and redrawn. [0J erases from the cursor to the end of
# the screen, so a clear-then-write leaves the region genuinely empty for the
# instant between the two - and five times a second that reads as the table
# flickering: something, nothing, something. Every line of a frame is padded to
# the box width, so while the geometry is identical an overwrite cannot leave a
# single stale character behind and the erase buys nothing.
#
# The erase is kept for the case where the geometry DID change - a resized
# console, or the first frame after the selection menu, which is one line taller
# because of the hint under it. Then old content really is left over and has to
# go.
function Update-ExakitTable {
    param([hashtable]$Table = $null, [int]$Cursor = 0)
    if ($null -eq $Table) { $Table = $script:UiTable }
    if ($null -eq $Table) { return }
    # Both halves of the PREVIOUS draw's geometry, read before the new frame
    # overwrites them on the table.
    $prev = [int]$Table.Lines
    if ($prev -lt 0) { $prev = 0 }
    $prevWidth = [int]$Table.Width
    $frame = Get-ExakitTableFrame -Table $Table -Cursor $Cursor
    $same = ($prev -eq [int]$Table.Lines -and $prevWidth -eq [int]$Table.Width)
    # The leading `r is not decoration either. Cursor-up PRESERVES the column, so
    # a cursor left mid-row by anything that printed without a newline - a spinner
    # frame, a progress line - makes the whole frame draw from that column, and
    # [0J clears only from there rightwards. What is left on screen is the first N
    # columns of the old frame with a new one starting inside it: several top
    # borders side by side on one line, at different widths. Twin of the same
    # carriage return in ui_table_redraw.
    try {
        if ($prev -le 0) {
            [Console]::Write("`r" + $frame + "`r`n")
        } elseif ($same) {
            [Console]::Write("`r$($script:UiEsc)[${prev}A" + $frame + "`r`n")
        } else {
            [Console]::Write("`r$($script:UiEsc)[${prev}A$($script:UiEsc)[0J" + $frame + "`r`n")
        }
    } catch { }
}

# Set-ExakitTableRow -Row <n> -State <state> [-Pct] [-Ceiling] [-Secs] [-Phase]
# [-Final] - one row has changed. Twin of ui_table_set in ui.sh.
function Set-ExakitTableRow {
    param(
        [Parameter(Mandatory)][int]$Row,
        [Parameter(Mandatory)][ValidateSet("idle", "waiting", "running", "done", "failed")][string]$State,
        [int]$Pct = 0, [int]$Ceiling = 0, [int]$Secs = 0,
        [string]$Phase = "", [string]$Final = "",
        [hashtable]$Table = $null
    )
    if ($null -eq $Table) { $Table = $script:UiTable }
    if ($null -eq $Table) { return }
    if ($Row -lt 1 -or $Row -gt $Table.Rows.Count) { return }
    $r = $Table.Rows[$Row - 1]
    # A row that was already running keeps its clock: a new PHASE inside the same
    # job must not restart the elapsed count the reader is watching. Only entering
    # "running" starts one.
    if ($State -eq "running") {
        if ($r.State -ne "running" -or $null -eq $r.SegT0) { $r.SegT0 = Get-Date }
    } else {
        $r.SegT0 = $null
    }
    $r.State = $State
    $r.Pct = $Pct
    $r.Ceiling = $Ceiling
    $r.Secs = $Secs
    $r.Phase = $Phase
    $r.Final = $Final
}

# Set-ExakitTableTicks -Rows <n[]> - mark which rows are ticked, and only those.
# Twin of ui_table_tick in ui.sh.
function Set-ExakitTableTicks {
    param([int[]]$Rows = @(), [hashtable]$Table = $null)
    if ($null -eq $Table) { $Table = $script:UiTable }
    if ($null -eq $Table) { return }
    for ($i = 1; $i -le $Table.Rows.Count; $i++) {
        $r = $Table.Rows[$i - 1]
        $on = [bool]($Rows -contains $i)
        # A disabled row can never carry a tick, whoever asked. Select All spans a
        # range that may contain one, and the defaults are built by the caller -
        # this is the one place both of those pass through.
        if ($r.State -eq "disabled") { $on = $false }
        $r.Tick = $on
    }
}

# Disable-ExakitTableRow -Row <n> -Note <text> - that row can be read but never
# picked: drawn dim with no checkbox and the note reading on from the label
# ("Cursor - not installed"), skipped by the cursor, by Space and by Select All.
#
# It exists so a menu can show the WHOLE set of options and say why the ones it
# cannot offer are missing. The MCP client list is the case: a list that quietly
# omitted the clients this machine does not have would read as "the kit supports
# four clients", and the reader has no way to tell a short list from a filtered
# one. The note is the answer to the question the row raises.
# Twin of ui_table_disable in ui.sh.
function Disable-ExakitTableRow {
    param(
        [Parameter(Mandatory)][int]$Row,
        [string]$Note = "",
        [hashtable]$Table = $null
    )
    if ($null -eq $Table) { $Table = $script:UiTable }
    if ($null -eq $Table) { return }
    if ($Row -lt 1 -or $Row -gt $Table.Rows.Count) { return }
    $r = $Table.Rows[$Row - 1]
    $r.State = "disabled"
    $r.Tick = $false
    # The note goes in the FINAL field: it is what this row has to say for
    # itself, which is exactly what that field is for.
    $r.Final = $Note
    $r.SegT0 = $null
}

# Start-ExakitTable [-Table] - animate the table in place. Returns $false when it
# did not start (no console, no colour, something already animating), which is the
# caller's cue to narrate in plain lines instead. Twin of ui_table_begin in ui.sh.
function Start-ExakitTable {
    param([hashtable]$Table = $null)
    if ($null -eq $Table) { $Table = $script:UiTable }
    if ($null -eq $Table) { return $false }
    if (-not $script:UiFancy) { return $false }
    if ($script:UiTableLive) { return $false }
    # ONE animation at a time: a spinner and a table redrawing the same rows
    # produce a flicker, and the loser's handle is lost the moment the winner
    # overwrites it.
    #
    # STOPPED, not refused. Start-ExakitSpinner takes a nesting reference when
    # something is already animating; this cannot, because the table REPLACES the
    # step's narration - and refusing here meant the table was drawn and then
    # never redrawn, which every caller reads as "no console" and answers by
    # falling back to plain lines. Nor may the spinner simply be abandoned: an
    # orphaned spinner keeps printing its own line without a trailing newline
    # every 90ms, which leaves the cursor mid-row for the frame that follows, and
    # cursor-up preserves the column (see Update-ExakitTable). The nesting count
    # is zeroed first because Stop-ExakitSpinner gives back a reference instead of
    # stopping while one is outstanding. Twin of the same block in ui_table_begin.
    if ($null -ne $script:UiSpinFlag) {
        $script:UiSpinNested = 0
        try { Stop-ExakitSpinner } catch { }
    }
    $src = $script:UiTableSrcText
    if (-not $src -and $script:UiTableSrc) {
        try { $src = [System.IO.File]::ReadAllText($script:UiTableSrc) } catch { $src = "" }
    }
    if (-not $src) { return $false }
    try {
        $Table.Run = $true
        $Table.Stop = $false
        $Table.Alive = $false
        # Measured ONCE. A console resized mid-load keeps the width it started
        # with, which is a fair trade for not measuring five times a second.
        try { $Table.Cols = [Console]::WindowWidth } catch { }
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('tbl', $Table)
        $rs.SessionStateProxy.SetVariable('uiSrc', $src)
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            # This file's own frame builder and palette, so there is exactly one
            # of each. Forced fancy: the only way to reach here is for the parent
            # to have been fancy, and the runspace's own detection has no console
            # of its own to ask.
            . ([scriptblock]::Create($uiSrc))
            $script:UiFancy = $true
            Set-ExakitPalette
            while ($tbl.Run) {
                # ONE frame, ONE write. Rendered straight to the console, a stop
                # could land between two of a frame's rows: the cursor would then
                # be part-way through a table nobody had finished, and the next
                # cursor-up by a frame height would land INSIDE it and clear from
                # there - which strands the top of a table on screen with the
                # final one printed under it.
                Update-ExakitTable -Table $tbl -Cursor 0
                $tbl.Alive = $true
                # Asked to stop: finish the frame that is on screen and go, so the
                # parent inherits a cursor sitting at a frame boundary.
                if ($tbl.Stop) { break }
                Start-Sleep -Milliseconds 200
            }
        })
        try { [Console]::Write("$($script:UiEsc)[?25l") } catch { }
        $handle = $ps.BeginInvoke()
        # Wait for the FIRST FRAME before claiming the screen. An animator that
        # never painted would leave the loaders silent underneath it (they stop
        # narrating precisely because the table is supposed to be narrating), and
        # that reads from the outside as a data load that hung.
        $waited = 0
        while (-not $Table.Alive -and $waited -lt 80) {
            Start-Sleep -Milliseconds 25
            $waited++
        }
        if (-not $Table.Alive) {
            $Table.Run = $false
            try { $ps.Stop(); $ps.Dispose() } catch { }
            try { $rs.Close(); $rs.Dispose() } catch { }
            try { [Console]::Write("$($script:UiEsc)[?25h") } catch { }
            return $false
        }
        $script:UiTablePs = $ps
        $script:UiTableRs = $rs
        $script:UiTableHandle = $handle
        $script:UiTableLive = $true
        # The table now owns the animation slot, so every Start-ExakitSpinner and
        # Start-ExakitProgress underneath it takes a reference instead of painting
        # (see their guards) and gives it back on its own Stop.
        $script:UiSpinNested = 0
        return $true
    } catch {
        $script:UiTableLive = $false
        $script:UiTablePs = $null
        $script:UiTableRs = $null
        $script:UiTableHandle = $null
        return $false
    }
}

# Stop-ExakitTable [-Table] - stop animating and leave the FINAL table on screen.
# Safe to call when nothing is animating. Twin of ui_table_end in ui.sh.
function Stop-ExakitTable {
    param([hashtable]$Table = $null)
    if ($null -eq $Table) { $Table = $script:UiTable }
    if (-not $script:UiTableLive) { return }
    $script:UiTableLive = $false
    # ASKED to stop, not shot. The animator finishes the frame it is drawing and
    # exits, which is the only way the cursor is guaranteed to be at a frame
    # boundary when this function starts counting lines. A Stop() is still the
    # backstop for an animator that has somehow wedged.
    if ($null -ne $Table) { $Table.Stop = $true }
    $waited = 0
    while ($waited -lt 30) {
        $busy = $false
        try { if ($null -ne $script:UiTableHandle -and -not $script:UiTableHandle.IsCompleted) { $busy = $true } } catch { }
        if (-not $busy) { break }
        Start-Sleep -Milliseconds 50
        $waited++
    }
    if ($null -ne $Table) { $Table.Run = $false }
    try { if ($null -ne $script:UiTablePs) { $script:UiTablePs.Stop(); $script:UiTablePs.Dispose() } } catch { }
    try { if ($null -ne $script:UiTableRs) { $script:UiTableRs.Close(); $script:UiTableRs.Dispose() } } catch { }
    $script:UiTablePs = $null
    $script:UiTableRs = $null
    $script:UiTableHandle = $null
    $script:UiSpinNested = 0
    try { [Console]::Write("$($script:UiEsc)[?25h") } catch { }
    # The animator can be stopped part-way through a frame, so the last thing
    # drawn is redrawn deliberately rather than trusted.
    if ($null -ne $Table) { Update-ExakitTable -Table $Table -Cursor 0 }
}

# Stop-ExakitAnimation - stop whatever this session is animating, table or
# spinner, before printing something the reader must not lose. Fail() calls this
# first for exactly that reason.
#
# Twin of ui_animation_stop in ui.sh, and it does ui_table_abort's job too: bash
# needs a separate abort because a trap can only name a function and cannot be
# handed the state file, while here the live table is module state that one entry
# point can always find.
function Stop-ExakitAnimation {
    if ($script:UiTableLive) { Stop-ExakitTable }
    else { try { Stop-ExakitSpinner } catch { } }
    Restore-ExakitCursor
}

# Invoke-ExakitTableMenu - the SELECTION phase of the same table: ticks are
# toggled in the rows the progress will later fill in, so the reader never has to
# map one screen onto another. Returns the selected 1-based row numbers, ascending.
#
# The key handling is Read-ExakitCheckboxMenu's, deliberately: same keys, same
# hint, same group and exclusive semantics, so there is one thing to learn.
# Twin of ui_table_menu in ui.sh.
#
# -OnScreen (optional): how many lines of this table - frame plus anything
# printed under it - are ALREADY on screen, so a re-ask overwrites them instead
# of drawing a second table below them. The MCP step passes it when an
# unconfirmed "Skip" sends the reader back to the menu. Twin of
# UI_TABLE_MENU_ONSCREEN.
function Invoke-ExakitTableMenu {
    param(
        [hashtable]$Table = $null,
        [int[]]$Defaults = @(),
        [int]$ExclusiveIndex = 0,
        [int]$GroupParent = 0, [int]$GroupFirst = 0, [int]$GroupLast = 0,
        [string]$GroupMode = "any",
        [int]$OnScreen = 0
    )
    if ($null -eq $Table) { $Table = $script:UiTable }
    if ($null -eq $Table) { return @() }
    $n = $Table.Rows.Count
    if ($n -lt 1) { return @() }
    $sel = New-Object 'System.Collections.Generic.List[int]'
    foreach ($d in $Defaults) {
        if ($d -ge 1 -and $d -le $n -and -not $sel.Contains($d)) { [void]$sel.Add($d) }
    }
    # Which rows can be ticked at all. A disabled row is drawn but never
    # selectable: the cursor steps over it, Space ignores it, and Select All
    # leaves it alone - that last one because $applyGroup below walks only the
    # pickable children, so there is no second rule to keep in step.
    $pickable = New-Object 'System.Collections.Generic.List[int]'
    for ($i = 1; $i -le $n; $i++) {
        if ($Table.Rows[$i - 1].State -ne "disabled") { [void]$pickable.Add($i) }
    }
    # Move the cursor, stepping over the rows nobody can pick. Returns the new row
    # rather than assigning it: a scriptblock runs in a child scope, so an
    # assignment in here would never reach the caller's $cur.
    $step = {
        param($from, $dir)
        $at = $from
        $tries = 0
        while ($tries -lt $n) {
            $at = $at + $dir
            if ($at -lt 1) { $at = $n }
            if ($at -gt $n) { $at = 1 }
            if ($pickable.Contains($at)) { return $at }
            $tries++
        }
        return $from
    }

    # Interactivity is decided the way Test-ExakitInteractive decides it, inlined:
    # this file is also dot-sourced on its own by install.ps1, where the shared
    # library does not exist yet.
    $interactive = $true
    try {
        if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) { $interactive = $false }
    } catch { $interactive = $false }
    # CONFIRMED means a human pressed Enter on this table - nothing else. A
    # caller about to INSTALL things needs the distinction: the defaults
    # standing without a console is right for the data-load and MCP menus, and
    # wrong for one whose defaults are "everything". Twin of
    # EXAKIT_TABLE_CONFIRMED in ui.sh.
    $script:ExakitTableConfirmed = $false
    if (-not $interactive -or -not $script:UiFancy) {
        # No console to answer with: the defaults stand, and the table is printed
        # once so a log still shows what was chosen.
        Set-ExakitTableTicks -Rows @($sel) -Table $Table
        Show-ExakitTable -Table $Table -Cursor 0
        return @($sel | Sort-Object)
    }

    # Toggling the group parent ON selects every child, OFF clears them all;
    # toggling a child re-derives the parent per $GroupMode - "all" makes it a
    # MASTER toggle (checked only while EVERY child is), "any" a group header.
    $applyGroup = {
        param($toggled)
        if ($GroupParent -lt 1 -or $GroupFirst -lt 1 -or $GroupLast -lt $GroupFirst) { return }
        if ($toggled -eq $GroupParent) {
            $parentOn = $sel.Contains($GroupParent)
            for ($c = $GroupFirst; $c -le $GroupLast; $c++) {
                if ($c -lt 1 -or $c -gt $n) { continue }
                # A disabled row can sit inside the range (a group spans a small
                # tree), so Select All has to step over it rather than tick it.
                if (-not $pickable.Contains($c)) { [void]$sel.Remove($c); continue }
                if ($parentOn) { if (-not $sel.Contains($c)) { [void]$sel.Add($c) } }
                else { [void]$sel.Remove($c) }
            }
        } elseif ($toggled -ge $GroupFirst -and $toggled -le $GroupLast) {
            $on = $false
            if ($GroupMode -eq "all") {
                $on = $true
                for ($c = $GroupFirst; $c -le $GroupLast; $c++) {
                    if ($c -lt 1 -or $c -gt $n) { continue }
                    # ...and the all-children rule must not wait for one either,
                    # or a machine missing one client could never tick Select All.
                    if (-not $pickable.Contains($c)) { continue }
                    if (-not $sel.Contains($c)) { $on = $false; break }
                }
            } else {
                for ($c = $GroupFirst; $c -le $GroupLast; $c++) {
                    if ($c -lt 1 -or $c -gt $n) { continue }
                    if (-not $pickable.Contains($c)) { continue }
                    if ($sel.Contains($c)) { $on = $true; break }
                }
            }
            if ($on) { if (-not $sel.Contains($GroupParent)) { [void]$sel.Add($GroupParent) } }
            else { [void]$sel.Remove($GroupParent) }
        }
    }
    # An option that cannot be combined with the others - think "Skip". Selecting
    # it clears every other choice; selecting any other choice clears it.
    $applyExclusive = {
        param($toggled)
        if ($ExclusiveIndex -lt 1) { return }
        if ($toggled -eq $ExclusiveIndex) {
            if ($sel.Contains($ExclusiveIndex)) { $sel.Clear(); [void]$sel.Add($ExclusiveIndex) }
        } elseif ($sel.Contains($ExclusiveIndex)) {
            [void]$sel.Remove($ExclusiveIndex)
        }
    }

    # The cursor starts on the FIRST DATASET, not on the "Select All" row above
    # it: the group row is the one answer nobody has to move to - and never on a
    # row that cannot be picked, or the first Space would land on one.
    $cur = 1
    if ($n -ge 2) { $cur = [int](& $step $cur 1) }
    if (-not $pickable.Contains($cur)) { $cur = [int](& $step $cur 1) }
    # Normally nothing of this table is on screen yet; a re-ask says otherwise.
    $drawn = 0
    if ($OnScreen -gt 0) { $drawn = $OnScreen }
    while ($true) {
        Set-ExakitTableTicks -Rows @($sel) -Table $Table
        # Built first, then written in ONE write. The other order - clear, then
        # spend time assembling - is what flickered: the region was genuinely
        # empty for that whole time.
        $drawnWidth = [int]$Table.Width
        $frame = Get-ExakitTableFrame -Table $Table -Cursor $cur
        $hint = "      " + $script:UiDim + "↑/↓ to move · Space to toggle · Enter to confirm" + $script:UiReset
        # Overwritten in place while the geometry is unchanged, and only erased
        # when it is not - the same rule as Update-ExakitTable, for the same
        # reason: [0J empties the region for the instant before the new frame
        # lands, and on a keypress-driven redraw that is a visible blank flash.
        # The hint is a constant, so its own line is always exactly as long.
        #
        # ...and from column 0, like every other frame this file writes: cursor-up
        # preserves the column, so a cursor left mid-row would indent the frame and
        # an erase would spare the first N columns of the one before it.
        $sameGeom = ($drawn -eq ([int]$Table.Lines + 1) -and $drawnWidth -eq [int]$Table.Width)
        if ($drawn -le 0) {
            [Console]::Write("`r" + $frame + "`r`n" + $hint + "`r`n")
        } elseif ($sameGeom) {
            [Console]::Write("`r$($script:UiEsc)[${drawn}A" + $frame + "`r`n" + $hint + "`r`n")
        } else {
            [Console]::Write("`r$($script:UiEsc)[${drawn}A$($script:UiEsc)[0J" + $frame + "`r`n" + $hint + "`r`n")
        }
        $drawn = [int]$Table.Lines + 1
        $key = [Console]::ReadKey($true)
        $confirmed = $false
        $handled = $true
        switch ($key.Key) {
            "Enter"     { if ($sel.Count -gt 0) { $confirmed = $true; $script:ExakitTableConfirmed = $true } }
            "Spacebar"  {
                # A row that cannot be picked cannot be toggled either. The cursor
                # never rests on one, so this catches only the keypress that
                # arrives before the cursor has moved at all.
                if ($pickable.Contains($cur)) {
                    if ($sel.Contains($cur)) { [void]$sel.Remove($cur) } else { [void]$sel.Add($cur) }
                    & $applyGroup $cur
                    & $applyExclusive $cur
                }
            }
            "UpArrow"   { $cur = [int](& $step $cur (-1)) }
            "DownArrow" { $cur = [int](& $step $cur 1) }
            default     { $handled = $false }
        }
        if (-not $handled) {
            switch -Regex ([string]$key.KeyChar) {
                '^[kK]$' { $cur = [int](& $step $cur (-1)) }
                '^[jJ]$' { $cur = [int](& $step $cur 1) }
            }
        }
        if ($confirmed) { break }
    }
    # Redraw once without the pointer or the hint: the selection is made, and the
    # same table is about to become the progress display. $drawn counts the hint
    # line too, so this erases it.
    Set-ExakitTableTicks -Rows @($sel) -Table $Table
    $Table.Lines = $drawn
    Update-ExakitTable -Table $Table -Cursor 0
    return @($sel | Sort-Object)
}

# Render the install banner + plan (used by install.ps1 after download).
function Write-ExakitInstallPlan {
    param([string]$Platform, [string]$Database, [string]$KitDir, [string]$StateDir)
    # Banner only: the old "Installation plan" panel repeated internals users
    # don't act on. Whether this machine can run the kit is answered by the
    # compatibility checks that follow, which fail or warn explicitly.
    Write-ExakitBanner "Personal Local Starter Kit"
    Write-Host ""
}
