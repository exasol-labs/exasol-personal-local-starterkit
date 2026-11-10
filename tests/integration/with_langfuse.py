"""Run DS4.4 against a disposable official Langfuse 4.59.0 stack; remove only this test's containers/volumes."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import time
from urllib.request import urlopen
import uuid

HERE = Path(__file__).resolve().parent


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    import yaml
    pin = json.loads((HERE / "service-pins.json").read_text())["langfuse"]
    with urlopen(pin["compose_url"], timeout=30) as response:
        source = response.read()
    if hashlib.sha256(source).hexdigest() != pin["compose_sha256"]:
        raise RuntimeError("Upstream compose digest mismatch; refusing the service fixture")
    compose = yaml.safe_load(source)
    project = "exakit-lf-" + secrets.token_hex(5)
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0)); port = sock.getsockname()[1]
    url = f"http://127.0.0.1:{port}"
    public, secret = "pk-lf-" + str(uuid.uuid4()), "sk-lf-" + str(uuid.uuid4())
    seed = {"LANGFUSE_INIT_ORG_ID": project, "LANGFUSE_INIT_ORG_NAME": "Acceptance fixture",
            "LANGFUSE_INIT_PROJECT_ID": project, "LANGFUSE_INIT_PROJECT_NAME": "Acceptance fixture",
            "LANGFUSE_INIT_PROJECT_PUBLIC_KEY": public, "LANGFUSE_INIT_PROJECT_SECRET_KEY": secret,
            "LANGFUSE_INIT_USER_EMAIL": project + "@example.invalid", "LANGFUSE_INIT_USER_PASSWORD": secrets.token_urlsafe(32)}
    with tempfile.TemporaryDirectory(prefix="exakit-lf-stack-") as folder:
        folder = Path(folder)
        for name, service in compose["services"].items():
            service["ports"] = [f"127.0.0.1:{port}:3000"] if name == "langfuse-web" else []
            service["restart"] = "no"
            if name.startswith("langfuse-"):
                service["image"] = service["image"].rsplit(":", 1)[0] + ":" + pin["version"]
                service["environment"].update(NEXTAUTH_URL=url, TELEMETRY_ENABLED="false")
            if name == "langfuse-web":
                service["environment"].update(seed)
        config = folder / "compose.yml"
        config.write_text(yaml.safe_dump(compose, sort_keys=False))
        config.chmod(0o600)
        # Override shared upstream defaults without exposing values in argv/stdout.
        allowed = {"PATH", "HOME", "USER", "LOGNAME", "DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CONFIG", "DOCKER_CERT_PATH", "DOCKER_TLS_VERIFY", "SSH_AUTH_SOCK", "XDG_RUNTIME_DIR"}
        env = {k: v for k, v in os.environ.items() if k in allowed}
        env.update(SALT=secrets.token_hex(32), ENCRYPTION_KEY=secrets.token_hex(32),
                   NEXTAUTH_SECRET=secrets.token_hex(32), TELEMETRY_ENABLED="false",
                   LANGFUSE_BASE_URL=url, LANGFUSE_PUBLIC_KEY=public, LANGFUSE_SECRET_KEY=secret)
        cmd = ["docker", "compose", "--project-name", project, "--file", str(config)]
        args.output.parent.mkdir(parents=True, exist_ok=True)
        log = args.output.with_suffix(".startup.log")
        try:
            with log.open("w") as handle:
                subprocess.run([*cmd, "up", "--detach", "--wait", "--wait-timeout", "360"],
                               env=env, stdout=handle, stderr=subprocess.STDOUT, check=True, timeout=600)
            for n in range(90):
                try:
                    with urlopen(url + "/api/public/health", timeout=5) as response:
                        health = json.load(response)
                    break
                except Exception:
                    time.sleep(2)
            else:
                raise RuntimeError("Self-hosted Langfuse did not become healthy")
            subprocess.run([sys.executable, str(HERE / "langfuse_live.py"), "--output", str(args.output)],
                           env=env, check=True, timeout=180)
            result = json.loads(args.output.read_text())
            result.update(server_version=pin["version"], service="self-hosted", cleanup_project=project)
            args.output.write_text(json.dumps(result, indent=2) + "\n")
        finally:
            subprocess.run([*cmd, "down", "--volumes", "--remove-orphans"], env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120, check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
