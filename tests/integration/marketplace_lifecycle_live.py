"""Exercise native add-on lifecycle commands in a disposable kit home."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shlex
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADDONS = ("dbt-exasol", "json-tables", "dash-server", "notebook", "exasol-vscode")


def fixture_manifest(source: Path) -> dict:
    runtime = json.loads((source / "manifest.json").read_text())["runtime"]
    return {"runtime": {**runtime, "ownership": "user"}, "components": {},
            "autostart": {"enabled": False}}


def snapshot(folder: Path) -> dict[str, tuple[int, int]]:
    return {str(path.relative_to(folder)): (path.stat().st_size, path.stat().st_mtime_ns)
            for path in folder.rglob("*") if path.is_file()
            and "logs" not in path.relative_to(folder).parts
            and path.name != "manifest.json.lock"}


def prefix() -> list[str]:
    if os.name == "nt":
        return ["powershell.exe", "-NoProfile", "-File", str(ROOT / "setup/exakit.ps1")]
    return ["bash", str(ROOT / "setup/exakit")]


def run(addons: list[str], source: Path, output: Path) -> dict:
    original = source / "manifest.json"
    before = hashlib.sha256(original.read_bytes()).hexdigest()
    fixture = fixture_manifest(source)
    runtime = fixture["runtime"]
    base = Path(tempfile.mkdtemp(prefix="exakit lifecycle "))
    base.chmod(0o700)
    home, bin_dir = base / "kit home", base / "kit bin"
    home.mkdir()
    bin_dir.mkdir()
    command_log = base / "commands.log"
    command_log.touch(mode=0o600)
    uv = shutil.which("uv")
    if not uv:
        raise RuntimeError("Install uv before running native lifecycle checks")
    private_uv = bin_dir / Path(uv).name
    if os.name == "nt":
        shutil.copy2(uv, private_uv)
    else:
        private_uv.symlink_to(uv)
    manifest = home / "manifest.json"
    # The fixture borrows connection paths; it owns no database or core tools.
    manifest.write_text(json.dumps(fixture))
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("EXAKIT_", "DASH_SERVER_", "JUPYTER_", "DBT_", "EXA_"))}
    env.update({"EXAKIT_HOME": str(home), "EXAKIT_BIN_DIR": str(bin_dir),
                "PATH": os.pathsep.join([str(bin_dir), *[
                    entry for entry in os.environ.get("PATH", "").split(os.pathsep)
                    if entry and Path(entry) != Path(uv).parent
                    and not Path(entry).is_relative_to(source)]]),
                "EXAKIT_VERSION_POLICY": "pinned", "EXAKIT_NO_UPDATE_NOTICE": "1",
                "EXAKIT_NO_FANCY": "1", "EXAKIT_SKIP_MCP": "1",
                "EXAKIT_SKILL_ROOTS": str(base / "skills") if os.name == "nt" else shlex.quote(str(base / "skills")),
                "EXAKIT_LAUNCHAGENT_DIR": str(base / "launch agents"),
                "EXAKIT_STARTUP_DIR": str(base / "startup"),
                "EXAKIT_SYSTEMD_USER_DIR": str(base / "systemd"),
                "EXAKIT_EXASOL_VSCODE_EXTDIR": str(base / "extensions"),
                "EXAKIT_NOTEBOOK_FRONTENDS": "jupyterlab,marimo",
                "JUPYTER_DATA_DIR": str(base / "jupyter data"),
                "JUPYTER_CONFIG_DIR": str(base / "jupyter config"),
                "JUPYTER_RUNTIME_DIR": str(base / "jupyter runtime")})
    versions = json.loads((ROOT / "versions.json").read_text())["components"]
    for addon in addons:
        env[f"EXAKIT_{addon.upper().replace('-', '_')}_VERSION"] = versions[addon]["version"]
    report = {"ok": False, "platform": os.sys.platform, "home": str(home), "addons": {},
              "scope": "native install/reinstall/current-version update/preview/removal; no version upgrade"}
    captured: list[str] = []

    def command(*args: str, check: bool = True) -> subprocess.CompletedProcess:
        result = subprocess.run([*prefix(), *args], env=env, capture_output=True,
                                text=True, timeout=1200, stdin=subprocess.DEVNULL)
        captured.extend((result.stdout, result.stderr))
        with command_log.open("a") as handle:
            handle.write(f"{args!r}: exit {result.returncode}\n{result.stdout}\n{result.stderr}\n")
        if check and result.returncode:
            raise RuntimeError(f"{' '.join(args)} exited {result.returncode}; see private commands.log")
        return result

    try:
        for addon in addons:
            print(f"{addon}: install, repeat, update and preview", flush=True)
            row: dict = {"ok": False}
            report["addons"][addon] = row
            key = addon.replace("-", "_")
            command("marketplace", addon)
            first = json.loads(manifest.read_text())["components"].get(key, {})
            if first.get("ownership") != "kit":
                raise RuntimeError(f"{addon} did not produce a kit-owned receipt")
            if first.get("validated") is not True:
                raise RuntimeError(f"{addon} did not validate its native installation")
            command("marketplace", addon)
            command("update", addon)
            current = json.loads(manifest.read_text())["components"][key]
            if current.get("version") != first["version"]:
                raise RuntimeError(f"{addon} unexpectedly changed version")
            sentinel = home / "personal notes.txt"
            sentinel.write_text("Keep my personal work.\n")
            if addon == "notebook":
                sentinel = Path(current["notebooks_dir"]) / "personal notebook.txt"
                sentinel.write_text("Keep my personal work.\n")
            if addon == "dbt-exasol":
                sentinel = Path(current["profiles_dir"]) / "personal profile.txt"
                sentinel.write_text("Keep my personal work.\n")
            state = snapshot(home)
            state_bin = snapshot(bin_dir)
            command("uninstall", addon, "--dry-run")
            if state != snapshot(home) or state_bin != snapshot(bin_dir):
                raise RuntimeError(f"{addon} preview changed resources outside its logs")
            print(f"{addon}: remove and repeat removal", flush=True)
            command("uninstall", addon, "--yes")
            command("uninstall", addon, "--yes")
            if key in json.loads(manifest.read_text()).get("components", {}):
                raise RuntimeError(f"{addon} receipt remains after removal")
            if sentinel.read_text() != "Keep my personal work.\n":
                raise RuntimeError(f"{addon} removed personal work")
            for field in ("venv", "command", "engine", "store_file", "master_file"):
                value = current.get(field)
                if value and Path(value).is_relative_to(base) and Path(value).exists():
                    raise RuntimeError(f"{addon} left its generated {field}")
            row.update({"ok": True, "version": first["version"], "install_twice": True,
                        "current_update": True, "preview_preserved_resources": True,
                        "uninstall_twice": True, "personal_file_preserved": True})
        report["ok"] = True
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        report["error"] = str(error)
    finally:
        # Only receipts created in this disposable home are eligible for cleanup.
        for addon in addons:
            if json.loads(manifest.read_text()).get("components", {}).get(addon.replace("-", "_"), {}).get("ownership") == "kit":
                try:
                    command("uninstall", addon, "--dry-run")
                    command("uninstall", addon, "--yes")
                except (OSError, RuntimeError, subprocess.TimeoutExpired):
                    report["cleanup_required"] = True
                    report["ok"] = False
        report["original_manifest_unchanged"] = before == hashlib.sha256(original.read_bytes()).hexdigest()
        report["ok"] &= report["original_manifest_unchanged"]
        credential = Path(runtime.get("password_file", ""))
        if credential.is_file():
            secret = credential.read_text().strip()
            # Short passwords can occur in package names; use synthetic privacy tests for those.
            if len(secret) >= 12:
                report["credential_absent_from_output"] = all(secret not in text for text in captured)
                report["ok"] &= report["credential_absent_from_output"]
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, indent=2) + "\n")
        output.chmod(0o600)
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("addons", nargs="+", choices=ADDONS)
    parser.add_argument("--source-home", type=Path, default=Path.home() / ".exasol-starter-kit")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = run(args.addons, args.source_home, args.output)
    print(json.dumps(report, indent=2))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
