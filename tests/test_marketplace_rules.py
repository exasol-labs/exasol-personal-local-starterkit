"""The marketplace's and personas' rules, each in one place and each proved once: the one id parser every answer
goes through (present, absent, malformed), the one front-end parser, an apply that skips what the kit already has,
skills and login entries that a second run leaves untouched, and the one writer of the persona record. No network,
no install, no real kit home."""

from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
import apply as market_apply  # noqa: E402
import integration  # noqa: E402
import persona_membership  # noqa: E402
from addons import notebook  # noqa: E402
from model import CatalogError, load_addons, parse_addon_answer, parse_ids, split_ids  # noqa: E402
from runtime import AddonFailure, KitContext, Manifest  # noqa: E402

KNOWN = ["dash-server", "notebook", "udf-devkit"]


class IdParserTest(unittest.TestCase):
    """One tokenizer and one checker for every comma-separated answer, whichever side reads it."""

    def test_case_spaces_and_repeats_do_not_matter(self):
        self.assertEqual(["dash-server", "notebook"], split_ids(" DASH-SERVER , notebook,dash-server "))
        self.assertEqual(["dash-server", "notebook"], parse_ids(" Dash-Server, NOTEBOOK ", KNOWN, what="add-on", where="x"))

    def test_absent_and_empty_answers(self):
        self.assertEqual([""], split_ids(""))
        self.assertEqual([""], split_ids(None))
        with self.assertRaisesRegex(CatalogError, "empty add-on ID in the selection"):
            parse_ids("", KNOWN, what="add-on", where="the selection")

    def test_malformed_answers_are_refused_with_the_known_ids(self):
        for raw, why in (("dash-server,", "empty add-on ID"), ("dash-server,,notebook", "empty add-on ID"),
                         (",", "empty add-on ID"), ("nope", "Unknown add-on in HERE: 'nope' \\(known: dash-server notebook udf-devkit\\)"),
                         ("dash-server, nope", "'nope'")):
            with self.subTest(raw=raw), self.assertRaisesRegex(CatalogError, why):
                parse_ids(raw, KNOWN, what="add-on", where="HERE")

    def test_all_and_none_stand_alone_and_only_where_allowed(self):
        self.assertEqual(["all"], parse_ids(" ALL ", KNOWN, what="add-on", where="x", all_none=True))
        self.assertEqual(["none"], parse_ids("none", KNOWN, what="add-on", where="x", all_none=True))
        with self.assertRaisesRegex(CatalogError, "'all' stands alone"):
            parse_ids("all,dash-server", KNOWN, what="add-on", where="x", all_none=True)
        with self.assertRaisesRegex(CatalogError, "Unknown add-on"):
            parse_ids("all", KNOWN, what="add-on", where="x")

    def test_the_environment_answer_keeps_its_contract(self):
        addons = load_addons(ROOT)
        self.assertEqual("dash-server,notebook", parse_addon_answer(addons, " DASH-SERVER , notebook,dash-server "))
        self.assertEqual("all", parse_addon_answer(addons, "All"))
        with self.assertRaisesRegex(CatalogError, "empty add-on ID in EXAKIT_MARKETPLACE_ADDONS"):
            parse_addon_answer(addons, "dash-server,")
        with self.assertRaisesRegex(CatalogError, "Unknown marketplace add-on in EXAKIT_MARKETPLACE_ADDONS"):
            parse_addon_answer(addons, "dash-server,nope")

    def test_the_front_end_answer_has_one_parser(self):
        for raw, expected in (("jupyterlab,marimo", ("jupyterlab", "marimo")), ("Jupyter; Marimo", ("jupyterlab", "marimo")),
                              ("marimo jupyterlab", ("jupyterlab", "marimo")), ("none", ()), ("", ()), ("  ", ())):
            with self.subTest(raw=raw):
                self.assertEqual(expected, notebook.normalize_frontends(raw))
        for raw in ("positron-ide", "jupyterlab,jupyterlab", "jupyterlab,none,"):
            with self.subTest(raw=raw):
                if raw == "jupyterlab,none,":
                    self.assertEqual(("jupyterlab",), notebook.normalize_frontends(raw))   # none and an empty part drop
                else:
                    with self.assertRaisesRegex(AddonFailure, "Unknown or repeated notebook frontend"):
                        notebook.normalize_frontends(raw)


def context(home: Path) -> KitContext:
    (home / "manifest.json").write_text('{"components":{}}\n', encoding="utf-8")
    return KitContext(ROOT, home, home / "bin", Manifest(home / "manifest.json"), Path("uv"))


class ApplyIdempotencyTest(unittest.TestCase):
    """A second `exakit marketplace <id>` is a no-op: the add-on the kit already has is skipped, nothing invoked."""

    def test_an_installed_addon_is_skipped_and_said_so(self):
        with tempfile.TemporaryDirectory() as temp:
            ctx = context(Path(temp))
            ctx.manifest.set_many({"components.dash_server.ownership": "kit", "components.dash_server.version": "1.2.3"})
            operations, events = [], []

            def invoke(_root, addon_id, operation, *, ctx):
                operations.append((addon_id, operation))
                return 0, None

            with patch.object(market_apply, "invoke", side_effect=invoke), \
                 patch.object(market_apply, "install_addon_skills", return_value=[]), \
                 patch.object(market_apply, "register_autostart", return_value=False), \
                 patch.object(market_apply, "_module", return_value=(None, FakeModule("1.2.3"))):
                self.assertTrue(market_apply.apply(ctx, "dash-server", events.append))
            self.assertEqual([], operations, "nothing was installed, validated or started")
            self.assertEqual(["done"], [event.phase for event in events])
            self.assertIn("already installed (1.2.3)", events[0].detail)
            self.assertIn("exakit update dash-server", events[0].detail)

    def test_a_forced_install_still_runs(self):
        with tempfile.TemporaryDirectory() as temp:
            ctx = context(Path(temp))
            ctx.manifest.set_many({"components.dash_server.ownership": "kit"})
            operations = []
            with patch.dict(os.environ, {"EXAKIT_FORCE_COMPONENT_INSTALL": "1"}), \
                 patch.object(market_apply, "invoke", side_effect=lambda _r, a, o, *, ctx: operations.append(o) or (0, None)), \
                 patch.object(market_apply, "install_addon_skills", return_value=[]), \
                 patch.object(market_apply, "register_autostart", return_value=False), \
                 patch.object(market_apply, "_module", return_value=(None, FakeModule("1.2.3"))):
                self.assertTrue(market_apply.apply(ctx, "dash-server", lambda _: None))
            self.assertIn("install", operations)

    def test_the_steps_after_an_install_only_warn(self):
        with tempfile.TemporaryDirectory() as temp:
            ctx = context(Path(temp))
            events = []

            def invoke(_root, addon_id, operation, *, ctx):
                if operation == "validate":
                    return 1, None
                if operation == "start":
                    raise AddonFailure("port taken")
                return 0, "ready" if operation == "summary" else None

            with patch.object(market_apply, "invoke", side_effect=invoke), \
                 patch.object(market_apply, "install_addon_skills", side_effect=OSError("read-only")), \
                 patch.object(market_apply, "register_autostart", return_value=False), \
                 patch.object(market_apply, "_module", return_value=(None, FakeModule(None))):
                self.assertTrue(market_apply.apply(ctx, "dash-server", events.append))
            warnings = [event.detail for event in events if event.phase == "warning"]
            self.assertEqual(["validation did not finish; retry with exakit update dash-server",
                              "skills were not placed: read-only",
                              "installed but did not start: port taken; retry with exakit start"], warnings)
            self.assertEqual(["installing", "validating", "warning", "warning", "starting", "warning", "done"],
                             [event.phase for event in events])
            self.assertEqual("ready", events[-1].detail)


class FakeModule:
    def __init__(self, version):
        self._version = version

    def installed_version(self, ctx):
        return self._version

    def validate(self, ctx):
        return True

    def start(self, ctx):
        return None

    def summary(self, ctx):
        return "ready"


class IntegrationIdempotencyTest(unittest.TestCase):
    """Skills and login entries: placed once, then left alone byte for byte."""

    def test_skills_are_copied_once_and_a_second_run_writes_nothing(self):
        with tempfile.TemporaryDirectory() as temp:
            home, roots = Path(temp) / "home", Path(temp) / "skills"
            home.mkdir()
            ctx = context(home)
            with patch.dict(os.environ, {"EXAKIT_SKILL_ROOTS": str(roots)}):
                first = integration.install_addon_skills(ctx, "dash-server")
                self.assertTrue(first, "the dash-server add-on ships a skill")
                placed = roots / first[0]
                before = {path.relative_to(placed).as_posix(): path.stat().st_mtime_ns for path in placed.rglob("*") if path.is_file()}
                manifest_before = (home / "manifest.json").read_bytes()
                second = integration.install_addon_skills(ctx, "dash-server")
            self.assertEqual([], second)
            after = {path.relative_to(placed).as_posix(): path.stat().st_mtime_ns for path in placed.rglob("*") if path.is_file()}
            self.assertEqual(before, after, "no file was rewritten")
            self.assertEqual(manifest_before, (home / "manifest.json").read_bytes())

    def test_a_login_entry_with_the_same_command_is_not_rewritten_or_reloaded(self):
        with tempfile.TemporaryDirectory() as temp:
            home, agents = Path(temp) / "home", Path(temp) / "agents"
            home.mkdir()
            ctx = context(home)
            ctx.manifest.set_many({"autostart.enabled": True})
            calls = []
            module = type("Module", (), {"autostart_command": staticmethod(lambda ctx: ["/bin/true", "serve"])})
            with patch.dict(os.environ, {"EXAKIT_LAUNCHAGENT_DIR": str(agents), "EXAKIT_STARTUP_DIR": str(agents),
                                         "EXAKIT_SYSTEMD_USER_DIR": str(agents)}), \
                 patch.object(integration, "_run_quiet", side_effect=lambda *argv: calls.append(argv) or True):
                self.assertTrue(integration.register_autostart(ctx, "dash-server", module))
                entry = next(agents.iterdir())
                first_bytes, first_calls = entry.read_bytes(), list(calls)
                self.assertTrue(integration.register_autostart(ctx, "dash-server", module))
            self.assertEqual(first_bytes, entry.read_bytes())
            # The second run only asks whether the entry is loaded; it never unloads, loads or reloads anything.
            probe = {"darwin": [("launchctl", "list", "com.exasol.exakit.dash-server")],
                     "win32": []}.get(sys.platform, [("systemctl", "--user", "is-enabled", entry.name)])
            self.assertEqual(probe, calls[len(first_calls):], "an unchanged entry is not reloaded (that would restart the service)")


class PersonaRecordTest(unittest.TestCase):
    """One writer: the same ids again write nothing, so the manifest stays byte for byte."""

    def test_record_writes_once_and_keeps_the_install_source(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            (home / "manifest.json").write_text("{}")
            self.assertEqual(("general", True), persona_membership.record(home, "general", "install"))
            first = (home / "manifest.json").read_bytes()
            self.assertEqual(("general", False), persona_membership.record(home, " general ", "add"))
            self.assertEqual(first, (home / "manifest.json").read_bytes())
            doc = json.loads(first)
            self.assertEqual({"id": "general", "source": "install"}, {k: doc["persona"][k] for k in ("id", "source")})
            self.assertEqual(("data-scientist,general", True), persona_membership.record(home, "data-scientist,general", "add"))
            self.assertEqual("add", json.loads((home / "manifest.json").read_text())["persona"]["source"])
            self.assertEqual(("", True), persona_membership.record(home, "", "install"))
            with self.assertRaisesRegex(AddonFailure, "invalid persona id"):
                persona_membership.record(home, "../x", "add")

    def test_remove_twice_and_the_cli(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            (home / "manifest.json").write_text("{}")
            persona_membership.record(home, "data-scientist,general", "install")
            self.assertEqual((["general"], True), persona_membership.remove(ROOT, home, "data-scientist"))
            once = (home / "manifest.json").read_bytes()
            self.assertEqual((["general"], False), persona_membership.remove(ROOT, home, "data-scientist"))
            self.assertEqual(once, (home / "manifest.json").read_bytes())
            out = io.StringIO()
            with patch.dict(os.environ, {"EXAKIT_HOME": str(home)}), redirect_stdout(out), redirect_stderr(io.StringIO()):
                self.assertEqual(0, persona_membership.main(["remove", "data-scientist"]))
                self.assertEqual(0, persona_membership.main(["record", "general", "--source", "add"]))
                self.assertEqual(2, persona_membership.main(["remove", "nope"]))
            self.assertIn("was not recorded; nothing changed", out.getvalue())
            self.assertIn("Recorded personas: general (unchanged)", out.getvalue())


if __name__ == "__main__":
    unittest.main()
