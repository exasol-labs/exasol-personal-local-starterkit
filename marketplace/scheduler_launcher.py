"""Supervise one Exasol Scheduler engine without putting a password in argv."""

from __future__ import annotations

import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path

import kit_telemetry
import kit_tls


def connection_env(doc: dict, env: dict, host: str, port: int) -> None:
    """The engine's connection in its environment: pinned through EXA_DSN once the kit recorded the database's
    certificate, else the EXA_* parts as before. What the caller already set is kept."""
    receipt = doc.get("components", {}).get("exasol_scheduler", {})
    pin = kit_tls.fingerprint(doc)
    if pin and not any(env.get(name) for name in ("EXA_DSN", "EXA_HOST")):
        # Pinned to the certificate the kit recorded (audit SEC-14): the engine takes the pin only in its connection
        # string, so the connection is EXA_DSN - the user and address, never the password, which stays EXA_PASSWORD.
        user = str(receipt.get("db_user", "scheduler_svc"))
        env["EXA_DSN"] = (f"exasol://{user}@{host or '127.0.0.1'}:{port}"
                          f"?tls=1&validateservercertificate=0&certificate_fingerprint={pin}")
        env.setdefault("EXA_SCHEMA", str(receipt.get("schema", "SCHED")))
    else:
        for name, value in (("EXA_HOST", host or "127.0.0.1"), ("EXA_PORT", str(port)),
                            ("EXA_USER", receipt.get("db_user", "scheduler_svc")),
                            ("EXA_SCHEMA", receipt.get("schema", "SCHED")),
                            ("EXA_TLS", "true"), ("EXA_VALIDATE_SERVER_CERT", "false")):
            env.setdefault(name, str(value))


def dsn_with_password(dsn: str, password: str) -> str:
    """The engine reads its password from EXA_DSN alone once that is set (EXA_PASSWORD only counts without a DSN), so
    a pinned connection carries it inside: exasol://user:password@host... A DSN that already names one is kept. It
    lives only in the engine's environment, as EXA_PASSWORD did, and is never printed."""
    scheme, sep, rest = dsn.partition("://")
    userinfo, at, address = rest.partition("@")
    if not sep or not at or ":" in userinfo or not password:
        return dsn
    return f"{scheme}://{userinfo}:{urllib.parse.quote(password, safe='')}@{address}"


# THE SUPERVISOR NEVER GIVES UP. The engine exits on fatal errors by design, and a database that goes away is one:
# Docker Desktop restarting, a Docker update, `exakit stop database`. This supervisor used to stop for good after
# five rapid failures, so on a real Windows 11 machine a 30-second Docker Desktop restart left the scheduler dead
# after the database was back, until someone ran `exakit start exasol-scheduler`. Now it keeps going:
# - an engine that failed is retried 5s later, five times, then the wait doubles up to a minute, so a real crash
#   loop costs one short start a minute and never the CPU;
# - while the database does not answer at all, no engine is started: the port is checked every 5s and the engine
#   starts the moment it answers, so a database restart costs seconds, not the backoff;
# - the state is in the RESTARTING marker while it lasts (exakit status reads it), and gone once an engine has run
#   longer than a rapid failure or the supervisor ends.
RESTARTING = "restarting"
RAPID_SECONDS = 60      # an engine that ran shorter than this failed rapidly
FIRST_WAIT = 5          # seconds before each of the first PACED_TRIES retries
PACED_TRIES = 5
MAX_WAIT = 60


def retry_wait(failures: int) -> int:
    """Seconds before the next start after this many rapid failures in a row: 5s for the first five, then doubling
    to at most a minute."""
    if failures < PACED_TRIES:
        return FIRST_WAIT
    return min(FIRST_WAIT * 2 ** (failures - PACED_TRIES + 1), MAX_WAIT)


def reachable(address: tuple[str, int]) -> bool:
    try:
        with socket.create_connection(address, timeout=2):
            return True
    except OSError:
        return False


class Supervisor:
    """Run one engine until stopped, restarting it whenever it exits non-zero (see THE SUPERVISOR NEVER GIVES UP)."""

    def __init__(self, name: str, command: list[str], env: dict, state: Path, database_up) -> None:
        self.name = name
        self.command = command
        self.env = env
        self.state = state
        self.database_up = database_up
        self.stop = False
        self.child: subprocess.Popen | None = None

    def shutdown(self, _signal=None, _frame=None) -> None:
        self.stop = True
        if self.child is not None and self.child.poll() is None:
            self.child.terminate()

    def _pause(self, seconds: int) -> None:
        for _ in range(seconds):
            if self.stop:
                return
            time.sleep(1)

    def _note(self, text: str) -> None:
        try:
            self.state.write_text(text + "\n", encoding="utf-8")
        except OSError:
            pass

    def _clear(self) -> None:
        try:
            self.state.unlink(missing_ok=True)
        except OSError:
            pass

    def _run_engine(self) -> tuple[int, float]:
        """(exit code, seconds it ran). An engine still up after RAPID_SECONDS is running again: the marker goes."""
        started = time.monotonic()
        self.child = subprocess.Popen(self.command, env=self.env, stdin=subprocess.DEVNULL)
        try:
            code = self.child.wait(timeout=RAPID_SECONDS)
        except subprocess.TimeoutExpired:
            self._clear()
            code = self.child.wait()
        self.child = None
        return code, time.monotonic() - started

    def run(self) -> int:
        self._clear()
        failures = 0
        code = 0
        waiting = False
        try:
            while not self.stop:
                if failures and not self.database_up():
                    if not waiting:
                        print(f"{self.name}: the database does not answer; starting the engine once it does",
                              file=sys.stderr)
                        self._note("waiting for the database")
                        waiting = True
                    self._pause(FIRST_WAIT)
                    continue
                waiting = False
                code, ran = self._run_engine()
                if self.stop or code == 0:
                    return 0
                failures = failures + 1 if ran < RAPID_SECONDS else 1
                wait = retry_wait(failures)
                self._note(f"{failures} rapid failures, last exit {code}")
                print(f"{self.name}: engine exited ({code}); restarting in {wait}s ({failures} rapid failures)",
                      file=sys.stderr)
                self._pause(wait)
            return 0
        finally:
            self._clear()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("home", type=Path)
    parser.add_argument("engine", type=Path)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("credential", type=Path)
    args = parser.parse_args()
    doc = json.loads(args.manifest.read_text(encoding="utf-8"))
    dsn = str(doc.get("runtime", {}).get("dsn", "127.0.0.1:8563"))
    host, _, port_text = dsn.partition(":")
    try:
        port = int(port_text)
    except ValueError:
        port = 8563
    env = os.environ.copy()
    kit_telemetry.default_off(env)
    connection_env(doc, env, host, port)
    if not env.get("EXA_PASSWORD"):
        try:
            env["EXA_PASSWORD"] = args.credential.read_text(encoding="utf-8").strip()
        except OSError:
            print("exasol-scheduler credential is unavailable; run exakit update exasol-scheduler", file=sys.stderr)
            return 1
    if env.get("EXA_DSN"):
        env["EXA_DSN"] = dsn_with_password(env["EXA_DSN"], env["EXA_PASSWORD"])
    args.home.mkdir(parents=True, exist_ok=True)
    # A marker an earlier kit's supervisor left when it gave up: this one never gives up, so it goes.
    (args.home / "gave-up").unlink(missing_ok=True)
    (args.home / RESTARTING).unlink(missing_ok=True)    # one a supervisor killed outright (taskkill /F) left behind
    address = (env.get("EXA_HOST") or host or "127.0.0.1", int(env.get("EXA_PORT") or port))
    supervisor = Supervisor("exasol-scheduler", [str(args.engine)], env, args.home / RESTARTING,
                            lambda: reachable(address))
    signal.signal(signal.SIGTERM, supervisor.shutdown)
    signal.signal(signal.SIGINT, supervisor.shutdown)
    # Startup races the database at login. A deliberately stopped database
    # does not hold a supervisor indefinitely.
    for _ in range(40):
        if supervisor.stop:
            return 0
        if reachable(address):
            break
        time.sleep(3)
    return supervisor.run()

if __name__ == "__main__":
    raise SystemExit(main())
