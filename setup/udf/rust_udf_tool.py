"""Create, build and deploy a pinned Exasol Rust scoring UDF.

The shell and PowerShell launchers supply the same environment and call this
stdlib CLI. A Rust toolchain is needed only inside the Linux build container
on macOS/Windows. The database write at deploy uses the kit's admin credential
file; a password is never placed in argv, output, source or an artifact.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SDK = "0.33.0"
RUSTC = "1.98.1"
IMAGE = "rust:1.98.1-trixie"
NAME = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
FEATURE = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,127}$")


class Refused(Exception):
    def __init__(self, message: str, code: int = 2, remedy: str | None = None):
        super().__init__(message)
        self.code, self.remedy = code, remedy


def kit_home() -> Path:
    return Path(os.environ.get("EXAKIT_HOME") or Path.home() / ".exasol-starter-kit").expanduser()


def project_path(name: str) -> Path:
    if not NAME.fullmatch(name):
        raise Refused("Rust UDF name must start with a lowercase letter and contain only lowercase letters, digits or _.")
    return kit_home() / "rust-udfs" / name


def coefficients(path: Path) -> tuple[list[str], list[float], float]:
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
        names = doc["features"]
        rows = doc["coef"]
        intercepts = doc["intercept"]
        classes = doc["classes"]
        if (not isinstance(names, list) or not names or not all(isinstance(n, str) and FEATURE.fullmatch(n) for n in names)
                or len(set(names)) != len(names) or not isinstance(rows, list) or len(rows) != 1
                or len(rows[0]) != len(names) or len(intercepts) != 1 or len(classes) != 2
                or str(classes[1]) != str(doc.get("positive_class", classes[1]))):
            raise ValueError("expected one binary classifier with matching feature, coefficient and class arrays")
        weights = [float(value) for value in rows[0]]
        bias = float(intercepts[0])
        if not all(math.isfinite(value) for value in [*weights, bias]):
            raise ValueError("coefficients and intercept must be finite")
        return names, weights, bias
    except (OSError, ValueError, TypeError, KeyError) as error:
        raise Refused(f"{path} is not a supported coefficients.json from 01_train: {error}") from error


def rust_source(name: str, weights: list[float], bias: float) -> str:
    weighted = ", ".join(repr(weight) for weight in weights)
    return f'''use exasol_udf_macros::exasol_udf;
use exasol_udf_sdk::context::UdfContext;
use exasol_udf_sdk::error::UdfError;

const WEIGHTS: [f64; {len(weights)}] = [{weighted}];
const INTERCEPT: f64 = {repr(bias)};

#[exasol_udf]
pub fn {name}(ctx: &mut dyn UdfContext) -> Result<Option<f64>, UdfError> {{
    let mut logit = INTERCEPT;
    for (index, weight) in WEIGHTS.iter().enumerate() {{
        let Some(value) = ctx.get_f64(index)? else {{ return Ok(None); }};
        logit += weight * value;
    }}
    // Stable sigmoid, with the same float64 formula as the Python parity check.
    let probability = if logit >= 0.0 {{ 1.0 / (1.0 + (-logit).exp()) }}
                      else {{ let value = logit.exp(); value / (1.0 + value) }};
    Ok(Some(probability))
}}
'''


def create(name: str, source: str | None) -> dict:
    project = project_path(name)
    if project.exists():
        raise Refused(f"{project} already exists; choose another name. Nothing was overwritten.", 5)
    if source:
        names, weights, bias = coefficients(Path(source).expanduser())
    else:
        names, weights, bias = ["VALUE_"], [1.0], 0.0
    project.mkdir(parents=True, mode=0o700)
    (project / "src").mkdir()
    (project / "Cargo.toml").write_text(f'''[package]
name = "{name}"
version = "0.1.0"
edition = "2024"

[lib]
crate-type = ["cdylib"]

[dependencies]
exasol-udf-sdk = "={SDK}"
exasol-udf-macros = "={SDK}"
''', encoding="utf-8")
    (project / "rust-toolchain.toml").write_text(f'[toolchain]\nchannel = "{RUSTC}"\n', encoding="utf-8")
    (project / "src" / "lib.rs").write_text(rust_source(name, weights, bias), encoding="utf-8")
    manifest = {"name": name, "features": names, "weights": weights, "intercept": bias,
                "sdk": SDK, "rustc": RUSTC, "coefficients_source_sha256":
                hashlib.sha256(Path(source).expanduser().read_bytes()).hexdigest() if source else None}
    (project / "exakit-rust.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    (project / "README.md").write_text(
        f"# {name}\n\nThe SQL arguments follow `exakit-rust.json` features in order. "
        f"Build: `exakit rust-udf build {name}`. Deploy: `exakit rust-udf deploy {name}`. "
        "A null input returns SQL NULL. The output is the positive class probability.\n", encoding="utf-8")
    return {"ok": True, "name": name, "project": str(project), "features": names,
            "next": f"exakit rust-udf build {name}"}


def architecture() -> str:
    chosen = os.environ.get("EXAKIT_UDF_ARCH", "")
    if chosen:
        if chosen not in ("aarch64", "x86_64"):
            raise Refused("EXAKIT_UDF_ARCH must be aarch64 or x86_64")
        return chosen
    machine = platform.machine().lower()
    if platform.system() == "Windows":
        return "x86_64"
    if machine in ("arm64", "aarch64"):
        return "aarch64"
    if machine in ("amd64", "x86_64"):
        return "x86_64"
    raise Refused(f"No Rust container is pinned for {machine}.", 4, "exakit udf-setup --language rust")


def _run(args: list[str], *, cwd: Path | None = None) -> None:
    completed = subprocess.run(args, cwd=cwd, text=True, capture_output=True, check=False)
    if completed.returncode:
        lines = (completed.stderr or completed.stdout).strip().splitlines()
        detail = lines[-1][:400] if lines else "no diagnostic"
        raise Refused(f"Rust build or validation failed: {detail}", 7,
                      "exakit rust-udf build " + (cwd.name if cwd else "<name>"))


def container_runtime() -> str:
    """Choose a running engine, not merely a CLI left on PATH."""
    for command in ("docker", "podman"):
        executable = shutil.which(command)
        if executable:
            try:
                probe = subprocess.run([executable, "info"], stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL, timeout=8, check=False)
                if probe.returncode == 0:
                    return executable
            except (OSError, subprocess.TimeoutExpired):
                pass
    raise Refused("A running Docker or Podman Linux engine is needed for the Rust build.", 5,
                  "exakit udf-build --help")


def build(name: str) -> dict:
    project = project_path(name)
    if not (project / "Cargo.toml").is_file():
        raise Refused(f"No Rust project at {project}. Create it with: exakit rust-udf new {name}", 4)
    arch = architecture()
    artifact = project / "target" / "release" / f"lib{name}.so"
    system = platform.system()
    if system in ("Darwin", "Windows"):
        runtime = container_runtime()
        platform_arg = "linux/arm64" if arch == "aarch64" else "linux/amd64"
        # The command text is fixed; name and path travel as argv / mount args.
        script = ("set -e; export PATH=$CARGO_HOME/bin:$PATH; "
                  "if [ ! -x $CARGO_HOME/bin/cargo-exasol-udf ]; then "
                  f"cargo install cargo-exasol-udf --version ={SDK} --locked; fi; "
                  "cargo exasol-udf build /work; "
                  f"cargo exasol-udf validate /work/target/release/lib{name}.so --deny-unknown-deps")
        _run([runtime, "run", "--rm", "--platform", platform_arg, "-v", f"{project}:/work",
              "-v", f"exakit-rust-cargo-{arch}:/cargo-home", "-e", "CARGO_HOME=/cargo-home",
              "-w", "/work", IMAGE, "sh", "-c", script], cwd=project)
    else:
        try:
            found = subprocess.run(["rustc", "--version"], capture_output=True, text=True, check=False)
        except FileNotFoundError as error:
            raise Refused(f"Rust UDF needs rustc {RUSTC}; rustc is not installed.", 5,
                          "exakit rust-udf build " + name) from error
        if found.returncode or not found.stdout.startswith(f"rustc {RUSTC} "):
            raise Refused(f"Rust UDF needs rustc {RUSTC}, found {found.stdout.strip() or 'none'}.", 7,
                          "exakit rust-udf build " + name)
        _run(["cargo", "exasol-udf", "build", str(project)], cwd=project)
        _run(["cargo", "exasol-udf", "validate", str(artifact), "--deny-unknown-deps"], cwd=project)
    if not artifact.is_file():
        raise Refused(f"The build returned without {artifact}; inspect the build log.", 7)
    digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
    record = {"sha256": digest, "arch": arch, "sdk": SDK, "rustc": RUSTC, "artifact": str(artifact)}
    (project / "build.json").write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    return {"ok": True, "name": name, **record, "next": f"exakit rust-udf deploy {name}"}


def create_sql(name: str, schema: str, features: list[str], path: str) -> str:
    if not FEATURE.fullmatch(schema):
        raise Refused("Schema must be a plain SQL name.")
    inputs = ", ".join(f'"{item}" DOUBLE' for item in features)
    return (f"CREATE OR REPLACE RUST SCALAR SCRIPT {schema.upper()}.{name.upper()}({inputs}) "
            f"RETURNS DOUBLE AS\n%udf_object {path};")


def _connect():
    import ssl
    import pyexasol

    filename = Path(os.environ["EXAKIT_PYX_PWFILE"])
    password = filename.read_text(encoding="utf-8").strip()
    options = {"dsn": os.environ["EXAKIT_PYX_DSN"], "user": os.environ["EXAKIT_PYX_USER"],
               "password": password}
    return pyexasol.connect(encryption=True, websocket_sslopt={"cert_reqs": ssl.CERT_NONE}, **options)


def deploy(name: str, schema: str) -> dict:
    project = project_path(name)
    try:
        built = json.loads((project / "build.json").read_text(encoding="utf-8"))
        meta = json.loads((project / "exakit-rust.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise Refused(f"{name} has no validated build record: {error}", 4,
                      f"exakit rust-udf build {name}") from error
    artifact = Path(built["artifact"])
    if (not artifact.is_file() or hashlib.sha256(artifact.read_bytes()).hexdigest() != built["sha256"]
            or built.get("arch") != architecture() or built.get("sdk") != SDK or built.get("rustc") != RUSTC):
        raise Refused("The compiled Rust library changed or has the wrong architecture, SDK or rustc; rebuild it.", 7,
                      f"exakit rust-udf build {name}")
    bucket = Path(os.environ.get("EXAKIT_RUST_BUCKET_DIR", ""))
    root = os.environ.get("EXAKIT_RUST_UDF_ROOT", "")
    if not bucket.is_dir() or not root.startswith("/buckets/"):
        raise Refused("The deployment's bucket directory is unavailable; the Rust library was not deployed.", 5,
                      "exakit model list")
    folder = bucket / "udf"
    folder.mkdir(parents=True, exist_ok=True)
    destination = folder / artifact.name
    with tempfile.NamedTemporaryFile(dir=folder, prefix="." + artifact.name + ".part-", delete=False) as output:
        part = Path(output.name)
        with artifact.open("rb") as source:
            shutil.copyfileobj(source, output)
        output.flush()
        os.fsync(output.fileno())
    try:
        os.replace(part, destination)
    finally:
        if part.exists():
            part.unlink()
    if hashlib.sha256(destination.read_bytes()).hexdigest() != built["sha256"]:
        raise Refused("The copied Rust library failed SHA-256 verification.", 7)
    udf_path = f"{root.rstrip('/')}/udf/{artifact.name}"
    sql = create_sql(name, schema, meta["features"], udf_path)
    conn = _connect()
    try:
        conn.execute(f"CREATE SCHEMA IF NOT EXISTS {schema.upper()}")
        conn.execute(sql)
    finally:
        conn.close()
    return {"ok": True, "name": name, "schema": schema.upper(), "udf": f"{schema.upper()}.{name.upper()}",
            "path": udf_path, "sha256": built["sha256"], "features": meta["features"]}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="exakit rust-udf")
    parser.add_argument("action", choices=("new", "build", "deploy"))
    parser.add_argument("name")
    parser.add_argument("--coefficients")
    parser.add_argument("--schema", default="EXAKIT_SCORING")
    parser.add_argument("--json", action="store_true")
    try:
        args = parser.parse_args(argv)
        if args.action != "new" and args.coefficients:
            raise Refused("--coefficients belongs to rust-udf new.")
        if args.action != "deploy" and args.schema != "EXAKIT_SCORING":
            raise Refused("--schema belongs to rust-udf deploy.")
        answer = (create(args.name, args.coefficients) if args.action == "new" else
                  build(args.name) if args.action == "build" else deploy(args.name, args.schema))
        if args.json:
            print(json.dumps(answer))
        else:
            print(f"Rust UDF {args.name}: {args.action} complete.")
            for key, value in answer.items():
                if key not in ("ok", "name"):
                    print(f"  {key}: {value}")
        return 0
    except Refused as error:
        payload = {"ok": False, "error": str(error), "step": argv[0] if argv else None,
                   "language": "rust", "remedy": error.remedy}
        if "--json" in argv:
            print(json.dumps(payload))
        else:
            print(f"Rust UDF: {error}", file=sys.stderr)
            if error.remedy:
                print("Run: " + error.remedy, file=sys.stderr)
        return error.code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
