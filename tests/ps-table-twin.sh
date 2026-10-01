#!/usr/bin/env bash
# ps-table-twin.sh — the live datasets table exists on BOTH sides.
#
#   bash tests/ps-table-twin.sh
#
# setup/lib/ui.sh and setup/lib/ui.ps1 are documented twins, and the table is
# the component that arrived on the shell side first: for a while Windows still
# printed a line per dataset while macOS and WSL showed one persistent table.
# This pins the port so the two cannot drift apart again by omission —
# ui_table_* gaining a member with no PowerShell peer fails here.
#
# There is no pwsh on most dev boxes (CI's Linux runner has one), so this is a
# STATIC guard: names, wiring, the glyph rule, and a brace/paren/string balance
# check over every .ps1 — which is the one class of PowerShell mistake that is
# otherwise invisible until a Windows install fails to parse.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fails=0
checks=0

pass() { checks=$((checks + 1)); printf 'ok   %s\n' "$1"; }
fail() { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL %s\n' "$1"; }

has() { # has <label> <needle> <file>
    if grep -qF -- "$2" "$3"; then pass "$1"; else fail "$1 (missing: $2)"; fi
}
lacks() { # lacks <label> <needle> <file>
    if grep -qF -- "$2" "$3"; then fail "$1 (present: $2)"; else pass "$1"; fi
}

UI_SH="$ROOT/setup/lib/ui.sh"
UI_PS1="$ROOT/setup/lib/ui.ps1"
PUMP_SH="$ROOT/setup/lib/exapump.sh"
PUMP_PS1="$ROOT/setup/lib/exapump.ps1"
COMMON_SH="$ROOT/setup/lib/common.sh"
COMMON_PS1="$ROOT/setup/lib/exakit-common.ps1"
MCP_PS1="$ROOT/setup/lib/mcp.ps1"

printf '\n== every ui_table_* has a named PowerShell twin ==\n'

# The map is deliberately explicit: a reviewer can read which shell function
# each PowerShell one answers, and adding a shell function without a twin means
# adding a row here and finding there is nothing to put in it.
#
#   <shell function>|<powershell function>
#
# DERIVED, NOT TRUSTED. The map alone could only fail for a function someone
# had already remembered to list - which is the case that needs no guard. The
# header promised it catches "drift by omission", and it was already blind to
# two live functions: ui_table_abort and ui_table_detach had been added to
# ui.sh and never appeared here. So the sweep below reads every ^ui_table_*
# out of ui.sh and fails on any name that is in neither the map nor the
# unix-only list. Adding a shell function is now "add a row or say why there
# is nothing to put in it", which is what the header always claimed.
UI_TABLE_MAP="$(cat <<'MAPEOF'
ui_table_widths|Get-ExakitTableWidths
ui_table_frame|Get-ExakitTableFrame
ui_table_render|Show-ExakitTable
ui_table_redraw|Update-ExakitTable
ui_table_set|Set-ExakitTableRow
ui_table_tick|Set-ExakitTableTicks
ui_table_begin|Start-ExakitTable
ui_table_end|Stop-ExakitTable
ui_table_menu|Invoke-ExakitTableMenu
ui_table_disable|Disable-ExakitTableRow
ui_table_abort|Stop-ExakitAnimation
ui_animation_stop|Stop-ExakitAnimation
MAPEOF
)"

# Deliberately unix-only, with the reason. A name here is a decision on the
# record, not an oversight - and the sweep still fails if it leaves ui.sh.
UI_TABLE_UNIX_ONLY="$(cat <<'SOLOEOF'
ui_table_detach|clears the animation ownership a SUBSHELL inherited, so a
SOLOEOF
)"

while IFS='|' read -r sh_fn ps_fn; do
    [ -n "$sh_fn" ] || continue
    if ! grep -q "^${sh_fn}()" "$UI_SH"; then
        fail "$sh_fn is gone from ui.sh — update this map, do not delete the twin"
        continue
    fi
    if grep -q "^function ${ps_fn} " "$UI_PS1" || grep -q "^function ${ps_fn}\$" "$UI_PS1"; then
        pass "$sh_fn -> $ps_fn"
    else
        fail "$sh_fn has no twin: ui.ps1 defines no $ps_fn"
    fi
done <<MAPLOOP
$UI_TABLE_MAP
MAPLOOP

# The sweep the header promised: ui.sh is the source of truth for the left
# column, not this file.
_utw_unmapped=""
for _utw_fn in $(grep -o '^ui_table_[a-z_]*' "$UI_SH" | sort -u); do
    case "
$UI_TABLE_MAP" in
        *"
$_utw_fn|"*) continue ;;
    esac
    case "
$UI_TABLE_UNIX_ONLY" in
        *"
$_utw_fn|"*) continue ;;
    esac
    _utw_unmapped="$_utw_unmapped $_utw_fn"
done
# pass/fail, NOT check - this suite has no check(). Calling one that does not
# exist prints "command not found" to stderr and leaves the counters untouched,
# so the assertion reads as a pass. That is the exact footgun agent-operability.sh
# documents as the reason its `lacks` helper exists, and these two lines were
# written with it before a mutation test showed them passing on a defect.
if [ -z "${_utw_unmapped# }" ]; then
    pass "every ui_table_* in ui.sh is mapped or declared unix-only"
else
    fail "ui.sh has ui_table_* with no map row and no unix-only declaration:${_utw_unmapped}"
fi
# ...and the sweep is not vacuous: it found the functions to check.
_utw_count="$(grep -c '^ui_table_[a-z_]*()' "$UI_SH")"
if [ "${_utw_count:-0}" -ge 10 ]; then
    pass "...and it saw the real function list ($_utw_count functions)"
else
    fail "...but it only found $_utw_count ui_table_* functions - the sweep is not looking at ui.sh"
fi
# A name declared unix-only must still exist; a stale exemption is a lie too.
while IFS='|' read -r _utw_solo _utw_why; do
    [ -n "$_utw_solo" ] || continue
    if grep -q "^${_utw_solo}()" "$UI_SH"; then
        pass "$_utw_solo is unix-only on purpose"
    else
        fail "$_utw_solo is exempted here but no longer exists in ui.sh"
    fi
done <<SOLOLOOP
$UI_TABLE_UNIX_ONLY
SOLOLOOP

# The two helpers with no direct shell name (_ui_table_prep is a bash-only
# fork-avoidance trick; building rows is a file write there and two calls here).
has "ui.ps1 builds a table"    "function New-ExakitTable"      "$UI_PS1"
has "...and appends rows"      "function Add-ExakitTableRow"   "$UI_PS1"
has "...and renders one cell"  "function Get-ExakitTableCell"  "$UI_PS1"

printf '\n== the cell is a bar over a phase, with the numbers stacked ==\n'

# Column 1 tick, column 2 name, column 3 status: a bar and its percentage on the
# first line, the phase and its elapsed count directly underneath, so the
# percentage sits vertically above the seconds.
has "the eighths come from the palette" '$script:UiProgressEighths[$rem]' "$UI_PS1"
has "the percentage is right-aligned"   '$pctText.PadLeft($num)'          "$UI_PS1"

# The width budget, which is the one piece of arithmetic in here that cannot be
# checked by running it. Both halves of it were wrong on the shell side and made
# the table flicker into two: the two-column left margin every row is built with
# was missing from the budget, so the table wrote the console's LAST column and
# the row wrapped; and the status column was measured from the stored string
# while the cell renders "<tick> <final>", two columns wider.
# ONE decomposition on both sides. Written as "11 + name + status" the gap
# before Status was folded into the 11, so an extra column had to add its own
# gap AND unpick that fold -- and not unpicking it made the no-extras table two
# columns wider than it had been. 9 is that chrome with the fold taken out.
has "the width budget takes the fold out"  '$total = 9 + $nameW + 3'  "$UI_PS1"
lacks "and nobody folds it back in"        '11 + $nameW + $statW + 3' "$UI_PS1"
has "...and the shell agrees"              '_utw_total=$(( 9 + UI_TABLE_NAME_W + 3 ))' "$UI_SH"
has "the status column is measured as rendered" '$row.Final.Length + $script:UiTick.Length + 1' "$UI_PS1"
has "and the status column gives way too"      '$statW -= $rest' "$UI_PS1"

# The phase sub-line is GONE, and so is the blank line that reserved room for
# it. It appeared and vanished as a row started and stopped running, which is
# why it needed a reserve at all; with one line per row the frame height is
# constant structurally rather than by arrangement.
lacks "no phase sub-line"                  '$cell.Text2' "$UI_PS1"
lacks "and nothing reserves room for one"  '$Table.Reserve' "$UI_PS1"
lacks "the shell has neither either"       'UI_TABLE_CELL2' "$UI_SH"
lacks "...nor a reserve"                   'UI_TABLE_RESERVE' "$UI_SH"

# The Status floor is only held once the table has something to report, and only
# where another column holds the width. Withheld from a name-and-status menu it
# shrank the box to barely wider than the longest name, then doubled the moment
# the first row started.
has "the status floor is conditional"   'if ($Table.Col2 -or $Table.Col3) {' "$UI_PS1"
has "the status column has a floor"     '$statW = 44'                        "$UI_PS1"
has "...and the shell gates it the same way" 'if [ -n "${UI_TABLE_COL2:-}" ] || [ -n "${UI_TABLE_COL3:-}" ]; then' "$UI_SH"

# Two optional columns, last in the row format so every row written in the old
# ten-field shape still parses.
has "the twin carries a second column"  'Col2 = $Col2; Col3 = $Col3' "$UI_PS1"
# No rule is drawn between columns -- alignment carries them, and a rule turned
# every wrapped description into a cage. The one vertical the table does draw is
# the TREE SPINE, which has to survive a description that wraps: a blank
# connector column snapped the line joining the add-ons in half, while the very
# same menu drew it unbroken while installing, where every row is one line.
lacks "no rule drawn between columns"   'if ($sepW -eq 3) { $sep = " " + $script:UiDim + $script:UiVB' "$UI_PS1"
lacks "...and none on the shell side"   '_UI_TABLE_SEP=" ${UI_DIM:-}${UI_VB:-|}${UI_RESET:-} "' "$UI_SH"
has "a tee remembers to carry a spine"  'if ($row.Kind -eq "tee") { $conn = $script:UiTee + " "; $spine = $true }' "$UI_PS1"
has "...drawn on every wrapped line"    '$wleft = (" " * 5) + $script:UiVB + (" " * ($nameW - 1))' "$UI_PS1"
has "the shell flags the tee the same"  'tee)    _utr_conn="${UI_TEE:-|-} "; _utr_spine=1 ;;' "$UI_SH"
has "...and draws the same spine"       '_utr_wleft="     ${UI_VB:-|}${_UI_TABLE_SP:0:$(( UI_TABLE_NAME_W - 1 ))}"' "$UI_SH"
has "the description wraps, never truncates" "function Split-ExakitWrap" "$UI_PS1"
has "...and the shell wraps without forking" "_ui_wrap() {" "$UI_SH"
has "the description width is fixed"    '$script:UiTableCol3Fixed = 44' "$UI_PS1"
has "...and may grow into slack"        '$script:UiTableCol3Max = 90'   "$UI_PS1"
has "the shell fixes and caps it too"   'UI_TABLE_COL3_MAX="${UI_TABLE_COL3_MAX:-90}"' "$UI_SH"
# A PowerShell [int] cast ROUNDS (and rounds .5 to even), so 12 eighths became
# two whole cells plus a half-cell frontier - a bar one cell ahead of the number
# beside it. The shell twin divides in integers, and the table has to agree with
# it cell for cell.
has "the table's bar floors, not rounds" '[int][Math]::Floor($units / 8)'  "$UI_PS1"

printf '\n== glyphs live only in ui.ps1 ==\n'

# Windows PowerShell 5.1 reads a BOM-less .ps1 with the legacy ANSI codepage, so
# a raw box-drawing byte anywhere else breaks the parse of the whole script.
# tests/ps-encoding-guard.sh proves the bytes; this proves the CONSEQUENCE was
# understood - the table's callers reach for the palette instead.
has "the datasets table asks for a middot" '$script:UiMidDot'  "$PUMP_PS1"
has "...which the palette defines"         '$script:UiMidDot = "'  "$UI_PS1"
lacks "the tree connectors are not typed there" 'Label "|- ' "$PUMP_PS1"

printf '\n== BOTH Windows entry points drive the table ==\n'

# This is the gap the shell side shipped with: only the standalone command
# started the table, so during an install it drew, stayed empty, and every
# dataset fell back to the single-line bar. The install path is the one that
# matters and it was the one untested.
STANDALONE="$(sed -n '/^function Show-ExakitDataLoadMenu/,/^}/p' "$PUMP_PS1")"
OFFER="$(sed -n '/^function Request-ExakitDataLoadOffer/,/^}/p' "$PUMP_PS1")"
case "$STANDALONE" in
    *"Start-ExakitDataTableRun"*) pass "the standalone command starts it" ;;
    *) fail "Show-ExakitDataLoadMenu never starts the table" ;;
esac
case "$STANDALONE" in
    *"Stop-ExakitDataTableRun"*) pass "...and stops it" ;;
    *) fail "Show-ExakitDataLoadMenu never stops the table" ;;
esac
case "$OFFER" in
    *"Start-ExakitDataTableRun"*) pass "the installer offer starts it" ;;
    *) fail "Request-ExakitDataLoadOffer never starts the table" ;;
esac
case "$OFFER" in
    *"Stop-ExakitDataTableRun"*) pass "...and stops it" ;;
    *) fail "Request-ExakitDataLoadOffer never stops the table" ;;
esac

printf '\n== the selection happens IN the table that fills in ==\n'

has "the shell selects in the table" 'ui_table_menu "$EXAKIT_TABLE_STATE"' "$PUMP_SH"
has "...and so does Windows"         "Invoke-ExakitTableMenu -Defaults"    "$PUMP_PS1"
has "the rows are built once"        "function New-ExakitDataTable"        "$PUMP_PS1"
has "a dataset finds its own row"    "function Get-ExakitDataTableRow"     "$PUMP_PS1"
# A dataset with a row reports INTO it; anything else still owns the one-line bar.
has "the load step routes to the row" 'Set-ExakitTableRow -Row $script:ExakitTableRow -State "running"' "$PUMP_PS1"
has "the finished row states the outcome" 'completed $($script:UiMidDot)'  "$PUMP_PS1"
has "a failed one says so"            '-State "failed"'                    "$PUMP_PS1"
# A live table is the same single animation slot as the spinner, or a per-file
# spinner paints over the frame and its Stop tears the table down.
has "the spinner defers to a live table"  '$script:UiTableLive) { $script:UiSpinNested++' "$UI_PS1"
has "a failure stops the animation first" "Stop-ExakitAnimation"           "$COMMON_PS1"
# A missing ui.ps1 must degrade to plainer output, not to CommandNotFoundException.
has "the no-ui fallback stubs the table" 'function Start-ExakitTable($Table = $null) { return $false }' "$COMMON_PS1"
has "...and the disabled-row call"       'function Disable-ExakitTableRow('           "$COMMON_PS1"

printf '\n== all THREE selections are the same table, not a checkbox ==\n'

# The shell side moved every one of its three selections onto the one component;
# Windows had it for datasets only, and the other two were still the old
# Read-ExakitCheckboxMenu. A checkbox menu scrolls away and the progress is
# printed underneath it, so the reader has to map one screen onto the other.
has "the AI clients select in the table"  "Invoke-ExakitTableMenu -Table \$script:McpTable" "$MCP_PS1"
lacks "and not in a checkbox any more"    'Read-ExakitCheckboxMenu -Title "Select the AI clients' "$MCP_PS1"
has "the add-ons select in the table"     'Invoke-ExakitTableMenu -Table $script:ExakitAddonTable' "$COMMON_PS1"
lacks "and neither do they"               'Read-ExakitCheckboxMenu -Title "Select add-ons to install"' "$COMMON_PS1"
# Each table is titled and its first column named for what it holds, or the
# add-ons would sit under "Dataset" - the heading the component defaults to.
has "the client table is titled"   'New-ExakitTable -Title "AI clients to connect" -Col1 "Client"' "$MCP_PS1"
has "the add-on table is titled"   'New-ExakitTable -Title "Marketplace add-ons" -Col1 "Add-on"'   "$COMMON_PS1"
has "...with Version and Description" '-Col2 "Version" -Col3 "Description"'                          "$COMMON_PS1"
has "...and the shell declares both"  'UI_TABLE_COL2="Version"'                                      "$COMMON_SH"
has "...and the shell agrees"      'UI_TABLE_COL1="Client"'                                        "$COMMON_SH"
has "...for add-ons too"           'UI_TABLE_COL1="Add-on"'                                        "$COMMON_SH"
# The heading comes off the TABLE, not out of module state: three tables are
# built in one run and a heading left behind is how the second wears the first's.
has "the frame reads its own heading" '$col1 = "" + $Table.Col1' "$UI_PS1"
# The rows the reader ticked are the rows that fill in - for all three now.
has "an add-on finds its own row"      "function Get-ExakitAddonTableRow"   "$COMMON_PS1"
has "...and its finished cell"         "function Get-ExakitAddonTableCell"  "$COMMON_PS1"
has "the install animates that table"  'Start-ExakitTable -Table $script:ExakitAddonTable' "$COMMON_PS1"
has "...and stops it"                  'Stop-ExakitTable -Table $script:ExakitAddonTable'  "$COMMON_PS1"
has "the add-on reports into its row"  'Set-ExakitTableRow -Row $script:ExakitAddonTableRow -State "running"' "$COMMON_PS1"
# Nothing may print over a frame that is still being repainted, so the lines an
# install has to say are collected and said after the table stops.
has "the notes are held back"          "function Write-ExakitAddonNote"     "$COMMON_PS1"
has "...and drained afterwards"        "Show-ExakitAddonNotes"              "$COMMON_PS1"
# The MCP bar sits on the GROUP row: ONE python process configures every selected
# client, so there is no per-client checkpoint a per-client bar could be honest
# about. Each client's final cell comes from the run's own record instead.
has "the MCP bar is on the group row" 'Set-ExakitTableRow -Row 1 -State "running" -Pct 5' "$MCP_PS1"
has "the client cells come from the result" "configured_clients"            "$MCP_PS1"
lacks "no invented per-client bar"    'Set-ExakitTableRow -Row $row -State "running"'      "$MCP_PS1"
# A scripted answer must not build a table at all: it has no console to draw on
# and its lines are the whole output. Pinned by ORDER - the env branch returns
# before the table is ever created.
_env_at="$(grep -n 'if ($env:EXAKIT_MCP_CLIENTS)' "$MCP_PS1" | head -1 | cut -d: -f1)"
_tbl_at="$(grep -n 'New-ExakitTable -Title "AI clients to connect"' "$MCP_PS1" | head -1 | cut -d: -f1)"
if [ -n "$_env_at" ] && [ -n "$_tbl_at" ] && [ "$_env_at" -lt "$_tbl_at" ]; then
    pass "EXAKIT_MCP_CLIENTS is answered before any table is built"
else
    fail "EXAKIT_MCP_CLIENTS no longer short-circuits the client table (env=$_env_at table=$_tbl_at)"
fi
_env_at="$(grep -n 'if ($env:EXAKIT_MARKETPLACE_ADDONS) {' "$COMMON_PS1" | head -1 | cut -d: -f1)"
_tbl_at="$(grep -n 'New-ExakitTable -Title "Marketplace add-ons"' "$COMMON_PS1" | head -1 | cut -d: -f1)"
if [ -n "$_env_at" ] && [ -n "$_tbl_at" ] && [ "$_env_at" -lt "$_tbl_at" ]; then
    pass "EXAKIT_MARKETPLACE_ADDONS is answered before any table is built"
else
    fail "EXAKIT_MARKETPLACE_ADDONS no longer short-circuits the add-on table (env=$_env_at table=$_tbl_at)"
fi

printf '\n== a disabled row can be read but never picked ==\n'

# The client list shows the WHOLE set of supported clients and says why the ones
# this machine cannot offer are missing. A list that quietly omitted them would
# read as "the kit supports four clients", and the reader has no way to tell a
# short list from a filtered one.
has "the client list disables a row" "Disable-ExakitTableRow -Row \$rowAt" "$MCP_PS1"
has "...saying it is not installed"  '"not installed"'                     "$MCP_PS1"
has "...or already connected"        '"already connected"'                 "$MCP_PS1"
# Drawn dim with no checkbox, the note reading on from the label.
has "the frame draws it dim"       'if ($row.State -eq "disabled") {'       "$UI_PS1"
# ...and refuses a tick whoever asked. Select All spans a range that may contain
# one and the defaults are built by the caller; this is where both pass through.
has "a tick is refused"            'if ($r.State -eq "disabled") { $on = $false }' "$UI_PS1"
# The cursor steps over it, Space ignores it, and Select All leaves it alone.
has "the cursor steps over it"     'if ($pickable.Contains($at)) { return $at }'   "$UI_PS1"
has "Space ignores it"             'if ($pickable.Contains($cur)) {'               "$UI_PS1"
has "Select All skips it"          'if (-not $pickable.Contains($c)) { [void]$sel.Remove($c); continue }' "$UI_PS1"
has "and it is never where the cursor starts" 'if (-not $pickable.Contains($cur)) { $cur = [int](& $step $cur 1) }' "$UI_PS1"
# The separator between a label and its note is a GLYPH, and every .ps1 but
# ui.ps1 has to stay pure ASCII - so it comes from the palette. The old client
# menu built one with [char]0xB7, which the encoding guard cannot see because the
# source bytes are ASCII; the palette is the one place it may live.
has "the disabled note uses the palette middot" '$script:UiMidDot' "$UI_PS1"
lacks "mcp.ps1 constructs no glyph of its own"  '[char]0xB7'       "$MCP_PS1"
has "and the truncation marker too"             '$script:UiEllipsis'  "$COMMON_PS1"
has "...which the palette defines"              '$script:UiEllipsis = "'  "$UI_PS1"

printf '\n== every frame is drawn from column 0 ==\n'

# Cursor-up PRESERVES the column. A frame drawn while the cursor sits mid-row -
# left there by anything that printed without a newline, a spinner frame or a
# progress line - starts at that column, and clear-to-end only clears from there
# rightwards. What stays on screen is the first N columns of the old frame with a
# new one starting inside it: several top borders side by side on ONE line at
# differing widths. One carriage return in front of every frame makes it
# impossible, whoever left the cursor where. Twin of the same \r in
# ui_table_redraw.
# Every console write that puts a frame on screen - $frames is the spinner's
# glyph list and is not one of them.
_frame_writes="$(grep -n '::Write(' "$UI_PS1" | grep -F '$frame' | grep -vF '$frames')"
_fw_n="$(printf '%s\n' "$_frame_writes" | grep -c .)"
_fw_cr="$(printf '%s\n' "$_frame_writes" | grep -c 'Write("`r')"
if [ "$_fw_n" -gt 0 ] && [ "$_fw_n" = "$_fw_cr" ]; then
    pass "all $_fw_n frame writes in ui.ps1 start with a carriage return"
else
    fail "a frame in ui.ps1 is written without a leading carriage return ($_fw_cr of $_fw_n)"
    printf '%s\n' "$_frame_writes" | grep -v 'Write("`r' | sed 's/^/       /'
fi

# ONE animation at a time, and the loser is STOPPED rather than orphaned: an
# orphaned spinner keeps printing its own line without a trailing newline every
# 90ms, which is what leaves the cursor mid-row for the frame above. Refusing
# instead was safe but degraded - the caller reads $false as "no console" and
# falls back to plain lines, so the table drew once and never moved.
TABLE_BEGIN="$(sed -n '/^function Start-ExakitTable {/,/\$handle = \$ps.BeginInvoke()/p' "$UI_PS1")"
case "$TABLE_BEGIN" in
    *'$script:UiSpinNested = 0'*) pass "the table gives the spinner's reference back" ;;
    *) fail "Start-ExakitTable does not zero the nesting count before stopping" ;;
esac
case "$TABLE_BEGIN" in
    *"Stop-ExakitSpinner"*) pass "...and stops a live animation before taking the line" ;;
    *) fail "Start-ExakitTable still refuses instead of stopping a live animation" ;;
esac
SH_TABLE_BEGIN="$(sed -n '/^ui_table_begin() {/,/printf .\\033\[?25l./p' "$UI_SH")"
case "$SH_TABLE_BEGIN" in
    *"_ui_step_stop_spinner"*) pass "the shell twin does the same" ;;
    *) fail "ui_table_begin no longer stops a live animation - the twins have drifted" ;;
esac

printf '\n== an unchanged frame is overwritten, never cleared ==\n'

# [0J erases from the cursor to the end of the screen, so clearing and then
# writing leaves the region genuinely EMPTY for the instant between the two -
# which five times a second is the table flickering: something, nothing,
# something. Every line of a frame is padded to the box width, so while the
# geometry is identical an overwrite cannot leave one stale character behind and
# the erase buys nothing. It is kept for the case where the geometry DID change
# (a resize, or the first frame after the menu, one line taller for its hint),
# because then old content really is left over.
has "the frame records its own width" '$Table.Width = $inner' "$UI_PS1"
has "the redraw compares BOTH halves" '$same = ($prev -eq [int]$Table.Lines -and $prevWidth -eq [int]$Table.Width)' "$UI_PS1"
has "an unchanged frame is overwritten" 'Write("`r$($script:UiEsc)[${prev}A" + $frame' "$UI_PS1"
has "...and a changed one still erases" 'Write("`r$($script:UiEsc)[${prev}A$($script:UiEsc)[0J" + $frame' "$UI_PS1"
# The menu's redraw is the one a reader watches keypress by keypress, so it needs
# the same rule - it is a second write site, not a call into the first.
has "the menu compares both halves too" '$sameGeom = ($drawn -eq ([int]$Table.Lines + 1) -and $drawnWidth -eq [int]$Table.Width)' "$UI_PS1"
has "...overwriting in place"           'Write("`r$($script:UiEsc)[${drawn}A" + $frame' "$UI_PS1"
has "...and erasing only on a change"   'Write("`r$($script:UiEsc)[${drawn}A$($script:UiEsc)[0J" + $frame' "$UI_PS1"
# Exactly TWO erasing writes in the whole file, one per write site: a third would
# be an unconditional clear creeping back in.
_erase_n="$(grep -F '::Write(' "$UI_PS1" | grep -cF '[0J')"
if [ "$_erase_n" = "2" ]; then
    pass "ui.ps1 erases in exactly the two changed-geometry branches"
else
    fail "ui.ps1 has $_erase_n clear-to-end writes, expected 2 (one per write site)"
fi

printf '\n== the PowerShell stays 5.1-compatible ==\n'

# Windows PowerShell 5.1 is the floor: no ternary, no null-coalescing, no Clean
# block. Checked over every .ps1, because the table is not the only thing that
# would be broken by one.
while IFS= read -r file; do
    rel="${file#"$ROOT"/}"
    bad=""
    # Comments and single-quoted strings first: this file's own header says "no
    # ternary, no ??", and half the regexes in the kit contain a literal "\?.".
    # Scanning the raw text reports both as PowerShell 7 syntax.
    code="$(sed -e "s/'[^']*'//g" -e 's/#.*$//' "$file")"
    printf '%s\n' "$code" | grep -qE '\?\?'       && bad="$bad ??"
    printf '%s\n' "$code" | grep -qE '\$[A-Za-z_][A-Za-z0-9_]*\?\.' && bad="$bad ?."
    printf '%s\n' "$code" | grep -qE '^[[:space:]]*[Cc]lean[[:space:]]*\{' && bad="$bad clean-block"
    # A ternary is `<expr> ? <a> : <b>`; the shape that cannot be anything else
    # is a closing paren followed by a bare `?`.
    printf '%s\n' "$code" | grep -qE '\)[[:space:]]*\?[[:space:]]' && bad="$bad ternary"
    if [ -n "$bad" ]; then
        fail "$rel uses PowerShell 7 syntax:$bad"
    else
        pass "$rel is 5.1 syntax"
    fi
done <<EOF
$(find "$ROOT" -name '*.ps1' -not -path "$ROOT/.git/*" -not -path "$ROOT/.claude/*" | sort -u)
EOF

printf '\n== every .ps1 still balances ==\n'

# Nothing else in the repo parses PowerShell, and a stray brace in a file that
# only Windows loads is invisible here until an install dies. This is a crude
# lexer - comments, both here-string forms, both quote forms, backtick escapes
# and $( ) inside a string - counting (), [] and {}. Not a parser; enough to
# catch the mistake you make when you cannot run pwsh.
if command -v python3 >/dev/null 2>&1; then
    _bal="$(python3 - "$ROOT" <<'PYEOF'
import io, os, sys, glob

def check(path):
    with io.open(path, encoding="utf-8-sig") as fh:
        s = fh.read()
    i, n, line = 0, len(s), 1
    stack, errs = [], []
    while i < n:
        c = s[i]
        in_dq = bool(stack) and stack[-1][0] == "DQ"
        if c == "\n":
            line += 1; i += 1; continue
        if in_dq:
            if c == "`":
                i += 2; continue
            if s[i:i+2] == '""':
                i += 2; continue
            if s[i:i+2] == "$(":
                stack.append(("(", line)); i += 2; continue
            if c == '"':
                stack.pop(); i += 1; continue
            i += 1; continue
        if s[i:i+2] == "<#":
            j = s.find("#>", i + 2)
            if j < 0:
                errs.append((line, "unterminated <# comment")); break
            line += s.count("\n", i, j); i = j + 2; continue
        if c == "#":
            j = s.find("\n", i)
            i = n if j < 0 else j
            continue
        if s[i:i+2] in ("@'", '@"'):
            q = s[i+1]
            term = "\n" + q + "@"
            j = s.find(term, i + 2)
            if j < 0:
                errs.append((line, "unterminated here-string")); break
            line += s.count("\n", i, j + len(term)); i = j + len(term); continue
        if c == "'":
            j = i + 1
            while j < n:
                if s[j] == "'":
                    if j + 1 < n and s[j+1] == "'":
                        j += 2; continue
                    break
                if s[j] == "\n":
                    line += 1
                j += 1
            if j >= n:
                errs.append((line, "unterminated ' string")); break
            i = j + 1; continue
        if c == '"':
            stack.append(("DQ", line)); i += 1; continue
        if c == "`":
            i += 2; continue
        if c in "([{":
            stack.append((c, line)); i += 1; continue
        if c in ")]}":
            want = {")": "(", "]": "[", "}": "{"}[c]
            if not stack:
                errs.append((line, "closing %s with nothing open" % c)); i += 1; continue
            o, ol = stack.pop()
            if o != want:
                errs.append((line, "closing %s but %s opened on line %d" % (c, o, ol)))
            i += 1; continue
        i += 1
    for o, ol in stack:
        errs.append((ol, "unclosed %s" % o))
    return errs

root = sys.argv[1]
bad = []
for path in sorted(glob.glob(os.path.join(root, "**", "*.ps1"), recursive=True)):
    # .claude holds other agents' worktrees when this runs from a shared
    # checkout: their half-finished files are not this suite's business.
    if os.sep + ".git" + os.sep in path or os.sep + ".claude" + os.sep in path:
        continue
    for line, msg in check(path):
        bad.append("%s:%d: %s" % (os.path.relpath(path, root), line, msg))
print("\n".join(bad))
PYEOF
)"
    if [ -z "$_bal" ]; then
        pass "every .ps1 balances its braces, parens and strings"
    else
        fail "unbalanced PowerShell:"
        printf '%s\n' "$_bal" | sed 's/^/       /'
    fi
else
    printf 'SKIP the balance check needs python3\n'
fi

printf '\n== the selection\047s columns do not survive into the install ==\n'
# The add-on table the reader ticks IS the table the install then fills in, so
# whatever headings the menu chose are still attached when the progress display
# starts. On the shell they are module globals the caller switches off; in
# PowerShell they are fields on the table OBJECT, which outlive the menu unless
# cleared. Nothing forced the two to agree, and they did not: a Windows install
# ran with Add-on, Version, Description AND Status while macOS showed Add-on and
# Status. Asserted as text because there is no pwsh on the machine this kit is
# developed on, and Windows is the only place that screen is drawn.
if grep -A2 'ui_table_menu "$EXAKIT_ADDON_TABLE_STATE"' "$COMMON_SH" | grep -qF 'UI_TABLE_COL2=""'; then
    pass "the shell drops Version once the add-on menu closes"
else
    fail "the shell no longer drops Version after the add-on menu"
fi
if grep -A3 'ui_table_menu "$EXAKIT_ADDON_TABLE_STATE"' "$COMMON_SH" | grep -qF 'UI_TABLE_COL3=""'; then
    pass "...and Description with it"
else
    fail "the shell no longer drops Description after the add-on menu"
fi
has "the twin drops Version on the object"  '$script:ExakitAddonTable.Col2 = ""' "$COMMON_PS1"
has "...and Description with it"            '$script:ExakitAddonTable.Col3 = ""' "$COMMON_PS1"

printf '\n== a row nobody can pick keeps its columns ==\n'
# It used to merge into one sentence -- "json-tables · Installed (0.2)" -- which
# put a version in the middle of a name while the Version column beside it sat
# empty, and left Status with nothing to say about the one row whose state was
# already known. Now it renders like any other row, minus the checkbox.
lacks "the shell no longer merges the note into the name" '_utr_text="$_utr_conn$_utr_label${_utr_note:+ · $_utr_note}"' "$UI_SH"
lacks "...nor does the twin"        '$text = $text + " " + $script:UiMidDot + " " + $note' "$UI_PS1"
has "the shell blanks the checkbox" '_utr_ptr=" "; _utr_box="   "; _utr_boxlen=3' "$UI_SH"
has "...and the twin does too"      'if ($row.State -eq "disabled") { $box = "   "; $boxLen = 3 }' "$UI_PS1"
# The name carries colour now, so its width must be measured before the escapes
# are added or every disabled row pads short by the length of the escape.
has "the shell measures the name plain" '_utr_namelen=${#_utr_plain}' "$UI_SH"
has "...and so does the twin"           '$nameLen = $plain.Length' "$UI_PS1"
# And the state cell is drawn ONLY where a Status column exists: a disabled row
# does not count as a status for width, so filling it on the selection screen
# drew into a column of width zero and pushed the row past its border.
has "the shell guards the cell on width" 'if [ "${UI_TABLE_STAT_W:-0}" -gt 0 ]; then' "$UI_SH"
has "...and the twin guards it too"      'if ($StatusWidth -gt 0) {' "$UI_PS1"

printf '\n== no PowerShell module builds a path out of a raw $HOME ==\n'
# PowerShell's $HOME is the account's home-directory ATTRIBUTE, which on a
# domain-joined machine is routinely H:\ or a UNC share. Every other tool the
# kit talks to -- exapump.exe, uv's installer, Claude Code, Codex -- resolves
# "home" as %USERPROFILE%. So a path built from $HOME is written where the tool
# that has to read it never looks: the exapump profile, the uv binary and the
# skills all landed in the wrong tree, and each failure looked like something
# else. Get-ExakitProfileHome is the one resolver; this fails if a module goes
# back to $HOME.
#
# Four things legitimately still name $HOME and are skipped by name:
#   the resolvers themselves      - $HOME is their documented fallback
#   comment lines                 - they explain exactly this
#   $HOME with a FORWARD slash    - literal text ("$HOME/.local/bin/exakit")
#                                   matched against Claude settings entries,
#                                   never dereferenced as a path
#   Get-ExakitTilde / Get-ExakitNormalizedPath / Show-McpOperationSummary
#                                 - display abbreviation and expanding a ~ the
#                                   USER typed, where $HOME is the right answer
raw_home_hits() { # raw_home_hits <file>
    awk '
        /^function [A-Za-z]+-[A-Za-z0-9]+/ { fn = $2 }
        /\$HOME/ {
            line = $0
            sub(/^[ \t]+/, "", line)
            if (line ~ /^#/) next
            if (line ~ /\$HOME\//) next
            if (fn == "Get-ExakitHomeBase") next
            if (fn == "Get-ExakitProfileHome") next
            if (fn == "Get-ExakitAgentHome") next
            if (fn == "Get-ExakitTilde") next
            if (fn == "Get-ExakitNormalizedPath") next
            if (fn == "Show-McpOperationSummary") next
            printf "%d ", NR
        }
    ' "$1"
}
for ps_module in exakit-common.ps1 exapump.ps1 mcp.ps1 runtime-personal.ps1 pyexasol.ps1; do
    hits="$(raw_home_hits "$ROOT/setup/lib/$ps_module")"
    if [ -n "$hits" ]; then
        fail "setup/lib/$ps_module builds a path from \$HOME (lines: $hits) -- use Get-ExakitProfileHome"
    else
        pass "setup/lib/$ps_module routes every home through the resolver"
    fi
done
has "the profile-home resolver exists"        'function Get-ExakitProfileHome' "$COMMON_PS1"
has "the agent home is the same resolver"     'return (Get-ExakitProfileHome)' "$COMMON_PS1"
has "the exapump profile follows it"          'Join-Path (Get-ExakitProfileHome) ".exapump\config.toml"' "$PUMP_PS1"
has "so does uv's installer directory"        'Join-Path (Get-ExakitProfileHome) ".local\bin\uv.exe"' "$COMMON_PS1"


printf '\n== the step narration is the same on every platform ==\n'

# WHY THIS SECTION EXISTS. A macOS install narrates each step on one line; the
# same install on Windows printed the download line, the checksum verdict and
# the unpack line underneath it. Both halves have the same four "Checksum
# verified" call sites, correctly mirrored - the difference was never the
# message, it was WHEN detail is silenced.
#
# The shell asks one question: is stdout a terminal. PowerShell asked whether
# ANSI rendering is available, which is a different question and is FALSE on a
# console without virtual-terminal support, under NO_COLOR, and under
# EXAKIT_NO_FANCY=1 - every one of them still a terminal. So the same install
# was quiet on macOS and verbose on a Windows console that merely lacked
# colour.
COMMON_PS="$ROOT/setup/lib/exakit-common.ps1"
RTP_PS="$ROOT/setup/lib/runtime-personal.ps1"
_PS_ALL="$(mktemp)"; cat "$ROOT"/setup/lib/*.ps1 "$ROOT"/setup/*.ps1 > "$_PS_ALL" 2>/dev/null

has "PowerShell has the shell's terminal test" "function Test-ExakitStdoutIsTerminal" "$COMMON_PS"
has "...and it asks about stdout, as [ -t 1 ] does" "IsOutputRedirected" "$COMMON_PS"
lacks "no quiet bracket is gated on fancy rendering any more" \
    'if ($script:UiFancy) { $script:ExakitQuietDetail = $true }' "$_PS_ALL"

# The two steps a user sees first. Both were unbracketed on Windows, which is
# where the checksum line came from.
has "the launcher step silences its detail"   '$prevQuiet = $script:ExakitQuietDetail' "$RTP_PS"
has "...and restores that flag again"         '$script:ExakitQuietDetail = $prevQuiet' "$RTP_PS"
has "the deploy step silences its detail too" '$prevDeployQuiet = $script:ExakitQuietDetail' "$RTP_PS"
has "...and restores that one too"            '$script:ExakitQuietDetail = $prevDeployQuiet' "$RTP_PS"

# EVERY bracket must be balanced. A leaked flag does not print too much, it
# prints too LITTLE - it silences every step after the one that leaked, which
# is the harder failure to notice.
_ps_on="$(grep -cF 'ExakitQuietDetail = $true' "$_PS_ALL" || true)"
_ps_off="$(grep -cE 'ExakitQuietDetail = \$[A-Za-z]*[Pp]rev[A-Za-z]*' "$_PS_ALL" || true)"
# THIS LINE CALLED AN ASSERTION THAT DOES NOT EXIST. The suite defines pass,
# fail, has and lacks - never `check` - so it printed "check: command not found"
# to stderr, touched neither counter, and the suite still reported "0 failed"
# with exit 0. A dead assertion is worse than no assertion: it reads as coverage.
#
# Reviving it verbatim would fail, and rightly: it asserted the two counts are
# EQUAL, and they are not (10 sets, 13 restores) because a restore in a finally
# block legitimately covers a set that only happens on one branch. What a grep
# can actually prove is the direction - restoring fewer times than you set means
# a flag escapes its bracket and silences every step after it, which is the
# failure the comment above describes.
if [ "$_ps_off" -ge "$_ps_on" ]; then
    pass "every quiet bracket is closed again ($_ps_on set, $_ps_off restored)"
else
    fail "a quiet flag escapes its bracket: $_ps_on set, only $_ps_off restored"
fi
rm -f "$_PS_ALL"

printf '\n%d checks, %d failed\n' "$checks" "$fails"
[ "$fails" -eq 0 ]
