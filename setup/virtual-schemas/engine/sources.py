"""Virtual schema state on the laptop: one folder per named source.

    <EXAKIT_HOME>/sources/<name>/config.json    non-secret inputs + object names
    <EXAKIT_HOME>/sources/<name>/state.json     status, pins, last check
    <EXAKIT_HOME>/sources/<name>/journal.json   the operation in progress
    <EXAKIT_HOME>/sources/registry.json         which sources use which staged file

No file here ever holds a password, a token or key material: secrets go from
protected input straight into the database's named CONNECTION. Every write
takes the sources lock and replaces the file atomically (the manifest
writers' discipline, from setup/core/state.py), so two kit processes cannot
lose each other's records and an interrupted write cannot truncate one.
"""

import contextlib
import importlib.util
import json
import os
import re
import time


def _load_core_state():
    """setup/core/state.py (lock + atomic write), under a name of its own."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "core", "state.py")
    spec = importlib.util.spec_from_file_location("exakit_core_state", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


core_state = _load_core_state()

NAME = re.compile(r"^[a-z][a-z0-9_]{0,39}$")
STATUSES = ("ready", "failed", "auth-failed", "unreachable", "tls-failed", "dns-failed",
            "expired", "disconnected", "empty", "unknown")


class SourceError(Exception):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def migrated(doc):
    """A source recorded before the lakehouse connectors became one, as the
    one connector records it now; None when it needs nothing.

    iceberg-rest and unity were connectors of their own, and lakehouse was
    Glue alone. Each is lakehouse now, its catalog and files among its inputs
    (the settings, first): iceberg-rest with an access key read the files with
    the storage's keys (files s3), without one the catalog vended them; Unity
    always vended them; Glue reads S3. The objects in the database stay as
    they are: the same CONNECTION, schema and shared LAKEHOUSE_ADAPTER."""
    if not isinstance(doc, dict):
        return None
    connector, inputs = doc.get("connector"), dict(doc.get("inputs") or {})
    if connector == "iceberg-rest":
        settings = {"catalog": "iceberg-rest", "files": "s3" if inputs.get("access_key_id") else "vended",
                    "login": "token"}
    elif connector == "unity":
        settings = {"catalog": "unity", "files": "vended", "login": "token"}
    elif connector == "lakehouse" and "catalog" not in inputs:
        settings = {"catalog": "glue", "files": "s3"}
    else:
        return None
    out = dict(doc, connector="lakehouse", migrated_from=connector)
    out["inputs"] = dict(settings, **{k: v for k, v in inputs.items() if k not in settings})
    return out


class Store(object):
    def __init__(self, kit_home, exa=None):
        self.root = os.path.join(kit_home, "sources")
        self._held = 0
        # The deployment's local/runtime/exa the engine stages into this run
        # (Runtime.exa), when it has one: registry paths under another one
        # that is gone are read as under this one (rebased).
        self.exa = exa

    def rebased(self, path):
        """``path`` under the current deployment, when it was recorded under a
        deployment folder that is gone. The registry and the journals hold
        absolute paths under <deployment>/local/runtime/exa, and the Exasol
        Personal launcher MOVES that folder (2.5.0 moves the 2.4 one, as a
        whole): the staged files are then the same ones, under the new folder.
        A path under a folder that is still there, or outside any deployment,
        is itself."""
        exa = self.exa
        if not exa or not isinstance(path, str) or not os.path.isdir(exa):
            return path
        for marker in {os.sep.join(["", "local", "runtime", "exa", ""]), "/local/runtime/exa/"}:
            at = path.find(marker)
            if at <= 0:
                continue
            old = path[:at + len(marker) - 1]
            same = old.lower() == exa.lower() if os.name == "nt" else old == exa
            if same or os.path.exists(old):
                return path
            return exa + path[at + len(marker) - 1:]
        return path

    def path(self, *parts):
        return os.path.join(self.root, *parts)

    @contextlib.contextmanager
    def lock(self):
        """One sources operation at a time per machine. Re-entrant within one
        process: an operation that holds it may call another that takes it
        (a check that moves its connector's sources forward), where a second
        flock on the same file would wait for itself."""
        if self._held:
            self._held += 1
            try:
                yield
            finally:
                self._held -= 1
            return
        os.makedirs(self.root, exist_ok=True)
        lock_target = self.path("registry.json")
        if not os.path.exists(lock_target):
            self._write(lock_target, {"schema_version": 1, "artifacts": {}})
        # Waited for on every platform: a second command that went ahead
        # without it would decide on sources the first is still changing.
        held = contextlib.ExitStack()
        try:
            held.enter_context(core_state.manifest_lock(lock_target))
        except core_state.StateError as error:
            raise SourceError(str(error))
        with held:
            self._held = 1
            try:
                # A registry recorded under a deployment folder the launcher
                # has moved since is written back under the current one, once.
                raw = self._read(lock_target, None)
                if isinstance(raw, dict) and raw != self.registry():
                    self.save_registry(self.registry())
                yield
            finally:
                self._held = 0

    # --- files -----------------------------------------------------------------
    def _read(self, path, default=None):
        try:
            with open(path, encoding="utf-8") as handle:
                return json.load(handle)
        except FileNotFoundError:
            return default
        except (OSError, ValueError) as error:
            raise SourceError("%s could not be read: %s" % (path, error))

    def _write(self, path, doc):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if os.name != "nt":
            os.chmod(os.path.dirname(path), 0o700)
        core_state._write_atomic(path, doc)

    # --- sources ---------------------------------------------------------------
    def names(self):
        if not os.path.isdir(self.root):
            return []
        return sorted(entry for entry in os.listdir(self.root)
                      if NAME.match(entry) and os.path.isfile(self.path(entry, "config.json")))

    def exists(self, name):
        return os.path.isfile(self.path(name, "config.json"))

    def config(self, name):
        doc = self._read(self.path(name, "config.json"))
        if doc is None:
            raise SourceError("no source named %s (see: exakit source list)" % name, 4)
        new = migrated(doc)
        if new is not None:
            # Migrated in place the first time it is read (atomically; two
            # readers write the same record), so every command after this one
            # - list, show, check, refresh, reauth, remove - reads it as is.
            try:
                self.save_config(name, new)
            except OSError:
                pass        # read-only: used migrated anyway, written next time
            doc = new
        return doc

    def status(self, name):
        return self._read(self.path(name, "state.json"), {}) or {}

    def journal(self, name):
        return self._read(self.path(name, "journal.json"), None)

    def save_config(self, name, doc):
        self._write(self.path(name, "config.json"), doc)

    def save_status(self, name, doc):
        self._write(self.path(name, "state.json"), doc)

    def update_status(self, name, **fields):
        doc = self.status(name)
        doc.update(fields)
        self.save_status(name, doc)
        return doc

    def save_journal(self, name, doc):
        self._write(self.path(name, "journal.json"), doc)

    def clear_journal(self, name):
        try:
            os.remove(self.path(name, "journal.json"))
        except FileNotFoundError:
            pass

    def delete_source(self, name):
        """Remove the source folder: the kit's own three files and nothing else."""
        folder = self.path(name)
        drafts = os.path.join(folder, "edml")
        if os.path.isdir(drafts):
            # The mapping the kit drafted for it (edml_draft): its .json files only.
            for leaf in os.listdir(drafts):
                if leaf.endswith(".json") and os.path.isfile(os.path.join(drafts, leaf)):
                    os.remove(os.path.join(drafts, leaf))
            try:
                os.rmdir(drafts)
            except OSError:
                pass
        for leaf in ("config.json", "state.json", "journal.json"):
            try:
                os.remove(os.path.join(folder, leaf))
            except FileNotFoundError:
                pass
        try:
            os.rmdir(folder)
        except OSError:
            pass          # something else lives there: left alone, never rm -rf

    # --- the shared-file registry -------------------------------------------------
    def registry(self):
        doc = self._read(self.path("registry.json"), {"schema_version": 1, "artifacts": {}}) or \
            {"schema_version": 1, "artifacts": {}}
        artifacts = doc.get("artifacts")
        if not self.exa or not isinstance(artifacts, dict):
            return doc
        # Every path as it is now (rebased); two records of one file merge.
        out = {}
        for path, entry in artifacts.items():
            now_path = self.rebased(path)
            if now_path not in out:
                out[now_path] = entry
                continue
            kept = dict(out[now_path])
            kept["consumers"] = list(kept.get("consumers") or []) + \
                [c for c in entry.get("consumers") or [] if c not in (kept.get("consumers") or [])]
            kept["owned"] = bool(kept.get("owned")) or bool(entry.get("owned"))
            out[now_path] = kept
        return dict(doc, artifacts=out)

    def save_registry(self, doc):
        self._write(self.path("registry.json"), doc)

    def add_consumer(self, staged_path, sha256, consumer, created):
        doc = self.registry()
        entry = doc.setdefault("artifacts", {}).setdefault(staged_path, {"sha256": sha256, "consumers": [],
                                                                        "owned": bool(created)})
        if consumer not in entry["consumers"]:
            entry["consumers"].append(consumer)
        self.save_registry(doc)

    def release(self, consumer):
        """Drop a consumer everywhere; return the owned paths nobody uses any more."""
        doc = self.registry()
        unused = []
        for path, entry in list(doc.get("artifacts", {}).items()):
            if consumer in entry.get("consumers", []):
                entry["consumers"].remove(consumer)
            if not entry.get("consumers"):
                if entry.get("owned"):
                    unused.append(path)
                del doc["artifacts"][path]
        self.save_registry(doc)
        return unused

    def release_paths(self, consumer, paths):
        """Drop a consumer from these paths only; return the owned ones nobody uses any more."""
        doc = self.registry()
        unused = []
        for path in paths:
            entry = doc.get("artifacts", {}).get(path)
            if entry is None:
                continue
            if consumer in entry.get("consumers", []):
                entry["consumers"].remove(consumer)
            if not entry.get("consumers"):
                if entry.get("owned"):
                    unused.append(path)
                del doc["artifacts"][path]
        self.save_registry(doc)
        return unused

    def consumers(self, staged_path):
        return list(self.registry().get("artifacts", {}).get(staged_path, {}).get("consumers", []))
