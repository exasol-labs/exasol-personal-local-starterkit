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
            "expired", "disconnected", "unknown")


class SourceError(Exception):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


class Store(object):
    def __init__(self, kit_home):
        self.root = os.path.join(kit_home, "sources")
        self._held = 0

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
        with core_state.manifest_lock(lock_target):
            self._held = 1
            try:
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
        return self._read(self.path("registry.json"), {"schema_version": 1, "artifacts": {}}) or \
            {"schema_version": 1, "artifacts": {}}

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
