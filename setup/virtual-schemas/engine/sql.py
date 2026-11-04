"""The database session: pyexasol as the kit's administrator, secrets redacted.

The administrator password is read from the file the manifest names
(runtime.password_file) and never leaves this process. A source credential
arrives on stdin and is written into the database only inside CREATE /
ALTER CONNECTION over the encrypted session; every error raised while it is
in play has it replaced by *** before anything prints or logs it.

Tests swap the backend: EXAKIT_VS_FAKE_DB names a Python file whose
`connect(**kwargs)` returns an object with query/execute/close.
"""

import importlib.util
import os
import re

MAX_ERROR = 600


class DbError(Exception):
    def __init__(self, message, kind="error"):
        super().__init__(message)
        self.kind = kind


# Ordered: the first match names the failure. Messages are the JDBC drivers'
# and Exasol's own; a generic failure stays "error" rather than guessing.
_KINDS = (
    ("nojava", r"No usable script language container"),
    # A driver naming a property its URL lacks (Simba: "Connection Refused:
    # ... Required Connection Key(s)") is configuration, not the network.
    ("error", r"Required Connection Key\(s\)"),
    # Unity Catalog through the lakehouse engine: a metastore or schema closed
    # to engines outside Databricks (it answers PERMISSION_DENIED, so this
    # comes before "denied"), and a catalog-managed table this engine cannot
    # read yet. Neither is a credential problem.
    ("external", r"EXTERNAL[ _]USE[ _]SCHEMA|External Data Access|EXTERNAL_ACCESS_DISABLED"),
    ("managed", r"catalog-managed table|Max catalog version is required"),
    # An Iceberg REST catalog or Unity Catalog without the namespace asked for.
    ("schema_missing", r"NoSuchNamespaceException|NoSuchWarehouseException|SCHEMA_DOES_NOT_EXIST|"
                       r"CATALOG_DOES_NOT_EXIST"),
    # Object stores answer over HTTPS with their own codes (S3 measured live):
    # a request signed by a clock too far off, a bucket in another region, a
    # key that may not list or read - each has its own fix, so each is named.
    ("clock", r"RequestTimeTooSkewed|difference between the request time and the current time is too large|"
              r"Signature not yet current|Signature expired|Request date header too (old|new)"),
    ("region", r"must be addressed using the specified endpoint|PermanentRedirect|"
               r"AuthorizationHeaderMalformed.*region|the region '[\w-]+' is wrong|"
               # object_store (the lakehouse engine) on S3's redirect to the bucket's region.
               r"incorrectly configured region|x-amz-bucket-region"),
    ("nobucket", r"NoSuchBucket|The specified bucket does not exist|ContainerNotFound"),
    ("denied", r"AccessDenied|not authorized to perform|AuthorizationPermissionMismatch|AuthorizationFailure|"
               r"PERMISSION_DENIED"),
    ("dns", r"UnknownHostException|Name or service not known|nodename nor servname|unable to resolve host"),
    ("tls", r"PKIX|certificate|SSLHandshake|SSL connection|ssl_server_dn_match|TLS|SSLException|"
            r"trustAnchors parameter must be non-empty"),
    ("auth", r"password authentication failed|Access denied for user|Login failed for user|ORA-01017|"
             r"Incorrect username or password|invalid username/password|authentication failed|"
             r"JWT token is invalid|Programmatic access token is invalid|token has expired|"
             r"signature we calculated does not match|InvalidAccessKeyId|Access Key Id you provided does not exist|"
             r"security token included in the request is (invalid|expired)|ExpiredToken|"
             r"Server failed to authenticate the request|AuthenticationFailed|"
             r"Error getting access token for service account|"
             # Databricks: the REST API (adapter) and the JDBC driver (loader).
             r"Invalid access token|REST API answered HTTP 401|"
             # An Iceberg REST catalog refusing the token or keys (the spec's error type).
             r"NotAuthorizedException"),
    ("unreachable", r"Connection refused|connect timed out|The connection attempt failed|"
                    r"Communications link failure|No route to host|Network is unreachable|"
                    r"Connection timed out|ORA-12541|ORA-12170|TCP/IP connection to the host|"
                    # The far end answered, but not as this database: a wrong
                    # port or a proxy that drops the protocol. Measured live.
                    r"ORA-17800|Got minus one from a read call|ORA-17002|IO Error: The Network Adapter|"
                    r"unexpected pre-login response|Broken pipe|EOFException"),
)


def classify(message):
    for kind, pattern in _KINDS:
        if re.search(pattern, message or "", re.I):
            return kind
    return "error"


def classify_raw(summary, raw):
    """The kind of a database error: from its one-line summary, else from its
    causes. An adapter can wrap the cause on a later line ("E-VSEXA-4: Unable
    to create ... reader" over "Caused by: ...authentication failed"), and
    the summary alone then reads as a generic failure. Only the cause lines
    are read - a whole stack names classes (SSL..., TLS...) that would
    misfile it."""
    kind = classify(summary)
    if kind not in ("error", "unreachable"):
        return kind
    causes = classify("\n".join(l for l in str(raw).splitlines() if "Caused by" in l or re.search(r"Exception: ", l)))
    if kind == "unreachable" and causes != "tls":
        return kind
    # MySQL's Connector/J reports a failed certificate check as
    # "Communications link failure" and names the SSLHandshakeException only
    # in a cause (measured on RDS MySQL 8.4): the server answered, so the
    # fix is the certificate, not the firewall.
    return causes


def ident(name):
    """A quoted identifier; the name is already validated, quotes doubled anyway."""
    return '"%s"' % str(name).replace('"', '""')


def literal(value):
    return "'%s'" % str(value).replace("'", "''")


def store_cause(text):
    """An object store's own answer under an adapter failure, as one line.

    Azure's SDK puts advice about logging the string to sign ahead of the
    answer; the store's code and message are in the XML body under it
    (measured: "Status code 403, "<?xml ...><Error><Code>..."). S3's SDK names
    its exception (measured: "software.amazon.awssdk...S3Exception: The
    request signature we calculated does not match ... (Service: S3, Status
    Code: 403, ...)").
    """
    body = re.search(r'Status code (\d+), "[^<]*<\?xml[^>]*\?>\s*<Error><Code>(\w+)</Code><Message>([^<\n]*)', text)
    if body:
        names = [n for n in re.findall(r"(?:[\w$]+\.)*([A-Z][\w$]*Exception): ", text[:body.start()])
                 if "ExaUDF" not in n]
        detail = re.search(r"<AuthenticationErrorDetail>([^<\n]{1,200})</AuthenticationErrorDetail>", text)
        return "%s%s: %s%s (HTTP %s)" % (names[-1] + ": " if names else "", body.group(2), body.group(3).strip(),
                                         " " + detail.group(1).strip() if detail else "", body.group(1))
    for line in text.splitlines():
        cause = re.match(r"\s*(?:Caused by: )?software\.amazon\.awssdk\.(?:[\w$]+\.)*([A-Z][\w$]*(?:Exception|Error)): (.+)$",
                         line)
        if cause:
            return _sdk_line(cause)
    return None


def rest_answer(line):
    """A Lua adapter's failed REST call as the API's own answer. Measured
    (Databricks 1.0.2): "E-VSDAB-5: HTTP request for URL '<url>' failed with
    status 403 ('HTTP/1.1 403 Forbidden') and body '{"error_code":403,
    "message":"Invalid access token. ..."}'" - the URL and JSON say less than
    the message inside them."""
    rest = re.match(r"(E-[A-Z]+-\d+): HTTP request for URL '[^']*' failed with status (\d+)\b.*?"
                    r'"message"\s*:\s*"((?:[^"\\]|\\.)*)"', line)
    if not rest:
        return None
    word = re.search(r'"error_code"\s*:\s*"([A-Z][A-Z_]*)"', line)
    return "%s: the REST API answered HTTP %s%s: %s" % (rest.group(1), rest.group(2),
                                                         " " + word.group(1) if word else "", rest.group(3))


def thrift_answer(cause):
    """The Databricks JDBC driver's HTTP failure as its code and message.
    Measured (3.4.3, a revoked token): "DatabricksSQLException: Error while
    receiving response from Thrift server. Request {TOpenSessionReq(...)},
    Error {Failed to flush data to server: HTTP request failed by code: 403,
    status line: ... Error message: Invalid access token. [ReqId: ...]}"."""
    found = re.search(r"HTTP request failed by code: (\d+).*?Error message: ([^}]+)", cause.group(2))
    if not found:
        return None
    return "%s: HTTP %s: %s" % (cause.group(1), found.group(1), found.group(2).strip())


def _sdk_line(cause):
    status = re.search(r"Status Code: (\d+)", cause.group(2))
    detail = re.sub(r"\s*\((?:Service|SDK Attempt)[^)]*\)", "", cause.group(2)).strip()
    return "%s: %s%s" % (cause.group(1).split("$")[0], detail, " (HTTP %s)" % status.group(1) if status else "")


def summarize(text):
    """One readable line out of Exasol's multi-line UDF error wrapper.

    An adapter failure arrives as "VM error: F-UDF-CL-... com.exasol..." with a
    Java stack under it; the line worth reading is the adapter's own coded
    message (E-VSPG-3: ... Caused by: '...'). A document adapter's coded line
    can be generic (E-VSD-102: Schema auto inference ... failed), so the
    store's own answer under it is added. Anything else keeps its first
    meaningful line.
    """
    text = str(text)
    coded = re.search(r"(E-[A-Z]+-\d+:[^\n]*)", text)
    store = store_cause(text)
    if coded:
        line = re.sub(r"\s*Known mitigations:\s*$", "", coded.group(1).strip())
        line = rest_answer(line) or line
        if store:
            line = "%s - caused by %s" % (line, store)
        return re.sub(r"\s+", " ", line).strip()
    if store:
        return re.sub(r"\s+", " ", store).strip()
    # Any other SDK under the UDF wrapper: its first exception line.
    for line in text.splitlines():
        cause = re.match(r"\s*(?:Caused by: )?(?:[\w$]+\.)*([A-Z][\w$]*(?:Exception|Error)): (.+)$", line)
        if cause and "ExaUDF" not in cause.group(1) and not cause.group(2).startswith("F-UDF"):
            return re.sub(r"\s+", " ", thrift_answer(cause) or _sdk_line(cause)).strip()
    # pyexasol's own wrapper: "(\n message => ...\n dsn => ...\n query => ...)".
    # The message field is the error; the fields under it describe the session.
    field = re.search(r"^\s*message\s*=>\s*(.+)$", text, re.M)
    if field:
        line = field.group(1)
    else:
        lines = [l.strip() for l in text.splitlines() if l.strip() and l.strip() not in ("(", ")")]
        line = next((l for l in lines if not l.startswith("message")), lines[0] if lines else text)
    return re.sub(r"\s+", " ", line).strip()


def redact(text, secrets):
    text = summarize(text)
    for secret in secrets:
        if secret:
            for form in (secret, secret.replace("'", "''")):
                text = text.replace(form, "***")
    text = re.sub(r"IDENTIFIED BY\s+'(?:[^']|'')*'", "IDENTIFIED BY '***'", text, flags=re.I)
    text = re.sub(r"\s*\(Session: \d+\)", "", text)
    return text[:MAX_ERROR]


class Database(object):
    def __init__(self, backend, log=None):
        self.backend = backend
        self.log = log or (lambda text: None)

    def query(self, sql_text, secrets=()):
        try:
            return self.backend.query(sql_text)
        except Exception as error:     # the driver's own exception types vary by backend
            message = redact(error, secrets)
            raise DbError(message, classify_raw(message, error))

    def execute(self, sql_text, secrets=()):
        try:
            self.backend.execute(sql_text)
        except Exception as error:
            message = redact(error, secrets)
            raise DbError(message, classify_raw(message, error))

    def close(self):
        try:
            self.backend.close()
        except Exception:
            pass


class _Pyexasol(object):
    def __init__(self, dsn, user, password):
        import pyexasol
        import ssl
        try:
            self.conn = pyexasol.connect(dsn=dsn, user=user, password=password, encryption=True,
                                         websocket_sslopt={"cert_reqs": ssl.CERT_NONE},
                                         fetch_dict=True, compression=False, debug=False)
        except Exception:
            # A deployment configured without TLS: the kit's own validation
            # (setup/lib/pyexasol.sh) falls back the same way.
            self.conn = pyexasol.connect(dsn=dsn, user=user, password=password, encryption=False,
                                         fetch_dict=True, debug=False)

    def query(self, sql_text):
        statement = self.conn.execute(sql_text)
        if statement.result_type != "resultSet":
            return []
        return [{str(k).upper(): v for k, v in row.items()} for row in statement.fetchall()]

    def execute(self, sql_text):
        self.conn.execute(sql_text)

    def close(self):
        self.conn.close()


def connect(dsn, user, password_file, log=None):
    fake = os.environ.get("EXAKIT_VS_FAKE_DB")
    if fake:
        spec = importlib.util.spec_from_file_location("exakit_vs_fake_db", fake)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return Database(module.connect(dsn=dsn, user=user), log)
    try:
        with open(password_file, encoding="utf-8") as handle:
            password = handle.read().strip()
    except OSError as error:
        raise DbError("the administrator password file could not be read: %s" % error, "error")
    try:
        backend = _Pyexasol(dsn, user, password)
    except ImportError:
        raise DbError("pyexasol is not installed in this Python (repair: exakit update pyexasol)", "error")
    except Exception as error:
        message = redact(error, [password])
        raise DbError("the database did not accept a connection: %s" % message, "unreachable")
    return Database(backend, log)
