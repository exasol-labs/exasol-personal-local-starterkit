"""Black-box tests: exakit marketplace and persona driven through the real shell entry points."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cli_entrypoints import entrypoints  # noqa: E402

TIMEOUT = 45
ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
INITIAL = {"components": {}}
HEADLESS_PERSONA = {"EXAKIT_LOAD_SAMPLE": "0", "EXAKIT_DATASETS": "", "EXAKIT_MCP_CLIENTS": "skip",
                    "EXAKIT_MARKETPLACE_ADDONS": "none"}
READ_ONLY = (["marketplace", "--list"], ["persona", "list"], ["persona", "show", "general"])


def visible(text: str) -> str:
    """Text with ANSI escapes removed."""
    return ANSI.sub("", text)


def squeeze(text: str) -> str:
    """Text with every run of whitespace collapsed to one space."""
    return " ".join(text.split())


class KitHomeCase(unittest.TestCase):
    """A fake kit home per test plus one helper per kind of assertion."""

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="exakit blackbox ")
        self.base = Path(self.temp.name)
        self.home = self.base / "kit home"
        self.bin_dir = self.base / "kit bin"
        self.home.mkdir()
        self.bin_dir.mkdir()
        self.manifest = self.home / "manifest.json"
        self.reset_manifest(INITIAL)
        self.commands = entrypoints()
        self.assertTrue(self.commands, "no exakit entry point on this host")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def reset_manifest(self, document: dict) -> None:
        """Write the manifest afresh."""
        self.manifest.write_text(json.dumps(document), encoding="utf-8")

    def env(self, extra: dict[str, str] | None = None, drop: tuple[str, ...] = ()) -> dict[str, str]:
        """The headless, offline environment every run gets, with overrides."""
        env = {**os.environ, "EXAKIT_HOME": str(self.home), "EXAKIT_BIN_DIR": str(self.bin_dir),
               "HOME": str(self.base), "EXAKIT_NO_FANCY": "1", "EXAKIT_NO_UPDATE_NOTICE": "1",
               "EXAKIT_ABOUT_OFFLINE": "1", **(extra or {})}
        for name in drop:
            env.pop(name, None)
        return env

    def run_kit(self, prefix: list[str], args: list[str], extra: dict[str, str] | None = None,
                drop: tuple[str, ...] = (), stdin: str = "devnull") -> subprocess.CompletedProcess:
        """Run one entry point; stdin is 'devnull', 'pipe' (empty input) or 'closed' (bash only)."""
        command = [*prefix, *args]
        if stdin == "closed":
            command = ["bash", "-c", 'exec 0<&-; exec "$@"', "_", *command]
        feed = {"input": ""} if stdin == "pipe" else {"stdin": subprocess.DEVNULL}
        return subprocess.run(command, env=self.env(extra, drop), capture_output=True, text=True,
                              timeout=TIMEOUT, check=False, **feed)

    def tree(self) -> dict[str, tuple[int, str]]:
        """Every file under the kit home and bin dir as (size, sha256); logs/ is skipped, each run appends a log."""
        return {str(path.relative_to(self.base)): (path.stat().st_size, hashlib.sha256(path.read_bytes()).hexdigest())
                for root in (self.home, self.bin_dir) for path in root.rglob("*")
                if path.is_file() and path.relative_to(self.base).parts[:2] != (self.home.name, "logs")}

    def directories(self) -> list[str]:
        """Directories the kit made under its home, logs/ aside."""
        return sorted(str(p.relative_to(self.home)) for p in self.home.rglob("*") if p.is_dir() and p.name != "logs")

    def persona_id(self) -> str | None:
        """persona.id from the manifest, None when absent."""
        return json.loads(self.manifest.read_text(encoding="utf-8")).get("persona", {}).get("id")

    def assert_rc(self, result: subprocess.CompletedProcess, code: int) -> None:
        """Exact exit code, with the output as the failure message."""
        self.assertEqual(code, result.returncode, result.stdout + result.stderr)

    def assert_mentions(self, result: subprocess.CompletedProcess, *phrases: str) -> None:
        """At least one phrase appears in stdout+stderr, case-insensitively."""
        text = (result.stdout + result.stderr).lower()
        self.assertTrue(any(phrase.lower() in text for phrase in phrases), f"{phrases!r} not in {text!r}")

    def assert_unchanged(self, before: dict, what: str) -> None:
        """The kit-home tree equals an earlier snapshot."""
        self.assertEqual(before, self.tree(), f"{what} changed the kit home")


class HeadlessTest(KitHomeCase):
    """Without a terminal, browsing never installs and nothing is written."""

    def test_browse_without_terminal_installs_nothing(self) -> None:
        for prefix in self.commands:
            modes = ("devnull", "pipe", "closed") if prefix[0] == "bash" else ("devnull", "pipe")
            for mode in modes:
                with self.subTest(shell=prefix[0], stdin=mode):
                    before = self.tree()
                    result = self.run_kit(prefix, ["marketplace"], drop=("EXAKIT_MARKETPLACE_ADDONS",), stdin=mode)
                    self.assert_rc(result, 0)
                    self.assert_mentions(result, "nothing was installed")
                    self.assert_unchanged(before, f"marketplace with stdin {mode}")

    def test_persona_add_without_id_names_the_command(self) -> None:
        for prefix in self.commands:
            with self.subTest(shell=prefix[0]):
                before = self.tree()
                result = self.run_kit(prefix, ["persona", "add"])
                self.assert_rc(result, 2)
                self.assert_mentions(result, "exakit persona add <id>")
                self.assert_unchanged(before, "persona add without an id")

    def test_browse_makes_the_same_directories_on_every_entry_point(self) -> None:
        made = {}
        for prefix in self.commands:
            for stale in self.directories():
                shutil.rmtree(self.home / stale, ignore_errors=True)
            self.assert_rc(self.run_kit(prefix, ["marketplace"], drop=("EXAKIT_MARKETPLACE_ADDONS",)), 0)
            made[prefix[0]] = self.directories()
        self.assertEqual(1, len({tuple(dirs) for dirs in made.values()}), f"directories differ: {made}")


class ColourTest(KitHomeCase):
    """Colour is off on every plain-text signal and never leaks into a pipe."""

    PLAIN = {"no_color": ({"NO_COLOR": "1"}, ("EXAKIT_NO_FANCY",)), "term_dumb": ({"TERM": "dumb"}, ()),
             "no_fancy": ({"EXAKIT_NO_FANCY": "1"}, ())}
    FANCY = ({"TERM": "xterm-256color", "FORCE_COLOR": "1"}, ("EXAKIT_NO_FANCY", "NO_COLOR"))

    def test_plain_signals_emit_no_escapes(self) -> None:
        for prefix in self.commands:
            for args in READ_ONLY:
                for name, (extra, drop) in self.PLAIN.items():
                    with self.subTest(shell=prefix[0], command=" ".join(args), signal=name):
                        result = self.run_kit(prefix, args, extra, drop)
                        self.assert_rc(result, 0)
                        self.assertNotIn("\x1b", result.stdout + result.stderr)

    def test_forced_palette_on_a_pipe_reads_like_plain_text(self) -> None:
        for prefix in self.commands:
            for args in READ_ONLY:
                with self.subTest(shell=prefix[0], command=" ".join(args)):
                    plain = self.run_kit(prefix, args, {"EXAKIT_NO_FANCY": "1"})
                    fancy = self.run_kit(prefix, args, *self.FANCY)
                    self.assert_rc(plain, 0)
                    self.assert_rc(fancy, 0)
                    self.assertEqual(squeeze(plain.stdout), squeeze(visible(fancy.stdout)))
                    if "\x1b" not in fancy.stdout:
                        self.assertEqual(fancy.stdout, visible(fancy.stdout))

    def test_list_fits_sixty_columns(self) -> None:
        for prefix in self.commands:
            with self.subTest(shell=prefix[0]):
                result = self.run_kit(prefix, ["marketplace", "--list"], {"COLUMNS": "60"})
                self.assert_rc(result, 0)
                for line in visible(result.stdout).splitlines():
                    self.assertLessEqual(len(line), 60, line)


class EnvAnswerTest(KitHomeCase):
    """EXAKIT_MARKETPLACE_ADDONS: absent, empty and malformed values never install anything."""

    CASES = {"": (True, ("nothing was installed",)), "nope": (False, ("nope",)),
             "dash-server,": (False, ("empty marketplace add-on id", "empty add-on id")),
             "ALL,dash-server": (False, ("'all'", "all"))}

    def test_values_are_refused_or_install_nothing(self) -> None:
        for value, (succeeds, phrases) in self.CASES.items():
            classes = {}
            for prefix in self.commands:
                with self.subTest(shell=prefix[0], value=value):
                    before = self.manifest.read_bytes()
                    result = self.run_kit(prefix, ["marketplace"], {"EXAKIT_MARKETPLACE_ADDONS": value})
                    classes[prefix[0]] = result.returncode == 0
                    self.assertEqual(succeeds, result.returncode == 0, result.stdout + result.stderr)
                    self.assert_mentions(result, *phrases)
                    self.assertEqual(before, self.manifest.read_bytes(), f"EXAKIT_MARKETPLACE_ADDONS={value!r}")
            self.assertEqual(1, len(set(classes.values())), f"exit classes differ for {value!r}: {classes}")

    def test_refusal_leaves_the_same_failure_note_on_every_entry_point(self) -> None:
        notes = {}
        for prefix in self.commands:
            (self.home / ".last-failure").unlink(missing_ok=True)
            result = self.run_kit(prefix, ["marketplace"], {"EXAKIT_MARKETPLACE_ADDONS": "nope"})
            self.assertNotEqual(0, result.returncode)
            notes[prefix[0]] = (self.home / ".last-failure").exists()
        self.assertEqual(1, len(set(notes.values())), f".last-failure after a refused env answer: {notes}")

    @unittest.skipIf(os.name == "nt", "the add-on's environment is stood in by a shell script")
    def test_already_installed_addon_is_left_alone(self) -> None:
        """An add-on the kit installed is left alone on a second run. "Installed" is what the add-on's own
        environment answers (a receipt alone is a stale record, and the kit reinstalls over it), so the
        environment is stood in: its python answers the recorded version to any question."""
        self.reset_manifest({"components": {"dash_server": {"ownership": "kit", "version": "9.9.9"}}})
        python = self.home / "dash-server-venv" / "bin" / "python"
        python.parent.mkdir(parents=True)
        python.write_text("#!/bin/sh\necho 9.9.9\n", encoding="utf-8")
        python.chmod(0o755)
        for prefix in self.commands:
            with self.subTest(shell=prefix[0]):
                before = self.tree()
                result = self.run_kit(prefix, ["marketplace"], {"EXAKIT_MARKETPLACE_ADDONS": " DASH-SERVER , dash-server "})
                self.assert_rc(result, 0)
                self.assert_mentions(result, "already")
                self.assert_unchanged(before, "a repeated, already installed add-on")


class PersonaEnvTest(KitHomeCase):
    """exakit persona add <value> refusals, and the JSON shape of a refused show."""

    def test_unknown_mixed_case_and_empty_ids_are_refused(self) -> None:
        for prefix in self.commands:
            for value in ("nope", "General", ""):
                with self.subTest(shell=prefix[0], value=value):
                    result = self.run_kit(prefix, ["persona", "add", value], HEADLESS_PERSONA, stdin="pipe")
                    self.assert_rc(result, 2)
                    self.assertIsNone(self.persona_id())

    def test_trailing_comma_is_handled_alike(self) -> None:
        outcomes = {}
        for prefix in self.commands:
            with self.subTest(shell=prefix[0]):
                self.reset_manifest(INITIAL)
                result = self.run_kit(prefix, ["persona", "add", "data-scientist,general,"], HEADLESS_PERSONA, stdin="pipe")
                outcomes[prefix[0]] = (result.returncode, self.persona_id())
        self.assertEqual(1, len(set(outcomes.values())), f"entry points disagree: {outcomes}")

    def test_show_unknown_json_is_one_object(self) -> None:
        for prefix in self.commands:
            with self.subTest(shell=prefix[0]):
                result = self.run_kit(prefix, ["persona", "show", "nope", "--json"])
                self.assert_rc(result, 2)
                self.assertIsInstance(json.loads(result.stdout), dict)

    def test_refusal_stream_agrees_across_entry_points(self) -> None:
        streams = {}
        for prefix in self.commands:
            result = self.run_kit(prefix, ["persona", "add", "nope"], HEADLESS_PERSONA, stdin="pipe")
            streams[prefix[0]] = "stderr" if "unknown persona" in result.stderr.lower() else "stdout"
        self.assertEqual(1, len(set(streams.values())), f"refusal stream differs: {streams}")


class IdempotencyTest(KitHomeCase):
    """A second run of each command exits 0, says so and leaves the manifest alone."""

    def test_uninstall_of_absent_addon_twice(self) -> None:
        for prefix in self.commands:
            with self.subTest(shell=prefix[0]):
                self.reset_manifest(INITIAL)
                initial = self.manifest.read_bytes()
                for _ in range(2):
                    result = self.run_kit(prefix, ["uninstall", "dash-server", "--yes"])
                    self.assert_rc(result, 0)
                    self.assert_mentions(result, "not installed", "nothing")
                    self.assertEqual(initial, self.manifest.read_bytes())

    def test_persona_add_twice_records_general_once(self) -> None:
        for prefix in self.commands:
            with self.subTest(shell=prefix[0]):
                self.reset_manifest(INITIAL)
                for _ in range(2):
                    result = self.run_kit(prefix, ["persona", "add", "general"], HEADLESS_PERSONA, stdin="pipe")
                    self.assert_rc(result, 0)
                    self.assertEqual("general", self.persona_id())

    def test_persona_add_twice_is_a_no_op(self) -> None:
        for prefix in self.commands:
            with self.subTest(shell=prefix[0]):
                self.reset_manifest(INITIAL)
                self.assert_rc(self.run_kit(prefix, ["persona", "add", "general"], HEADLESS_PERSONA, stdin="pipe"), 0)
                first = self.manifest.read_bytes()
                result = self.run_kit(prefix, ["persona", "add", "general"], HEADLESS_PERSONA, stdin="pipe")
                self.assert_rc(result, 0)
                self.assert_mentions(result, "already", "nothing", "not installed", "not recorded")
                self.assertEqual(first, self.manifest.read_bytes())

    def test_persona_remove_twice(self) -> None:
        for prefix in self.commands:
            with self.subTest(shell=prefix[0]):
                self.reset_manifest(INITIAL)
                self.assert_rc(self.run_kit(prefix, ["persona", "add", "general"], HEADLESS_PERSONA, stdin="pipe"), 0)
                first = self.run_kit(prefix, ["persona", "remove", "general"], stdin="pipe")
                self.assert_rc(first, 0)
                self.assertEqual("", self.persona_id())
                after_first = self.manifest.read_bytes()
                second = self.run_kit(prefix, ["persona", "remove", "general"], stdin="pipe")
                self.assert_rc(second, 0)
                self.assert_mentions(second, "not recorded", "nothing")
                self.assertEqual(after_first, self.manifest.read_bytes())


if __name__ == "__main__":
    unittest.main()
