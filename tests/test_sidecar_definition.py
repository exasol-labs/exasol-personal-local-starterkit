"""setup/lib/sidecar_definition.py: the kit's edits to a deployment's sidecars.yaml.

The launcher owns the file (mode 0600, written by Go's yaml.v3) and keeps the
user's own sidecars in it, so an edit must change only the named sidecar, keep
the value types the launcher wrote (a quoted "4896" stays a string, a port stays
a number), keep the mode, and never print a value. Skipped where PyYAML is not
installed: the kit itself runs the editor with a pinned PyYAML through uv.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
EDITOR = ROOT / "setup" / "lib" / "sidecar_definition.py"

try:
    import yaml
except ImportError:  # pragma: no cover - depends on the machine
    yaml = None

# What the launcher writes after `exasol sidecar enable mcp`, plus a sidecar of the user's own.
LAUNCHER_FILE = """version: 1
sidecars:
    mine:
        enabled: true
        container:
            image: example.org/mine:1
    mcp:
        enabled: true
        container:
            image: docker.io/exasol/mcp-server:2.2.0@sha256:2f27525e93d3e117e7ae0d8512bbacb19d083cff66d001c0642681f29eba547f
            args:
                - --port
                - "4896"
            env:
                - name: EXA_USER
                  valueFrom:
                    secretKeyRef:
                        name: exasol-database
                        key: username
                - name: EXA_SSL_CERT_VALIDATION
                  value: "false"
            ports:
                - name: mcp
                  containerPort: 4896
                  hostPort: 4896
"""


@unittest.skipIf(yaml is None, "PyYAML is not installed here")
class SidecarDefinitionEditorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp(prefix="sidecar-def-"))
        self.file = self.dir / "sidecars.yaml"
        self.file.write_text(LAUNCHER_FILE, encoding="utf-8")
        self.file.chmod(0o600)
        self.secret = self.dir / "pw"
        self.secret.write_text("readonly-secret\n", encoding="utf-8")

    def tearDown(self) -> None:
        shutil.rmtree(self.dir, ignore_errors=True)

    def run_editor(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(EDITOR), *args], capture_output=True, text=True, check=False)

    def doc(self) -> dict:
        return yaml.safe_load(self.file.read_text(encoding="utf-8"))

    def test_literal_env_swaps_the_reference_for_the_value_and_only_once(self) -> None:
        first = self.run_editor("literal-env", str(self.file), "mcp", "EXA_USER=mcp_readonly",
                                f"EXA_PASSWORD=@{self.secret}")
        self.assertEqual(first.stdout.strip(), "changed")
        env = {e["name"]: e for e in self.doc()["sidecars"]["mcp"]["container"]["env"]}
        self.assertEqual(env["EXA_USER"], {"name": "EXA_USER", "value": "mcp_readonly"})
        self.assertEqual(env["EXA_PASSWORD"]["value"], "readonly-secret")
        again = self.run_editor("literal-env", str(self.file), "mcp", "EXA_USER=mcp_readonly",
                                f"EXA_PASSWORD=@{self.secret}")
        self.assertEqual(again.stdout.strip(), "unchanged")
        self.assertNotIn("readonly-secret", first.stdout + first.stderr + again.stdout + again.stderr)

    def test_types_the_user_sidecar_and_the_mode_survive(self) -> None:
        self.run_editor("literal-env", str(self.file), "mcp", "EXA_USER=mcp_readonly")
        doc = self.doc()
        self.assertEqual(doc["sidecars"]["mine"], {"enabled": True, "container": {"image": "example.org/mine:1"}})
        container = doc["sidecars"]["mcp"]["container"]
        self.assertEqual(container["args"], ["--port", "4896"])
        self.assertEqual(container["ports"][0]["hostPort"], 4896)
        env = {e["name"]: e for e in container["env"]}
        self.assertEqual(env["EXA_SSL_CERT_VALIDATION"]["value"], "false")
        if os.name != "nt":
            self.assertEqual(stat.S_IMODE(self.file.stat().st_mode), 0o600)

    def test_put_resolves_value_files_and_drop_removes_only_that_sidecar(self) -> None:
        definition = self.dir / "def.json"
        definition.write_text(json.dumps({"enabled": True, "container": {
            "image": "x:1", "env": [{"name": "EXA_PASSWORD", "valueFile": str(self.secret)}]}}), encoding="utf-8")
        put = self.run_editor("put", str(self.file), "mcp", str(definition))
        self.assertEqual(put.stdout.strip(), "changed")
        self.assertEqual(self.doc()["sidecars"]["mcp"]["container"]["env"],
                         [{"name": "EXA_PASSWORD", "value": "readonly-secret"}])
        self.assertEqual(self.run_editor("put", str(self.file), "mcp", str(definition)).stdout.strip(), "unchanged")
        self.assertEqual(self.run_editor("drop", str(self.file), "mcp").stdout.strip(), "changed")
        self.assertEqual(list(self.doc()["sidecars"]), ["mine"])

    def test_an_unknown_sidecar_is_refused_with_exit_2(self) -> None:
        result = self.run_editor("literal-env", str(self.file), "nope", "X=1")
        self.assertEqual(result.returncode, 2)

    def test_a_missing_file_is_created_with_only_the_kit_sidecar(self) -> None:
        self.file.unlink()
        definition = self.dir / "def.json"
        definition.write_text(json.dumps({"enabled": True, "container": {"image": "x:1"}}), encoding="utf-8")
        self.run_editor("put", str(self.file), "mcp", str(definition))
        self.assertEqual(self.doc(), {"version": 1, "sidecars": {"mcp": {"enabled": True, "container": {"image": "x:1"}}}})


if __name__ == "__main__":
    unittest.main()
