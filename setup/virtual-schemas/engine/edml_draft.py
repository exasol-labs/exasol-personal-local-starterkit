"""An EDML mapping drafted from the bucket or container itself.

The S3 and Azure Blob connectors read their tables from an EDML mapping. A
user who leaves the mapping empty gets one drafted here: the objects are
listed with the credential just given, grouped by folder and file type, and
each group becomes one table. JSON needs its fields spelled out, so one
sample per JSON group is read (the first 64 KiB) and its top-level keys typed;
CSV and Parquet are written without fields, and the adapter infers their
columns itself (its CsvHeaderDetector and Parquet schema reader).

Standard library only: the engine runs on the kit's Python, which has no AWS
or Azure SDK. S3 requests are signed with SigV4 (sigv4_headers), Azure ones
carry the SAS or a Shared Key signature. Nothing here prints or returns the
secret: errors are said in the kit's words, never with a request URL.
"""

import base64
import datetime
import hashlib
import hmac
import json
import os
import re
import ssl
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

import document

SCHEMA = "https://schemas.exasol.com/edml-2.1.0.json"
MAX_TABLES = 25
MAX_OBJECTS = 10000
SAMPLE_BYTES = 65536
SAMPLE_RECORDS = 50
SAMPLE_FILES = 10          # .json holds one document per file: up to this many are read
VARCHAR = 2000
JSON_TEXT = 2000000
AZURE_VERSION = "2021-08-06"
TIMEOUT = 30

# The adapter knows a file's type by its extension (.json, .jsonl, .csv,
# .parquet). .ndjson is the same content as .jsonl, but the adapter does not
# read that extension, so such files are reported, not mapped.
FORMATS = {".json": "json", ".jsonl": "jsonl", ".csv": "csv", ".parquet": "parquet"}
FORMAT_NAMES = {"json": "JSON", "jsonl": "JSON Lines", "csv": "CSV", "parquet": "Parquet"}
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
TIMESTAMP = re.compile(r"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d{1,9})?)?(Z|[+-]\d{2}:?\d{2})?$")
LENIENT = "CONVERT_OR_NULL"


class DraftError(Exception):
    pass


# --- requests -------------------------------------------------------------------

def _context():
    try:
        import certifi  # in the kit's pyexasol venv; the system store otherwise
        return ssl.create_default_context(cafile=certifi.where())
    except Exception:  # noqa: BLE001
        return ssl.create_default_context()


def _http(url, headers):
    """(status, headers, body) of a GET; an HTTP error is an answer too."""
    request = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT, context=_context()) as response:
            return response.status, dict(response.headers), response.read()
    except urllib.error.HTTPError as error:
        return error.code, dict(error.headers or {}), error.read()
    except (urllib.error.URLError, OSError) as error:
        reason = getattr(error, "reason", error)
        raise DraftError("the network did not answer (%s)" % type(reason).__name__
                         if not isinstance(reason, str) else "the network did not answer (%s)" % reason)


# --- AWS SigV4 ------------------------------------------------------------------

def _hmac(key, text):
    return hmac.new(key, text.encode("utf-8"), hashlib.sha256).digest()


def _quote(text, safe="-_.~"):
    return urllib.parse.quote(text, safe=safe)


def sigv4_headers(method, host, path, query, headers, region, service, key_id, secret, now,
                  payload_hash=None, token=None):
    """The request headers with SigV4's Authorization added. query is a list of
    (name, value), path the URI-encoded path; every given header is signed."""
    stamp = now.strftime("%Y%m%dT%H%M%SZ")
    day = stamp[:8]
    payload_hash = payload_hash or hashlib.sha256(b"").hexdigest()
    signed = {k.lower(): " ".join(str(v).split()) for k, v in headers.items()}
    signed["host"] = host
    signed["x-amz-date"] = stamp
    if token:
        signed["x-amz-security-token"] = token
    names = sorted(signed)
    canonical_query = "&".join("%s=%s" % (_quote(k), _quote(v)) for k, v in sorted(query))
    canonical = "\n".join([method, path, canonical_query,
                           "".join("%s:%s\n" % (n, signed[n]) for n in names),
                           ";".join(names), payload_hash])
    scope = "%s/%s/%s/aws4_request" % (day, region, service)
    to_sign = "\n".join(["AWS4-HMAC-SHA256", stamp, scope, hashlib.sha256(canonical.encode("utf-8")).hexdigest()])
    key = _hmac(_hmac(_hmac(_hmac(("AWS4" + secret).encode("utf-8"), day), region), service), "aws4_request")
    signature = hmac.new(key, to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
    out = dict(signed)
    out["authorization"] = "AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s" % (
        key_id, scope, ";".join(names), signature)
    return out


def _s3_error(status, body, headers, bucket, region, what):
    code = ""
    match = re.search(rb"<Code>([^<]+)</Code>", body or b"")
    if match:
        code = match.group(1).decode("ascii", "replace")
    if code in ("PermanentRedirect", "AuthorizationHeaderMalformed", "IllegalLocationConstraintException") \
            or status == 301:
        actual = headers.get("x-amz-bucket-region") or headers.get("X-Amz-Bucket-Region")
        return "bucket %s is not in %s%s" % (bucket, region, " but in %s" % actual if actual else "")
    if code == "NoSuchBucket" or status == 404 and what == "list":
        return "there is no bucket %s in %s" % (bucket, region)
    if code in ("InvalidAccessKeyId", "SignatureDoesNotMatch", "ExpiredToken", "InvalidToken"):
        return "S3 rejected the access key (%s)" % code
    if code == "RequestTimeTooSkewed":
        return "this computer's clock is too far from S3's (RequestTimeTooSkewed)"
    if status == 403:
        if what == "list":
            return "the key cannot list the bucket (s3:ListBucket)"
        return "the key cannot read the objects (s3:GetObject)"
    return "S3 answered %s%s" % (status, " (%s)" % code if code else "")


class S3(object):
    def __init__(self, values, secret):
        self.bucket, self.region = values["bucket"], values["region"]
        self.key_id, self.secret, self.token, _ = document._aws_keys(values, secret)
        self.host = "%s.s3.%s.amazonaws.com" % (self.bucket, self.region)
        self.where = "bucket"

    def _get(self, path, query, extra=None):
        headers = sigv4_headers("GET", self.host, path, query, dict(extra or {}, **{"x-amz-content-sha256":
                                hashlib.sha256(b"").hexdigest()}), self.region, "s3", self.key_id, self.secret,
                                datetime.datetime.now(datetime.timezone.utc), token=self.token)
        headers.pop("host", None)
        qs = "&".join("%s=%s" % (_quote(k), _quote(v)) for k, v in sorted(query))
        return _http("https://%s%s%s" % (self.host, path, "?" + qs if qs else ""), headers)

    def objects(self, prefix="", limit=MAX_OBJECTS):
        """([(key, size)], truncated): at most limit objects under prefix, in key order."""
        out, token = [], None
        while len(out) < limit:
            query = [("list-type", "2"), ("max-keys", str(min(1000, limit - len(out))))]
            if prefix:
                query.append(("prefix", prefix))
            if token:
                query.append(("continuation-token", token))
            status, headers, body = self._get("/", query)
            if status != 200:
                raise DraftError(_s3_error(status, body, headers, self.bucket, self.region, "list"))
            root = ET.fromstring(body)
            ns = root.tag.split("}")[0] + "}" if root.tag.startswith("{") else ""
            for item in root.findall(ns + "Contents"):
                out.append((item.findtext(ns + "Key") or "", int(item.findtext(ns + "Size") or 0)))
            token = root.findtext(ns + "NextContinuationToken")
            if root.findtext(ns + "IsTruncated") != "true" or not token:
                return out, False
        return out[:limit], True

    def head(self, key, size=SAMPLE_BYTES):
        status, headers, body = self._get("/" + _quote(key, safe="/-_.~"), [], {"range": "bytes=0-%d" % (size - 1)})
        if status not in (200, 206):
            raise DraftError(_s3_error(status, body, headers, self.bucket, self.region, "get"))
        return body[:size], status == 206 and _total(headers) > size


def _total(headers):
    value = headers.get("Content-Range") or headers.get("content-range") or ""
    try:
        return int(value.rsplit("/", 1)[1])
    except (IndexError, ValueError):
        return 0


# --- Azure Blob -----------------------------------------------------------------

class Azure(object):
    def __init__(self, values, secret):
        self.account, self.container = values["account"], values["container"]
        body, _, _ = document.credential("azure-blob", values, secret)
        conn = json.loads(body)["absStorageAccountConnectionString"]
        parts = dict(p.split("=", 1) for p in conn.split(";") if "=" in p)
        self.sas = parts.get("SharedAccessSignature")
        self.key = parts.get("AccountKey")
        self.host = "%s.blob.core.windows.net" % self.account
        self.where = "container"

    def _get(self, path, query, extra=None):
        headers = {"x-ms-version": AZURE_VERSION,
                   "x-ms-date": datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S GMT")}
        headers.update(extra or {})
        qs = "&".join("%s=%s" % (_quote(k), _quote(v)) for k, v in query)
        if self.sas:
            qs = "&".join(filter(None, [qs, self.sas]))
        else:
            headers["Authorization"] = "SharedKey %s:%s" % (self.account, shared_key_signature(
                self.account, self.key, "GET", path, query, headers))
        return _http("https://%s%s%s" % (self.host, path, "?" + qs if qs else ""), headers)

    def _error(self, status, body, what):
        code = ""
        match = re.search(rb"<Code>([^<]+)</Code>", body or b"")
        if match:
            code = match.group(1).decode("ascii", "replace")
        if code == "ContainerNotFound":
            return "there is no container %s in account %s" % (self.container, self.account)
        if code in ("AuthenticationFailed", "AuthorizationFailure") or status == 403:
            if code == "AuthorizationPermissionMismatch" or "Permission" in code:
                return "the SAS cannot %s the container (it needs %s)" % (
                    what, "list (l)" if what == "list" else "read (r)")
            return "Azure rejected the credential (%s)" % (code or status)
        return "Azure answered %s%s" % (status, " (%s)" % code if code else "")

    def objects(self, prefix="", limit=MAX_OBJECTS):
        out, marker = [], ""
        path = "/" + self.container
        while len(out) < limit:
            query = [("restype", "container"), ("comp", "list"), ("maxresults", str(min(5000, limit - len(out))))]
            if prefix:
                query.append(("prefix", prefix))
            if marker:
                query.append(("marker", marker))
            status, _, body = self._get(path, query)
            if status != 200:
                raise DraftError(self._error(status, body, "list"))
            root = ET.fromstring(body)
            for blob in root.iter("Blob"):
                size = blob.findtext("Properties/Content-Length") or "0"
                out.append((blob.findtext("Name") or "", int(size)))
            marker = root.findtext("NextMarker") or ""
            if not marker:
                return out, False
        return out[:limit], True

    def head(self, key, size=SAMPLE_BYTES):
        status, headers, body = self._get("/%s/%s" % (self.container, _quote(key, safe="/-_.~")), [],
                                          {"x-ms-range": "bytes=0-%d" % (size - 1)})
        if status not in (200, 206):
            raise DraftError(self._error(status, body, "read"))
        return body[:size], status == 206 and _total(headers) > size


def shared_key_signature(account, key, method, path, query, headers):
    """Azure Storage Shared Key: the canonical request signed with the account key."""
    low = {k.lower(): v for k, v in headers.items()}
    standard = ["content-encoding", "content-language", "content-length", "content-md5", "content-type", "date",
                "if-modified-since", "if-match", "if-none-match", "if-unmodified-since", "range"]
    lines = [method] + [low.get(name, "") for name in standard]
    canonical_headers = "".join("%s:%s\n" % (k, low[k]) for k in sorted(low) if k.startswith("x-ms-"))
    resource = "/%s%s" % (account, path)
    params = {}
    for k, v in query:
        params.setdefault(k.lower(), []).append(v)
    for k in sorted(params):
        resource += "\n%s:%s" % (k, ",".join(sorted(params[k])))
    to_sign = "\n".join(lines) + "\n" + canonical_headers + resource
    digest = hmac.new(base64.b64decode(key), to_sign.encode("utf-8"), hashlib.sha256).digest()
    return base64.b64encode(digest).decode("ascii")


# --- grouping -------------------------------------------------------------------

def table_name(text):
    name = re.sub(r"[^A-Z0-9_]+", "_", text.upper()).strip("_")
    name = re.sub(r"_+", "_", name)
    if not name:
        name = "FILES"
    if not name[0].isalpha():
        name = "T_" + name
    return name[:120]


def group(objects):
    """(groups, notes): one group per folder and file type. A folder named
    key=value (a Hive partition) and everything below it belong to the folder
    above it, read with a ** glob."""
    groups, notes, odd = {}, [], {}
    for key, size in objects:
        leaf = key.rsplit("/", 1)[-1]
        parts = key.split("/")
        if key.endswith("/") or not leaf or size == 0 or leaf.startswith((".", "_")) or \
                any(p.startswith((".", "_")) for p in parts[:-1]):
            continue            # folder markers, empty objects, _SUCCESS, dot-files
        ext = os.path.splitext(leaf)[1].lower()
        fmt = FORMATS.get(ext)
        if not fmt:
            if ext in (".ndjson", ".gz", ".zip", ".csv.gz", ".txt", ".tsv", ".avro", ".orc", ".xml"):
                odd[ext] = odd.get(ext, 0) + 1
            continue
        folders = parts[:-1]
        nested = False
        for i, part in enumerate(folders):
            if "=" in part:
                folders, nested = folders[:i], True
                break
        prefix = "/".join(folders)
        entry = groups.setdefault((prefix, ext), {"prefix": prefix, "ext": ext, "format": fmt, "keys": [],
                                                  "nested": False})
        entry["keys"].append(key)
        entry["nested"] = entry["nested"] or nested
    for ext, count in sorted(odd.items()):
        why = "the adapter does not read .ndjson: rename them .jsonl" if ext == ".ndjson" else \
            "the adapter reads .json, .jsonl, .csv and .parquet only"
        notes.append("%d %s file%s skipped (%s)" % (count, ext, "" if count == 1 else "s", why))
    out = []
    for (prefix, ext), entry in sorted(groups.items()):
        if entry["nested"]:
            source = "%s/**/*%s" % (prefix, ext) if prefix else "**/*%s" % ext
        elif prefix:
            source = "%s/*%s" % (prefix, ext)      # files added to the folder later are read too
        elif len(entry["keys"]) == 1:
            source = entry["keys"][0]
        else:
            source = "*%s" % ext
        base = prefix.rsplit("/", 1)[-1] if prefix else (
            os.path.splitext(entry["keys"][0].rsplit("/", 1)[-1])[0] if len(entry["keys"]) == 1 else ext[1:])
        entry.update(source=source, base=table_name(base))
        out.append(entry)
    # One folder with two file types, or two folders of one name: told apart.
    counts = {}
    for entry in out:
        counts[entry["base"]] = counts.get(entry["base"], 0) + 1
    taken = set()
    for entry in out:
        name = entry["base"]
        if counts[name] > 1:
            name = "%s_%s" % (name, entry["format"].upper())
        candidate, n = name, 2
        while candidate in taken:
            candidate, n = "%s_%d" % (name, n), n + 1
        taken.add(candidate)
        entry["table"] = candidate
    return out, notes


# --- JSON inference ---------------------------------------------------------------

def records(data, fmt, truncated):
    """The JSON objects in a sample: one per line (jsonl), or the one document
    of a .json file. A JSON array file is said, not guessed: the adapter reads
    a .json file as one row."""
    text = data.decode("utf-8", "replace").lstrip("﻿")
    if fmt == "jsonl":
        lines = text.splitlines()
        if truncated and lines:
            lines = lines[:-1]           # cut by the 64 KiB read
        out = []
        for line in lines:
            line = line.strip()
            if not line:
                continue
            try:
                doc = json.loads(line)
            except ValueError:
                continue
            if isinstance(doc, dict):
                out.append(doc)
            if len(out) >= SAMPLE_RECORDS:
                break
        return out
    try:
        doc = json.loads(text)
    except ValueError:
        if truncated:
            raise DraftError("the file is larger than the 64 KiB sample")
        raise DraftError("the file is not valid JSON")
    if isinstance(doc, list):
        raise DraftError("it holds a JSON array, and the adapter reads one object per .json file: save it as "
                         "JSON Lines (.jsonl, one object per line)")
    if not isinstance(doc, dict):
        raise DraftError("it does not hold a JSON object")
    return [doc]


def kind_of(value):
    if value is None:
        return None
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, int):
        return "int" if len(str(abs(value))) <= 36 else "string"
    if isinstance(value, float):
        return "float"
    if isinstance(value, (dict, list)):
        return "json"
    text = str(value)
    if DATE.match(text):
        return "date"
    if TIMESTAMP.match(text):
        return "timestamp"
    return "string"


def merge(a, b):
    if a is None or a == b:
        return b if a is None else a
    if b is None:
        return a
    if {a, b} == {"int", "float"}:
        return "float"
    if {a, b} == {"date", "timestamp"}:
        return "timestamp"
    if "json" in (a, b):
        return "json"
    return "string"


def infer(docs):
    """[(key, kind)] in first-seen order over the sampled objects."""
    order, kinds = [], {}
    for doc in docs:
        for key, value in doc.items():
            if key not in kinds:
                order.append(key)
                kinds[key] = None
            kinds[key] = merge(kinds[key], kind_of(value))
    return [(key, kinds[key] or "string") for key in order]


COLUMN = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")


def field_mapping(key, kind):
    if kind == "int":
        body = {"toDecimalMapping": {"decimalPrecision": 36, "decimalScale": 0, "overflowBehaviour": "NULL",
                                     "notNumericBehaviour": LENIENT}}
    elif kind == "float":
        body = {"toDoubleMapping": {"notNumericBehaviour": LENIENT}}
    elif kind == "bool":
        body = {"toBoolMapping": {"notBooleanBehavior": LENIENT}}
    elif kind == "date":
        body = {"toDateMapping": {"notDateBehavior": LENIENT}}
    elif kind == "timestamp":
        body = {"toTimestampMapping": {"notTimestampBehavior": LENIENT}}
    elif kind == "json":
        body = {"toJsonMapping": {"varcharColumnSize": JSON_TEXT, "overflowBehaviour": "NULL"}}
    else:
        body = {"toVarcharMapping": {"varcharColumnSize": VARCHAR, "nonStringBehaviour": LENIENT}}
    if not COLUMN.match(key):
        # A key that is no SQL name (a space, a dot, a leading digit) gets one.
        list(body.values())[0]["destinationName"] = table_name(key)
    return body


TYPE_NAMES = {"int": "DECIMAL(36,0)", "float": "DOUBLE", "bool": "BOOLEAN", "date": "DATE",
              "timestamp": "TIMESTAMP", "json": "VARCHAR (JSON text)", "string": "VARCHAR(%d)" % VARCHAR}


def edml(entry, fields=None):
    doc = {"$schema": SCHEMA, "source": entry["source"], "destinationTable": entry["table"],
           "description": "Drafted by exakit from %d %s file%s; edit it freely"
                          % (len(entry["keys"]), FORMAT_NAMES[entry["format"]], "" if len(entry["keys"]) == 1 else "s")}
    if fields:
        doc["mapping"] = {"fields": {key: field_mapping(key, kind) for key, kind in fields}}
    return doc


# --- the draft --------------------------------------------------------------------

class LocalStore(object):
    """A folder standing in for the bucket (EXAKIT_VS_FAKE_STORE, the tests'
    stand-in, as EXAKIT_VS_FAKE_DB is the database's). A file .deny in it
    answers the listing as a store would that refuses it."""
    def __init__(self, root, where):
        self.root, self.where = root, where

    def objects(self, prefix="", limit=MAX_OBJECTS):
        if os.path.exists(os.path.join(self.root, ".deny")) and not prefix:
            raise DraftError("the key cannot list the bucket (s3:ListBucket)" if self.where == "bucket" else
                             "the SAS cannot list the container (it needs list (l))")
        out = []
        for folder, dirs, files in os.walk(self.root):
            dirs.sort()
            for leaf in sorted(files):
                path = os.path.join(folder, leaf)
                out.append((os.path.relpath(path, self.root).replace(os.sep, "/"), os.path.getsize(path)))
        out = sorted(o for o in out if o[0].startswith(prefix))
        return out[:limit], len(out) > limit

    def head(self, key, size=SAMPLE_BYTES):
        with open(os.path.join(self.root, *key.split("/")), "rb") as handle:
            data = handle.read(size + 1)
        return data[:size], len(data) > size


def store_for(connector_id, values, secret):
    fake = os.environ.get("EXAKIT_VS_FAKE_STORE")
    if fake:
        return LocalStore(fake, "container" if connector_id == "azure-blob" else "bucket")
    if connector_id == "s3":
        return S3(values, secret)
    if connector_id == "azure-blob":
        return Azure(values, secret)
    raise DraftError("%s has no mapping to draft" % connector_id)


def draft(store, folder, prefix=""):
    """{folder, tables: [{table, source, format, files, columns}], notes}: the
    mapping written to folder, one .json file per table. DraftError when
    nothing can be listed or nothing can be mapped."""
    objects, truncated = store.objects(prefix)
    groups, notes = group(objects)
    if truncated:
        notes.insert(0, "only the first %d objects were listed" % MAX_OBJECTS)
    if len(groups) > MAX_TABLES:
        notes.append("%d more folder%s not mapped (at most %d tables are drafted): %s"
                     % (len(groups) - MAX_TABLES, "" if len(groups) - MAX_TABLES == 1 else "s", MAX_TABLES,
                        ", ".join(g["source"] for g in groups[MAX_TABLES:MAX_TABLES + 5])
                        + (", ..." if len(groups) > MAX_TABLES + 5 else "")))
        groups = groups[:MAX_TABLES]
    docs, tables = [], []
    for entry in groups:
        fields = None
        if entry["format"] in ("json", "jsonl"):
            sample, problem = [], None
            for key in entry["keys"][:SAMPLE_FILES if entry["format"] == "json" else 3]:
                try:
                    data, cut = store.head(key)
                    sample += records(data, entry["format"], cut)
                except DraftError as error:
                    problem = "%s: %s" % (key, error)
                    if entry["format"] == "json" and "array" in str(error):
                        break
                if len(sample) >= SAMPLE_RECORDS:
                    break
            fields = infer(sample)
            if not fields:
                notes.append("%s not mapped: %s" % (entry["source"], problem or "no JSON object found in the sample"))
                continue
        docs.append((entry, edml(entry, fields)))
        tables.append({"table": entry["table"], "source": entry["source"], "format": FORMAT_NAMES[entry["format"]],
                       "files": len(entry["keys"]), "columns": len(fields) if fields else None,
                       "types": [[k, TYPE_NAMES[t]] for k, t in fields] if fields else []})
    if not tables:
        raise DraftError("the %s%s holds no .json, .jsonl, .csv or .parquet files the kit can map%s"
                         % (store.where, " folder %s" % prefix if prefix else "",
                            " (%s)" % "; ".join(notes) if notes else ""))
    os.makedirs(folder, exist_ok=True)
    try:
        os.chmod(folder, 0o700)
    except OSError:
        pass
    for name in os.listdir(folder):
        # An earlier draft's files: the new one replaces them, nothing else is touched.
        if name.endswith(".json") and os.path.isfile(os.path.join(folder, name)):
            os.remove(os.path.join(folder, name))
    for entry, doc in docs:
        with open(os.path.join(folder, entry["table"].lower() + ".json"), "w", encoding="utf-8") as handle:
            json.dump(doc, handle, indent=2)
            handle.write("\n")
    document.load_mappings(folder)       # what connect checks, checked now
    return {"folder": folder, "tables": tables, "notes": notes}


def summary_lines(result):
    """The draft as rows for a terminal: Table | Files (glob) | Format | Columns."""
    rows = [("Table", "Files (glob)", "Format", "Columns")]
    for t in result["tables"]:
        rows.append((t["table"], t["source"], t["format"],
                     str(t["columns"]) if t["columns"] is not None else "inferred by the adapter"))
    widths = [max(len(r[i]) for r in rows) for i in range(4)]
    return ["  ".join(cell.ljust(widths[i]) for i, cell in enumerate(row)).rstrip() for row in rows]
