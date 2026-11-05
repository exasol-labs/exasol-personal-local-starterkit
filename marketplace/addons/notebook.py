"""Notebook connector and front-end lifecycle shared by every platform.

The notebooks and helper packages are release files. Existing user notebooks
and an externally installed JupyterLab are never overwritten or removed.
"""

from __future__ import annotations

import os
import platform
import re
import secrets
import shutil
import socket
import subprocess
import sys
from pathlib import Path

import kit_telemetry
from model import load_addons
from runtime import AddonFailure, KitContext, venv_executable, venv_python, write_private, host_machine

ID = "notebook"
RECEIPT = "components.notebook"
PACKAGE = "exasol-notebook-connector"
IMPORT_CHECK = ("import exasol.nb_connector, exakit.nb, exakit_nb, exasol_mlflow, ipykernel; "
                "from exasol.nb_connector.ui.access import access_store")
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
        write_private(target, secrets.token_urlsafe(36) + "\n")
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


def _linux_arm() -> bool:
    return sys.platform.startswith("linux") and host_machine().lower() in ("aarch64", "arm64")


def _intel_mac() -> bool:
    """macOS on an Intel processor. Asked of the hardware, not of this Python: one running under Rosetta 2 reports
    x86_64 on an Apple silicon Mac, where the notebook environment is built native and works."""
    if sys.platform != "darwin" or host_machine().lower() not in ("x86_64", "amd64", "i386"):
        return False
    try:
        answer = subprocess.run(["sysctl", "-n", "hw.optional.arm64"], capture_output=True, text=True, check=False,
                                timeout=5).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return True
    return answer != "1"


def applicable(ctx: KitContext) -> bool:
    """Not on Linux Arm (audit LNX-07) or an Intel Mac (audit MAC-05): the connector needs a package that publishes
    no build for either (bitsandbytes, through the transformers extension), so the install could only fail. It is
    not offered there, as its help says, and a persona that brings it skips it with the reason instead."""
    return not (_linux_arm() or _intel_mac())


def applicable_reason(ctx: KitContext) -> str:
    where = "an Intel Mac" if _intel_mac() else "Linux Arm"
    return (f"the notebook connector has no build for {where} (one of its dependencies publishes none); it runs on "
            "Linux x86_64, macOS on Apple silicon and Windows")


def installed_version(ctx: KitContext) -> str | None:
    return _package_version(ctx) if ctx.manifest.get(f"{RECEIPT}.version") else None


def _frontends(ctx: KitContext) -> tuple[str, ...]:
    raw = os.environ.get("EXAKIT_NOTEBOOK_FRONTENDS")
    if raw is None:
        raw = ctx.manifest.get(f"{RECEIPT}.front_ends")
    if raw is None or raw == "":
        skipped = {"skip", "no", "0", "false", "none"}
        # JupyterLab and Marimo. Positron stays supported here (EXAKIT_NOTEBOOK_FRONTENDS=positron) but is not
        # offered or picked by default until it is fully supported and tested.
        defaults = []
        if os.environ.get("EXAKIT_NOTEBOOK_JUPYTER", "").lower() not in skipped:
            defaults.append("jupyterlab")
        if os.environ.get("EXAKIT_NOTEBOOK_MARIMO", "").lower() not in skipped:
            defaults.append("marimo")
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
    # Connector 3.1 imports Docker UI types even when opening a local database store.
    extras = "bucketfs,docker-db,ibis,pyexasol,sqlalchemy,notebook-dependencies"
    install_jupyter = "jupyterlab" in selected and not _external_jupyter(ctx)
    if install_jupyter or venv_executable(venv, "jupyter-lab").is_file():
        extras += ",jupyter"
    # No pyexasol pin here: the connector pins pydantic==2.11.5 (3.1.0 and 4.0.0 alike) and every pyexasol from 2.4.0
    # needs pydantic>=2.13.4, so the connector's own pyexasol (2.3.x) is the only one that resolves. The kit's
    # separate pyexasol environment keeps the 2.4.1 default (setup/lib/pyexasol.sh).
    specs = [f"{PACKAGE}[{extras}]=={version}", f"scikit-learn=={_sklearn_pin(ctx)}", *COMPANIONS]
    if install_jupyter or venv_executable(venv, "jupyter-lab").is_file():
        specs.append(f"jupyterlab=={_pin(ctx, 'jupyterlab')}")
    if "marimo" in selected or venv_executable(venv, "marimo").is_file():
        specs.append(f"marimo=={_pin(ctx, 'marimo')}")
    specs.extend((str(ctx.root / "notebook" / "package"), str(ctx.root / "packages" / "exasol-mlflow")))
    return specs


def _stages(ctx: KitContext, version: str, selected: tuple[str, ...]) -> list[tuple[str, list[str]]]:
    """(what the activity line says, the specs) for each step of the install, so the table says which part is
    installing: the connector and the kit's helpers, then JupyterLab, then Marimo. Each step asks for everything
    before it as well, and the last asks for exactly _specs(): one resolution, as when it was a single command."""
    final = _specs(ctx, version, selected)
    tools = {spec.split("==", 1)[0]: spec for spec in final if spec.startswith(("jupyterlab==", "marimo=="))}
    connector = next(spec for spec in final if spec.startswith(f"{PACKAGE}["))
    plain = connector.replace(",jupyter]", "]")           # the jupyter extra comes with JupyterLab's step
    base = [plain if spec == connector else spec for spec in final if spec not in tools.values()]
    stages = [(f"Installing notebook connector {version}", base)]   # short: the activity cell is ~44 wide
    so_far = list(base)
    if "jupyterlab" in tools:
        so_far = [connector if spec == plain else spec for spec in so_far] + [tools["jupyterlab"]]
        stages.append((f"Installing JupyterLab {tools['jupyterlab'].split('==', 1)[1]}", list(so_far)))
    if "marimo" in tools:
        so_far = [connector if spec == plain else spec for spec in so_far] + [tools["marimo"]]
        stages.append((f"Installing Marimo {tools['marimo'].split('==', 1)[1]}", list(so_far)))
    return stages


def _notebook_script(ctx: KitContext, name: str) -> Path:
    return ctx.root / "notebook" / "kit" / name


def _run_helper(ctx: KitContext, name: str, *args: str, env: dict[str, str] | None = None) -> str:
    python = venv_python(paths(ctx)[0])
    # The helpers open the database through the notebook connector (pyexasol)
    # and register_kernel.py copies the variable into the kernel spec.
    env = kit_telemetry.default_off(dict(os.environ) if env is None else dict(env))
    result = subprocess.run([str(python), str(_notebook_script(ctx, name)), *args], env=env,
                            capture_output=True, text=True, check=False, timeout=60)
    if result.returncode:
        raise AddonFailure(f"Notebook {name} failed; see exakit logs setup")
    return result.stdout.strip()


def _personas(ctx: KitContext) -> str:
    """The personas this kit was set up as (persona.id): their notebooks are the ones copied."""
    recorded = ctx.manifest.get("persona.id") or os.environ.get("EXAKIT_PERSONA") or ""
    return ",".join(part for part in str(recorded).split(",") if re.fullmatch(r"[a-z0-9][a-z0-9_-]*", part))


def _copy(ctx: KitContext, frontend: str) -> None:
    _, _, folder = paths(ctx)
    # This helper tracks copied files and intentionally respects edits/deletes.
    try:
        result = _run_helper(ctx, "notebooks.py", "copy", frontend, str(ctx.root), str(folder), _personas(ctx))
    except AddonFailure:
        ctx.activity(f"Some {frontend} notebooks could not be copied; existing files were kept")
        return
    if result:
        ctx.activity(f"New {frontend} notebooks: {result.replace(chr(10), ', ')}")


HELPER_PACKAGES = (("exakit-nb", ("notebook", "package")), ("exasol-mlflow", ("packages", "exasol-mlflow")))


def _helpers_digest(ctx: KitContext) -> str:
    """What the kit's own two packages (the exakit.nb helpers and exasol-mlflow) are in this kit copy."""
    import hashlib

    digest = hashlib.sha256()
    for _, parts in HELPER_PACKAGES:
        base = ctx.root.joinpath(*parts)
        for path in sorted(base.rglob("*")):
            relative = path.relative_to(base).parts
            if not path.is_file() or relative[0] == "build" or "__pycache__" in relative or \
                    any(part.endswith(".egg-info") for part in relative):
                continue
            digest.update("/".join(relative).encode("utf-8") + b"\0" + path.read_bytes())
    return digest.hexdigest()


def sync_helpers(ctx: KitContext) -> bool:
    """Reinstall the kit's own packages into the notebook environment when this kit copy carries other code than the
    one they were installed from. `exakit update exakit` moves the notebooks forward, and they import these helpers:
    left at the old kit's code, a refreshed notebook called helpers that were not there yet (DAY-07)."""
    if ctx.manifest.get(f"{RECEIPT}.ownership") != "kit":
        return False
    python = venv_python(paths(ctx)[0])
    if not python.is_file():
        return False
    digest = _helpers_digest(ctx)
    if ctx.manifest.get(f"{RECEIPT}.helpers_digest") == digest:
        return False
    sources = [ctx.root.joinpath(*parts) for _, parts in HELPER_PACKAGES]
    for source in sources:
        if (source / "build").is_dir():
            shutil.rmtree(source / "build")
    command = [str(ctx.require_uv()), "pip", "install", "--python", str(python)]
    for name, _ in HELPER_PACKAGES:
        command += ["--reinstall-package", name]
    ctx.run_logged("Updating the notebook helpers to this kit", *command, *(str(source) for source in sources))
    ctx.manifest.set_many({f"{RECEIPT}.helpers_digest": digest})
    return True


def sync_notebooks(ctx: KitContext) -> None:
    """The notebooks of every persona now recorded, for the front ends installed: a persona added later brings its
    folder (and the README names it). Nothing is overwritten or brought back after a delete."""
    if ctx.manifest.get(f"{RECEIPT}.ownership") != "kit":
        return
    venv = paths(ctx)[0]
    sync_helpers(ctx)
    _copy(ctx, "jupyter")
    if venv_executable(venv, "marimo").is_file():
        _copy(ctx, "marimo")


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
        ctx.run_logged(f"Creating notebook environment (Python {ctx.managed_python_version})", str(ctx.uv), "venv", "--python", ctx.managed_python_version, str(venv))
    for local in (ctx.root / "notebook" / "package" / "build", ctx.root / "packages" / "exasol-mlflow" / "build"):
        if local.is_dir():
            shutil.rmtree(local)
    for number, (label, specs) in enumerate(_stages(ctx, version, selected)):
        command = [str(ctx.uv), "pip", "install", "--python", str(python)]
        if number == 0:                                   # the kit's own two packages, rebuilt once
            command += ["--reinstall-package", "exakit-nb", "--reinstall-package", "exasol-mlflow"]
        if sys.platform != "darwin":
            command.extend(("--torch-backend", "cpu"))
        ctx.run_logged(label, *command, *specs)
    ctx.activity("Validating notebook connector")
    if _package_version(ctx) != version:
        raise AddonFailure("The notebook connector does not report the requested version")
    ctx.manifest.set_many({f"{RECEIPT}.helpers_digest": _helpers_digest(ctx)})
    ctx.activity("Placing notebooks and the kernel")
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


def tool_outcomes(ctx: KitContext) -> list[tuple[str, str, str]]:
    """What became of each tool, for its own row in the add-ons table after an install: (tool, done or
    skipped, what to say). Read from what the install left, so it is true whoever asks."""
    from notebook_cli import _positron_command

    selected = set(_frontends(ctx))
    venv = paths(ctx)[0]
    outcomes = []
    if "jupyterlab" not in selected:
        outcomes.append(("jupyterlab", "skipped", "skipped"))
    elif venv_executable(venv, "jupyter-lab").is_file():
        outcomes.append(("jupyterlab", "done", f"installed {_pin(ctx, 'jupyterlab')}"))
    elif _external_jupyter(ctx):
        outcomes.append(("jupyterlab", "done", "yours, kernel added"))
    else:
        outcomes.append(("jupyterlab", "skipped", "not installed - see the log"))
    if "marimo" not in selected:
        outcomes.append(("marimo", "skipped", "skipped"))
    elif venv_executable(venv, "marimo").is_file():
        outcomes.append(("marimo", "done", f"installed {_pin(ctx, 'marimo')}"))
    else:
        outcomes.append(("marimo", "skipped", "not installed - see the log"))
    if "positron" not in selected:
        pass  # not offered on any screen: no row to say "skipped" on
    elif _positron_command():
        outcomes.append(("positron", "done", "configured"))
    else:
        outcomes.append(("positron", "skipped", "not on this machine - folder ready"))
    return outcomes


def validate(ctx: KitContext) -> bool:
    python = venv_python(paths(ctx)[0])
    if not python.is_file():
        ctx.manifest.set_many({f"{RECEIPT}.validated": False})
        return False
    result = subprocess.run([str(python), "-c", IMPORT_CHECK],
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


def _stop_services(ctx: KitContext) -> tuple[list[tuple[str, int]], bool]:
    """Stop what runs from the notebook environment before it is reinstalled (DAY-08): JupyterLab, Marimo and
    udf-devkit's MLflow server. On Windows their open files block the reinstall; elsewhere they would go on
    running half-replaced packages. Returns what was running - the notebook tools with their ports, and
    whether MLflow was - so the update can start exactly those again."""
    from notebook_cli import OnDemandServer

    fronts = []
    for front, key, default in (("jupyterlab", "port", 8888), ("marimo", "marimo_port", 2718)):
        server = OnDemandServer(ctx, front)
        if server.pid():
            fronts.append((front, server.recorded_port(int(ctx.manifest.get(f"{RECEIPT}.{key}", default)))))
            server.stop()
    mlflow = False
    if ctx.manifest.get("components.udf_devkit.version"):
        from addons import udf_devkit

        try:
            mlflow = udf_devkit.status(ctx) == "running"
            if mlflow:
                udf_devkit.stop(ctx)
        except (AddonFailure, OSError):
            mlflow = False
    names = [{"jupyterlab": "JupyterLab", "marimo": "Marimo"}[front] for front, _ in fronts] + (["MLflow"] if mlflow else [])
    if names:
        ctx.activity("stopped " + ", ".join(names) + " for the update; starting them again after it")
    return fronts, mlflow


def _restart_services(ctx: KitContext, fronts: list[tuple[str, int]], mlflow: bool) -> None:
    """Start again what _stop_services stopped, on the same ports, without opening a browser. A service that does
    not come back is named with the command that starts it; it never fails the update."""
    import io
    from contextlib import redirect_stdout

    import notebook_cli

    for front, port in fronts:
        try:
            with redirect_stdout(io.StringIO()):
                notebook_cli._start_frontend(ctx, front, port, False, False)
        except (AddonFailure, OSError) as error:
            again = "exakit notebook" if front == "jupyterlab" else "exakit notebook marimo"
            ctx.activity(f"{front} did not start again ({error}); start it with: {again}")
    if mlflow:
        from addons import udf_devkit

        try:
            udf_devkit.start(ctx)
        except (AddonFailure, OSError) as error:
            ctx.activity(f"MLflow did not start again ({error}); start it with: exakit mlflow start")


def update(ctx: KitContext) -> None:
    if ctx.manifest.get(f"{RECEIPT}.ownership") != "kit":
        raise AddonFailure("Notebook is not kit-owned; its owner manages updates")
    fronts, mlflow = _stop_services(ctx)
    try:
        install(ctx)
        if not validate(ctx):
            raise AddonFailure("Notebook did not validate after the update")
        ctx.manifest.set_many({"desired.notebook": ctx.manifest.get(f"{RECEIPT}.version")})
    finally:
        _restart_services(ctx, fronts, mlflow)


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
    if os.environ.get("EXAKIT_UNINSTALL_FULL") != "1" and ctx.manifest.get("components.udf_devkit.version"):
        # Said, not refused: removing both in either order is fine. udf-devkit's
        # status names the same thing until the notebook is back (DAY-06).
        ctx.activity("udf-devkit's MLflow server and UDF build tools ran from this environment; "
                     "reinstall with exakit marketplace notebook, or remove them too: exakit uninstall udf-devkit")
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
    # The add-on's folder and the credentials folder go only when nothing else lives in them.
    for folder in (home, ctx.home / "credentials"):
        try:
            folder.rmdir()
        except OSError:
            pass
    ctx.manifest.delete(RECEIPT, "desired.notebook")
    return targets
