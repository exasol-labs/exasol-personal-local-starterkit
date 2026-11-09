"""Installed shell entry points usable on the current test host."""

import os
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def entrypoints() -> list[list[str]]:
    commands = []
    if os.name != "nt" and shutil.which("bash"):
        commands.append(["bash", str(ROOT / "setup/exakit")])
    for shell in (("powershell", "pwsh") if os.name == "nt" else ("pwsh",)):
        if shutil.which(shell):
            commands.append([shell, "-NoProfile", "-File", str(ROOT / "setup/exakit.ps1")])
    return commands
