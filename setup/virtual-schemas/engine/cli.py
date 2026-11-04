"""The virtual schema coordinator, called by setup/lib/virtual-schemas.{sh,ps1}.

    cli.py [context] catalog    [--query Q]
    cli.py [context] resolve    QUERY
    cli.py [context] inputs     CONNECTOR
    cli.py [context] field      CONNECTOR INPUT [--base64]   (the value on standard input)
    cli.py [context] plan       CONNECTOR --name N [--set KEY=VALUE ...]
    cli.py [context] connect    CONNECTOR --name N [--set KEY=VALUE ...] [--secret-stdin]
    cli.py [context] list | issues [--status S] | show N | check N|--all
    cli.py [context] reauth     N --secret-stdin
    cli.py [context] refresh    N
    cli.py [context] describe   N [TABLE] [--ddl] [--into SCHEMA]
    cli.py [context] disconnect N [--dry-run]
    cli.py [context] remove     N [--dry-run]

    context: --defs DIR --kit-home DIR --deployment-dir DIR --dsn HOST:PORT
             --user USER --password-file FILE [--json]

A secret is read from standard input only (--secret-stdin), never from an
argument: arguments are visible to every local user through the process table.
It is read as UTF-8 bytes, a byte-order mark dropped. --secret-stdin-base64
takes it base64-encoded instead: the Windows bridge sends it so, because
Windows PowerShell 5.1 re-encodes what it pipes to a native program (measured
on CI: a byte-order mark added, every non-ASCII character turned into '?'),
and plain ASCII survives every code page.

Without --json, one "OK|INFO|WARN|FAIL <text>" line per event on stdout for
the shell to render. With --json, events go to stderr and stdout carries one
JSON object. Exit codes: 0 done, 1 failed, 2 bad input, 3 conflict, 4 no such
source, 5 gated, 20 Java in the database cannot resolve host names,
21 Java is not installed in the database, 22 the local database is unreachable.
"""

import argparse
import base64
import binascii
import json
import locale
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import lifecycle  # noqa: E402
import plan as planner  # noqa: E402
import sources  # noqa: E402


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
    sub.add_parser("resolve").add_argument("query")
    sub.add_parser("inputs").add_argument("connector")
    cmd = sub.add_parser("field")
    cmd.add_argument("connector")
    cmd.add_argument("input")
    cmd.add_argument("--base64", action="store_true")
    for name in ("plan", "connect"):
        cmd = sub.add_parser(name)
        cmd.add_argument("connector")
        cmd.add_argument("--name", required=True)
        cmd.add_argument("--set", action="append", default=[], metavar="KEY=VALUE")
        cmd.add_argument("--secret-stdin", action="store_true")
        cmd.add_argument("--secret-stdin-base64", action="store_true")
        cmd.add_argument("--dry-run", action="store_true")
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
    raw = sys.stdin.buffer.read()
    try:
        data = raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        data = raw.decode(locale.getpreferredencoding(False), errors="replace")
    return data.rstrip("\r\n") or None


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
        fields = [{"name": "name", "label": "Name for this connection", "kind": "source-name", "required": True,
                   "default": "", "choices": [], "secret": False}]
        for spec in connector["inputs"]:
            fields.append({"name": spec["name"], "label": spec.get("label", spec["name"]), "kind": spec["kind"],
                           "required": bool(spec.get("required")), "default": str(spec.get("default", "")),
                           "choices": list(spec.get("choices", [])),
                           "secret": spec["kind"] in ("secret", "secret-file")})
        return {"connector": connector_id, "name": entry["name"], "status": entry["status"],
                "gate": entry.get("gate") or "", "inputs": fields}
    if args.base64:
        # The Windows bridge's encoding, for the reason read_secret takes it.
        try:
            raw = base64.b64decode(re.sub(rb"[^A-Za-z0-9+/=]", b"", sys.stdin.buffer.read()), validate=True).decode("utf-8")
        except (ValueError, binascii.Error):
            raise planner.PlanError("the value on standard input is not valid base64 UTF-8")
    else:
        raw = sys.stdin.read()
    raw = raw.rstrip("\r\n")
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
                raise planner.PlanError("a source named %s already exists (%s); choose another name or remove it "
                                        "first: exakit source remove %s" % (raw, current["connector"], raw),
                                        code=lifecycle.EXIT["conflict"])
        return {"value": raw}
    spec = next((s for s in connector["inputs"] if s["name"] == args.input), None)
    if spec is None or spec["kind"] in ("secret", "secret-file"):
        raise planner.PlanError("%s is not an input of %s that the form checks" % (args.input, connector_id))
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


def main(argv=None):
    args = parse(argv)
    out = sys.stderr if args.json else sys.stdout

    def emit(level, text):
        out.write("%s %s\n" % (level, text))
        out.flush()

    if not args.command:
        emit("FAIL", "name a command (see the module docstring)")
        return lifecycle.EXIT["input"]
    result, code = None, 0
    engine = None
    try:
        if args.command in ("inputs", "field"):
            result = form_answer(args)
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
                q = args.query.lower()
                result = {"connectors": [dict(e, profile=e["profile"]) for e in defs.entries()
                                         if not q or q in json.dumps(e).lower()]}
        else:
            engine = lifecycle.Engine(args, emit)
            if args.command in ("plan", "connect"):
                connector = engine.defs.resolve(args.connector)
                result = engine.connect(connector, args.name, pairs(args.set), read_secret(args),
                                        dry_run=args.dry_run, plan_only=args.command == "plan")
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
                result = engine.reauth(args.name, read_secret(args))
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
        emit("FAIL", str(error))
        if error.choices:
            emit("INFO", "choices: %s" % ", ".join(error.choices))
        result, code = {"ok": False, "error": str(error), "choices": error.choices}, error.code
    except lifecycle.Failure as error:
        emit("FAIL", str(error))
        result, code = {"ok": False, "error": str(error), "kind": error.kind}, error.code
    except sources.SourceError as error:
        emit("FAIL", str(error))
        result, code = {"ok": False, "error": str(error)}, error.code
    finally:
        if engine is not None:
            engine.close()
    if args.json:
        payload = dict(result or {})
        payload.setdefault("ok", code == 0)
        print(json.dumps(payload, indent=2, default=str))
    elif result is not None and code == 0:
        print("RESULT " + json.dumps(result, default=str))
    return code


if __name__ == "__main__":
    sys.exit(main())
