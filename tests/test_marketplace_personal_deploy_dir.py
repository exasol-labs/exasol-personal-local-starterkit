"""The marketplace finds the Exasol Personal deployment where launcher 2.5.0 keeps it.

The kit's database is the deployment named starter-kit-local. Launcher 2.5.0 moves a stopped deployment from
~/.exasol/personal/deployments/<name> to ~/.exasol/launcher/deployments/<name> by itself, and a 0.3.0 kit's own
`default` is renamed to starter-kit-local by its update. The scheduler add-on writes its sidecar into the
deployment's sidecars.yaml, found from runtime.deployment_dir: that path follows the move and the rename by the
deployment's id (runtime.personal_deployment_dir, the twin of detect_personal_deploy_resolve and
Resolve-PersonalDeployDir). In mode P the launcher runs in the kit's private home, and so do its folders.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
from addons import exasol_scheduler as scheduler  # noqa: E402
from runtime import (KIT_DEPLOYMENT, KitContext, Manifest, _personal_folder_deployment_id,  # noqa: E402
                     personal_deploy_defaults, personal_deploy_roots, personal_deployment_dir,
                     personal_launcher_deployments, personal_launcher_home)


class PersonalDeployDirTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        if os.name == "nt":
            self.env = {"USERPROFILE": str(self.root / "profile"), "LOCALAPPDATA": str(self.root / "profile" / "local")}
        else:
            self.env = {"HOME": str(self.root / "profile")}
        self.new, self.old = personal_deploy_defaults(self.env)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_the_two_homes_are_the_launchers(self) -> None:
        self.assertEqual("starter-kit-local", KIT_DEPLOYMENT)
        if os.name == "nt":
            self.assertEqual(Path(self.env["LOCALAPPDATA"], "exasol", "launcher", "deployments", "starter-kit-local"), self.new)
            self.assertEqual(Path(self.env["USERPROFILE"], ".exasol", "personal", "deployments", "starter-kit-local"), self.old)
        else:
            self.assertEqual(Path(self.env["HOME"], ".exasol", "launcher", "deployments", "starter-kit-local"), self.new)
            self.assertEqual(Path(self.env["HOME"], ".exasol", "personal", "deployments", "starter-kit-local"), self.old)

    @unittest.skipIf(os.name == "nt", "mode P is macOS and Linux only")
    def test_mode_p_runs_the_launcher_in_the_kits_private_home(self) -> None:
        kit = self.root / "profile" / ".exasol-starter-kit"
        private = kit / "personal" / "home"
        self.assertEqual(self.env["HOME"], personal_launcher_home(self.env))
        wrapper = kit / "personal" / "bin" / "exasol"
        wrapper.parent.mkdir(parents=True)
        wrapper.write_text("#!/bin/sh\n")
        wrapper.chmod(0o755)
        # Every mode has a launcher there (K and U too): not the marker.
        self.assertEqual(self.env["HOME"], personal_launcher_home(self.env))
        binary = kit / "personal" / "libexec" / "exasol"
        binary.parent.mkdir(parents=True)
        binary.write_text("#!/bin/sh\n")
        self.assertEqual(self.env["HOME"], personal_launcher_home(self.env))   # not executable: not the binary
        binary.chmod(0o755)
        self.assertEqual(str(private), personal_launcher_home(self.env))
        self.assertEqual((private / ".exasol" / "launcher" / "deployments" / "starter-kit-local",
                          private / ".exasol" / "personal" / "deployments" / "starter-kit-local"),
                         personal_deploy_defaults(self.env))
        # The recorded home wins (runtime.launcher_home), then EXAKIT_PERSONAL_LAUNCHER_HOME.
        self.assertEqual("/rec", personal_launcher_home(self.env, "/rec"))
        self.assertEqual("/env", personal_launcher_home(dict(self.env, EXAKIT_PERSONAL_LAUNCHER_HOME="/env")))
        self.assertEqual(Path("/rec", ".exasol", "launcher", "deployments"), personal_deploy_roots(self.env, "/rec")[0])

    def test_nothing_recorded_is_nothing(self) -> None:
        self.assertIsNone(personal_deployment_dir(None, self.env))
        self.assertIsNone(personal_deployment_dir("", self.env))

    def test_an_old_layout_is_itself(self) -> None:
        self.old.mkdir(parents=True)
        self.assertEqual(self.old, personal_deployment_dir(str(self.old), self.env))

    def test_a_fresh_layout_is_itself(self) -> None:
        self.new.mkdir(parents=True)
        self.assertEqual(self.new, personal_deployment_dir(str(self.new), self.env))

    def seed(self, folder: Path, deployment_id: str) -> None:
        folder.mkdir(parents=True)
        (folder / "deployment.json").write_text('{\n  "deploymentId": "%s",\n  "connection": {}\n}\n' % deployment_id)

    def test_a_moved_deployment_is_followed(self) -> None:
        self.seed(self.new, "exa-kit")      # the launcher moved it; the record still names the old path
        self.assertEqual(self.new, personal_deployment_dir(str(self.old), self.env, deployment_id="exa-kit"))

    def test_the_users_own_deployment_is_never_followed(self) -> None:
        self.seed(self.new, "exa-user")     # the kit's own is gone; this one has another id
        self.assertIsNone(personal_deployment_dir(str(self.old), self.env, deployment_id="exa-kit"))

    def test_no_recorded_id_follows_nothing(self) -> None:
        self.seed(self.new, "exa-user")     # a kit from before 0.3.1 recorded no id
        self.assertIsNone(personal_deployment_dir(str(self.old), self.env))
        self.assertIsNone(personal_deployment_dir(str(self.old), self.env, deployment_id=""))

    def test_an_id_that_reads_as_a_number_is_text_and_a_number_is_no_id(self) -> None:
        self.seed(self.new, "3e082473")
        self.assertEqual(self.new, personal_deployment_dir(str(self.old), self.env, deployment_id="3e082473"))
        self.assertIsNone(personal_deployment_dir(str(self.old), self.env, deployment_id=float("inf")))
        # ... the recorded folder still there: no id on record is not another id.
        self.assertEqual(self.new, personal_deployment_dir(str(self.new), self.env, deployment_id=float("inf")))
        self.assertIsNone(personal_deployment_dir(str(self.new), self.env, deployment_id="1e000003"))

    def test_a_folder_that_names_no_id_is_not_followed(self) -> None:
        self.new.mkdir(parents=True)
        self.assertIsNone(personal_deployment_dir(str(self.old), self.env, deployment_id="exa-kit"))

    def test_both_present_keeps_the_recorded_one(self) -> None:
        self.old.mkdir(parents=True)
        self.new.mkdir(parents=True)        # not a move: the recorded deployment is still there
        self.assertEqual(self.old, personal_deployment_dir(str(self.old), self.env))

    def test_a_folder_the_user_chose_is_never_redirected(self) -> None:
        self.new.mkdir(parents=True)
        custom = self.root / "custom"
        self.assertIsNone(personal_deployment_dir(str(custom), self.env))
        custom.mkdir()
        self.assertEqual(custom, personal_deployment_dir(str(custom), self.env))

    def test_another_deployment_in_the_kits_folder_is_not_the_kits(self) -> None:
        # MCU-02 / OWN-01: the kit's own destroyed, the user's made in the same folder (another id).
        self.seed(self.new, "exa-user")
        self.assertIsNone(personal_deployment_dir(str(self.new), self.env, deployment_id="exa-kit"))
        self.assertEqual(self.new, personal_deployment_dir(str(self.new), self.env, deployment_id="exa-user"))
        # Adopted on purpose (the installer's "Use it instead?"): the user's, and used.
        self.assertEqual(self.new, personal_deployment_dir(str(self.new), self.env, deployment_id="exa-kit",
                                                           ownership="user"))

    def test_gone_everywhere_is_none(self) -> None:
        self.assertIsNone(personal_deployment_dir(str(self.old), self.env))

    def test_a_0_3_0_default_record_is_followed_by_its_id_whatever_its_name(self) -> None:
        # A 0.3.0 kit recorded .../deployments/default; its update renamed it to starter-kit-local, and 2.5.0 moved it.
        new_root, old_root = personal_deploy_roots(self.env)
        self.seed(self.new, "exa-kit")
        self.assertEqual(self.new, personal_deployment_dir(str(old_root / "default"), self.env, deployment_id="exa-kit"))
        self.assertEqual(self.new, personal_deployment_dir(str(new_root / "default"), self.env, deployment_id="exa-kit"))

    def test_a_default_moved_but_not_renamed_is_followed_too(self) -> None:
        # The user's own 2.5 moved a 0.3.0 kit's `default` (with the kit's id) before the update renamed it.
        new_root, old_root = personal_deploy_roots(self.env)
        self.seed(new_root / "default", "exa-kit")
        self.assertEqual(new_root / "default",
                         personal_deployment_dir(str(old_root / "default"), self.env, deployment_id="exa-kit"))

    def test_the_users_default_is_never_the_kits(self) -> None:
        # The kit's starter-kit-local gone; the user's `default` (another id) and a `dev` with no id are not followed.
        new_root, _ = personal_deploy_roots(self.env)
        self.seed(new_root / "default", "exa-user")
        self.seed(new_root / "dev", "")
        self.assertIsNone(personal_deployment_dir(str(self.new), self.env, deployment_id="exa-kit"))
        self.assertIsNone(personal_deployment_dir(str(self.old), self.env, deployment_id="exa-kit"))

    # --- the deployment id: the launcher's state first, top-level key, never "local" (WSL-03, MCU-04) ---------
    def test_the_id_is_the_launchers_state_first(self) -> None:
        self.new.mkdir(parents=True)
        state, info = self.new / ".exasolLauncherState.json", self.new / "deployment.json"
        state.write_text('{"deploymentId": "exa-state", "nested": {"deploymentId": "exa-deep"}}')
        info.write_text('{"deploymentId": "local"}')
        self.assertEqual("exa-state", _personal_folder_deployment_id(self.new))
        info.write_text('{"deploymentId": "exa-old"}')
        self.assertEqual("exa-state", _personal_folder_deployment_id(self.new))
        state.unlink()
        self.assertEqual("exa-old", _personal_folder_deployment_id(self.new))
        for text in ('{"deploymentId": "local"}', '{"deploymentId": "  "}', '{"connection": {"deploymentId": "x"}}',
                     '["deploymentId"]', 'not json'):
            info.write_text(text)
            self.assertEqual("", _personal_folder_deployment_id(self.new), text)
        state.write_text('{"currentWorkflowState": {}}')
        info.write_text('{"deploymentId": "exa-json"}')
        self.assertEqual("exa-json", _personal_folder_deployment_id(self.new))

    def test_the_guard_reads_the_state_not_a_contradicting_deployment_json(self) -> None:
        self.new.mkdir(parents=True)
        (self.new / ".exasolLauncherState.json").write_text('{"deploymentId": "exa-user"}')
        (self.new / "deployment.json").write_text('{"deploymentId": "exa-kit"}')
        self.assertIsNone(personal_deployment_dir(str(self.old), self.env, deployment_id="exa-kit"))
        (self.new / ".exasolLauncherState.json").write_text('{"deploymentId": "exa-kit"}')
        (self.new / "deployment.json").write_text('{"deploymentId": "local"}')
        self.assertEqual(self.new, personal_deployment_dir(str(self.old), self.env, deployment_id="exa-kit"))

    # --- the launcher's own list (exasol deployments list --json) ---------------------------------------------
    def launcher(self, answer: str | None, rc: int = 0) -> Path:
        """A stub launcher in EXAKIT_BIN_DIR: `deployments list --json` prints ``answer`` (exit ``rc``); with no
        answer the command is unknown, as to a 2.4.x launcher. Every call is logged in ``calls``."""
        bin_dir = self.root / "bin"
        bin_dir.mkdir(exist_ok=True)
        (self.root / "answer").write_text(answer or "")
        stub = bin_dir / "exasol"
        stub.write_text("#!/bin/sh\n"
                        'echo "$*" >> "%s"\n' % (self.root / "calls") +
                        ('[ "$1" = deployments ] && { cat "%s"; exit %d; }\n' % (self.root / "answer", rc) if answer is not None
                         else "") +
                        "echo 'Error: unknown command' >&2; exit 1\n")
        stub.chmod(0o755)
        self.env["EXAKIT_BIN_DIR"] = str(bin_dir)
        return stub

    def listed(self, *rows: tuple[str, Path, str]) -> str:
        return json.dumps([{"name": n, "path": str(p), "status": s, "infrastructure": "local", "installation": "local"}
                           for n, p, s in rows], indent=2)

    def calls(self) -> str:
        path = self.root / "calls"
        return path.read_text() if path.exists() else ""

    @unittest.skipIf(os.name == "nt", "a shell-script launcher")
    def test_the_launchers_list_is_read(self) -> None:
        custom = self.root / "profile" / ".exasol" / "somewhere-new" / "deployments" / "default"
        self.launcher(self.listed(("default", custom, "database_ready"), ("mine", self.root / "x", "stopped")))
        self.assertEqual([(custom, "database_ready"), (self.root / "x", "stopped")], personal_launcher_deployments(self.env))
        # In the launcher's own order: `default` is not put first (it is the user's, never the kit's by its place).
        self.launcher("Migrated managed deployments to somewhere\n" + self.listed(("other", self.old, "stopped"), ("default", custom, "")))
        self.assertEqual([(self.old, "stopped"), (custom, "")], personal_launcher_deployments(self.env))
        self.launcher("[]")
        self.assertEqual([], personal_launcher_deployments(self.env))

    @unittest.skipIf(os.name == "nt", "a shell-script launcher")
    def test_no_list_is_no_answer(self) -> None:
        self.assertIsNone(personal_launcher_deployments(dict(self.env, EXAKIT_BIN_DIR=str(self.root / "none"))))
        self.launcher(None)                                     # a 2.4.x launcher
        self.assertIsNone(personal_launcher_deployments(self.env))
        for answer, rc in (("Usage: exasol deployments list [flags]", 0), ('{"name": "default"}', 0),
                           ('[{"name": "default", "path": ', 0), (self.listed(("default", self.new, "stopped")), 1),
                           ('["just a string"]', 0)):
            self.launcher(answer, rc)
            self.assertIsNone(personal_launcher_deployments(self.env), answer)
        self.launcher(self.listed(("default", Path("relative/default"), "stopped")))
        self.assertEqual([], personal_launcher_deployments(self.env))

    @unittest.skipIf(os.name == "nt", "a shell-script launcher")
    def test_a_deployment_moved_where_the_launcher_lists_it_is_followed(self) -> None:
        custom = self.root / "profile" / ".exasol" / "somewhere-new" / "deployments" / "default"
        self.seed(custom, "exa-kit")    # a "2.6.0" moved the kit's 2.5 folder somewhere new
        self.launcher(self.listed(("default", custom, "stopped")))
        self.assertEqual(custom, personal_deployment_dir(str(self.new), self.env, deployment_id="exa-kit"))
        self.assertEqual(custom, personal_deployment_dir(str(self.old), self.env, deployment_id="exa-kit"))

    @unittest.skipIf(os.name == "nt", "a shell-script launcher")
    def test_the_users_own_deployment_the_launcher_lists_is_never_followed(self) -> None:
        custom = self.root / "profile" / ".exasol" / "somewhere-new" / "deployments" / "default"
        self.seed(custom, "exa-user")
        self.launcher(self.listed(("default", custom, "database_ready")))
        self.assertIsNone(personal_deployment_dir(str(self.new), self.env, deployment_id="exa-kit"))
        self.assertIsNone(personal_deployment_dir(str(self.new), self.env))

    @unittest.skipIf(os.name == "nt", "a shell-script launcher")
    def test_without_the_list_the_known_folders_are_followed(self) -> None:
        self.seed(self.new, "exa-kit")
        for answer in (None, "garbage"):
            self.launcher(answer)
            self.assertEqual(self.new, personal_deployment_dir(str(self.old), self.env, deployment_id="exa-kit"))

    @unittest.skipIf(os.name == "nt", "a shell-script launcher")
    def test_a_folder_on_disk_asks_no_launcher(self) -> None:
        self.seed(self.new, "exa-kit")
        self.launcher(self.listed(("default", self.new, "stopped")))
        self.assertEqual(self.new, personal_deployment_dir(str(self.new), self.env, deployment_id="exa-kit"))
        self.assertEqual("", self.calls())

    def scheduler_folder(self, runtime: dict) -> Path | None:
        home = self.root / "kit"
        home.mkdir(exist_ok=True)
        manifest = Manifest(home / "manifest.json")
        manifest.path.write_text(json.dumps({"runtime": dict({"type": "personal", "deployment_dir": str(self.old)}, **runtime)}))
        ctx = KitContext(ROOT, home, self.root / "bin", manifest, Path("uv"))
        environ = dict(os.environ, **self.env)
        environ.pop("EXAKIT_PERSONAL_DEPLOY_DIR", None)
        # No launcher of this machine's is asked: none in the bin folder, none on PATH.
        environ.setdefault("EXAKIT_BIN_DIR", str(self.root / "no-bin"))
        environ["PATH"] = os.pathsep.join(p for p in ("/usr/bin", "/bin") if Path(p).is_dir())
        with patch.dict(os.environ, environ, clear=True):
            return scheduler._deployment(ctx)

    def test_the_scheduler_writes_its_sidecar_into_the_moved_folder(self) -> None:
        self.seed(self.new, "exa-kit")
        self.assertEqual(self.new, self.scheduler_folder({"deployment_id": "exa-kit"}))

    def test_the_scheduler_never_writes_into_the_users_own_deployment(self) -> None:
        self.seed(self.new, "exa-user")
        self.assertIsNone(self.scheduler_folder({"deployment_id": "exa-kit"}))
        self.assertIsNone(self.scheduler_folder({}))

    def test_the_scheduler_follows_a_0_3_0_default_renamed_to_starter_kit_local(self) -> None:
        _, old_root = personal_deploy_roots(self.env)
        self.seed(self.new, "exa-kit")
        self.assertEqual(self.new, self.scheduler_folder({"deployment_id": "exa-kit",
                                                          "deployment_dir": str(old_root / "default")}))

    @unittest.skipIf(os.name == "nt", "mode P is macOS and Linux only")
    def test_the_scheduler_looks_in_the_recorded_launcher_home(self) -> None:
        private = self.root / "private-home"
        new = private / ".exasol" / "launcher" / "deployments" / "starter-kit-local"
        self.seed(new, "exa-kit")
        recorded = private / ".exasol" / "personal" / "deployments" / "starter-kit-local"
        self.assertEqual(new, self.scheduler_folder({"deployment_id": "exa-kit", "deployment_dir": str(recorded),
                                                     "launcher_home": str(private)}))


if __name__ == "__main__":
    unittest.main()
