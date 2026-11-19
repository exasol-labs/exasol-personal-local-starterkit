"""The Exasol Scheduler as an Exasol Personal sidecar (launcher 2.4.0+).

Dormant until versions.json pins a scheduler image by digest
(components.exasol-scheduler.image): until then every path is the native engine
under the kit's supervisor, exactly as before. With the pin and a launcher that
has sidecars, the engine runs as the deployment's `exasol-scheduler` sidecar,
connected as scheduler_svc (never SYS), and the same add-on functions - install,
status, start, stop, update, uninstall - drive it through the launcher.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
from addons import exasol_scheduler as scheduler  # noqa: E402
from runtime import KitContext, Manifest  # noqa: E402

IMAGE = "ghcr.io/exasol-labs/exasol-scheduler:0.5.0@sha256:" + "a" * 64


class SchedulerSidecarTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        base = Path(self.temp.name)
        self.home = base / "kit"
        self.home.mkdir()
        self.deployment = base / "deployment"
        self.deployment.mkdir()
        self.launcher = base / "exasol"
        self.launcher.write_text("#!/bin/sh\n", encoding="utf-8")
        self.manifest = Manifest(self.home / "manifest.json")
        self.manifest.path.write_text(json.dumps({
            "runtime": {"type": "personal", "dsn": "127.0.0.1:8563", "deployment_dir": str(self.deployment)},
            "components": {"personal": {"ownership_path": str(self.launcher)}}}))
        self.ctx = KitContext(ROOT, self.home, base / "bin", self.manifest, Path("uv"))
        self.calls: list[tuple[str, ...]] = []
        self.status = {"running": True}
        self.definitions: list[dict] = []

    def tearDown(self) -> None:
        self.temp.cleanup()

    def versions(self, image: str | None) -> dict:
        block = {"version": "0.5.0"}
        if image:
            block["image"] = image
        return {"components": {"exasol-scheduler": block}}

    def launch(self, _ctx, *args, timeout=300):
        self.calls.append(args)
        stdout = "  sidecar   Manage sidecars\n" if args == ("--help",) else json.dumps(self.status)
        return subprocess.CompletedProcess(args, 0, stdout=stdout, stderr="")

    def edit(self, _ctx, command, *rest):
        self.calls.append(("editor", command))
        if command == "put":
            self.definitions.append(json.loads(Path(rest[0]).read_text(encoding="utf-8")))
        return "changed"

    def patches(self, image: str | None = IMAGE):
        return (patch.object(KitContext, "versions_document", return_value=self.versions(image)),
                patch.object(scheduler, "_launch", side_effect=self.launch),
                patch.object(scheduler, "_edit_sidecars", side_effect=self.edit),
                patch.object(scheduler, "_user", return_value=("SCHEDULER_SVC", "SCHED", True)))

    def test_without_an_image_pin_nothing_changes(self) -> None:
        with patch.object(KitContext, "versions_document", return_value=self.versions(None)):
            self.assertFalse(scheduler._sidecar_mode(self.ctx))
        self.assertEqual(scheduler.autostart_command(self.ctx), [str(scheduler.paths(self.ctx)[1])])

    def test_host_backend_can_be_kept(self) -> None:
        with self.patches()[0], patch.dict("os.environ", {"EXAKIT_EXASOL_SCHEDULER_BACKEND": "host"}):
            self.assertFalse(scheduler._sidecar_mode(self.ctx))

    def test_install_writes_the_scheduler_user_never_sys_and_reconciles(self) -> None:
        first, second, third, fourth = self.patches()
        with first, second, third, fourth:
            scheduler.install(self.ctx)
        definition = self.definitions[0]
        env = {item["name"]: item for item in definition["container"]["env"]}
        self.assertEqual(definition["container"]["image"], IMAGE)
        self.assertEqual(env["EXA_USER"], {"name": "EXA_USER", "value": "SCHEDULER_SVC"})
        self.assertEqual(env["EXA_PASSWORD"], {"name": "EXA_PASSWORD",
                                               "valueFile": str(scheduler.paths(self.ctx)[4])})
        self.assertNotIn("username", json.dumps(definition))
        self.assertIn(("start",), self.calls)
        self.assertEqual(self.manifest.get("components.exasol_scheduler.backend"), "sidecar")
        self.assertEqual(scheduler.installed_version(self.ctx), "0.5.0")
        self.assertIsNone(scheduler.autostart_command(self.ctx))

    def test_status_start_stop_and_uninstall_go_through_the_launcher(self) -> None:
        self.manifest.set_many({"components.exasol_scheduler.backend": "sidecar",
                                "components.exasol_scheduler.version": "0.5.0",
                                "components.exasol_scheduler.ownership": "kit"})
        first, second, third, fourth = self.patches()
        with first, second, third, fourth:
            self.assertEqual(scheduler.status(self.ctx), "running")
            self.status = {"running": False, "error": "image pull failed"}
            self.assertIn("image pull failed", scheduler.status(self.ctx))
            scheduler.start(self.ctx)
            scheduler.stop(self.ctx)
            with patch.object(scheduler, "_sql", return_value="EXAKIT_SCHED_NO_OTHER_SCHEMAS"):
                scheduler.uninstall(self.ctx)
        self.assertIn(("sidecar", "enable", "exasol-scheduler"), self.calls)
        self.assertIn(("sidecar", "disable", "exasol-scheduler"), self.calls)
        self.assertIn(("sidecar", "disable", "exasol-scheduler", "--remove"), self.calls)


if __name__ == "__main__":
    unittest.main()
