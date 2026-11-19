"""Build the JSON Tables module for this database, and optionally register it.

    generate.py [--home DIR] [--exapump BIN] [--profile NAME] OUT
    generate.py --register [--home DIR] [--exapump BIN] [--profile NAME]

The first form writes the module's artifact (json_tables.sql.tmpl filled in) to OUT and prints one line, the note
the framework records with the version ("exasol-json-tables v0.4.1 + 2 wrappers"). It is the [kit] generator in
module.toml, which the framework's verify pass runs, and what the add-on's install and update run.

The second form is what the kit's exasol-json-tables launcher runs after a successful `wrap install`, `wrap deploy`
or `ingest-and-wrap`: build the artifact and hand it to manage.py register-module. A new wrapper changes the
artifact, so it is deployed as the next PREPROC_RT.JSON_TABLES_V<N>, the rule repointed and the old version
retired; an unchanged set of wrappers changes nothing.

The artifact is upstream's own code with this database's configuration: generate_preprocessor_library_body() (the
Lua library every upstream wrapper preprocessor imports) and build_preprocessor_config() over every installed
wrapper package, read with load_installed_wrapper_manifests() - the same union upstream's COMPILE_SQL serves, so
wrappers installed by any kit version, 0.2.5 included, are covered. No wrappers: a module that passes every statement
through.

Upstream (exasol_json_tables) lives in the JSON Tables environment, not in the kit's Python: run by any other
interpreter, this script runs itself again with the environment's Python, read from the kit's manifest. The database
is read through the kit's exapump profile, every session behind the preprocessor bypass.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
TEMPLATE = HERE / "json_tables.sql.tmpl"
MANAGE = HERE.parent.parent / "manage.py"
ADDON = "json-tables"
BYPASS = "ALTER SESSION SET sql_preprocessor_script = '';"
QUERY_TIMEOUT = 180
EXIT_FAILED = 1


class GenerateError(Exception):
    pass


def _manifest(home: Path) -> dict:
    try:
        return json.loads((home / "manifest.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def _component(home: Path, key: str) -> dict:
    node = _manifest(home).get("components", {}).get(key)
    return node if isinstance(node, dict) else {}


def _defaults(args: argparse.Namespace) -> None:
    """Fill what the caller left out from the kit's own records, as the kit's shell does."""
    home = Path(args.home) if args.home else Path(os.environ.get("EXAKIT_HOME") or Path.home() / ".exasol-starter-kit")
    args.home = str(home)
    if not args.exapump:
        recorded = _component(home, "exapump").get("path")
        args.exapump = recorded if isinstance(recorded, str) and recorded else "exapump"
    if not args.profile:
        args.profile = os.environ.get("EXAKIT_EXAPUMP_PROFILE") or "starter-kit"
    # The launcher runs in the user's own shell, which has not exported the kit's exapump profile store.
    config = home / "exapump" / "config.toml"
    if not os.environ.get("EXAPUMP_CONFIG") and config.is_file():
        os.environ["EXAPUMP_CONFIG"] = str(config)


# --- the database, read through exapump --------------------------------------------------------------------------

def _select_columns(sql: str) -> list[str]:
    """The result column names of upstream's own catalog reads: a plain SELECT list, each item a column or an
    aliased column. exapump's JSON leaves a NULL value's key out of its row, so a row becomes a tuple by name."""
    match = re.search(r"(?is)\bSELECT\b(.*?)\bFROM\b", sql)
    if not match:
        raise GenerateError("cannot read the result columns of: %s" % " ".join(sql.split())[:80])
    columns = []
    for item in match.group(1).split(","):
        words = item.strip().split()
        if not words:
            raise GenerateError("cannot read the result columns of: %s" % " ".join(sql.split())[:80])
        columns.append(words[-1].split(".")[-1].strip('"').upper())
    return columns


class _Result:
    def __init__(self, rows: list[tuple]):
        self.rows = rows

    def fetchall(self) -> list[tuple]:
        return list(self.rows)

    def fetchone(self):
        return self.rows[0] if self.rows else None


class ExapumpConnection:
    """The slice of a pyexasol connection upstream's catalog readers use - execute(sql).fetchall() - over the
    kit's exapump profile. One exapump run is one session, and every one starts with the preprocessor bypass, so
    the reads never pass through any module, this one included."""

    def __init__(self, binary: str, profile: str):
        self.binary = binary
        self.profile = profile

    def execute(self, sql: str) -> _Result:
        columns = _select_columns(sql)
        text = "%s\n%s;\n" % (BYPASS, sql.strip().rstrip(";"))
        try:
            done = subprocess.run([self.binary, "sql", "-p", self.profile, "-f", "json"], input=text.encode("utf-8"),
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=QUERY_TIMEOUT)
        except subprocess.TimeoutExpired:
            raise GenerateError("exapump did not answer within %ss" % QUERY_TIMEOUT)
        except OSError as error:
            raise GenerateError("could not run exapump (%s): %s" % (self.binary, error))
        if done.returncode != 0:
            err = done.stderr.decode("utf-8", "replace").strip().splitlines()
            reason = next((line.strip() for line in reversed(err) if "rror" in line), "") or \
                "exapump exited with %s" % done.returncode
            raise GenerateError(re.sub(r"\s*\(Session: \d+\)", "", reason))
        out = done.stdout.decode("utf-8", "replace").strip()
        try:
            rows = json.loads(out) if out else []
        except ValueError:
            raise GenerateError("exapump printed something that is not JSON: %r" % out[:80])
        if not isinstance(rows, list):
            raise GenerateError("exapump printed something that is not a result: %r" % out[:80])
        result = []
        for row in rows:
            unknown = [key for key in row if key.upper() not in columns]
            if unknown:
                raise GenerateError("exapump returned columns %s the query did not ask for" % ", ".join(unknown))
            values = {key.upper(): value for key, value in row.items()}
            result.append(tuple(values.get(column) for column in columns))
        return _Result(result)


# --- the artifact --------------------------------------------------------------------------------------------------

# Wrapper schema names are values read from the database (every __JVS_ROOTS table any schema holds), so they
# reach the Lua as data only: each character a quoted Lua string cannot hold as it is - a quote, a backslash, a
# line break, NUL, any other control character - is written as an escape, and nothing from the database is ever
# written into a comment.
_LUA_ESCAPES = {"\\": "\\\\", "'": "\\'", '"': '\\"', "\n": "\\n", "\r": "\\r", "\0": "\\0"}


def _lua_string(text: str) -> str:
    return "'" + "".join(_LUA_ESCAPES.get(char) or (char if ord(char) >= 32 and ord(char) != 127
                                                     else "\\%03d" % ord(char)) for char in text) + "'"


def _plain(value) -> bool:
    """True when no name in a wrapper manifest holds a control character. Upstream quotes the manifest's names into
    the rewriter's CONFIG escaping only quotes and backslashes, so a line break there would end up raw in the Lua
    of a module every session loads; a real wrapper never has one."""
    if isinstance(value, dict):
        return all(_plain(key) and _plain(item) for key, item in value.items())
    if isinstance(value, (list, tuple)):
        return all(_plain(item) for item in value)
    return not isinstance(value, str) or not any(ord(char) < 32 or ord(char) == 127 for char in value)


def build_artifact(con) -> tuple[str, str]:
    """(artifact text, note) for every wrapper package installed in the database ``con`` reads."""
    import importlib.metadata

    from exasol_json_tables import generate_wrapper_preprocessor_sql as wrapper_sql
    from exasol_json_tables.generate_preprocessor_sql import build_preprocessor_config, render_lua_string_table
    from exasol_json_tables.preprocessor_library_builder import generate_preprocessor_library_body
    from exasol_json_tables.wrapper_schema_support import load_installed_wrapper_manifests

    try:
        version = "v" + importlib.metadata.version("exasol-json-tables")
    except importlib.metadata.PackageNotFoundError:
        version = "unknown version"
    manifests = []
    for manifest in load_installed_wrapper_manifests(con):
        if _plain(manifest):
            manifests.append(manifest)
        else:
            print("JSON Tables: the wrapper package %r was left out of the SQL preprocessor module: its names hold a"
                  " line break or another control character" % manifest.get("helperSchema"), file=sys.stderr)
    if manifests:
        # Upstream finds a wrapper by its helper schema, which stays when the wrapper schema is dropped by hand: only
        # a wrapper whose schema is still there is configured, so a later schema of that name is plain SQL again.
        present = set(str(row[0]).upper() for row in con.execute("SELECT SCHEMA_NAME AS N FROM EXA_SCHEMAS").fetchall())
        manifests = [manifest for manifest in manifests if str(manifest["publicSchema"]).upper() in present]
    public = [str(manifest["publicSchema"]).upper() for manifest in manifests]
    helper = [str(manifest["helperSchema"]).upper() for manifest in manifests]
    if manifests:
        # The same inputs upstream's COMPILE_SQL is generated from (generate_wrapper_compile_sql_text, v0.4.1):
        # every package's group, visible-column and TO_JSON configuration, the default helper names, and path
        # rewriting on. _build_wrapper_rewrite_inputs is upstream's own derivation of them, shared by its
        # preprocessor and its compile script; the kit pins the release it calls.
        inputs = wrapper_sql._build_wrapper_rewrite_inputs(
            wrapper_schemas=public, helper_schemas=helper, manifests=manifests, function_names=None,
            variant_typeof_function_names=None, variant_varchar_function_names=None,
            variant_decimal_function_names=None, variant_boolean_function_names=None,
            to_json_function_names=None, blocked_helper_names=None)
        config = build_preprocessor_config(
            function_names=list(inputs["helper_function_kinds"].keys()),
            blocked_function_names=list(inputs["blocked_helper_names"]),
            blocked_function_message="This helper is not available on the wrapper surface yet.",
            allowed_schemas=list(inputs["wrapper_schemas"]),
            helper_schema_map=dict(inputs["helper_schema_map"]),
            wrapper_group_config=inputs["group_config"],
            wrapper_visible_column_config=inputs["visible_column_config"],
            wrapper_to_json_config=inputs["to_json_config"],
            regular_to_json_row_object_function=str(inputs["regular_to_json_row_object_function"]),
            rewrite_path_identifiers=True,
            helper_function_kinds=dict(inputs["helper_function_kinds"]))
        library = (generate_preprocessor_library_body(compact=True).rstrip("\n")
                   + "\n\nlocal CONFIG = " + render_lua_string_table(config, 0)
                   + "\n\nfunction rewrite_statement(sqltext)\n    return rewrite(sqltext, CONFIG)\nend")
    else:
        library = "function rewrite_statement(sqltext)\n    return sqltext\nend"
    schemas = "{" + ", ".join(_lua_string(name) for name in public) + "}"
    text = TEMPLATE.read_text(encoding="utf-8")
    for key, value in (("__SCHEMAS__", schemas), ("__LIBRARY__", library)):
        text = text.replace(key, value)
    if any(line.strip() == "/" for line in library.splitlines()):
        raise GenerateError("the JSON Tables library holds a line the artifact's block markers would cut")
    count = len(manifests)
    note = "exasol-json-tables %s + %d wrapper%s" % (version, count, "" if count == 1 else "s")
    return text, note


# --- the commands --------------------------------------------------------------------------------------------------

def _rerun_in_environment(argv: list[str], home: Path) -> int | None:
    """Run this script with the JSON Tables environment's Python when this one cannot import upstream."""
    try:
        import exasol_json_tables  # noqa: F401
        return None
    except ImportError:
        pass
    receipt = _component(home, "json_tables")
    python = receipt.get("python") if receipt.get("ownership") == "kit" else None
    if not isinstance(python, str) or not Path(python).is_file() or Path(python) == Path(sys.executable):
        print("JSON Tables is not installed by the kit here, so its module cannot be built", file=sys.stderr)
        return EXIT_FAILED
    try:
        return subprocess.run([python, str(Path(__file__).resolve()), *argv], timeout=900).returncode
    except (OSError, subprocess.TimeoutExpired) as error:
        print("the JSON Tables environment did not run: %s" % error, file=sys.stderr)
        return EXIT_FAILED


def _register(args: argparse.Namespace) -> int:
    """Build and register; one line on stderr says what happened (stdout stays the CLI's)."""
    # Said first: the build and the registration take a dozen-plus database sessions, after the CLI has printed its
    # result, and a prompt that does not come back with nothing said reads as a hang.
    print("JSON Tables: registering the new wrapper ...", file=sys.stderr, flush=True)
    with tempfile.TemporaryDirectory(prefix="exakit-json-tables-module-") as temp:
        out = Path(temp) / "json_tables.sql"
        try:
            text, note = build_artifact(ExapumpConnection(args.exapump, args.profile))
        except (GenerateError, ValueError, SystemExit) as error:
            print("JSON Tables: the SQL preprocessor module was not rebuilt: %s" % error, file=sys.stderr)
            return EXIT_FAILED
        out.write_text(text, encoding="utf-8")
        home = Path(args.home)
        command = [sys.executable, str(MANAGE), "register-module", "--exapump", args.exapump, "--profile",
                   args.profile, "--manifest", str(home / "manifest.json"),
                   "--log", str(home / "logs" / "marketplace.log"), ADDON, "--artifact", str(out), "--note", note]
        try:
            done = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=900)
        except (OSError, subprocess.TimeoutExpired) as error:
            print("JSON Tables: the SQL preprocessor module step did not run: %s" % error, file=sys.stderr)
            return EXIT_FAILED
    lines = [line.split(" ", 1) for line in done.stdout.decode("utf-8", "replace").splitlines() if " " in line]
    lines = [text for level, text in lines if level in ("OK", "INFO", "WARN", "FAIL")]
    if done.returncode == 0:
        module = (_component(home, "preprocessor").get("modules") or {}).get(ADDON) or {}
        print("JSON Tables: JSON queries work on every connection, no session setup (%s%s)"
              % (str(module.get("script")) + ", " if module.get("script") else "", note), file=sys.stderr)
    elif lines:
        print("JSON Tables: %s" % lines[-1], file=sys.stderr)
    return done.returncode


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--home", default="")
    parser.add_argument("--exapump", default="")
    parser.add_argument("--profile", default="")
    parser.add_argument("--register", action="store_true")
    parser.add_argument("out", nargs="?")
    args = parser.parse_args(argv)
    if not args.register and not args.out:
        parser.error("OUT is required without --register")
    _defaults(args)
    code = _rerun_in_environment(argv, Path(args.home))
    if code is not None:
        return code
    if args.register:
        return _register(args)
    try:
        text, note = build_artifact(ExapumpConnection(args.exapump, args.profile))
    except (GenerateError, ValueError, SystemExit) as error:
        print("the JSON Tables module was not built: %s" % error, file=sys.stderr)
        return EXIT_FAILED
    Path(args.out).write_text(text, encoding="utf-8")
    print(note)
    return 0


if __name__ == "__main__":
    sys.exit(main())
