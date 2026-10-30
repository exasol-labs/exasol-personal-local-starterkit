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
import tarfile
import time
from pathlib import Path

SDK = "0.33.0"
RUSTC = "1.98.1"
IMAGE = "docker.io/library/rust:1.98.1-trixie"
NAME = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
FEATURE = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,127}$")


class Refused(Exception):
    def __init__(self, message: str, code: int = 2, remedy: str | None = None,
                 step: str | None = None):
        super().__init__(message)
        self.code, self.remedy, self.step = code, remedy, step


class ArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise Refused(message)


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
    row = rust_pins(architecture())
    sdk = row["crates"]["exasol-udf-sdk"]
    rustc = row["runtime"]["rustc"]
    if source:
        try:
            source_digest = hashlib.sha256(Path(source).expanduser().read_bytes()).hexdigest()
        except OSError as error:
            raise Refused(f"Cannot read the coefficients file {source}: {error}") from error
    else:
        source_digest = None
    if project.exists():
        try:
            recorded = json.loads((project / "exakit-rust.json").read_text(encoding="utf-8"))
            if (recorded.get("coefficients_source_sha256") == source_digest
                    and recorded.get("sdk") == sdk and recorded.get("rustc") == rustc
                    and (project / "Cargo.toml").is_file() and (project / "src/lib.rs").is_file()):
                return {"ok": True, "name": name, "project": str(project),
                        "features": recorded["features"], "reused": True,
                        "next": f"exakit rust-udf build {name}"}
        except (OSError, ValueError, KeyError):
            pass
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
exasol-udf-sdk = "={sdk}"
exasol-udf-macros = "={sdk}"
''', encoding="utf-8")
    (project / "rust-toolchain.toml").write_text(f'[toolchain]\nchannel = "{rustc}"\n', encoding="utf-8")
    (project / "src" / "lib.rs").write_text(rust_source(name, weights, bias), encoding="utf-8")
    manifest = {"name": name, "features": names, "weights": weights, "intercept": bias,
                "sdk": sdk, "rustc": rustc, "coefficients_source_sha256": source_digest}
    (project / "exakit-rust.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    (project / "README.md").write_text(
        f"# {name}\n\nThe SQL arguments follow `exakit-rust.json` features in order. "
        f"Build: `exakit rust-udf build {name}`. Deploy: `exakit rust-udf deploy {name}`. "
        "A null input returns SQL NULL. The output is the positive class probability.\n", encoding="utf-8")
    return {"ok": True, "name": name, "project": str(project), "features": names,
            "next": f"exakit rust-udf build {name}"}


def architecture() -> str:
    # Keep the build target identical to udf-setup's database target, including
    # the EXAKIT_UDF_ARCH override for non-native deployments.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from udf_tool import database_arch
    try:
        return database_arch(platform.machine(), platform.system(), os.environ.get("EXAKIT_UDF_ARCH", ""))
    except ValueError as error:
        raise Refused(str(error), 4, "exakit udf-setup --language rust") from error


def rust_pins(arch: str) -> dict:
    versions = Path(os.environ.get("EXAKIT_MARKETPLACE_VERSIONS_DOC") or
                    Path(__file__).resolve().parents[2] / "versions.json")
    try:
        rows = json.loads(versions.read_text(encoding="utf-8"))["components"]["udf-devkit"]["containers"]
        matches = [row for row in rows if row.get("language") == "rust" and row.get("arch") == arch]
        if len(matches) != 1:
            raise ValueError(f"expected one Rust container row for {arch}, found {len(matches)}")
        row = matches[0]
        rustc = row["runtime"]["rustc"]
        sdk = row["crates"]["exasol-udf-sdk"]
        if not rustc or not sdk or row.get("alias") != "RUST":
            raise ValueError("Rust runtime, SDK or alias pin is missing")
        return row
    except (OSError, KeyError, TypeError, ValueError) as error:
        raise Refused(f"This kit has no usable Rust pins for {arch}: {error}", 4,
                      "exakit update") from error


def rust_installed(row: dict) -> None:
    try:
        manifest = json.loads((kit_home() / "manifest.json").read_text(encoding="utf-8"))
        installed = manifest["components"]["udf_devkit"]
        proved = installed["rust"]
        if (proved.get("validated") is not True or proved.get("rustc") != row["runtime"]["rustc"]
                or proved.get("sdk") != row["crates"]["exasol-udf-sdk"]
                or not installed.get("containers", {}).get(row["alias"])):
            raise ValueError("the RUST container is not installed and validated at the pinned SDK and rustc")
    except (OSError, KeyError, TypeError, ValueError) as error:
        raise Refused(f"Rust deployment requires a validated RUST container: {error}", 5,
                      "exakit udf-setup --language rust") from error


def _run(args: list[str], *, cwd: Path | None = None) -> None:
    completed = subprocess.run(args, cwd=cwd, text=True, capture_output=True, check=False)
    if completed.returncode:
        lines = (completed.stderr or completed.stdout).strip().splitlines()
        detail = lines[-1][:400] if lines else "no diagnostic"
        stage = "validate" if "EXAKIT_STAGE=validate" in (completed.stderr or "") else "build"
        raise Refused(f"Rust {stage} failed: {detail}", 7,
                      "exakit rust-udf build " + (cwd.name if cwd else "<name>"), stage)


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
    row = rust_pins(arch)
    sdk = row["crates"]["exasol-udf-sdk"]
    rustc = row["runtime"]["rustc"]
    try:
        project_meta = json.loads((project / "exakit-rust.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise Refused(f"Rust project metadata is missing or invalid: {error}", 7,
                      f"exakit rust-udf new {name}") from error
    if project_meta.get("sdk") != sdk or project_meta.get("rustc") != rustc:
        raise Refused(f"Rust project SDK/rustc differs from the container pins {sdk}/{rustc}; create a new project with the current kit.", 7)
    artifact = project / "target" / "release" / f"lib{name}.so"
    runtime = container_runtime()
    platform_arg = "linux/arm64" if arch == "aarch64" else "linux/amd64"
    # The pinned Linux image avoids a newer host glibc even on Linux. The
    # command text is fixed; name and path travel as argv / mount args.
    script = ("set -e; export PATH=$CARGO_HOME/bin:$PATH; "
              "if [ ! -x $CARGO_HOME/bin/cargo-exasol-udf ]; then "
              f"cargo install cargo-exasol-udf --version ={sdk} --locked; fi; "
              "cargo generate-lockfile; "
              "echo EXAKIT_STAGE=build >&2; cargo exasol-udf build /work; "
              "echo EXAKIT_STAGE=validate >&2; "
              f"cargo exasol-udf validate /work/target/release/lib{name}.so --deny-unknown-deps")
    _run([runtime, "run", "--rm", "--platform", platform_arg, "-v", f"{project}:/work",
          "-v", f"exakit-rust-cargo-{arch}:/cargo-home", "-e", "CARGO_HOME=/cargo-home",
          "-w", "/work", IMAGE, "sh", "-c", script], cwd=project)
    if not artifact.is_file():
        raise Refused(f"The build returned without {artifact}; inspect the build log.", 7)
    digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
    lock = project / "Cargo.lock"
    if not lock.is_file():
        raise Refused("The Rust build did not record Cargo.lock; the result is not reproducible.", 7)
    record = {"sha256": digest, "arch": arch, "sdk": sdk, "rustc": rustc, "artifact": str(artifact),
              "cargo_lock_sha256": hashlib.sha256(lock.read_bytes()).hexdigest(),
              "container_sha256": row["sha256"], "image": IMAGE}
    (project / "build.json").write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    return {"ok": True, "name": name, **record, "next": f"exakit rust-udf deploy {name}"}


def create_sql(name: str, schema: str, features: list[str], path: str) -> str:
    if not FEATURE.fullmatch(schema):
        raise Refused("Schema must be a plain SQL name.")
    if (not isinstance(features, list) or not features
            or not all(isinstance(item, str) and FEATURE.fullmatch(item) for item in features)):
        raise Refused("Rust feature names must be plain SQL identifiers.")
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


def install_container_library(row: dict, artifact: Path, sha256: str) -> dict:
    from rust_container import install
    try:
        deployment = os.environ.get("EXAKIT_RUST_DEPLOYMENT", "")
        if not deployment:
            raise ValueError("The kit deployment directory is unavailable; run exakit status.")
        return install(kit_home(), row, artifact, sha256,
                       os.environ.get("EXAKIT_RUST_LAUNCHER", ""),
                       Path(deployment))
    except (OSError, ValueError, KeyError, TypeError, tarfile.TarError) as error:
        raise Refused(str(error) if isinstance(error, ValueError) else
                      "The Rust container fallback could not be prepared; check the launcher, disk and container mirror.",
                      6, "exakit status", "install") from error


def _ready_after_restart():
    deadline = time.monotonic() + 150
    while True:
        conn = None
        try:
            conn = _connect()
            conn.execute("SELECT 1")
            return conn
        except Exception:
            if conn is not None:
                try:
                    conn.close()
                except Exception:
                    pass
            if time.monotonic() >= deadline:
                raise Refused("The database did not become ready after the Rust container update.", 5,
                              "exakit status", "restart") from None
            time.sleep(2)


def deploy(name: str, schema: str, *, yes: bool = False) -> dict:
    from rust_container import bucket_visible, installed_library, current_receipt
    project = project_path(name)
    try:
        built = json.loads((project / "build.json").read_text(encoding="utf-8"))
        meta = json.loads((project / "exakit-rust.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise Refused(f"{name} has no validated build record: {error}", 4,
                      f"exakit rust-udf build {name}") from error
    if not isinstance(built, dict) or not isinstance(meta, dict) or not built.get("artifact") or not meta.get("features"):
        raise Refused("The Rust build record or project metadata is incomplete; rebuild the UDF.", 7,
                      f"exakit rust-udf build {name}")
    artifact = Path(built["artifact"])
    if artifact.absolute() != (project / "target/release" / f"lib{name}.so").absolute():
        raise Refused("The Rust artifact path is outside this project's build output; rebuild it.", 7,
                      f"exakit rust-udf build {name}")
    arch = architecture()
    row = rust_pins(arch)
    if (not artifact.is_file() or hashlib.sha256(artifact.read_bytes()).hexdigest() != built["sha256"]
            or built.get("arch") != arch or built.get("sdk") != row["crates"]["exasol-udf-sdk"]
            or built.get("rustc") != row["runtime"]["rustc"]):
        raise Refused("The compiled Rust library changed or has the wrong architecture, SDK or rustc; rebuild it.", 7,
                      f"exakit rust-udf build {name}")
    lock = project / "Cargo.lock"
    if (not lock.is_file() or built.get("cargo_lock_sha256") != hashlib.sha256(lock.read_bytes()).hexdigest()
            or built.get("container_sha256") != row["sha256"]):
        raise Refused("The Cargo lockfile or pinned Rust container changed; rebuild the library.", 7,
                      f"exakit rust-udf build {name}")
    create_sql(name, schema, meta["features"], "/opt/exakit/udf/" + artifact.name)
    rust_installed(row)
    bucket = Path(os.environ.get("EXAKIT_RUST_BUCKET_DIR", ""))
    root = os.environ.get("EXAKIT_RUST_UDF_ROOT", "")
    fallback = not bucket.is_dir() or not root.startswith("/buckets/")
    conn = None
    if not fallback:
        _copy_library(bucket, artifact, built["sha256"])
        conn = _connect()
        try:
            fallback = not bucket_visible(conn, f"{root.rstrip('/')}/udf/{artifact.name}", built["sha256"])
        except Exception:
            conn.close()
            raise
    retained = installed_library(kit_home(), row, artifact.name, built["sha256"]) if fallback else {}
    if fallback and not retained and not yes:
        if conn is not None:
            conn.close()
        raise Refused("The shared bucket is unavailable. Packing the Rust library into its container restarts the database; confirm with --yes.",
                      5, f"exakit rust-udf deploy {name} --schema {schema.upper()} --yes", "confirm")
    restarted = False
    if fallback:
        if conn is not None:
            conn.close()
        if retained:
            result = retained
            conn = _connect()
        else:
            print("The shared bucket is unavailable; updating the RUST container with this library restarts the database.", file=sys.stderr)
            result = install_container_library(row, artifact, built["sha256"])
            restarted = True
            conn = _ready_after_restart()
        udf_path = f"/opt/exakit/udf/{artifact.name}"
    else:
        result = current_receipt(kit_home(), row) or {"container_sha256": row["sha256"]}
        udf_path = f"{root.rstrip('/')}/udf/{artifact.name}"
    sql = create_sql(name, schema, meta["features"], udf_path)
    conn = conn or _connect()
    try:
        conn.execute(f"CREATE SCHEMA IF NOT EXISTS {schema.upper()}")
        conn.execute(sql)
        # Loading the library is part of deployment success, not left for the notebook.
        conn.execute(f"SELECT {schema.upper()}.{name.upper()}(" + ", ".join("0.0" for _ in meta["features"]) + ")").fetchall()
    finally:
        conn.close()
    return {"ok": True, "name": name, "schema": schema.upper(), "udf": f"{schema.upper()}.{name.upper()}",
            "path": udf_path, "sha256": built["sha256"], "features": meta["features"],
            "deployment": "container" if fallback else "bucket", **result,
            "database_restart_requested": restarted}


def _copy_library(bucket: Path, artifact: Path, expected: str) -> None:
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
    if hashlib.sha256(destination.read_bytes()).hexdigest() != expected:
        raise Refused("The copied Rust library failed SHA-256 verification.", 7)


def main(argv: list[str]) -> int:
    parser = ArgumentParser(prog="exakit rust-udf")
    parser.add_argument("action", choices=("new", "build", "deploy"))
    parser.add_argument("name")
    parser.add_argument("--coefficients")
    parser.add_argument("--schema", default="EXAKIT_SCORING")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--yes", action="store_true")
    try:
        args = parser.parse_args(argv)
        if args.action != "new" and args.coefficients:
            raise Refused("--coefficients belongs to rust-udf new.")
        if args.action != "deploy" and args.schema != "EXAKIT_SCORING":
            raise Refused("--schema belongs to rust-udf deploy.")
        if args.yes and args.action != "deploy":
            raise Refused("--yes belongs to rust-udf deploy.")
        answer = (create(args.name, args.coefficients) if args.action == "new" else
                  build(args.name) if args.action == "build" else deploy(args.name, args.schema, yes=args.yes))
        if args.json:
            print(json.dumps(answer))
        else:
            print(f"Rust UDF {args.name}: {args.action} complete.")
            for key, value in answer.items():
                if key not in ("ok", "name"):
                    print(f"  {key}: {value}")
        return 0
    except Exception as failure:
        # Driver/launcher exceptions can include connection options. Keep the
        # public error contract useful without exposing their raw diagnostic.
        error = failure if isinstance(failure, Refused) else Refused(
            "The Rust UDF command failed; check exakit status and the project build record.",
            6, "exakit status", "deploy" if argv and argv[0] == "deploy" else "build")
        payload = {"ok": False, "error": str(error), "reason": str(error),
                   "step": error.step or (argv[0] if argv else None),
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
