"""Bash and PowerShell resolve the same scripted catalog selections."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class SelectionParityTest(unittest.TestCase):
    def test_named_csv_all_none_and_hidden_ids_match(self):
        with tempfile.TemporaryDirectory(prefix="marketplace selection ") as folder:
            base = Path(folder)
            checkout = base / "candidate"
            shutil.copytree(ROOT / "marketplace", checkout / "marketplace",
                            ignore=shutil.ignore_patterns("__pycache__"))
            shutil.copy2(ROOT / "versions.json", checkout / "versions.json")
            path = checkout / "marketplace/catalog.json"
            catalog = json.loads(path.read_text())
            next(row for row in catalog["addons"] if row["id"] == "notebook")["visible"] = False
            path.write_text(json.dumps(catalog))
            home, capture = base / "kit", base / "selected.txt"
            home.mkdir()
            (home / "manifest.json").write_text('{}')
            scripts = []
            if os.name != "nt" and shutil.which("bash"):
                scripts.append(["bash", "-c",
                    f'. "{ROOT / "setup/lib/common.sh"}"\n'
                    f'_exakit_marketplace_root() {{ printf "%s\\n" "{checkout}"; }}\n'
                    '_exakit_marketplace_python_hooks\n'
                    'exakit_marketplace_addon_installed() { return 1; }\n'
                    '_exakit_addon_system_present() { return 1; }\n'
                    '_exakit_addon_applicable() { return 0; }\n'
                    '_exakit_marketplace_apply() { printf "%s" "$1" > "$EXAKIT_TEST_CAPTURE"; }\n'
                    'exakit_marketplace_menu\n'])
            hosts = ("powershell", "pwsh") if os.name == "nt" else ("pwsh",)
            for host in hosts:
                if not shutil.which(host):
                    continue
                scripts.append([host, "-NoProfile", "-Command",
                    f'. "{ROOT / "setup/lib/exakit-common.ps1"}"\n'
                    f'function Get-ExakitMarketplaceRoot {{ return "{checkout}" }}\n'
                    f'function Get-ExakitPersonaPython {{ return "{sys.executable}" }}\n'
                    'Initialize-ExakitMarketplacePythonHooks\n'
                    'function Test-ExakitMarketplaceAddonInstalled { return $false }\n'
                    'function Test-ExakitAddonSystemPresent { return $false }\n'
                    'function Test-ExakitAddonApplicable { return $true }\n'
                    'function Invoke-ExakitMarketplaceApply { param([string[]]$Ids) '
                    '[IO.File]::WriteAllText($env:EXAKIT_TEST_CAPTURE, ($Ids -join ",")) }\n'
                    'Show-ExakitMarketplaceMenu\n'])
            self.assertTrue(scripts, "No supported shell is available")
            visible = [row["id"] for row in catalog["addons"] if row["visible"]]
            for answer, expected in (("dash-server", ["dash-server"]),
                                     ("dash-server,notebook,dbt-exasol", ["dash-server", "dbt-exasol"]),
                                     ("all", visible), ("none", []), ("notebook", [])):
                for script in scripts:
                    with self.subTest(host=script[0], answer=answer):
                        capture.write_text("")
                        env = {**os.environ, "EXAKIT_HOME": str(home), "EXAKIT_BIN_DIR": str(base / "bin"),
                               "EXAKIT_MARKETPLACE_ADDONS": answer, "EXAKIT_MARKETPLACE_ONLY": "",
                               "EXAKIT_NO_FANCY": "1", "EXAKIT_ABOUT_OFFLINE": "1",
                               "EXAKIT_VERSION_POLICY": "pinned", "EXAKIT_TEST_CAPTURE": str(capture)}
                        result = subprocess.run(script, env=env, capture_output=True, text=True, timeout=30)
                        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
                        selected = capture.read_text().strip()
                        self.assertEqual(expected, selected.split(",") if selected else [])
                        self.assertEqual({}, json.loads((home / "manifest.json").read_text()))


if __name__ == "__main__":
    unittest.main()
