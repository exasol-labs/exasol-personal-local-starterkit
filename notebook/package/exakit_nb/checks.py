"""The three things the ML Engineer's notebooks depend on, one check each (ml-engineer/00_quickstart): the database's
Python container answers a smoke UDF with the packages training needs, the MLflow server is reachable, and the bucket
directory is where the kit expects it. Each prints one line - ``ok`` with what it found, or ``FAIL`` with the reason
and the fix - and returns True or False, so the notebook shows all three before anything stops.

Nothing here prints a host, a user or a password; an MLflow address is shown without any credentials it holds.
"""

from __future__ import annotations

import json
import os
import subprocess
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from ._kit import exakit_command

__all__ = ["check_bucket", "check_container", "check_mlflow", "model_list"]

PROBE_SCHEMA = "EXAKIT_UDF"                   # the udf-devkit add-on's schema; the probe is a script of its own there
PROBE = "EXAKIT_NB_PROBE"
TRAINING_PACKAGES = ("scikit-learn", "pandas", "numpy")


def _report(what: str, ok: bool, detail: str, fix: str = "") -> bool:
    print(f"ok   {what}: {detail}" if ok else f"FAIL {what}: {detail}" + (f" Fix: {fix}" if fix else ""))
    return ok


def probe_script(alias: str, packages: tuple[str, ...]) -> str:
    """The CREATE SCRIPT of a UDF that reports Python, each package's version (or MISSING) and whether a path is a folder."""
    names = ", ".join(repr(p) for p in packages)
    return (f"CREATE OR REPLACE {alias} SCALAR SCRIPT {PROBE_SCHEMA}.{PROBE}(path VARCHAR(2000)) "
            "EMITS (NAME VARCHAR(200), VALUE VARCHAR(2000)) AS\n"
            "import os\n"
            "import sys\n"
            "from importlib import metadata\n"
            "def run(ctx):\n"
            "    ctx.emit('python', sys.version.split()[0])\n"
            f"    for name in [{names}]:\n"
            "        try:\n"
            "            ctx.emit(name, metadata.version(name))\n"
            "        except Exception:\n"
            "            ctx.emit(name, 'MISSING')\n"
            "    if ctx.path:\n"
            "        ctx.emit('path', 'folder' if os.path.isdir(ctx.path) else 'missing')\n")


def _probe(conn, alias: str = "PYTHON3", packages: tuple[str, ...] = TRAINING_PACKAGES, path: str = "") -> dict[str, str]:
    """What the probe UDF reports, as name -> value. Raises what the database raised."""
    conn.execute(f"CREATE SCHEMA IF NOT EXISTS {PROBE_SCHEMA}")
    conn.execute(probe_script(alias, packages))
    quoted = path.replace("'", "''")
    rows = conn.execute(f"SELECT {PROBE_SCHEMA}.{PROBE}('{quoted}')").fetchall()
    return {str(row[0]): str(row[1]) for row in rows}


def check_container(conn, alias: str = "PYTHON3", packages: tuple[str, ...] = TRAINING_PACKAGES) -> bool:
    """The container behind ``alias`` runs a smoke UDF, and it has every package training needs."""
    try:
        found = _probe(conn, alias, packages)
    except Exception as err:                                   # the database's own message says why
        reason = str(err).splitlines()[0][:300] if str(err) else type(err).__name__
        return _report("container", False, f"the smoke UDF on {alias} did not run ({reason}).",
                       "exakit udf-setup installs the Python container (the udf-devkit add-on: exakit marketplace udf-devkit).")
    missing = [p for p in packages if found.get(p, "MISSING") == "MISSING"]
    versions = ", ".join(f"{p} {found[p]}" for p in packages if p not in missing)
    if missing:
        return _report("container", False, f"Python {found.get('python', '?')} on {alias} lacks {', '.join(missing)}.",
                       "exakit udf-use default (the pre-built container with them), or exakit udf-build <requirements.txt>.")
    return _report("container", True, f"the smoke UDF answers on {alias}: Python {found.get('python', '?')}, {versions}.")


def _shown(uri: str) -> str:
    """A tracking URI without any user or password in it."""
    parts = urllib.parse.urlsplit(uri)
    if parts.username or parts.password:
        host = parts.hostname or ""
        netloc = f"{host}:{parts.port}" if parts.port else host
        return urllib.parse.urlunsplit((parts.scheme, netloc, parts.path, "", ""))
    return uri


def check_mlflow(timeout: float = 5.0) -> bool:
    """MLflow is importable, and the server MLFLOW_TRACKING_URI names answers its health check; without the variable,
    runs go to a local store beside the notebook, which needs no server."""
    try:
        import mlflow  # noqa: F401
    except ImportError:
        return _report("mlflow", False, "the MLflow client is not in the notebook environment.", "exakit update notebook")
    uri = os.environ.get("MLFLOW_TRACKING_URI", "").strip()
    if not uri:
        return _report("mlflow", True, "MLFLOW_TRACKING_URI is not set, so runs go to the local store mlflow/ beside the "
                                       "notebook (open it with: mlflow ui --backend-store-uri sqlite:///mlflow/mlflow.db).")
    shown = _shown(uri)
    if not uri.startswith(("http://", "https://")):
        return _report("mlflow", True, f"tracking store {shown} (not a server; nothing to reach).")
    try:
        with urllib.request.urlopen(uri.rstrip("/") + "/health", timeout=timeout) as answer:
            status = answer.status
    except urllib.error.HTTPError as err:
        status = err.code
    except (urllib.error.URLError, OSError) as err:
        reason = getattr(err, "reason", err)
        return _report("mlflow", False, f"the server at {shown} does not answer ({reason}).",
                       "start it (mlflow server --port 5000), or set MLFLOW_TRACKING_URI to the one you use, or unset it "
                       "for a local store - before exakit notebook.")
    if 200 <= status < 300:
        return _report("mlflow", True, f"the server at {shown} answers.")
    return _report("mlflow", False, f"the server at {shown} answers HTTP {status} to its health check.",
                   "check that MLFLOW_TRACKING_URI names an MLflow tracking server.")


def model_list(timeout: float = 120.0) -> dict[str, Any]:
    """What ``exakit model list --json`` says: bucket_dir (the host folder), udf_root (the path UDFs read it under) and
    the models in it. Raises RuntimeError naming why it could not be read."""
    command = exakit_command()
    if command is None:
        raise RuntimeError("the kit's command line (exakit) is not on PATH")
    done = subprocess.run([*command, "model", "list", "--json"], stdin=subprocess.DEVNULL, capture_output=True,
                          text=True, encoding="utf-8", errors="replace", timeout=timeout, check=False)
    if done.returncode != 0:
        said = (done.stderr or done.stdout).strip().splitlines()
        raise RuntimeError(f"exakit model list exited {done.returncode}" + (f": {said[-1]}" if said else ""))
    try:
        doc = json.loads(done.stdout)
    except ValueError as err:
        raise RuntimeError(f"exakit model list --json did not print JSON ({err})") from err
    if not isinstance(doc, dict) or not doc.get("bucket_dir") or not doc.get("udf_root"):
        raise RuntimeError("exakit model list --json names no bucket_dir and udf_root")
    return doc


def check_bucket(conn=None) -> bool:
    """The deployment's bucket directory exists on this machine where the kit says it is, and - given a connection -
    a UDF sees it at its /buckets path too (skipped, with a note, when the container check fails)."""
    try:
        doc = model_list()
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as err:
        return _report("bucket directory", False, f"the kit could not name it ({err}).",
                       "run exakit model list in a terminal; the database must be installed and running (exakit start).")
    folder, root = Path(doc["bucket_dir"]), str(doc["udf_root"])
    models = doc.get("models") or []
    if not folder.is_dir():
        return _report("bucket directory", False, f"{folder} does not exist.",
                       "exakit start creates the deployment's folders; then run this cell again.")
    detail = f"{folder}, read by UDFs at {root}; {len(models)} model file(s) in it"
    if conn is None:
        return _report("bucket directory", True, detail + ".")
    try:
        seen = _probe(conn, packages=(), path=root).get("path")
    except Exception:                                          # the container check says why
        return _report("bucket directory", True, detail + " (not checked from a UDF: see the container check).")
    if seen != "folder":
        return _report("bucket directory", False, f"{detail}, but a UDF does not see {root}.",
                       "restart the database (exakit stop, then exakit start) so it mounts the bucket directory.")
    return _report("bucket directory", True, detail + "; a UDF sees it.")
