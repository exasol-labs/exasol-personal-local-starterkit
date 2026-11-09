"""The virtual schema log: every statement and event of a run, no secret.

One file a day under the kit's log folder (<kit home>/logs, the folder the
shells' `exakit logs` lists), virtual-schemas-YYYYMMDD.log, created owner-only
(mode 600). Opening a day's file removes the ones dated more than KEEP_DAYS
days before it. A line is

    2026-11-09 17:20:01 [4242] connect sales SQL    CREATE CONNECTION "EXAKIT_SRC_SALES" TO '...' USER 'reader' IDENTIFIED BY '***'

time, process id, the engine command, the source it names ("-" for none), a
level and the text. The levels: START and END frame a run; SQL is a statement
the engine sent (its further lines are marked "|"), SQLERR the database's
answer when it failed (the line a person reads, then the driver's own text
without its stack frames); OK, INFO, WARN and FAIL are the engine's own events,
the lines a person reads; TRACE is a fault's traceback.

Every line is redacted before it is written: the secrets this run knows (the
credential on standard input, and every value a statement was sent with as a
secret) wherever they appear, and the shapes a credential takes in SQL and in
a URL whoever's it is (IDENTIFIED BY '...', password= / pwd= / token= / sig=
parameters, user:password@ in a URI). A statement over LONG characters is
written as its first HEAD characters and the sha256 of the redacted whole: an
adapter script carrying its Lua source would otherwise fill the file.

The kit's own database password is not registered: it never enters a
statement, sql.connect already removes it from its own error, and blanking a
password that is a common word (an adopted deployment's) out of every path
and name would give it away rather than hide it.

Logging never fails a command: a folder that cannot be written means no log.
"""

import datetime
import hashlib
import json
import os
import re
import time

from urllib.parse import quote

KEEP_DAYS = 14
LONG = 4000
HEAD = 1000
RAW_LINES = 40
NAME =re.compile(r"^virtual-schemas-(\d{8})\.log$")

# Whoever's credential it is: the shapes, not the values.
PATTERNS = (
    # CREATE CONNECTION ... IDENTIFIED BY '<secret>' (a string literal, quotes
    # doubled inside) and CREATE USER ... IDENTIFIED BY "<secret>".
    (re.compile(r"(IDENTIFIED\s+BY\s+)'(?:[^']|'')*'", re.I), r"\1'***'"),
    (re.compile(r'(IDENTIFIED\s+BY\s+)"(?:[^"]|"")*"', re.I), r'\1"***"'),
    # A URL or JDBC parameter that carries one (?password=, ;pwd=, &sig= of an
    # Azure SAS, X-Amz-Signature=, an Azure connection string's AccountKey=),
    # percent-encoded separators included.
    (re.compile(r"(\b(?:password|passwd|pwd|token|access_token|sig|signature|secret|client_secret|accountkey|"
                r"sharedaccesssignature)(?:=|%3D))(?:(?!%26|%3B)[^&;\s'\"<>])+", re.I), r"\1***"),
    # user:password@host in a URI: up to the last @ of the authority, so a
    # password with an unencoded @ goes whole.
    (re.compile(r"(\b[A-Za-z][A-Za-z0-9+.\-]*://[^/\s:@'\"]*:)[^\s'\"/]*@"), r"\1***@"),
)


def forms(secret):
    """The ways a secret is written where this engine puts it: as given, as a
    SQL string literal ('' for '), percent-encoded in a URL, escaped in JSON."""
    found = [secret, secret.replace("'", "''"), quote(secret, safe=""), json.dumps(secret)[1:-1],
             json.dumps(secret, ensure_ascii=False)[1:-1]]
    # The longest first: a form that contains another is replaced whole.
    return sorted(set(f for f in found if f), key=len, reverse=True)


def redact(text, secrets=()):
    """text with every form of every secret, and every credential shape, as ***."""
    text = str(text)
    for secret in sorted(set(s for s in secrets if s), key=len, reverse=True):
        for form in forms(secret):
            text = text.replace(form, "***")
    for pattern, replacement in PATTERNS:
        text = pattern.sub(replacement, text)
    return text


def digest(text):
    """A statement over LONG characters: its head and the sha256 of the whole."""
    if len(text) <= LONG:
        return text
    return "%s ... [%d characters, sha256 %s]" % (text[:HEAD], len(text),
                                                  hashlib.sha256(text.encode("utf-8")).hexdigest())


class Null(object):
    """No log: the commands that are not logged, and a folder that cannot be written."""
    path = None

    def secret(self, *values):
        pass

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
            fd = os.open(self.path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            try:
                # A file an older kit or another umask made: owner-only all the same.
                os.chmod(self.path, 0o600)
            except OSError:
                pass
            self.handle = os.fdopen(fd, "a", encoding="utf-8", newline="\n")
        except OSError:
            self.path, self.handle = None, None
            return
        prune(folder, today)

    def secret(self, *values):
        for value in values:
            if value:
                self.secrets.add(str(value))

    def write(self, level, text):
        if self.handle is None:
            return
        stamp = "%s [%d] %s %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), os.getpid(), self.command, self.source)
        lines = redact(text, self.secrets).splitlines() or [""]
        try:
            for i, line in enumerate(lines):
                self.handle.write("%s %-6s %s\n" % (stamp, level if i == 0 or level != "SQL" else "|", line))
            self.handle.flush()
        except (OSError, ValueError):
            self.handle = None

    def statement(self, sql_text, secrets=()):
        """A statement, before it is sent; the secrets it carries are this
        run's from now on, so the database's answer is redacted of them too."""
        self.secret(*secrets)
        if self.handle is not None:
            self.write("SQL", digest(redact(sql_text, self.secrets)))

    def failed(self, message, kind, raw, secrets=()):
        """The database's answer to a failed statement: the line a person
        reads, then the answer as the driver gave it, without the stack frames
        of a Java trace (at ..., ... N more) and at most RAW_LINES lines."""
        self.secret(*secrets)
        self.write("SQLERR", "[%s] %s" % (kind, message))
        lines = [l.strip() for l in str(raw).splitlines()
                 if l.strip() and not re.match(r"\s*(?:at |\.\.\. \d+ more)", l)]
        for line in lines[:RAW_LINES]:
            self.write("SQLERR", "  " + digest(line))

    def close(self):
        if self.handle is not None:
            try:
                self.handle.close()
            except OSError:
                pass
            self.handle = None


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
