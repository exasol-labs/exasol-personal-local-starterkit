"""Run the kit's dbt adapter with its own profile and delegated credentials."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path


def main() -> int:
    home = Path(os.environ.get("EXAKIT_HOME", str(Path.home() / ".exasol-starter-kit")))
    doc = json.loads((home / "manifest.json").read_text(encoding="utf-8"))
    paths = doc["components"]["dbt_exasol"]
    credential = Path(doc["runtime"]["password_file"])
    env = dict(os.environ)
    env.setdefault("DBT_ENV_SECRET_EXASOL_PASSWORD", credential.read_text(encoding="utf-8").strip())
    env.setdefault("DBT_PROFILES_DIR", paths["profiles_dir"])
    dbt = Path(paths["venv"]) / ("Scripts/dbt.exe" if os.name == "nt" else "bin/dbt")
    return subprocess.call([str(dbt), *sys.argv[1:]], env=env)


if __name__ == "__main__":
    raise SystemExit(main())
