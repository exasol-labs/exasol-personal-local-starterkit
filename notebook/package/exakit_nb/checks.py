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

__all__ = ["check_bucket", "check_container", "check_mlflow", "check_model_compatibility", "model_list"]

PROBE_SCHEMA = "EXAKIT_UDF"                   # the udf-devkit add-on's schema; the probe is a script of its own there
PROBE = "EXAKIT_NB_PROBE"
TRAINING_PACKAGES = ("scikit-learn", "pandas", "numpy")


def _report(what: str, ok: bool, detail: str, fix: str = "") -> bool:
    print(f"ok   {what}: {detail}" if ok else f"FAIL {what}: {detail}" + (f" Fix: {fix}" if fix else ""))
    if not ok and os.environ.get("EXAKIT_NB_STRICT") == "1":
        raise RuntimeError(f"{what}: {detail}" + (f" Fix: {fix}" if fix else ""))
    return ok


def probe_script(alias: str, packages: tuple[str, ...]) -> str:
    """The CREATE SCRIPT of a UDF that reports Python, each package's version (or MISSING) and whether a path is a folder."""
    names = ", ".join(repr(p) for p in packages)
    # No reserved word among the names: VALUE and PATH are reserved in Exasol, and a CREATE SCRIPT using them failed
    # with a syntax error the check could only report as "did not run".
    return (f"CREATE OR REPLACE {alias} SCALAR SCRIPT {PROBE_SCHEMA}.{PROBE}(probe_path VARCHAR(2000)) "
            "EMITS (ITEM VARCHAR(200), DETAIL VARCHAR(2000)) AS\n"
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
            "    if ctx.probe_path:\n"
            "        ctx.emit('path', 'folder' if os.path.isdir(ctx.probe_path) else 'missing')\n")


def _probe(conn, alias: str = "PYTHON3", packages: tuple[str, ...] = TRAINING_PACKAGES, path: str = "") -> dict[str, str]:
    """What the probe UDF reports, as name -> value. Raises what the database raised."""
    conn.execute(f"CREATE SCHEMA IF NOT EXISTS {PROBE_SCHEMA}")
    conn.execute(probe_script(alias, packages))
    quoted = path.replace("'", "''")
    rows = conn.execute(f"SELECT {PROBE_SCHEMA}.{PROBE}('{quoted}')").fetchall()
    return {str(row[0]): str(row[1]) for row in rows}


def _reason(err: Exception) -> str:
    """The database's own message, on one line: pyexasol's errors carry it in .message, and their text starts with a
    blank line, so the first line of str(err) said nothing."""
    message = getattr(err, "message", None) or next((line.strip() for line in str(err).splitlines() if line.strip()), "")
    return str(message).splitlines()[0][:300] if message else type(err).__name__


def check_container(conn, alias: str | None = None, packages: tuple[str, ...] = TRAINING_PACKAGES) -> bool:
    """The container behind ``alias`` runs a smoke UDF, and it has every package training needs. The line names the
    alias probed and the fix for that alias (PYTHON3_ML: exakit udf-use default; PYTHON3: exakit udf-setup), so the
    fix installs the container the check looks at. ``alias`` None is the notebook's default, ml_train.udf_container():
    PYTHON3_ML before PYTHON3 from the kit's manifest, EXAKIT_UDF_CONTAINER first; none installed is a FAIL line."""
    from .ml_train import CONTAINER_INSTALLS, container_fix, udf_container

    if alias is None:
        try:
            alias = udf_container()
        except (RuntimeError, ValueError) as err:            # the message carries the fix
            return _report("container", False, str(err))
    try:
        found = _probe(conn, alias, packages)
    except Exception as err:                                   # the database's own message says why
        reason = _reason(err)
        return _report("container", False, f"the smoke UDF on {alias} did not run ({reason}).", container_fix(alias))
    missing = [p for p in packages if found.get(p, "MISSING") == "MISSING"]
    versions = ", ".join(f"{p} {found[p]}" for p in packages if p not in missing)
    if missing:
        fix = (f"{CONTAINER_INSTALLS['PYTHON3_ML']} again (the pre-built container ships them)"
               if alias.upper() == "PYTHON3_ML" else
               f"{CONTAINER_INSTALLS['PYTHON3_ML']} installs the pre-built container with them as PYTHON3_ML "
               "(then CONTAINER = \"PYTHON3_ML\")") + ", or exakit udf-build <requirements.txt>."
        return _report("container", False, f"Python {found.get('python', '?')} on {alias} lacks {', '.join(missing)}.", fix)
    return _report("container", True, f"the smoke UDF answers on {alias}: Python {found.get('python', '?')}, {versions}.")


def check_model_compatibility(conn, model_version: str, alias: str = "PYTHON3", model_path: str = "model.pkl") -> bool:
    """Refuse a pickle whose scikit-learn version differs before any scoring SQL runs."""
    try:
        found = _probe(conn, alias, ("scikit-learn",))
        container_version = found.get("scikit-learn", "MISSING")
    except Exception as error:
        print(f"Cannot score {model_path}: the {alias} container version check failed ({_reason(error)}). Run exakit udf-use default.")
        return False
    if container_version != model_version:
        print(f"Cannot score {model_path}: pickled with scikit-learn {model_version}, but the {alias} container has "
              f"{container_version}. Train with the container's version and put the model again.")
        return False
    print(f"Model version matches {alias}: scikit-learn {container_version}.")
    return True


def _shown(uri: str) -> str:
    """A tracking URI without any user or password in it."""
    parts = urllib.parse.urlsplit(uri)
    if parts.username or parts.password:
        host = parts.hostname or ""
        netloc = f"{host}:{parts.port}" if parts.port else host
        return urllib.parse.urlunsplit((parts.scheme, netloc, parts.path, "", ""))
    return uri


def check_mlflow(timeout: float = 5.0) -> bool:
    """Check the destination runs will really use: configured server, kit server, or local store."""
    try:
        import mlflow  # noqa: F401
    except ImportError:
        return _report("mlflow", False, "the MLflow client is not in the notebook environment.", "exakit update notebook")
    from exasol_mlflow import tracking

    destination = tracking.resolve()
    shown = tracking.redacted(destination.uri)
    if not destination.is_http:
        return _report("mlflow", True, f"local store {shown} (no server needed).")
    try:
        tracking.check(destination, timeout=timeout)
    except tracking.TrackingUnavailable as err:
        return _report("mlflow", False, str(err), "exakit mlflow start" if destination.source == tracking.KIT_SERVER else "check MLFLOW_TRACKING_URI")
    return _report("mlflow", True, f"the server at {shown} answers.")


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
    if seen == "missing" and not models:
        # The Personal VM synchronizes files, so an empty host directory may
        # not exist in the guest yet. A kit marker materializes it without
        # creating a model or changing any user file.
        marker = folder / ".exakit-bucket"
        try:
            with marker.open("x", encoding="utf-8") as stream:
                stream.write("Exasol Starter Kit bucket directory\n")
        except FileExistsError:
            pass
        except OSError:
            return _report("bucket directory", False, detail + "; cannot initialize the empty bucket.",
                           "check the host bucket folder permissions, then rerun this cell.")
        import time
        for attempt in range(10):
            seen = _probe(conn, packages=(), path=root).get("path")
            if seen == "folder":
                break
            time.sleep(0.5)
    if seen != "folder":
        return _report("bucket directory", False, f"{detail}, but a UDF does not see {root}.",
                       "restart the database (exakit stop, then exakit start) so it mounts the bucket directory.")
    return _report("bucket directory", True, detail + "; a UDF sees it.")
