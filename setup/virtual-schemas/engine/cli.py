"""The virtual schema coordinator, called by setup/lib/virtual-schemas.{sh,ps1}.

    cli.py [context] catalog    [--query Q] [--public-ip]
    cli.py [context] resolve    QUERY
    cli.py [context] inputs     CONNECTOR
    cli.py [context] field      CONNECTOR INPUT [--base64]   (the value on standard input)
    cli.py [context] paste      CONNECTOR [--base64] [--secret-out FILE | --credential-given] [--as INPUT]
                                (a connection string on standard input)
    cli.py [context] draft      CONNECTOR --name N [--set KEY=VALUE ...] --secret-stdin
                                (an EDML mapping drafted from the bucket or container, edml_draft.py)
    cli.py [context] plan       CONNECTOR --name N [--set KEY=VALUE ...] [--secret-given]
    cli.py [context] connect    CONNECTOR --name N [--set KEY=VALUE ...] [--secret-stdin]
    cli.py [context] list | issues [--status S] | show N | check N|--all
    cli.py [context] reauth     N --secret-stdin
    cli.py [context] refresh    N
    cli.py [context] describe   N [TABLE] [--ddl] [--into SCHEMA]
    cli.py [context] disconnect N [--dry-run]
    cli.py [context] remove     N [--dry-run]

    context: --defs DIR --kit-home DIR --deployment-dir DIR --dsn HOST:PORT
             --user USER --password-file FILE [--json]

plan and connect for a name that is a connected source of the same connector
re-point it in place (lifecycle.Engine.repoint): the recorded inputs with the
given ones over them, VS_<NAME> kept, and the credential given again - always
(the database never returns a stored one, and moving a CONNECTION clears it).
Their answer has "action": the plan's is connect, reconnect, repoint or
unchanged (nothing would change: the same inputs and no credential), the
result's connected, reconnected, repointed or unchanged. A re-point's adds
"changes" ([{input, from, to}]) and "credential" ("required" in the plan,
"replaced" in the result), and its plan "command", the connect that makes it
without its credential or --yes; "interrupted" is true when an earlier
re-point left its journal. An unchanged source that is not ready answers exit
1 with its error, kind, remedy and command. A name taken by another connector
is a conflict (exit 3).

A secret is read from standard input only (--secret-stdin), never from an
argument: arguments are visible to every local user through the process table.
It is read as UTF-16 by its byte-order mark, else as UTF-8 with or without
one (decode_secret); anything else is refused. --secret-stdin-base64
takes it base64-encoded instead: the Windows bridge sends it so, because
Windows PowerShell 5.1 re-encodes what it pipes to a native program (measured
on CI: a byte-order mark added, every non-ASCII character turned into '?'),
and plain ASCII survives every code page.

Without --json, one "OK|INFO|WARN|FAIL <text>" line per event on stdout for
the shell to render. With --json, events go to stderr and stdout carries one
JSON object, and only that, whatever happens; for plan and connect (and
paste, the step connect --url takes first) it always has public_ip
(publicip.py), null when it is not known or the source is not on the
internet. A failure is

    {"ok": false, "error": <what happened>, "kind": <its class>,
     "remedy": <the fix, in words>, "command": <the exakit command that is the
     fix, or null>}

the shape `check` has always answered with (plus command), with "choices" when
the input was ambiguous. An unexpected exception is kind "internal": one line
in error, the traceback on stderr. Exit codes: 0 done, 1 failed, 2 bad input,
3 conflict, 4 no such source, 5 gated, 20 Java in the database cannot resolve
host names, 21 Java is not installed in the database, 22 the local database is
unreachable, 23 the Rust language container is not installed.

The commands that act on sources (LOGGED) also write the day's log under
<kit home>/logs (vslog.py): the command, every statement sent and every
event above, each redacted of the run's secrets.
"""

import argparse
import base64
import binascii
import codecs
import json
import os
import re
import sys
import time
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# A kit copy updated by halves can fail here, before main() runs; that too is
# answered in the one shape below (kind "internal"), not with a bare traceback.
try:
    import lifecycle  # noqa: E402
    import paste  # noqa: E402
    import plan as planner  # noqa: E402
    import publicip  # noqa: E402
    import sources  # noqa: E402
    import vslog  # noqa: E402
    BROKEN = None
except Exception:  # noqa: BLE001
    BROKEN = traceback.format_exc()


def parse(argv):
    parser = argparse.ArgumentParser(prog="cli.py")
    parser.add_argument("--defs", required=True)
    parser.add_argument("--kit-home", required=True)
    parser.add_argument("--deployment-dir", default="")
    parser.add_argument("--dsn", default="")
    parser.add_argument("--user", default="sys")
    parser.add_argument("--password-file", default="")
    parser.add_argument("--json", action="store_true")
    sub = parser.add_subparsers(dest="command")
    cmd = sub.add_parser("catalog")
    cmd.add_argument("--query", default="")
    # The connect menu's first line: this computer's public IP (publicip.py),
    # an INFO event when it is known and public_ip in the result either way.
    cmd.add_argument("--public-ip", action="store_true")
    sub.add_parser("resolve").add_argument("query")
    sub.add_parser("inputs").add_argument("connector")
    cmd = sub.add_parser("field")
    cmd.add_argument("connector")
    cmd.add_argument("input")
    cmd.add_argument("--base64", action="store_true")
    cmd = sub.add_parser("paste")
    cmd.add_argument("connector")
    cmd.add_argument("--base64", action="store_true")
    # The credential the string holds, where the connector's stands, is
    # written to this file (the shell's own, owner-only) - never to stdout,
    # --json or the log - and the shell uses it as typed (paste.py).
    cmd.add_argument("--secret-out", default="")
    # --password-file or --password-stdin gives the credential: the string's is not used.
    cmd.add_argument("--credential-given", action="store_true")
    # The string is the value of this input, given with --set (uri=...).
    cmd.add_argument("--as", dest="only", default="")
    cmd = sub.add_parser("draft")
    cmd.add_argument("connector")
    cmd.add_argument("--name", required=True)
    cmd.add_argument("--set", action="append", default=[], metavar="KEY=VALUE")
    cmd.add_argument("--secret-stdin", action="store_true")
    cmd.add_argument("--secret-stdin-base64", action="store_true")
    for name in ("plan", "connect"):
        cmd = sub.add_parser(name)
        cmd.add_argument("connector")
        cmd.add_argument("--name", required=True)
        cmd.add_argument("--set", action="append", default=[], metavar="KEY=VALUE")
        cmd.add_argument("--secret-stdin", action="store_true")
        cmd.add_argument("--secret-stdin-base64", action="store_true")
        cmd.add_argument("--dry-run", action="store_true")
        # A credential will come with the connect (the shell knows before it
        # reads one): the plan of a connected source with no other change is
        # then a re-point that replaces only the credential, not "unchanged" -
        # a given --password-file is never dropped unread.
        cmd.add_argument("--secret-given", action="store_true")
    # The language containers (java, rust) of those named that the database
    # lacks: the terminal flow prepares the database before its table.
    sub.add_parser("languages").add_argument("need", nargs="*")
    sub.add_parser("list")
    sub.add_parser("issues").add_argument("--status", default="")
    sub.add_parser("show").add_argument("name")
    cmd = sub.add_parser("check")
    cmd.add_argument("name", nargs="?")
    cmd.add_argument("--all", action="store_true")
    cmd = sub.add_parser("reauth")
    cmd.add_argument("name")
    cmd.add_argument("--secret-stdin", action="store_true")
    cmd.add_argument("--secret-stdin-base64", action="store_true")
    sub.add_parser("refresh").add_argument("name")
    cmd = sub.add_parser("describe")
    cmd.add_argument("name")
    cmd.add_argument("table", nargs="?", default="")
    cmd.add_argument("--ddl", action="store_true")
    cmd.add_argument("--into", default="")
    for name in ("disconnect", "remove"):
        cmd = sub.add_parser(name)
        cmd.add_argument("name")
        cmd.add_argument("--dry-run", action="store_true")
    return parser.parse_args(argv)


# A failure's class when nothing classified it further: its exit code says it.
KIND_FOR_CODE = {2: "input", 3: "conflict", 4: "missing", 5: "gated", 20: "dns", 21: "nojava",
                 22: "unreachable_db", 23: "norust"}

# The fix for a failure that names none of its own, by kind; never null, so a
# reader always has the next step in words.
REMEDY_FOR_KIND = {
    "input": "correct what the error names and run the same command again",
    "conflict": "choose another name, or remove what holds this one first",
    "missing": "name a source that exists; they are listed by: exakit source list",
    "gated": "connect another source; the ones available are listed by: exakit source catalog",
    "dns": "Java in the database could not resolve the host name; restart the database - exakit stop, then "
           "exakit start (the start gives Java the deployment's DNS) - then try again",
    "nojava": "exakit connect installs the Java language container with one database "
              "restart - asked on a terminal, --yes for a script - or run: exasol slc install java",
    "norust": "exakit connect installs the Rust language container with one database "
              "restart - asked on a terminal, --yes for a script",
    "unreachable_db": "the local database did not answer: start it (exakit start), then try again",
    "internal": "a fault in the kit, not in the input: the traceback is in the log (exakit logs); report it with that",
    "error": "see the log: exakit logs",
}

# The one exakit command that is that fix, where one is.
COMMAND_FOR_KIND = {"missing": "exakit source list", "gated": "exakit source catalog", "unreachable_db": "exakit start"}


# The commands that act on a source that exists: a failure of theirs takes the
# fix `check` would name for its class, when it names none of its own.
SOURCE_COMMANDS = ("show", "check", "reauth", "refresh", "describe", "disconnect", "remove")

# The commands the day's log records (vslog). Not the catalog and resolve
# lookups, nor the terminal form's inputs and field: no database, nothing to
# debug, and a field's value may be a secret typed into the wrong one.
LOGGED = ("paste", "draft", "plan", "connect", "list", "issues") + SOURCE_COMMANDS


def set_keys(words):
    """The command's words with every --set value left out: the keys say what
    was given, and a value is logged by no one before it is validated - a
    password pasted into the wrong input would otherwise be in the file."""
    shown, rest = [], list(words)
    while rest:
        word = rest.pop(0)
        if word == "--set" and rest:
            item = rest.pop(0)
            shown += ["--set", item.split("=", 1)[0] + "=..." if "=" in item else "..."]
        elif word.startswith("--set="):
            item = word[len("--set="):]
            shown.append("--set=" + (item.split("=", 1)[0] + "=..." if "=" in item else "..."))
        else:
            shown.append(word)
    return shown


def run_log(args, argv):
    """The day's log for this run (a no-op for a command it does not record),
    its START line written: the command as given after the context options,
    --set keys without their values, and the database it talks to."""
    if args.command not in LOGGED:
        return vslog.NULL
    source = getattr(args, "name", None) or ("all" if getattr(args, "all", False) else None)
    log = vslog.RunLog(os.path.join(args.kit_home, "logs"), args.command, source)
    words = argv[argv.index(args.command):] if args.command in argv else [args.command]
    log.write("START", "%s (dsn %s, user %s%s)" % (" ".join(set_keys(words)), args.dsn or "-", args.user,
                                                    ", --json" if args.json else ""))
    return log


def kind_remedy(kind):
    """REMEDY_FOR_KIND's fix, as lifecycle.remedy_text words it - except in
    an engine that could not start, where lifecycle may not be there to ask."""
    if BROKEN is None:
        return lifecycle.remedy_text(kind, REMEDY_FOR_KIND)
    return REMEDY_FOR_KIND.get(kind, REMEDY_FOR_KIND["error"])


def failure(message, code, kind=None, remedy=None, command=None, source=None):
    """The one shape every --json failure has (see the module docstring)."""
    if not kind or kind == "error":
        kind = KIND_FOR_CODE.get(code, "error")
    if source and not remedy and kind != "error" and kind in lifecycle.REMEDY_FOR:
        remedy = lifecycle.remedy_text(kind).format(name=source, access="read access", store="bucket",
                                                    warehouse=lifecycle.catalog_warehouse(message))
        command = command or lifecycle.command_for(kind, source)
    return {"ok": False, "error": str(message), "kind": kind,
            "remedy": remedy or kind_remedy(kind),
            "command": command if command else COMMAND_FOR_KIND.get(kind)}


def pairs(items):
    values = {}
    for item in items:
        if "=" not in item:
            raise planner.PlanError("--set takes KEY=VALUE, not %r" % item)
        key, value = item.split("=", 1)
        values[key.strip()] = value
    return values


def read_secret(args):
    if args.secret_stdin_base64:
        raw = sys.stdin.buffer.read()
        try:
            # Only the base64 alphabet counts: a byte-order mark or a line
            # ending the pipe added around it is not part of the secret.
            data = base64.b64decode(re.sub(rb"[^A-Za-z0-9+/=]", b"", raw), validate=True).decode("utf-8")
        except (ValueError, binascii.Error):
            raise lifecycle.Failure("the credential on standard input is not valid base64 UTF-8", lifecycle.EXIT["input"])
        return data.rstrip("\r\n") or None
    if not args.secret_stdin:
        return None
    return decode_secret(sys.stdin.buffer.read()).rstrip("\r\n") or None


def decode_secret(raw):
    """A credential's bytes as text: UTF-16 (little or big endian) by its
    byte-order mark, else UTF-8 with or without one, and no NUL anywhere - the
    rules the Windows bridge (ConvertFrom-ExakitVsSecretBytes) and the shell's
    reader (_exakit_vs_secret_text) apply, so all three read one file alike. A
    NUL is refused because a shell variable drops it without a word: BOM-less
    UTF-16 would be another credential on each path. Anything else is refused,
    never guessed: a password decoded in the wrong code page is another
    password."""
    try:
        if raw[:2] in (codecs.BOM_UTF16_LE, codecs.BOM_UTF16_BE):
            text = raw.decode("utf-16")
        else:
            text = raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        text = None
    if text is None or "\0" in text:
        remedy = "save the credential as UTF-8 (UTF-16 needs its byte-order mark), then run the same command again"
        raise lifecycle.Failure("the credential is not UTF-8 or UTF-16 text", lifecycle.EXIT["input"], kind="input",
                                remedy=remedy, said="the credential is not UTF-8 or UTF-16 text: " + remedy)
    return text


def read_value(args):
    """A value on standard input (field, paste); --base64 is the Windows
    bridge's encoding, for the reason read_secret takes it."""
    if args.base64:
        try:
            raw = base64.b64decode(re.sub(rb"[^A-Za-z0-9+/=]", b"", sys.stdin.buffer.read()), validate=True).decode("utf-8")
        except (ValueError, binascii.Error):
            raise planner.PlanError("the value on standard input is not valid base64 UTF-8")
    else:
        raw = sys.stdin.read()
    return raw.rstrip("\r\n")


def write_secret_out(path, value):
    """The string's credential into the shell's file, owner-only: created so
    when it is not there yet, emptied first when it is."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as out:
        out.write(value.encode("utf-8"))


def paste_answer(args, emit, log):
    """A pasted connection string as the connector's inputs (paste.read): the
    values, notes and dropped parameter names. The string comes on standard
    input, never as an argument: it may hold a password. The credential it
    holds goes to --secret-out only, and is a secret of this run's log."""
    defs = planner.Definitions(args.defs)
    connector_id = defs.resolve(args.connector)
    credential = "given" if args.credential_given else ("use" if args.secret_out else None)
    text = read_value(args)
    answer = paste.read(defs.connector(connector_id), text, credential, args.only or None)
    value = answer.pop("secret_value")
    if value:
        log.secret(value)
        write_secret_out(args.secret_out, value)
    value = text = None
    for level, event in answer.pop("events"):
        emit(level, event)
    return dict(answer, connector=connector_id)


def adapter_version(defs, connector_id):
    """The adapter version a connector pins, for the menu; "" when its
    definition cannot be read (the catalog still lists it)."""
    try:
        return str(defs.connector(connector_id)["adapter"].get("version", ""))
    except (OSError, ValueError, KeyError, planner.PlanError):
        return ""


def form_answer(args):
    """The terminal form's two questions, answered without the database.

    inputs: what to ask for a connector, in order - the source name first, then
    each input as connector.json declares it (secrets flagged, never valued).
    field: is one answer right? The value comes on standard input, not as an
    argument, for the reason a secret does: a value pasted into the wrong field
    is still not shown to every local user. The answer is the stored value, or
    a PlanError in the words a scripted connect would get for the same value."""
    defs = planner.Definitions(args.defs)
    connector_id = defs.resolve(args.connector)
    connector = defs.connector(connector_id)
    entry = defs.entry(connector_id)
    if args.command == "inputs":
        fields = [{"name": "name", "label": "Name (alias) for this connection", "kind": "source-name", "required": True,
                   "default": "", "choices": [], "secret": False}]
        for spec in connector["inputs"]:
            fields.append({"name": spec["name"], "label": spec.get("label", spec["name"]), "kind": spec["kind"],
                           "required": bool(spec.get("required")), "default": str(spec.get("default", "")),
                           "choices": list(spec.get("choices", [])),
                           "secret": spec["kind"] in ("secret", "secret-file"),
                           # Said under the panel when it is asked; the question's own words; drafted when empty.
                           "hint": list(spec.get("hint", [])), "prompt": spec.get("prompt", ""),
                           "draft": connector.get("store", "bucket") if spec.get("draft") else ""})
        return {"connector": connector_id, "name": entry["name"], "status": entry["status"],
                "gate": entry.get("gate") or "", "inputs": fields}
    raw = read_value(args)
    if args.input == "name":
        if not sources.NAME.match(raw):
            raise planner.PlanError("the source name must be lower case letters, digits and _ (start with a letter, "
                                    "at most 40), e.g. sales")
        store = sources.Store(args.kit_home)
        if store.exists(raw):
            current = store.config(raw)
            # A disconnected source of the same connector is reconnected by
            # name - the one case where an existing name is the right answer.
            if store.status(raw).get("status") != "disconnected" or current["connector"] != connector_id:
                taken = "a source named %s already exists (%s)" % (raw, current["connector"])
                fix = "choose another name or remove it first: exakit source remove %s" % raw
                if current["connector"] == connector_id:
                    # The form makes new sources; a connected one moves with
                    # the line-by-line connect, its inputs as recorded.
                    fix += ("; to point it at a new address instead: exakit connect %s --name %s --set "
                            "<input>=<new value>" % (connector_id, raw))
                raise planner.PlanError(taken, code=lifecycle.EXIT["conflict"], remedy=fix,
                                        said="%s; %s" % (taken, fix))
        return {"value": raw}
    spec = next((s for s in connector["inputs"] if s["name"] == args.input), None)
    if spec is None or spec["kind"] in ("secret", "secret-file"):
        raise planner.PlanError("%s is not an input of %s that the form checks" % (args.input, connector_id))
    if spec["kind"] == "edml" and spec.get("draft"):
        value, problem = planner.draft_value(raw)
        if problem:
            raise planner.PlanError(problem)
        if value is not None:
            return {"value": value}
    if raw == "":
        if "default" in spec:
            raw = str(spec["default"])
        elif spec.get("required"):
            raise planner.PlanError("%s is required (%s)" % (spec["name"], spec.get("label", spec["name"])))
        else:
            return {"value": ""}
    value, problem = planner.check_value(spec, raw)
    if problem:
        raise planner.PlanError(problem)
    return {"value": value}


def draft_answer(args, secret):
    """The terminal form's draft: the mapping written to <kit home>/sources/<name>/edml
    from the bucket or container, with the credential on standard input. Only for a
    name that is not a source yet - the form makes new sources."""
    defs = planner.Definitions(args.defs)
    connector_id = defs.resolve(args.connector)
    connector = defs.connector(connector_id)
    if not lifecycle.Engine.drafts(connector):
        raise planner.PlanError("%s takes no mapping to draft" % connector_id)
    if not sources.NAME.match(args.name):
        raise planner.PlanError("the source name must be lower case letters, digits and _ (start with a letter, "
                                "at most 40), e.g. sales")
    store = sources.Store(args.kit_home)
    if store.exists(args.name):
        raise planner.PlanError("a source named %s already exists; its mapping is staged already" % args.name,
                                code=lifecycle.EXIT["conflict"])
    values = planner.validate_inputs(connector, pairs(args.set))
    if planner.draft_prefix(connector, values) is None:
        raise planner.PlanError("a mapping path is given; there is nothing to draft")
    if not secret:
        raise planner.PlanError("the draft reads the %s with the credential: give it on standard input"
                                % connector.get("store", "bucket"))
    result = lifecycle.draft_into(connector, values, secret, store.path(args.name, "edml"))
    return dict(result, connector=connector_id, summary=lifecycle.edml_draft.summary_lines(result))


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if BROKEN:
        sys.stderr.write(BROKEN)
        line = "the engine could not start: %s" % " ".join(BROKEN.strip().splitlines()[-1].split())
        if "--json" in argv:
            print(json.dumps(failure(line, 1, "internal"), indent=2))
        else:
            print("FAIL %s (details: exakit logs)" % line)
        return 1
    try:
        args = parse(argv)
    except SystemExit as stop:
        # argparse said why on stderr; a caller that asked for JSON still gets
        # its one object.
        if stop.code and "--json" in argv:
            print(json.dumps(failure("the engine does not take these arguments (the reason is in the log)", 2),
                             indent=2))
            return 2
        raise
    # Where "this computer" is depends on the deployment's engine (plan.py).
    planner.use_engine(args.kit_home)
    out = sys.stderr if args.json else sys.stdout
    log = run_log(args, argv)
    started = time.time()

    def emit(level, text):
        out.write("%s %s\n" % (level, text))
        out.flush()
        log.write(level, text)

    def secret_of(args):
        secret = read_secret(args)
        log.secret(secret)
        return secret

    result, code = None, 0
    engine = None
    try:
        if not args.command:
            raise planner.PlanError("name a command (see the module docstring)")
        if args.command in ("inputs", "field"):
            result = form_answer(args)
        elif args.command == "paste":
            result = paste_answer(args, emit, log)
        elif args.command == "draft":
            result = draft_answer(args, secret_of(args))
            for note in result["notes"]:
                emit("WARN", note)
        elif args.command in ("catalog", "resolve"):
            defs = planner.Definitions(args.defs)
            if args.command == "resolve":
                # The gate comes before any question: asking for a project and
                # a dataset only to then say "not available" wastes the answers.
                connector = defs.resolve(args.query)
                entry = defs.entry(connector)
                if entry["status"] == "gated":
                    raise planner.PlanError("%s is not available yet: %s" % (entry["name"], entry["gate"]),
                                            code=lifecycle.EXIT["gated"])
                result = {"connector": connector}
            else:
                if args.public_ip:
                    publicip.start()        # asked while the catalog is read
                q = args.query.lower()
                result = {"connectors": [dict(e, profile=e["profile"], version=adapter_version(defs, e["id"]))
                                         for e in defs.entries() if not q or q in json.dumps(e).lower()]}
                if args.public_ip:
                    result["public_ip"] = publicip.get()
                    if result["public_ip"]:
                        emit("INFO", publicip.advice(result["public_ip"]))
        else:
            engine = lifecycle.Engine(args, emit, log)
            if args.command in ("plan", "connect"):
                connector = engine.defs.resolve(args.connector)
                result = engine.connect(connector, args.name, pairs(args.set), secret_of(args),
                                        dry_run=args.dry_run, plan_only=args.command == "plan",
                                        secret_given=args.secret_given)
                if args.command == "connect" and result.get("action") == "unchanged" and \
                        result.get("status") != "ready":
                    # Nothing to change, but not working either: a failure,
                    # with the source's own fix.
                    code = 1
            elif args.command == "languages":
                result = {"missing": engine.missing_languages(args.need)}
            elif args.command == "list":
                result = {"sources": engine.listing()}
            elif args.command == "issues":
                result = {"issues": engine.issues(args.status or None)}
            elif args.command == "show":
                result = engine.show(args.name)
            elif args.command == "check":
                if args.all:
                    results = [engine.check(name) for name in engine.store.names()]
                    result = {"checks": results}
                    code = 1 if any(r.get("status") not in ("ready", "disconnected") for r in results) else 0
                elif args.name:
                    result = engine.check(args.name)
                    code = 0 if result.get("status") in ("ready", "disconnected") else 1
                else:
                    raise planner.PlanError("check takes a source name or --all")
            elif args.command == "reauth":
                result = engine.reauth(args.name, secret_of(args))
                code = 0 if result.get("status") == "ready" else 1
            elif args.command == "refresh":
                result = engine.refresh(args.name)
            elif args.command == "describe":
                result = engine.describe(args.name, args.table, args.ddl, args.into)
            elif args.command == "disconnect":
                result = engine.disconnect(args.name, args.dry_run)
            elif args.command == "remove":
                result = engine.remove(args.name, args.dry_run)
    except planner.PlanError as error:
        emit("FAIL", error.said)
        if error.choices:
            emit("INFO", "choices: %s" % ", ".join(error.choices))
        result, code = dict(failure(error, error.code, None, error.remedy, error.command),
                            choices=error.choices), error.code
    except lifecycle.Failure as error:
        emit("FAIL", error.said)
        source = args.name if args.command in SOURCE_COMMANDS else None
        result, code = failure(error, error.code, error.kind, error.remedy, error.command, source), error.code
    except sources.SourceError as error:
        emit("FAIL", str(error))
        result, code = failure(error, error.code), error.code
    except Exception as error:  # noqa: BLE001 - the last line: never a traceback on stdout
        # The traceback goes to stderr, which the shells keep in the log; the
        # answer is one line, and the same shape as every other failure.
        # Without the exceptions it was raised while handling (chain=False),
        # and redacted: a driver's exception carries its statement, secret
        # and all, and this traceback reaches files the run log does not.
        trace = log.scrub(traceback.format_exc(chain=False))
        sys.stderr.write(trace)
        log.write("TRACE", trace.rstrip())
        line = log.scrub(" ".join(("%s: %s" % (type(error).__name__, error)).split()))
        emit("FAIL", "the engine failed unexpectedly: %s (details: exakit logs)" % line)
        result, code = failure("the engine failed unexpectedly: %s" % line, 1, "internal"), 1
    finally:
        if engine is not None:
            try:
                engine.close()
            except Exception:  # noqa: BLE001 - the answer is already decided
                sys.stderr.write(log.scrub(traceback.format_exc(chain=False)))
        kind = result.get("kind") if code and isinstance(result, dict) else None
        log.write("END", "exit %d%s (%.1f s)" % (code, ", kind %s" % kind if kind else "", time.time() - started))
        log.close()
    if args.json:
        payload = dict(result or {})
        payload.setdefault("ok", code == 0)
        if args.command in ("plan", "connect", "paste"):
            # Always present for plan and connect: the address a source on the
            # internet must allow, null when it is not known or not needed -
            # and for paste, the step connect --url takes before them.
            try:
                payload.setdefault("public_ip", engine.public_ip() if engine is not None else None)
            except Exception:  # noqa: BLE001 - an address is never worth the answer
                payload.setdefault("public_ip", None)
        print(json.dumps(payload, indent=2, default=str))
    elif result is not None and code == 0:
        print("RESULT " + json.dumps(result, default=str))
    return code


if __name__ == "__main__":
    sys.exit(main())
