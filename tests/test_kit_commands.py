"""The kit's commands from a notebook (exakit_nb.kit_commands): the output streams into the cell as it comes, the
result carries the exit code, a question takes its default because the command has no terminal, the status is read as
JSON and summed up, and addon_ready installs and starts only what is missing. The ``exakit`` here is a shell script
that records what it was called with and answers like the kit, so no kit is needed."""

from __future__ import annotations

import contextlib
import io
import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "notebook/package"))
import exakit_nb  # noqa: E402
from exakit_nb import kit_commands  # noqa: E402

FAKE = r'''#!/bin/sh
# A stand-in for exakit: logs its arguments, answers status and marketplace as JSON, echoes the rest.
printf '%s\n' "$*" >> "$EXAKIT_FAKE_LOG"
case "$1 $2" in
  "status --json")
    printf '%s\n' "$EXAKIT_FAKE_STATUS"; exit 0 ;;
  "marketplace --json")
    printf '%s\n' "$EXAKIT_FAKE_MARKETPLACE"; exit 0 ;;
esac
case "$1" in
  update) echo "Checking for updates..."; echo "Everything is up to date."; exit 0 ;;
  marketplace) echo "Installing $2..."; echo "[ok] $2 installed"; exit 0 ;;
  start) echo "[ok] $2 started"; exit 0 ;;
  ask) # a question with a default: without a terminal it must not block
    if [ -t 0 ]; then echo "has a terminal"; else echo "no terminal: default taken"; fi
    if (: < /dev/tty) 2>/dev/null; then echo "tty open"; else echo "tty closed"; fi
    exit 0 ;;
  fail) echo "something went wrong" >&2; exit 3 ;;
  slow) sleep 30; exit 0 ;;
esac
echo "unknown $1"; exit 2
'''

STATUS = {"installed": True, "status": "running", "runtime": {"type": "exasol-personal", "status": "running"},
          "services": {"dash-server": "stopped"}, "urls": {}, "datasets_loaded": ["amazon_sales"],
          "remedies": {"mcp": "exakit mcp-doctor"}}
MARKETPLACE = {"addons": [{"id": "dash-server", "status": "available", "installed": False},
                          {"id": "notebook", "status": "installed", "installed": True}]}


class KitCommandsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        folder = Path(self.temp.name)
        self.script = folder / "exakit"
        self.script.write_text(FAKE, encoding="utf-8")
        self.script.chmod(self.script.stat().st_mode | stat.S_IXUSR)
        self.log = folder / "calls.log"
        env = mock.patch.dict(os.environ, {"EXAKIT_FAKE_LOG": str(self.log), "EXAKIT_FAKE_STATUS": json.dumps(STATUS),
                                           "EXAKIT_FAKE_MARKETPLACE": json.dumps(MARKETPLACE)})
        env.start()
        self.addCleanup(env.stop)
        found = mock.patch.object(kit_commands, "exakit_command", return_value=[str(self.script)])
        found.start()
        self.addCleanup(found.stop)

    def calls(self) -> list[str]:
        return self.log.read_text(encoding="utf-8").splitlines() if self.log.is_file() else []

    def test_the_output_streams_into_the_cell_and_the_result_says_how_it_ended(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            run = exakit_nb.exakit("update")
        self.assertTrue(run.ok)
        self.assertEqual(["update"], self.calls())
        self.assertEqual(["Checking for updates...", "Everything is up to date."], run.lines)
        self.assertIn("Everything is up to date.\n", out.getvalue())
        self.assertIn("exakit update: ok (2 lines)", out.getvalue())
        self.assertEqual("exakit update: ok (2 lines)", repr(run))

    def test_a_failure_keeps_its_output_and_exit_code(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            run = exakit_nb.exakit("fail")
        self.assertEqual((False, 3), (run.ok, run.code))
        self.assertIn("something went wrong", run.output)
        self.assertIn("exit 3", out.getvalue())
        self.assertFalse(run)

    @unittest.skipIf(os.name == "nt", "a controlling terminal is a POSIX thing")
    def test_the_command_has_no_terminal_so_a_question_takes_its_default(self):
        with contextlib.redirect_stdout(io.StringIO()):
            run = exakit_nb.exakit("ask")
        self.assertIn("no terminal: default taken", run.lines)
        self.assertIn("tty closed", run.lines)

    def test_the_environment_asks_for_plain_output_and_takes_extra_variables(self):
        env = kit_commands._environment({"EXAKIT_MCP_CLIENTS": "claude"})
        self.assertEqual(("1", "dumb", "claude"), (env["NO_COLOR"], env["TERM"], env["EXAKIT_MCP_CLIENTS"]))
        self.assertNotIn("EXAKIT_REFUSAL_JSON", env)

    def test_a_command_over_its_timeout_is_stopped_and_says_so(self):
        with contextlib.redirect_stdout(io.StringIO()):
            run = exakit_nb.exakit("slow", timeout=0.5)
        self.assertTrue(run.timed_out)
        self.assertFalse(run.ok)

    def test_kit_check_sums_the_status_up_and_never_raises(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            status = exakit_nb.kit_check()
        self.assertEqual("running", status["status"])
        text = out.getvalue()
        self.assertIn("Kit: installed; database running", text)
        self.assertIn("Add-on services: dash-server stopped", text)
        self.assertIn("Datasets loaded: amazon_sales", text)
        self.assertIn('To fix mcp: nb.exakit("mcp-doctor")', text)
        self.assertEqual(["status --json"], self.calls())

    def test_kit_check_without_the_command_says_where_it_looked(self):
        out = io.StringIO()
        with mock.patch.object(kit_commands, "exakit_command", return_value=None), contextlib.redirect_stdout(out):
            self.assertEqual({}, exakit_nb.kit_check())
        self.assertIn("`exakit` was not found on PATH", out.getvalue())
        with self.assertRaisesRegex(RuntimeError, "not found on PATH"), mock.patch.object(kit_commands, "exakit_command", return_value=None):
            exakit_nb.exakit("status")

    def test_kit_check_says_when_the_kit_is_not_installed(self):
        out = io.StringIO()
        with mock.patch.dict(os.environ, {"EXAKIT_FAKE_STATUS": json.dumps({"installed": False, "status": "not installed",
                                                                            "remedy": "curl ... | sh"})}), \
                contextlib.redirect_stdout(out):
            exakit_nb.kit_check()
        self.assertIn("The kit is not installed (not installed)", out.getvalue())
        self.assertIn("Install it with: curl ... | sh", out.getvalue())

    def test_addon_ready_installs_what_is_missing_starts_what_is_stopped_and_says_where_it_is(self):
        started = json.dumps({**STATUS, "services": {"dash-server": "running"}, "urls": {"dash-server": "http://localhost:5100"}})

        def status_after_start(*args, **kwargs):
            if "start" in self.calls()[-1] if self.calls() else False:
                os.environ["EXAKIT_FAKE_STATUS"] = started
            return original(*args, **kwargs)

        original = kit_commands.exakit
        out = io.StringIO()
        with mock.patch.object(kit_commands, "exakit", side_effect=status_after_start), contextlib.redirect_stdout(out):
            found = exakit_nb.addon_ready("dash-server")
        self.assertEqual(["marketplace --json", "marketplace dash-server", "status --json", "start dash-server", "status --json"],
                         self.calls())
        self.assertEqual({"addon": "dash-server", "installed": True, "state": "running", "url": "http://localhost:5100"}, found)
        self.assertIn("Installing the dash-server add-on from here", out.getvalue())
        self.assertIn("dash-server: running, at http://localhost:5100", out.getvalue())

    def test_addon_ready_touches_nothing_that_is_already_there(self):
        with mock.patch.dict(os.environ, {
                "EXAKIT_FAKE_MARKETPLACE": json.dumps({"addons": [{"id": "dash-server", "installed": True}]}),
                "EXAKIT_FAKE_STATUS": json.dumps({**STATUS, "services": {"dash-server": "running"}})}), \
                contextlib.redirect_stdout(io.StringIO()):
            found = exakit_nb.addon_ready("dash-server")
        self.assertEqual(["marketplace --json", "status --json"], self.calls())
        self.assertEqual("running", found["state"])
        with self.assertRaisesRegex(ValueError, "No add-on 'nope'"):
            exakit_nb.addon_ready("nope", show=False)

    def test_kit_update_reminds_about_the_kernel(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            run = exakit_nb.kit_update()
        self.assertTrue(run.ok)
        self.assertEqual(["update"], self.calls())
        self.assertIn("restart this kernel", out.getvalue())


if __name__ == "__main__":
    unittest.main()
