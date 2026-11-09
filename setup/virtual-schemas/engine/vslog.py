"""The virtual schema log: every statement and event of a run, no secret.

One file a day under the kit's log folder (<kit home>/logs, the folder the
shells' `exakit logs` lists), virtual-schemas-YYYYMMDD.log, created owner-only
(mode 600). Opening a day's file removes the ones dated more than KEEP_DAYS
days before it. A line is

    2026-11-09 17:20:01 [4242] connect sales SQL    CREATE CONNECTION "EXAKIT_SRC_SALES" TO '...' USER 'reader' IDENTIFIED BY '***'

time, process id, the engine command, the source it names ("-" for none), a
level and the text. The levels: START and END frame a run (START names the
--set keys, never their values); SQL is a statement the engine sent (its
further lines are marked "|"), SQLERR the database's answer when it failed
(the line a person reads, then the driver's own text without its stack
frames); OK, INFO, WARN and FAIL are the engine's own events, the lines a
person reads; TRACE is a fault's traceback.

Every text is redacted WHOLE before it is split, cut or hashed (redact):

  - the secrets this run knows (the credential on standard input, every
    value credential() derives from it, every statement's secrets) in each
    form they are written in: as given, quotes doubled, percent-encoded
    (both hex cases, + for a space, Java's %7E), JSON-escaped (\\/ too),
    whitespace collapsed as sql.summarize prints it, and each line of a
    multi-line one. A secret under SHORT characters is replaced only where
    it stands alone, so the password "postgres" does not turn every
    jdbc:postgresql:// into jdbc:***ql:// and give itself away;
  - the shapes a credential takes whoever's it is: IDENTIFIED BY '...' or
    "...", a parameter, property or JSON key whose name ends in password,
    pwd, token, secret, sig, signature, key, credential (sslpassword=,
    trustStorePassword=, "awsSecretAccessKey":, PWD = x, password: x,
    {pa;ss} braces), user:password@ in a URI and Oracle's user/password@.

A statement or a driver line over LONG characters is written as its first
HEAD characters and the sha256 of the REDACTED whole: an adapter script
carrying its Lua source would otherwise fill the file, and a digest of the
clear text would let a secret be guessed offline.

The kit's own database password is not registered: it never enters a
statement, sql.connect already removes it from its own error, and blanking a
password that is a common word (an adopted deployment's) out of every path
and name would give it away rather than hide it.

Logging never fails a command: a folder that cannot be written, a day file
that is a link or not a regular file, or any fault inside this module means
no log line, never an error. Every pattern runs in linear time: a hostile
source's error message cannot stall a connect.
"""

import datetime
import functools
import hashlib
import json
import os
import re
import stat
import time

from urllib.parse import quote, quote_plus

KEEP_DAYS = 14
LONG = 4000
HEAD = 1000
RAW_LINES = 40
SHORT = 12
NAME = re.compile(r"^virtual-schemas-(\d{8})\.log$")

# The words a credential's name ends in. A plain "name: value" takes only the
# unmistakable ones, and not an error code such as ExpiredToken: or NoSuchKey:.
_ANY = r"password|passwd|pwd|token|secret|signature|sig|accountkey|sharedaccesssignature|apikey|api[_-]?key|credentials?|key"
_STRONG = r"password|passwd|pwd|token|secret|accountkey|sharedaccesssignature|apikey|api[_-]?key|credentials?"
# The value after it: quoted (JSON escapes, SQL's doubled quote), braced (SQL
# Server's {pa;ss}) or bare up to the next separator. A quote or brace left
# open runs to the end of the line. Every alternative ends without a test
# that can fail, so a match never rescans what it read.
_VALUE = (r"(\"(?:[^\"\\\n]|\\.)*\"?"
          r"|'(?:[^'\n]|'')*'?"
          r"|\{(?:[^}\n]|\}\})*\}?"
          r"|(?:(?!%26|%3[Bb])[^&;\s'\"<>])+)")


def _masked(found):
    value = found.group(2)
    return found.group(1) + {'"': '"***"', "'": "'***'", "{": "{***}"}.get(value[:1], "***")


PATTERNS = (
    # CREATE CONNECTION ... IDENTIFIED BY '<secret>' (quotes doubled inside)
    # and CREATE USER ... IDENTIFIED BY "<secret>"; one left open (a message
    # cut short) to the end of the text.
    (re.compile(r"(IDENTIFIED\s+BY\s+)'(?:[^']|'')*(?:'|\Z)", re.I), r"\1'***'"),
    (re.compile(r'(IDENTIFIED\s+BY\s+)"(?:[^"]|"")*(?:"|\Z)', re.I), r'\1"***"'),
    # name=value and name%3Dvalue: ?password=, ;PWD = x, sslpassword=,
    # trustStorePassword=, &sig=, X-Amz-Signature=, AccountKey=, key=,
    # api_key=, credential=id:secret. The name starts where a name can.
    (re.compile(r"(?<![\w.-])((?i:[\w.-]*?(?:" + _ANY + r"))[ \t]*(?:=|%3[Dd])[ \t]*)" + _VALUE), _masked),
    # A JSON key: {"password": "x"}, "awsSecretAccessKey":"abc\/def".
    (re.compile(r'(?<=")((?i:[\w.-]*?(?:' + _ANY + r'))"[ \t]*:[ \t]*)' + _VALUE), _masked),
    # name: value - password:dapi..., (using password: YES), DB_PASSWORD: x.
    (re.compile(r"(?<![\w.-])((?:[a-z0-9_.-][\w.-]*?|[A-Z0-9_.-]*?)(?i:" + _STRONG + r")[ \t]*:[ \t]*)" + _VALUE),
     _masked),
    # Oracle's jdbc:oracle:thin:scott/tiger@//host.
    (re.compile(r"((?i:jdbc:oracle:[a-z0-9]+):[^\s'\"/@:]{0,256}/)[^\s'\"<>]{1,1024}@"), r"\1***@"),
    # user:password@host in a URI: the user up to the first colon, the
    # password up to the LAST @ before a space or quote, so one holding / or
    # @ goes whole (mongodb://alice@x.com:pa/ss@host). The scheme starts
    # where a scheme can, which keeps the scan linear.
    (re.compile(r"((?<![A-Za-z0-9+.\-])[A-Za-z][A-Za-z0-9+.\-]*://[^\s'\"<>:/]{0,256}:)[^\s'\"<>]{0,1024}@"),
     r"\1***@"),
)


def _lower_hex(text):
    return re.sub(r"%[0-9A-F]{2}", lambda found: found.group(0).lower(), text)


def forms(secret):
    """{base: the ways it is written} for a secret: as given, whitespace
    collapsed (sql.summarize), and each line of a multi-line one (a driver
    or a PEM printed line by line); each with quotes doubled, percent-encoded
    (%2F and %2f, + for a space, Java's %7E for ~) and JSON-escaped (\\/ too)."""
    bases = {secret, re.sub(r"\s+", " ", secret).strip()}
    if "\n" in secret or "\r" in secret:
        bases.update(line.strip() for line in secret.splitlines() if re.search(r"\w", line))
    found = {}
    for base in bases:
        if not base:
            continue
        encoded = {base, base.replace("'", "''"), base.replace('"', '""')}
        for text in (quote(base, safe=""), quote_plus(base, safe=""), quote(base, safe="").replace("~", "%7E"),
                     quote_plus(base, safe="*").replace("~", "%7E")):
            encoded.update((text, _lower_hex(text)))
        for text in (json.dumps(base)[1:-1], json.dumps(base, ensure_ascii=False)[1:-1]):
            encoded.update((text, text.replace("/", "\\/")))
        found[base] = encoded
    return found


def _alone(form):
    """A short secret's form, matched only where it stands alone."""
    return "%s%s%s" % ("(?<!\\w)" if re.match(r"\w", form) else "", re.escape(form),
                       "(?!\\w)" if re.search(r"\w$", form) else "")


@functools.lru_cache(maxsize=32)
def _matchers(secrets):
    plain, alone = set(), set()
    for secret in secrets:
        for base, encoded in forms(secret).items():
            (plain if len(base) >= SHORT else alone).update(f for f in encoded if f)
    found = []
    if plain:
        found.append(re.compile("|".join(re.escape(f) for f in sorted(plain, key=len, reverse=True))))
    if alone:
        found.append(re.compile("|".join(_alone(f) for f in sorted(alone, key=len, reverse=True))))
    return found


def redact(text, secrets=()):
    """text with every form of every secret, and every credential shape, as ***."""
    text = str(text)
    for matcher in _matchers(tuple(sorted(set(str(s) for s in secrets if s)))):
        text = matcher.sub("***", text)
    for pattern, replacement in PATTERNS:
        text = pattern.sub(replacement, text)
    return text


def digest(text):
    """A text over LONG characters (already redacted): its head and the sha256 of the whole."""
    if len(text) <= LONG:
        return text
    return "%s ... [%d characters, sha256 %s]" % (text[:HEAD], len(text),
                                                  hashlib.sha256(text.encode("utf-8", "surrogatepass")).hexdigest())


class Null(object):
    """No log: the commands that are not logged, and a file that cannot be written."""
    path = None
    secrets = frozenset()

    def secret(self, *values):
        pass

    def scrub(self, text):
        """text redacted of this run's secrets and every credential shape (for
        what goes elsewhere: a traceback on stderr)."""
        try:
            return redact(text, self.secrets)
        except Exception:  # noqa: BLE001 - never the clear text
            return "(a text that could not be redacted was left out)\n"

    def write(self, level, text):
        pass

    def statement(self, sql_text, secrets=()):
        pass

    def failed(self, message, kind, raw, secrets=()):
        pass

    def close(self):
        pass


NULL = Null()


class RunLog(Null):
    def __init__(self, folder, command, source, today=None):
        self.command = command or "-"
        self.source = source or "-"
        self.secrets = set()
        self.handle = None
        today = today or datetime.date.today()
        try:
            os.makedirs(folder, exist_ok=True)
            self.path = os.path.join(folder, "virtual-schemas-%s.log" % today.strftime("%Y%m%d"))
            self.handle = _open(self.path)
        except (OSError, ValueError):
            self.path, self.handle = None, None
            return
        prune(folder, today)

    def secret(self, *values):
        try:
            for value in values:
                if value:
                    self.secrets.add(str(value))
        except Exception:  # noqa: BLE001 - logging never fails a command
            pass

    def write(self, level, text):
        if self.handle is None:
            return
        try:
            stamp = "%s [%d] %s %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), os.getpid(), self.command, self.source)
            lines = redact(text, self.secrets).splitlines() or [""]
            for i, line in enumerate(lines):
                self.handle.write("%s %-6s %s\n" % (stamp, level if i == 0 or level != "SQL" else "|", line))
            self.handle.flush()
        except (OSError, ValueError):
            self.handle = None
        except Exception:  # noqa: BLE001 - logging never fails a command
            pass

    def statement(self, sql_text, secrets=()):
        """A statement, before it is sent; the secrets it carries are this
        run's from now on, so the database's answer is redacted of them too."""
        self.secret(*secrets)
        if self.handle is None:
            return
        try:
            self.write("SQL", digest(redact(sql_text, self.secrets)))
        except Exception:  # noqa: BLE001 - logging never fails a command
            pass

    def failed(self, message, kind, raw, secrets=()):
        """The database's answer to a failed statement: the line a person
        reads, then the answer as the driver gave it - redacted whole first,
        so a secret the driver printed across lines is caught - without the
        stack frames of a Java trace (at ..., ... N more), at most RAW_LINES."""
        self.secret(*secrets)
        if self.handle is None:
            return
        try:
            self.write("SQLERR", "[%s] %s" % (kind, message))
            text = redact(str(raw), self.secrets)
            lines = [l.strip() for l in text.splitlines()
                     if l.strip() and l.strip() != message and not re.match(r"\s*(?:at |\.\.\. \d+ more)", l)]
            for line in lines[:RAW_LINES]:
                self.write("SQLERR", "  " + digest(line))
        except Exception:  # noqa: BLE001 - logging never fails a command
            pass

    def close(self):
        if self.handle is not None:
            try:
                self.handle.close()
            except (OSError, ValueError):
                pass
            self.handle = None


def _open(path):
    """The day file for appending, owner-only. Never through a link (its
    target's mode would change), never a FIFO or device (it would block or
    swallow the run): those are no log."""
    flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    fd = os.open(path, flags, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError("%s is not a regular file" % path)
        if hasattr(os, "fchmod"):
            # A file an older kit or another umask made: owner-only all the same.
            os.fchmod(fd, 0o600)
        return os.fdopen(fd, "a", encoding="utf-8", errors="backslashreplace", newline="\n")
    except Exception:
        os.close(fd)
        raise


def prune(folder, today):
    """Remove the day files dated more than KEEP_DAYS days before today."""
    try:
        names = os.listdir(folder)
    except OSError:
        return
    for name in names:
        found = NAME.match(name)
        if not found:
            continue
        try:
            day = datetime.datetime.strptime(found.group(1), "%Y%m%d").date()
        except ValueError:
            continue
        if (today - day).days > KEEP_DAYS:
            try:
                os.remove(os.path.join(folder, name))
            except OSError:
                pass
