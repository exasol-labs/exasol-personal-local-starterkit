"""Run a SELECT 1 task through the installed Scheduler and retain its history."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def cli_prefix() -> list[str]:
    if os.name == "nt":
        host = shutil.which("powershell.exe") or shutil.which("pwsh")
        if not host:
            raise RuntimeError("PowerShell is required")
        return [host, "-NoProfile", "-File", str(ROOT / "setup/exakit.ps1")]
    return ["bash", str(ROOT / "setup/exakit")]


def command(prefix: list[str], *args: str) -> str:
    result = subprocess.run([*prefix, *args], capture_output=True, text=True, timeout=45)
    if result.returncode:
        raise RuntimeError(f"exakit {args[0]} exited {result.returncode}; inspect the kit logs")
    return result.stdout


def query(prefix: list[str], sql: str) -> list[dict]:
    result = json.loads(command(prefix, "sql", "--json", sql))
    if not result.get("ok"):
        raise RuntimeError("Scheduler verification query failed")
    return result["rows"]


def verify(prefix: list[str], timeout: int) -> dict:
    if query(prefix, 'SELECT COUNT(*) AS N FROM SCHED.SCHED_TASKS')[0]["N"]:
        raise RuntimeError("Existing scheduler tasks found; use an empty test deployment")
    command(prefix, "start", "exasol-scheduler")
    task = "exakit_smoke_" + uuid.uuid4().hex
    sql = ('INSERT INTO SCHED.SCHED_TASKS ("TASK_ID", "ENABLED", "SCHEDULE", "SQL_TEXT") '
           f"VALUES ('{task}', TRUE, 'CRON */10 * * * * * TZ=UTC', 'SELECT 1')")
    result = {"task_id": task}
    try:
        print(sql, flush=True)
        command(prefix, "sql", "--write", sql)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            history = query(prefix, 'SELECT "STATUS" FROM SCHED.SCHED_HISTORY '
                            f'WHERE "TASK_ID"=\'{task}\' ORDER BY "STARTED_AT" DESC LIMIT 1')
            if history:
                result["status"] = history[0]["STATUS"]
                if result["status"] != "SUCCEEDED":
                    raise RuntimeError("The verification task did not succeed")
                break
            time.sleep(2)
        else:
            raise RuntimeError("Timed out waiting for the verification task")
        result["privileges"] = [row["PRIVILEGE"] for row in query(prefix,
            "SELECT PRIVILEGE FROM SYS.EXA_DBA_SYS_PRIVS WHERE GRANTEE='SCHEDULER_SVC'")]
        if result["privileges"] != ["CREATE SESSION"]:
            raise RuntimeError("Unexpected Scheduler system privileges")
        result["service"] = json.loads(command(prefix, "status", "--json"))["services"]["exasol-scheduler"]
        if result["service"] != "running":
            raise RuntimeError("Scheduler stopped after the verification task")
    finally:
        command(prefix, "sql", "--write", f'DELETE FROM SCHED.SCHED_TASKS WHERE "TASK_ID"=\'{task}\'')
    result["remaining_tasks"] = query(prefix, 'SELECT COUNT(*) AS N FROM SCHED.SCHED_TASKS')[0]["N"]
    if result["remaining_tasks"]:
        raise RuntimeError("Scheduler task cleanup did not finish")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--approve-test-writes", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=int, default=90)
    args = parser.parse_args()
    if not args.approve_test_writes:
        parser.error("--approve-test-writes authorizes the displayed SELECT 1 task and its cleanup")
    if not 10 <= args.timeout <= 600:
        parser.error("--timeout must be between 10 and 600 seconds")
    try:
        result = {"ok": True, **verify(cli_prefix(), args.timeout)}
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        result = {"ok": False, "error": str(error)}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
