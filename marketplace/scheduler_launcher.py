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
    args.home.mkdir(parents=True, exist_ok=True)
    give_up = args.home / "gave-up"
    give_up.unlink(missing_ok=True)
    stop = False
    child: subprocess.Popen | None = None

    def shutdown(_signal, _frame) -> None:
        nonlocal stop
        stop = True
        if child is not None and child.poll() is None:
            child.terminate()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    # Startup races the database at login. A deliberately stopped database
    # does not hold a supervisor indefinitely.
    for _ in range(40):
        if stop:
            return 0
        try:
            with socket.create_connection((env.get("EXA_HOST") or host or "127.0.0.1", int(env.get("EXA_PORT") or port)),
                                          timeout=2):
                break
        except OSError:
            time.sleep(3)
    failures = 0
    while not stop:
        started = time.monotonic()
        child = subprocess.Popen([str(args.engine)], env=env, stdin=subprocess.DEVNULL)
        code = child.wait()
        child = None
        if stop or code == 0:
            return 0
        failures = failures + 1 if time.monotonic() - started < 60 else 1
        if failures >= 5:
            message = f"gave up after {failures} rapid failures (last exit {code})"
            give_up.write_text(message + "\n", encoding="utf-8")
            print(f"exasol-scheduler: {message}; inspect exakit logs exasol-scheduler", file=sys.stderr)
            return code or 1
        print(f"exasol-scheduler: engine exited ({code}); restarting in 5s ({failures}/5)", file=sys.stderr)
        for _ in range(5):
            if stop:
                return 0
            time.sleep(1)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
