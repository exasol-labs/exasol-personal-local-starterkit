"""Local connection and IPython support for the bundled Exasol example collection.

Marimo exposes editable cells with explicit Run buttons. IPython executes those
cells so SQL magics and shared Python variables retain their notebook meaning.
Opening a lesson never executes its database, download or installation cells.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import threading
from pathlib import Path

SCHEMA = "EXAKIT_EXAMPLES"
_LOCK = threading.RLock()


class ExampleConfig:
    def __init__(self, store):
        self._store = store

    def get(self, key, default_value=None):
        name = getattr(key, "name", key)
        defaults = {"db_schema": SCHEMA, "bfs_service": "bfsdefault", "bfs_bucket": "default"}
        return defaults[name] if name in defaults else self._store.get(key, default_value)

    def __getattr__(self, key):
        value = self.get(key)
        if value is not None:
            return value
        return getattr(self._store, key)

    def __getitem__(self, key):
        value = self.get(key)
        if value is None:
            raise KeyError(key)
        return value

    def __repr__(self):
        return "<Starter Kit example configuration: EXAKIT_EXAMPLES>"


def bootstrap(namespace, notebook=""):
    if notebook.startswith("cloud/"):
        raise RuntimeError("This cloud/external-source tutorial is bundled as reference material. "
                           "Its integration is outside the starter-kit notebook setup.")
    if notebook.startswith(("gpu_in_udf/", "transformers/", "text_ai/", "script_languages_container/")):
        if os.environ.get("EXAKIT_EXAMPLES_ADVANCED") != "1":
            raise RuntimeError("This lesson needs the additional services listed at its top. "
                               "Configure them first on a suitable deployment, then set "
                               "EXAKIT_EXAMPLES_ADVANCED=1 before starting the notebook tool.")
    from . import _store, connect
    config = ExampleConfig(_store())
    with connect() as conn:
        conn.execute(f"CREATE SCHEMA IF NOT EXISTS {SCHEMA}")
    namespace["ai_lab_config"] = config
    return config


def open_pyexasol_connection(conf, **kwargs):
    from exasol.nb_connector.connections import open_pyexasol_connection as original
    conn = original(conf, **kwargs)
    # Personal's release suffix is not PEP 440; pyexasol's HTTP import checks
    # packaging.Version. This connection belongs only to the example session.
    release = conn.login_info.get("releaseVersion", "")
    match = re.fullmatch(r"(\d+\.\d+\.\d+)-nano\.\d+", release)
    if match:
        conn.login_info["releaseVersion"] = match.group(1)
    return conn


def init_sql(conf):
    from IPython import get_ipython
    from exasol.nb_connector.connections import open_sqlalchemy_connection
    shell = get_ipython()
    if shell is None:
        raise RuntimeError("Run SQL cells in Jupyter or the bundled Marimo cell runner.")
    engine = open_sqlalchemy_connection(conf)
    shell.user_ns["engine"] = engine
    shell.run_line_magic("load_ext", "sql")
    shell.run_line_magic("sql", "engine")
    shell.run_line_magic("sql", f"OPEN SCHEMA {SCHEMA}")
    return engine


class LocalBucket:
    def __init__(self, root, udf_root, relative=Path()):
        self.root, self.udf_root, self.relative = Path(root), udf_root, Path(relative)
        if not (self.root / self.relative).resolve().is_relative_to(self.root.resolve()):
            raise ValueError("The file must stay inside the example bucket folder.")

    def __truediv__(self, name):
        return LocalBucket(self.root, self.udf_root, self.relative / name)

    @property
    def name(self):
        return self.relative.name

    def write(self, data):
        target = self.root / self.relative
        target.parent.mkdir(parents=True, exist_ok=True)
        part = target.with_name(target.name + ".part")
        part.write_bytes(data)
        part.replace(target)

    def upload(self, name, data):
        (self / name).write(data)

    def iterdir(self):
        folder = self.root / self.relative
        return ((self / child.name) for child in sorted(folder.iterdir()))

    def as_udf_path(self):
        return self.udf_root.rstrip("/") + ("/" + self.relative.as_posix() if self.relative.parts else "")


def open_bucketfs_location(conf=None):
    command = shutil.which("exakit") or str(Path.home() / ".local/bin/exakit")
    if os.name == "nt":
        command = shutil.which("exakit.cmd") or command + ".cmd"
    done = subprocess.run([command, "model", "list", "--json"], capture_output=True, text=True)
    if done.returncode:
        raise RuntimeError("The local file bucket is unavailable. Run: exakit model list")
    result = json.loads(done.stdout)
    root = Path(result["bucket_dir"]) / "exasol-examples"
    root.mkdir(parents=True, exist_ok=True)
    return LocalBucket(root, result["udf_root"] + "/exasol-examples")


open_bucketfs_connection = open_bucketfs_location
open_bucketfs_bucket = open_bucketfs_location


def get_udf_bucket_path(conf):
    return open_bucketfs_location(conf).as_udf_path()


def sklearn_version_check(conf):
    import sklearn
    from .checks import check_model_compatibility
    from .ml_train import udf_container
    with open_pyexasol_connection(conf) as conn:
        compatible = check_model_compatibility(conn, sklearn.__version__, alias=udf_container())
    if not compatible:
        raise RuntimeError("The notebook and UDF scikit-learn versions differ. Run: exakit udf-use default")
    print("The notebook and ML UDF scikit-learn versions match.")


def __getattr__(name):
    if name.startswith("__"):
        raise AttributeError(name)
    # Connection functions that need no adaptation keep the official behavior.
    from exasol.nb_connector import connections
    return getattr(connections, name)


class Lesson:
    def __init__(self, notebook, root=None):
        self.notebook = notebook
        home = Path(os.environ.get("EXAKIT_HOME") or Path.home() / ".exasol-starter-kit")
        self.root = Path(root) if root else home / "notebooks/marimo/exasol-examples"
        self.shell = None

    def run(self, source):
        from IPython.core.interactiveshell import InteractiveShell
        from IPython.utils.capture import capture_output
        with _LOCK:
            if self.shell is None:
                self.shell = InteractiveShell(user_ns={"__name__": "__main__"})
            previous = Path.cwd()
            try:
                os.chdir(self.root / Path(self.notebook).parent)
                # %run remains an IPython operation. Its utility notebooks are
                # the matching bundled Jupyter files, not lossy Python exports.
                def resolve_run(match):
                    value = match.group(1).strip().strip("\"'")
                    target = self.root.parent.parent / "starter-kit-notebooks/exasol-examples" / Path(self.notebook).parent / value
                    return "%run " + json.dumps(str(target.resolve()))
                source = re.sub(r"(?m)^%run\s+([^\n]+\.ipynb)\s*$", resolve_run, source)
                with self.shell.builtin_trap, capture_output() as captured:
                    result = self.shell.run_cell(source, store_history=False)
                error = result.error_before_exec or result.error_in_exec
                return {"stdout": captured.stdout, "stderr": captured.stderr,
                        "displays": [item.data for item in captured.outputs],
                        "error": str(error) if error else None}
            finally:
                os.chdir(previous)


def render(mo, result):
    blocks = []
    for key in ("stdout", "stderr"):
        if result[key].strip():
            blocks.append(mo.plain_text(result[key]))
    for item in result["displays"]:
        if "application/vnd.jupyter.widget-view+json" in item:
            blocks.append(mo.callout("This step uses a Jupyter widget. Use the matching Jupyter notebook for its widget UI, "
                                     "or set its Python values in an editable cell here.", kind="info"))
        elif "text/html" in item:
            blocks.append(mo.Html(item["text/html"]))
        elif "text/plain" in item:
            blocks.append(mo.plain_text(item["text/plain"]))
    if result["error"]:
        blocks.append(mo.callout(result["error"], kind="warn"))
    return mo.vstack(blocks) if blocks else mo.md("Cell finished.")
