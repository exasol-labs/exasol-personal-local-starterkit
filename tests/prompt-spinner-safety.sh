#!/usr/bin/env bash
# Guard: a question is never asked under a live spinner or step bar.
#
# The installer's Setup Utilities step draws its items as one bar that repaints
# its line every 0.2 s. An item that has to ask something - exapump's profile
# asks "? Database password for user sys (input hidden):" when the database's
# secrets cannot be read - printed its question on that line, and the bar's next
# frame painted over it: the screen showed only "1/3  Data Loader (141s)"
# counting up, and the install looked hung (scenario X, finding MX-05). The
# question runs in a $( ) subshell, which ui_spin_end may not stop.
#
# This replays a real pty: the bar starts, the question is asked from a
# subshell exactly as exapump_create_profile asks it, and no bar frame may
# reach the screen between the question and the answer.
#
#   bash tests/prompt-spinner-safety.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/exakit-prompt-spin.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if ! command -v python3 >/dev/null 2>&1; then
    printf 'python3 not available - skipping\n'; exit 0
fi

# scenario <kind>: hidden (exakit_read_hidden in $( )), confirm, text (prompt_text in $( )).
cat > "$WORK/scenario.sh" <<EOF
cd "$ROOT"
. setup/lib/ui.sh
. setup/lib/common.sh 2>/dev/null
ui_detect >/dev/null 2>&1
UI_FANCY=1
UI_ACCENT=\$'\033[38;5;35m'; UI_RESET=\$'\033[0m'; UI_DIM=\$'\033[2m'
UI_OK=\$'\033[1;32m'; UI_TICK='+'
exakit_step_group_begin "Step 3/4  Setup Utilities" 3
exakit_item_begin "Data Loader"
sleep 0.6
case "\$1" in
    hidden)  _a="\$(exakit_read_hidden "Database password for user sys")" ;;
    confirm) if confirm "Use it?" y; then _a=yes; else _a=no; fi ;;
    text)    _a="\$(prompt_text "Profile name" "starter-kit")" ;;
esac
printf 'ANSWER[%s]\n' "\$_a"
sleep 0.3
exakit_item_end 0
EOF

# Waits for the question, lets a second of bar frames go by, then answers.
# Prints: the bytes that arrived between the question and the answer, a
# separator, and everything.
cat > "$WORK/ptyrun.py" <<'EOF'
import os, pty, sys, select, time
env = dict(os.environ)
env['TERM'] = 'xterm-256color'
env['LC_ALL'] = 'en_US.UTF-8'
env.pop('NO_COLOR', None)
env.pop('EXAKIT_NO_FANCY', None)
script, kind, needle, answer = sys.argv[1], sys.argv[2], sys.argv[3].encode(), sys.argv[4].encode()
pid, fd = pty.fork()
if pid == 0:
    os.execvpe('/bin/bash', ['/bin/bash', script, kind], env)
    os._exit(1)
buf = b''
asked_at = None
between = b''
answered = False
deadline = time.time() + 30
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.05)
    if r:
        try:
            d = os.read(fd, 65536)
        except OSError:
            break
        if not d:
            break
        buf += d
        if asked_at is not None and not answered:
            between += d
    if asked_at is None and needle in buf:
        asked_at = time.time()
        between = buf[buf.index(needle) + len(needle):]
    if asked_at is not None and not answered and time.time() - asked_at > 1.0:
        os.write(fd, answer + b'\r')
        answered = True
try:
    os.waitpid(pid, 0)
except OSError:
    pass
sys.stdout.buffer.write(between + b'\n=====\n' + buf)
EOF

run_kind() { # run_kind <kind> <needle> <answer> <label>
    _out="$(python3 "$WORK/ptyrun.py" "$WORK/scenario.sh" "$1" "$2" "$3" 2>&1)"
    _between="$(printf '%s' "$_out" | sed '/^=====$/,$d' | LC_ALL=C sed 's/\x1b\[[0-9;?]*[A-Za-z]//g')"
    _all="$(printf '%s' "$_out" | sed '1,/^=====$/d' | LC_ALL=C sed 's/\x1b\[[0-9;?]*[A-Za-z]//g')"
    case "$_all" in
        *"1/3  Data Loader"*) pass "$4: the bar ran before the question (the test is not vacuous)" ;;
        *) printf '  SKIP %s: no bar drew on this host - nothing to guard\n' "$4"; return 0 ;;
    esac
    case "$_all" in
        *"$2"*) pass "$4: the question was asked" ;;
        *) fail "$4: the question was never asked"; return 0 ;;
    esac
    case "$_between" in
        *"Data Loader"*) fail "$4: the bar drew over the question while it waited for the answer" ;;
        *) pass "$4: nothing drew over the question while it waited" ;;
    esac
    case "$_all" in
        *"ANSWER[$5]"*) pass "$4: the answer came through" ;;
        *) fail "$4: the answer did not come through" ;;
    esac
}

echo "== a hidden question asked from a subshell, as exapump_create_profile asks it"
run_kind hidden "(input hidden): " "secret" "hidden" "secret"
echo "== a yes/no question"
run_kind confirm "[Y/n]" "y" "confirm" "yes"
echo "== a text question asked from a subshell"
run_kind text "[starter-kit]" "mine" "text" "mine"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
