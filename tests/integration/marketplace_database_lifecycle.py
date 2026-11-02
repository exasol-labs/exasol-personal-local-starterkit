"""Database assertions and cleanup for the disposable marketplace fixture."""

from __future__ import annotations

import json
import os
import shlex
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class DatabaseChecks:
    def __init__(self, source: Path, home: Path, bin_dir: Path, env: dict, fixture: dict, addons: list[str]):
        self.home = home
        self.env = env
        self.schema = "EXAKIT_LC_" + uuid.uuid4().hex[:12].upper()
        self.user = self.schema + "_SVC"
        self.scheduler_created = False
        self.history = 0
        self.evidence: dict[str, dict] = {}
        self.aliases: set[str] = set()
        self.guard: Path | None = None
        self.denied = home.parent / "runtime-change-refused"
        original = json.loads((source / "manifest.json").read_text())
        if "udf-devkit" in addons:
            personal = original["components"]["personal"]["ownership_path"]
            guard_script = Path(__file__).with_name("personal_readonly_guard.py")
            self.guard = bin_dir / ("exasol-query.cmd" if os.name == "nt" else "exasol-query")
            argv = [sys.executable, str(guard_script), personal, str(self.denied)]
            if os.name == "nt":
                self.guard.write_text("@echo off\r\n" + subprocess.list2cmdline(argv) + " %*\r\n")
            else:
                self.guard.write_text("#!/bin/sh\nexec " + shlex.join(argv) + ' "$@"\n')
                self.guard.chmod(0o755)
            fixture["components"]["personal"] = {"ownership": "user", "ownership_path": str(self.guard)}
            fixture["components"]["pyexasol"] = {**original["components"]["pyexasol"], "ownership": "user"}
            env["EXAKIT_PERSONAL_BIN"] = str(self.guard)
            self.deployment = original["runtime"]["deployment_dir"]
            overlay = source / "rust-udfs/.container"
            if overlay.is_dir():
                shutil.copytree(overlay, home / "rust-udfs/.container")
        if "exasol-scheduler" not in addons:
            return
        exapump = original["components"]["exapump"]
        binary = exapump.get("path") or exapump["ownership_path"]
        fixture["components"]["exapump"] = {"path": binary, "ownership": "user",
                                              "version": exapump["version"]}
        profiles = home / "exapump"
        profiles.mkdir()
        shutil.copy2(source / "exapump/config.toml", profiles / "config.toml")
        (profiles / "config.toml").chmod(0o600)
        env.update({"EXAKIT_EXAPUMP_BIN": binary,
                    "EXAPUMP_CONFIG": str(profiles / "config.toml"),
                    "EXAKIT_EXASOL_SCHEDULER_SCHEMA": self.schema,
                    "EXAKIT_EXASOL_SCHEDULER_USER": self.user})

    @staticmethod
    def query(command, sql: str) -> list[dict]:
        result = json.loads(command("sql", "--json", sql).stdout)
        if not result.get("ok"):
            raise RuntimeError("Lifecycle verification query failed")
        return result["rows"]

    def before_install(self, addon: str, command) -> None:
        if addon == "udf-devkit":
            self.aliases = self.read_aliases()
            if not {"PYTHON3", "PYTHON3_ML", "RUST"} <= self.aliases:
                raise RuntimeError("Install Python, ML and Rust runtimes before the UDF reuse check")
        if addon != "exasol-scheduler":
            return
        schemas = self.query(command, f"SELECT COUNT(*) AS N FROM EXA_SCHEMAS WHERE SCHEMA_NAME='{self.schema}'")[0]["N"]
        users = self.query(command, f"SELECT COUNT(*) AS N FROM EXA_DBA_USERS WHERE USER_NAME='{self.user}'")[0]["N"]
        if schemas or users:
            raise RuntimeError("The generated Scheduler test namespace already exists")
        self.scheduler_created = True

    def after_install(self, addon: str, command) -> None:
        if addon != "exasol-scheduler":
            return
        sql = (f'INSERT INTO {self.schema}.SCHED_TASKS ("TASK_ID","ENABLED","SCHEDULE","SQL_TEXT") '
               "VALUES ('lifecycle_smoke',TRUE,'CRON */10 * * * * * TZ=UTC','SELECT 1')")
        print(sql, flush=True)
        command("sql", "--write", sql)
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            rows = self.query(command, f'SELECT "STATUS" FROM {self.schema}.SCHED_HISTORY '
                              'WHERE "TASK_ID"=\'lifecycle_smoke\' ORDER BY "STARTED_AT" DESC LIMIT 1')
            if rows:
                if rows[0]["STATUS"] != "SUCCEEDED":
                    raise RuntimeError("The isolated Scheduler task failed")
                break
            time.sleep(2)
        else:
            raise RuntimeError("The isolated Scheduler task did not run")
        privileges = self.query(command, f"SELECT PRIVILEGE FROM EXA_DBA_SYS_PRIVS WHERE GRANTEE='{self.user}'")
        if [row["PRIVILEGE"] for row in privileges] != ["CREATE SESSION"]:
            raise RuntimeError("Scheduler bootstrap privileges remain")

    def before_uninstall(self, addon: str, command) -> None:
        if addon == "exasol-scheduler":
            self.history = self.query(command, f"SELECT COUNT(*) AS N FROM {self.schema}.SCHED_HISTORY")[0]["N"]

    def after_uninstall(self, addon: str, command) -> None:
        if addon == "udf-devkit":
            if self.denied.exists():
                raise RuntimeError("UDF reuse attempted a runtime change; the acceptance guard refused it")
            if self.aliases != self.read_aliases():
                raise RuntimeError("UDF add-on removal changed installed runtime aliases")
            self.evidence[addon] = {"runtime_aliases_preserved": sorted(self.aliases),
                                    "runtime_changes_refused": True}
        if addon != "exasol-scheduler":
            return
        self.assert_scheduler_preserved(command)
        previous = self.query(command, f"SELECT COUNT(*) AS N FROM {self.schema}.SCHED_HISTORY")[0]["N"]
        command("marketplace", addon)
        receipt = json.loads((self.home / "manifest.json").read_text())["components"]["exasol_scheduler"]
        if receipt.get("validated") is not True:
            raise RuntimeError("Scheduler reinstall could not use its preserved schema")
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            total = self.query(command, f"SELECT COUNT(*) AS N FROM {self.schema}.SCHED_HISTORY")[0]["N"]
            if total > previous:
                status = self.query(command, f'SELECT "STATUS" FROM {self.schema}.SCHED_HISTORY '
                                    'ORDER BY "STARTED_AT" DESC LIMIT 1')[0]["STATUS"]
                if status != "SUCCEEDED":
                    raise RuntimeError("The preserved Scheduler task failed after reinstall")
                break
            time.sleep(2)
        else:
            raise RuntimeError("Scheduler reinstall did not execute its preserved task")
        command("uninstall", addon, "--dry-run")
        command("uninstall", addon, "--yes")
        command("uninstall", addon, "--yes")
        self.assert_scheduler_preserved(command)
        self.evidence[addon] = {"reinstall_preserved_history": True, "service_user_removed": True}

    def assert_scheduler_preserved(self, command) -> None:
        users = self.query(command, f"SELECT COUNT(*) AS N FROM EXA_DBA_USERS WHERE USER_NAME='{self.user}'")[0]["N"]
        if users:
            raise RuntimeError("Scheduler uninstall left its service user behind")
        history = self.query(command, f"SELECT COUNT(*) AS N FROM {self.schema}.SCHED_HISTORY")[0]["N"]
        tasks = self.query(command, f"SELECT COUNT(*) AS N FROM {self.schema}.SCHED_TASKS")[0]["N"]
        if history < self.history or tasks != 1:
            raise RuntimeError("Scheduler uninstall changed task definitions or history")

    def read_aliases(self) -> set[str]:
        listed = subprocess.run([str(self.guard), "slc", "list", "--json", "--deployment-dir", self.deployment],
                                capture_output=True, text=True, timeout=30, check=True)
        parsed = subprocess.run([sys.executable, str(ROOT / "setup/udf/udf_tool.py"), "aliases"],
                                input=listed.stdout, capture_output=True, text=True, timeout=30, check=True)
        return set(parsed.stdout.splitlines())

    def cleanup(self, command) -> None:
        if self.scheduler_created:
            command("sql", "--write", f"DROP SCHEMA IF EXISTS {self.schema} CASCADE")
            command("sql", "--write", f"DROP USER IF EXISTS {self.user}")
        if self.denied.exists():
            raise RuntimeError("UDF acceptance refused a runtime mutation")
