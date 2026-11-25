"""(run: python3 -m unittest discover -s tests -p 'test_marketplace_kit_logins.py' -v) SEC-01: at uninstall, a
database the user let the kit use keeps everything of theirs, and loses only what the kit made inside it. The kit's
own logins go (their sessions ended first: Exasol keeps a dropped user's sessions until they are killed), the roles
the kit created go unless one of the user's own users or roles holds them, a schema such a login or role owns goes to
SYS first and stays, nothing is ever dropped with CASCADE, the connections stay and are listed with the statement
that drops them, and a database that is not running is never started: the statements are printed for later, in the
same order. No password is ever printed. Every database here is a stand-in."""

from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))

import kit_logins  # noqa: E402

FAKE_DB = ROOT / "tests" / "lib" / "fake-kit-logins-db.py"
SECRET = "Sup3rS3cretAdminPassw0rd"


class FakeDb:
    """apply()'s two calls, answered from a dict; every statement recorded. As Exasol, it refuses a DROP USER or DROP
    ROLE without CASCADE while that user or role still owns a schema (``owners``: schema -> owner)."""

    def __init__(self, users=(), sessions=None, roles=None, connections=(), schemas=(), slot="", refuse=None,
                 owners=None):
        self.users = set(users)
        self.sessions = dict(sessions or {})
        self.roles = {name: list(grantees) for name, grantees in (roles or {}).items()}
        self.connections = list(connections)
        self.schemas = set(schemas)
        self.slot = slot
        self.refuse = dict(refuse or {})
        self.owners = dict(owners or {})
        self.statements: list[str] = []

    def _check(self, sql):
        self.statements.append(sql)
        for start, why in self.refuse.items():
            if sql.startswith(start):
                raise RuntimeError(why)

    def query(self, sql):
        self._check(sql)
        names = [part.split("'")[0] for part in sql.split("'")[1::2]]
        if "EXA_DBA_USERS" in sql:
            return [(name,) for name in names if name in self.users]
        if "EXA_DBA_SESSIONS" in sql:
            return [(sid,) for sid in self.sessions.get(names[0], [])]
        if "EXA_DBA_ROLES" in sql:
            return [(name,) for name in names if name in self.roles]
        if "EXA_DBA_ROLE_PRIVS" in sql:
            return [(grantee,) for grantee in self.roles.get(names[0], [])]
        if "EXA_DBA_CONNECTIONS" in sql:
            return [(name,) for name in self.connections]
        if "EXA_SCHEMAS" in sql and "SCHEMA_OWNER =" in sql:
            return [(schema, False) for schema, owner in sorted(self.owners.items()) if owner == names[0]]
        if "EXA_SCHEMAS" in sql:
            return [(name,) for name in names if name in self.schemas or name in self.owners]
        if "EXA_PARAMETERS" in sql:
            return [(self.slot,)]
        return []

    def execute(self, sql):
        self._check(sql)
        if sql.startswith(("ALTER SCHEMA \"", "ALTER VIRTUAL SCHEMA \"")):
            self.owners[sql.split('"')[1]] = sql.rsplit(" ", 1)[1]
        if sql.startswith(('DROP USER "', 'DROP ROLE "')) and not sql.endswith("CASCADE") and \
                sql.split('"')[1] in self.owners.values():
            kind, name = sql.split()[1].lower(), sql.split('"')[1]
            raise RuntimeError(f"CASCADE must be specified to drop {kind} {name}")
        if sql.startswith('DROP USER "'):
            name = sql.split('"')[1]
            self.users.discard(name)
            for grantees in self.roles.values():
                if name in grantees:
                    grantees.remove(name)
        if sql.startswith('DROP ROLE "'):
            self.roles.pop(sql.split('"')[1], None)


def manifest(**overrides) -> dict:
    doc = {"runtime": {"type": "personal", "user": "sys", "dsn": "127.0.0.1:8563", "ownership": "user"},
           "components": {"mcp_server": {"connection": {"user": "mcp_readonly"}},
                          "exasol_scheduler": {"ownership": "kit", "db_user": "scheduler_svc"},
                          "semantic_views": {"ownership": "kit", "role_created": True},
                          "preprocessor": {"origin": "kit", "state": "active"}}}
    for dotted, value in overrides.items():
        node = doc
        parts = dotted.split("__")
        for key in parts[:-1]:
            node = node.setdefault(key, {})
        if value is None:
            node.pop(parts[-1], None)
        else:
            node[parts[-1]] = value
    return doc


class KitLoginsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name) / "kit-home"
        (self.home / "credentials").mkdir(parents=True)
        self.password_file = self.home / "credentials" / "runtime_sys_password"
        self.password_file.write_text(SECRET + "\n", encoding="utf-8")
        source = self.home / "sources" / "sales"
        source.mkdir(parents=True)
        (source / "config.json").write_text(json.dumps({"objects": {"connection": "EXAKIT_SRC_SALES",
                                                                    "schema": "VS_SALES"}}), encoding="utf-8")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def write(self, doc: dict) -> None:
        doc.setdefault("runtime", {})["password_file"] = str(self.password_file)
        (self.home / "manifest.json").write_text(json.dumps(doc), encoding="utf-8")

    def run_main(self, *args: str, env: dict | None = None) -> tuple[int, str]:
        out = io.StringIO()
        with mock.patch.dict(os.environ, env or {}), redirect_stdout(out):
            code = kit_logins.main([*args, "--home", str(self.home), "--database", "starter-kit-local"])
        return code, out.getvalue()

    # --- the plan: only what the kit's own records say it made -----------------------------------------------------
    def test_plan_names_the_kit_logins_and_roles_from_its_records(self):
        plan = kit_logins.build_plan(manifest(), self.home, "starter-kit-local")
        self.assertEqual(["MCP_READONLY", "SCHEDULER_SVC"], plan.logins)
        self.assertEqual(["SEMANTIC_USER", "PREPROC_ADMIN"], plan.roles)
        self.assertEqual(["EXAKIT_SRC_SALES"], plan.connections)
        self.assertEqual(["VS_SALES"], plan.virtual_schemas)
        self.assertTrue(plan.preprocessor)

    def test_plan_never_names_the_administrator_or_what_the_kit_did_not_make(self):
        doc = manifest(components__mcp_server__connection__user="SYS",
                       components__exasol_scheduler__ownership="user",
                       components__semantic_views__role_created=False,
                       components__preprocessor__origin="pre-existing")
        plan = kit_logins.build_plan(doc, self.home, "starter-kit-local")
        self.assertEqual([], plan.logins)
        self.assertEqual([], plan.roles)
        doc = manifest(runtime__user="dba_admin", components__mcp_server__connection__user="dba_admin")
        self.assertNotIn("DBA_ADMIN", kit_logins.build_plan(doc, self.home, "x").logins)

    def test_what_was_made_in_another_database_is_not_the_kits_here(self):
        blocks = ("components__mcp_server__connection__made_in", "components__exasol_scheduler__made_in",
                  "components__semantic_views__made_in", "components__preprocessor__made_in")
        other = dict.fromkeys(blocks, "exa-old")
        for now in ({"runtime__deployment_id": "exa-new"}, {"runtime__deployment_id": None}):
            plan = kit_logins.build_plan(manifest(**other, **now), self.home, "x")
            self.assertEqual(([], []), (plan.logins, plan.roles))
            self.assertEqual(["MCP_READONLY", "SCHEDULER_SVC"], plan.kept_logins)
        here = kit_logins.build_plan(manifest(**dict.fromkeys(blocks, "exa-new"), runtime__deployment_id="exa-new"),
                                     self.home, "x")
        self.assertEqual((["MCP_READONLY", "SCHEDULER_SVC"], ["SEMANTIC_USER", "PREPROC_ADMIN"]),
                         (here.logins, here.roles))

    def test_an_id_that_became_a_number_is_none_and_not_another_one(self):
        blocks = ("components__mcp_server__connection__made_in", "components__exasol_scheduler__made_in",
                  "components__semantic_views__made_in", "components__preprocessor__made_in")
        # The number it became, over the same id read again: made here. Another id, or none: not here.
        same = kit_logins.build_plan(manifest(**dict.fromkeys(blocks, float("inf")), runtime__deployment_id="3e082473"),
                                     self.home, "x")
        self.assertEqual(["MCP_READONLY", "SCHEDULER_SVC"], same.logins)
        for now in ("exa-new", "1e000003", None, float("inf")):
            plan = kit_logins.build_plan(manifest(**dict.fromkeys(blocks, float("inf")), runtime__deployment_id=now),
                                         self.home, "x")
            self.assertEqual(([], []), (plan.logins, plan.roles), now)
        # Infinity on record is never "inf": nothing with an id on record was made in it.
        plan = kit_logins.build_plan(manifest(**dict.fromkeys(blocks, "inf"), runtime__deployment_id=float("inf")),
                                     self.home, "x")
        self.assertEqual([], plan.logins)

    def test_an_interrupted_framework_install_is_the_kits_own(self):
        doc = manifest(components__preprocessor={"state": "installing"})
        self.assertIn("PREPROC_ADMIN", kit_logins.build_plan(doc, self.home, "x").roles)

    def test_a_framework_role_the_kit_put_back_is_the_kits_own(self):
        # After an uninstall that kept the database, the next install finds the framework (pre-existing), puts its role
        # back and says so (setup/preprocessor/manage.py): the next uninstall drops it again.
        block = {"state": "active", "origin": "pre-existing", "role_created": True, "made_in": "exa-mine"}
        plan = kit_logins.build_plan(manifest(components__preprocessor=block, runtime__deployment_id="exa-mine"),
                                     self.home, "x")
        self.assertIn("PREPROC_ADMIN", plan.roles)
        self.assertEqual(["PREPROC", "PREPROC_RT"], plan.owned["PREPROC_ADMIN"])
        # Not in another database, and not a framework whose role the kit never made.
        for other in (dict(block, made_in="exa-old"), dict(block, role_created=False)):
            plan = kit_logins.build_plan(manifest(components__preprocessor=other, runtime__deployment_id="exa-mine"),
                                         self.home, "x")
            self.assertNotIn("PREPROC_ADMIN", plan.roles)

    def test_a_name_that_is_not_an_identifier_is_never_used(self):
        doc = manifest(components__mcp_server__connection__user="x'; DROP SCHEMA SALES CASCADE; --")
        self.assertEqual(["SCHEDULER_SVC"], kit_logins.build_plan(doc, self.home, "x").logins)

    def test_the_schemas_a_login_or_role_owns_come_from_the_records(self):
        plan = kit_logins.build_plan(manifest(), self.home, "starter-kit-local")
        self.assertEqual({"SCHEDULER_SVC": ["SCHED"], "PREPROC_ADMIN": ["PREPROC", "PREPROC_RT"]}, plan.owned)
        plan = kit_logins.build_plan(manifest(components__exasol_scheduler__schema="tasks"), self.home, "x")
        self.assertEqual(["TASKS"], plan.owned["SCHEDULER_SVC"])

    def test_plan_mode_that_cannot_ask_the_database_names_any_other_schema_too(self):
        # A dry run of a database that does not answer: the records' schemas, and any other one the login or role
        # owns, which a real run hands to SYS too. Its order is a real run's.
        self.write(manifest())
        with mock.patch.object(kit_logins, "connect", side_effect=kit_logins.Unreachable("refused")), \
                mock.patch.object(kit_logins, "_has_pyexasol", return_value=True):
            code, out = self.run_main("plan")
        self.assertEqual(0, code)
        self.assertEqual([
            "PLAN the kit's login MCP_READONLY in your database 'starter-kit-local'. Any schema it owns stays and goes "
            "to SYS first (ALTER SCHEMA ... CHANGE OWNER SYS for each, then DROP USER)",
            "PLAN the kit's login SCHEDULER_SVC in your database 'starter-kit-local'. Its schema SCHED and any other "
            "schema it owns stay and go to SYS first (ALTER SCHEMA ... CHANGE OWNER SYS for each, then DROP USER)",
            "PLAN the role SEMANTIC_USER in your database 'starter-kit-local', unless one of your own users holds it. "
            "Any schema it owns stays and goes to SYS first (ALTER SCHEMA ... CHANGE OWNER SYS for each, then DROP "
            "ROLE)",
            "PLAN the role PREPROC_ADMIN in your database 'starter-kit-local', unless one of your own users holds it. "
            "Its schemas PREPROC and PREPROC_RT and any other schema it owns stay and go to SYS first (ALTER SCHEMA "
            "... CHANGE OWNER SYS for each, then DROP ROLE)",
            "INFO The connection EXAKIT_SRC_SALES stays in your database. To remove it: DROP CONNECTION "
            "EXAKIT_SRC_SALES;",
            "INFO The virtual schema VS_SALES stays in your database.",
            "INFO The Semantic Views schemas and their models stay in your database.",
            "INFO The SQL preprocessor PREPROC_RT.MASTER stays in your database."], out.splitlines())
        self.assertNotIn("CASCADE", out)

    def test_plan_mode_names_every_schema_the_real_run_hands_to_sys_and_changes_nothing(self):
        # The Scheduler's login owns a schema of the user's too: the real run hands every schema its owner has to
        # SYS, so the dry run, asking the database (read only), names the same set.
        self.write(manifest())
        state = {"users": ["MCP_READONLY", "SCHEDULER_SVC"], "roles": {"SEMANTIC_USER": [], "PREPROC_ADMIN": []},
                 "owners": {"SCHED": "SCHEDULER_SVC", "SALES_MART": "SCHEDULER_SVC", "PREPROC": "PREPROC_ADMIN",
                            "PREPROC_RT": "PREPROC_ADMIN", "THEIRS": "THEIR_ANALYST"}}
        env = self.fake_env(state)
        with mock.patch.object(kit_logins, "_has_pyexasol", return_value=True):
            code, out = self.run_main("plan", env=env)
        self.assertEqual(0, code, out)
        lines = out.splitlines()
        self.assertEqual([
            "PLAN the kit's login MCP_READONLY in your database 'starter-kit-local' (DROP USER)",
            "PLAN the kit's login SCHEDULER_SVC in your database 'starter-kit-local'. Its schemas SALES_MART and SCHED "
            "stay and go to SYS first (ALTER SCHEMA ... CHANGE OWNER SYS for each, then DROP USER)",
            "PLAN the role SEMANTIC_USER in your database 'starter-kit-local', unless one of your own users holds it "
            "(DROP ROLE)",
            "PLAN the role PREPROC_ADMIN in your database 'starter-kit-local', unless one of your own users holds it. "
            "Its schemas PREPROC and PREPROC_RT stay and go to SYS first (ALTER SCHEMA ... CHANGE OWNER SYS for each, "
            "then DROP ROLE)"], lines[:4])
        self.assertTrue(self.statements())
        self.assertFalse([sql for sql in self.statements() if not sql.startswith("SELECT ")], self.statements())
        # ...the set the real run then hands over, no more.
        with mock.patch.object(kit_logins, "_has_pyexasol", return_value=True):
            code, out = self.run_main("drop", env=env)
        self.assertEqual(0, code, out)
        moved = sorted(sql.split('"')[1] for sql in self.statements() if sql.startswith("ALTER SCHEMA"))
        self.assertEqual(["PREPROC", "PREPROC_RT", "SALES_MART", "SCHED"], moved)
        self.assertIn("INFO The schemas SALES_MART and SCHED stay in your database, now owned by SYS.", out)

    def test_plan_mode_without_pyexasol_here_asks_through_the_kits_own_python(self):
        self.write(manifest(components__pyexasol={"python": sys.executable}))
        env = self.fake_env({"users": ["SCHEDULER_SVC"], "owners": {"SCHED": "SCHEDULER_SVC",
                                                                     "SALES_MART": "SCHEDULER_SVC"}})
        with mock.patch.object(kit_logins, "_has_pyexasol", return_value=False):
            code, out = self.run_main("plan", env=env)
        self.assertEqual(0, code, out)
        self.assertIn("Its schemas SALES_MART and SCHED stay and go to SYS first", out)
        self.assertNotIn("any other schema", out)

    def test_plan_mode_with_no_driver_at_all_names_any_other_schema(self):
        self.write(manifest(components__pyexasol=None))
        with mock.patch.object(kit_logins, "_has_pyexasol", return_value=False):
            code, out = self.run_main("plan")
        self.assertEqual(0, code)
        self.assertIn("Its schema SCHED and any other schema it owns stay and go to SYS first", out)

    # --- a login the kit did not create is never dropped -------------------------------------------------------------
    def test_only_a_login_the_kit_created_is_dropped(self):
        cases = [
            # (mcp user, its created flag, scheduler user, its created flag) -> (dropped, kept)
            (("mcp_readonly", True, "scheduler_svc", True), (["MCP_READONLY", "SCHEDULER_SVC"], [])),
            # 0.3.0: no flag; the kit's own names are the kit's.
            (("mcp_readonly", None, "scheduler_svc", None), (["MCP_READONLY", "SCHEDULER_SVC"], [])),
            # A name from EXAKIT_MCP_READONLY_USER / EXAKIT_EXASOL_SCHEDULER_USER: never, flag or not.
            (("bi_reader", None, "etl_user", None), ([], ["BI_READER", "ETL_USER"])),
            (("bi_reader", True, "etl_user", True), ([], ["BI_READER", "ETL_USER"])),
            # The kit's own name, taken over (it was there: ALTER USER, not CREATE USER).
            (("mcp_readonly", False, "scheduler_svc", False), ([], ["MCP_READONLY", "SCHEDULER_SVC"])),
            (("mcp_readonly", "false", "scheduler_svc", "true"), (["SCHEDULER_SVC"], ["MCP_READONLY"])),
        ]
        for (mcp_user, mcp_created, sched_user, sched_created), (dropped, kept) in cases:
            doc = manifest(components__mcp_server__connection__user=mcp_user,
                           components__mcp_server__connection__created=mcp_created,
                           components__exasol_scheduler__db_user=sched_user,
                           components__exasol_scheduler__db_user_created=sched_created)
            plan = kit_logins.build_plan(doc, self.home, "x")
            self.assertEqual((dropped, kept), (plan.logins, plan.kept_logins), (mcp_user, mcp_created, sched_user))

    def test_a_login_the_kit_did_not_create_is_left_as_it_is_and_its_drop_is_printed(self):
        doc = manifest(components__mcp_server__connection__user="bi_reader",
                       components__mcp_server__connection__created=False)
        plan = kit_logins.build_plan(doc, self.home, "starter-kit-local")
        lines = kit_logins.plan_lines(plan)
        self.assertFalse([text for kind, text in lines if kind == "PLAN" and "BI_READER" in text])
        self.assertIn(("INFO", "The login BI_READER stays in your database: the kit did not create it. To remove it: "
                               "DROP USER BI_READER;"), lines)
        db = FakeDb(users={"BI_READER", "SCHEDULER_SVC"}, sessions={"BI_READER": ["31"]},
                    roles={"SEMANTIC_USER": ["BI_READER"], "PREPROC_ADMIN": []},
                    owners={"BI_MART": "BI_READER", "SCHED": "SCHEDULER_SVC"})
        code, lines = kit_logins.apply(plan, db)
        self.assertEqual(0, code, lines)
        touched = [sql for sql in db.statements if "BI_READER" in sql and not sql.startswith("SELECT")]
        self.assertEqual([], touched)
        self.assertNotIn("KILL SESSION 31", db.statements)
        self.assertEqual("BI_READER", db.owners["BI_MART"])
        self.assertIn('DROP USER "SCHEDULER_SVC"', db.statements)
        self.assertIn(("INFO", "The login BI_READER stays in your database: the kit did not create it. To remove it: "
                               "DROP USER BI_READER;"), lines)
        # It holds the kit's role, so the role stays: nothing it holds is taken from it.
        self.assertIn(("INFO", "The role SEMANTIC_USER stays in your database: BI_READER holds it."), lines)
        # Gone from the database already: no line about it.
        _, lines = kit_logins.apply(plan, FakeDb(users={"SCHEDULER_SVC"}))
        self.assertFalse([text for _, text in lines if "BI_READER" in text])

    def test_semantic_views_that_stays_is_said(self):
        doc = manifest(components__semantic_views={"ownership": "user"})
        self.assertIn(("INFO", "The Semantic Views schemas and their models stay in your database."),
                      kit_logins.plan_lines(kit_logins.build_plan(doc, self.home, "x")))
        db = FakeDb(users={"MCP_READONLY"}, schemas={"SEMANTIC_CATALOG", "SYS_SEMANTIC"})
        _, lines = kit_logins.apply(self.plan(), db)
        self.assertIn(("INFO", "The Semantic Views schemas and their models stay in your database."), lines)
        _, lines = kit_logins.apply(self.plan(), FakeDb(users={"MCP_READONLY"}))
        self.assertNotIn(("INFO", "The Semantic Views schemas and their models stay in your database."), lines)

    def test_no_manifest_is_nothing_to_do(self):
        code, out = self.run_main("drop")
        self.assertEqual((0, ""), (code, out))

    # --- apply: the drops -------------------------------------------------------------------------------------------
    def plan(self, **overrides):
        return kit_logins.build_plan(manifest(**overrides), self.home, "starter-kit-local")

    def test_a_login_is_dropped_after_its_sessions_end_and_never_with_cascade(self):
        db = FakeDb(users={"MCP_READONLY", "SCHEDULER_SVC"}, sessions={"MCP_READONLY": ["11", "12"]},
                    roles={"SEMANTIC_USER": ["MCP_READONLY"], "PREPROC_ADMIN": []},
                    connections=["EXAKIT_SRC_SALES", "THEIR_OWN_CONNECTION"], schemas={"VS_SALES"},
                    slot='"PREPROC_RT"."MASTER"')
        code, lines = kit_logins.apply(self.plan(), db)
        self.assertEqual(0, code)
        statements = db.statements
        self.assertEqual(kit_logins.BYPASS, statements[0])
        revoke = statements.index('REVOKE CREATE SESSION FROM "MCP_READONLY"')
        kill = statements.index("KILL SESSION 11")
        drop = statements.index('DROP USER "MCP_READONLY"')
        self.assertLess(revoke, kill)
        self.assertLess(statements.index("KILL SESSION 12"), drop)
        self.assertIn('DROP USER "SCHEDULER_SVC"', statements)
        self.assertIn('DROP ROLE "SEMANTIC_USER"', statements)
        self.assertIn('DROP ROLE "PREPROC_ADMIN"', statements)
        self.assertFalse([sql for sql in statements if "CASCADE" in sql.upper()], statements)
        self.assertFalse([sql for sql in statements if "CONNECTION" in sql and sql.startswith("DROP")])
        self.assertFalse([sql for sql in statements if "SCHEMA" in sql and sql.startswith("DROP")])
        self.assertEqual(("OK", "Removed the kit's logins MCP_READONLY and SCHEDULER_SVC from your database "
                                "'starter-kit-local'"), lines[0])
        self.assertIn(("OK", "Removed the role SEMANTIC_USER from your database 'starter-kit-local'"), lines)
        self.assertIn(("INFO", "The connection EXAKIT_SRC_SALES stays in your database. To remove it: "
                               "DROP CONNECTION EXAKIT_SRC_SALES;"), lines)
        self.assertFalse([text for _, text in lines if "THEIR_OWN_CONNECTION" in text])
        self.assertIn(("INFO", "The SQL preprocessor PREPROC_RT.MASTER stays in your database."), lines)

    def test_a_role_one_of_their_own_users_holds_stays(self):
        db = FakeDb(users={"MCP_READONLY"}, roles={"SEMANTIC_USER": ["MCP_READONLY", "ANALYST", "SYS"],
                                                   "PREPROC_ADMIN": ["SYS"]})
        code, lines = kit_logins.apply(self.plan(), db)
        self.assertEqual(0, code)
        self.assertNotIn('DROP ROLE "SEMANTIC_USER"', db.statements)
        self.assertIn(("INFO", "The role SEMANTIC_USER stays in your database: ANALYST holds it."), lines)
        # SYS holding a role is the administrator, not one of their users: the kit's role still goes.
        self.assertIn('DROP ROLE "PREPROC_ADMIN"', db.statements)

    def test_a_login_or_role_that_is_not_there_is_left_alone(self):
        db = FakeDb(users=set(), roles={})
        code, lines = kit_logins.apply(self.plan(), db)
        self.assertEqual(0, code)
        self.assertFalse([sql for sql in db.statements if sql.startswith(("DROP", "REVOKE", "KILL"))])
        self.assertFalse([kind for kind, _ in lines if kind in ("OK", "WARN")])

    def test_a_drop_the_database_refuses_is_said_with_the_statement_that_finishes_it(self):
        db = FakeDb(users={"MCP_READONLY", "SCHEDULER_SVC"}, roles={"PREPROC_ADMIN": []},
                    refuse={'DROP USER "SCHEDULER_SVC"': "insufficient privileges for dropping user",
                            'DROP ROLE "PREPROC_ADMIN"': "insufficient privileges for dropping role"})
        code, lines = kit_logins.apply(self.plan(), db)
        self.assertEqual(1, code)
        self.assertIn(("WARN", "The kit's login SCHEDULER_SVC was not removed from your database 'starter-kit-local':"
                               " insufficient privileges for dropping user."), lines)
        self.assertIn(("OK", "Removed the kit's login MCP_READONLY from your database 'starter-kit-local'"), lines)
        self.assertIn(("INFO", "To finish, run this in your database as sys:"), lines)
        self.assertIn(("INFO", "  DROP USER SCHEDULER_SVC;"), lines)
        self.assertIn(("INFO", "  DROP ROLE PREPROC_ADMIN;"), lines)

    # --- the schemas a dropped login or role owns: handed to SYS first, never CASCADE (the live PREPROC_ADMIN case) --
    def test_owned_schemas_go_to_sys_before_their_owner_is_dropped_never_with_cascade(self):
        db = FakeDb(users={"MCP_READONLY", "SCHEDULER_SVC"}, roles={"PREPROC_ADMIN": ["SYS"]},
                    owners={"PREPROC": "PREPROC_ADMIN", "PREPROC_RT": "PREPROC_ADMIN", "SCHED": "SCHEDULER_SVC",
                            "THEIRS": "THEIR_ANALYST"})
        code, lines = kit_logins.apply(self.plan(), db)
        self.assertEqual(0, code, lines)
        statements = db.statements
        self.assertLess(statements.index('ALTER SCHEMA "SCHED" CHANGE OWNER SYS'),
                        statements.index('DROP USER "SCHEDULER_SVC"'))
        for schema in ("PREPROC", "PREPROC_RT"):
            self.assertLess(statements.index(f'ALTER SCHEMA "{schema}" CHANGE OWNER SYS'),
                            statements.index('DROP ROLE "PREPROC_ADMIN"'))
        self.assertFalse([sql for sql in statements if "CASCADE" in sql.upper()], statements)
        self.assertFalse([sql for sql in statements if sql.startswith("DROP SCHEMA")])
        self.assertEqual({"PREPROC": "SYS", "PREPROC_RT": "SYS", "SCHED": "SYS", "THEIRS": "THEIR_ANALYST"},
                         db.owners)
        self.assertEqual([
            ("OK", "Removed the kit's logins MCP_READONLY and SCHEDULER_SVC from your database 'starter-kit-local'"),
            ("INFO", "The schema SCHED stays in your database, now owned by SYS.")], lines[:2])
        role = lines.index(("OK", "Removed the role PREPROC_ADMIN from your database 'starter-kit-local'"))
        self.assertEqual(("INFO", "The schemas PREPROC and PREPROC_RT stay in your database, now owned by SYS."),
                         lines[role + 1])

    def test_without_the_handover_the_drop_is_what_exasol_refuses(self):
        # The stand-in refuses as Exasol did on the live machine: the order above is what makes the drop pass.
        db = FakeDb(roles={"PREPROC_ADMIN": []}, owners={"PREPROC": "PREPROC_ADMIN"})
        with self.assertRaisesRegex(RuntimeError, "CASCADE must be specified to drop role PREPROC_ADMIN"):
            db.execute('DROP ROLE "PREPROC_ADMIN"')

    def test_a_schema_that_cannot_be_handed_over_keeps_its_owner_and_the_rest_is_printed(self):
        db = FakeDb(users={"MCP_READONLY"}, roles={"PREPROC_ADMIN": []},
                    owners={"PREPROC": "PREPROC_ADMIN", "PREPROC_RT": "PREPROC_ADMIN"},
                    refuse={'ALTER SCHEMA "PREPROC_RT"': "insufficient privileges"})
        code, lines = kit_logins.apply(self.plan(), db)
        self.assertEqual(1, code)
        self.assertNotIn('DROP ROLE "PREPROC_ADMIN"', db.statements)
        self.assertIn(("WARN", "The schema PREPROC_RT could not be handed to SYS, so the role PREPROC_ADMIN was not "
                               "removed from your database 'starter-kit-local': insufficient privileges."), lines)
        self.assertIn(("INFO", "The schema PREPROC stays in your database, now owned by SYS."), lines)
        finish = lines.index(("INFO", "To finish, run this in your database as sys:"))
        self.assertEqual([("INFO", "  ALTER SCHEMA PREPROC_RT CHANGE OWNER SYS;"), ("INFO", "  DROP ROLE PREPROC_ADMIN;")],
                         lines[finish + 1:])

    # --- drop: the connection ---------------------------------------------------------------------------------------
    def fake_env(self, state: dict) -> dict:
        state_file = Path(self.temp.name) / "db-state.json"
        state_file.write_text(json.dumps(state), encoding="utf-8")
        self.db_log = Path(self.temp.name) / "db.log"
        return {kit_logins.FAKE_DB: str(FAKE_DB), "EXAKIT_FAKE_DB_STATE": str(state_file),
                "EXAKIT_FAKE_DB_LOG": str(self.db_log)}

    def statements(self) -> list[str]:
        return self.db_log.read_text(encoding="utf-8").splitlines() if self.db_log.exists() else []

    def test_a_stopped_database_is_never_started_and_the_statements_are_printed_for_later(self):
        self.write(manifest())
        with mock.patch.object(kit_logins, "_has_pyexasol", return_value=True):
            code, out = self.run_main("drop", env=self.fake_env({"down": True}))
        self.assertEqual(3, code)
        self.assertEqual([], self.statements())
        self.assertIn("WARN Your database 'starter-kit-local' is not running, so the kit's logins in it were not "
                      "removed.", out)
        # The same statements, in the order a real run takes: a schema goes to SYS before its owner is dropped.
        start = out.index("INFO Remove them once it runs, as sys:\n")
        self.assertEqual([
            "INFO Remove them once it runs, as sys:",
            "INFO   -- any schema MCP_READONLY owns: ALTER SCHEMA <name> CHANGE OWNER SYS;",
            "INFO   DROP USER IF EXISTS MCP_READONLY;",
            "INFO   ALTER SCHEMA SCHED CHANGE OWNER SYS;  -- if SCHEDULER_SVC owns it",
            "INFO   -- any other schema SCHEDULER_SVC owns: ALTER SCHEMA <name> CHANGE OWNER SYS;",
            "INFO   DROP USER IF EXISTS SCHEDULER_SVC;",
            "INFO   -- only if none of your own users needs the role SEMANTIC_USER:",
            "INFO   -- any schema SEMANTIC_USER owns: ALTER SCHEMA <name> CHANGE OWNER SYS;",
            "INFO   DROP ROLE IF EXISTS SEMANTIC_USER;",
            "INFO   -- only if none of your own users needs the role PREPROC_ADMIN:",
            "INFO   ALTER SCHEMA PREPROC CHANGE OWNER SYS;",
            "INFO   ALTER SCHEMA PREPROC_RT CHANGE OWNER SYS;",
            "INFO   -- any other schema PREPROC_ADMIN owns: ALTER SCHEMA <name> CHANGE OWNER SYS;",
            "INFO   DROP ROLE IF EXISTS PREPROC_ADMIN;"], out[start:].splitlines()[:14])
        self.assertIn("DROP CONNECTION EXAKIT_SRC_SALES;", out)
        self.assertNotIn("CASCADE", out)

    def test_drop_through_the_fake_database_end_to_end(self):
        self.write(manifest())
        env = self.fake_env({"users": ["MCP_READONLY"], "sessions": {"MCP_READONLY": [7]},
                             "roles": {"SEMANTIC_USER": ["MCP_READONLY"], "PREPROC_ADMIN": []},
                             "owners": {"PREPROC": "PREPROC_ADMIN", "PREPROC_RT": "PREPROC_ADMIN"},
                             "connections": ["EXAKIT_SRC_SALES"]})
        with mock.patch.object(kit_logins, "_has_pyexasol", return_value=True):
            code, out = self.run_main("drop", env=env)
        self.assertEqual(0, code, out)
        self.assertIn('DROP USER "MCP_READONLY"', self.statements())
        self.assertIn("KILL SESSION 7", self.statements())
        self.assertLess(self.statements().index('ALTER SCHEMA "PREPROC_RT" CHANGE OWNER SYS'),
                        self.statements().index('DROP ROLE "PREPROC_ADMIN"'))
        self.assertIn("OK Removed the role PREPROC_ADMIN from your database 'starter-kit-local'", out)
        self.assertIn("INFO The schemas PREPROC and PREPROC_RT stay in your database, now owned by SYS.", out)
        self.assertIn("OK Removed the kit's login MCP_READONLY from your database 'starter-kit-local'", out)
        self.assertIn("OK Removed the role SEMANTIC_USER from your database 'starter-kit-local'", out)

    def test_nothing_of_the_kits_to_drop_is_never_a_connection(self):
        self.write(manifest(components__mcp_server=None, components__exasol_scheduler=None,
                            components__semantic_views=None, components__preprocessor=None))
        with mock.patch.object(kit_logins, "connect", side_effect=AssertionError("connected for nothing")):
            code, out = self.run_main("drop")
        self.assertEqual(0, code)
        self.assertIn("INFO The connection EXAKIT_SRC_SALES stays in your database.", out)

    def test_without_pyexasol_here_the_kits_own_python_runs_it(self):
        # The kit's pyexasol Python is this one (the stand-in database needs no driver): started again with --here.
        self.write(manifest(components__pyexasol={"python": sys.executable}))
        env = self.fake_env({"users": ["MCP_READONLY", "SCHEDULER_SVC"], "roles": {}})
        with mock.patch.object(kit_logins, "_has_pyexasol", return_value=False):
            code, out = self.run_main("drop", env=env)
        self.assertEqual(0, code, out)
        self.assertIn('DROP USER "SCHEDULER_SVC"', self.statements())
        self.assertIn("OK Removed the kit's logins MCP_READONLY and SCHEDULER_SVC", out)

    def test_without_any_driver_the_statements_are_printed(self):
        self.write(manifest(components__pyexasol=None))
        with mock.patch.object(kit_logins, "_has_pyexasol", return_value=False):
            code, out = self.run_main("drop")
        self.assertEqual(1, code)
        self.assertIn("WARN The kit's logins in your database 'starter-kit-local' were not removed: the kit's database "
                      "driver (pyexasol) is missing.", out)
        self.assertIn("INFO Remove them by hand, as sys:", out)
        self.assertIn("INFO   DROP USER IF EXISTS MCP_READONLY;", out)

    def test_a_refused_sign_in_never_prints_the_password(self):
        self.write(manifest())

        class Refused(Exception):
            pass

        def refuse(**kwargs):
            raise Refused(f"[ExaAuthError] login refused for {kwargs['user']} with password {kwargs['password']}")

        fake = mock.Mock(connect=refuse)
        with mock.patch.dict(sys.modules, {"pyexasol": fake}), \
                mock.patch.object(kit_logins, "_has_pyexasol", return_value=True):
            code, out = self.run_main("drop")
        self.assertEqual(1, code)
        self.assertNotIn(SECRET, out)
        self.assertIn("the kit could not sign in to it ([ExaAuthError] login refused for sys with password ***)", out)

    def test_a_driver_that_finds_nothing_listening_reads_as_not_running(self):
        self.write(manifest())

        class ExaConnectionFailedError(Exception):
            pass

        def refuse(**kwargs):
            raise ExaConnectionFailedError("Could not connect to Exasol: Connection refused")

        captured = {}

        def connect(**kwargs):
            captured.update(kwargs)
            refuse(**kwargs)

        fake = mock.Mock(connect=connect)
        with mock.patch.dict(sys.modules, {"pyexasol": fake}), \
                mock.patch.object(kit_logins, "_has_pyexasol", return_value=True):
            code, out = self.run_main("drop")
        self.assertEqual(3, code)
        self.assertIn("is not running", out)
        # The kit's connection: its administrator, the password from its credential file, TLS on.
        self.assertEqual(("sys", SECRET, True), (captured["user"], captured["password"], captured["encryption"]))

    def test_a_credential_file_with_a_byte_order_mark_still_signs_in(self):
        self.write(manifest())
        self.password_file.write_text("\ufeff" + SECRET + "\r\n", encoding="utf-8")
        captured = {}

        def connect(**kwargs):
            captured.update(kwargs)
            raise OSError("refused")

        with mock.patch.dict(sys.modules, {"pyexasol": mock.Mock(connect=connect)}), \
                mock.patch.object(kit_logins, "_has_pyexasol", return_value=True):
            self.run_main("drop")
        self.assertEqual(SECRET, captured["password"])

    def test_the_pin_the_kit_recorded_is_on_the_dsn(self):
        pin = "ab" * 32
        self.write(manifest(runtime__tls_fingerprint=pin))
        captured = {}

        def connect(**kwargs):
            captured.update(kwargs)
            raise OSError("refused")

        with mock.patch.dict(sys.modules, {"pyexasol": mock.Mock(connect=connect)}), \
                mock.patch.object(kit_logins, "_has_pyexasol", return_value=True):
            code, _ = self.run_main("drop")
        self.assertEqual(3, code)
        self.assertEqual(f"127.0.0.1/{pin}:8563", captured["dsn"])


if __name__ == "__main__":
    unittest.main()
