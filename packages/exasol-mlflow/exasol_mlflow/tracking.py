"""Where the run goes, and whether that place answers: the tracking URI resolution and the health check that runs
BEFORE any SQL (AC-ML2.5).

Resolution, in order: ``MLFLOW_TRACKING_URI`` when set (a remote or any server of yours); the kit's own server when
``exakit mlflow start`` recorded it in ``$EXAKIT_HOME/mlflow/server.json`` (``{"url": ..., "port": ..., "pid": ...}``);
else a local store - the kit's SQLite database ``$EXAKIT_HOME/mlflow/mlflow.db`` with ``artifacts`` beside it (the same
files the kit's server serves, so the runs show up once it is started) or, outside the kit, ``./mlflow``.

Credentials for a remote server - ``MLFLOW_TRACKING_USERNAME`` + ``MLFLOW_TRACKING_PASSWORD`` (Basic; wins) or
``MLFLOW_TRACKING_TOKEN`` (Bearer), ``MLFLOW_TRACKING_INSECURE_TLS`` - are read for the health check only and never
logged, never written and never passed to the database.
"""

from __future__ import annotations

import base64
import json
import os
import ssl
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

KIT_HOME_DEFAULT = Path.home() / ".exasol-starter-kit"
LOCAL_DIR = "mlflow"
SERVER_FILE = "server.json"
START_HINT = "start it with: exakit mlflow start"

ENV_URI = "env"            # MLFLOW_TRACKING_URI
KIT_SERVER = "kit"         # $EXAKIT_HOME/mlflow/server.json
LOCAL_STORE = "local"      # SQLite file store, no server


class TrackingUnavailable(RuntimeError):
    """The tracking server does not answer; nothing ran in the database."""


@dataclass(frozen=True)
class Tracking:
    uri: str
    source: str                  # ENV_URI | KIT_SERVER | LOCAL_STORE
    artifacts: str | None = None  # the local store's artifact folder (LOCAL_STORE only)

    @property
    def is_http(self) -> bool:
        return self.uri.startswith(("http://", "https://"))


def kit_home() -> Path:
    """``$EXAKIT_HOME``, else ``~/.exasol-starter-kit``."""
    return Path(os.environ.get("EXAKIT_HOME") or KIT_HOME_DEFAULT).expanduser()


def in_kit() -> bool:
    """Whether this runs inside an installed kit (EXAKIT_HOME set, or the default home has a manifest)."""
    return bool(os.environ.get("EXAKIT_HOME")) or (KIT_HOME_DEFAULT / "manifest.json").is_file()


def mlflow_dir() -> Path:
    return kit_home() / "mlflow"


def server_file() -> Path:
    """``$EXAKIT_HOME/mlflow/server.json`` - written by ``exakit mlflow start``, removed by ``stop``."""
    return mlflow_dir() / SERVER_FILE


def kit_server_url() -> str | None:
    """The kit's server URL from server.json (its ``url``, else ``http://127.0.0.1:<port>``), or None."""
    try:
        doc = json.loads(server_file().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(doc, dict):
        return None
    url = str(doc.get("url") or "").strip()
    if not url and doc.get("port"):
        url = f"http://127.0.0.1:{int(doc['port'])}"
    return url.rstrip("/") or None


def resolve(tracking_dir: str | os.PathLike | None = None) -> Tracking:
    """The tracking target for this process (see the module docstring); ``tracking_dir`` forces a local store there."""
    if tracking_dir is None and os.environ.get("MLFLOW_TRACKING_URI"):
        return Tracking(os.environ["MLFLOW_TRACKING_URI"].strip(), ENV_URI)
    if tracking_dir is None:
        url = kit_server_url()
        if url:
            return Tracking(url, KIT_SERVER)
    folder = Path(tracking_dir).expanduser() if tracking_dir is not None else (mlflow_dir() if in_kit() else Path(LOCAL_DIR))
    folder = folder.resolve()
    return Tracking(f"sqlite:///{folder / 'mlflow.db'}", LOCAL_STORE, str(folder / "artifacts"))


def _auth_headers() -> dict[str, str]:
    user, password = os.environ.get("MLFLOW_TRACKING_USERNAME"), os.environ.get("MLFLOW_TRACKING_PASSWORD")
    if user and password is not None:
        return {"Authorization": "Basic " + base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")}
    token = os.environ.get("MLFLOW_TRACKING_TOKEN")
    if token:
        return {"Authorization": "Bearer " + token}
    return {}


def _context() -> ssl.SSLContext | None:
    if os.environ.get("MLFLOW_TRACKING_INSECURE_TLS", "").lower() in ("1", "true", "yes"):
        return ssl._create_unverified_context()      # the user asked for it, as mlflow's own client does
    return None


def urlopen(url: str, timeout: float) -> int:
    """HTTP status of a GET (tests replace this)."""
    request = urllib.request.Request(url, headers=_auth_headers(), method="GET")
    with urllib.request.urlopen(request, timeout=timeout, context=_context()) as answer:  # noqa: S310 - the user's own server
        return int(answer.status)


def check(tracking: Tracking, timeout: float = 3.0) -> None:
    """GET /health on an HTTP tracking server; a local file store needs no check. TrackingUnavailable says what failed and
    - for the kit's server - how to start it. Nothing here touches the database."""
    if not tracking.is_http:
        return
    url = tracking.uri.rstrip("/") + "/health"
    try:
        status = urlopen(url, timeout)
    except urllib.error.HTTPError as err:
        status = int(err.code)
    except Exception as err:  # noqa: BLE001 - every failure means the same: no server
        reason = f"{type(err).__name__}: {err}".strip()
        raise TrackingUnavailable(_unavailable(tracking, f"does not answer ({reason})")) from None
    if not 200 <= status < 300:
        raise TrackingUnavailable(_unavailable(tracking, f"answers HTTP {status} to GET /health"))


def _unavailable(tracking: Tracking, what: str) -> str:
    shown = redacted(tracking.uri)
    if tracking.source == KIT_SERVER:
        return f"the kit's MLflow server at {shown} {what}; {START_HINT} (exakit mlflow status says what is running)"
    return (f"the MLflow tracking server at {shown} (MLFLOW_TRACKING_URI) {what}; check the URL and the server, "
            f"or unset MLFLOW_TRACKING_URI and {START_HINT}")


def redacted(uri: str) -> str:
    """The URI without a user:password@ part, for messages and records."""
    head, sep, rest = uri.partition("://")
    if sep and "@" in rest.split("/", 1)[0]:
        rest = rest.split("@", 1)[1]
    return head + sep + rest
