"""Real authenticated MLflow server contract and recovery; fixture UDF rows, no database or provider keys."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import subprocess
import sys
import tempfile
import time
from urllib.error import HTTPError
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / "packages/exasol-mlflow"), str(ROOT / "tests")]
from test_exasol_mlflow import FakeConn
import exasol_mlflow
from exasol_mlflow import records, tracking


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    import mlflow
    from mlflow import MlflowClient
    with tempfile.TemporaryDirectory(prefix="exakit-mlflow-live-") as folder:
        folder = Path(folder)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0)); port = sock.getsockname()[1]
        uri = f"http://127.0.0.1:{port}"
        password = secrets.token_urlsafe(24)
        config = folder / "auth.ini"
        config.write_text(f"[mlflow]\ndefault_permission = READ\ndatabase_uri = sqlite:///{folder/'auth.db'}\n"
                          f"admin_username = acceptance\nadmin_password = {password}\n"
                          "authorization_function = mlflow.server.auth:authenticate_request_basic_auth\n")
        config.chmod(0o600)
        os.environ.update(EXAKIT_HOME=str(folder / "kit"), MLFLOW_TRACKING_URI=uri,
                          MLFLOW_TRACKING_USERNAME="acceptance", MLFLOW_TRACKING_PASSWORD=password,
                          MLFLOW_AUTH_CONFIG_PATH=str(config), MLFLOW_FLASK_SERVER_SECRET_KEY=secrets.token_hex(32),
                          MLFLOW_HTTP_REQUEST_MAX_RETRIES="0", MLFLOW_HTTP_REQUEST_TIMEOUT="3")
        os.environ.pop("MLFLOW_TRACKING_TOKEN", None)
        process = None
        args.output.parent.mkdir(parents=True, exist_ok=True)
        log = args.output.with_suffix(".startup.log").open("w")
        cmd = [sys.executable, "-m", "mlflow", "server", "--host", "127.0.0.1", "--port", str(port), "--workers", "1",
               "--app-name", "basic-auth", "--backend-store-uri", "sqlite:///" + str(folder / "tracking.db"),
               "--default-artifact-root", (folder / "artifacts").as_uri()]
        def stop():
            nonlocal process
            if process is not None and process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=20)
        def start():
            nonlocal process
            process = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            for attempt in range(120):
                try:
                    with urlopen(uri + "/health", timeout=2) as response:
                        if response.status == 200:
                            return
                except Exception:
                    pass
                if process.poll() is not None:
                    raise RuntimeError("The authenticated MLflow fixture did not start")
                time.sleep(1)
            raise RuntimeError("The authenticated MLflow fixture timed out")
        report = {"kind": "real-authenticated-mlflow-fixture-udf", "version": mlflow.__version__, "passed": False}
        try:
            start()
            conn = FakeConn()
            with exasol_mlflow.start_run(conn, experiment="acceptance") as run:
                run.execute("SELECT fixture_training_contract")
            client = MlflowClient(tracking_uri=uri)
            logged = client.get_run(run.run_id)
            assert logged.data.metrics["roc_auc"] == 0.8
            assert logged.data.params["C"] == "1.0"
            blob = Path(client.download_artifacts(run.run_id, "model/model.pkl")).read_bytes()
            assert hashlib.sha256(blob).hexdigest() == hashlib.sha256(b"model-bytes").hexdigest()
            try:
                urlopen(uri + "/api/2.0/mlflow/runs/get?run_id=" + run.run_id, timeout=3)
            except HTTPError as err:
                assert err.code == 401
            else:
                raise AssertionError("Unauthenticated tracking access was allowed")
            assert password not in json.dumps(conn.statements)
            class DisconnectAfterSQL(FakeConn):
                def execute(self, sql):
                    result = super().execute(sql)
                    if "EXA_METADATA" not in sql:
                        stop()
                    return result
            try:
                with exasol_mlflow.start_run(DisconnectAfterSQL(), experiment="acceptance") as failed:
                    failed.execute("SELECT fixture_training_contract")
            except Exception:
                pass
            assert records.pending(), "The interrupted run was not spooled"
            unexecuted = FakeConn()
            try:
                with exasol_mlflow.start_run(unexecuted, experiment="acceptance", timeout=1):
                    raise AssertionError("Unreachable tracking passed preflight")
            except tracking.TrackingUnavailable:
                pass
            assert not unexecuted.statements
            start()
            replayed = records.replay(tracking_uri=uri, timeout=3)
            assert replayed and not records.pending()
            report.update(passed=True, authentication_required=True, metrics_artifact_verified=True,
                          credentials_absent_from_sql=True, unreachable_before_sql=True, live_disconnect_replayed=True)
        finally:
            stop(); log.close()
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(report, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
