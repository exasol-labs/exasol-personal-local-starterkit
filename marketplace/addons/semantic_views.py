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

Semantic SQL works in every session of every user with no setup: the kit registers Semantic Views as a module of
its SQL preprocessor framework (setup/preprocessor/modules/semantic-views: one rule, ROLE PUBLIC, phase EXPAND,
delegating to Semantic Views' own compiler), after install and update, and retires it before uninstall. Semantic
Views' own SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR never takes the database's one preprocessor slot, and nothing tells
a user or an AI to switch the preprocessor per session. A framework that is declined or not set up skips the module
(the add-on is installed either way) and registers it on its next verify (every installer run and `exakit update`).

The kit's read-only AI login (the MCP server's, made by `exakit mcp-setup`) is granted SEMANTIC_USER on install
and update, so an AI client can read the models and run Semantic SQL through the MCP server; uninstall takes the
grant back. That role is Semantic Views' own caller baseline - catalog reads, EXECUTE on SEMANTIC_ADMIN,
and the compile cache and logs the compiler writes as the caller - and the kit's read-only posture check accepts
it only in exactly that shape.
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

import kit_telemetry
import preprocessor_modules
from runtime import AddonFailure, KitContext, utf8_child

ID = "semantic-views"
RECEIPT = "components.semantic_views"
REPO = "exasol-labs/exasol-semantic-views"
HEX = re.compile(r"^[0-9a-f]{64}$")
TAG = re.compile(r"^v?[0-9][0-9A-Za-z._+-]*$")
SCHEMAS = ("SEMANTIC_AGENT", "SEMANTIC_SOURCE", "SEMANTIC_CATALOG", "SEMANTIC_ADMIN", "SYS_SEMANTIC")
ROLE = "SEMANTIC_USER"
IDENTIFIER = re.compile(r"^[A-Z][A-Z0-9_]*$")
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
os.environ.setdefault("EXASOL_TELEMETRY_DISABLE", "1")   # pyexasol's usage telemetry stays off unless the user set it
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
            "PYEXASOL_TELEMETRY": "0"}
    kit_telemetry.default_off(env)             # off unless the user set the variable (kit_telemetry.py)


def _db(ctx: KitContext, *statements: str, timeout: int = 120) -> list:
    """Run statements as the kit's administrator; each answer is the rows of a query or the row count."""
    env = utf8_child({**os.environ, **_connection_env(ctx)})
    try:
        result = subprocess.run([str(_python(ctx)), "-c", _QUERY], input=json.dumps(list(statements)), env=env,
                                capture_output=True, encoding="utf-8", errors="replace", check=False,
                                timeout=timeout)
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
    found = {"schemas": sorted(row[0] for row in schemas), "role": bool(roles), "version": None, "models": 0,
             "models_error": None}
    if "SEMANTIC_CATALOG" in found["schemas"]:
        try:                                       # best-effort: an install that stopped part-way may not have it
            version = _db(ctx, "SELECT DISPLAY_VERSION FROM SEMANTIC_CATALOG.PRODUCT_VERSION")[0]
            found["version"] = str(version[0][0]) if version else None
        except AddonFailure:
            pass
    if "SYS_SEMANTIC" in found["schemas"]:
        # The models, read on their own and from the table that holds them (SEMANTIC_CATALOG.MODELS shows only the
        # models the reader's roles may see). A count that cannot be read is None with its reason, never "no models":
        # uninstall refuses on it (audit SCR-06). No MODELS table yet (an install that stopped part-way): no models.
        try:
            if _db(ctx, "SELECT 1 FROM SYS.EXA_DBA_TABLES "
                        "WHERE TABLE_SCHEMA = 'SYS_SEMANTIC' AND TABLE_NAME = 'MODELS'")[0]:
                found["models"] = int(_db(ctx, "SELECT COUNT(*) FROM SYS_SEMANTIC.MODELS")[0][0][0])
        except (AddonFailure, IndexError, TypeError, ValueError) as error:
            found["models"], found["models_error"] = None, str(error) or type(error).__name__
    return found


def _mcp_login(ctx: KitContext) -> str | None:
    """The kit's read-only AI login, as the database names it, or None when the kit has not made one."""
    login = str(ctx.manifest.get("components.mcp_server.connection.user") or "").strip().upper()
    return login if IDENTIFIER.fullmatch(login) else None


def grant_mcp_login(ctx: KitContext) -> None:
    """SEMANTIC_USER for the kit's read-only AI login, so an AI client can run Semantic SQL through the MCP server
    (upstream: a login with only SELECT ANY TABLE reaches the compiler, but every semantic query is refused).
    Granted once and recorded; a login that does not exist yet is left for the next `exakit update semantic-views`.
    Never fatal: the add-on works for every SQL user either way.

    The role carries a write the login otherwise lacks: INSERT/UPDATE/DELETE on SYS_SEMANTIC.COMPILE_CACHE (and INSERT
    on the two logs). Upstream's design (v0.6.1 docs/governance.md, sections 6 and 8): the compiler runs as the caller
    and writes the cache and its logs as the caller, so every SEMANTIC_USER holds that write. Since Semantic Views is a
    ROLE PUBLIC preprocessor module, a cache row is also what the administrator's next matching semantic query runs.
    The role is granted whole anyway: it is upstream's caller baseline, a role cannot be granted minus one privilege,
    and the read-only posture check accepts exactly that baseline and nothing more. What bounds the write: the MCP
    server refuses write statements (enable_write_query false), and upstream serves a cache row only when it reads a
    relation the model declares and no other (compile_cache.cache_lookup, since 0.3); a rejected row is a miss."""
    login = _mcp_login(ctx)
    if not login:
        return
    try:
        users, held = _db(ctx, f"SELECT 1 FROM SYS.EXA_DBA_USERS WHERE USER_NAME = '{login}'",
                          f"SELECT 1 FROM SYS.EXA_DBA_ROLE_PRIVS WHERE GRANTEE = '{login}' AND GRANTED_ROLE = '{ROLE}'")
        if not users:
            return
        if not held:
            _db(ctx, f'GRANT {ROLE} TO "{login}"')
    except AddonFailure as error:
        ctx.log_event(f"Semantic Views: {ROLE} could not be granted to the AI login {login} ({error}); "
                      "retry with: exakit update semantic-views")
        return
    ctx.manifest.set_many({f"{RECEIPT}.mcp_login": login})


def system_present(ctx: KitContext) -> bool:
    """Semantic Views is in the database and the kit did not put it there (someone ran its installer by hand). A kit
    receipt, finished or still installing (see install), always answers no."""
    if ctx.manifest.get(f"{RECEIPT}.ownership") == "kit" or not applicable(ctx):
        return False
    try:
        return "SEMANTIC_ADMIN" in _present(ctx)["schemas"]
    except AddonFailure:
        return False


# --- the release ----------------------------------------------------------------------------------------------------

def _asset(version: str) -> tuple[str, str]:
    repo = REPO                                        # the pinned repository: never one from the environment
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
    if not expected:
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
           "PYEXASOL_TELEMETRY": "0"}
    kit_telemetry.default_off(env)             # off unless the user set the variable (kit_telemetry.py)
    ctx.run_logged("Installing Exasol Semantic Views into the database", str(_python(ctx)),
                   str(release / "tools" / "install.py"), "--skip-package", env=env, cwd=release,
                   timeout=INSTALL_TIMEOUT)


# install() fetches its release into its own folder, installs its own schemas (only reading the kit's pyexasol
# environment), and writes its receipt through the locked manifest: apply.py may run it beside other parallel-safe
# add-ons (the steps after it stay serial).
PARALLEL_INSTALL = True


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
        updating = bool(ctx.manifest.get(f"{RECEIPT}.version"))
        if updating:
            # An update: the module imports the runtimes the installer is about to replace, so it is out of every
            # session while the installer runs, and registered again below (or by _restore_module on a failure).
            preprocessor_modules.retire(ctx, ID)
        # The installer changes the database from its first statement, so the receipt is the kit's BEFORE it runs:
        # ownership=kit with state=installing. An install that fails, times out or is interrupted part-way leaves
        # schemas behind; without this receipt system_present took them for an installation made outside the kit, and
        # every retry, update and removal was refused from then on (audit MKT-06). With it, the next install resumes,
        # and uninstall removes what is there. The role is the kit's to remove only when this install made it, so that
        # is recorded now too, from the database as it was before the installer ran.
        ctx.manifest.set_many({f"{RECEIPT}.ownership": "kit", f"{RECEIPT}.state": "installing",
                               f"{RECEIPT}.role_created": bool(ctx.manifest.get(f"{RECEIPT}.role_created"))
                               or not before["role"]})
        try:
            _run_installer(ctx, release)
        except Exception:
            if updating:
                try:
                    _restore_module(ctx)
                except Exception as error:     # the installer's failure is the one to report
                    ctx.log_event(f"Semantic Views: the module was not registered again ({error})")
            raise
    with ctx.manifest.edit() as doc:              # finished: the version it runs, and no longer installing
        receipt = doc.setdefault("components", {}).setdefault("semantic_views", {})
        receipt.update({"version": version, "path": str(release), "ownership": "kit"})
        receipt.pop("state", None)
    for old in home.iterdir():                     # earlier releases: the database runs the new one now
        if old.is_dir() and old.name != version:
            shutil.rmtree(old, ignore_errors=True)
    grant_mcp_login(ctx)
    register_module(ctx)


def register_module(ctx: KitContext) -> str:
    """Register Semantic Views with the kit's SQL preprocessor framework, so Semantic SQL works in every session.
    Never fatal: a declined or absent framework skips it (and its verify registers it later); a failure is logged."""
    status, message = preprocessor_modules.register(ctx, ID)
    if status != "ok" and message:
        ctx.log_event(f"Semantic Views: {message}")
    return status


def _restore_module(ctx: KitContext) -> None:
    """An update whose installer failed. While the database still holds a whole Semantic Views (validate), the receipt
    is the earlier install again and the module the update retired is registered again, so Semantic SQL stays on.
    Otherwise, or when that registration fails, the receipt stays installing and the next `exakit update` runs the
    update again (needs_update)."""
    if not validate(ctx):
        return
    with ctx.manifest.edit() as doc:
        doc.setdefault("components", {}).setdefault("semantic_views", {}).pop("state", None)
    if register_module(ctx) == "failed":
        ctx.manifest.set_many({f"{RECEIPT}.state": "installing"})


def needs_update(ctx: KitContext) -> bool:
    """Installed by the kit, but an update did not finish (state=installing): `exakit update` runs it again."""
    return bool(installed_version(ctx)) and ctx.manifest.get(f"{RECEIPT}.state") == "installing"


def semantic_sql_active(ctx: KitContext) -> bool:
    """The framework recorded the module as registered (setup/preprocessor/manage.py)."""
    return bool(ctx.manifest.get(f"components.preprocessor.modules.{ID}.version"))


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
    framework = ctx.manifest.get("components.preprocessor") or {}
    # A slot left to the user's own preprocessor (declined) keeps the modules record but runs none of it.
    if semantic_sql_active(ctx) and framework.get("state") == "active" and not framework.get("declined"):
        return "semantic models in SEMANTIC_CATALOG; Semantic SQL works in every session, no setup"
    return ("semantic models in SEMANTIC_CATALOG; Semantic SQL is not on yet: it needs the kit's SQL preprocessor "
            "framework active in this database")


def update(ctx: KitContext) -> None:
    if ctx.manifest.get(f"{RECEIPT}.ownership") != "kit":
        raise AddonFailure("Semantic Views is not kit-owned; its owner manages updates")
    install(ctx)
    if not validate(ctx):
        raise AddonFailure("Semantic Views did not validate after the update")
    ctx.manifest.set_many({"desired.semantic_views": _version(ctx)})


def uninstall(ctx: KitContext, *, dry_run: bool = False) -> list[Path | str]:
    if ctx.manifest.get(f"{RECEIPT}.ownership") != "kit":
        raise AddonFailure("Semantic Views is not kit-owned; it will not be removed")
    home = paths(ctx)[0]
    targets = [home] if home.exists() else []
    if dry_run:
        # Every action the removal below performs, read from the receipt (a preview asks no database): a preview of
        # the folder alone hid that five schemas and a role leave the database. Defined models stop it all.
        plan: list[Path | str] = []
        if ctx.manifest.get(f"components.preprocessor.modules.{ID}.version"):
            plan.append("Semantic SQL stops working in every session (the SQL preprocessor's Semantic SQL module is "
                        "switched off)")
        login = str(ctx.manifest.get(f"{RECEIPT}.mcp_login") or "")
        if IDENTIFIER.fullmatch(login):
            plan.append(f"the {ROLE} grant to {login} (REVOKE)")
        plan.append(f"the schemas {', '.join(SCHEMAS)} where present (DROP SCHEMA ... CASCADE); "
                    "nothing is removed while a semantic model is defined, or when the models cannot be counted")
        if ctx.manifest.get(f"{RECEIPT}.role_created"):
            plan.append(f"the role {ROLE} (DROP ROLE ... CASCADE)")
        return plan + targets
    found = _present(ctx)
    if found["models"] is None:
        raise AddonFailure(f"Could not check whether semantic models exist ({found.get('models_error')}); nothing was "
                           "removed. Check exakit status and retry, or drop the schemas yourself after backing up "
                           "the models")
    if found["models"]:
        raise AddonFailure(f"{found['models']} semantic model(s) are defined in the database: they are your work, so "
                           "nothing was removed. Drop each one first with EXECUTE SCRIPT "
                           "SEMANTIC_ADMIN.DROP_MODEL('<model name>'), then remove the add-on again")
    # The module goes first: nothing may import a runtime the drops below remove. A registered module whose
    # retire failed leaves its rule live, so nothing is dropped and it is said.
    registered = semantic_sql_active(ctx)
    status, message = preprocessor_modules.retire(ctx, ID)
    if status == "failed" and registered:
        raise AddonFailure(f"{message}; nothing was removed. Retry with: exakit uninstall {ID}")
    statements = [f"DROP SCHEMA IF EXISTS {name} CASCADE" for name in SCHEMAS if name in found["schemas"]]
    login = str(ctx.manifest.get(f"{RECEIPT}.mcp_login") or "")
    if found["role"] and IDENTIFIER.fullmatch(login) and _db(
            ctx, f"SELECT 1 FROM SYS.EXA_DBA_ROLE_PRIVS WHERE GRANTEE = '{login}' AND GRANTED_ROLE = '{ROLE}'")[0]:
        statements.insert(0, f'REVOKE {ROLE} FROM "{login}"')   # the AI login's grant goes with the add-on
    # What this removal drops, named for the caller: after an interrupted install (state=installing) that is the
    # report of what the install had created, so it lists what was there, never the five names it might have made.
    removed: list[Path | str] = [f"schema {name}" for name in SCHEMAS if name in found["schemas"]]
    if found["role"] and ctx.manifest.get(f"{RECEIPT}.role_created"):
        statements.append(f"DROP ROLE {ROLE} CASCADE")
        removed.append(f"role {ROLE}")
    if statements:
        _db(ctx, *statements, timeout=300)
    for target in targets:
        shutil.rmtree(target, ignore_errors=True)
    ctx.manifest.delete(RECEIPT, "desired.semantic_views")
    return removed + targets
