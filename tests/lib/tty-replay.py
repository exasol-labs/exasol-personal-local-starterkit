# usage: tty-replay.py <scenario.sh> <repo-root> [table-title] [keystrokes] [boxes]
# TTY_REPLAY_COLS sets the emulated terminal width (default 80); the scenario is
# told the same width, so the table sizes itself to the screen it is replayed on.
#
# <table-title> is the title in the table's top border, so a scenario for
# another caller of the same component can be asserted the same way.
# <boxes> is the total number of boxes expected on the final screen (default 1),
# for a scenario that prints a static panel above the live table.
# <keystrokes> are typed INTO the scenario, e.g. 'jj \r' for down, down, Space,
# Enter (python escapes are honoured, so '\e[B' is the Down arrow; '\x01' is a
# one-second pause).
#
# '\x02TEXT\x03' is a WAIT, not a key: nothing more is typed until TEXT has
# appeared in what the scenario wrote since the last key (colours and cursor
# moves taken out), and then only after a short settle, so the program is
# reading by the time the key lands. TEXT is plain ASCII, matched as written.
# A wait that is not met within TTY_REPLAY_WAIT seconds (default 120), or that
# the scenario exits before meeting, kills the run and says so in the report
# ("=== WAIT ... ===", with the tail of what the scenario wrote last), with
# exit 1. Those waits are what catches a hang, so the run as a whole is given
# as long as a loaded machine needs (20 minutes; 5 after the last key). A scenario whose questions arrive between
# engine round-trips waits for each question before answering it: the clock
# alone types into a quiet screen, and quiet means busy as often as it means
# waiting - a key typed while the program works, or switches the terminal to a
# hidden prompt, is lost or answers the wrong question. Keystrokes without a
# wait keep the clock below, unchanged. With waits, the keys of one answer go
# in 0.05 s apart (TTY_REPLAY_KEY_GAP sets another gap, for a slow console).
#
# The pty is driven directly rather than through pty.spawn, for two reasons that
# both showed up as a wrong screen. It asks for keystrokes only when OUR stdin
# has some, so a run from an interactive terminal is never asked and hangs on a
# menu waiting for a key nobody sends; and its one loop cannot both wait to send
# the next key and keep draining the terminal, so the pty's buffer fills, the
# scenario BLOCKS half way through writing a frame, and the keys that arrive
# meanwhile are echoed into the middle of it. Here the output is drained
# continuously and each key goes in on a clock of its own -- a beat apart, and
# the first only once the menu is up, because bytes pushed in before that sit in
# the line discipline, which is free to drop them when `read -n1` takes the
# terminal out of canonical mode.
import pty, os, re, sys, time, select, struct, fcntl, termios, subprocess
title = sys.argv[3] if len(sys.argv) > 3 else 'Datasets to load'
keys = []
if len(sys.argv) > 4 and sys.argv[4]:
    _text = sys.argv[4].encode('utf-8').decode('unicode_escape')
    _i = 0
    while _i < len(_text):
        if _text[_i] == '\x02':
            _end = _text.find('\x03', _i + 1)
            if _end < 0:
                sys.exit("tty-replay: a wait (\\x02...) has no closing \\x03")
            _want = _text[_i + 1:_end]
            if not _want or any(ord(_c) > 126 or ord(_c) < 32 for _c in _want):
                sys.exit("tty-replay: a wait's text must be plain printable ASCII: %r" % _want)
            keys.append(('wait', _want))
            _i = _end + 1
            continue
        keys.append(_text[_i])
        _i += 1
WAITS = any(isinstance(_k, tuple) for _k in keys)
WAIT_SECS = float(os.environ.get('TTY_REPLAY_WAIT', '120'))
# After a wait is met: long enough for the program to go from printing its
# question to reading the answer, under load too.
SETTLE = 0.3
# Between the keys of one answer: a scenario that waits for its questions
# types the rest at once, a terminal's line editor reads them in any rhythm;
# one without a wait keeps its beat.
KEY_GAP = float(os.environ.get('TTY_REPLAY_KEY_GAP') or (0.05 if WAITS else 0.35))
SHOWN = re.compile(r'\x1b\[[0-9;?]*[A-Za-z]|\x1b[=>]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)?|[\x01\x02]')
master, slave = pty.openpty()
# A definite window size: the table sizes its columns from the terminal, so
# every assertion below is about a screen 80 columns wide.
COLS = int(os.environ.get('TTY_REPLAY_COLS', '80'))
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, COLS, 0, 0))
# _ui_term_cols reads COLUMNS first and falls back to `stty size < /dev/tty` --
# which is the REAL terminal running the suite, not the pty above. Without this
# the table sized itself to one width and was replayed at another, and the
# mismatch that matters here (a row that fills the last column) could not happen.
env = dict(os.environ); env['COLUMNS'] = str(COLS)
# The FANCY palette, guaranteed rather than inherited. ui_detect turns it off
# for a "dumb" TERM, a non-UTF-8 locale, NO_COLOR, or EXAKIT_NO_FANCY -- and a
# CI step supplies several of those. Without the fancy palette the table refuses
# to draw at all, the one-line bar prints instead, and every assertion below
# counts zero boxes: the suite went green on a developer's macOS terminal and
# red on Linux for a reason that had nothing to do with the code under test.
#
# This harness exists to exercise the fancy table specifically. Anything that
# cannot run it should say so, not quietly measure the fallback.
env['TERM'] = 'xterm-256color'
env['LC_ALL'] = 'C.UTF-8'
env.pop('NO_COLOR', None)
env.pop('EXAKIT_NO_FANCY', None)
# TTY_REPLAY_CTTY=1: the pty becomes the scenario's controlling terminal, so
# /dev/tty is this pty as it is in a real terminal. Opt-in: a scenario whose
# prompts read /dev/tty (the line-by-line `exakit connect`, a hidden prompt)
# needs it; without it /dev/tty is whatever ran the suite, or nothing.
def _ctty():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)
proc = subprocess.Popen(['/bin/bash', sys.argv[1], sys.argv[2]], env=env,
                        stdin=slave, stdout=slave, stderr=slave, close_fds=True,
                        preexec_fn=_ctty if os.environ.get('TTY_REPLAY_CTTY') else None)
os.close(slave)
out = []
next_key = time.time() + 1.2
# A scenario that waits for its questions answers each one as soon as it is
# asked, however slowly the machine gets there: its own waits time out, so the
# whole run may take as long as a loaded machine needs.
deadline = time.time() + (1200 if WAITS else 120)
since = bytearray()          # what the scenario wrote since the last key
fresh = False                # ... and whether some of it is not checked yet
wait_since = None            # when the wait at the head of the keys began
wait_failed = ''

def wait_met():
    """The wait at the head of the keys, checked against what was written
    since the last key: met (popped, the next key after the settle) or not."""
    global next_key, wait_since, fresh
    fresh = False
    if SHOWN.sub('', since.decode('utf-8', 'replace')).find(keys[0][1]) < 0:
        return False
    keys.pop(0)
    wait_since = None
    next_key = max(next_key, time.time() + SETTLE)
    return True

while True:
    if time.time() > deadline:
        if keys and isinstance(keys[0], tuple):
            wait_failed = 'the run passed its deadline waiting for: %s' % keys[0][1]
        proc.kill()
        break
    ready, _, _ = select.select([master], [], [], 0.05)
    if ready:
        try:
            chunk = os.read(master, 65536)
        except OSError:                 # EIO: the far end of the pty has gone
            break
        if not chunk:
            break
        out.append(chunk)
        since.extend(chunk)
        fresh = True
        # A live table never goes quiet for long: a wait is checked as the
        # output arrives, not only in the gaps.
        if keys and isinstance(keys[0], tuple):
            wait_met()
        continue
    if keys and isinstance(keys[0], tuple):
        if wait_since is None:
            wait_since = time.time()
        if fresh and wait_met():
            continue
        if time.time() - wait_since > WAIT_SECS:
            wait_failed = 'nothing showed %r within %.0f s' % (keys[0][1], WAIT_SECS)
            proc.kill()
            break
    elif keys and time.time() >= next_key:
        k = keys.pop(0)
        if k == '\x01':
            # A PAUSE, not a key: '\x01' in the keystrokes waits a second, for a
            # scenario that throws away what was typed while it worked (the
            # connect table discards an impatient Enter) - the next key has to
            # arrive once it is listening again.
            next_key = time.time() + 1.0
            continue
        os.write(master, k.encode('utf-8'))
        since = bytearray()
        fresh = False
        next_key = time.time() + KEY_GAP
        if not keys:
            # Every key typed: what is left is the scenario finishing.
            deadline = min(deadline, time.time() + (300 if WAITS else 120))
        continue
    if proc.poll() is not None:
        break
if not wait_failed and keys and isinstance(keys[0], tuple):
    wait_failed = 'the scenario ended before showing %r' % keys[0][1]
proc.wait()
raw = b''.join(out).decode('utf-8', 'replace')
# TTY_REPLAY_RAW=<file>: everything the scenario wrote, colours and cursor moves
# taken out, in that file - for what a person saw on the way that the final
# screen no longer holds (a refused answer, a prompt's (required) mark).
if os.environ.get('TTY_REPLAY_RAW'):
    with open(os.environ['TTY_REPLAY_RAW'], 'w', encoding='utf-8') as f:
        f.write(re.sub(r'\x1b\[[0-9;?]*[A-Za-z]|\x1b[=>]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)?|[\x01\x02]', '', raw))

# Minimal terminal: rows, cursor, ESC[nA (up), ESC[nJ (clear to end), ESC[K, \r
scr, cur, col = [], 0, 0
worst_per_line, worst_total = 0, 0
def put(ch):
    global cur, col
    while len(scr) <= cur: scr.append('')
    line = scr[cur]
    if col > len(line): line = line + ' ' * (col - len(line))
    scr[cur] = line[:col] + ch + line[col+1:]
    col += 1
    # A terminal wraps when the last column is written, and the row the frame
    # then occupies is one taller than the height the animator moves the cursor
    # up by -- which strands the top of the previous frame on screen. Modelling
    # it is the difference between catching that and asserting a clean screen
    # while the user watches the table flicker into two.
    if col >= COLS:
        cur += 1
        col = 0
i = 0
while i < len(raw):
    c = raw[i]
    if c == '\x1b':
        m = re.match(r'\x1b\[(\d*)([A-Za-z])', raw[i:])
        if m:
            n = int(m.group(1) or 1); k = m.group(2)
            if k == 'A': cur = max(0, cur - n); col = 0
            elif k == 'B': cur += n
            elif k == 'J':
                while len(scr) <= cur: scr.append('')
                scr[cur] = scr[cur][:col]; del scr[cur+1:]
            elif k == 'K':
                while len(scr) <= cur: scr.append('')
                scr[cur] = scr[cur][:col]
            i += m.end(); continue
        m = re.match(r'\x1b\[\?25[lh]', raw[i:])
        if m: i += m.end(); continue
        # Invisible on a real terminal, and emitted by .NET's console on Unix
        # around every ReadLine (the PowerShell scenarios): any other private
        # mode (keypad: ESC[?1h), the keypad switches ESC= / ESC>, and a window
        # title (OSC ... BEL). Printed as text here they would widen a line
        # until it wrapped, and the replay would report stacking a terminal
        # never shows.
        m = re.match(r'\x1b\[\?[0-9;]*[lh]|\x1b[=>]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)?', raw[i:])
        if m: i += m.end(); continue
        m = re.match(r'\x1b\[[0-9;]*m', raw[i:])
        if m: i += m.end(); continue
    if c == '\n':
        cur += 1; col = 0
        # The worst INSTANT, not the final screen. Both failures this catches are
        # transient -- the last frame repaints over the evidence while the user
        # has already watched the table double. Borders side by side on ONE line
        # mean a frame was drawn from a column something else left the cursor in
        # (cursor-up preserves the column); borders on separate lines mean a
        # frame was taller than the height the animator moves up by.
        _now = re.sub(r'\x1b\[[0-9;]*m', '', '\n'.join(scr))
        for _l in _now.split('\n'):
            _n = _l.count('╭─ ' + title)
            if _n > worst_per_line: worst_per_line = _n
        _t = _now.count('╭─ ' + title)
        if _t > worst_total: worst_total = _t
    elif c == '\r': col = 0
    else: put(c)
    i += 1
screen = '\n'.join(scr).rstrip('\n')
# How many boxes the screen should end up holding IN TOTAL. A scenario may print
# a static panel above the live table on purpose, and a live table that miscounts
# its own height eats that panel -- which shows up as a bottom border missing
# rather than a top border extra, so it needs its own number.
want_bots = int(sys.argv[5]) if len(sys.argv) > 5 else 1
tops = screen.count('╭─ ' + title)
bots = screen.count('╰')
print("=== FINAL SCREEN ===")
print(screen)
# A screen with no box glyphs AT ALL is a palette failure, not a stacking bug.
# Said plainly, because "0 top borders" read for hours like the table had
# vanished when the table had simply never been fancy enough to draw.
if '\u256d' not in screen and '\u2570' not in screen:
    print("=== NO BOX GLYPHS ON SCREEN: the plain palette was in effect, so the "
          "table never drew and this measured the one-line fallback. Check TERM, "
          "the locale, NO_COLOR and EXAKIT_NO_FANCY. ===")
print("=== tables on screen: %d top borders, %d bottom borders (wanted 1 and %d) ==="
      % (tops, bots, want_bots))

# The screen is not the whole story. When bash reaps a background job that was
# killed, it prints the job's own source at the terminal -- and a later redraw
# can paint over the evidence while the damage to the cursor arithmetic is
# already done. So count it in the RAW stream, where nothing can overwrite it.
noise = len(re.findall(r'Terminated:? *\d*|Killed:? *\d*', raw))
print("=== shell job announcements: %d ===" % noise)
# A spinner frame anywhere in the raw stream while a table is meant to own the
# line is a SECOND animator. It cannot be seen on the screen -- the table's next
# frame paints over it -- but it is writing to the same terminal, without a
# newline, five to twelve times a second.
spin = sum(raw.count(g) for g in '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏')
print("=== spinner frames in stream: %d ===" % spin)
print("=== worst instant: %d tables on screen, %d on one line ==="
      % (worst_total, worst_per_line))
if wait_failed:
    print("=== WAIT FAILED: %s ===" % wait_failed)
    # What the scenario wrote last, for the next person to read the failure.
    print("=== since the last key, the end: %r ===" % SHOWN.sub('', since.decode('utf-8', 'replace'))[-400:])
sys.exit(0 if (tops == 1 and bots == want_bots and noise == 0
               and worst_per_line <= 1 and worst_total <= 1 and not wait_failed) else 1)
