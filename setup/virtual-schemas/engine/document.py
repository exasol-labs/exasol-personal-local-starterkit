"""Profile B (document files): the EDML mapping and the credential JSON.

A document source has no URL and no user: its CONNECTION holds a JSON
credential in IDENTIFIED BY, and its tables come from an EDML mapping - JSON
files the user writes, staged where the adapter reads them. Both are checked
here before anything reaches the database: the mapping for what would make the
virtual schema fail or collide, the credential for its shape, so a typo is
named on this computer instead of as a Java stack from inside the database.
"""

import datetime
import json
import os
import re
from urllib.parse import parse_qs, quote

EDML_SCHEMA = re.compile(r"^https://schemas\.exasol\.com/edml-\d+\.\d+\.\d+\.json$")
TABLE = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,127}$")
MAX_FILES = 50
MAX_BYTES = 1 << 20

KEY_ID = re.compile(r"^(AKIA|ASIA)[A-Z0-9]{16}$")

AZURE_ACCOUNT = re.compile(r"^[a-z0-9]{3,24}$")
AZURE_CONTAINER = re.compile(r"^(?!.*--)[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$")
AZURE_KEY = re.compile(r"^[A-Za-z0-9+/]{86}==$")
# Where a connection string begins, and the names a SAS token is made of.
AZURE_FIELDS = ("defaultendpointsprotocol", "accountname", "accountkey", "blobendpoint", "sharedaccesssignature",
                "endpointsuffix", "usedevelopmentstorage")
SAS_FIELD = re.compile(r"^\??(sv|ss|srt|sp|se|st|spr|sr|si|sig|skoid|sdd)=")


class DocumentError(Exception):
    pass


def mapping_files(path):
    """The mapping's files as [(file name, text)]: one .json file, or every
    .json file directly in a folder (sorted, so the staged copy is stable)."""
    path = os.path.abspath(os.path.expanduser(path))
    if os.path.isdir(path):
        names = sorted(n for n in os.listdir(path) if n.lower().endswith(".json")
                       and os.path.isfile(os.path.join(path, n)))
        if not names:
            raise DocumentError("mapping folder %s holds no .json files" % path)
        files = [os.path.join(path, n) for n in names]
    elif os.path.isfile(path):
        if not path.lower().endswith(".json"):
            raise DocumentError("mapping %s is not a .json file" % path)
        files = [path]
    else:
        raise DocumentError("mapping %s does not exist" % path)
    if len(files) > MAX_FILES:
        raise DocumentError("mapping %s has %d files; at most %d are staged" % (path, len(files), MAX_FILES))
    out = []
    for name in files:
        if os.path.getsize(name) > MAX_BYTES:
            raise DocumentError("mapping file %s is larger than 1 MiB" % name)
        with open(name, encoding="utf-8") as handle:
            out.append((os.path.basename(name), handle.read()))
    return out


def load_mappings(path):
    """[{file, table, source}] for a valid mapping; DocumentError names every problem."""
    try:
        files = mapping_files(path)
    except (OSError, UnicodeDecodeError) as error:
        raise DocumentError("mapping %s cannot be read: %s" % (path, error))
    problems, tables, seen = [], [], {}
    for name, text in files:
        try:
            doc = json.loads(text)
        except ValueError as error:
            problems.append("%s is not valid JSON (%s)" % (name, error))
            continue
        if not isinstance(doc, dict):
            problems.append("%s must hold one EDML object" % name)
            continue
        if not EDML_SCHEMA.match(str(doc.get("$schema", ""))):
            problems.append("%s needs \"$schema\": \"https://schemas.exasol.com/edml-2.1.0.json\"" % name)
        source = doc.get("source")
        if not isinstance(source, str) or not source.strip():
            problems.append("%s needs a \"source\": the object key or glob to read, e.g. data/orders/*.json" % name)
        elif "://" in source:
            problems.append("%s: \"source\" is the key inside the bucket, without s3:// or a host (got %s)"
                            % (name, source))
        table = doc.get("destinationTable")
        if not isinstance(table, str) or not TABLE.match(table):
            problems.append("%s needs a \"destinationTable\" that is a plain SQL name (letters, digits, _)" % name)
        elif table.upper() in seen:
            problems.append("%s and %s both map to table %s" % (seen[table.upper()], name, table.upper()))
        else:
            seen[table.upper()] = name
            tables.append({"file": name, "table": table.upper(), "source": source})
    if problems:
        raise DocumentError("; ".join(problems))
    return tables


def _first(doc, *keys):
    for key in keys:
        if doc.get(key):
            return str(doc[key]).strip()
    return ""


def credential(kind, values, secret, now=None):
    """(the CONNECTION's JSON, every string to redact, notes) for a document source."""
    if kind == "azure-blob":
        return _azure(values, secret.strip(), now or datetime.datetime.now(datetime.timezone.utc))
    if kind in ("lakehouse-rest", "lakehouse-unity"):
        return _catalog(kind, values, secret.strip())
    if kind not in ("s3", "lakehouse-glue"):
        raise DocumentError("unknown credential kind %s" % kind)
    key_id, secret_key, token, hidden = _aws_keys(values, secret)
    if kind == "s3":
        body = {"awsAccessKeyId": key_id, "awsSecretAccessKey": secret_key,
                "awsRegion": values["region"], "s3Bucket": values["bucket"]}
        token_field = "awsSessionToken"
    else:
        # lakehouse-engine-rs, CATALOG_KIND GLUE: one key pair signs Glue and S3.
        body = {"region": values["region"], "access_key": key_id, "secret_key": secret_key}
        token_field = "session_token"
    notes = []
    if token:
        body[token_field] = token
        notes.append("temporary credentials expire (usually within hours); when they do, give new ones with: "
                     "exakit source reauth <name> --password-file <file>")
    text = json.dumps(body)
    return text, [h for h in hidden + [text] if h], notes


def _catalog(kind, values, secret):
    """lakehouse-engine-rs over an Iceberg REST catalog (lakehouse-rest) or
    Unity Catalog (lakehouse-unity), next to the Glue body above. Either the
    storage's own keys (the catalog only names the files) or a catalog token,
    with which the catalog vends short-lived storage credentials per table.
    Unity's vended credentials carry no region, so its body always names one."""
    keyed = kind == "lakehouse-rest" and values.get("access_key_id")
    what = "secret key" if keyed else "token"
    if not secret or re.search(r"\s", secret):
        raise DocumentError("the %s is missing or has white space in it" % what)
    if secret.startswith("{"):
        raise DocumentError("give the %s itself, not JSON: the kit writes the connection's JSON" % what)
    notes = []
    if kind == "lakehouse-unity":
        body = {"token": secret, "use_vended_credentials": True, "region": values["region"]}
        notes.append("a Databricks personal access token stops working on the expiry date it was made with; "
                     "then give a new one with: exakit source reauth <name>")
    elif keyed:
        if not values.get("region"):
            raise DocumentError("region is required with an access key: the region of the bucket (an S3-compatible "
                                "store such as MinIO usually answers to us-east-1)")
        body = {"warehouse": values["warehouse"], "access_key": values["access_key_id"], "secret_key": secret,
                "region": values["region"]}
        if values.get("endpoint"):
            body.update(endpoint=values["endpoint"], path_style=True)
    else:
        if values.get("endpoint"):
            raise DocumentError("a storage endpoint goes with an access key (--set access_key_id=...); with a "
                                "catalog token the catalog names its storage")
        body = {"warehouse": values["warehouse"], "token": secret, "use_vended_credentials": True}
        if values.get("region"):
            body["region"] = values["region"]
    text = json.dumps(body)
    return text, [secret, text], notes


def _aws_keys(values, secret):
    """(key id, secret key, session token, strings to redact) from a typed
    secret key plus --set access_key_id, or from a credential file."""
    key_id, secret_key, token = values.get("access_key_id", ""), secret, ""
    try:
        doc = json.loads(secret)
    except ValueError:
        doc = None
    if isinstance(doc, dict):
        # What `aws iam create-access-key` prints (AccessKey: {...}), what
        # `aws sts ...` prints (Credentials: {...}), either unwrapped, or the
        # adapter's own field names.
        inner = doc.get("AccessKey") or doc.get("Credentials") or doc
        file_id = _first(inner, "awsAccessKeyId", "AccessKeyId")
        secret_key = _first(inner, "awsSecretAccessKey", "SecretAccessKey")
        token = _first(inner, "awsSessionToken", "SessionToken")
        if key_id and file_id and key_id != file_id:
            raise DocumentError("access_key_id does not match the key in the credential file; give one of them")
        key_id = key_id or file_id
    hidden = [secret, secret_key, token]
    if not key_id:
        raise DocumentError("no access key ID: give --set access_key_id=AKIA... with the secret key, or a "
                            "credential file that holds both")
    if not KEY_ID.match(key_id):
        raise DocumentError("the access key ID must look like AKIA... or ASIA... (20 characters)")
    if not secret_key or len(secret_key) < 30 or re.search(r"\s", secret_key):
        raise DocumentError("the secret access key is missing or malformed")
    if key_id.startswith("ASIA") and not token:
        raise DocumentError("ASIA... keys are temporary and need their session token: give the whole JSON from "
                            "aws sts (with SessionToken) through --password-file")
    return key_id, secret_key, token, hidden


def _sas_time(raw):
    for form in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%MZ", "%Y-%m-%d"):
        try:
            return datetime.datetime.strptime(re.sub(r"\.\d+Z$", "Z", raw), form).replace(tzinfo=datetime.timezone.utc)
        except ValueError:
            continue
    raise DocumentError("the SAS time %s is not a date the kit can read" % raw)


def _sas(token, now):
    """Notes for a SAS that can list and read a container; DocumentError for one that cannot."""
    fields = {k: v[0] for k, v in parse_qs(token, keep_blank_values=True).items()}
    if not fields.get("sig"):
        raise DocumentError("the SAS token has no signature (sig=...): give the whole token")
    perms = fields.get("sp", "")
    missing = [name for flag, name in (("r", "read (r)"), ("l", "list (l)")) if flag not in perms]
    if missing and not fields.get("si"):
        raise DocumentError("the SAS lacks %s permission: the adapter lists the container, then reads the files"
                            % " and ".join(missing))
    if fields.get("sr") and fields["sr"] != "c":
        raise DocumentError("the SAS is for a single blob or directory (sr=%s); it needs to cover the container (sr=c)"
                            % fields["sr"])
    if fields.get("srt") and not ("c" in fields["srt"] and "o" in fields["srt"]):
        raise DocumentError("the account SAS needs the container and object resource types (srt=co)")
    if fields.get("ss") and "b" not in fields["ss"]:
        raise DocumentError("the account SAS does not include the blob service (ss needs b)")
    if fields.get("spr") == "http":
        raise DocumentError("the SAS allows only HTTP; the kit reads over HTTPS")
    notes = []
    if fields.get("st") and _sas_time(fields["st"]) > now:
        raise DocumentError("the SAS is not valid before %s" % fields["st"])
    if fields.get("se"):
        expires = _sas_time(fields["se"])
        if expires <= now:
            raise DocumentError("the SAS expired at %s: generate a new one" % fields["se"])
        notes.append("this SAS expires at %s; then give a new one with: exakit source reauth <name> "
                     "--password-file <file>" % expires.strftime("%Y-%m-%d %H:%M UTC"))
    return notes


def _azure(values, text, now):
    account, container = values["account"], values["container"]
    endpoint = "https://%s.blob.core.windows.net/" % account
    key = sas = None
    if text.startswith("{"):
        # The adapter's own IDENTIFIED BY body, as its user guide writes it.
        try:
            doc = json.loads(text)
        except ValueError as error:
            raise DocumentError("the credential file is not valid JSON (%s)" % error)
        if not isinstance(doc, dict) or not isinstance(doc.get("absStorageAccountConnectionString"), str):
            raise DocumentError("a JSON credential needs absStorageAccountConnectionString")
        if doc.get("absContainerName") not in (None, container):
            raise DocumentError("the credential file names container %s, not %s" % (doc["absContainerName"], container))
        inner = doc["absStorageAccountConnectionString"].strip()
        body, hidden, notes = _azure(values, inner, now)
        return body, [text] + hidden, notes
    first = text.split("=", 1)[0].strip().lower()
    if first in AZURE_FIELDS:
        parts = {}
        for item in filter(None, (p.strip() for p in text.split(";"))):
            name, sep, value = item.partition("=")
            name = name.strip().lower()
            if not sep or name not in AZURE_FIELDS + ("queueendpoint", "tableendpoint", "fileendpoint"):
                raise DocumentError("the connection string has a part the kit does not know: %s"
                                    % (name or "an empty name"))
            parts[name] = value.strip()
        if parts.get("usedevelopmentstorage"):
            raise DocumentError("a development-storage (Azurite) connection string is not reached from the database")
        if parts.get("defaultendpointsprotocol", "https").lower() != "https":
            raise DocumentError("the connection string uses %s; the kit reads only over HTTPS"
                                % parts["defaultendpointsprotocol"])
        if parts.get("endpointsuffix", "core.windows.net").lower() != "core.windows.net":
            raise DocumentError("endpoint suffix %s is a sovereign cloud, which this connector does not reach"
                                % parts["endpointsuffix"])
        if parts.get("accountname") and parts["accountname"] != account:
            raise DocumentError("the connection string is for account %s, not %s" % (parts["accountname"], account))
        if parts.get("blobendpoint") and parts["blobendpoint"].rstrip("/").lower() != endpoint.rstrip("/"):
            raise DocumentError("the blob endpoint must be %s (custom domains and other clouds are not reached)"
                                % endpoint)
        key, sas = parts.get("accountkey"), parts.get("sharedaccesssignature")
        if key and sas:
            raise DocumentError("the connection string holds both an account key and a SAS; give one of them")
        if not key and not sas:
            raise DocumentError("the connection string holds neither AccountKey nor SharedAccessSignature")
    elif SAS_FIELD.match(text):
        sas = text
    elif AZURE_KEY.match(text):
        key = text
    else:
        raise DocumentError("the credential must be the storage account's connection string, a SAS token "
                            "(sv=...&sig=...) or the account key")
    if key:
        if not AZURE_KEY.match(key):
            raise DocumentError("the account key is malformed (88 base64 characters ending in ==)")
        conn = "DefaultEndpointsProtocol=https;AccountName=%s;AccountKey=%s;EndpointSuffix=core.windows.net" % (
            account, key)
        notes = ["an account key opens every container of %s, for writing too; a SAS limited to container %s with "
                 "read and list permissions and an expiry is the narrower credential" % (account, container)]
    else:
        sas = sas.lstrip("?")
        notes = _sas(sas, now)
        conn = "BlobEndpoint=%s;SharedAccessSignature=%s" % (endpoint, sas)
    body = json.dumps({"absStorageAccountConnectionString": conn, "absContainerName": container})
    # The signature alone too, in either encoding: an SDK message can quote it.
    sig = parse_qs(sas or "").get("sig", [""])[0]
    hidden = [text, key, sas, conn, body, sig, quote(sig, safe="")]
    return body, [h for h in hidden if h], notes
