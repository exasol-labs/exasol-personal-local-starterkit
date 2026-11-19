"""Core-task state: the tasks a kit ships and the ones this machine completed.

Two files meet here. setup/core/tasks.json, in the kit, names every core task a
release has ever added. ~/.exasol-starter-kit/manifest.json, on the laptop,
records under core_tasks.completed the names whose setup checks passed. A name
in the first and not the second is pending.

Writes take the same lock the shell and PowerShell writers take
(<manifest>.lock: flock on POSIX, an exclusive open on Windows) and replace the
file atomically, so a write here can never lose a concurrent manifest_set or
Set-ExakitManifestValue, and an interrupted write can never truncate the file.

Standard library only, Python 3.8+: this runs on whatever interpreter the kit
found, before pyexasol or anything else is installed.
"""

import contextlib
import json
import os
import re
import tempfile
import time

TASK_NAME = re.compile(r"^[a-z][a-z0-9_]*$")
SCOPES = ("database", "kit")

# Exit codes shared by every caller, matching _exakit_manifest_write_error in
# common.sh so the shell can name the remedy without parsing a traceback.
EXIT_USAGE = 2
EXIT_NO_MANIFEST = 3
EXIT_BAD_MANIFEST = 4
EXIT_NOT_WRITABLE = 5


class StateError(Exception):
    """A state problem with an exit code the shell knows how to explain."""

    def __init__(self, message, code):
        super().__init__(message)
        self.code = code


def load_tasks(path):
    """The task list from tasks.json, validated, in file order."""
    try:
        with open(path, encoding="utf-8") as handle:
            doc = json.load(handle)
    except OSError as error:
        raise StateError("cannot read %s: %s" % (path, error), EXIT_USAGE)
    except ValueError as error:
        raise StateError("%s is not valid JSON: %s" % (path, error), EXIT_USAGE)
    tasks = doc.get("tasks") if isinstance(doc, dict) else None
    if not isinstance(tasks, list):
        raise StateError("%s has no \"tasks\" list" % path, EXIT_USAGE)
    seen = set()
    result = []
    for entry in tasks:
        name = entry.get("name") if isinstance(entry, dict) else None
        scope = entry.get("scope") if isinstance(entry, dict) else None
        if not isinstance(name, str) or not TASK_NAME.match(name):
            raise StateError("%s: task name %r is not [a-z][a-z0-9_]*" % (path, name), EXIT_USAGE)
        if scope not in SCOPES:
            raise StateError("%s: task %s has scope %r (expected one of %s)"
                             % (path, name, scope, ", ".join(SCOPES)), EXIT_USAGE)
        if name in seen:
            raise StateError("%s: task %s is listed twice" % (path, name), EXIT_USAGE)
        seen.add(name)
        result.append({"name": name, "scope": scope})
    return result


def read_manifest(path):
    """The manifest as a dict. Missing and unreadable are different answers."""
    if not os.path.exists(path):
        raise StateError("no install manifest at %s" % path, EXIT_NO_MANIFEST)
    try:
        with open(path, encoding="utf-8") as handle:
            doc = json.load(handle)
    except (OSError, ValueError) as error:
        raise StateError("the install manifest at %s could not be read: %s" % (path, error),
                         EXIT_BAD_MANIFEST)
    if not isinstance(doc, dict):
        raise StateError("the install manifest at %s is not a JSON object" % path, EXIT_BAD_MANIFEST)
    return doc


def completed(doc):
    """Names recorded as completed, in the order they were recorded."""
    node = doc.get("core_tasks")
    names = node.get("completed") if isinstance(node, dict) else None
    if not isinstance(names, list):
        return []
    return [name for name in names if isinstance(name, str)]


def pending(tasks, doc, scope=None):
    """Task names not yet completed, in tasks.json order."""
    done = set(completed(doc))
    return [task["name"] for task in tasks
            if task["name"] not in done and (scope is None or task["scope"] == scope)]


@contextlib.contextmanager
def manifest_lock(path):
    """Exclusive lock on <path>.lock for the length of a read-modify-write.

    POSIX uses flock, as mark_step and manifest_set do. Windows has no flock;
    the PowerShell writers open the lock file with FileShare::None, so holding
    an open handle here keeps them out, and msvcrt.locking keeps a second
    Python writer out. A lock that cannot be had in about five seconds is not
    worth failing an install over - PowerShell proceeds unlocked in the same
    case - so neither does this.
    """
    lock_path = path + ".lock"
    handle = None
    if os.name == "nt":
        import msvcrt
        deadline = time.time() + 5
        while True:
            try:
                handle = open(lock_path, "a+")
                # Byte 0 for every writer: "a+" opens at the end of the file.
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
                break
            except OSError:
                if handle is not None:
                    handle.close()
                    handle = None
                if time.time() >= deadline:
                    break
                time.sleep(0.025)
        try:
            yield
        finally:
            if handle is not None:
                try:
                    handle.seek(0)
                    msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
                except OSError:
                    pass
                handle.close()
        return
    import fcntl
    try:
        handle = open(lock_path, "a+")
    except OSError as error:
        raise StateError("cannot open %s: %s" % (lock_path, error), EXIT_NOT_WRITABLE)
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        yield
    finally:
        handle.close()


def _write_atomic(path, doc):
    directory = os.path.dirname(path) or "."
    try:
        fd, tmp = tempfile.mkstemp(dir=directory, prefix=os.path.basename(path) + ".")
    except OSError as error:
        raise StateError("the install manifest at %s is not writable: %s" % (path, error),
                         EXIT_NOT_WRITABLE)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(doc, handle, indent=2)
            handle.write("\n")
        if os.name != "nt":
            os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def update_manifest(path, mutate):
    """Lock, read, apply mutate(doc), write atomically. Returns mutate's result."""
    if not os.path.exists(path):
        raise StateError("no install manifest at %s" % path, EXIT_NO_MANIFEST)
    with manifest_lock(path):
        doc = read_manifest(path)
        result = mutate(doc)
        try:
            _write_atomic(path, doc)
        except OSError as error:
            raise StateError("the install manifest at %s is not writable: %s" % (path, error),
                             EXIT_NOT_WRITABLE)
    return result


def mark_completed(path, name):
    """Record one task name as completed. Idempotent; keeps recording order."""
    def mutate(doc):
        node = doc.get("core_tasks")
        if not isinstance(node, dict):
            node = {}
            doc["core_tasks"] = node
        names = node.get("completed")
        if not isinstance(names, list):
            names = []
        if name not in names:
            names.append(name)
        node["completed"] = names
        return names
    return update_manifest(path, mutate)


def component(doc, name):
    """components.<name> from a manifest dict, or {}."""
    node = doc.get("components")
    entry = node.get(name) if isinstance(node, dict) else None
    return entry if isinstance(entry, dict) else {}


def update_component(path, name, fields, remove=()):
    """Merge fields into components.<name>; drop the keys named in remove."""
    def mutate(doc):
        node = doc.get("components")
        if not isinstance(node, dict):
            node = {}
            doc["components"] = node
        entry = node.get(name)
        if not isinstance(entry, dict):
            entry = {}
            node[name] = entry
        entry.update(fields)
        for key in remove:
            entry.pop(key, None)
        return dict(entry)
    return update_manifest(path, mutate)
