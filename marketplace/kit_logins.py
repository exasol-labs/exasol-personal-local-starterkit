"""The kit's own logins inside a database it does not own, dropped at uninstall (SEC-01).

A database the user let the kit use (runtime.ownership "user": one of their own Exasol Personal deployments) is never
destroyed by `exakit uninstall`, and it keeps its name. What the kit created inside it to work with it goes, before
the kit's own tools do:

  - the read-only login the AI clients used (components.mcp_server.connection.user, MCP_READONLY by default)
  - the Exasol Scheduler's login (components.exasol_scheduler.db_user), when the kit's add-on made it
  A login is dropped only when the kit created it: its record says the kit ran CREATE USER for it
  (components.mcp_server.connection.created, components.exasol_scheduler.db_user_created), or, from a kit before that
  record (0.3.0), it has the kit's own name (MCP_READONLY, SCHEDULER_SVC). A login named by EXAKIT_MCP_READONLY_USER
  or EXAKIT_EXASOL_SCHEDULER_USER, one made in another database (its record's made_in, the deployment id it was written
  for, is not runtime.deployment_id; the same holds for the roles below), or one the kit took over (it was there already: ALTER USER, not CREATE USER), stays
  as it is, nothing revoked from it, and the statement that drops it is printed for the user.
  - SEMANTIC_USER (Semantic Views, components.semantic_views.role_created) and PREPROC_ADMIN (the SQL preprocessor
    framework, setup/preprocessor/manifest.json), when the kit created them and nothing the kit did not create holds
    them: a user or role of the database's own that was granted one keeps it

Never with CASCADE, which would delete the schemas the dropped login or role owns with everything in them. Exasol
refuses to drop an owner of a schema without it, so every schema a kit login or role owns is handed to SYS first
(ALTER SCHEMA ... CHANGE OWNER SYS), then it is dropped: PREPROC_ADMIN owns the framework's PREPROC and PREPROC_RT,
the Scheduler's login its task schema, and those schemas stay, PREPROC_RT.MASTER included. A schema that cannot be
handed over keeps its owner, and that owner is not dropped (said, with the statements that finish it). Exasol keeps
a dropped user's open sessions until they are killed, so a login's sessions end first: its CREATE SESSION is
revoked, then each session is killed. Kept, and said: the connections the kit made for its sources (each with the
statement that drops it), the virtual schemas, Semantic Views and the SQL preprocessor framework (PREPROC_RT.MASTER
keeps the slot).

    kit_logins.py plan --home DIR --database NAME     what the removal does, in its order; reads, never changes
    kit_logins.py drop --home DIR --database NAME     connect as the kit's administrator and drop

The dry run (plan) asks the database which schemas each login or role owns, read only, so it names every schema a
real run hands to SYS; when the database cannot be asked it names the recorded ones "and any other schema it owns".

The full uninstall runs this before the add-ons go, and their own removal then leaves the database alone
(EXAKIT_UNINSTALL_KEEP_DATABASE, runtime.uninstall_keeps_database): this is the only change made inside it. A
database that does not answer is never started: the statements are printed for later, in the same order.

The connection is the one every kit-built pyexasol connection makes: the kit's administrator (runtime.user), the
password read from the kit's credential file (runtime.password_file) by the process that connects, and the DSN with
the database's TLS pin (KitContext.client_dsn). pyexasol is the kit's own (components.pyexasol.python): this file
runs on any Python 3 and starts itself again on that one when this one has no pyexasol.

Output: one line per event on stdout, "<KIND> <text>", which the shells render with the kit's own marks
(_exakit_uninstall_kit_logins in common.sh, Invoke-ExakitUninstallKitLogins in exakit.ps1):
  PLAN  a dry-run step, shown as "will remove: <text>"
  OK    something removed (a record line)
  INFO  something kept, or a statement to run by hand
  WARN  something that did not happen
No line holds a password: every error text is redacted before it is printed.

Exit codes: 0 done, or nothing to do; 1 something was not removed (said, with the statement to run by hand);
2 usage; 3 the database is not running (nothing changed; the statements to run later are printed).
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import ssl
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

from runtime import AddonFailure, KitContext, Manifest, made_in_this_database, utf8_child

ROOT = Path(__file__).resolve().parents[1]
IDENTIFIER = re.compile(r"^[A-Z][A-Z0-9_]{0,127}$")
SEMANTIC_ROLE = "SEMANTIC_USER"
SEMANTIC_SCHEMAS = ("SEMANTIC_AGENT", "SEMANTIC_SOURCE", "SEMANTIC_CATALOG", "SEMANTIC_ADMIN", "SYS_SEMANTIC")
PREPROC_ROLE = "PREPROC_ADMIN"                    # setup/preprocessor/manifest.json "role", when it cannot be read
PREPROC_SCHEMAS = ("PREPROC", "PREPROC_RT")       # ...and its "schemas", which that role owns
SCHEDULER_SCHEMA = "SCHED"                        # the Scheduler's task schema when its receipt names none
MCP_LOGIN = "MCP_READONLY"                        # the kit's own name for the read-only login (setup/lib/common.sh)
SCHEDULER_LOGIN = "SCHEDULER_SVC"                 # ...and the Scheduler add-on's (marketplace/addons/exasol_scheduler.py)
NEW_OWNER = "SYS"                                 # who a kept schema goes to before its owner is dropped
PREPROC_DISPATCHER = "PREPROC_RT.MASTER"
CONNECTION_PREFIXES = ("EXAKIT_SRC_", "EXAKIT_PREVIOUS_EXAKIT_SRC_")   # the virtual-schema engine's names
# manage.py's BYPASS: the session's statements never pass through any preprocessor, a broken one included.
BYPASS = "ALTER SESSION SET sql_preprocessor_script = ''"
FAKE_DB = "EXAKIT_KIT_LOGINS_FAKE_DB"            # tests: a module whose connect(dsn=, user=) stands in for pyexasol
EXIT_OK, EXIT_LEFT, EXIT_USAGE, EXIT_UNREACHABLE = 0, 1, 2, 3
# pyexasol's exceptions for "nothing answered there", by name: the driver's version decides the module they live in.
UNREACHABLE = ("ExaConnectionFailedError", "ExaCommunicationError", "ExaConnectionClosedError")


class Unreachable(Exception):
    """The database did not answer: it is not running."""


class NoLogin(Exception):
    """The database answered, and the kit could not sign in (why, redacted)."""


@dataclass
class Plan:
    database: str
    admin: str                                   # as recorded (runtime.user), for "run this as <admin>"
    logins: list = field(default_factory=list)
    roles: list = field(default_factory=list)
    connections: list = field(default_factory=list)
    virtual_schemas: list = field(default_factory=list)
    preprocessor: bool = False
    semantic_views: bool = False                 # its schemas (and the models in them) stay
    owned: dict = field(default_factory=dict)    # login or role -> the schemas the kit's records say it owns
    kept_logins: list = field(default_factory=list)  # logins in the records the kit did not create: never dropped

    def drops(self) -> bool:
        return bool(self.logins or self.roles)


def _identifier(value: object) -> str | None:
    text = str(value or "").strip().upper()
    return text if IDENTIFIER.fullmatch(text) else None


def _get(doc: object, dotted: str, default=None):
    node = doc
    for key in dotted.split("."):
        if not isinstance(node, dict) or key not in node:
            return default
        node = node[key]
    return node


def _kit_made(name: str, default: str, created: object) -> bool:
    """The kit created the login ``name`` itself, so the uninstall may drop it. Its record says so (``created``, written
    when the kit ran CREATE USER for it; False when it took over a login that was there), or, from a kit before that
    record (0.3.0, no flag), the login has the kit's own name. A name another one chose (EXAKIT_MCP_READONLY_USER,
    EXAKIT_EXASOL_SCHEDULER_USER) is never the kit's to drop, whoever created it."""
    if name != default:
        return False
    if created is None:
        return True
    return created is True or str(created).strip().lower() == "true"


def _unique(names: list) -> list:
    seen: list = []
    for name in names:
        if name and name not in seen:
            seen.append(name)
    return seen


def _preproc_package(root: Path) -> tuple:
    """(the framework's role, the schemas it owns), from setup/preprocessor/manifest.json."""
    try:
        doc = json.loads((root / "setup" / "preprocessor" / "manifest.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        doc = {}
    doc = doc if isinstance(doc, dict) else {}
    listed = doc.get("schemas") if isinstance(doc.get("schemas"), list) else []
    schemas = [name for name in (_identifier(item) for item in listed) if name]
    return _identifier(doc.get("role")) or PREPROC_ROLE, schemas or list(PREPROC_SCHEMAS)


def _sources(home: Path) -> tuple[list, list]:
    """(connections, virtual schemas) the kit recorded for its sources (<home>/sources/<name>/config.json)."""
    connections, schemas = [], []
    for config in sorted((home / "sources").glob("*/config.json")):
        try:
            doc = json.loads(config.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        objects = doc.get("objects") if isinstance(doc, dict) else None
        objects = objects if isinstance(objects, dict) else {}
        upper = config.parent.name.upper()
        connections.append(_identifier(objects.get("connection")) or _identifier("EXAKIT_SRC_" + upper))
        schemas.append(_identifier(objects.get("schema")) or _identifier("VS_" + upper))
    return _unique(connections), _unique(schemas)


def build_plan(doc: dict, home: Path, database: str, *, root: Path = ROOT) -> Plan:
    """What the kit made inside the database, from its own records: never a guess from names in the database. The
    schemas a login or role owns are the records' too (a dry run and the statements for later); a real run asks the
    database which ones it owns."""
    admin = str(_get(doc, "runtime.user") or "sys")
    never = {NEW_OWNER, _identifier(admin) or NEW_OWNER}
    plan = Plan(database=database or "starter-kit-local", admin=admin)

    def here(receipt: str) -> bool:
        return made_in_this_database(lambda dotted: _get(doc, dotted), receipt)
    logins, kept = [], []
    connection = _get(doc, "components.mcp_server.connection") or {}
    connection = connection if isinstance(connection, dict) else {}
    login = _identifier(connection.get("user"))
    if login:
        made = here("components.mcp_server.connection") and _kit_made(login, MCP_LOGIN, connection.get("created"))
        (logins if made else kept).append(login)
    scheduler = _get(doc, "components.exasol_scheduler") or {}
    if isinstance(scheduler, dict) and scheduler.get("ownership") == "kit":
        login = _identifier(scheduler.get("db_user") or "scheduler_svc")
        if login and here("components.exasol_scheduler") and \
                _kit_made(login, SCHEDULER_LOGIN, scheduler.get("db_user_created")):
            logins.append(login)
            schema = _identifier(scheduler.get("schema") or SCHEDULER_SCHEMA)
            if schema:
                plan.owned[login] = [schema]    # its engine made it, as this login, when it was not there yet
        elif login:
            kept.append(login)
    plan.logins = [name for name in _unique(logins) if name not in never]
    plan.kept_logins = [name for name in _unique(kept) if name not in never and name not in plan.logins]
    semantic = _get(doc, "components.semantic_views") or {}
    if isinstance(semantic, dict) and semantic.get("role_created") and here("components.semantic_views"):
        plan.roles.append(SEMANTIC_ROLE)
    framework = _get(doc, "components.preprocessor") or {}
    if isinstance(framework, dict) and here("components.preprocessor") and \
            (framework.get("origin") == "kit" or framework.get("state") == "installing" or
             framework.get("role_created") is True):
        # The kit's own install made the role ("installing": recorded before its first statement, manage.py), or a
        # later one put it back into a framework an earlier uninstall left here ("role_created"), and the role owns
        # the framework's schemas.
        role, schemas = _preproc_package(root)
        plan.roles.append(role)
        plan.owned[role] = schemas
    plan.roles = [name for name in _unique(plan.roles) if name not in never]
    plan.connections, plan.virtual_schemas = _sources(home)
    plan.preprocessor = isinstance(framework, dict) and framework.get("state") == "active" and \
        not framework.get("declined")
    plan.semantic_views = isinstance(semantic, dict) and bool(semantic)
    return plan


def _join(names: list) -> str:
    """'A', 'A and B', 'A, B and C'."""
    names = list(names)
    return names[0] if len(names) == 1 else ", ".join(names[:-1]) + " and " + names[-1]


def kept_lines(connections: list, schemas: list, preprocessor: bool, semantic_views: bool = False,
               logins: tuple = ()) -> list:
    """What stays in the database, said the same before (a dry run) and after (a real run). ``logins``: the ones in
    the kit's records it did not create, which it never drops."""
    lines = [("INFO", f"The login {name} stays in your database: the kit did not create it. To remove it: "
                      f"DROP USER {name};") for name in logins]
    lines += [("INFO", f"The connection {name} stays in your database. To remove it: DROP CONNECTION {name};")
              for name in connections]
    if len(schemas) == 1:
        lines.append(("INFO", f"The virtual schema {schemas[0]} stays in your database."))
    elif schemas:
        lines.append(("INFO", f"The virtual schemas {_join(schemas)} stay in your database."))
    if semantic_views:
        lines.append(("INFO", "The Semantic Views schemas and their models stay in your database."))
    if preprocessor:
        lines.append(("INFO", f"The SQL preprocessor {PREPROC_DISPATCHER} stays in your database."))
    return lines


def recorded_kept(plan: Plan) -> list:
    """kept_lines from the kit's records: a dry run, or a database that cannot be asked."""
    return kept_lines(plan.connections, plan.virtual_schemas, plan.preprocessor, plan.semantic_views,
                      plan.kept_logins)


def _steps(owned: list, drop: str, *, other: bool = False) -> str:
    """The order of a removal whose login or role owns schemas: they go to SYS first, then the drop. ``other``: the
    database was not asked, so the schemas named are the records' ones and any other it owns goes too (a real run
    hands every schema its owner has to SYS)."""
    if other:
        if not owned:
            return (f". Any schema it owns stays and goes to {NEW_OWNER} first "
                    f"(ALTER SCHEMA ... CHANGE OWNER {NEW_OWNER} for each, then {drop})")
        named = f"Its schema {owned[0]}" if len(owned) == 1 else f"Its schemas {_join(owned)}"
        return (f". {named} and any other schema it owns stay and go to {NEW_OWNER} first "
                f"(ALTER SCHEMA ... CHANGE OWNER {NEW_OWNER} for each, then {drop})")
    if not owned:
        return f" ({drop})"
    if len(owned) == 1:
        return (f". Its schema {owned[0]} stays and goes to {NEW_OWNER} first "
                f"(ALTER SCHEMA {owned[0]} CHANGE OWNER {NEW_OWNER}, then {drop})")
    return (f". Its schemas {_join(owned)} stay and go to {NEW_OWNER} first "
            f"(ALTER SCHEMA ... CHANGE OWNER {NEW_OWNER} for each, then {drop})")


def plan_lines(plan: Plan, owned: dict | None = None) -> list:
    """The dry run's lines, in the order a real run takes. ``owned``: every schema each login or role owns, as the
    database answered (the set a real run hands to SYS); None when it could not be asked."""
    def steps(name: str, drop: str) -> str:
        if owned is None:
            return _steps(plan.owned.get(name) or [], drop, other=True)
        return _steps(owned.get(name) or [], drop)
    lines = [("PLAN", f"the kit's login {name} in your database '{plan.database}'" + steps(name, "DROP USER"))
             for name in plan.logins]
    lines += [("PLAN", f"the role {name} in your database '{plan.database}', unless one of your own users holds it"
                       + steps(name, "DROP ROLE")) for name in plan.roles]
    return lines + recorded_kept(plan)


def later_lines(plan: Plan, *, stopped: bool = False) -> list:
    """The statements that finish the job, in the order a real run takes, for the user to run: once the database
    runs, or by hand. A schema goes to SYS before its owner is dropped (DROP without CASCADE refuses an owner)."""
    statements = []
    for name in plan.logins:
        recorded = plan.owned.get(name) or []
        statements += [f"ALTER SCHEMA {schema} CHANGE OWNER {NEW_OWNER};  -- if {name} owns it" for schema in recorded]
        statements.append(_any_other(name, recorded))
        statements.append(f"DROP USER IF EXISTS {name};")
    for name in plan.roles:
        recorded = plan.owned.get(name) or []
        statements.append(f"-- only if none of your own users needs the role {name}:")
        statements += [f"ALTER SCHEMA {schema} CHANGE OWNER {NEW_OWNER};" for schema in recorded]
        statements.append(_any_other(name, recorded))
        statements.append(f"DROP ROLE IF EXISTS {name};")
    when = "once it runs" if stopped else "by hand"
    return [("INFO", f"Remove them {when}, as {plan.admin}:")] + [("INFO", "  " + text) for text in statements]


def _any_other(owner: str, recorded: list) -> str:
    """The statement for later that covers the schemas the records do not name: the database was not asked, and a
    DROP without CASCADE refuses an owner of any schema."""
    which = "any other schema" if recorded else "any schema"
    return f"-- {which} {owner} owns: ALTER SCHEMA <name> CHANGE OWNER {NEW_OWNER};"


def _reason(error: BaseException, secret: str = "") -> str:
    text = str(getattr(error, "message", "") or error or type(error).__name__)
    if secret:
        text = text.replace(secret, "***")
    first = next((line.strip() for line in text.splitlines() if line.strip()), type(error).__name__)
    return first[:200].rstrip(".")


def _literals(names: list) -> str:
    return ", ".join(f"'{name}'" for name in names)


def _quoted(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def _shown(name: str) -> str:
    """A schema name as a statement to type shows it: bare when it is a plain identifier, quoted when it is not."""
    return name if IDENTIFIER.fullmatch(name) else _quoted(name)


def _owned_by(db, owner: str) -> list:
    """(schema, is virtual) for every schema ``owner`` owns now."""
    rows = db.query("SELECT SCHEMA_NAME, SCHEMA_IS_VIRTUAL FROM SYS.EXA_SCHEMAS "
                    f"WHERE SCHEMA_OWNER = '{owner}' ORDER BY SCHEMA_NAME")
    return [(str(row[0]), len(row) > 1 and str(row[1]).strip().upper() in ("TRUE", "1")) for row in rows]


def _alter(schema: str, virtual: bool, show: bool = False) -> str:
    kind = "VIRTUAL SCHEMA" if virtual else "SCHEMA"
    if show:
        return f"ALTER {kind} {_shown(schema)} CHANGE OWNER {NEW_OWNER};"
    return f"ALTER {kind} {_quoted(schema)} CHANGE OWNER {NEW_OWNER}"


def _hand_over(db, owner: str, what: str, plan: Plan, lines: list) -> tuple:
    """Every schema ``owner`` owns goes to SYS, so the drop that follows needs no CASCADE and the schemas stay.
    (handed, still to run): what was handed over, and when one could not be, the statements still to run from that
    one on (the drop after them is the caller's), with the reason said."""
    try:
        owned = _owned_by(db, owner)
    except Exception:  # noqa: BLE001 - not listed: the drop itself refuses while it still owns one, and says so
        return [], []
    handed = []
    for index, (schema, virtual) in enumerate(owned):
        try:
            db.execute(_alter(schema, virtual))
            handed.append(schema)
        except Exception as error:  # noqa: BLE001 - its owner stays: never dropped with CASCADE
            lines.append(("WARN", f"The schema {schema} could not be handed to {NEW_OWNER}, so {what} was not removed "
                                  f"from your database '{plan.database}': {_reason(error)}."))
            return handed, [_alter(name, flag, show=True) for name, flag in owned[index:]]
    return handed, []


def _stays(handed: list) -> list:
    if not handed:
        return []
    if len(handed) == 1:
        return [("INFO", f"The schema {handed[0]} stays in your database, now owned by {NEW_OWNER}.")]
    return [("INFO", f"The schemas {_join(handed)} stay in your database, now owned by {NEW_OWNER}.")]


def apply(plan: Plan, db) -> tuple:
    """Drop the plan's logins and roles through ``db`` (query(sql) -> rows, execute(sql)); (exit code, lines)."""
    lines, left = [], []
    try:
        db.execute(BYPASS)
    except Exception:  # noqa: BLE001 - a database with no preprocessor setting still takes the drops
        pass
    present = set()
    asked = plan.logins + plan.kept_logins
    if asked:
        present = {str(row[0]).upper() for row in
                   db.query(f"SELECT USER_NAME FROM SYS.EXA_DBA_USERS WHERE USER_NAME IN ({_literals(asked)})")}
    dropped, kept_schemas = [], []
    for name in plan.logins:
        if name not in present:
            continue
        # Exasol keeps a dropped user's open sessions until they are killed (DROP USER): no new session, then the
        # open ones end.
        try:
            db.execute(f'REVOKE CREATE SESSION FROM "{name}"')
        except Exception:  # noqa: BLE001 - held through a role, or never granted: the drop below says
            pass
        try:
            sessions = db.query(f"SELECT SESSION_ID FROM SYS.EXA_DBA_SESSIONS WHERE USER_NAME = '{name}'")
        except Exception:  # noqa: BLE001 - no session list: nothing to end
            sessions = []
        for row in sessions:
            try:
                db.execute(f"KILL SESSION {int(row[0])}")
            except Exception:  # noqa: BLE001 - it ended on its own
                pass
        handed, still = _hand_over(db, name, f"the kit's login {name}", plan, lines)
        kept_schemas += handed
        if still:
            left += still + [f"DROP USER {name};"]
            continue
        try:
            db.execute(f'DROP USER "{name}"')
            dropped.append(name)
        except Exception as error:  # noqa: BLE001 - said, with the statement that finishes it
            lines.append(("WARN", f"The kit's login {name} was not removed from your database '{plan.database}': "
                                  f"{_reason(error)}."))
            left.append(f"DROP USER {name};")
    if dropped:
        word = "login" if len(dropped) == 1 else "logins"
        lines[:0] = [("OK", f"Removed the kit's {word} {_join(dropped)} from your database '{plan.database}'")] + \
            _stays(kept_schemas)
    elif kept_schemas:
        lines[:0] = _stays(kept_schemas)
    never = {NEW_OWNER, _identifier(plan.admin) or NEW_OWNER, *plan.logins}
    for role in plan.roles:
        try:
            if not db.query(f"SELECT ROLE_NAME FROM SYS.EXA_DBA_ROLES WHERE ROLE_NAME = '{role}'"):
                continue
            holders = sorted({str(row[0]).upper() for row in
                              db.query(f"SELECT GRANTEE FROM SYS.EXA_DBA_ROLE_PRIVS WHERE GRANTED_ROLE = '{role}'")}
                             - never)
        except Exception as error:  # noqa: BLE001 - who holds it is unknown: it stays
            lines.append(("WARN", f"The role {role} stays in your database: the kit could not check who holds it "
                                  f"({_reason(error)})."))
            continue
        if holders:
            lines.append(("INFO", f"The role {role} stays in your database: {_join(holders)} "
                                  f"{'holds' if len(holders) == 1 else 'hold'} it."))
            continue
        handed, still = _hand_over(db, role, f"the role {role}", plan, lines)
        if still:
            lines += _stays(handed)
            left += still + [f"DROP ROLE {role};"]
            continue
        try:
            db.execute(f'DROP ROLE "{role}"')
            lines += [("OK", f"Removed the role {role} from your database '{plan.database}'")] + _stays(handed)
        except Exception as error:  # noqa: BLE001 - said, with the statement that finishes it (never CASCADE)
            lines += [("WARN", f"The role {role} was not removed from your database '{plan.database}': "
                               f"{_reason(error)}.")] + _stays(handed)
            left.append(f"DROP ROLE {role};")
    # A login the kit did not create: nothing revoked, nothing ended, nothing handed over, never dropped.
    lines += kept_lines(*_kept_in(plan, db), logins=tuple(name for name in plan.kept_logins if name in present))
    if left:
        lines.append(("INFO", f"To finish, run this in your database as {plan.admin}:"))
        lines += [("INFO", "  " + statement) for statement in left]
    return (EXIT_LEFT if left else EXIT_OK), lines


def _kept_in(plan: Plan, db) -> tuple:
    """What stays, as the database has it now: the kit's connections (its records and the engine's names), the
    recorded virtual schemas that are there, Semantic Views when its schemas are, and the framework when it holds the
    slot. The records when it cannot be read."""
    try:
        listed = [str(row[0]).upper() for row in db.query("SELECT CONNECTION_NAME FROM SYS.EXA_DBA_CONNECTIONS")]
        connections = [name for name in _unique(plan.connections + sorted(
            name for name in listed if name.startswith(CONNECTION_PREFIXES))) if name in listed]
        schemas = []
        if plan.virtual_schemas:
            found = {str(row[0]).upper() for row in db.query(
                f"SELECT SCHEMA_NAME FROM SYS.EXA_SCHEMAS WHERE SCHEMA_NAME IN ({_literals(plan.virtual_schemas)})")}
            schemas = [name for name in plan.virtual_schemas if name in found]
        semantic = bool(db.query(
            f"SELECT SCHEMA_NAME FROM SYS.EXA_SCHEMAS WHERE SCHEMA_NAME IN ({_literals(list(SEMANTIC_SCHEMAS))})"))
        slot = db.query("SELECT SYSTEM_VALUE FROM SYS.EXA_PARAMETERS WHERE PARAMETER_NAME = 'SQL_PREPROCESSOR_SCRIPT'")
        holder = str(slot[0][0] or "").replace('"', "").upper() if slot else ""
        return connections, schemas, holder == PREPROC_DISPATCHER, semantic
    except Exception:  # noqa: BLE001 - the records still say what the kit made
        return plan.connections, plan.virtual_schemas, plan.preprocessor, plan.semantic_views


class _Pyexasol:
    """The two calls apply() makes, on a pyexasol connection."""

    def __init__(self, connection):
        self.connection = connection

    def query(self, sql: str) -> list:
        statement = self.connection.execute(sql)
        return [tuple(row) for row in statement.fetchall()] if statement.result_type == "resultSet" else []

    def execute(self, sql: str) -> None:
        self.connection.execute(sql)

    def close(self) -> None:
        try:
            self.connection.close()
        except Exception:  # noqa: BLE001
            pass


def connect(doc: dict, home: Path, root: Path = ROOT):
    """The kit's administrator connection: Unreachable when nothing answers, NoLogin when the database answered and
    the kit could not sign in, ImportError when this Python has no pyexasol."""
    manifest = Manifest(home / "manifest.json")
    dsn = KitContext(root, home, home, manifest, Path("uv")).client_dsn()
    user = str(_get(doc, "runtime.user") or "sys")
    if not dsn:
        raise NoLogin("no database address is recorded")
    fake = os.environ.get(FAKE_DB)
    if fake:
        spec = importlib.util.spec_from_file_location("exakit_kit_logins_fake_db", fake)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        try:
            return module.connect(dsn=dsn, user=user)
        except OSError as error:
            raise Unreachable(_reason(error)) from None
    credential = str(_get(doc, "runtime.password_file") or "")
    try:
        # utf-8-sig: a credential file Windows PowerShell 5.1 wrote may start with a byte order mark.
        password = Path(credential).read_text(encoding="utf-8-sig").strip() if credential else ""
    except OSError:
        password = ""
    if not password:
        raise NoLogin("its password file is gone")
    os.environ.setdefault("EXASOL_TELEMETRY_DISABLE", "1")
    import pyexasol  # noqa: PLC0415 - only the process that connects needs it
    try:
        connection = pyexasol.connect(dsn=dsn, user=user, password=password, encryption=True,
                                      websocket_sslopt={"cert_reqs": ssl.CERT_NONE}, connection_timeout=10,
                                      socket_timeout=120, compression=False, debug=False)
    except Exception as error:  # noqa: BLE001 - classified below, the password never in the text
        if type(error).__name__ in UNREACHABLE or isinstance(error, OSError):
            raise Unreachable(_reason(error, password)) from None
        raise NoLogin(_reason(error, password)) from None
    return _Pyexasol(connection)


def _not_removed(plan: Plan, why: str) -> list:
    return [("WARN", f"The kit's logins in your database '{plan.database}' were not removed: {why}.")] + \
        later_lines(plan)


def drop_here(plan: Plan, doc: dict, home: Path) -> tuple:
    """drop, in this Python: it has pyexasol (or a test's stand-in)."""
    try:
        db = connect(doc, home)
    except Unreachable:
        lines = [("WARN", f"Your database '{plan.database}' is not running, so the kit's logins in it were not "
                          "removed.")] + later_lines(plan, stopped=True)
        return EXIT_UNREACHABLE, lines + recorded_kept(plan)
    except NoLogin as error:
        lines = _not_removed(plan, f"the kit could not sign in to it ({error})")
        return EXIT_LEFT, lines + recorded_kept(plan)
    except ImportError:
        lines = _not_removed(plan, "the kit's database driver (pyexasol) is missing")
        return EXIT_LEFT, lines + recorded_kept(plan)
    try:
        return apply(plan, db)
    finally:
        close = getattr(db, "close", None)
        if callable(close):
            close()


def _owned_here(plan: Plan, doc: dict, home: Path) -> dict | None:
    """Every schema each login and role of the plan owns now, as the database answers (read only: one SELECT per
    owner, nothing changed); None when it cannot be asked (not running, no sign-in, no driver, any error)."""
    try:
        db = connect(doc, home)
    except Exception:  # noqa: BLE001 - Unreachable, NoLogin, ImportError: the records then
        return None
    try:
        return {name: [schema for schema, _ in _owned_by(db, name)] for name in plan.logins + plan.roles}
    except Exception:  # noqa: BLE001 - not listed: the records then
        return None
    finally:
        close = getattr(db, "close", None)
        if callable(close):
            close()


def plan_mode(plan: Plan, doc: dict, home: Path, argv: list, *, here: bool) -> tuple:
    """The dry run, in this Python when it has pyexasol, else in the kit's own (as drop): every schema a real run
    hands to SYS named as the database has them, or the records' "and any other schema it owns" when it cannot be
    asked. Always exit 0: a dry run changes nothing, whatever it could read."""
    if not plan.drops():
        return EXIT_OK, plan_lines(plan)
    if here or _has_pyexasol():
        return EXIT_OK, plan_lines(plan, _owned_here(plan, doc, home))
    python = str(_get(doc, "components.pyexasol.python") or "")
    if not python or not Path(python).is_file():
        return EXIT_OK, plan_lines(plan)
    try:
        done = subprocess.run([python, str(Path(__file__).resolve()), *argv, "--here"], capture_output=True,
                              text=True, encoding="utf-8", errors="replace", timeout=120, check=False,
                              env=utf8_child(), cwd=str(home))
    except (OSError, subprocess.TimeoutExpired):
        return EXIT_OK, plan_lines(plan)
    if done.stderr.strip():
        print(done.stderr.strip(), file=sys.stderr)
    lines = [tuple(line.split(" ", 1)) for line in done.stdout.splitlines() if " " in line]
    if done.returncode != EXIT_OK or not lines:
        return EXIT_OK, plan_lines(plan)
    return EXIT_OK, lines


def _has_pyexasol() -> bool:
    return importlib.util.find_spec("pyexasol") is not None


def drop(plan: Plan, doc: dict, home: Path, argv: list, *, here: bool) -> tuple:
    if not plan.drops():
        # Nothing of the kit's to drop: nothing to connect for. What stays is still said.
        return EXIT_OK, recorded_kept(plan)
    if here or _has_pyexasol():
        return drop_here(plan, doc, home)
    python = str(_get(doc, "components.pyexasol.python") or "")
    if not python or not Path(python).is_file():
        lines = _not_removed(plan, "the kit's database driver (pyexasol) is missing")
        return EXIT_LEFT, lines + recorded_kept(plan)
    try:
        done = subprocess.run([python, str(Path(__file__).resolve()), *argv, "--here"], capture_output=True,
                              text=True, encoding="utf-8", errors="replace", timeout=300, check=False,
                              env=utf8_child(), cwd=str(home))
    except (OSError, subprocess.TimeoutExpired) as error:
        lines = _not_removed(plan, f"the kit's database driver did not run ({_reason(error)})")
        return EXIT_LEFT, lines + recorded_kept(plan)
    if done.stderr.strip():
        print(done.stderr.strip(), file=sys.stderr)
    lines = [tuple(line.split(" ", 1)) for line in done.stdout.splitlines() if " " in line]
    if done.returncode not in (EXIT_OK, EXIT_LEFT, EXIT_UNREACHABLE) or not lines:
        lines = _not_removed(plan, f"the kit's database driver stopped (exit {done.returncode})")
        return EXIT_LEFT, lines + recorded_kept(plan)
    return done.returncode, lines


def main(argv: list | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    parser = argparse.ArgumentParser(prog="kit_logins.py", description="The kit's logins in a database it keeps.")
    parser.add_argument("mode", choices=("plan", "drop"))
    parser.add_argument("--home", required=True, help="the kit home (EXAKIT_HOME)")
    parser.add_argument("--database", default="", help="the database's name, for the lines it prints")
    parser.add_argument("--here", action="store_true", help=argparse.SUPPRESS)
    try:
        args = parser.parse_args(argv)
    except SystemExit:
        return EXIT_USAGE
    home = Path(args.home).expanduser()
    try:
        doc = Manifest(home / "manifest.json").read()
    except (AddonFailure, OSError, ValueError):
        return EXIT_OK                                   # nothing recorded: nothing of the kit's to drop
    plan = build_plan(doc if isinstance(doc, dict) else {}, home, args.database)
    forwarded = [arg for arg in argv if arg != "--here"]
    if args.mode == "plan":
        try:
            code, lines = plan_mode(plan, doc, home, forwarded, here=args.here)
        except Exception:  # noqa: BLE001 - whatever stopped the reading, the records still say what it does
            code, lines = EXIT_OK, plan_lines(plan)
    else:
        try:
            code, lines = drop(plan, doc, home, forwarded, here=args.here)
        except Exception as error:  # noqa: BLE001 - whatever stopped it, the user still gets the statements
            code, lines = EXIT_LEFT, _not_removed(plan, f"the kit stopped ({_reason(error)})")
    for kind, text in lines:
        print(f"{kind} {text}")
    return code


if __name__ == "__main__":
    sys.exit(main())
