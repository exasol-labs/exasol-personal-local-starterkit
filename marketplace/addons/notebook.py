"""Notebook connector and front-end lifecycle shared by every platform.

The notebooks and helper packages are release files. Existing user notebooks
and an externally installed JupyterLab are never overwritten or removed.
"""

from __future__ import annotations

import os
import re
import secrets
import shutil
import socket
import subprocess
import sys
from pathlib import Path

from model import load_addons
from runtime import AddonFailure, KitContext, venv_executable, venv_python

ID = "notebook"
RECEIPT = "components.notebook"
PACKAGE = "exasol-notebook-connector"
KERNEL = "exasol-starter-kit"
KERNEL_TITLE = "Exasol (Starter Kit)"
FRONTENDS = ("jupyterlab", "marimo", "positron")
COMPANIONS = (
    "ipykernel>=6.29,<8", "langfuse>=5,<6", "openai>=1.40,<3",
    "mlflow-skinny>=3,<4", "alembic>=1.13,<2", "pyarrow>=14",
    "pandas>=2,<3", "numpy>=1.26,<3", "scipy>=1.10,<2", "joblib>=1.5,<2",
)


def paths(ctx: KitContext) -> tuple[Path, Path, Path]:
    # Once installed, receipts anchor paths. A changed environment override
    # must not make an update or uninstall operate on an unrelated directory.
    recorded_venv = ctx.manifest.get(f"{RECEIPT}.venv")
    recorded_store = ctx.manifest.get(f"{RECEIPT}.store_file")
    recorded_notebooks = ctx.manifest.get(f"{RECEIPT}.notebooks_dir")
    return (Path(recorded_venv) if recorded_venv else ctx.path("EXAKIT_NOTEBOOK_VENV", ctx.home / "notebook-venv"),
            Path(recorded_store).parent if recorded_store else ctx.path("EXAKIT_NOTEBOOK_HOME", ctx.home / "notebook"),
            Path(recorded_notebooks) if recorded_notebooks else ctx.path("EXAKIT_NOTEBOOK_DIR", ctx.home / "notebooks"))


def _credential(ctx: KitContext, name: str) -> Path:
    folder = ctx.home / "credentials"
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / name
    if not target.is_file() or not target.read_text(encoding="utf-8").strip():
        target.write_text(secrets.token_urlsafe(36) + "\n", encoding="utf-8")
    if os.name != "nt":
        target.chmod(0o600)
    return target


def _package_version(ctx: KitContext) -> str | None:
    python = venv_python(paths(ctx)[0])
    if not python.is_file():
        return None
    try:
        result = subprocess.run([str(python), "-c",
                                 "from importlib.metadata import version; print(version('exasol-notebook-connector'))"],
                                capture_output=True, text=True, check=False, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return result.stdout.strip() if result.returncode == 0 else None


def installed_version(ctx: KitContext) -> str | None:
    return _package_version(ctx) if ctx.manifest.get(f"{RECEIPT}.version") else None


def _frontends(ctx: KitContext) -> tuple[str, ...]:
    raw = os.environ.get("EXAKIT_NOTEBOOK_FRONTENDS")
    if raw is None:
        raw = ctx.manifest.get(f"{RECEIPT}.front_ends")
    if raw is None or raw == "":
        skipped = {"skip", "no", "0", "false", "none"}
        defaults = ["positron"]
        if os.environ.get("EXAKIT_NOTEBOOK_JUPYTER", "").lower() not in skipped:
            defaults.insert(0, "jupyterlab")
        if os.environ.get("EXAKIT_NOTEBOOK_MARIMO", "").lower() not in skipped:
            defaults.insert(-1, "marimo")
        raw = ",".join(defaults)
    if not isinstance(raw, str):
        raise AddonFailure("notebook front_ends receipt is invalid")
    selected = [part.lower() for part in re.split(r"[,;\s]+", raw.strip()) if part]
    selected = ["jupyterlab" if part == "jupyter" else part for part in selected]
    if selected == ["none"]:
        return ()
    selected = [part for part in selected if part != "none"]
    unknown = set(selected) - set(FRONTENDS)
    if unknown or len(selected) != len(set(selected)):
        raise AddonFailure(f"Unknown or repeated notebook frontend: {raw}")
    return tuple(name for name in FRONTENDS if name in selected)


def validate_selection(ctx: KitContext) -> None:
    """Reject malformed frontend answers before a multi-add-on apply begins."""
    _frontends(ctx)


def _pin(ctx: KitContext, frontend: str) -> str:
    override = os.environ.get("EXAKIT_NOTEBOOK_" + frontend.upper() + "_VERSION")
    version = override
    if version is None:
        document = ctx.versions_document()
        version = document.get("components", {}).get("notebook", {}).get("frontends", {}).get(frontend, "")
    if not isinstance(version, str) or not version or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-" for c in version):
        raise AddonFailure(f"No safe {frontend} pin in versions.json")
    return version


def _sklearn_pin(ctx: KitContext) -> str:
    document = ctx.versions_document()
    rows = document.get("components", {}).get("udf-devkit", {}).get("containers", [])
    pins = {row.get("packages", {}).get("scikit-learn") for row in rows if row.get("language") == "python"}
    if len(pins) != 1 or None in pins:
        raise AddonFailure("Python UDF container rows need one shared scikit-learn pin")
    return pins.pop()


def _external_jupyter(ctx: KitContext) -> Path | None:
    venv, _, _ = paths(ctx)
    for name in ("jupyter-lab", "jupyter-notebook"):
        found = shutil.which(name)
        if found and not Path(found).is_relative_to(venv) and not Path(found).is_relative_to(ctx.home):
            return Path(found)
    return None


def _specs(ctx: KitContext, version: str, selected: tuple[str, ...]) -> list[str]:
    venv, _, _ = paths(ctx)
    extras = "bucketfs,ibis,pyexasol,sqlalchemy,notebook-dependencies"
    install_jupyter = "jupyterlab" in selected and not _external_jupyter(ctx)
    if install_jupyter or venv_executable(venv, "jupyter-lab").is_file():
        extras += ",jupyter"
    specs = [f"{PACKAGE}[{extras}]=={version}", f"scikit-learn=={_sklearn_pin(ctx)}", *COMPANIONS]
    if install_jupyter or venv_executable(venv, "jupyter-lab").is_file():
        specs.append(f"jupyterlab=={_pin(ctx, 'jupyterlab')}")
    if "marimo" in selected or venv_executable(venv, "marimo").is_file():
        specs.append(f"marimo=={_pin(ctx, 'marimo')}")
    specs.extend((str(ctx.root / "notebook" / "package"), str(ctx.root / "packages" / "exasol-mlflow")))
    return specs


def _notebook_script(ctx: KitContext, name: str) -> Path:
    return ctx.root / "notebook" / "kit" / name


def _run_helper(ctx: KitContext, name: str, *args: str, env: dict[str, str] | None = None) -> str:
    python = venv_python(paths(ctx)[0])
    result = subprocess.run([str(python), str(_notebook_script(ctx, name)), *args], env=env,
                            capture_output=True, text=True, check=False, timeout=60)
    if result.returncode:
        raise AddonFailure(f"Notebook {name} failed; see exakit logs setup")
    return result.stdout.strip()


def _copy(ctx: KitContext, frontend: str) -> None:
    _, _, folder = paths(ctx)
    # This helper tracks copied files and intentionally respects edits/deletes.
    try:
        result = _run_helper(ctx, "notebooks.py", "copy", frontend, str(ctx.root), str(folder))
    except AddonFailure:
        ctx.activity(f"Some {frontend} notebooks could not be copied; existing files were kept")
        return
    if result:
        ctx.activity(f"New {frontend} notebooks: {result.replace(chr(10), ', ')}")


def _write_store(ctx: KitContext) -> None:
    _, home, _ = paths(ctx)
    dsn = ctx.manifest.get("runtime.dsn", "")
    password_file = ctx.manifest.get("runtime.password_file", "")
    user = ctx.manifest.get("runtime.user", "sys")
    try:
        host, port = str(dsn).rsplit(":", 1)
        int(port)
    except (TypeError, ValueError) as error:
        raise AddonFailure("The database connection record is incomplete") from error
    if not password_file or not Path(password_file).is_file():
        raise AddonFailure("The database credential file is missing")
    home.mkdir(parents=True, exist_ok=True)
    store = home / "connection.scs"
    master_path = ctx.home / "credentials" / "notebook_store_master_password"
    if store.is_file() and (not master_path.is_file() or not master_path.read_text(encoding="utf-8").strip()):
        store.unlink()
    master = _credential(ctx, "notebook_store_master_password")
    env = {**os.environ, "SCS_FILE": str(store), "SCS_MASTER_PASSWORD": master.read_text(encoding="utf-8").strip(),
           "EXAKIT_NB_HOST": host, "EXAKIT_NB_PORT": port, "EXAKIT_NB_USER": str(user),
           "EXAKIT_NB_PWFILE": str(password_file),
           "EXAKIT_NB_SCHEMA": os.environ.get("EXAKIT_NOTEBOOK_SCHEMA", "STARTER_KIT")}
    try:
        _run_helper(ctx, "write_store.py", env=env)
    except AddonFailure:
        if not store.is_file():
            raise
        damaged = store.with_name(store.name + ".unreadable")
        os.replace(store, damaged)
        try:
            _run_helper(ctx, "write_store.py", env=env)
        except AddonFailure:
            os.replace(damaged, store)
            raise


def _register_kernel(ctx: KitContext) -> None:
    _, home, _ = paths(ctx)
    master = _credential(ctx, "notebook_store_master_password")
    env = {**os.environ, "EXAKIT_KERNEL_NAME": KERNEL, "EXAKIT_KERNEL_TITLE": KERNEL_TITLE,
           "EXAKIT_NB_STORE": str(home / "connection.scs"), "EXAKIT_NB_MASTER_FILE": str(master),
           "EXAKIT_NB_KIT": str(ctx.root), "EXAKIT_NB_DATASETS": str(ctx.root / "data" / "datasets")}
    _run_helper(ctx, "register_kernel.py", env=env)


def install(ctx: KitContext) -> None:
    if ctx.manifest.get(f"{RECEIPT}.ownership") in ("user", "unknown"):
        return
    ctx.require_uv()
    default = next(item.default_version for item in load_addons(ctx.root) if item.id == ID)
    version = ctx.target_version(ID, default)
    selected = _frontends(ctx)
    venv, home, notebooks = paths(ctx)
    python = venv_python(venv)
    if not python.is_file():
        if venv.is_dir() and (venv / "pyvenv.cfg").exists():
            shutil.rmtree(venv)
        ctx.run_logged("Creating notebook environment", str(ctx.uv), "venv", "--python", ctx.managed_python_version, str(venv))
    for local in (ctx.root / "notebook" / "package" / "build", ctx.root / "packages" / "exasol-mlflow" / "build"):
        if local.is_dir():
            shutil.rmtree(local)
    command = [str(ctx.uv), "pip", "install", "--python", str(python),
               "--reinstall-package", "exakit-nb", "--reinstall-package", "exasol-mlflow"]
    if sys.platform != "darwin":
        command.extend(("--torch-backend", "cpu"))
    command.extend(_specs(ctx, version, selected))
    ctx.run_logged(f"Installing notebook connector {version} and selected frontends", *command)
    if _package_version(ctx) != version:
        raise AddonFailure("The notebook connector does not report the requested version")
    notebooks.mkdir(parents=True, exist_ok=True)
    _copy(ctx, "jupyter")
    if "marimo" in selected:
        _copy(ctx, "marimo")
    if "positron" in selected:
        try:
            _run_helper(ctx, "notebooks.py", "positron", str(notebooks), str(python), str(venv))
        except AddonFailure:
            ctx.activity(f"Positron settings were left alone; select {python} in Positron manually")
    _write_store(ctx)
    _register_kernel(ctx)
    ctx.manifest.set_many({
        f"{RECEIPT}.version": version, f"{RECEIPT}.ownership": "kit",
        f"{RECEIPT}.venv": str(venv), f"{RECEIPT}.python": str(python),
        f"{RECEIPT}.notebooks_dir": str(notebooks), f"{RECEIPT}.store_file": str(home / "connection.scs"),
        f"{RECEIPT}.master_file": str(ctx.home / "credentials" / "notebook_store_master_password"),
        f"{RECEIPT}.kernel": KERNEL, f"{RECEIPT}.front_ends": ",".join(selected) or "none",
        f"{RECEIPT}.jupyter": "kit" if venv_executable(venv, "jupyter-lab").is_file() else "user" if _external_jupyter(ctx) else "none",
        f"{RECEIPT}.marimo": "kit" if venv_executable(venv, "marimo").is_file() else "none",
    })


def validate(ctx: KitContext) -> bool:
    python = venv_python(paths(ctx)[0])
    if not python.is_file():
        ctx.manifest.set_many({f"{RECEIPT}.validated": False})
        return False
    result = subprocess.run([str(python), "-c", "import exasol.nb_connector, exakit.nb, exakit_nb, exasol_mlflow, ipykernel"],
                            capture_output=True, check=False, timeout=30)
    if result.returncode:
        ctx.manifest.set_many({f"{RECEIPT}.validated": False})
        return False
    dsn = ctx.manifest.get("runtime.dsn", "")
    try:
        host, port = str(dsn).rsplit(":", 1)
        with socket.create_connection((host, int(port)), timeout=2):
            pass
    except (OSError, ValueError):
        ctx.manifest.set_many({f"{RECEIPT}.validated": True, f"{RECEIPT}.validated_by": "import"})
        return True
    try:
        _write_store(ctx)
        master = _credential(ctx, "notebook_store_master_password")
        _run_helper(ctx, "check_connection.py", env={**os.environ,
            "SCS_FILE": str(paths(ctx)[1] / "connection.scs"),
            "SCS_MASTER_PASSWORD": master.read_text(encoding="utf-8").strip()})
    except AddonFailure:
        ctx.manifest.set_many({f"{RECEIPT}.validated": False})
        return False
    ctx.manifest.set_many({f"{RECEIPT}.validated": True, f"{RECEIPT}.validated_by": "connection"})
    return True


def update(ctx: KitContext) -> None:
    if ctx.manifest.get(f"{RECEIPT}.ownership") != "kit":
        raise AddonFailure("Notebook is not kit-owned; its owner manages updates")
    install(ctx)
    if not validate(ctx):
        raise AddonFailure("Notebook did not validate after the update")
    ctx.manifest.set_many({"desired.notebook": ctx.manifest.get(f"{RECEIPT}.version")})


def summary(ctx: KitContext) -> str:
    return "notebooks: exakit notebook"


def log_path(ctx: KitContext) -> list[str]:
    folder = Path(os.environ.get("EXAKIT_LOG_DIR", str(ctx.home / "logs")))
    return [f"notebook|JupyterLab (exakit notebook)|{folder / 'notebook.log'}",
            f"notebook-marimo|Marimo (notebook marimo)|{folder / 'notebook-marimo.log'}"]


def uninstall(ctx: KitContext, *, dry_run: bool = False) -> list[Path]:
    if ctx.manifest.get(f"{RECEIPT}.ownership") != "kit":
        raise AddonFailure("Notebook is not kit-owned; it will not be removed")
    venv, home, notebooks = paths(ctx)
    targets = [venv, home / "connection.scs", home / "connection.scs.unreadable",
               home / "jupyter.pid", home / "marimo.pid", home / "open-jupyter.html",
               home / "open-marimo.html", home / "jupyter_server_config.json",
               ctx.home / "credentials" / "notebook_store_master_password",
               ctx.home / "credentials" / "notebook_jupyter_token",
               ctx.home / "credentials" / "notebook_marimo_token"]
    remove_notebooks = os.environ.get("EXAKIT_UNINSTALL_NOTEBOOKS", "keep").lower() == "remove"
    if remove_notebooks:
        targets.append(notebooks)
    if dry_run:
        return [path for path in targets if path.exists()]
    from notebook_cli import OnDemandServer

    OnDemandServer(ctx, "jupyterlab").stop()
    OnDemandServer(ctx, "marimo").stop()
    if venv_python(venv).is_file():
        try:
            _run_helper(ctx, "remove_kernel.py", env={**os.environ, "EXAKIT_KERNEL_NAME": KERNEL})
        except AddonFailure:
            pass
    settings = notebooks / ".vscode" / "settings.json"
    if settings.exists() and venv_python(venv).is_file():
        try:
            _run_helper(ctx, "notebooks.py", "positron-remove", str(notebooks), str(venv_python(venv)), str(venv))
        except AddonFailure:
            pass
    if venv.exists():
        shutil.rmtree(venv)
    for target in targets[1:]:
        if target == notebooks and target.is_dir():
            shutil.rmtree(target)
        else:
            target.unlink(missing_ok=True)
    ctx.manifest.delete(RECEIPT, "desired.notebook")
    return targets
