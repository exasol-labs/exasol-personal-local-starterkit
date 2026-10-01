# usage: tty-replay.py <scenario.sh> <repo-root> [table-title] [keystrokes] [boxes]
# TTY_REPLAY_COLS sets the emulated terminal width (default 80); the scenario is
# told the same width, so the table sizes itself to the screen it is replayed on.
#
# <table-title> is the title in the table's top border, so a scenario for
# another caller of the same component can be asserted the same way.
# <boxes> is the total number of boxes expected on the final screen (default 1),
# for a scenario that prints a static panel above the live table.
# <keystrokes> are typed INTO the scenario, e.g. 'jj \r' for down, down, Space,
# Enter (python escapes are honoured, so '\e[B' is the Down arrow).
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
    keys = list(sys.argv[4].encode('utf-8').decode('unicode_escape'))
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
proc = subprocess.Popen(['/bin/bash', sys.argv[1], sys.argv[2]], env=env,
                        stdin=slave, stdout=slave, stderr=slave, close_fds=True)
os.close(slave)
out = []
next_key = time.time() + 1.2
deadline = time.time() + 120
while True:
    if time.time() > deadline:
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
        continue
    if keys and time.time() >= next_key:
        os.write(master, keys.pop(0).encode('utf-8'))
        next_key = time.time() + 0.35
        continue
    if proc.poll() is not None:
        break
proc.wait()
raw = b''.join(out).decode('utf-8', 'replace')

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
sys.exit(0 if (tops == 1 and bots == want_bots and noise == 0
               and worst_per_line <= 1 and worst_total <= 1) else 1)
