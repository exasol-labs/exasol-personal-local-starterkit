"""Exasol Semantic Views in the local database: a verified release, installed with its own installer.

Exasol Semantic Views (exasol-labs/exasol-semantic-views) is a semantic layer that lives in the database: Lua
scripts and catalog tables in five schemas (SYS_SEMANTIC, SEMANTIC_CATALOG, SEMANTIC_ADMIN, SEMANTIC_AGENT,
SEMANTIC_SOURCE) and one role, SEMANTIC_USER. Nothing runs on this computer once it is installed.

Install downloads the release archive the kit pins (versions.json: version and SHA-256), refuses one whose digest
does not match, unpacks it under the kit's home and runs the release's own installer (tools/install.py
--skip-package: the install SQL ships built) with the kit's pyexasol, connected as the kit's administrator through
the database's TLS pin. The password reaches the installer in its environment only, read from the kit's credential
file at the moment it runs, and every line it prints goes to the marketplace log with that password redacted.

Running the installer again is how an update works: it keeps the models already defined and adds what a newer
release brings. Uninstall removes the five schemas and the role only when no model is defined: a model is the
user's work, and the kit never deletes it.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile
from pathlib import Path

from runtime import AddonFailure, KitContext

ID = "semantic-views"
RECEIPT = "components.semantic_views"
REPO = "exasol-labs/exasol-semantic-views"
HEX = re.compile(r"^[0-9a-f]{64}$")
TAG = re.compile(r"^v?[0-9][0-9A-Za-z._+-]*$")
SCHEMAS = ("SEMANTIC_AGENT", "SEMANTIC_SOURCE", "SEMANTIC_CATALOG", "SEMANTIC_ADMIN", "SYS_SEMANTIC")
ROLE = "SEMANTIC_USER"
INSTALL_TIMEOUT = 900          # some 2 MB of SQL and Lua: minutes on a busy laptop, never an hour


def paths(ctx: KitContext) -> tuple[Path, Path]:
    """(the add-on's folder under the kit home, the unpacked release the kit installed from)."""
    home = ctx.home / "semantic-views"
    version = str(ctx.manifest.get(f"{RECEIPT}.version") or "")
    return home, home / version if version else home / "current"


def _python(ctx: KitContext) -> Path:
    recorded = ctx.manifest.get("components.pyexasol.python")
    if isinstance(recorded, str) and Path(recorded).is_file():
        return Path(recorded)
    raise AddonFailure("The kit's pyexasol environment is missing; repair it with: exakit update pyexasol")


def applicable(ctx: KitContext) -> bool:
    return bool(ctx.manifest.get("runtime.dsn")) and bool(ctx.manifest.get("runtime.password_file"))


def applicable_reason(ctx: KitContext) -> str:
    return "it installs into the kit's database, and this kit has no database connection recorded"


def _version(ctx: KitContext) -> str:
    from model import load_addons

    fallback = next(row.default_version for row in load_addons(ctx.root) if row.id == ID)
    version = ctx.target_version(ID, fallback)
    if not TAG.fullmatch(version):
        raise AddonFailure(f"invalid Semantic Views version: {version}")
    return version if version.startswith("v") else f"v{version}"


def installed_version(ctx: KitContext) -> str | None:
    version = ctx.manifest.get(f"{RECEIPT}.version")
    return str(version).removeprefix("v") if version and ctx.manifest.get(f"{RECEIPT}.ownership") == "kit" else None


# --- the database -------------------------------------------------------------------------------------------------

_QUERY = r"""
import json, os, ssl, sys
import pyexasol
con = pyexasol.connect(dsn=os.environ["EXAKIT_SV_DSN"], user=os.environ["EXAKIT_SV_USER"],
                       password=os.environ["EXAKIT_SV_PASSWORD"], encryption=True,
                       websocket_sslopt={"cert_reqs": ssl.CERT_NONE}, schema="SYS")
answers = []
for statement in json.loads(sys.stdin.read()):
    stmt = con.execute(statement)
    answers.append(stmt.fetchall() if stmt.result_type == "resultSet" else stmt.rowcount())
con.close()
print(json.dumps(answers, default=str))
"""


def _connection_env(ctx: KitContext) -> dict[str, str]:
    """The kit's administrator connection for a child process: the DSN with the database's TLS pin, the user, and
    the password read from the kit's credential file now. Never an argument, never written anywhere."""
    credential = ctx.manifest.get("runtime.password_file", "")
    if not credential or not Path(str(credential)).is_file():
        raise AddonFailure("The kit's database password file is missing; check exakit status")
    return {"EXAKIT_SV_DSN": ctx.client_dsn(), "EXAKIT_SV_USER": str(ctx.manifest.get("runtime.user") or "sys"),
            "EXAKIT_SV_PASSWORD": Path(str(credential)).read_text(encoding="utf-8").strip(),
            "PYEXASOL_TELEMETRY": "0", "EXASOL_TELEMETRY_DISABLE": "1"}


def _db(ctx: KitContext, *statements: str, timeout: int = 120) -> list:
    """Run statements as the kit's administrator; each answer is the rows of a query or the row count."""
    env = {**os.environ, **_connection_env(ctx)}
    try:
        result = subprocess.run([str(_python(ctx)), "-c", _QUERY], input=json.dumps(list(statements)), env=env,
                                capture_output=True, text=True, check=False, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise AddonFailure("The database did not answer; check exakit status") from error
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().splitlines()[-1:] or ["no output"]
        raise AddonFailure(f"Semantic Views database step failed: {detail[0].replace(env['EXAKIT_SV_PASSWORD'], '***')}")
    return json.loads(result.stdout or "[]")


def _present(ctx: KitContext) -> dict:
    """What of Semantic Views is in the database now: its schemas, its role, the version it records, the models."""
    listed = ", ".join(f"'{name}'" for name in SCHEMAS)
    schemas, roles = _db(ctx, f"SELECT SCHEMA_NAME FROM SYS.EXA_SCHEMAS WHERE SCHEMA_NAME IN ({listed})",
                         f"SELECT ROLE_NAME FROM SYS.EXA_ALL_ROLES WHERE ROLE_NAME = '{ROLE}'")
    found = {"schemas": sorted(row[0] for row in schemas), "role": bool(roles), "version": None, "models": None}
    if "SEMANTIC_CATALOG" in found["schemas"]:
        try:
            version, models = _db(ctx, "SELECT DISPLAY_VERSION FROM SEMANTIC_CATALOG.PRODUCT_VERSION",
                                  "SELECT COUNT(*) FROM SEMANTIC_CATALOG.MODELS")
            found["version"] = str(version[0][0]) if version else None
            found["models"] = int(models[0][0]) if models else 0
        except AddonFailure:
            pass
    return found


def system_present(ctx: KitContext) -> bool:
    """Semantic Views is in the database and the kit did not put it there (someone ran its installer by hand)."""
    if ctx.manifest.get(f"{RECEIPT}.ownership") == "kit" or not applicable(ctx):
        return False
    try:
        return "SEMANTIC_ADMIN" in _present(ctx)["schemas"]
    except AddonFailure:
        return False


# --- the release ----------------------------------------------------------------------------------------------------

def _asset(version: str) -> tuple[str, str]:
    repo = os.environ.get("EXAKIT_SEMANTIC_VIEWS_REPO", REPO)
    if not re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", repo):
        raise AddonFailure("invalid Semantic Views repository")
    return repo, f"exasol-semantic-views-{version}.zip"


def _https(url: str):
    if not url.startswith("https://"):
        raise AddonFailure("Semantic Views downloads must use HTTPS")
    response = urllib.request.urlopen(url, timeout=60)
    if not response.url.startswith("https://"):
        response.close()
        raise AddonFailure("the Semantic Views download was redirected away from HTTPS")
    return response


def _expected_digest(ctx: KitContext, version: str, repo: str, name: str) -> str | None:
    """The archive's SHA-256: the kit copy's own pin for the pinned version (never a fetched document), else the
    release's published .sha256 file."""
    block = ctx.pinned_document().get("components", {}).get(ID, {})
    if repo == REPO and version == str(block.get("version", "")):
        pin = str((block.get("sha256") or {}).get("archive", "")).lower()
        if HEX.fullmatch(pin):
            return pin
    try:
        with _https(f"https://github.com/{repo}/releases/download/{version}/{name}.sha256") as response:
            published = response.read(4096).decode("ascii").split()[0].lower()
        return published if HEX.fullmatch(published) else None
    except (OSError, ValueError, IndexError, UnicodeError):
        return None


def _download(ctx: KitContext, version: str, archive: Path) -> None:
    repo, name = _asset(version)
    expected = _expected_digest(ctx, version, repo, name)
    if not expected and os.environ.get("EXAKIT_ALLOW_UNVERIFIED_SEMANTIC_VIEWS") != "1":
        raise AddonFailure(f"No checksum for {name}; refusing an unverified archive")
    ctx.activity(f"Downloading Exasol Semantic Views {version}")
    digest = hashlib.sha256()
    try:
        with _https(f"https://github.com/{repo}/releases/download/{version}/{name}") as response, \
                archive.open("wb") as output:
            for chunk in iter(lambda: response.read(1024 * 1024), b""):
                digest.update(chunk)
                output.write(chunk)
        if expected and digest.hexdigest() != expected:
            raise AddonFailure(f"Checksum mismatch for {name}")
    except Exception:
        archive.unlink(missing_ok=True)
        raise


def _unpack(archive: Path, destination: Path) -> Path:
    """The release, unpacked into destination; returns its top folder. Every entry must stay inside destination,
    and the release must carry its built install SQL and its installer."""
    with zipfile.ZipFile(archive) as source:
        root = destination.resolve()
        for item in source.infolist():
            target = (destination / item.filename).resolve()
            if root != target and root not in target.parents:
                raise AddonFailure("the Semantic Views archive holds a path outside its folder")
        source.extractall(destination)
    tops = [path for path in destination.iterdir() if path.is_dir()]
    top = tops[0] if len(tops) == 1 else destination
    if not (top / "tools" / "install.py").is_file() or not list((top / "build" / "install").glob("*.sql")):
        raise AddonFailure("the Semantic Views archive has no built install SQL or no installer")
    return top


def _run_installer(ctx: KitContext, release: Path) -> None:
    connection = _connection_env(ctx)
    host, _, port = connection["EXAKIT_SV_DSN"].rpartition(":")
    env = {**os.environ, "EXASOL_HOST": host, "EXASOL_PORT": port, "EXASOL_USER": connection["EXAKIT_SV_USER"],
           "EXASOL_PASSWORD": connection["EXAKIT_SV_PASSWORD"], "NO_COLOR": "1", "TERM": "dumb",
           "PYEXASOL_TELEMETRY": "0", "EXASOL_TELEMETRY_DISABLE": "1"}
    ctx.run_logged("Installing Exasol Semantic Views into the database", str(_python(ctx)),
                   str(release / "tools" / "install.py"), "--skip-package", env=env, cwd=release,
                   timeout=INSTALL_TIMEOUT)


def install(ctx: KitContext) -> None:
    if not applicable(ctx):
        raise AddonFailure(applicable_reason(ctx))
    if ctx.manifest.get(f"{RECEIPT}.ownership") in ("user", "unknown") or \
            (not ctx.manifest.get(f"{RECEIPT}.version") and system_present(ctx)):
        raise AddonFailure("Semantic Views is already in the database and was not installed by the kit; "
                           "its owner updates it with its own installer")
    version = _version(ctx)
    home = paths(ctx)[0]
    home.mkdir(parents=True, exist_ok=True)
    release = home / version
    with tempfile.TemporaryDirectory(prefix="exakit-semantic-views-", dir=ctx.home) as temp:
        if not (release / "tools" / "install.py").is_file() or os.environ.get("EXAKIT_FORCE_COMPONENT_INSTALL") == "1":
            archive = Path(temp) / _asset(version)[1]
            _download(ctx, version, archive)
            top = _unpack(archive, Path(temp) / "unpacked")
            if release.exists():
                shutil.rmtree(release)
            shutil.move(str(top), str(release))
        before = _present(ctx)
        _run_installer(ctx, release)
    ctx.manifest.set_many({f"{RECEIPT}.version": version, f"{RECEIPT}.path": str(release),
                           f"{RECEIPT}.ownership": "kit",
                           # The role is the kit's to remove only when this install made it.
                           f"{RECEIPT}.role_created": bool(ctx.manifest.get(f"{RECEIPT}.role_created"))
                           or not before["role"]})
    for old in home.iterdir():                     # earlier releases: the database runs the new one now
        if old.is_dir() and old.name != version:
            shutil.rmtree(old, ignore_errors=True)


def validate(ctx: KitContext) -> bool:
    """Every schema is there and the database says which release it runs."""
    try:
        found = _present(ctx)
    except AddonFailure:
        return False
    ok = set(SCHEMAS) <= set(found["schemas"]) and bool(found["version"])
    ctx.manifest.set_many({f"{RECEIPT}.validated": ok})
    return ok


def summary(ctx: KitContext) -> str:
    return "semantic models in SEMANTIC_CATALOG; enable in a session: EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()"


def update(ctx: KitContext) -> None:
    if ctx.manifest.get(f"{RECEIPT}.ownership") != "kit":
        raise AddonFailure("Semantic Views is not kit-owned; its owner manages updates")
    install(ctx)
    if not validate(ctx):
        raise AddonFailure("Semantic Views did not validate after the update")
    ctx.manifest.set_many({"desired.semantic_views": _version(ctx)})


def uninstall(ctx: KitContext, *, dry_run: bool = False) -> list[Path]:
    if ctx.manifest.get(f"{RECEIPT}.ownership") != "kit":
        raise AddonFailure("Semantic Views is not kit-owned; it will not be removed")
    home = paths(ctx)[0]
    targets = [home] if home.exists() else []
    if dry_run:
        return targets
    found = _present(ctx)
    if found["models"]:
        raise AddonFailure(f"{found['models']} semantic model(s) are defined in the database: they are your work, so "
                           "nothing was removed. Drop them first (EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL(...)), "
                           "then remove the add-on again")
    statements = [f"DROP SCHEMA IF EXISTS {name} CASCADE" for name in SCHEMAS if name in found["schemas"]]
    if found["role"] and ctx.manifest.get(f"{RECEIPT}.role_created"):
        statements.append(f"DROP ROLE {ROLE} CASCADE")
    if statements:
        _db(ctx, *statements, timeout=300)
    for target in targets:
        shutil.rmtree(target, ignore_errors=True)
    ctx.manifest.delete(RECEIPT, "desired.semantic_views")
    return targets
