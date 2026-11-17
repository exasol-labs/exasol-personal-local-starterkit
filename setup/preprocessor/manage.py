"""Install, activate and verify the SQL preprocessor framework in local Exasol.

    manage.py ensure  --exapump BIN --profile NAME --manifest FILE --admin-user USER
                      --pin-version V --pin-ref REF --pin-sha256 HEX
                      [--package FILE] [--log FILE]
    manage.py inspect --exapump BIN --profile NAME --manifest FILE
    manage.py derive  --package FILE [--out FILE]

Exasol has one global preprocessor slot. The framework's PREPROC_RT.MASTER
dispatcher takes it, and every later SQL transformation registers with MASTER
as a module instead of fighting for the slot. This is the core task the
installer's database features (Step 3, "Setup Utilities") run, and it runs on every
installer pass: the manifest record only skips the install, never the check.

All SQL goes through exapump and the kit's administrator profile. The profile
holds the password, so no credential ever reaches an argument list or the log.

ensure decides from what the database holds:

  slot holds another script             conflict: change nothing (exit 3)
  framework present, not the kit's,     conflict: change nothing (exit 3)
    and not active
  nothing present                       fresh install from the pinned package
  the kit's own interrupted install     drop exactly its objects, then install
  installed by the kit                  check objects; test in one session;
                                        activate; verify in fresh connections
  already active                        verify; deactivate again on failure

A fresh install never replays over an existing framework schema: release.sql
is clean-install only, and it would re-seed rules and fail on its role.

The kit installs the CORE-ONLY package: the pinned release.sql, verified, with
its PYTHON3 script blocks left out (today one, PREPROC.MODULE_RESOLVER_V1).
Local deployments ship no script language container, so a Python script
cannot even be created there - and that one only fetches modules from a
remote registry for PREPROC INSTALL MODULE ... FROM <url>. The dispatcher,
rules, refresh and command sugar are Lua. The kit registers its own add-on
modules from setup/preprocessor/modules/ instead. The derived text is checked
against its own pin (--pin-core-sha256), so what runs is as fixed as what was
downloaded.

Output: one line per event on stdout, "OK|INFO|WARN|FAIL <text>", which the
shell renders with the kit's own marks. exapump's own output goes to --log.

Exit codes: 0 ready (active and verified); 1 failed (the slot is left as it
was before this run); 3 conflict, nothing changed; 10 a fresh install is needed
and --package is missing; 11 the package does not match the pinned SHA-256.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "core"))

import state  # noqa: E402  (path set above)

COMPONENT = "preprocessor"
EXIT_OK = 0
EXIT_FAILED = 1
EXIT_CONFLICT = 3
EXIT_NEED_PACKAGE = 10
EXIT_BAD_PACKAGE = 11

PROBE_SCRIPT = "PREPROC_RT.EXAKIT_PROBE_V1"
PROBE_FUNCTION = "exakit_probe"
PROBE_IN = "SELECT 'EXAKIT_PP_PROBE_IN' AS R"
PROBE_OUT = "EXAKIT_PP_PROBE_OUT"
ORDINARY = "SELECT 'EXAKIT_PP_ORDINARY' AS R"
# Every setup session starts with this, so the statements that install, probe
# or repair the framework never pass through any preprocessor - including one
# this run is in the middle of activating.
BYPASS = "ALTER SESSION SET sql_preprocessor_script = '';"
INSTALL_TIMEOUT = 900
QUERY_TIMEOUT = 180


class SqlError(Exception):
    pass


class Outcome(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def emit(level, text):
    print("%s %s" % (level, text))
    sys.stdout.flush()


def load_package_manifest():
    with open(os.path.join(HERE, "manifest.json"), encoding="utf-8") as handle:
        return json.load(handle)


def normalize_slot(value):
    """'"PREPROC_RT"."MASTER"' and 'preproc_rt.master' are the same script."""
    if value is None:
        return ""
    return str(value).replace('"', "").strip().upper()


def sql_literal(value):
    return "'" + str(value).replace("'", "''") + "'"


PYTHON_SCRIPT = re.compile(r"(?i)^\s*CREATE\s+(OR\s+REPLACE\s+)?PYTHON3\b[^(]*?SCRIPT\s+([\w.\"]+)")


def core_only(text):
    """release.sql without its PYTHON3 script blocks: (text, [removed names]).

    A script block runs from its "--/" opener (and the comment header under
    it) to the lone "/" that ends the body. Everything else - every Lua
    script, table, grant and seed - is kept byte for byte.
    """
    lines = text.splitlines(True)
    kept, removed, index = [], [], 0
    while index < len(lines):
        if lines[index].strip() == "--/":
            ahead = index + 1
            while ahead < len(lines) and (not lines[ahead].strip() or lines[ahead].lstrip().startswith("--")):
                ahead += 1
            match = PYTHON_SCRIPT.match(lines[ahead]) if ahead < len(lines) else None
            if match:
                end = ahead + 1
                while end < len(lines) and lines[end].strip() != "/":
                    end += 1
                removed.append(match.group(2).replace('"', "").upper())
                index = end + 1
                continue
        kept.append(lines[index])
        index += 1
    return "".join(kept), removed


def sha256_text(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 16), b""):
            digest.update(block)
    return digest.hexdigest()


class Exapump(object):
    """One exapump invocation is one connection; that is the session boundary."""

    def __init__(self, binary, profile, log_path):
        self.binary = binary
        self.profile = profile
        self.log_path = log_path

    def _log(self, text):
        if not self.log_path or not text:
            return
        try:
            with open(self.log_path, "a", encoding="utf-8") as handle:
                for line in text.splitlines():
                    handle.write("PREPROC %s\n" % line)
        except OSError:
            pass

    def run(self, sql, timeout=QUERY_TIMEOUT):
        """Run SQL text on one connection; return the result arrays of its SELECTs."""
        command = [self.binary, "sql", "-p", self.profile, "-f", "json"]
        try:
            done = subprocess.run(command, input=sql.encode("utf-8"), stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise SqlError("exapump did not answer within %ss" % timeout)
        except OSError as error:
            raise SqlError("could not run exapump (%s): %s" % (self.binary, error))
        out = done.stdout.decode("utf-8", "replace")
        err = done.stderr.decode("utf-8", "replace")
        self._log(err)
        if done.returncode != 0:
            raise SqlError(self._reason(err) or "exapump exited with %s" % done.returncode)
        return self._results(out)

    @staticmethod
    def _results(text):
        decoder = json.JSONDecoder()
        results, index = [], 0
        while True:
            while index < len(text) and text[index].isspace():
                index += 1
            if index >= len(text):
                return results
            try:
                value, index = decoder.raw_decode(text, index)
            except ValueError:
                raise SqlError("exapump printed something that is not JSON: %r" % text[index:index + 80])
            results.append(value if isinstance(value, list) else [])

    @staticmethod
    def _reason(err):
        """The database's own message, without the session id."""
        for line in reversed(err.splitlines()):
            line = line.strip()
            if line.startswith("Error:") or "execution failed" in line:
                line = re.sub(r"^Error:\s*", "", line)
                line = re.sub(r"^Query execution failed:\s*(Protocol error:\s*)?", "", line)
                return re.sub(r"\s*\(Session: \d+\)", "", line)
        return ""


class Preprocessor(object):
    def __init__(self, args):
        self.args = args
        self.db = Exapump(args.exapump, args.profile, getattr(args, "log", None))
        self.package = load_package_manifest()
        self.dispatcher = self.package["dispatcher"]

    # --- state -----------------------------------------------------------------
    def record(self):
        try:
            return state.component(state.read_manifest(self.args.manifest), COMPONENT)
        except state.StateError:
            return {}

    def save(self, fields, remove=()):
        state.update_component(self.args.manifest, COMPONENT, fields, remove)

    def inspect(self):
        """What the database holds right now."""
        results = self.db.run("\n".join([
            "SELECT SYSTEM_VALUE AS S FROM EXA_PARAMETERS WHERE PARAMETER_NAME = 'SQL_PREPROCESSOR_SCRIPT';",
            "SELECT SCHEMA_NAME AS N FROM EXA_SCHEMAS WHERE SCHEMA_NAME IN (%s);"
            % ", ".join(sql_literal(name) for name in self.package["schemas"]),
            "SELECT SCRIPT_SCHEMA || '.' || SCRIPT_NAME AS N FROM EXA_ALL_SCRIPTS"
            " WHERE SCRIPT_SCHEMA IN (%s);" % ", ".join(sql_literal(name) for name in self.package["schemas"]),
            "SELECT ROLE_NAME AS N FROM EXA_DBA_ROLES WHERE ROLE_NAME = %s;" % sql_literal(self.package["role"]),
        ]))
        if len(results) != 4:
            raise SqlError("the inspection returned %d result sets, expected 4" % len(results))
        slot_rows, schema_rows, script_rows, role_rows = results
        scripts = set(row.get("N") for row in script_rows)
        schemas = set(row.get("N") for row in schema_rows)
        return {
            "slot": normalize_slot(slot_rows[0].get("S")) if slot_rows else "",
            "schemas": sorted(schemas),
            "scripts": sorted(scripts),
            "role": bool(role_rows),
            "present": bool(scripts or schemas or role_rows),
            "missing": [name for name in self.package["required_scripts"] if name not in scripts]
                       + [name for name in self.package["schemas"] if name not in schemas]
                       + ([] if role_rows else [self.package["role"]]),
        }

    # --- checks ----------------------------------------------------------------
    def ordinary_sql_works(self):
        rows = self.db.run(ORDINARY)
        return bool(rows and rows[0] and rows[0][0].get("R") == "EXAKIT_PP_ORDINARY")

    def probe_dispatches(self, sql_prefix=""):
        rows = self.db.run(sql_prefix + PROBE_IN)
        last = rows[-1] if rows else []
        return bool(last and last[0].get("R") == PROBE_OUT)

    def deploy_probe(self):
        with open(os.path.join(HERE, "checks", "probe_module.sql"), encoding="utf-8") as handle:
            module = handle.read()
        self.drop_probe(quiet=True)
        self.db.run("\n".join([
            BYPASS, module,
            "EXECUTE SCRIPT PREPROC.RULE_ENSURE('USER', %s, 'EXPAND', %s, %s, NULL, FALSE);"
            % (sql_literal(self.args.admin_user.upper()), sql_literal(PROBE_SCRIPT), sql_literal(PROBE_FUNCTION)),
        ]))

    def drop_probe(self, quiet=False):
        """Remove every probe rule and the probe script. Safe to repeat."""
        try:
            results = self.db.run(BYPASS + "\nSELECT RULE_ID AS ID FROM PREPROC.CONFIG WHERE SCRIPT_NAME = %s;"
                                  % sql_literal(PROBE_SCRIPT))
            ids = [row.get("ID") for row in (results[-1] if results else []) if row.get("ID") is not None]
            statements = [BYPASS]
            statements += ["EXECUTE SCRIPT PREPROC.RULE_DROP(%s, FALSE);" % int(rule_id) for rule_id in ids]
            statements.append("DROP SCRIPT IF EXISTS %s;" % PROBE_SCRIPT)
            self.db.run("\n".join(statements))
        except SqlError as error:
            if not quiet:
                emit("WARN", "The activation probe could not be removed (%s); it is scoped to %s only."
                     % (error, self.args.admin_user.upper()))

    def restore_slot(self, previous):
        """Put the database default back to what it was before this run."""
        value = previous if previous else "NULL"
        self.db.run("%s\nALTER SYSTEM SET sql_preprocessor_script = %s;" % (BYPASS, value))

    # --- the flows -------------------------------------------------------------
    def fresh_install(self, recover=False):
        package = self.args.package
        if not package or not os.path.isfile(package):
            raise Outcome(EXIT_NEED_PACKAGE, "Fresh install: fetching the pinned framework package")
        actual = sha256_of(package)
        if actual != self.args.pin_sha256.lower():
            raise Outcome(EXIT_BAD_PACKAGE, "the framework package does not match the pinned SHA-256"
                          " (expected %s, got %s)" % (self.args.pin_sha256.lower(), actual))
        with open(package, encoding="utf-8", newline="") as handle:
            body, removed = core_only(handle.read())
        core_sha = sha256_text(body)
        if self.args.pin_core_sha256 and core_sha != self.args.pin_core_sha256.lower():
            raise Outcome(EXIT_BAD_PACKAGE, "the core-only package derived from the verified download does not"
                          " match its pin (expected %s, got %s)" % (self.args.pin_core_sha256.lower(), core_sha))
        if recover:
            self.drop_own_partial_install()
        # Recorded BEFORE any SQL runs: a run that dies part way leaves this
        # record, and it is the only proof the next run has that the objects it
        # finds are the kit's own and safe to drop.
        self.save({"state": "installing", "version": self.args.pin_version, "source_ref": self.args.pin_ref,
                   "sha256": actual, "package": "core-only", "core_sha256": core_sha,
                   "left_out": removed, "validated": False},
                  remove=("installed_at", "verified_at", "activated_at", "previous_setting", "origin"))
        try:
            self.db.run(BYPASS + "\n" + body, timeout=INSTALL_TIMEOUT)
        except SqlError as error:
            raise Outcome(EXIT_FAILED, "the framework install did not finish: %s" % error)
        found = self.inspect()
        if found["missing"]:
            raise Outcome(EXIT_FAILED, "the framework install finished without %s" % ", ".join(found["missing"]))
        self.save({"state": "installed", "origin": "kit", "installed_at": now()})
        emit("INFO", "SQL preprocessor framework %s installed (not active yet)" % self.args.pin_version)
        return found

    def drop_own_partial_install(self):
        """Drop what the kit's own interrupted install created, and nothing else."""
        seeds = set(self.package["seed_scripts"]) | {PROBE_SCRIPT}
        try:
            results = self.db.run(BYPASS + "\nSELECT DISTINCT SCRIPT_NAME AS N FROM PREPROC.CONFIG;")
            foreign = sorted(row.get("N") for row in (results[-1] if results else [])
                             if row.get("N") not in seeds)
        except SqlError:
            foreign = []        # no CONFIG table yet: nothing anyone configured
        if foreign:
            raise Outcome(EXIT_FAILED, "an interrupted framework install was found, but PREPROC.CONFIG"
                          " already has rules for %s; the kit will not drop it. Keep them by activating the framework"
                          " (ALTER SYSTEM SET sql_preprocessor_script = PREPROC_RT.MASTER), or remove those rules,"
                          " then run the command below" % ", ".join(foreign))
        statements = [BYPASS]
        statements += ["DROP SCHEMA IF EXISTS %s CASCADE;" % name for name in self.package["schemas"]]
        statements.append("DROP ROLE IF EXISTS %s CASCADE;" % self.package["role"])
        try:
            self.db.run("\n".join(statements))
        except SqlError as error:
            raise Outcome(EXIT_FAILED, "the interrupted framework install could not be cleaned up: %s" % error)
        emit("INFO", "Cleaned up an interrupted framework install before reinstalling")

    def activate(self, previous):
        """Trial in one session, then the database default, then fresh-connection checks."""
        try:
            try:
                self.deploy_probe()
            except SqlError as error:
                raise Outcome(EXIT_FAILED, "the activation probe could not be deployed: %s" % error)
            trial = "ALTER SESSION SET sql_preprocessor_script = %s;\n%s;\n" % (self.dispatcher, ORDINARY)
            try:
                rows = self.db.run(trial + PROBE_IN)
            except SqlError as error:
                raise Outcome(EXIT_FAILED, "a session using the dispatcher failed: %s" % error)
            ordinary_ok = len(rows) >= 2 and rows[0] and rows[0][0].get("R") == "EXAKIT_PP_ORDINARY"
            probe_ok = bool(rows and rows[-1] and rows[-1][0].get("R") == PROBE_OUT)
            if not ordinary_ok:
                raise Outcome(EXIT_FAILED, "ordinary SQL did not come back unchanged in a session using the dispatcher")
            if not probe_ok:
                raise Outcome(EXIT_FAILED, "the dispatcher did not run a module scoped to %s"
                              % self.args.admin_user.upper())
            # The recovery value goes on disk before the default changes.
            self.save({"previous_setting": previous})
            try:
                self.db.run("ALTER SYSTEM SET sql_preprocessor_script = %s;" % self.dispatcher)
            except SqlError as error:
                raise Outcome(EXIT_FAILED, "the database default could not be set: %s" % error)
            problem = self.verify_active(dispatch=True)
            if problem:
                self.roll_back(previous, problem)
        finally:
            self.drop_probe()
        self.save({"state": "active", "validated": True, "activated_at": now(), "verified_at": now()})

    def verify_active(self, dispatch=False):
        """None when fresh connections see a working dispatcher, else the reason."""
        try:
            if not self.ordinary_sql_works():
                return "ordinary SQL did not come back unchanged with the framework active"
            if dispatch and not self.probe_dispatches():
                return "a fresh connection did not dispatch to the scoped probe module"
            results = self.db.run("\n".join([
                "SELECT SYSTEM_VALUE AS S FROM EXA_PARAMETERS WHERE PARAMETER_NAME = 'SQL_PREPROCESSOR_SCRIPT';",
                "SELECT COUNT(*) AS N FROM PREPROC_RT.MY_PIPELINE;",
            ]))
        except SqlError as error:
            return "a fresh connection failed with the framework active: %s" % error
        slot = normalize_slot(results[0][0].get("S")) if results and results[0] else ""
        if slot != self.dispatcher:
            return "the database default is %s, not %s" % (slot or "empty", self.dispatcher)
        return None

    def roll_back(self, previous, problem):
        try:
            self.restore_slot(previous)
            restored = self.ordinary_sql_works()
        except SqlError as error:
            raise Outcome(EXIT_FAILED, "%s, and restoring the previous setting failed: %s" % (problem, error))
        self.save({"state": "installed", "validated": False}, remove=("activated_at", "verified_at"))
        if not restored:
            raise Outcome(EXIT_FAILED, "%s; the previous setting was restored but ordinary SQL still fails" % problem)
        raise Outcome(EXIT_FAILED, "%s; the previous setting was restored and ordinary SQL works" % problem)

    def upgrade_note(self, rec):
        installed = rec.get("version")
        if not installed or installed == self.args.pin_version:
            return
        tested = [step for step in self.package.get("upgrades") or []
                  if step.get("from") == installed and step.get("to") == self.args.pin_version]
        if not tested:
            emit("WARN", "Framework %s is installed and this kit pins %s; there is no tested upgrade path"
                 " yet, so the installed framework is kept as it is" % (installed, self.args.pin_version))

    def ensure(self):
        try:
            found = self.inspect()
        except SqlError as error:
            raise Outcome(EXIT_FAILED, "the database could not be inspected: %s" % error)
        rec = self.record()
        ours = rec.get("state") in ("installing", "installed", "active")
        slot = found["slot"]

        if slot and slot != self.dispatcher:
            raise Outcome(EXIT_CONFLICT, "the database's SQL preprocessor slot holds %s, which the kit does"
                          " not manage; it was left unchanged. To let the kit's framework own the slot, move that"
                          " script into a framework module or clear the slot (ALTER SYSTEM SET"
                          " sql_preprocessor_script = NULL), then run the command below" % slot)

        if not found["present"]:
            # A slot naming a dispatcher that no longer exists is no setting
            # worth restoring.
            self.fresh_install()
            self.activate(previous="")
        elif not ours and slot != self.dispatcher:
            raise Outcome(EXIT_CONFLICT, "a preprocessor framework the kit did not install is already in this"
                          " database and is not active; it was left unchanged. To have the kit manage it, activate it"
                          " (ALTER SYSTEM SET sql_preprocessor_script = PREPROC_RT.MASTER) and run the command below -"
                          " the kit then verifies and adopts it")
        elif rec.get("state") == "installing" and slot != self.dispatcher:
            self.fresh_install(recover=True)
            self.activate(previous="")
        else:
            if found["missing"]:
                raise Outcome(EXIT_FAILED, "framework objects are missing (%s); the kit does not replay its"
                              " fresh install over an existing framework" % ", ".join(found["missing"]))
            if not ours:
                # Installed and activated by hand: verified, then managed.
                self.save({"state": "active", "origin": "pre-existing", "validated": False})
                rec = self.record()
            self.upgrade_note(rec)
            if slot != self.dispatcher:
                if rec.get("state") == "active":
                    emit("INFO", "The framework was installed but is no longer active - activating it again")
                # The slot is empty here (any other value was a conflict above),
                # so the setting to restore is the one recorded before the kit
                # first activated, or empty.
                self.activate(previous=rec.get("previous_setting", ""))
            else:
                problem = self.verify_active()
                if problem:
                    self.roll_back(rec.get("previous_setting", ""), problem)
                # "active" here too: a framework activated by hand after an
                # interrupted install was still recorded as "installing".
                self.save({"state": "active", "validated": True, "verified_at": now()})
                emit("OK", "SQL preprocessor framework %s verified and active" % self.version_label())
                self.refresh_if_stale()
                return EXIT_OK
        emit("OK", "SQL preprocessor framework %s installed, tested and activated" % self.version_label())
        emit("OK", "Ordinary SQL verified with the framework active")
        return EXIT_OK

    def refresh_if_stale(self):
        """Rules reach users through PREPROC.RESOLUTION, a per-user table the
        framework rebuilds only on REFRESH (and on its own admin scripts). A user
        or role grant created since then gets none of its ROLE-scoped rules, and
        the framework expects its operator to refresh - here, every kit run.
        Never fatal: the framework works, it is only behind."""
        try:
            rows = self.db.run("EXECUTE SCRIPT PREPROC.STATUS;")
            row = rows[0][0] if rows and rows[0] else {}
            if str(row.get("IS_STALE")).lower() != "true":
                return
            self.db.run("EXECUTE SCRIPT PREPROC.REFRESH;")
        except SqlError as error:
            emit("WARN", "The framework's rule resolution could not be refreshed (%s); as the admin, run:"
                 " EXECUTE SCRIPT PREPROC.REFRESH" % error)
            return
        last = str(row.get("LAST_REFRESH") or "")[:16]
        emit("OK", "Rule resolution refreshed for users and roles changed since %s"
             % ("the last refresh (%s, database time)" % last if last else "the install"))

    def version_label(self):
        return self.record().get("version") or "(installed outside the kit)"


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _parser():
    parser = argparse.ArgumentParser(prog="manage.py", description="SQL preprocessor framework setup.")
    sub = parser.add_subparsers(dest="command")
    derive = sub.add_parser("derive")
    derive.add_argument("--package", required=True)
    derive.add_argument("--out", default="")
    for name in ("ensure", "inspect"):
        cmd = sub.add_parser(name)
        cmd.add_argument("--exapump", required=True)
        cmd.add_argument("--profile", required=True)
        cmd.add_argument("--manifest", required=True)
        cmd.add_argument("--log", default="")
        if name == "ensure":
            cmd.add_argument("--admin-user", required=True)
            cmd.add_argument("--pin-version", required=True)
            cmd.add_argument("--pin-ref", required=True)
            cmd.add_argument("--pin-sha256", required=True)
            cmd.add_argument("--pin-core-sha256", default="")
            cmd.add_argument("--package", default="")
    return parser


def main(argv=None):
    parser = _parser()
    args = parser.parse_args(argv)
    if not args.command:
        parser.print_usage(sys.stderr)
        return state.EXIT_USAGE
    if args.command == "derive":
        # The maintainer's and CI's view of the core-only package: its digest
        # (the value pinned as sha256.core-only) and what it leaves out.
        with open(args.package, encoding="utf-8", newline="") as handle:
            body, removed = core_only(handle.read())
        if args.out:
            with open(args.out, "w", encoding="utf-8", newline="") as handle:
                handle.write(body)
        print(json.dumps({"sha256": sha256_text(body), "left_out": removed}))
        return EXIT_OK
    manager = Preprocessor(args)
    if args.command == "inspect":
        try:
            found = manager.inspect()
        except SqlError as error:
            print(json.dumps({"ok": False, "error": str(error)}))
            return EXIT_FAILED
        found["record"] = manager.record()
        print(json.dumps(dict(found, ok=True), indent=2))
        return EXIT_OK
    if not re.match(r"^[0-9a-fA-F]{64}$", args.pin_sha256) or (
            args.pin_core_sha256 and not re.match(r"^[0-9a-fA-F]{64}$", args.pin_core_sha256)):
        emit("FAIL", "the pinned SHA-256 is not a 64-character hex digest")
        return state.EXIT_USAGE
    try:
        return manager.ensure()
    except Outcome as outcome:
        # Asking for the package is a step of a normal fresh install, not a
        # failure: the caller fetches it and calls again.
        emit("INFO" if outcome.code == EXIT_NEED_PACKAGE else "FAIL", str(outcome))
        return outcome.code
    except state.StateError as error:
        emit("FAIL", "the install manifest could not be updated: %s" % error)
        return EXIT_FAILED


if __name__ == "__main__":
    sys.exit(main())
