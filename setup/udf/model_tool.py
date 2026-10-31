"""The rules behind `exakit model put | list | rm | prune | inspect`, used by marketplace/model_cli.py: which name a model file gets in the bucket directory, its digest, when an
existing file may be replaced, what a file's provenance says and whether it is trusted, and what the kit's record says
about each file. Standard library only (any Python 3.9 or later); no database, no network, and NO unpickling: a
pickle is read as a byte stream (pickletools), never loaded.

    python model_tool.py inspect <file> <bucket dir> <kit home>
        what the shell needs to know BEFORE the copy, as one JSON object: {"name", "kind" (pickle|joblib|onnx|other),
        "sha256", "size", "loads_code" (a pickle or joblib file runs code when loaded), "trusted" (a provenance
        sidecar matches the file's sha256 AND names an MLflow run or a workflow this kit knows), "provenance",
        "in_bucket" (same|different|absent), "reason"}.
    python model_tool.py put <file> <bucket dir> <udf root> <replace 0|1> [<kit home>]
        copies <file> to <bucket dir>/models/<its name>; the kit's record of the models (a JSON object, possibly {})
        comes on stdin. Prints three lines: copied|replaced|unchanged, the answer as one JSON object
        {"name", "path", "sha256", "size", "replaced", "trusted_origin", "provenance", "warning"}, and the record to
        store back. Exit 5 when a file of that name with a DIFFERENT digest is there and <replace> is 0 (nothing is
        copied), exit 6 over 500 MB, exit 2 for input it refuses; the reason on stderr. The trust decision (prompt,
        --yes, EXAKIT_MODEL_TRUST) is the shell's, from `inspect`; put never prompts.
    python model_tool.py list <bucket dir> <udf root> [<created 0|1> [<mapping>]]
        the files under <bucket dir>/models, each with its digest held against the record (stdin), as one JSON object
        {"bucket_dir", "udf_root", "created", "mapping", "models": [{"name", "path", "sha256", "size",
         "recorded_sha256", "status"}], "missing"}; status is ok, changed (the digest differs from the record) or
        unrecorded. created says the shell made the bucket folder on this call; mapping where the path came from
        (bucketfs.conf or the default).
    python model_tool.py rm <name> <bucket dir> <udf root>
    python model_tool.py prune <bucket dir> <udf root> <kit home> <days> <apply 0|1>
        old records nothing refers to: not a handoff, not a provenance run id, and not a model logged by an MLflow run
        in the kit's store (exasol_mlflow.records, the local store or the kit's server; a remote server is not
        consulted and the answer says so).

The record is components.udf_devkit.models in the kit's manifest: per name the sha256, size, the /buckets path, the
provenance and when it was put. Nothing about the database or a credential is read or written here.
"""

from __future__ import annotations

import hashlib
import json
import os
import pickletools
import re
import sqlite3
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

MODELS = "models"                                  # the folder inside the bucket every model lands in
_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$")
_PART = ".part"                                    # a copy in progress; never listed, never a model
MAX_MODEL_BYTES = 500_000_000
SIDECAR = ".provenance.json"
SIDECAR_KEYS = ("sha256", "run_id", "workflow_id", "python", "scikit-learn", "pickle_protocol", "source")
_VERSION = re.compile(r"^\d+(\.\d+){1,3}([a-z]+\d*)?(\.post\d+)?(\.dev\d+)?$")
_SKLEARN_KEY = b"_sklearn_version"
_FULL_SCAN_LIMIT = 64 << 20                        # a stream larger than this is not walked op by op
PICKLE_SUFFIXES = (".pkl", ".pickle", ".pck", ".p")
JOBLIB_SUFFIXES = (".joblib", ".jl")
ONNX_SUFFIXES = (".onnx",)
TRUST_WARNING = "Only load pickle or joblib models from a source you trust."
# The folder of the kit package that reads the MLflow store (exasol_mlflow), beside this repo copy.
_MLFLOW_PACKAGE = Path(__file__).resolve().parents[2] / "packages" / "exasol-mlflow"


class Refused(ValueError):
    """Input the kit refuses; the message names what is wrong. Exit 2."""

    code = 2


class NotConfirmed(Refused):
    """A different file of the same name is there and --replace was not given. Exit 5, like every unconfirmed step."""

    code = 5


class TooLarge(Refused):
    code = 6


def model_name(source: str) -> str:
    """The name a model file keeps in the bucket: its own file name, plain enough for a /buckets path in SQL."""
    name = os.path.basename(source.replace("\\", "/").rstrip("/"))
    if not _NAME.match(name) or name.endswith(_PART):
        raise Refused(f"'{name}' cannot be a model name in the bucket: use letters, digits, '.', '_' and '-' "
                      "(for example churn_model.pkl); rename the file and put it again.")
    return name


def digest(path: Path) -> tuple[str, int]:
    """(sha256 hex, size in bytes) of a file, read in blocks."""
    sha, size = hashlib.sha256(), 0
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            sha.update(block)
            size += len(block)
    return sha.hexdigest(), size


def read_record(text: str) -> dict:
    """The kit's record of the models; anything that is not a JSON object reads as an empty record."""
    try:
        record = json.loads(text) if text.strip() else {}
    except ValueError:
        return {}
    return record if isinstance(record, dict) else {}


def _now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


# --- what a model file is, read without loading it -------------------------------------------------------------------

def model_kind(path: Path) -> str:
    """pickle, joblib, onnx or other: by suffix, and a file of another suffix that starts with the pickle PROTO
    opcode is a pickle too."""
    lowered = path.name.lower()
    if lowered.endswith(ONNX_SUFFIXES):
        return "onnx"
    if lowered.endswith(JOBLIB_SUFFIXES):
        return "joblib"
    if lowered.endswith(PICKLE_SUFFIXES):
        return "pickle"
    try:
        with open(path, "rb") as handle:
            head = handle.read(2)
    except OSError:
        return "other"
    return "pickle" if head[:1] == b"\x80" and head[1:2] and head[1] <= 5 else "other"


def pickle_protocol_of(data: bytes) -> int | None:
    """The protocol a pickle stream announces (PROTO opcode), 0 or 1 for a stream without one; None when the bytes
    are not a pickle at all."""
    if not data:
        return None
    if data[:1] == b"\x80" and len(data) > 1:
        return data[1]
    # Protocol 0 and 1 streams start with a plain opcode; ones that are not even that are not a pickle.
    return 0 if data[:1] in (b"(", b"c", b"]", b"}", b"I", b"S", b"V", b"N", b"F", b"L", b"p", b"q", b"K", b"X", b"U", b"T") else None


def _string_arg(op, arg) -> str | None:
    return arg if op.name in ("SHORT_BINUNICODE", "BINUNICODE", "BINUNICODE8", "UNICODE", "STRING",
                              "SHORT_BINSTRING", "BINSTRING") and isinstance(arg, str) else None


def sklearn_version_of(data: bytes) -> str | None:
    """The scikit-learn version an estimator was pickled with - the ``_sklearn_version`` entry every estimator's
    state carries - read from the stream with pickletools, never by unpickling. None when the stream holds none (not a
    scikit-learn estimator, a compressed joblib file, not a pickle)."""
    at = data.find(_SKLEARN_KEY)
    if at < 0:
        return None
    # The key's opcode starts just before its text: SHORT_BINUNICODE (0x8c, length) in protocol 4+, BINUNICODE
    # ('X', 4-byte length) before, UNICODE ('V') in protocol 0. From there, pickletools reads the key, its memo
    # opcode and the value - a few opcodes, however large the file.
    for start in (at - 2, at - 5, at - 1):
        if start < 0:
            continue
        found = _value_after_key(data, start)
        if found:
            return found
    if len(data) > _FULL_SCAN_LIMIT:
        return None
    return _value_by_full_scan(data)


def _value_after_key(data: bytes, start: int) -> str | None:
    try:
        ops = pickletools.genops(data[start:start + 1024])
        op, arg, _ = next(ops)
        if _string_arg(op, arg) != _SKLEARN_KEY.decode("ascii"):
            return None
        for op, arg, _ in ops:
            if op.name in ("MEMOIZE", "BINPUT", "LONG_BINPUT", "PUT"):
                continue
            value = _string_arg(op, arg)
            return value if value and _VERSION.match(value) else None
    except Exception:  # noqa: BLE001 - a slice that is not a stream, or ends mid-opcode: not this guess
        return None
    return None


def _value_by_full_scan(data: bytes) -> str | None:
    """The slow way, for a stream whose first key is a memo reference: walk every opcode with the memo."""
    memo: dict[int, str] = {}
    last: str | None = None
    want_value = False
    counter = 0
    try:
        for op, arg, _ in pickletools.genops(data):
            if op.name == "MEMOIZE":
                if last is not None:
                    memo[counter] = last
                counter += 1
                continue
            if op.name in ("BINPUT", "LONG_BINPUT", "PUT"):
                if last is not None:
                    memo[int(arg)] = last
                continue
            value = _string_arg(op, arg)
            if value is None and op.name in ("BINGET", "LONG_BINGET", "GET"):
                value = memo.get(int(arg))
            if want_value:
                if value and _VERSION.match(value):
                    return value
                want_value = False
            elif value == _SKLEARN_KEY.decode("ascii"):
                want_value = True
            last = value
    except Exception:  # noqa: BLE001 - not a complete stream
        return None
    return None


def header_provenance(path: Path, sha: str) -> dict | None:
    """What the file itself says about its origin: for a pickle or joblib file, the scikit-learn version and the
    pickle protocol in its header (python is not in a pickle; it stays null). None for a file that is not a pickle."""
    if model_kind(path) not in ("pickle", "joblib"):
        return None
    try:
        data = path.read_bytes()
    except OSError:
        return None
    protocol = pickle_protocol_of(data)
    if protocol is None:
        return None
    return {"sha256": sha, "run_id": None, "workflow_id": None, "python": None,
            "scikit-learn": sklearn_version_of(data), "pickle_protocol": protocol, "source": "pickle-header"}


# --- provenance and trust -------------------------------------------------------------------------------------------

def _records_module(kit_home: str | None):
    """exasol_mlflow.records from the repo copy beside this file, or None (the lookup is then skipped)."""
    if kit_home:
        os.environ["EXAKIT_HOME"] = kit_home
    if str(_MLFLOW_PACKAGE) not in sys.path and _MLFLOW_PACKAGE.is_dir():
        sys.path.insert(0, str(_MLFLOW_PACKAGE))
    try:
        from exasol_mlflow import records
    except Exception:  # noqa: BLE001 - an old or missing package copy: no lookup
        return None
    return records


def workflow_known(kit_home: str | None, workflow_id: str | None) -> bool:
    """Whether the kit holds a log for the workflow ($EXAKIT_HOME/workflows/<id>.jsonl)."""
    if not kit_home or not workflow_id or not re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$", str(workflow_id)):
        return False
    return (Path(kit_home) / "workflows" / f"{workflow_id}.jsonl").is_file()


def run_known(kit_home: str | None, run_id: str | None) -> bool:
    """Whether the MLflow store on this machine holds the run (exasol_mlflow.records.run_exists); a store that cannot
    be consulted (a remote server) counts as unknown, so the file is not trusted on its say-so."""
    if not run_id or not re.match(r"^[A-Za-z0-9-]{1,64}$", str(run_id)):
        return False
    records = _records_module(kit_home)
    if records is None:
        return False
    try:
        return records.run_exists(str(run_id)) is True
    except Exception:  # noqa: BLE001 - a broken store is not a trusted one
        return False


def provenance_of(src: Path, sha: str, kit_home: str | None) -> tuple[dict | None, bool, str]:
    """(provenance, trusted, reason) for a model file: the sidecar <file>.provenance.json when its sha256 is the
    file's, trusted only when it also names a run_id the kit's MLflow store holds or a workflow_id the kit logged;
    else what the pickle header says (never trusted); else nothing."""
    sidecar = Path(str(src) + SIDECAR)
    if sidecar.is_file():
        try:
            candidate = json.loads(sidecar.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            candidate = None
        if isinstance(candidate, dict) and candidate.get("sha256") == sha:
            doc = {key: candidate.get(key) for key in SIDECAR_KEYS}
            doc["source"] = candidate.get("source") or "sidecar"
            if run_known(kit_home, candidate.get("run_id")):
                return doc, True, f"the provenance sidecar matches the file and names MLflow run {candidate.get('run_id')} of this kit"
            if workflow_known(kit_home, candidate.get("workflow_id")):
                return doc, True, f"the provenance sidecar matches the file and names workflow {candidate.get('workflow_id')} of this kit"
            header = header_provenance(src, sha)
            if header and not doc.get("scikit-learn"):
                doc["scikit-learn"] = header["scikit-learn"]
            if header and doc.get("pickle_protocol") is None:
                doc["pickle_protocol"] = header["pickle_protocol"]
            return doc, False, ("the provenance sidecar matches the file but names no MLflow run or workflow this kit knows"
                                if candidate.get("run_id") or candidate.get("workflow_id")
                                else "the provenance sidecar matches the file but names no MLflow run or workflow")
        elif isinstance(candidate, dict):
            reason = "the provenance sidecar does not match the file (its sha256 is another file's)"
        else:
            reason = "the provenance sidecar is not a JSON object"
    else:
        reason = "no provenance sidecar (<file>.provenance.json) beside the file"
    header = header_provenance(src, sha)
    if header is not None:
        return header, False, reason + "; the pickle header says scikit-learn " + (header["scikit-learn"] or "unknown")
    return None, False, reason


def inspect(source: str, bucket_dir: str, kit_home: str | None) -> dict:
    """What the shell decides the prompt from, and what `exakit model inspect` prints."""
    src = Path(source).expanduser()
    if not src.is_file():
        raise Refused(f"{source} is not a file.")
    name = model_name(str(src))
    sha, size = digest(src)
    kind = model_kind(src)
    provenance, trusted, reason = provenance_of(src, sha, kit_home)
    dest = Path(bucket_dir) / MODELS / name
    in_bucket = "absent"
    if dest.is_file():
        in_bucket = "same" if digest(dest)[0] == sha else "different"
    return {"name": name, "kind": kind, "sha256": sha, "size": size, "loads_code": kind in ("pickle", "joblib"),
            "trusted": trusted, "provenance": provenance, "in_bucket": in_bucket, "reason": reason,
            "pickled_with": (provenance or {}).get("scikit-learn") if provenance else None,
            "warning": None if (trusted or kind not in ("pickle", "joblib")) else TRUST_WARNING}


# --- put / rm / prune / list ----------------------------------------------------------------------------------------

def _write_sidecar(dest: Path, doc: dict) -> None:
    folder = dest.parent
    folder.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", prefix="." + dest.name + _PART + "-", dir=folder,
                                     encoding="utf-8", delete=False) as output:
        part = Path(output.name)
        json.dump({key: doc.get(key) for key in SIDECAR_KEYS}, output, sort_keys=True)
        output.flush()
        os.fsync(output.fileno())
    try:
        os.replace(part, Path(str(dest) + SIDECAR))
    finally:
        if part.exists():
            part.unlink()


def put(source: str, bucket_dir: str, udf_root: str, replace: bool, record: dict,
        kit_home: str | None = None) -> tuple[str, dict, dict]:
    """Copy ``source`` into the bucket's models folder: (what happened, the answer, the record to store)."""
    src = Path(source).expanduser()
    if not src.is_file():
        raise Refused(f"{source} is not a file.")
    if src.stat().st_size > MAX_MODEL_BYTES:
        raise TooLarge(f"{source} exceeds the 500 MB model limit; nothing was copied.")
    name = model_name(str(src))
    folder = Path(bucket_dir) / MODELS
    dest = folder / name
    path = f"{udf_root.rstrip('/')}/{MODELS}/{name}"
    sha, size = digest(src)
    if size > MAX_MODEL_BYTES:
        raise TooLarge(f"{source} exceeds the 500 MB model limit; nothing was copied.")
    provenance, trusted, _ = provenance_of(src, sha, kit_home)
    action = "copied"
    if dest.is_file():
        there, _ = digest(dest)
        if there == sha:
            action = "unchanged"
        elif not replace:
            raise NotConfirmed(f"{path} already holds a different file (sha256 {there[:12]}..., this one is "
                               f"{sha[:12]}...). Nothing was copied; --replace overwrites it.")
        else:
            action = "replaced"
    if action != "unchanged":
        folder.mkdir(parents=True, exist_ok=True)
        part = None
        try:
            with tempfile.NamedTemporaryFile(prefix="." + name + _PART + "-", dir=folder, delete=False) as output:
                part = Path(output.name)
                with src.open("rb") as source_file:
                    for block in iter(lambda: source_file.read(1 << 20), b""):
                        output.write(block)
                output.flush()
                os.fsync(output.fileno())
            if digest(part)[0] != sha:
                raise OSError(f"the copy at {part} does not match {source}")
            os.replace(part, dest)
            if os.name != "nt":
                directory_fd = os.open(folder, os.O_RDONLY)
                try:
                    os.fsync(directory_fd)
                finally:
                    os.close(directory_fd)
        finally:
            if part is not None and part.exists():
                part.unlink()
        if digest(dest)[0] != sha:
            raise OSError(f"the copy at {dest} does not match {source}; put it again")
    dest_sidecar = Path(str(dest) + SIDECAR)
    if provenance is not None:
        # The sidecar travels with the file so the scoring UDF can say "pickled with scikit-learn X" (AC-ML4.5),
        # whether it came from 01_train or from the pickle's own header.
        _write_sidecar(dest, provenance)
    elif dest_sidecar.exists():
        dest_sidecar.unlink()
    previous = record.get(name) if isinstance(record.get(name), dict) else {}
    updated = dict(record)
    stored = dict(provenance, trusted=trusted) if provenance is not None else None
    updated[name] = {"sha256": sha, "size": size, "path": path, "provenance": stored,
                     "put_at": previous.get("put_at") if action == "unchanged" and previous.get("sha256") == sha
                     else _now()}
    loads_code = model_kind(src) in ("pickle", "joblib")
    answer = {"name": name, "path": path, "sha256": sha, "size": size, "replaced": action == "replaced",
              "trusted_origin": trusted, "provenance": stored,
              "warning": None if (trusted or not loads_code) else TRUST_WARNING}
    return action, answer, updated


def remove(name: str, bucket_dir: str, udf_root: str, record: dict) -> tuple[dict, dict]:
    """Remove one recorded model, refusing symlinks and unrecorded files."""
    if model_name(name) != name:
        raise Refused("Name one model file, without a directory.")
    dest = Path(bucket_dir) / MODELS / name
    if name not in record:
        raise Refused(f"{name} is not recorded by exakit model put.")
    if dest.is_symlink():
        raise Refused(f"{name} is a symlink; remove it manually after inspection.")
    if dest.is_file():
        actual, _ = digest(dest)
        if actual != record[name].get("sha256"):
            raise NotConfirmed(f"{name} changed since it was put; inspect it before removal.")
        dest.unlink()
    sidecar = Path(str(dest) + SIDECAR)
    if sidecar.is_file():
        sidecar.unlink()
    updated = dict(record)
    updated.pop(name)
    return {"name": name, "path": f"{udf_root.rstrip('/')}/{MODELS}/{name}", "removed": True}, updated


def mlflow_references(kit_home: str | None) -> tuple[set[str] | None, str]:
    """(the sha256 of every model an MLflow run in the kit's store logged, where that came from) - None when the
    store is a remote server, which is not consulted (the answer says so)."""
    records = _records_module(kit_home)
    if records is None:
        return None, "the exasol_mlflow package is not beside this kit copy; MLflow runs were not consulted"
    try:
        digests, where = records.model_digests()
    except Exception as err:  # noqa: BLE001 - a store that cannot be read is reported, not fatal
        return None, f"the MLflow store could not be read ({err}); MLflow runs were not consulted"
    return digests, where


def prune(bucket_dir: str, udf_root: str, kit_home: str, days: int, apply: bool, record: dict) -> tuple[dict, dict]:
    """Find old unreferenced records. A model with training provenance is kept because its MLflow run may be remote;
    one whose digest an MLflow run in the kit's store logged is kept because that run refers to it."""
    if days < 1:
        raise Refused("--older-than must be at least one day.")
    threshold = datetime.now(timezone.utc) - timedelta(days=days)
    handoffs = Path(kit_home) / "handoffs"
    handoff_text = "\n".join(p.read_text(encoding="utf-8", errors="replace") for p in handoffs.glob("*.json")) \
        if handoffs.is_dir() else ""
    logged, mlflow_note = mlflow_references(kit_home)
    candidates, kept, removed = [], [], []
    updated = dict(record)
    for name, entry in sorted(record.items()):
        if not isinstance(entry, dict):
            kept.append({"name": name, "reason": "invalid record"})
            continue
        try:
            put_at = datetime.fromisoformat(str(entry["put_at"]).replace("Z", "+00:00"))
        except (KeyError, ValueError):
            kept.append({"name": name, "reason": "unknown age"})
            continue
        if put_at > threshold:
            kept.append({"name": name, "reason": "recent"})
            continue
        provenance = entry.get("provenance")
        if isinstance(provenance, dict) and provenance.get("run_id"):
            kept.append({"name": name, "reason": "MLflow run"})
            continue
        if logged and str(entry.get("sha256")) in logged:
            kept.append({"name": name, "reason": "logged by an MLflow run"})
            continue
        if name in handoff_text or str(entry.get("sha256")) in handoff_text:
            kept.append({"name": name, "reason": "handoff"})
            continue
        dest = Path(bucket_dir) / MODELS / name
        if dest.is_symlink() or (dest.is_file() and digest(dest)[0] != entry.get("sha256")):
            kept.append({"name": name, "reason": "changed or symlink"})
            continue
        candidates.append(name)
        if apply:
            remove(name, bucket_dir, udf_root, updated)
            updated.pop(name)
            removed.append(name)
    return {"dry_run": not apply, "older_than_days": days, "candidates": candidates, "removed": removed,
            "kept": kept, "mlflow": mlflow_note}, updated


def listing(bucket_dir: str, udf_root: str, record: dict, created: bool = False, mapping: str = "") -> dict:
    """What is in the bucket's models folder, each file's digest held against the record."""
    folder = Path(bucket_dir) / MODELS
    models = []
    if folder.is_dir():
        for path in sorted(p for p in folder.rglob("*") if p.is_file() and _PART not in p.name
                           and not p.name.endswith(SIDECAR)):
            name = path.relative_to(folder).as_posix()
            sha, size = digest(path)
            known = record.get(name) if isinstance(record.get(name), dict) else None
            recorded = known.get("sha256") if known else None
            status = "unrecorded" if not recorded else ("ok" if recorded == sha else "changed")
            models.append({"name": name, "path": f"{udf_root.rstrip('/')}/{MODELS}/{name}", "sha256": sha,
                           "size": size, "recorded_sha256": recorded, "status": status})
    present = {m["name"] for m in models}
    return {"bucket_dir": str(bucket_dir), "udf_root": udf_root.rstrip("/"), "created": bool(created),
            "mapping": mapping or "default", "models": models,
            "missing": sorted(name for name in record if name not in present)}


def main(argv: list[str]) -> int:
    command, args = (argv[0], argv[1:]) if argv else ("", [])
    try:
        if command == "inspect" and len(args) == 3:
            print(json.dumps(inspect(args[0], args[1], args[2] or None)))
            return 0
        if command == "put" and len(args) in (4, 5):
            action, answer, updated = put(args[0], args[1], args[2], args[3] == "1", read_record(sys.stdin.read()),
                                          args[4] if len(args) == 5 and args[4] else None)
            print(action)
            print(json.dumps(answer))
            print(json.dumps(updated, sort_keys=True))
            return 0
        if command == "list" and len(args) in (2, 3, 4):
            print(json.dumps(listing(args[0], args[1], read_record(sys.stdin.read()),
                                     len(args) >= 3 and args[2] == "1", args[3] if len(args) == 4 else "")))
            return 0
        if command == "rm" and len(args) == 3:
            answer, updated = remove(args[0], args[1], args[2], read_record(sys.stdin.read()))
            print(json.dumps(answer))
            print(json.dumps(updated, sort_keys=True))
            return 0
        if command == "prune" and len(args) == 5:
            if not args[3].isdigit():
                raise Refused("--older-than must be a positive number of days.")
            answer, updated = prune(args[0], args[1], args[2], int(args[3]), args[4] == "1",
                                    read_record(sys.stdin.read()))
            print(json.dumps(answer))
            print(json.dumps(updated, sort_keys=True))
            return 0
    except Refused as err:
        print(str(err), file=sys.stderr)
        return err.code
    except OSError as err:
        print(f"{err.__class__.__name__}: {err}", file=sys.stderr)
        return 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
