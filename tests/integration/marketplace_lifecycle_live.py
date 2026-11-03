"""Exercise native add-on lifecycle commands in a disposable kit home."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import tempfile
from pathlib import Path

from marketplace_database_lifecycle import DatabaseChecks
from privacy_watch import PrivacyWatch, leftovers, paths

ROOT = Path(__file__).resolve().parents[2]
ADDONS = ("dbt-exasol", "json-tables", "dash-server", "notebook", "exasol-vscode", "exasol-scheduler", "udf-devkit")


def fixture_manifest(source: Path) -> dict:
    runtime = json.loads((source / "manifest.json").read_text())["runtime"]
    return {"runtime": {**runtime, "ownership": "user"}, "components": {},
            "autostart": {"enabled": False}}


def snapshot(folder: Path) -> dict[str, tuple[int, int] | None]:
    """Every file with its size and modification time, and every folder: a preview may change none of it."""
    return {str(path.relative_to(folder)): (path.stat().st_size, path.stat().st_mtime_ns) if path.is_file() else None
            for path in folder.rglob("*")}


def prefix() -> list[str]:
    if os.name == "nt":
        return ["powershell.exe", "-NoProfile", "-File", str(ROOT / "setup/exakit.ps1")]
    return ["bash", str(ROOT / "setup/exakit")]


def run(addons: list[str], source: Path, output: Path, *, approve_test_writes: bool = False,
        upgrades: dict[str, str] | None = None, baselines: dict[str, str] | None = None) -> dict:
    if set(addons) & {"exasol-scheduler", "udf-devkit"} and not approve_test_writes:
        raise RuntimeError("Scheduler/UDF checks need --approve-test-writes for isolated database test objects")
    versions = json.loads((ROOT / "versions.json").read_text())["components"]
    upgrades = dict(upgrades or {})
    baselines = baselines or {}
    for addon in baselines:
        if addon not in addons or addon == "udf-devkit":
            raise RuntimeError("Baseline versions must name selected package add-ons")
        upgrades.setdefault(addon, versions[addon]["version"])
    for addon, version in upgrades.items():
        baseline = baselines.get(addon, versions.get(addon, {}).get("version", ""))
        target = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", version)
        current = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", baseline)
        if addon not in addons or addon == "udf-devkit" or not target or not current or \
           tuple(map(int, target.groups())) <= tuple(map(int, current.groups())):
            raise RuntimeError("Upgrade targets must name selected package add-ons and a newer stable version")
    original = source / "manifest.json"
    digest = hashlib.sha256(original.read_bytes()).hexdigest()
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
    for addon in addons:
        env[f"EXAKIT_{addon.upper().replace('-', '_')}_VERSION"] = baselines.get(addon, versions[addon]["version"])
    database = DatabaseChecks(source, home, bin_dir, env, fixture, addons)
    watch = PrivacyWatch(source, home, bin_dir, fixture)
    manifest.write_text(json.dumps(fixture))
    report = {"ok": False, "platform": os.sys.platform, "home": str(home), "addons": {},
              "scope": "native install/reinstall/current-version update/preview/removal",
              "upgrade_targets": upgrades, "baseline_versions": baselines}
    captured: list[str] = []

    def command(*args: str, check: bool = True) -> subprocess.CompletedProcess:
        with watch.watching(" ".join(args)):
            result = subprocess.run([*prefix(), *args], env=env, capture_output=True,
                                    text=True, timeout=1200, stdin=subprocess.DEVNULL)
        captured.extend((result.stdout, result.stderr))
        watch.scan_text(" ".join(args), "command output", result.stdout + result.stderr)
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
            database.before_install(addon, command)
            before = paths(home) | {"bin/" + item for item in paths(bin_dir)}
            command("marketplace", addon)
            watch.scan_files(f"{addon} installed")
            first = json.loads(manifest.read_text())["components"].get(key, {})
            if first.get("ownership") != "kit":
                raise RuntimeError(f"{addon} did not produce a kit-owned receipt")
            if first.get("validated") is not True:
                raise RuntimeError(f"{addon} did not validate its native installation")
            database.after_install(addon, command)
            personal_dir = home
            if addon == "notebook":
                personal_dir = Path(first["notebooks_dir"])
            elif addon == "dbt-exasol":
                personal_dir = Path(first["profiles_dir"])
            elif addon == "dash-server":
                personal_dir = Path(first["instance"])
            elif addon == "udf-devkit":
                personal_dir = home / "rust-udfs"
            personal_dir.mkdir(parents=True, exist_ok=True)
            sentinel = personal_dir / "personal work.txt"
            sentinel.write_text("Keep my personal work.\n")
            command("marketplace", addon)
            command("update", addon)
            current = json.loads(manifest.read_text())["components"][key]
            if current.get("version") != first["version"]:
                raise RuntimeError(f"{addon} unexpectedly changed version")
            if addon in upgrades:
                env[f"EXAKIT_{addon.upper().replace('-', '_')}_VERSION"] = upgrades[addon]
                print(f"{addon}: upgrade to {upgrades[addon]}", flush=True)
                command("update", addon)
                current = json.loads(manifest.read_text())["components"][key]
                if str(current.get("version", "")).removeprefix("v") != upgrades[addon].removeprefix("v") or \
                   current.get("validated") is not True:
                    raise RuntimeError(f"{addon} did not validate its upgraded native installation")
                row.update({"upgrade_from": first["version"], "upgrade_to": current["version"]})
            if sentinel.read_text() != "Keep my personal work.\n":
                raise RuntimeError(f"{addon} update changed personal work")
            state = snapshot(home)
            state_bin = snapshot(bin_dir)
            command("uninstall", addon, "--dry-run")
            command("uninstall", "--dry-run")
            # A running service writes its own log on its own schedule (the Scheduler logs every task run, here every
            # ten seconds): that file changing is the service at work, not the preview. Every log a command writes -
            # install-*.log, marketplace.log, the lock - stays in the comparison.
            service_log = str(Path("logs") / f"{addon}.log")
            changed = sorted(item for item in set(state.items()) ^ set(snapshot(home).items()) if item[0] != service_log)
            changed += sorted(set(state_bin.items()) ^ set(snapshot(bin_dir).items()))
            if changed:
                raise RuntimeError(f"{addon} preview changed {', '.join(sorted({str(item[0]) for item in changed}))}")
            print(f"{addon}: remove and repeat removal", flush=True)
            database.before_uninstall(addon, command)
            command("uninstall", addon, "--yes")
            command("uninstall", addon, "--yes")
            database.after_uninstall(addon, command)
            if key in json.loads(manifest.read_text()).get("components", {}):
                raise RuntimeError(f"{addon} receipt remains after removal")
            watch.scan_files(f"{addon} removed")
            # Dashboards, notebooks and Rust UDF sources are the user's work: removal keeps them by design.
            kept = personal_dir if addon in ("dash-server", "notebook", "udf-devkit") else sentinel
            kept = [kept.relative_to(home).as_posix() + ("/" if kept.is_dir() else "")] if kept.is_relative_to(home) else []
            left = leftovers(before, paths(home) | {"bin/" + item for item in paths(bin_dir)}, kept)
            row["leftovers"] = left
            if left:
                raise RuntimeError(f"{addon} removal left {', '.join(left[:10])}")
            if sentinel.read_text() != "Keep my personal work.\n":
                raise RuntimeError(f"{addon} removed personal work")
            for field in ("venv", "command", "engine", "store_file", "master_file"):
                value = current.get(field)
                if value and Path(value).is_relative_to(base) and Path(value).exists():
                    raise RuntimeError(f"{addon} left its generated {field}")
            row.update({"ok": True, "version": first["version"], "install_twice": True,
                        "current_update": True, "preview_changed_nothing": True,
                        "uninstall_twice": True, "personal_file_preserved": True})
            row.update(database.evidence.get(addon, {}))
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
        try:
            database.cleanup(command)
        except (OSError, RuntimeError, subprocess.TimeoutExpired):
            report["cleanup_required"] = True
            report["ok"] = False
        report["original_manifest_unchanged"] = digest == hashlib.sha256(original.read_bytes()).hexdigest()
        report["ok"] &= report["original_manifest_unchanged"]
        report["privacy"] = {"findings": watch.findings, "process_samples": watch.samples}
        report["ok"] &= not watch.findings
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
    parser.add_argument("--approve-test-writes", action="store_true")
    parser.add_argument("--upgrade", action="append", default=[], metavar="ADDON=VERSION")
    parser.add_argument("--baseline", action="append", default=[], metavar="ADDON=VERSION")
    args = parser.parse_args()
    targets = {"upgrade": {}, "baseline": {}}
    for kind in targets:
        for value in getattr(args, kind):
            addon, separator, version = value.partition("=")
            if not separator or addon in targets[kind]:
                parser.error(f"--{kind} requires one ADDON=VERSION per target")
            targets[kind][addon] = version
    report = run(args.addons, args.source_home, args.output,
                 approve_test_writes=args.approve_test_writes,
                 upgrades=targets["upgrade"], baselines=targets["baseline"])
    print(json.dumps(report, indent=2))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
