"""The live lifecycle's privacy watch finds a kit's secrets by label, never by value, and its leftover rule."""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "integration"))
import privacy_watch  # noqa: E402

PASSWORD = "borrowed-database-password"
TOKEN = "generated-notebook-token"


class PrivacyWatchTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.source, self.home, self.bin_dir = base / "source", base / "home", base / "bin"
        for folder in (self.source, self.home / "credentials", self.bin_dir):
            folder.mkdir(parents=True)
        password_file = self.source / "password"
        password_file.write_text(PASSWORD + "\n")
        (self.source / "manifest.json").write_text(json.dumps({"runtime": {"password_file": str(password_file)}}))
        (self.home / "credentials" / "notebook_jupyter_token").write_text(TOKEN)
        (self.home / "credentials" / "langfuse.json").write_text(json.dumps({"LANGFUSE_SECRET_KEY": "sk-lf-secret-value", "n": 1}))
        (self.home / "credentials" / "short").write_text("abc")
        self.watch = privacy_watch.PrivacyWatch(self.source, self.home, self.bin_dir,
                                                {"runtime": {"password_file": str(password_file)}})

    def test_secrets_are_the_borrowed_password_and_every_generated_credential(self) -> None:
        secrets = self.watch.secrets()
        self.assertEqual(PASSWORD, secrets["database_password_0"])
        self.assertEqual(TOKEN, secrets["credentials/notebook_jupyter_token#0"])
        self.assertIn("sk-lf-secret-value", secrets.values())
        self.assertNotIn("abc", secrets.values())

    def test_a_secret_in_a_generated_file_is_named_without_its_value(self) -> None:
        (self.bin_dir / "launcher").write_text(f"export PASSWORD={PASSWORD}\n")
        (self.home / "profile.yml").write_text("password: \"{{ env_var('DBT_PASSWORD') }}\"\n")
        self.watch.scan_files("installed")
        self.assertEqual([{"phase": "installed", "where": "file bin/launcher", "secret": "database_password_0"}],
                         self.watch.findings)
        self.assertNotIn(PASSWORD, json.dumps(self.watch.findings))

    def test_the_credentials_store_venv_packages_and_binaries_are_not_findings(self) -> None:
        (self.home / "x-venv" / "site-packages").mkdir(parents=True)
        (self.home / "x-venv" / "site-packages" / "copy.txt").write_text(TOKEN)
        (self.home / "engine").write_bytes(b"\0" + PASSWORD.encode())
        self.watch.scan_files("installed")
        self.assertEqual([], self.watch.findings)

    def test_command_output_is_scanned_once_per_place(self) -> None:
        self.watch.scan_text("marketplace notebook", "command output", f"token {TOKEN} and {TOKEN}")
        self.watch.scan_text("marketplace notebook", "command output", TOKEN)
        self.assertEqual(1, len(self.watch.findings))

    def test_process_arguments_are_sampled_while_a_command_runs(self) -> None:
        privacy_watch._process_lines, original = (lambda: [f"server --token {TOKEN}"]), privacy_watch._process_lines
        self.addCleanup(setattr, privacy_watch, "_process_lines", original)
        with self.watch.watching("notebook start"):
            pass
        self.assertGreaterEqual(self.watch.samples, 1)
        self.assertEqual("process arguments", self.watch.findings[0]["where"])


class LeftoversTest(unittest.TestCase):
    AFTER = {"dash-server/", "dash-server/instance/", "dash-server/instance/app.py", "dbt/", "dbt/profiles.yml",
             "dbt/personal work.txt", "logs/install.log", "cache/x", "manifest.json.lock", "x-venv/"}

    def test_kept_user_work_and_the_folders_holding_it_are_not_leftovers(self) -> None:
        left = privacy_watch.leftovers(set(), self.AFTER, ["dash-server/instance/", "dbt/personal work.txt"])
        self.assertEqual(["dbt/profiles.yml", "x-venv/"], left)

    def test_what_was_there_before_is_not_a_leftover(self) -> None:
        self.assertEqual([], privacy_watch.leftovers(self.AFTER, self.AFTER, []))

    def test_paths_mark_folders_with_a_slash(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            (Path(temporary) / "a").mkdir()
            (Path(temporary) / "a" / "b").write_text("x")
            self.assertEqual({"a/", "a/b"}, privacy_watch.paths(Path(temporary)))


if __name__ == "__main__":
    unittest.main()
