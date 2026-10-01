#!/usr/bin/env bash
# Guard the "Add-ons only" row in `exakit uninstall`.
#
# Clearing the add-ons while keeping the database was always reachable - tick
# every add-on row, leave EVERYTHING alone - but nothing on the screen said so.
# The row states the outcome instead, and expands to the add-ons themselves so
# the confirmation panel names each one before anybody types UNINSTALL.
#
# It ships with a trap already sprung once: the sweep key __all_addons__ is
# spelled like the placeholder keys (__header__) that the selection loop skips,
# so a check placed after that skip silently discarded the pick and the menu
# answered "Nothing selected" with the row plainly ticked. Nothing was removed
# and nothing said why. These checks drive the real menu for that reason - a
# test that only inspected the labels would have passed the broken version.
#
#   bash tests/uninstall-addons-only.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fails=0
checks=0

pass() { checks=$((checks + 1)); printf 'ok   %s\n' "$1"; }
fail() { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL %s\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The menu only draws on a terminal, so each case runs under a pty. Removal is
# stubbed: this is about which components get routed, never about deleting.
cat > "$WORK/menu.sh" <<EOF
set -u
export HOME="$WORK/home"; mkdir -p "\$HOME"
export EXAKIT_HOME="$WORK/kh"; mkdir -p "\$EXAKIT_HOME"
export EXAKIT_BIN_DIR="$WORK/bin"; mkdir -p "\$EXAKIT_BIN_DIR"
. "$ROOT/setup/lib/ui.sh" 2>/dev/null; ui_detect 2>/dev/null
. "$ROOT/setup/lib/common.sh"
printf '{"kit":{"version":"0.2.0"},"runtime":{"type":"personal"}}\n' > "\$EXAKIT_HOME/manifest.json"
exakit_marketplace_installed_addons() { printf 'dash-server\nexasol-vscode\njson-tables\n'; }
_exakit_uninstall_component() { printf 'WOULD-REMOVE: %s\n' "\$1"; }
exakit_uninstall_menu
EOF

# script(1) comes in two incompatible flavours: BSD/macOS takes the command as
# ARGUMENTS after the typescript file, util-linux takes it after -c. Written the
# BSD way only, this ran on a developer's macOS and nowhere else -- which went
# unnoticed for as long as the suite itself was not in CI. The same detection
# tests/versions-manifest.sh already carries, for the same reason.
#
# stdin must be /dev/null for the probe: macOS script(1) refuses to start when
# its stdin is a socket, which is what a CI or agent shell hands it.
PTY_KIND="none"
if command -v script >/dev/null 2>&1; then
    if script -q /dev/null /bin/echo probe </dev/null >/dev/null 2>&1; then
        PTY_KIND="bsd"
    elif script -q -c "/bin/echo probe" /dev/null </dev/null >/dev/null 2>&1; then
        PTY_KIND="util-linux"
    fi
fi
# in_pty <script-file> — run it on a pty, whichever flavour is present.
in_pty() {
    case "$PTY_KIND" in
        bsd)        script -q /dev/null bash "$1" 2>&1 ;;
        util-linux) script -q -c "bash $1" /dev/null 2>&1 ;;
        *)          printf '' ;;
    esac
}

# run <keystrokes> -> what the menu did, escape codes stripped
run() {
    # tr -d '\r': a pty ends every line with CR, which is invisible in output and
    # makes a string compare fail against text that prints identically.
    printf '%b' "$1" | in_pty "$WORK/menu.sh" \
        | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | tr -d '\r'
}
removed() { printf '%s\n' "$1" | sed -n 's/^WOULD-REMOVE: //p' | sort | tr '\n' ' ' | sed 's/ $//'; }

# Rows: 1 Skip, 2 Add-ons only, 3..5 the add-ons, 6 EVERYTHING.
DOWN='\033[B'

# 1. The sweep removes every add-on, and NOTHING else. The database is the whole
#    point of the row: a reader picked it because their data must survive.
out="$(run "${DOWN} \nUNINSTALL\n")"
got="$(removed "$out")"
if [ "$got" = "dash-server exasol-vscode json-tables" ]; then
    pass "Add-ons only removes exactly the add-ons"
else
    fail "Add-ons only removed [$got] - expected the three add-ons"
fi
case " $got " in
    *" database "*|*" everything "*) fail "Add-ons only touched the database" ;;
    *)                               pass "Add-ons only leaves the database alone" ;;
esac

# 2. It must reach the confirmation panel by NAME. A row that hides its members
#    asks for a typed UNINSTALL against something the reader cannot see.
for addon in dash-server exasol-vscode json-tables; do
    case "$out" in
        *"$addon"*) : ;;
        *) fail "the confirmation panel never names $addon"; continue ;;
    esac
done
case "$out" in
    *"PERMANENTLY remove"*) pass "the confirmation panel names each add-on" ;;
    *) fail "no confirmation panel was drawn" ;;
esac

# 3. The failure this shipped with: ticked row, nothing removed, no reason given.
case "$out" in
    *"Nothing selected"*) fail "the sweep row is ticked and the menu says nothing was selected - the key is being skipped as a placeholder" ;;
    *)                    pass "a ticked sweep row is not discarded as a placeholder" ;;
esac

# 4. EVERYTHING is untouched by all this: still one pick that covers the lot.
out_all="$(run "${DOWN}${DOWN}${DOWN}${DOWN}${DOWN} \nUNINSTALL\n")"
if [ "$(removed "$out_all")" = "everything" ]; then
    pass "EVERYTHING still routes to the full uninstall"
else
    fail "EVERYTHING routed to [$(removed "$out_all")]"
fi

# 5. A single add-on on its own still works - the sweep is an addition, not a
#    replacement for picking one.
out_one="$(run "${DOWN}${DOWN} \nUNINSTALL\n")"
if [ "$(removed "$out_one")" = "dash-server" ]; then
    pass "a single add-on can still be picked alone"
else
    fail "picking one add-on removed [$(removed "$out_one")]"
fi

# 6. Skip is still the pre-selected default: Enter alone removes nothing.
out_skip="$(run "\nUNINSTALL\n")"
if [ -z "$(removed "$out_skip")" ]; then
    pass "Enter alone removes nothing"
else
    fail "Enter alone removed [$(removed "$out_skip")]"
fi

# 7. Both scope rows say what SURVIVES. That is the fact a reader at this screen
#    is weighing, and "keeps: nothing" is the plainest thing EVERYTHING can say.
#    The add-ons row names the kit rather than listing its parts, so this must
#    not go back to enumerating components as the row's text.
case "$out_skip" in
    *"keeps: starter-kit"*) pass "the add-ons row says what it keeps" ;;
    *) fail "the add-ons row no longer says what survives" ;;
esac
case "$out_skip" in
    *"keeps: nothing"*) pass "EVERYTHING says it keeps nothing" ;;
    *) fail "EVERYTHING no longer states its scope in the same terms" ;;
esac

# 8. The closing line has to be followable. A full uninstall deletes the exakit
#    binary, so ending the run with "See where you stand with: exakit info"
#    hands the reader a command that no longer exists - as the last word of the
#    run, with nothing after it to correct the impression.
case "$out_all" in
    *"exakit info"*) fail "a full uninstall still points at exakit info, which it has just deleted" ;;
    *)               pass "a full uninstall does not point at the command it removed" ;;
esac
# Matched on the sentence, not on a filename: the installer is published at an
# exasol.com address now, and the property under test is that the reader is
# left with a way back - not which file serves it.
case "$out_all" in
    *"Install it again any time:"*) pass "and offers the reinstall command instead" ;;
    *)                              fail "a full uninstall leaves the reader with no way back" ;;
esac
# Anything short of EVERYTHING leaves the CLI in place, and there info IS the
# right next step: the fix must not silence it for every scope.
case "$out" in
    *"exakit info"*) pass "a partial uninstall still points at exakit info" ;;
    *)               fail "a partial uninstall lost its next step - the CLI is still installed" ;;
esac

# 9. Skills are reported per FOLDER, not per skill. Nine skills across two
#    discovery folders printed eighteen near-identical lines mid-uninstall.
_sk_home="$WORK/skillhome"
mkdir -p "$_sk_home/.claude/skills" "$_sk_home/.agents/skills"
for _sk in dash-server exasol-mcp json-tables; do
    mkdir -p "$_sk_home/.claude/skills/$_sk" "$_sk_home/.agents/skills/$_sk"
done
_sk_out="$(
    export HOME="$_sk_home"
    export EXAKIT_HOME="$WORK/skillkit"; mkdir -p "$EXAKIT_HOME"
    . "$ROOT/setup/lib/ui.sh" 2>/dev/null; ui_detect 2>/dev/null
    . "$ROOT/setup/lib/common.sh"
    printf '{"components":{"skills":{"installed":["dash-server","exasol-mcp","json-tables"]}}}\n' \
        > "$EXAKIT_HOME/manifest.json"
    exakit_repo_root() { return 1; }
    _exakit_remove_installed_skills 0 2>&1
)"
_sk_lines="$(printf '%s\n' "$_sk_out" | grep -c "AI skill")"
if [ "$_sk_lines" -le 2 ]; then
    pass "three skills in two folders report on $_sk_lines line(s), not six"
else
    fail "skill removal printed $_sk_lines lines - one per skill per folder is a wall of near-identical text"
fi
case "$_sk_out" in
    *"3 AI skills"*) pass "and the line says how many went" ;;
    *)               fail "the collapsed line does not say how many skills were removed" ;;
esac

# 8. The PowerShell twin routes the same way; it cannot be executed here.
PS="$ROOT/setup/exakit.ps1"
if grep -q '__all_addons__' "$PS" && grep -q 'keeps: nothing' "$PS"; then
    pass "the PowerShell twin carries the sweep row"
else
    fail "the PowerShell twin has no sweep row - Windows keeps the old menu"
fi
# The ordering bug, checked on the twin: the sweep must be handled BEFORE the
# placeholder skip, or Windows repeats the silent no-op.
if awk '/\$key -eq "__all_addons__"/ { found = NR } /StartsWith\("__"\)/ { if (!found || NR < found) exit 1 } END { exit(found ? 0 : 1) }' "$PS"; then
    pass "the PowerShell twin handles the sweep before the placeholder skip"
else
    fail "the PowerShell twin checks the sweep key after the __ skip - the pick is discarded"
fi

PS_MAIN="$ROOT/setup/exakit.ps1"
if grep -q 'The kit is gone' "$PS_MAIN"; then
    pass "the PowerShell twin has the full-uninstall closing line"
else
    fail "the PowerShell twin still ends a full uninstall with a command it deleted"
fi
if grep -q 'AI \$word from' "$PS_MAIN"; then
    pass "the PowerShell twin collapses the skill lines too"
else
    fail "the PowerShell twin still prints one line per skill per folder"
fi

printf '\n%d checks, %d failed\n' "$checks" "$fails"
[ "$fails" -eq 0 ]
