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
    } else {
        $script:UiTick="+"; $script:UiCross="x"; $script:UiBullet="-"; $script:UiArrow=">"
        $script:UiHr="-"; $script:UiTL="+"; $script:UiTR="+"; $script:UiBL="+"; $script:UiBR="+"; $script:UiVB="|"
        $script:UiTee="|-"; $script:UiCorner='`-'
        $script:UiBarFull="#"; $script:UiBarEmpty="."
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
function Get-ExakitTilde([string]$Path) {
    if (-not $Path) { return $Path }
    $h = $HOME
    if ($h -and $Path.StartsWith($h)) { return "~" + $Path.Substring($h.Length) }
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

function Start-ExakitSpinner([string]$Label) {
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
    if ($null -eq $script:UiSpinFlag) { return }
    try { $script:UiSpinFlag.Run = $false; Start-Sleep -Milliseconds 110 } catch { }
    try { if ($script:UiSpinPs) { $script:UiSpinPs.Stop(); $script:UiSpinPs.Dispose() } } catch { }
    try { if ($script:UiSpinRs) { $script:UiSpinRs.Close(); $script:UiSpinRs.Dispose() } } catch { }
    $script:UiSpinPs = $null; $script:UiSpinRs = $null; $script:UiSpinFlag = $null
    try { [Console]::Write("`r$($script:UiEsc)[K$($script:UiEsc)[?25h") } catch { }  # clear line, restore cursor
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

# Render the install banner + plan (used by install.ps1 after download).
function Write-ExakitInstallPlan {
    param([string]$Platform, [string]$Database, [string]$KitDir, [string]$StateDir)
    # Banner only: the old "Installation plan" panel repeated internals users
    # don't act on. Whether this machine can run the kit is answered by the
    # compatibility checks that follow, which fail or warn explicitly.
    Write-ExakitBanner "Personal Local Starter Kit"
    Write-Host ""
}
