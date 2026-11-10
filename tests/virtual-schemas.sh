#!/usr/bin/env bash
# The virtual schema engine (setup/virtual-schemas/engine) against a simulated
# Exasol (tests/lib/fake-exasol-vs.py) and a fake Personal deployment folder.
#
# The invariants worth a suite:
#   1. A secret travels on stdin into CREATE/ALTER CONNECTION and nowhere else:
#      not into argv, the source records, the registry, the output or errors.
#   2. A failed connect leaves nothing it created - objects or files - and
#      never touches what another source uses or what the kit did not make.
#   3. Shared files are reference-counted: removing one source keeps what
#      another still needs, and the last one out cleans up - without ever
#      removing a bucket the kit did not create.
#   4. disconnect drops only the CONNECTION; remove drops the owned objects.
#   5. Failures are classified (auth, tls, unreachable, dns, no Java) with an
#      exit code or status the shell and `exakit source issues` act on.
#   6. Every input is validated before it reaches a template.
#
#   bash tests/virtual-schemas.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1"; printf '         expected: %s\n         actual:   %.400s\n' "$2" "$3"; fi; }
has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1"; printf '         missing: %s\n         in: %.400s\n' "$2" "$3" ;; esac; }
lacks() { case "$3" in *"$2"*) fail "$1"; printf '         unexpected: %s\n' "$2" ;; *) pass "$1" ;; esac; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
DEFS="$WORK/defs"; HOME_K="$WORK/kit"; DEPLOY="$WORK/deploy"; EXA="$DEPLOY/local/runtime/exa"
cp -R "$ROOT/setup/virtual-schemas" "$DEFS"
mkdir -p "$HOME_K" "$EXA/bucketfs/bfsdefault/default" "$EXA/jdbc"
printf 'kept\n' > "$EXA/jdbc/java.security"
SECRET='s3cr3t-Pa55'"'"'word'
NEWSECRET='n3w-T0ken-value'
# Offline: a plan or connect of a source on the internet would ask
# checkip.amazonaws.com for this computer's public IP. The tests of that turn
# the lookup back on against a file:// URL (ipeng, and the two terminal flows).
export EXAKIT_NO_IP_LOOKUP=1
# The engine falls back to this when nothing is recorded (plan.py); a value
# left in the caller's environment must not decide the cases below.
unset EXAKIT_PERSONAL_ENGINE
printf '203.0.113.7\n' > "$WORK/public-ip"
IPURL="file://$WORK/public-ip"

# Small stand-in artifacts with real digests, pinned into the copied
# definitions and placed in the cache, so nothing is downloaded.
python3 - "$DEFS" "$HOME_K" <<'PY'
import hashlib, io, json, os, sys, tarfile, zipfile
defs, home = sys.argv[1:3]
def seed(pin, data):
    pin["size"], pin["sha256"] = len(data), hashlib.sha256(data).hexdigest()
    folder = os.path.join(home, "cache", "virtual-schemas", pin["sha256"])
    os.makedirs(folder, exist_ok=True)
    open(os.path.join(folder, pin["asset"]), "wb").write(data)
def targz(member, data):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as archive:
        info = tarfile.TarInfo(member); info.size = len(data)
        archive.addfile(info, io.BytesIO(data))
    return buf.getvalue()
for cid in ("postgresql", "mysql", "sqlserver", "oracle", "snowflake", "bigquery", "s3", "azure-blob", "mongodb",
            "databricks", "lakehouse", "iceberg-rest", "unity"):
    path = os.path.join(defs, "connectors", cid, "connector.json")
    doc = json.load(open(path))
    if "arch" in doc["adapter"]:
        for arch, pin in doc["adapter"]["arch"].items():
            # One family (lakehouse, iceberg-rest, unity) pins one engine: the same bytes.
            data = ("adapter-%s-%s" % (doc.get("family", cid), arch)).encode()
            if doc["adapter"].get("bundle") == "tar.gz":
                # A release archive: the pinned member inside it is pinned too.
                pin["member_size"], pin["member_sha256"] = len(data), hashlib.sha256(data).hexdigest()
                data = targz(doc["adapter"]["member"], data)
            seed(pin, data)
    else:
        seed(doc["adapter"], ("adapter-" + cid).encode())
    if doc.get("trust"):
        # A CA bundle as curl ships it: comments (UTF-8 names) around PEM blocks.
        seed(doc["trust"], ("## Bundle of CA Root Certificates\n\nNetLock Arany F\u0151tan\u00fas\u00edtv\u00e1ny\n"
                            "=====\n-----BEGIN CERTIFICATE-----\nQUJDRA==\n-----END CERTIFICATE-----\n\nSecond\n=====\n"
                            "-----BEGIN CERTIFICATE-----\nRUZHSA==\n-----END CERTIFICATE-----\n").encode("utf-8"))
    if not doc.get("driver"):
        pass
    elif doc["driver"].get("bundle") == "zip":
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            z.writestr("GoogleBigQueryJDBC42.jar", b"a"); z.writestr("dep.jar", b"b"); z.writestr("EULA.txt", b"c")
        seed(doc["driver"], buf.getvalue())
    else:
        seed(doc["driver"], ("driver-" + cid).encode())
    json.dump(doc, open(path, "w"), indent=2)
PY

STATE="$WORK/db.json"
db() { printf '%s\n' "$1" > "$STATE"; }
dbq() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); v=eval(sys.argv[2], {"d": d}); print(json.dumps(v) if not isinstance(v, str) else v)' "$STATE" "$1"; }
eng() {
    EXAKIT_VS_FAKE_DB="$ROOT/tests/lib/fake-exasol-vs.py" FAKE_VS_STATE="$STATE" FAKE_VS_EXA="$EXA" \
        EXAKIT_VS_SETTLE_SECONDS="${SETTLE_SECONDS:-0}" EXAKIT_VS_VISIBLE_TIMEOUT="${VISIBLE_TIMEOUT:-20}" \
        python3 "$ROOT/setup/virtual-schemas/engine/cli.py" --defs "$DEFS" --kit-home "$HOME_K" \
        --deployment-dir "$DEPLOY" --dsn 127.0.0.1:8563 --user sys --password-file /nonexistent "$@"
}
run() { OUT="$(eng "$@" 2>&1)"; RC=$?; }
run_secret() { local s="$1"; shift; OUT="$(printf '%s' "$s" | eng "$@" 2>&1)"; RC=$?; }
# What a reauth trial leaves in the database: nothing, once it is over.
pending() { dbq '[c for c in d["connections"] if c.startswith("EXAKIT_PENDING_")] + [v for v in d["virtual"] if v.startswith("EXAKIT_PENDING_")]'; }
PG_SET="--set host=pg.example.com --set database=sales --set user=reader"

printf '\n== search and plan ==\n'
run resolve mssql; has "an alias resolves" '"connector": "sqlserver"' "$OUT"
run resolve sql; check "an ambiguous search is refused, exit 2" "2" "$RC"; has "...with the choices" "choices: postgresql, mysql, sqlserver" "$OUT"
db '{}'
run plan pg --name sales $PG_SET
check "plan: exit 0" "0" "$RC"
has "...names the objects" '"connection": "EXAKIT_SRC_SALES"' "$OUT"
has "...states the MCP exposure" "MCP read-only user can read every table of VS_SALES" "$OUT"
check "...and changes nothing" "[]" "$(dbq 'd.get("statements", [])')"

printf '\n== input validation ==\n'
for bad in "--set host=pg.example.com;DROP --set database=x --set user=u" "--set host=h --set port=70000 --set database=x --set user=u" \
           "--set host=h --set database=x --set user=u --set colour=red" "--set host=h --set database=x' --set user=u" \
           "--set host=h --set database=x --set user=u --set tls=sometimes"; do
    # shellcheck disable=SC2086
    run plan postgresql --name bad $bad
    check "refused with exit 2: $bad" "2" "$RC"
done
run plan postgresql --name Bad-Name $PG_SET; check "a source name outside [a-z][a-z0-9_] is refused" "2" "$RC"
for loop in localhost 127.0.0.1 ::1 LOCALHOST; do
    run plan postgresql --name sales --set host=$loop --set database=x --set user=u
    check "host=$loop is refused (it is the database itself)" "2" "$RC"
done
has "...with the address to use instead" "on macOS 192.168.64.1, on Linux and WSL host.containers.internal" "$OUT"
# Where this computer is follows the deployment's engine, read from the kit's
# record (runtime.engine, kit 0.2.4+): Docker has no host.containers.internal.
# Linux, WSL or Windows only: on macOS the database is in the launcher VM's
# Podman whatever the record says (EXAKIT_VS_OS stands in for the platform).
DOCKER_HOST_WORDS="on Docker host.docker.internal where the deployment provides it, else the bridge gateway"
export EXAKIT_VS_OS=Linux
printf '{"runtime": {"type": "personal", "engine": "docker"}}\n' > "$HOME_K/manifest.json"
run plan postgresql --name sales --set host=localhost --set database=x --set user=u
check "a Docker deployment: localhost is still refused, exit 2" "2" "$RC"
has "...with Docker's address for this computer" "$DOCKER_HOST_WORDS" "$OUT"
lacks "...not Podman's" "host.containers.internal" "$OUT"
run plan iceberg-rest --name rest1 --set catalog_url=http://localhost:8181 --set warehouse=w --set namespace=sales
has "...the same for a catalog URL on localhost" "$DOCKER_HOST_WORDS" "$OUT"
run plan iceberg-rest --name rest1 --set catalog_url=http://rest.example.com --set warehouse=w --set namespace=sales
has "...and in the plain-http refusal" "accepted only for this computer ($DOCKER_HOST_WORDS) or a private network" "$OUT"
printf '{"runtime": {"type": "personal", "engine": "podman"}}\n' > "$HOME_K/manifest.json"
run plan postgresql --name sales --set host=localhost --set database=x --set user=u
has "a Podman deployment: Podman's name" "on macOS 192.168.64.1, on Linux and WSL host.containers.internal" "$OUT"
printf '{"runtime": {"engine": "docker", "container": "exasol-nano"}}\n' > "$HOME_K/manifest.json"
run plan postgresql --name sales --set host=localhost --set database=x --set user=u
has "a nano record's engine (the OLD database's) is not this deployment's" "host.containers.internal" "$OUT"
printf '{"runtime": {"engine": "docker", "container": null}}\n' > "$HOME_K/manifest.json"
run plan postgresql --name sales --set host=localhost --set database=x --set user=u
has "...runtime.container null is a nano record too, as the shell reads it" "host.containers.internal" "$OUT"
printf '{"runtime": {"engine": "docker", "container": ""}}\n' > "$HOME_K/manifest.json"
run plan postgresql --name sales --set host=localhost --set database=x --set user=u
has "...an empty runtime.container is none: Docker's address" "$DOCKER_HOST_WORDS" "$OUT"
printf '{"runtime": {"type": "personal", "engine": "docker"}}\n' > "$HOME_K/manifest.json"
EXAKIT_VS_OS=Darwin run plan postgresql --name sales --set host=localhost --set database=x --set user=u
has "macOS: the launcher VM's address whatever the record says" "on macOS 192.168.64.1, on Linux and WSL host.containers.internal" "$OUT"
lacks "...never Docker's there" "host.docker.internal" "$OUT"
printf '{"runtime": {"type": "personal"}}\n' > "$HOME_K/manifest.json"
run plan postgresql --name sales --set host=localhost --set database=x --set user=u
has "no engine recorded (before kit 0.2.4): as before" "on macOS 192.168.64.1, on Linux and WSL host.containers.internal" "$OUT"
# Then this run's choice, as the shells' personal_slc_dns_engine reads it:
# the record first, the run's EXAKIT_PERSONAL_ENGINE next, Podman last.
EXAKIT_PERSONAL_ENGINE=docker run plan postgresql --name sales --set host=localhost --set database=x --set user=u
has "...nothing recorded, this run chose Docker: Docker's address" "$DOCKER_HOST_WORDS" "$OUT"
printf '{"runtime": {"type": "personal", "engine": "podman"}}\n' > "$HOME_K/manifest.json"
EXAKIT_PERSONAL_ENGINE=docker run plan postgresql --name sales --set host=localhost --set database=x --set user=u
has "...the record beats this run's choice" "on Linux and WSL host.containers.internal" "$OUT"
printf '{"runtime": {"engine": "podman", "container": "exasol-nano"}}\n' > "$HOME_K/manifest.json"
EXAKIT_PERSONAL_ENGINE=docker run plan postgresql --name sales --set host=localhost --set database=x --set user=u
has "...a nano record is none: this run's choice" "$DOCKER_HOST_WORDS" "$OUT"
# The bridge hands the engine the shell's own value, exported or not.
rm -f "$HOME_K/manifest.json"
OUT="$( ( EXAKIT_HOME="$HOME_K"
    . "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/virtual-schemas.sh"
    exakit_vs_defs() { printf '%s' "$ROOT/setup/virtual-schemas"; }
    _exakit_vs_kit_python() { command -v python3; }
    manifest_get() { return 1; }
    unset EXAKIT_PERSONAL_ENGINE; EXAKIT_PERSONAL_ENGINE=docker
    exakit_vs_engine plan postgresql --name sales --set host=localhost --set database=x --set user=u ) 2>&1 )"
has "...the bridge passes the run's choice on, set in the shell and not exported" "$DOCKER_HOST_WORDS" "$OUT"
rm -f "$HOME_K/manifest.json"
unset EXAKIT_VS_OS
V6="$(python3 - "$ROOT" <<'PYV6'
import sys; sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import plan
c = plan.Definitions(sys.argv[1] + "/setup/virtual-schemas").connector("postgresql")
for given in ("2001:db8::1", "[2001:db8::1]"):
    v = plan.validate_inputs(c, {"host": given, "database": "d", "user": "u"})
    print(plan.jdbc_url(c, v).split("?")[0])
PYV6
)"
check "an IPv6 host is bracketed in the URL, written either way" \
    "jdbc:postgresql://[2001:db8::1]:5432/d|jdbc:postgresql://[2001:db8::1]:5432/d|" "$(printf '%s\n' "$V6" | tr '\n' '|')"

run plan postgresql --name sales --set host=h --set user=u; has "a missing required input is named" "database is required" "$OUT"

printf '\n== every connector, every TLS mode: the templates build ==\n'
TEMPLATES="$(python3 - "$ROOT" <<'PYT'
import sys; sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import plan
defs = plan.Definitions(sys.argv[1] + "/setup/virtual-schemas")
samples = {"host": "db.example.com", "database": "sales", "schema": "public", "user": "reader", "service": "ORCLPDB1",
           "account": "myorg-acct1", "warehouse": "COMPUTE_WH", "project": "my-proj", "dataset": "analytics",
           "http_path": "/sql/1.0/warehouses/abc123def456ghi7", "catalog": "main"}
for entry in defs.entries():
    c = defs.connector(entry["id"])
    if c.get("credential") or c.get("shared_adapter"):
        continue    # document and native sources have no JDBC URL or probe host (their own sections below)
    given = {s["name"]: samples[s["name"]] for s in c["inputs"] if s["name"] in samples}
    tls = next((s for s in c["inputs"] if s["name"] == "tls"), None)
    for mode in (tls["choices"] if tls else [None]):
        g = dict(given, **({"tls": mode} if mode else {}))
        try:
            v = plan.validate_inputs(c, g)
            url = plan.jdbc_url(c, v, {"key_path": "/buckets/x/key.json", "sa_email": "r@p.iam.gserviceaccount.com"})
            [t.format(**v) for t in c["vs_properties"].values()]
            ok = url.startswith("jdbc:") and "{" not in url and plan.source_host(c, v)
            print("%s/%s %s" % (c["id"], mode or "-", "ok" if ok else "BAD " + url))
        except Exception as e:
            print("%s/%s BAD %s" % (c["id"], mode or "-", e))
PYT
)"
check "14 connector/TLS combinations build a URL, properties and a probe host" "14 0" \
    "$(printf '%s\n' "$TEMPLATES" | grep -c ' ok$') $(printf '%s\n' "$TEMPLATES" | grep -c ' BAD')"

printf '\n== failure classes, from real driver messages ==\n'
CLASSES="$(python3 - "$ROOT" <<'PYC'
import sys; sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import sql
for text in [
    "E-VSPG-3: Unable to create PostgreSQL remote metadata reader. Caused by: 'The connection attempt failed.'",
    "E-VSMYSQL-1: Unable to create MySQL remote metadata reader. Caused by: Communications link failure",
    "E-VSSQLS-2: ... The TCP/IP connection to the host 192.168.64.1, port 55432 has failed. Error: \"The driver received an unexpected pre-login response.",
    "E-VSORA-1: Unable to create Oracle remote metadata reader. Caused by: ORA-17800: Got minus one from a read call.",
    'FATAL: password authentication failed for user "reader"',
    "ORA-01017: invalid username/password; logon denied",
    "PKIX path building failed: unable to find valid certification path to requested target",
    "No usable script language container is installed for the requested language.",
    "java.net.UnknownHostException: db.example.com",
    # Measured live on a fresh Exasol Personal 2.4 (VM and Docker):
    # SCRIPT_LANGUAGES names JAVA=builtin_java, and its client is not there.
    "VM error: The required executable '/exaudf/exaudfclient' does not exist in BucketFS",
    # Another file missing from BucketFS is not a missing Java - not even one
    # whose name starts like the client does (no apostrophe here: bash 3.2
    # reads quotes inside a heredoc in a command substitution).
    "The required executable '/buckets/bfsdefault/default/drivers/tool' does not exist in BucketFS",
    "The required executable '/exaudf/exaudfclient_py3' does not exist in BucketFS",
    "The required executable '/exaudf/exaudfclient.sh' does not exist in BucketFS",
]:
    print(sql.classify(text))
PYC
)"
check "each real message lands in its class" "unreachable|unreachable|unreachable|unreachable|auth|auth|tls|nojava|dns|nojava|error|error|error|" \
    "$(printf '%s\n' "$CLASSES" | tr '\n' '|')"
# The 2.4 words on a line under the summary - a wrapper's first line, or past
# the cut to MAX_ERROR - are still a missing Java, never a generic failure.
RAW_NOJAVA='Query execution failed: Protocol error: VM error: F-UDF-CL-LIB-1127: the script could not be started
The required executable '"'"'/exaudf/exaudfclient'"'"' does not exist in BucketFS'
check "the 2.4 message under the summary line: nojava" "nojava" \
    "$(python3 - "$ROOT" "$RAW_NOJAVA" <<'PYC'
import sys; sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import sql
raw = sys.argv[2]
print(sql.classify_raw(sql.summarize(raw), raw))
PYC
)"
# Measured live: a rotated source password. The summary line is the
# adapter's generic "Unable to create ... reader"; the cause is lines below.
RAW_AUTH='Query execution failed: Protocol error: VM error: F-UDF-CL-LIB-1126: F-UDF-CL-SL-JAVA-1006:
com.exasol.adapter.jdbc.RemoteMetadataReaderException: E-VSEXA-4: Unable to create Exasol remote metadata reader.
	at com.exasol.adapter.dialects.exasol.ExasolSqlDialect.createRemoteMetadataReader(ExasolSqlDialect.java:212)
	at com.exasol.ssl.TlsHelper.wrap(TlsHelper.java:9)
Caused by: java.sql.SQLInvalidAuthorizationSpecException: Connection exception - authentication failed.'
# Measured live: pyexasol's wrapper around a loader error, as a reauth try
# raises it. The line under "message =>" is the session's dsn, not the error.
RAW_ETL="$(printf '\n(\n    message     =>  JDBC-Client-Error: Connecting to %s as user=%s failed: Connection exception - authentication failed. (Session: 1880237644681707520)\n    dsn         =>  127.0.0.1:8563\n    user        =>  sys\n    code        =>  ETL-5\n    query       =>  SELECT 1\n)\n' "'jdbc:exa:10.0.0.9:8563'" "'READER'")"
check "a pyexasol error is summarized by its message field, and classifies" \
    "JDBC-Client-Error: Connecting to 'jdbc:exa:10.0.0.9:8563' as user='READER' failed: Connection exception - authentication failed. auth" \
    "$(python3 - "$ROOT" "$RAW_ETL" <<'PYC'
import sys; sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import sql
line = sql.redact(sys.argv[2], [])
print(line, sql.classify_raw(line, sys.argv[2]))
PYC
)"
check "a cause on a later line still classifies (auth), not the generic summary" "auth" \
    "$(python3 - "$ROOT" "$RAW_AUTH" <<'PYC'
import sys; sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import sql
raw = sys.argv[2]
print(sql.classify_raw(sql.summarize(raw), raw))
PYC
)"
# Measured live on RDS MySQL 8.4: Connector/J wraps a failed certificate
# check in "Communications link failure", and the kit had sent the user to
# check the firewall of a server its own route check had just reached.
RAW_MY_TLS='com.exasol.adapter.jdbc.RemoteMetadataReaderException: E-VSMYSQL-1: Unable to create MySQL remote metadata reader. Caused by: Communications link failure
Caused by: com.mysql.cj.jdbc.exceptions.CommunicationsException: Communications link failure
Caused by: com.mysql.cj.exceptions.CJCommunicationsException: Communications link failure
Caused by: javax.net.ssl.SSLHandshakeException: (certificate_unknown) java.security.cert.CertPathValidatorException: Path does not chain with any of the trust anchors'
RAW_MY_DOWN='com.exasol.adapter.jdbc.RemoteMetadataReaderException: E-VSMYSQL-1: Unable to create MySQL remote metadata reader. Caused by: Communications link failure
Caused by: com.mysql.cj.jdbc.exceptions.CommunicationsException: Communications link failure
Caused by: java.net.ConnectException: Connection refused'
check "MySQL's 'Communications link failure' over a certificate cause is tls; over a refused connect, unreachable" "tls unreachable" \
    "$(python3 - "$ROOT" "$RAW_MY_TLS" "$RAW_MY_DOWN" <<'PYC'
import sys; sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import sql
print(" ".join(sql.classify_raw(sql.summarize(raw), raw) for raw in sys.argv[2:4]))
PYC
)"
# An account that signs in but may not read is told what to grant: the
# connector's "access", the least it needs at the source. A connector without
# one falls back to the bare words "read access", which name no grant. Read
# from the catalog, so a new connector is checked the moment it lands.
check "every connector names the rights it needs at the source, and the denied, privilege and missing_or_denied fixes say them" "ok" \
    "$(python3 - "$ROOT" <<'PYC'
import json, os, sys
sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import lifecycle
root = os.path.join(sys.argv[1], "setup", "virtual-schemas")
for entry in json.load(open(os.path.join(root, "catalog.json")))["connectors"]:
    doc = json.load(open(os.path.join(root, "connectors", entry["id"], "connector.json")))
    access = doc.get("access", "").strip()
    if not access or "(%s)" % access not in lifecycle.remedy_for("denied", "src", doc) \
            or "(%s)" % access not in lifecycle.remedy_for("privilege", "src", doc) \
            or "(grant it %s)" % access not in lifecycle.remedy_for("missing_or_denied", "src", doc):
        print("bad: " + entry["id"]); break
else:
    print("ok")
PYC
)"
# A database refusing a statement for a missing grant, in each driver's own
# words, as they arrive: pyexasol's wrapper around Exasol's IMPORT error
# ("JDBC-Client-Error: Failed to receive MetaData for the given statement:"),
# the driver's text inside it - Snowflake's on a second line, which pyexasol
# prints bare. Each is "privilege": the remedy names that connector's access,
# and no public IP, since a database answers it after the address was let in.
GRANTS="$(python3 - "$ROOT" <<'PYC'
import json, os, sys
sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import lifecycle, sql
load = lambda c: json.load(open(os.path.join(sys.argv[1], "setup/virtual-schemas/connectors", c, "connector.json")))
IMPORT = "JDBC-Client-Error: Failed to receive MetaData for the given statement: "
for cid, words in [
    ("postgresql", IMPORT + "ERROR: permission denied for table orders"),
    ("postgresql", IMPORT + 'FATAL: permission denied for database "sales"\n  Detail: User does not have CONNECT privilege.'),
    ("mysql", IMPORT + "SELECT command denied to user 'reader'@'203.0.113.7' for table 'orders'"),
    ("sqlserver", IMPORT + "The SELECT permission was denied on the object 'orders', database 'sales', schema 'dbo'."),
    ("oracle", IMPORT + "ORA-01031: insufficient privileges\nhttps://docs.oracle.com/error-help/db/ora-01031/"),
    ("oracle", IMPORT + 'ORA-41900: missing READ privilege on "SALES"."ORDERS"'),
    ("snowflake", IMPORT + "SQL access control error:\nInsufficient privileges to operate on schema 'PUBLIC'"),
    ("mongodb", "VM error: F-UDF-CL-RUST-9001: UDF error: Command failed: Error code 13 (Unauthorized): not authorized "
                'on sales to execute command { find: "orders", $db: "sales" }'),
]:
    raw = ("\n(\n    message     =>  %s (Session: 1880237644681707520)\n    dsn         =>  127.0.0.1:8563\n"
           "    user        =>  sys\n    code        =>  ETL-5\n)\n" % words)
    line = sql.redact(raw, [])
    kind = sql.classify_raw(line, raw)
    doc = load(cid)
    remedy = lifecycle.remedy_for(kind, "src", doc, line)
    print("%s %s %s %s %s" % (cid, kind, lifecycle.STATUS_FOR[kind],
                              "access" if "(%s)" % doc["access"] in remedy else "NO-ACCESS: " + remedy,
                              "no-ip" if lifecycle.allow_ip(remedy, kind, "203.0.113.7") == remedy else "IP"))
PYC
)"
check "a missing grant, in each driver's words, is privilege: access-denied, the connector's access named, no IP" \
    "postgresql privilege access-denied access no-ip|postgresql privilege access-denied access no-ip|mysql privilege access-denied access no-ip|sqlserver privilege access-denied access no-ip|oracle privilege access-denied access no-ip|oracle privilege access-denied access no-ip|snowflake privilege access-denied access no-ip|mongodb privilege access-denied access no-ip|" \
    "$(printf '%s\n' "$GRANTS" | tr '\n' '|')"
# Oracle and Snowflake answer for an object the account may not see as if it
# did not exist. Neither cause is certain, so the fix names both: the name
# (dropped or renamed: refresh) and the grant (the connector's access).
AMBIG="$(python3 - "$ROOT" <<'PYC'
import json, os, sys
sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import lifecycle, sql
load = lambda c: json.load(open(os.path.join(sys.argv[1], "setup/virtual-schemas/connectors", c, "connector.json")))
IMPORT = "JDBC-Client-Error: Failed to receive MetaData for the given statement: "
last = ""
for cid, words in [
    ("oracle", IMPORT + "ORA-00942: table or view does not exist"),
    ("oracle", IMPORT + 'ORA-00942: table or view "SALES"."ORDERS" does not exist\nhttps://docs.oracle.com/error-help/db/ora-00942/'),
    ("snowflake", IMPORT + "SQL compilation error:\nSchema 'SALES.PUBLIC' does not exist or not authorized."),
    ("snowflake", IMPORT + "SQL compilation error:\nObject 'SALES.PUBLIC.ORDERS' does not exist or not authorized."),
]:
    raw = "\n(\n    message     =>  %s (Session: 1)\n    dsn         =>  127.0.0.1:8563\n    code        =>  ETL-5\n)\n" % words
    line = last = sql.redact(raw, [])
    kind = sql.classify_raw(line, raw)
    doc = load(cid)
    remedy = lifecycle.remedy_for(kind, "src", doc, line)
    both = "dropped or renamed (then: exakit source refresh src)" in remedy and "(grant it %s)" % doc["access"] in remedy
    print("%s %s %s %s %s" % (cid, kind, lifecycle.STATUS_FOR[kind], "both" if both else "NOT-BOTH: " + remedy,
                              "no-ip" if lifecycle.allow_ip(remedy, kind, "203.0.113.7") == remedy else "IP"))
print(last)
PYC
)"
check "missing or not granted (ORA-00942, Snowflake): missing_or_denied, never denied, the fix names both causes" \
    "oracle missing_or_denied failed both no-ip|oracle missing_or_denied failed both no-ip|snowflake missing_or_denied failed both no-ip|snowflake missing_or_denied failed both no-ip|" \
    "$(printf '%s\n' "$AMBIG" | sed '$d' | tr '\n' '|')"
check "...Snowflake's second line stays in the message: it names the object" \
    "JDBC-Client-Error: Failed to receive MetaData for the given statement: SQL compilation error: Object 'SALES.PUBLIC.ORDERS' does not exist or not authorized." \
    "$(printf '%s\n' "$AMBIG" | tail -1)"
# What was classified before stays so: the new words come after every cloud
# class, and a sign-in refusal or a network failure has none of them.
KEPT="$(python3 - "$ROOT" <<'PYC'
import sys
sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import lifecycle, sql
for text in [
    "AccessDeniedException: User: arn:aws:iam::1:user/reader is not authorized to perform: s3:ListBucket (Service: S3, Status Code: 403)",
    "AuthorizationFailure: This request is not authorized to perform this operation. (HTTP 403)",
    "AuthorizationPermissionMismatch: This request is not authorized to perform this operation using this permission.",
    "[Simba][BigQueryJDBCDriver](100032) PERMISSION_DENIED: Access Denied: Table p:d.t: User does not have permission",
    'Unity Catalog request failed: HTTP 403: {"error_code":"PERMISSION_DENIED","message":"User does not have EXTERNAL USE SCHEMA on Schema"}',
    "Access denied for user 'reader'@'203.0.113.7' (using password: YES)",
    'FATAL: password authentication failed for user "reader"',
    "Login failed for user 'reader'.",
    "ORA-01017: invalid username/password; logon denied",
    "Incorrect username or password was specified.",
    "PKIX path building failed: unable to find valid certification path to requested target",
    "Connection refused. Check that the hostname and port are correct",
    "java.net.UnknownHostException: db.example.com",
    "RequestTimeTooSkewed: The difference between the request time and the current time is too large.",
    "NoSuchBucketException: The specified bucket does not exist",
    "NoSuchNamespaceException: Namespace does not exist: sales (HTTP 404)",
    'ERROR: relation "orders" does not exist',
]:
    print(sql.classify(text))
print(lifecycle.allow_ip(lifecycle.remedy_for("denied", "src", {"access": "s3:ListBucket"}), "denied", "203.0.113.7"))
PYC
)"
check "every class before is unchanged: cloud refusals denied (Unity's closed schema external), sign-in auth, and the rest" \
    "denied|denied|denied|denied|external|auth|auth|auth|auth|auth|tls|unreachable|dns|clock|nobucket|schema_missing|error|" \
    "$(printf '%s\n' "$KEPT" | sed '$d' | tr '\n' '|')"
has "...and a cloud refusal still names the public IP, since an address filter answers it too" \
    "allow this computer's public IP 203.0.113.7" "$(printf '%s\n' "$KEPT" | tail -1)"
MG_NOTES="$(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["notes"]))' \
    "$ROOT/setup/virtual-schemas/connectors/mongodb/connector.json")"
has "MongoDB's notes: the adapter signs in against admin, whatever the URI says" "Keep authSource=admin" "$MG_NOTES"
has "...and an Atlas access-list entry is permanent, since a temporary one expires" "as a permanent entry" "$MG_NOTES"

printf '\n== connect: the happy path ==\n'
db '{"sources": {"pg.example.com": {"tables": ["ORDERS", "CUSTOMERS"]}}}'
run connect postgresql --name sales $PG_SET --secret-stdin </dev/null
check "no secret on stdin: refused, exit 2" "2" "$RC"
run_secret "$SECRET" connect postgresql --name sales $PG_SET --secret-stdin
check "connect: exit 0" "0" "$RC"
has "...reports the tables and the bounded read" "Virtual schema VS_SALES: 2 table(s); a bounded read succeeded" "$OUT"
check "...the CONNECTION carries the credential" "$SECRET" "$(dbq 'd["connections"]["EXAKIT_SRC_SALES"]["secret"]')"
check "...and verified TLS in its URL" "jdbc:postgresql://pg.example.com:5432/sales?sslmode=verify-full&sslfactory=org.postgresql.ssl.DefaultJavaSSLFactory" \
    "$(dbq 'd["connections"]["EXAKIT_SRC_SALES"]["url"]')"
check "...adapter script and virtual schema exist" '["EXAKIT_VS.EXAKIT_DNS_PROBE_V2", "EXAKIT_VS.EXAKIT_FILES_PROBE_V1", "EXAKIT_VS.ADAPTER_SALES"] ["ORDERS", "CUSTOMERS"]' \
    "$(dbq 'd["scripts"]') $(dbq 'd["virtual"]["VS_SALES"]["tables"]')"
check "the staged files were confirmed from inside the database before the adapter was created" "1 yes" \
    "$(dbq 'd.get("files_probes")') $(dbq '"yes" if [i for i, s in enumerate(d["statements"]) if "EXAKIT_FILES_PROBE_V1(" in s][0] < [i for i, s in enumerate(d["statements"]) if "ADAPTER SCRIPT" in s][0] else "no"')"
ADAPTER_SQL="$(dbq '[s for s in d["statements"] if "ADAPTER SCRIPT" in s][0]')"
has "...the adapter script lists the staged adapter" "%jar /buckets/bfsdefault/default/exakit/vs/postgresql/4.1.0/virtual-schema-dist-14.1.0-postgresql-4.1.0.jar;" "$ADAPTER_SQL"
has "...and the driver" "%jar /buckets/bfsdefault/default/exakit/vs/postgresql/driver-42.7.14/postgresql-42.7.14.jar;" "$ADAPTER_SQL"
has "...with telemetry off" "%env EXASOL_TELEMETRY_DISABLE=1;" "$ADAPTER_SQL"
has "the virtual schema has the dialect's properties" "CATALOG_NAME = 'sales' SCHEMA_NAME = 'public'" "$(dbq '[s for s in d["statements"] if s.startswith("CREATE VIRTUAL SCHEMA")][0]')"
check "files staged where SQL reads them" "yes yes" \
    "$([ -f "$EXA/bucketfs/bfsdefault/default/exakit/vs/postgresql/4.1.0/virtual-schema-dist-14.1.0-postgresql-4.1.0.jar" ] && echo yes) $([ -f "$EXA/bucketfs/bfsdefault/default/exakit/vs/postgresql/driver-42.7.14/postgresql-42.7.14.jar" ] && echo yes)"
CFG="$EXA/jdbc/POSTGRES_JDBC_DRIVER/settings.cfg"
check "the loader driver's settings.cfg: documented keys, final blank line" \
    "DRIVERNAME=POSTGRES_JDBC_DRIVER|PREFIX=jdbc:postgresql:|DRIVERMAIN=org.postgresql.Driver|FETCHSIZE=100000|INSERTSIZE=-1|JAR=postgresql-42.7.14.jar||" \
    "$(tr '\n' '|' < "$CFG")"
check "the source record says ready" "ready" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$HOME_K/sources/sales/state.json")"
lacks "the secret is not in the output" "s3cr3t" "$OUT"
check "...nor anywhere under the kit home" "" "$(grep -rl 's3cr3t' "$HOME_K/sources" 2>/dev/null)"
check "the source folder is owner-only" "700" "$(stat -c '%a' "$HOME_K/sources/sales" 2>/dev/null || stat -f '%Lp' "$HOME_K/sources/sales")"

printf '\n== a second source on the same connector shares the files ==\n'
python3 - "$STATE" <<'PY'
import json, sys; d = json.load(open(sys.argv[1])); d["sources"]["wh.example.com"] = {"tables": ["STOCK"]}; json.dump(d, open(sys.argv[1], "w"))
PY
run_secret "$SECRET" connect postgresql --name warehouses --set host=wh.example.com --set database=wh --set user=reader --secret-stdin
check "connect warehouses: exit 0" "0" "$RC"
check "the shared driver lists both consumers" '["sales", "warehouses"]' \
    "$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["artifacts"]; print(json.dumps(next(v["consumers"] for k,v in r.items() if k.endswith("POSTGRES_JDBC_DRIVER/postgresql-42.7.14.jar"))))' "$HOME_K/sources/registry.json")"
run_secret "$SECRET" connect postgresql --name sales $PG_SET --secret-stdin
check "a name already in use is a conflict, exit 3" "3" "$RC"

printf '\n== a staged file reaches the database a moment after it is written ==\n'
# Measured on Exasol Personal: the jar staged on this computer was loaded
# from inside the database within the same second and was not there yet.
python3 - "$STATE" <<'PY'
import json, sys; d = json.load(open(sys.argv[1])); d["sources"]["lag.example.com"] = {"tables": ["T"]}; d["stage_lag"] = 2; d["files_probes"] = 0; json.dump(d, open(sys.argv[1], "w"))
PY
run_secret "$SECRET" connect postgresql --name lagged --set host=lag.example.com --set database=lag --set user=reader --secret-stdin
check "two probes saw nothing, the third saw every file: the connect waited and succeeded" "0 3" "$RC $(dbq 'd["files_probes"]')"
has "...and said how long" "Waited 1." "$OUT"
check "...the adapter was created only after that" "yes" \
    "$(dbq '"yes" if [i for i, s in enumerate(d["statements"]) if "EXAKIT_FILES_PROBE_V1(" in s][-1] < [i for i, s in enumerate(d["statements"]) if "ADAPTER_LAGGED" in s][0] else "no"')"
python3 - "$STATE" <<'PY'
import json, sys; d = json.load(open(sys.argv[1])); d["sources"]["never.example.com"] = {"tables": ["T"]}; d["stage_never"] = True; json.dump(d, open(sys.argv[1], "w"))
PY
VISIBLE_TIMEOUT=1.2 run_secret "$SECRET" connect postgresql --name never --set host=never.example.com --set database=n --set user=reader --secret-stdin
check "a file the database never sees: refused after the timeout, exit 1" "1" "$RC"
has "...naming the file and the folder" "does not see /buckets/bfsdefault/default/exakit/vs/postgresql/4.1.0/virtual-schema-dist-14.1.0-postgresql-4.1.0.jar after 1 s (written under" "$OUT"
check "...no adapter, no schema, no record" "0 0 no" \
    "$(dbq 'sum("ADAPTER_NEVER" in s for s in d["scripts"])') $(dbq 'sum("VS_NEVER" in v for v in d["virtual"])') $([ -d "$HOME_K/sources/never" ] && echo yes || echo no)"
python3 - "$STATE" <<'PY'
import json, sys; d = json.load(open(sys.argv[1])); d.pop("stage_never"); json.dump(d, open(sys.argv[1], "w"))
PY
run remove lagged; check "remove lagged: exit 0" "0" "$RC"

printf '\n== a failed connect leaves nothing behind ==\n'
python3 - "$STATE" <<'PY'
import json, sys; d = json.load(open(sys.argv[1])); d["sources"]["bad.example.com"] = {"tables": ["T"], "fail": "auth"}; json.dump(d, open(sys.argv[1], "w"))
PY
run_secret "$SECRET" connect mysql --name crm --set host=bad.example.com --set database=crm --set user=reader --secret-stdin
check "rejected credentials: exit 1" "1" "$RC"
has "...said plainly, with what to do" "the source rejected the credentials; nothing was kept" "$OUT"
check "...its CONNECTION, script and schema were undone" "false false false" \
    "$(dbq '"EXAKIT_SRC_CRM" in d["connections"]' | tr A-Z a-z) $(dbq '"EXAKIT_VS.ADAPTER_CRM" in d["scripts"]' | tr A-Z a-z) $(dbq '"VS_CRM" in d["virtual"]' | tr A-Z a-z)"
check "...no record and no files of its own remain" "no no no" \
    "$([ -d "$HOME_K/sources/crm" ] && echo yes || echo no) $([ -d "$EXA/bucketfs/bfsdefault/default/exakit/vs/mysql" ] && echo yes || echo no) $([ -d "$EXA/jdbc/MYSQL" ] && echo yes || echo no)"
check "...while the other sources' files are untouched" "yes" "$([ -f "$CFG" ] && echo yes)"
lacks "...and the secret never reaches the error text" "s3cr3t" "$OUT"
run_secret "$SECRET" connect mysql --name crm --set host=down.example.com --set database=crm --set user=reader --secret-stdin
check "a host the source list does not know: exit 1" "1" "$RC"

python3 - "$STATE" <<'PY'
import json, sys; d = json.load(open(sys.argv[1])); d["dns"] = False; json.dump(d, open(sys.argv[1], "w"))
PY
run_secret "$SECRET" connect mysql --name crm --set host=pg.example.com --set database=crm --set user=reader --secret-stdin
check "Java without DNS: exit 20, for the shell to repair and retry" "20" "$RC"
# The fix it names is the same on every engine: a stop and a start. Podman
# (and macOS) repair the running container after the start; Docker mounts the
# language container read-only, and its start links the image before it
# mounts it (personal-slc-dns.py). `exakit start` alone does nothing to a
# running database, so the fix names both.
dnsfix() { printf '%s' "$SECRET" | eng --json connect mysql --name crm --set host=pg.example.com --set database=crm \
    --set user=reader --secret-stdin 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["kind"], "|", d["remedy"])'; }
DNSFIX="dns | Java in the database could not resolve the host name; restart the database - exakit stop, then exakit start (the start gives Java the deployment's DNS)"
has "...the fix on Podman: a stop and a start" "$DNSFIX" "$(dnsfix)"
export EXAKIT_VS_OS=Linux
printf '{"runtime": {"type": "personal", "engine": "docker"}}\n' > "$HOME_K/manifest.json"
OUT="$(dnsfix)"
has "...on a Docker deployment: the same (its start links the image)" "$DNSFIX" "$OUT"
lacks "...never the start alone, which does nothing to a running database" "restart the database with exakit start" "$OUT"
check "...the same words for a failure the engine names no fix for (cli.failure)" "True True" "$(python3 - "$ROOT" <<'PYC'
import sys; sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import cli, lifecycle, plan
plan.ENGINE = "docker"
said = "exakit stop, then exakit start (the start gives Java the deployment's DNS)"
print(said in cli.failure("x", 20)["remedy"], said in cli.failure("x", 20, source="crm")["remedy"])
PYC
)"
has "...on macOS the same" "$DNSFIX" "$(EXAKIT_VS_OS=Darwin dnsfix)"
rm -f "$HOME_K/manifest.json"
unset EXAKIT_VS_OS
python3 - "$STATE" <<'PYDNS'
import json, sys; d = json.load(open(sys.argv[1])); d["dns"] = True; json.dump(d, open(sys.argv[1], "w"))
PYDNS
run_secret "$SECRET" connect mysql --name crm --set host=no-such-db.invalid --set database=crm --set user=reader --secret-stdin
check "a name that does not exist is not a DNS repair: exit 1" "1" "$RC"; has "...said as a spelling problem" "does not resolve; nothing was kept - check the spelling" "$OUT"
lacks "...without the firewall advice meant for a host that answers nothing" "firewall" "$OUT"
python3 - "$STATE" <<'PY'
import json, sys; d = json.load(open(sys.argv[1])); d["dns"] = True; d["unreachable"] = ["slow.example.com"]; json.dump(d, open(sys.argv[1], "w"))
PY
run_secret "$SECRET" connect mysql --name crm --set host=slow.example.com --set database=crm --set user=reader --secret-stdin
check "a host that resolves but does not answer: exit 1" "1" "$RC"; has "...named as unreachable from inside the database" "is not reachable from inside the database" "$OUT"
lacks "...said once, not restated in a second parenthesis" "did not answer from inside the database" "$OUT"
db '{"java": false}'
run_secret "$SECRET" connect oracle --name erp --set host=ora.example.com --set service=ORCL --set schema=APP --set user=reader --secret-stdin
check "no Java in the database: exit 21, for the shell to offer the install" "21" "$RC"
# A fresh Exasol Personal 2.4: JAVA=builtin_java, no client in BucketFS. The
# first connect of every new user failed here with exit 1 (live test, 2.4.0).
db '{"java": "builtin"}'
run_secret "$SECRET" connect oracle --name erp --set host=ora.example.com --set service=ORCL --set schema=APP --set user=reader --secret-stdin
check "Personal 2.4's builtin_java without its client: exit 21 too, not 1" "21" "$RC"
has "...said as a missing Java" "Java is not installed in the database" "$OUT"

printf '\n== the first query and the tips ==\n'
db '{"sources": {"my.example.com": {"tables": ["orders", "actor"]}}}'
run_secret "$SECRET" connect mysql --name shop --set host=my.example.com --set database=shop --set user=reader --secret-stdin
check "a MySQL source: exit 0" "0" "$RC"
has "...the first query names a real table, quoted as MySQL spells it" '"example": "SELECT * FROM VS_SHOP.\"actor\" LIMIT 10"' "$OUT"
has "...with the connector's tips, the schema filled in" "quote them, e.g. SELECT \\\"first_name\\\" FROM VS_SHOP.\\\"actor\\\"" "$OUT"
run show shop
has "source show carries the tips too" "YEAR columns arrive as DATE" "$OUT"
run remove shop
db '{"sources": {"pg.example.com": {"tables": ["ORDERS", "LINES"]}}}'
run_secret "$SECRET" connect postgresql --name up $PG_SET --secret-stdin
has "an upper-case table is named without quotes" '"example": "SELECT * FROM VS_UP.LINES LIMIT 10"' "$OUT"
run remove up

printf '\n== the schema is checked before anything is created ==\n'
# Exasol creates a virtual schema over a name the source does not have, empty,
# and that reads as success. The loader asks the source first.
db '{"sources": {"pg.example.com": {"tables": ["ORDERS"], "schemas": {"public": "ok", "Sales": "ok", "locked": "denied"}}}}'
run_secret "$SECRET" connect postgresql --name nosch $PG_SET --set schema=nosuch --secret-stdin
check "a schema the source does not have: exit 1" "1" "$RC"
has "...said with the name" "the source has no schema nosuch that this account can see" "$OUT"
check "...before any script or virtual schema, the connection dropped again" "[] {} {}" \
    "$(dbq '[s for s in d["scripts"] if "NOSCH" in s]') $(dbq '{k: v for k, v in d["virtual"].items() if "NOSCH" in k}') $(dbq '{k: v for k, v in d["connections"].items() if "NOSCH" in k}')"
check "...and no record" "no" "$([ -d "$HOME_K/sources/nosch" ] && echo yes || echo no)"
db '{"sources": {"pg.example.com": {"tables": ["ORDERS"], "schemas": {"public": "ok", "Sales": "ok", "sales": "case:Sales", "locked": "denied"}}}}'
run_secret "$SECRET" connect postgresql --name nosch $PG_SET --set schema=sales --secret-stdin
has "a schema spelled in another case is named as the source spells it" "it has Sales (PostgreSQL folds an unquoted name to lower case); give it as the source spells it: --set schema=Sales" "$OUT"
run_secret "$SECRET" connect postgresql --name nosch $PG_SET --set schema=locked --secret-stdin
check "a schema the account may not use: exit 1" "1" "$RC"
has "...filed as access denied, with the grant to give" "the account may not use schema locked; grant it USAGE on the schema" "$OUT"
run_secret "$SECRET" connect postgresql --name withsch $PG_SET --set schema=Sales --secret-stdin
check "the right schema: exit 0" "0" "$RC"
has "...said before the adapter is created" "The source has schema Sales, and the account may use it" "$OUT"
check "...asked with the schema as given" "Sales" "$(dbq 'd["scope_checks"][-1]')"
run remove withsch
db '{"sources": {"my.example.com": {"tables": ["orders"], "schemas": {"shop": "ok"}}}}'
run_secret "$SECRET" connect mysql --name nodb --set host=my.example.com --set database=Shop --set user=reader --secret-stdin
has "MySQL: the database is the scope checked" "the source has no database Shop that this account can see" "$OUT"
db '{"sources": {"my.example.com": {"tables": ["orders"]}}}'
run_secret "$SECRET" connect bigquery --name nobq --set project=p --set dataset=d --secret-stdin < /dev/null
lacks "a connector without a schema check asks nothing" "that this account can see" "$OUT"

printf '\n== source describe: tables and columns, and DDL to copy them ==\n'
db '{"sources": {"my.example.com": {"tables": ["orders", "Orders2", "actor"]}}, "columns": {"orders": [["order_id", "DECIMAL(10,0)", false], ["note", "VARCHAR(100) UTF8", true]], "actor": [["first|name", "VARCHAR(45) UTF8", true]]}}'
run_secret "$SECRET" connect mysql --name desc --set host=my.example.com --set database=shop --set user=reader --secret-stdin
check "a source to describe: exit 0" "0" "$RC"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["statements"]=[]; json.dump(d, open(sys.argv[1], "w"))' "$STATE"
run --json describe desc
check "describe: exit 0" "0" "$RC"
has "...every table, columns in order" '"name": "orders"' "$OUT"
has "...with types and nullability" '"type": "DECIMAL(10,0)"' "$OUT"
lacks "...and nothing reaches the source (no import, no adapter call)" "IMPORT FROM" "$(dbq 'd["statements"]')"
run --json describe desc ORDERS
check "a table named in another case, when only one matches: exit 0" "0" "$RC"
has "...gives that table" '"name": "orders"' "$OUT"
lacks "...and only that one" '"name": "actor"' "$OUT"
run describe desc nosuch
check "an unknown table: exit 2" "2" "$RC"; has "...listing the tables" "its tables: Orders2, actor, orders" "$OUT"
db '{"sources": {"my.example.com": {"tables": ["t", "T"]}}, "virtual": {"VS_DESC": {"connection": "EXAKIT_SRC_DESC", "tables": ["t", "T"]}}}'
run describe desc TT
check "no match at all: exit 2" "2" "$RC"
python3 - "$STATE" <<'PY'
import json, sys; d = json.load(open(sys.argv[1])); d["virtual"]["VS_DESC"]["tables"] = ["ab", "AB"]; json.dump(d, open(sys.argv[1], "w"))
PY
run describe desc Ab
check "two tables that differ only in case: exit 2, never a guess" "2" "$RC"; has "...said so" "matches 2 tables in VS_DESC" "$OUT"
db '{"sources": {"my.example.com": {"tables": ["orders", "actor"]}}, "virtual": {"VS_DESC": {"connection": "EXAKIT_SRC_DESC", "tables": ["orders", "actor"]}}, "columns": {"orders": [["order_id", "DECIMAL(10,0)", false], ["note", "VARCHAR(100) UTF8", true]], "actor": [["first|name", "VARCHAR(45) UTF8", true]]}}'
run --json describe desc orders --ddl --into LOCAL
has "--ddl: a CREATE TABLE in the target schema, every name quoted" 'CREATE TABLE \"LOCAL\".\"orders\" (\n    \"order_id\" DECIMAL(10,0) NOT NULL,\n    \"note\" VARCHAR(100) UTF8\n);' "$OUT"
has "...and the copy, as a comment" '-- a local copy: INSERT INTO \"LOCAL\".\"orders\" SELECT * FROM VS_DESC.\"orders\";' "$OUT"
run --json describe desc actor --ddl
has "...without --schema: the session's schema, a MongoDB-style name quoted" 'CREATE TABLE \"actor\" (\n    \"first|name\" VARCHAR(45) UTF8\n);' "$OUT"
run describe desc --ddl --into 'X;DROP'
check "--schema takes a plain name only: exit 2" "2" "$RC"
run disconnect desc
run --json describe desc
check "a disconnected source still describes (the catalog is local): exit 0" "0" "$RC"
python3 - "$STATE" <<'PY'
import json, sys; d = json.load(open(sys.argv[1])); d["virtual"].pop("VS_DESC"); json.dump(d, open(sys.argv[1], "w"))
PY
run describe desc
check "a virtual schema that is gone: exit 1" "1" "$RC"; has "...with the way back" "exakit source check desc" "$OUT"
run remove desc; check "...and it still removes cleanly" "0" "$RC"

printf '\n== an interrupted connect is recovered, not mistaken for a stranger ==\n'
# The state an attempt killed right after CREATE CONNECTION leaves behind: its
# journal (naming what it made) and the connection in the database.
db '{"sources": {"pg.example.com": {"tables": ["ORDERS"]}}, "connections": {"EXAKIT_SRC_LATE": {"url": "x", "user": "reader", "secret": "half-done"}}}'
mkdir -p "$HOME_K/sources/late"
printf '{"operation": "connect", "connector": "postgresql", "created": {"files": [], "connection": true, "script": false, "schema": false}}\n' > "$HOME_K/sources/late/journal.json"
run_secret "$SECRET" connect postgresql --name late $PG_SET --secret-stdin
check "a retry after an interrupted connect succeeds" "0" "$RC"
has "...and says what it cleaned up first" "was interrupted; removing what it created first" "$OUT"
check "...the connection now holds the new attempt's credential" "$SECRET" "$(dbq 'd["connections"]["EXAKIT_SRC_LATE"]["secret"]')"
run remove late >/dev/null
# A journal with nothing recorded is simply cleared.
mkdir -p "$HOME_K/sources/late2"; printf '{"operation": "connect", "created": {"files": []}}\n' > "$HOME_K/sources/late2/journal.json"
run_secret "$SECRET" connect postgresql --name late2 $PG_SET --secret-stdin
check "an empty journal does not block a connect" "0" "$RC"
run remove late2 >/dev/null

printf '\n== what the kit does not own ==\n'
db '{"sources": {"pg.example.com": {"tables": ["ORDERS"]}}, "connections": {"EXAKIT_SRC_HR": {"url": "x", "user": "u", "secret": "theirs"}}}'
run_secret "$SECRET" connect postgresql --name hr $PG_SET --secret-stdin
check "a CONNECTION the kit did not create: conflict, exit 3" "3" "$RC"
check "...and it is left exactly as it was" "theirs" "$(dbq 'd["connections"]["EXAKIT_SRC_HR"]["secret"]')"
mkdir -p "$EXA/jdbc/SQLSERVER"; printf 'DRIVERNAME=SQLSERVER\nJAR=theirs.jar\n' > "$EXA/jdbc/SQLSERVER/settings.cfg"
db '{"sources": {"ms.example.com": {"tables": ["T"]}}}'
run_secret "$SECRET" connect mssql --name fin --set host=ms.example.com --set database=fin --set user=reader --secret-stdin
check "a loader driver the kit did not register: conflict, exit 3" "3" "$RC"
check "...its settings.cfg untouched" "JAR=theirs.jar" "$(sed -n 2p "$EXA/jdbc/SQLSERVER/settings.cfg")"
rm -rf "$EXA/jdbc/SQLSERVER"
# No shipped connector is gated now; a test-only one keeps the gate honest.
python3 - "$DEFS" <<'PYG'
import json, os, shutil, sys
defs = sys.argv[1]
cat = json.load(open(os.path.join(defs, "catalog.json")))
cat["connectors"].append({"id": "gatedtest", "name": "Gated Test", "aliases": ["gt"], "profile": "java-jdbc",
                          "tier": "GA", "status": "gated", "gate": "its credential is not qualified on Exasol Personal yet"})
json.dump(cat, open(os.path.join(defs, "catalog.json"), "w"), indent=2)
os.makedirs(os.path.join(defs, "connectors", "gatedtest"), exist_ok=True)
shutil.copy(os.path.join(defs, "connectors", "bigquery", "connector.json"), os.path.join(defs, "connectors", "gatedtest"))
PYG
run_secret "{}" connect gatedtest --name gt --set project=p --set dataset=d --secret-stdin
check "a gated connector explains its gate, exit 5" "5" "$RC"; has "...naming it" "not qualified on Exasol Personal yet" "$OUT"
run connect gatedtest --name gt --dry-run
check "...before any input is asked for, dry run included" "5" "$RC"; lacks "...no input complaint" "is required" "$OUT"
run resolve gt
check "resolving a gated connector says so, exit 5 (the wizard asks nothing)" "5" "$RC"; has "...with the reason" "not available yet" "$OUT"

printf '\n== check, issues, reauth ==\n'
# Back to the two healthy sources from the happy path.
python3 - "$STATE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d.update({"sources": {"pg.example.com": {"tables": ["ORDERS", "CUSTOMERS"], "secret": "s3cr3t-Pa55'word"},
                      "wh.example.com": {"tables": ["STOCK"]}},
          "connections": {"EXAKIT_SRC_SALES": {"url": "jdbc:postgresql://pg.example.com:5432/sales", "user": "reader", "secret": "s3cr3t-Pa55'word"},
                          "EXAKIT_SRC_WAREHOUSES": {"url": "jdbc:postgresql://wh.example.com:5432/wh", "user": "reader", "secret": "x"}},
          "schemas": ["EXAKIT_VS"], "scripts": ["EXAKIT_VS.EXAKIT_DNS_PROBE_V2", "EXAKIT_VS.EXAKIT_FILES_PROBE_V1", "EXAKIT_VS.ADAPTER_SALES", "EXAKIT_VS.ADAPTER_WAREHOUSES"],
          "virtual": {"VS_SALES": {"connection": "EXAKIT_SRC_SALES", "tables": ["ORDERS", "CUSTOMERS"]},
                      "VS_WAREHOUSES": {"connection": "EXAKIT_SRC_WAREHOUSES", "tables": ["STOCK"]}}})
json.dump(d, open(sys.argv[1], "w"))
PY
run check sales; check "check: ready" "0" "$RC"; has "...with its evidence" "metadata and a bounded read (2 tables)" "$OUT"
python3 - "$STATE" <<'PY'
import json, sys; d = json.load(open(sys.argv[1])); d["sources"]["pg.example.com"]["secret"] = "n3w-T0ken-value"; json.dump(d, open(sys.argv[1], "w"))
PY
run check sales; check "a rotated credential at the source: check exits 1" "1" "$RC"
has "...and says why, though no RESULT line follows a failure" "FAIL sales is auth-failed:" "$OUT"
has "...with the fix" "INFO Fix: the source rejected the credentials: exakit source reauth sales" "$OUT"
check "...the record says auth-failed" "auth-failed" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$HOME_K/sources/sales/state.json")"
run --json issues; has "issues lists it" '"name": "sales"' "$OUT"; has "...with the runnable remedy" "exakit source reauth sales" "$OUT"
lacks "...and not the healthy one" '"name": "warehouses"' "$OUT"
run --json check --all; check "check --all: exit 1 while one source is failing" "1" "$RC"
OLDSECRET="$(dbq 'd["connections"]["EXAKIT_SRC_SALES"]["secret"]')"
run_secret "typo-$NEWSECRET" reauth sales --secret-stdin
check "reauth with a credential the source refuses: exit 1" "1" "$RC"
has "...and says the previous one was kept" "refused the new credential, so the previous one was kept" "$OUT"
check "...the CONNECTION still holds the previous credential" "$OLDSECRET" "$(dbq 'd["connections"]["EXAKIT_SRC_SALES"]["secret"]')"
check "...and the pending CONNECTION is gone" "[]" "$(pending)"
has "...it was tried under a name no source can have" 'CREATE OR REPLACE CONNECTION "EXAKIT_PENDING_EXAKIT_SRC_SALES"' "$(dbq '" | ".join(d["statements"])')"
lacks "...the refused credential is in none of the output" "typo-$NEWSECRET" "$OUT"
run_secret "$NEWSECRET" reauth sales --secret-stdin
check "reauth with the new credential: ready again" "0" "$RC"
has "...after the source accepted it" "The source accepted the new credential" "$OUT"
check "...the CONNECTION holds it" "$NEWSECRET" "$(dbq 'd["connections"]["EXAKIT_SRC_SALES"]["secret"]')"
check "...and it is in no file" "" "$(grep -rl 'n3w-T0ken' "$HOME_K/sources" 2>/dev/null)"
run refresh warehouses; has "refresh reports the table count" '"tables": 1' "$OUT"

printf '\n== disconnect and reconnect ==\n'
run disconnect sales --dry-run; check "disconnect --dry-run changes nothing" "true" "$(dbq '"EXAKIT_SRC_SALES" in d["connections"]' | tr A-Z a-z)"
has "...and says what it keeps" "virtual schema VS_SALES" "$OUT"
run disconnect sales
check "disconnect drops only the CONNECTION" "false true true" \
    "$(dbq '"EXAKIT_SRC_SALES" in d["connections"]' | tr A-Z a-z) $(dbq '"VS_SALES" in d["virtual"]' | tr A-Z a-z) $(dbq '"EXAKIT_VS.ADAPTER_SALES" in d["scripts"]' | tr A-Z a-z)"
run check sales; has "a disconnected source is skipped by check" '"skipped": true' "$OUT"
run_secret "$NEWSECRET" connect postgresql --name sales --secret-stdin
check "connect on a disconnected source reconnects it, from the name and the credential alone" "0" "$RC"
has "...to the recorded host" "pg.example.com resolves and answers on port 5432" "$OUT"
check "...recreating the CONNECTION" "true" "$(dbq '"EXAKIT_SRC_SALES" in d["connections"]' | tr A-Z a-z)"

printf '\n== remove: owned objects, shared files kept until the last consumer ==\n'
DRIVER="$EXA/jdbc/POSTGRES_JDBC_DRIVER/postgresql-42.7.14.jar"
run remove sales --dry-run; has "remove --dry-run lists what it keeps" "keep_files" "$OUT"; check "...and changes nothing" "true" "$(dbq '"VS_SALES" in d["virtual"]' | tr A-Z a-z)"
run remove sales
check "remove sales: its objects are gone" "false false false" \
    "$(dbq '"VS_SALES" in d["virtual"]' | tr A-Z a-z) $(dbq '"EXAKIT_VS.ADAPTER_SALES" in d["scripts"]' | tr A-Z a-z) $(dbq '"EXAKIT_SRC_SALES" in d["connections"]' | tr A-Z a-z)"
check "...the driver warehouses still uses stays" "yes" "$([ -f "$DRIVER" ] && echo yes)"
check "...and so does the kit schema" "true" "$(dbq '"EXAKIT_VS" in d["schemas"]' | tr A-Z a-z)"
run disconnect warehouses
run remove warehouses
check "remove after disconnect works (the adapter callback is skipped)" "0" "$RC"
has "...with FORCE, on the kit's own schema only" 'DROP FORCE VIRTUAL SCHEMA "VS_WAREHOUSES"' "$(dbq '" | ".join(s for s in d["statements"] if "VIRTUAL SCHEMA" in s and s.startswith("DROP"))')"
check "the last consumer out: shared files deleted" "no no" "$([ -f "$DRIVER" ] && echo yes || echo no) $([ -d "$EXA/jdbc/POSTGRES_JDBC_DRIVER" ] && echo yes || echo no)"
check "...the kit schema dropped" "false" "$(dbq '"EXAKIT_VS" in d["schemas"]' | tr A-Z a-z)"
check "...but never the bucket or what the kit did not make" "yes yes" \
    "$([ -d "$EXA/bucketfs/bfsdefault/default" ] && echo yes) $([ -f "$EXA/jdbc/java.security" ] && echo yes)"
run --json list; has "nothing is listed" '"sources": []' "$OUT"
run show sales; check "show on a removed source: exit 4" "4" "$RC"

printf '\n== the shell bridge (setup/lib/virtual-schemas.sh) ==\n'
# A stand-in engine records its arguments and its stdin, and answers with the
# exit code a test arranges - so what the bridge does with each is observable.
B="$WORK/bridge"; mkdir -p "$B"
bridge() {
    ( EXAKIT_HOME="$B/home"; mkdir -p "$EXAKIT_HOME"
      . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/detect.sh"; . "$ROOT/setup/lib/runtime-personal.sh"
      . "$ROOT/setup/lib/virtual-schemas.sh"
      _require_install() { :; }; exakit_init_logging() { :; }
      # The credential reader runs on the kit's pyexasol: here, this python3.
      pyexasol_venv_python() { command -v python3; }
      exakit_vs_engine() {
          printf '%s\n' "$*" >> "$B/argv"
          [ -t 0 ] || cat >> "$B/stdin"
          # What a child of the bridge sees in its environment (item: exported names).
          env >> "$B/env"
          _n="$(wc -l < "$B/argv" | tr -d ' ')"
          _code="$(sed -n "${_n}p" "$B/codes" 2>/dev/null)"
          if [ "$1" = resolve ] && [ -f "$B/gated" ]; then echo "FAIL BigQuery is not available yet: gated"; return 5; fi
          case "$1" in list|issues) cat "$B/rows" 2>/dev/null ;; check) echo 'RESULT {"checks": []}' ;; remove|disconnect) echo 'RESULT {"name": "sales", "drop": ["virtual schema VS_SALES", "CONNECTION EXAKIT_SRC_SALES"], "keep": [], "delete_files": ["a.jar"], "keep_files": ["b.jar"], "note": "nothing is revoked at the source"}' ;; show) echo "FAIL no source named $2 (see: exakit source list)" ;; resolve) echo 'RESULT {"connector": "postgresql"}' ;; plan) echo 'RESULT {"name": "x", "connector": "postgresql", "tier": "GA", "status": "candidate", "downloads": [], "steps": [], "exposure": "e", "warnings": []}' ;; esac
          return "${_code:-0}"
      }
      # B/dnsrc: what the repair answers (2: Docker, linked in the image).
      personal_slc_dns_repair() { echo "REPAIRED" >> "$B/argv"; return "$(cat "$B/dnsrc" 2>/dev/null || echo 0)"; }
      _exakit_vs_install_java() { echo "JAVA-ASKED" >> "$B/argv"; return 1; }
      EXAKIT_BIN_DIR="$B/bin"
      "$@" ) 2>&1
}
# The installed kit's exakit, recording what it was asked.
mkdir -p "$B/bin"
printf '#!/bin/sh\necho "EXAKIT $1" >> "%s/argv"\n' "$B" > "$B/bin/exakit"; chmod +x "$B/bin/exakit"
reset_bridge() { rm -f "$B/argv" "$B/stdin" "$B/codes" "$B/env" "$B/dnsrc"; printf '%s\n' "$@" > "$B/codes"; }
# The same bridge for a fresh bash started with a given environment (review 5).
{ printf 'ROOT=%q; B=%q\n' "$ROOT" "$B"; declare -f bridge; } > "$WORK/bridge-fn.sh"

reset_bridge
OUT="$(bridge cmd_connect pg --name sales --password=hunter2 </dev/null)"; RC=$?
check "a password argument is refused before anything runs, exit 2" "2 no" "$RC $([ -f "$B/argv" ] && echo yes || echo no)"
OUT="$(bridge cmd_connect pg --set host=h </dev/null)"; RC=$?
check "unattended, the name is required" "2" "$RC"
reset_bridge 0 0 0
printf 'pw-from-stdin' > "$B/pw"
OUT="$(bridge cmd_connect pg --name sales --set host=db.example.com --set user=reader --password-file "$B/pw" </dev/null)"; RC=$?
check "connect with a password file: exit 0" "0" "$RC"
check "...the engine ran resolve, plan, connect - the last with --secret-stdin" \
    "resolve pg|plan postgresql --name sales --set host=db.example.com --set user=reader|connect postgresql --name sales --set host=db.example.com --set user=reader --secret-stdin|" \
    "$(tr '\n' '|' < "$B/argv")"
check "...the credential reached it on stdin" "pw-from-stdin" "$(cat "$B/stdin")"
lacks "...and never as an argument" "pw-from-stdin" "$(cat "$B/argv")"
reset_bridge 0 0 20 0
OUT="$(bridge cmd_connect pg --name sales --set host=h --password-file "$B/pw" </dev/null)"; RC=$?
check "exit 20 from the engine: DNS repaired, connect retried once, exit 0" \
    "0 connect|REPAIRED|connect|" "$RC $(grep -E '^(connect|REPAIRED)' "$B/argv" | cut -d' ' -f1 | tr '\n' '|')"
reset_bridge 0 0 20 0; echo 2 > "$B/dnsrc"
OUT="$(bridge cmd_connect pg --name sales --set host=h --password-file "$B/pw" --yes </dev/null)"; RC=$?
check "exit 20 on Docker (the image linked): --yes restarts the database once, then retries" \
    "0 connect|REPAIRED|EXAKIT stop|EXAKIT start|connect|" "$RC $(grep -E '^(connect|REPAIRED|EXAKIT)' "$B/argv" | cut -d' ' -f1-2 | sed 's/^connect .*/connect/' | tr '\n' '|')"
reset_bridge 0 0 20 0; echo 2 > "$B/dnsrc"
OUT="$(bridge cmd_connect pg --name sales --set host=h --password-file "$B/pw" </dev/null)"; RC=$?
check "...without --yes and no terminal: no restart, nothing retried, exit 20" "20 0 1" "$RC $(grep -c '^EXAKIT' "$B/argv") $(grep -c '^connect' "$B/argv")"
has "...and it names the restart that fixes it" "Run: exakit stop, then exakit start - and try again." "$OUT"
reset_bridge 0 0 20 0; echo 1 > "$B/dnsrc"
OUT="$(bridge cmd_connect pg --name sales --set host=h --password-file "$B/pw" --yes </dev/null)"; RC=$?
check "a repair that fails: no restart, nothing retried" "20 0" "$RC $(grep -c '^EXAKIT' "$B/argv")"
reset_bridge 0 0 21
OUT="$(bridge cmd_connect pg --name sales --set host=h --password-file "$B/pw" </dev/null)"; RC=$?
check "exit 21: the Java install is offered; declined, nothing retried" "21 1" "$RC $(grep -c '^connect' "$B/argv")"
# A repair that fails: the bridge names the stop and start, whose start links
# the image on Docker and repairs the container elsewhere.
dnsline() { ( EXAKIT_HOME="$HOME_K"; STUB_OS="$1"; STUB_ENGINE="$2"
    . "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/virtual-schemas.sh"
    personal_slc_dns_repair() { return 1; }
    detect_os() { printf '%s' "$STUB_OS"; }
    personal_slc_dns_engine() { printf '%s' "$STUB_ENGINE"; }
    _exakit_vs_repair 20; echo "rc=$?" ) 2>&1; }
for _e in "linux docker" "linux podman" "macos docker"; do
    has "a failed repair ($_e): the stop and start that fix it" "Restart the database (exakit stop, exakit start) and try again." "$(dnsline $_e)"
done

printf '\n== preparing the database for a source: said at a terminal, never asked; a script keeps its contract ==\n'
# The real _exakit_vs_install_java, _exakit_vs_install_rust and _exakit_vs_repair;
# only what they call is a stand-in: the launcher, the kit's exakit, a download.
# prep <interactive> <json> <yes> <terminal> <function> [args] - interactive is a
# person connecting (cmd_connect or the terminal flow set it), terminal whether
# one is reachable. Every question, launcher call, download and stop/start lands
# in $WORK/prep.calls.
mkdir -p "$WORK/prepbin"
printf '#!/bin/sh\necho "EXAKIT $1" >> "%s/prep.calls"\n' "$WORK" > "$WORK/prepbin/exakit"; chmod +x "$WORK/prepbin/exakit"
prep() {
    : > "$WORK/prep.calls"
    ( EXAKIT_HOME="$HOME_K"
      . "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/virtual-schemas.sh"
      exakit_vs_defs() { printf '%s\n' "$DEFS"; }
      _EXAKIT_VS_INTERACTIVE="$1"; EXAKIT_VS_JSON="$2"; EXAKIT_VS_ASSUME_YES="$3"; _p_tty="$4"; shift 4
      _EXAKIT_VS_FOR=PostgreSQL
      _exakit_prompt_tty() { [ "$_p_tty" = 1 ] && printf '/dev/tty\n'; return 0; }
      prompt_text() { echo "ASKED $1" >> "$WORK/prep.calls"; printf 'y\n'; }
      personal_cli() { printf 'exasol\n'; }
      personal_auto_approve_flag() { :; }
      personal_slc_dns_prepare() { :; }
      personal_slc_dns_repair() { return "${PREP_DNS:-0}"; }
      run_logged() { echo "RUN $*" >> "$WORK/prep.calls"; }
      fetch() { echo "FETCH" >> "$WORK/prep.calls"; return 1; }
      EXAKIT_BIN_DIR="$WORK/prepbin"
      "$@"; echo "rc=$?" ) 2>&1
}
calls() { tr '\n' '|' < "$WORK/prep.calls"; }
OUT="$(prep 1 0 0 1 _exakit_vs_install_java)"
check "a connect at a terminal, Java missing: installed with no question, one restart" \
    "rc=0 RUN exasol slc install java --no-restart|EXAKIT stop|EXAKIT start|" "$(printf '%s' "$OUT" | tail -n 1) $(calls)"
has "...one line says what it does and why" "Installing the Java language container for PostgreSQL: about 250 MiB, and the database restarts once" "$OUT"
lacks "...and nothing asked" "ASKED" "$(calls)"
OUT="$(prep 1 1 0 1 _exakit_vs_install_java)"
check "--json at the same terminal: the contract - nothing installed, nothing asked" "rc=1 " "$(printf '%s' "$OUT" | tail -n 1) $(calls)"
has "...and the remedy said" "Install it later with: exasol slc install java --no-restart, then exakit stop and exakit start" "$OUT"
OUT="$(prep 0 0 0 0 _exakit_vs_install_java)"
check "no terminal, no --yes: nothing installed, nothing asked (exit 21 follows)" "rc=1 " "$(printf '%s' "$OUT" | tail -n 1) $(calls)"
OUT="$(prep 0 0 1 0 _exakit_vs_install_java)"
check "no terminal, --yes: installed" "rc=0 RUN exasol slc install java --no-restart|EXAKIT stop|EXAKIT start|" "$(printf '%s' "$OUT" | tail -n 1) $(calls)"
OUT="$(prep 0 0 0 1 _exakit_vs_install_java)"
check "a terminal but not a connect (exakit source refresh): still asked, as before" "ASKED Install the Java language container now? [y/N]" \
    "$(grep '^ASKED' "$WORK/prep.calls")"
OUT="$(PREP_DNS=2 prep 1 0 0 1 _exakit_vs_repair 20)"
check "a connect at a terminal, Docker's DNS repair: one restart with no question" "rc=0 EXAKIT stop|EXAKIT start|" "$(printf '%s' "$OUT" | tail -n 1) $(calls)"
has "...one line says what it does and why" "Restarting the database once, so Java in it can resolve host names for PostgreSQL" "$OUT"
OUT="$(PREP_DNS=2 prep 0 0 0 0 _exakit_vs_repair 20)"
check "...no terminal, no --yes: no restart, nothing asked (exit 20 follows)" "rc=1 " "$(printf '%s' "$OUT" | tail -n 1) $(calls)"
has "...and the restart named" "Run: exakit stop, then exakit start - and try again." "$OUT"
OUT="$(PREP_DNS=2 prep 1 1 0 1 _exakit_vs_repair 20)"
check "...--json at a terminal: no restart, nothing asked" "rc=1 " "$(printf '%s' "$OUT" | tail -n 1) $(calls)"
OUT="$(prep 1 0 0 1 _exakit_vs_install_rust)"
check "a connect at a terminal, Rust missing: the download starts with no question" "FETCH|" "$(calls)"
has "...one line says what it does and why" "Installing the Rust language container for PostgreSQL:" "$OUT"
OUT="$(prep 0 0 0 0 _exakit_vs_install_rust)"
check "...no terminal, no --yes: nothing downloaded, nothing asked (exit 23 follows)" "rc=1 " "$(printf '%s' "$OUT" | tail -n 1) $(calls)"
has "...and it says so" "Nothing was installed. Run the same exakit connect again when you are ready." "$OUT"
# The whole connect, unattended: the engine's exit 21 and its remedy, unchanged.
reset_bridge 0 0 21
OUT="$(bridge cmd_connect pg --name sales --set host=h --password-file "$B/pw" </dev/null)"; RC=$?
check "unattended connect, Java missing: exit 21, nothing retried" "21 1" "$RC $(grep -c '^connect' "$B/argv")"
has "...the offer was made" "JAVA-ASKED" "$(cat "$B/argv")"
reset_bridge 0
OUT="$(bridge cmd_source remove sales --dry-run </dev/null)"
check "source remove --dry-run passes the preview through" "remove sales --dry-run" "$(cat "$B/argv")"
OUT="$(bridge cmd_source remove </dev/null)"; RC=$?
check "source remove without a name: exit 2" "2" "$RC"
OUT="$(bridge cmd_source bogus </dev/null)"; RC=$?
check "an unknown action: exit 2" "2" "$RC"
reset_bridge 0
OUT="$(bridge cmd_source remove sales --dry-run </dev/null)"
has "remove --dry-run shows what it drops" "drops: virtual schema VS_SALES, CONNECTION EXAKIT_SRC_SALES" "$OUT"
has "...the files it deletes and keeps" "deletes 1 unused file(s); keeps 1 still shared" "$OUT"
reset_bridge 0
OUT="$(bridge cmd_source disconnect sales </dev/null)"; RC=$?
check "disconnect without a terminal or --yes: exit 5, not 0" "5" "$RC"
check "...only the preview ran" "disconnect sales --dry-run|" "$(tr '\n' '|' < "$B/argv")"
reset_bridge 0 0
OUT="$(bridge cmd_source remove sales --yes </dev/null)"; RC=$?
check "remove --yes: exit 0" "0" "$RC"; has "...and says it is done" "sales removed" "$OUT"
reset_bridge 4
OUT="$(bridge cmd_source reauth nosuch --password-file "$B/pw" </dev/null)"; RC=$?
check "reauth of a source that does not exist: exit 4, before any credential" "4 show nosuch|" "$RC $(tr '\n' '|' < "$B/argv")"
check "...nothing reached the engine's stdin" "no" "$([ -s "$B/stdin" ] && echo yes || echo no)"
has "...and says which name" "no source named nosuch" "$OUT"
reset_bridge 0 1
OUT="$(bridge cmd_source reauth docs --password-file "$B/pw" </dev/null)"; RC=$?
check "reauth: the name is checked, then the engine gets --secret-stdin" "show docs|reauth docs --secret-stdin|" "$(tr '\n' '|' < "$B/argv")"
check "...the credential reached it on stdin" "pw-from-stdin" "$(cat "$B/stdin")"
lacks "...and never as an argument" "pw-from-stdin" "$(cat "$B/argv")"
check "...a refused credential (engine exit 1) exits 1" "1" "$RC"
lacks "...without saying the source is ready again" "ready again with the new credential" "$OUT"
reset_bridge 0
OUT="$(bridge cmd_source check --all </dev/null)"
has "check --all with no sources says so" "(none)" "$OUT"
reset_bridge; : > "$B/gated"
OUT="$(bridge cmd_connect bq --name b </dev/null)"; RC=$?
check "a gated connector stops the wizard with the engine's exit 5" "5 resolve bq|resolve bq|" "$RC $(tr '\n' '|' < "$B/argv")"
has "...and the reason is shown" "not available yet" "$OUT"
rm -f "$B/gated"
# --password-stdin: ALL of stdin (a JSON key file's line breaks kept), one
# trailing line ending dropped; nothing on it, or --password-file beside it,
# refused before anything runs. What the stand-in engine got is compared byte
# for byte: $( ) would hide the line endings.
same() { if printf '%s' "$1" | cmp -s - "$2"; then echo same; else echo "differs: $(od -c < "$2" | head -3 | tr -s ' ' | tr '\n' ' ')"; fi; }
KEYJSON='{
  "type": "service_account",
  "private_key": "-----BEGIN PRIVATE KEY-----\nMIIx\n-----END PRIVATE KEY-----\n"
}'
reset_bridge 0 0 0
OUT="$(printf '%s\n' "$KEYJSON" | bridge cmd_connect pg --name sales --set host=db.example.com --set user=reader --password-stdin --yes)"; RC=$?
check "--password-stdin: exit 0, resolve, plan, then connect with --secret-stdin" \
    "0 resolve pg|plan postgresql --name sales --set host=db.example.com --set user=reader|connect postgresql --name sales --set host=db.example.com --set user=reader --secret-stdin|" \
    "$RC $(tr '\n' '|' < "$B/argv")"
check "...all of stdin reached the engine, its line breaks kept, the trailing one dropped" "same" "$(same "$KEYJSON" "$B/stdin")"
lacks "...never as an argument" "service_account" "$(cat "$B/argv")"
lacks "...nor in the output" "service_account" "$OUT"
reset_bridge 0 0 0
OUT="$(printf 'pw-crlf\r\n' | bridge cmd_connect pg --name sales --set host=h --password-stdin --yes)"
check "--password-stdin: a CRLF ending is one line ending" "same" "$(same 'pw-crlf' "$B/stdin")"
reset_bridge 0 0 0
OUT="$(printf 'pw-two\n\n' | bridge cmd_connect pg --name sales --set host=h --password-stdin --yes)"
check "--password-stdin: the bridge drops one trailing line ending (the engine the rest: end to end below)" "same" "$(same 'pw-two
' "$B/stdin")"
reset_bridge 0 0 0
OUT="$(bridge cmd_connect pg --name sales --set host=h --password-stdin --yes </dev/null)"; RC=$?
check "--password-stdin with nothing on stdin: exit 2, before anything ran" "2 no" "$RC $([ -f "$B/argv" ] && echo yes || echo no)"
has "...saying so in one line" "--password-stdin read nothing: standard input was empty." "$OUT"
reset_bridge 0 0 0
OUT="$(printf 'pw' | bridge cmd_connect pg --name sales --set host=h --password-stdin --password-file "$B/pw" --yes)"; RC=$?
check "--password-stdin with --password-file: exit 2, before anything ran" "2 no" "$RC $([ -f "$B/argv" ] && echo yes || echo no)"
has "...saying to use one" "--password-stdin and --password-file both give the credential; use one." "$OUT"
reset_bridge 0 1
OUT="$(printf 'new-cred\n' | bridge cmd_source reauth docs --password-stdin)"; RC=$?
check "source reauth --password-stdin: the name is checked, then the engine gets --secret-stdin" "show docs|reauth docs --secret-stdin|" "$(tr '\n' '|' < "$B/argv")"
check "...the piped credential reached it, its newline dropped" "same" "$(same 'new-cred' "$B/stdin")"
reset_bridge 0
OUT="$(bridge cmd_source reauth docs --password-stdin </dev/null)"; RC=$?
check "source reauth --password-stdin, nothing on stdin: exit 2 after the name check, no reauth" "2 show docs|" "$RC $(tr '\n' '|' < "$B/argv")"
reset_bridge 0
OUT="$(printf 'pw' | bridge cmd_source reauth docs --password-stdin --password-file "$B/pw")"; RC=$?
check "source reauth --password-stdin with --password-file: exit 2, nothing ran" "2 no" "$RC $([ -f "$B/argv" ] && echo yes || echo no)"
reset_bridge 0
OUT="$(printf 'pw' | bridge cmd_source check docs --password-stdin)"; RC=$?
check "--password-stdin on an action that takes no credential: exit 2, nothing ran" "2 no" "$RC $([ -f "$B/argv" ] && echo yes || echo no)"
has "...saying where it belongs" "--password-stdin is for exakit source reauth" "$OUT"

# Security review 1: what is not UTF-8 or UTF-16 text is refused BEFORE a shell
# variable takes it. $( ) drops NUL bytes without a word: UTF-16 with a stray
# byte, or without its BOM, became another credential (measured: '慰獳', 'pass').
reset_bridge 0 0 0
OUT="$(printf '\377\376p\000a\000s\000s\000\n' | bridge cmd_connect pg --name sales --set host=h --password-stdin --yes)"; RC=$?
check "review 1: UTF-16 with a stray byte on stdin: exit 2, before anything ran" "2 no" "$RC $([ -f "$B/argv" ] && echo yes || echo no)"
has "...saying it is not UTF-8 or UTF-16 text" "The credential is not UTF-8 or UTF-16 text" "$OUT"
printf 'p\000a\000s\000s\000\n\000' > "$B/bomless16.pw"
reset_bridge 0 0 0
OUT="$(bridge cmd_connect pg --name sales --set host=h --password-file "$B/bomless16.pw" --yes </dev/null)"; RC=$?
check "review 1: a BOM-less UTF-16 --password-file (NUL bytes): exit 2, no connect" "2 resolve pg|plan postgresql --name sales --set host=h|" "$RC $(tr '\n' '|' < "$B/argv")"
reset_bridge 0 1
OUT="$(printf 'p\000w' | bridge cmd_source reauth docs --password-stdin)"; RC=$?
check "review 1: a NUL on stdin for reauth: exit 2, no reauth" "2 show docs|" "$RC $(tr '\n' '|' < "$B/argv")"

# Security review 2: a credential given as an option is refused by name, on
# connect and on source, and no option's =value is ever repeated.
for args in "cmd_connect pg --name sales --password-stdin=hunter2" "cmd_connect pg --name sales --passwd=hunter2" \
            "cmd_connect pg --name sales --password-file=hunter2" "cmd_source reauth docs --password=hunter2" \
            "cmd_source reauth docs --secret hunter2" "cmd_source check docs --token=hunter2"; do
    reset_bridge 0
    # shellcheck disable=SC2086
    OUT="$(bridge $args </dev/null)"; RC=$?
    check "review 2: $(printf '%s' "$args" | sed 's/hunter2/<v>/'): exit 2, before anything ran" "2 no" "$RC $([ -f "$B/argv" ] && echo yes || echo no)"
    has "...as a credential given as an argument" "A credential is never taken as an argument" "$OUT"
    lacks "...without repeating it" "hunter2" "$OUT"
done
for args in "cmd_connect pg --name sales --bogus=hunter2" "cmd_source list --bogus=hunter2"; do
    reset_bridge 0
    # shellcheck disable=SC2086
    OUT="$(bridge $args </dev/null)"; RC=$?
    check "review 2: an unknown option with =value: exit 2 ($args)" "2" "$RC"
    has "...its name said" "Unknown option '--bogus' for" "$OUT"
    lacks "...its value not" "hunter2" "$OUT"
done

# Security review 5: a name that holds the credential, exported (even empty)
# before exakit ran, stays exported when assigned - every child would see it.
# The control first: this bash does keep the export.
check "review 5 control: bash keeps an exported name exported when it is assigned" "1" \
    "$( (export _evctl=; _evctl=val; env | grep -c '^_evctl=val') )"
reset_bridge 0 0 0
OUT="$(printf 'Exp0rted-Val' | env EXAKIT_VS_STDIN_SECRET= _cc_secret= _evx_secret= _erh_value= \
    bash -c '. "$1"; shift; bridge "$@"' _ "$WORK/bridge-fn.sh" cmd_connect pg --name sales --set host=h --password-stdin --yes)" 2>/dev/null
check "review 5: names exported empty: the credential reached the engine on stdin" "same" "$(same 'Exp0rted-Val' "$B/stdin")"
check "...and is in no child's environment" "0" "$(grep -c 'Exp0rted-Val' "$B/env")"
reset_bridge 0 0
OUT="$(printf 'Exp0rted-Val' | env _cs_secret= _evx_secret= bash -c '. "$1"; shift; bridge "$@"' _ "$WORK/bridge-fn.sh" cmd_source reauth docs --password-stdin)" 2>/dev/null
check "review 5: reauth, _cs_secret exported empty: in no child's environment" "1 0" "$(grep -c '^reauth' "$B/argv") $(grep -c 'Exp0rted-Val' "$B/env")"

# Security review 12: under bash -x the credential is not in the trace.
traced() { set -x; "$@"; }
reset_bridge 0 0 0
OUT="$(printf 'Tr4ced-Val' | bridge traced cmd_connect pg --name sales --set host=h --password-stdin --yes)"
has "review 12: bash -x was on" "+ cmd_connect" "$OUT"
lacks "...and the credential is not in its trace" "Tr4ced-Val" "$OUT"
check "...which still reached the engine" "same" "$(same 'Tr4ced-Val' "$B/stdin")"

# exakit source list: one table, where each source lives and its TLS level,
# inside the terminal - columns give way rather than wrap.
LONGHOST="mydb.cluster-abc123def456.eu-west-1.rds.amazonaws.com"
printf 'RESULT {"sources": [{"name": "sales", "connector": "postgresql", "schema": "VS_SALES", "status": "ready", "last_check": {"at": "2026-11-09T10:22:33Z"}, "needs_refresh": false, "host": "pg.example.com", "tls": "verify"}, {"name": "orders", "connector": "mysql", "schema": "VS_ORDERS", "status": "auth-failed", "last_check": null, "needs_refresh": false, "host": "%s", "tls": "require"}, {"name": "old", "connector": "gone", "schema": "VS_OLD", "status": "ready", "last_check": null, "needs_refresh": false, "host": "", "tls": null}]}\n' "$LONGHOST" > "$B/rows"
reset_bridge 0
OUT="$(COLUMNS=200 bridge cmd_source list </dev/null)"
has "list on a wide terminal: every column, under a heading" "NAME    SOURCE      SCHEMA     HOST" "$OUT"
has "...a row names its host and TLS level, and when it was last checked" \
    "sales   postgresql  VS_SALES   pg.example.com" "$(printf '%s\n' "$OUT" | grep '^  sales')"
has "...TLS, then status" "verify   ready        2026-11-09 10:22" "$(printf '%s\n' "$OUT" | grep '^  sales')"
has "...a host in full when there is room" "$LONGHOST  require  auth-failed  never" "$OUT"
has "...a source whose connector is gone: no host, TLS n/a" "old     gone        VS_OLD     -" "$(printf '%s\n' "$OUT" | grep '^  old')"
has "...n/a" " n/a " "$(printf '%s\n' "$OUT" | grep '^  old')"
OUT="$(COLUMNS=80 bridge cmd_source list </dev/null)"
check "on 80 columns: every line fits (79, the last column unwritten)" "0" \
    "$(printf '%s\n' "$OUT" | awk 'length($0) > 79' | wc -l | tr -d ' ')"
check "...SCHEMA goes first, then LAST CHECK; HOST and TLS stay" "  NAME    SOURCE      HOST                                 TLS      STATUS" \
    "$(printf '%s\n' "$OUT" | grep '^  NAME')"
has "...then a long host is cut, marked ..." "mydb.cluster-abc123def456.eu-wes...  require  auth-failed" "$OUT"
has "...a short one kept whole" "  sales   postgresql  pg.example.com" "$OUT"
OUT="$(COLUMNS=60 bridge cmd_source list </dev/null)"
check "on 60 columns: the host is cut further, every line still fits" "0 1" \
    "$(printf '%s\n' "$OUT" | awk 'length($0) > 59' | wc -l | tr -d ' ') $(printf '%s\n' "$OUT" | grep -c 'mydb\.cluster\.\.\.  require')"
printf 'RESULT {"issues": [{"name": "orders", "connector": "mysql", "schema": "VS_ORDERS", "status": "auth-failed", "last_check": {"at": "2026-11-09T10:22:33Z"}, "needs_refresh": false, "host": "my.example.com", "tls": "require", "remedy": "the source rejected the credentials: exakit source reauth orders", "command": "exakit source reauth orders"}]}\n' > "$B/rows"
OUT="$(COLUMNS=80 bridge cmd_source issues </dev/null)"
has "issues: the same table, the fix on its own line under the row" \
    "    fix: the source rejected the credentials: exakit source reauth orders" "$OUT"
printf 'RESULT {"sources": []}\n' > "$B/rows"
OUT="$(COLUMNS=80 bridge cmd_source list </dev/null)"
check "no sources: (none), no heading" "  (none)" "$OUT"
rm -f "$B/rows"

printf '\n== a private CA (AWS RDS, Azure, a company CA) is trusted, not skipped ==\n'
# Measured live against RDS PostgreSQL 18 (ap-south-1): tls=verify fails with
# PKIX because the JVM does not hold Amazon's RDS roots. The certificate goes
# into the URL, because the loader's sandbox denies file reads.
CA="$WORK/ca"; mkdir -p "$CA"
mkca() {
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=$1" -keyout "$CA/$1.key" -out "$CA/$1.pem" \
        -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
}
mkca TestRootA; mkca TestRootB; mkca TestRootC
printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n' > "$CA/leaf.ext"
openssl req -newkey rsa:2048 -nodes -subj "/CN=127.0.0.1" -keyout "$CA/server.key" -out "$CA/server.csr" >/dev/null 2>&1
openssl x509 -req -in "$CA/server.csr" -CA "$CA/TestRootB.pem" -CAkey "$CA/TestRootB.key" -CAcreateserial -days 30 \
    -extfile "$CA/leaf.ext" -out "$CA/server.pem" >/dev/null 2>&1
cat "$CA/TestRootA.pem" "$CA/TestRootB.pem" > "$CA/bundle.pem"
cat "$CA/TestRootA.pem" "$CA/TestRootC.pem" > "$CA/wrong.pem"
printf 'not a certificate\n' > "$CA/garbage.pem"
CHOICE="$(python3 - "$ROOT" "$CA" <<'PYCA'
import os, socket, ssl, sys, threading
sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import tlsca
ca = sys.argv[2]
# A server that answers like PostgreSQL: SSLRequest, "S", then TLS.
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(os.path.join(ca, "server.pem"), os.path.join(ca, "server.key"))
lsock = socket.socket(); lsock.bind(("127.0.0.1", 0)); lsock.listen(32); port = lsock.getsockname()[1]
def serve():
    while True:
        try:
            conn, _ = lsock.accept()
            conn.recv(8); conn.sendall(b"S")
            with ctx.wrap_socket(conn, server_side=True) as tls:
                tls.recv(1)
        except Exception:
            pass
threading.Thread(target=serve, daemon=True).start()
pem = lambda n: tlsca.certificates(os.path.join(ca, n))
def run(certs, p=port, name="bundle.pem"):
    try:
        got = tlsca.choose(certs, "127.0.0.1", p, "postgres", name, timeout=3)
        return "B" if got == pem("TestRootB.pem")[0] else "A" if got == pem("TestRootA.pem")[0] else "?"
    except tlsca.CaError as e:
        return "ERR " + str(e)
print(len(pem("bundle.pem")))
print(run(pem("bundle.pem")))                               # B, found by handshake though A comes first
print(run(pem("TestRootA.pem")))                            # a single certificate is taken as given
print(run(pem("wrong.pem"), name="wrong.pem"))              # nothing in it signs the server
free = socket.socket(); free.bind(("127.0.0.1", 0)); closed = free.getsockname()[1]; free.close()
print(run(pem("bundle.pem"), p=closed))                     # cannot tell without reaching it
try:
    tlsca.certificates(os.path.join(ca, "garbage.pem")); print("read")
except tlsca.CaError as e:
    print("ERR " + str(e))
print(tlsca.url_value(pem("TestRootB.pem")[0])[:40])
PYCA
)"
check "a two-root bundle is read as two certificates" "2" "$(printf '%s\n' "$CHOICE" | sed -n 1p)"
check "...the one that signs the server is picked by a verified handshake, not by position" "B" "$(printf '%s\n' "$CHOICE" | sed -n 2p)"
check "a single certificate is taken as given (the database's own check judges it)" "A" "$(printf '%s\n' "$CHOICE" | sed -n 3p)"
has "a bundle with no signer is refused, and says so" "none of the 2 certificates in wrong.pem signs 127.0.0.1" "$(printf '%s\n' "$CHOICE" | sed -n 4p)"
has "a bundle against an unreachable server asks for the one root" "give the one root certificate instead" "$(printf '%s\n' "$CHOICE" | sed -n 5p)"
has "a file with no PEM certificate is refused" "holds no PEM certificate" "$(printf '%s\n' "$CHOICE" | sed -n 6p)"
check "the certificate survives URL decoding: only letters, digits and %XX (and -._~)" "-----BEGIN%20CERTIFICATE-----%0AMII" \
    "$(printf '%s\n' "$CHOICE" | sed -n 7p | cut -c1-35)"

db '{"sources": {"rds.example.com": {"tables": ["RENTAL"]}}}'
RDS_SET="--set host=rds.example.com --set database=pagila --set user=reader"
run plan pg --name rds $RDS_SET --set ca="$CA/missing.pem"
check "a CA file that is not there: exit 2" "2" "$RC"; has "...named" "cannot be read" "$OUT"
run plan pg --name rds $RDS_SET --set ca="$CA/TestRootA.pem" --set tls=require
check "a CA with tls=require is refused: it would read as a check that is not made" "2" "$RC"
has "...and says why" "needs tls=verify (not require)" "$OUT"
run plan pg --name rds $RDS_SET --set ca="$CA/bundle.pem"
has "the plan says which CA is trusted, and how one is chosen from a bundle" "trust the CA in $CA/bundle.pem for this source only (2 certificates" "$OUT"
run_secret "$SECRET" connect pg --name rds $RDS_SET --set ca="$CA/TestRootA.pem" --secret-stdin
check "connect with a CA: exit 0" "0" "$RC"
URL="$(dbq 'd["connections"]["EXAKIT_SRC_RDS"]["url"]')"
has "...the URL verifies host and chain against that CA" "?sslmode=verify-full&sslfactory=org.postgresql.ssl.SingleCertValidatingFactory&sslfactoryarg=-----BEGIN%20CERTIFICATE-----%0A" "$URL"
lacks "...and never falls back to the JVM's public CAs" "DefaultJavaSSLFactory" "$URL"
check "...the certificate is kept with the source" "yes" \
    "$(python3 -c 'import json,sys; print("yes" if "BEGIN CERTIFICATE" in json.load(open(sys.argv[1])).get("tls_ca", "") else "no")' "$HOME_K/sources/rds/config.json")"
run show rds; lacks "...but show does not dump it" "BEGIN CERTIFICATE" "$OUT"
mv "$CA/TestRootA.pem" "$CA/moved.pem"
run_secret "$NEWSECRET" reauth rds --secret-stdin
check "reauth after the CA file moved: the kept certificate is used, exit 0" "0" "$RC"
has "...in the replaced CONNECTION too" "SingleCertValidatingFactory" "$(dbq 'd["connections"]["EXAKIT_SRC_RDS"]["url"]')"
run remove rds; check "...and it removes cleanly" "0" "$RC"

REMEDIES="$(python3 - "$ROOT" <<'PYR'
import json, sys
sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import lifecycle
pg = json.load(open(sys.argv[1] + "/setup/virtual-schemas/connectors/postgresql/connector.json"))
sf = json.load(open(sys.argv[1] + "/setup/virtual-schemas/connectors/snowflake/connector.json"))
pkix = "E-VSPG-3: Unable to create PostgreSQL remote metadata reader. Caused by: 'SSL error: (certificate_unknown) PKIX path building failed: sun.security.provider.certpath.SunCertPathBuilderException: unable to find valid certification path to requested target'"
clock = "E-VSPG-3: ... 'SSL error: (bad_certificate) PKIX path validation failed: java.security.cert.CertPathValidatorException: validity check failed'"
print(lifecycle.tls_remedy(pkix, pg))
print(lifecycle.tls_remedy(clock, pg))
print(lifecycle.tls_remedy(pkix, sf))
PYR
)"
has "an untrusted CA (measured on RDS) points at --set ca" "download that CA as PEM and give it with --set ca=<file>" "$(printf '%s\n' "$REMEDIES" | sed -n 1p)"
has "a validity failure (measured: the clock after the laptop hibernated) points at the restart" "exakit stop, then exakit start" "$(printf '%s\n' "$REMEDIES" | sed -n 2p)"
check "...a connector without a ca input is not told to use one" "None" "$(printf '%s\n' "$REMEDIES" | sed -n 3p)"
db '{"sources": {"rds.example.com": {"tables": ["RENTAL"], "fail": "tls"}}}'
run_secret "$SECRET" connect pg --name rds $RDS_SET --secret-stdin
check "connect to a private-CA source without ca: exit 1, nothing kept" "1 {}" "$RC $(dbq 'd["connections"]')"
has "...and the fix is named" "give it with --set ca=<file>, then connect again" "$OUT"

printf '\n== a database clock left behind by a sleeping laptop ==\n'
# Measured on Exasol Personal (macOS): the VM's clock does not catch up after
# the Mac sleeps (32 min to 2 h 26 min behind), and an RDS certificate issued
# that morning failed as "validity check failed". connect and check measure it.
check "with the skew measured, a validity failure names it instead of guessing" \
    "the database clock is 33 min behind this computer, so the certificate is outside its validity dates by it - restart the database (exakit stop, then exakit start) and retry" \
    "$(python3 - "$ROOT" <<'PYC'
import json, sys
sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import lifecycle
pg = json.load(open(sys.argv[1] + "/setup/virtual-schemas/connectors/postgresql/connector.json"))
print(lifecycle.tls_remedy("PKIX path validation failed: java.security.cert.CertPathValidatorException: validity check failed",
                           pg, lifecycle.clock_words(-1955)))
PYC
)"
db '{"clock_skew": -1955, "sources": {"rds.example.com": {"tables": ["RENTAL"], "fail": "tls-validity"}}}'
run_secret "$SECRET" connect pg --name rds $RDS_SET --set ca="$CA/moved.pem" --secret-stdin
check "a certificate outside its dates by a clock 33 min behind: exit 1, nothing kept" "1 {}" "$RC $(dbq 'd["connections"]')"
has "...connect warns about the clock before it creates anything" "The database clock is 33 min behind this computer" "$OUT"
has "...and the fix is the restart, with the measured cause" "the database clock is 33 min behind this computer, so the certificate is outside its validity dates by it" "$OUT"
db '{"clock_skew": -1955, "sources": {"rds.example.com": {"tables": ["RENTAL"]}}}'
run_secret "$SECRET" connect pg --name rds $RDS_SET --set ca="$CA/moved.pem" --secret-stdin
check "a source whose certificate is still in date connects anyway: exit 0" "0" "$RC"
has "...with the warning" "Restart the database (exakit stop, then exakit start) to resync it" "$OUT"
run check rds
has "source check warns too" "The database clock is 33 min behind this computer" "$OUT"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["clock_skew"]=3; d["statements"]=[]; json.dump(d, open(sys.argv[1], "w"))' "$STATE"
run check rds
check "a clock in sync: check exit 0" "0" "$RC"
lacks "...and no clock warning" "database clock" "$OUT"
check "the clock is asked once per run" "1" "$(dbq 'sum(1 for s in d["statements"] if s == "SELECT POSIX_TIME() AS T")')"
run remove rds; check "...and it removes cleanly" "0" "$RC"

printf '\n== a private CA for MySQL: a truststore file both readers find ==\n'
# Measured on Exasol Personal: the adapter (a UDF) starts in "/" and sees the
# bucket at /buckets/...; the MySQL loader resolves the same relative path
# under its driver folder (/exa/jdbc/MYSQL), where the kit puts a copy.
check "the truststore is a JKS: magic, version 2, two trusted entries, digest over the empty password" "ok" \
    "$(python3 - "$ROOT" "$CA/bundle.pem" <<'PYJ'
import hashlib, struct, sys
sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import tlsca
data = tlsca.jks(tlsca.certificates(sys.argv[2]))
magic, version, count = struct.unpack(">III", data[:12])
tags = data.count(struct.pack(">I", 2) + struct.pack(">H", len("exakit-ca-0")))
ok = (magic, version, count) == (0xFEEDFEED, 2, 2) and data[-20:] == hashlib.sha1(b"Mighty Aphrodite" + data[:-20]).digest()
print("ok" if ok and tags >= 2 else "bad %x %d %d %d" % (magic, version, count, tags))
PYJ
)"
MY_SET="--set host=my.example.com --set database=sakila --set user=reader"
db '{"sources": {"my.example.com": {"tables": ["rental"]}}}'
run plan mysql --name my $MY_SET --set ca="$CA/bundle.pem"
has "the plan says the whole bundle becomes a truststore (no handshake needed)" "(2 certificates, in a truststore for the adapter and the loader)" "$OUT"
run_secret "$SECRET" connect mysql --name my $MY_SET --set ca="$CA/bundle.pem" --secret-stdin
check "MySQL with a CA bundle: exit 0, with no handshake from this computer (my.example.com is not reachable)" "0" "$RC"
REL="buckets/bfsdefault/default/exakit/vs/tls/my.jks"
has "...the URL verifies identity against the truststore by its relative path" \
    "sslMode=VERIFY_IDENTITY&trustCertificateKeyStoreUrl=file:$REL&trustCertificateKeyStoreType=JKS" \
    "$(dbq 'd["connections"]["EXAKIT_SRC_MY"]["url"]')"
check "...one copy in the bucket for the adapter, one under the loader at the same relative path, identical" "yes" \
    "$(cmp -s "$EXA/bucketfs/bfsdefault/default/exakit/vs/tls/my.jks" "$EXA/jdbc/MYSQL/$REL" && echo yes || echo no)"
run_secret "$NEWSECRET" reauth my --secret-stdin
has "reauth keeps the truststore in the URL" "trustCertificateKeyStoreUrl=file:$REL" "$(dbq 'd["connections"]["EXAKIT_SRC_MY"]["url"]')"
run remove my
check "remove deletes both copies (and the loader's now-empty folders)" "0 gone gone" \
    "$RC $([ -e "$EXA/bucketfs/bfsdefault/default/exakit/vs/tls/my.jks" ] && echo kept || echo gone) $([ -e "$EXA/jdbc/MYSQL/buckets" ] && echo kept || echo gone)"
db '{"sources": {"my.example.com": {"tables": ["rental"], "fail": "tls"}}}'
run_secret "$SECRET" connect mysql --name my $MY_SET --set ca="$CA/bundle.pem" --secret-stdin
check "a MySQL connect that fails leaves no truststore behind" "1 gone gone" \
    "$RC $([ -e "$EXA/bucketfs/bfsdefault/default/exakit/vs/tls/my.jks" ] && echo kept || echo gone) $([ -e "$EXA/jdbc/MYSQL/buckets" ] && echo kept || echo gone)"
printf '\n== a private CA for SQL Server: the kit'"'"'s TLS helper class ==\n'
# Measured on Exasol Personal: the SQL Server loader starts in / of the
# database container, so no file path reaches both readers; mssql-jdbc's
# trustManagerClass carries the CA in the URL instead. The helper is built by
# the database's Java (faked here) from setup/virtual-schemas/java/.
MS_SET="--set host=ms.example.com --set database=erp --set user=reader"
db '{"sources": {"ms.example.com": {"tables": ["ORDERS"]}}}'
rm -rf "$HOME_K/cache/virtual-schemas/tls-helper"
run plan mssql --name ms $MS_SET --set ca="$CA/bundle.pem"
has "the plan names the helper and the host check" "(2 certificates, checked with the host name by the kit's TLS helper class)" "$OUT"
run_secret "$SECRET" connect mssql --name ms $MS_SET --set ca="$CA/bundle.pem" --secret-stdin
check "SQL Server with a CA bundle: exit 0 (no handshake from this computer: ms.example.com is not reachable)" "0" "$RC"
URL="$(dbq 'd["connections"]["EXAKIT_SRC_MS"]["url"]')"
has "...the URL names the helper class, with the host it must check" \
    "encrypt=true;trustServerCertificate=false;trustManagerClass=exakit.tls.PemTrustManager;trustManagerConstructorArg=ms.example.com|" "$URL"
check "...both certificates, as base64url DER, and nothing a ;-separated URL would split" "2 ok" \
    "$(printf '%s' "${URL#*trustManagerConstructorArg=ms.example.com|}" | awk -F. '{print NF}') $(printf '%s' "${URL#*trustManagerConstructorArg=}" | grep -q '^[A-Za-z0-9_.|-]*$' && echo ok || echo bad)"
lacks "...and no truststore file" "trustStore=" "$URL"
MS_ADAPTER="$(dbq '[s for s in d["statements"] if "ADAPTER SCRIPT" in s and "ADAPTER_MS" in s][0]')"
has "...the helper jar is on the adapter's classpath" "/exakit/vs/sqlserver/tls-helper-" "$MS_ADAPTER"
check "...and on the loader's, as a second JAR= beside the driver" "JAR=exakit-tls.jar yes" \
    "$(grep -x 'JAR=exakit-tls.jar' "$EXA/jdbc/SQLSERVER/settings.cfg") $([ -f "$EXA/jdbc/SQLSERVER/exakit-tls.jar" ] && echo yes || echo no)"
check "...built once in the database, and its build script dropped" "1 no" \
    "$(dbq 'd.get("tls_builds", 0)') $(dbq '"EXAKIT_VS.EXAKIT_TLS_BUILD" in d["scripts"]' | tr A-Z a-z | sed 's/true/yes/;s/false/no/')"
python3 - "$STATE" <<'PYS'
import json, sys
d = json.load(open(sys.argv[1])); d["sources"]["ms2.example.com"] = {"tables": ["ITEMS"]}; json.dump(d, open(sys.argv[1], "w"))
PYS
run_secret "$SECRET" connect mssql --name ms2 --set host=ms2.example.com --set database=erp --set user=reader --secret-stdin
check "a second SQL Server source (no ca): exit 0, the cached helper is reused, not rebuilt" "0 1" "$RC $(dbq 'd.get("tls_builds", 0)')"
has "...it verifies with the default store, as before" "encrypt=true;trustServerCertificate=false;hostNameInCertificate=ms2.example.com" "$(dbq 'd["connections"]["EXAKIT_SRC_MS2"]["url"]')"
run_secret "$NEWSECRET" reauth ms --secret-stdin
has "reauth keeps the helper and the certificates in the URL" "trustManagerConstructorArg=ms.example.com|" "$(dbq 'd["connections"]["EXAKIT_SRC_MS"]["url"]')"
run remove ms
check "removing one source keeps the helper the other still uses" "0 yes" "$RC $([ -f "$EXA/jdbc/SQLSERVER/exakit-tls.jar" ] && echo yes || echo no)"
run remove ms2
check "the last one out removes the helper and the loader folder" "0 gone" "$RC $([ -e "$EXA/jdbc/SQLSERVER" ] && echo kept || echo gone)"
rm -rf "$HOME_K/cache/virtual-schemas/tls-helper"
db '{"sources": {"ms.example.com": {"tables": ["ORDERS"]}}, "tls_compiler": false}'
run_secret "$SECRET" connect mssql --name ms $MS_SET --set ca="$CA/bundle.pem" --secret-stdin
check "no Java compiler in the database: exit 1, said so, nothing kept" "1 {} gone" \
    "$RC $(dbq 'd["connections"]') $([ -e "$EXA/jdbc/SQLSERVER" ] && echo kept || echo gone)"
has "...the reason" "the kit's TLS helper could not be built in the database: no Java compiler" "$OUT"
check "the helper jar is deterministic: the same classes give the same bytes" "same" \
    "$(python3 - "$ROOT" <<'PYD'
import sys; sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import tlshelper
a = tlshelper.package({"exakit/tls/PemTrustManager.class": b"x"}); b = tlshelper.package({"exakit/tls/PemTrustManager.class": b"x"})
print("same" if a == b else "differs")
PYD
)"
check "the helper's source ships as ASCII text, no binary" "0" \
    "$(LC_ALL=C grep -c '[^[:print:][:space:]]' "$ROOT/setup/virtual-schemas/java/exakit/tls/PemTrustManager.java")"
E6="$(python3 - "$ROOT" <<'PYE'
import json, sys
sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import lifecycle
load = lambda c: json.load(open(sys.argv[1] + "/setup/virtual-schemas/connectors/%s/connector.json" % c))
text = "ETL-5402: ... Error: (internal_error) Unexpected error: java.security.InvalidAlgorithmParameterException: the trustAnchors parameter must be non-empty."
print(lifecycle.tls_remedy(text, load("sqlserver")))
print(lifecycle.tls_remedy(text, load("snowflake")))
print(lifecycle.tls_remedy(text, load("mysql")))
import sql
print(sql.classify(text))
PYE
)"
has "the loader's empty CA store (measured, Exasol Personal) is explained, with --set ca where it exists" \
    "has no CA store of its own (an Exasol Personal issue)" "$(printf '%s\n' "$E6" | sed -n 1p)"
has "...for SQL Server now: give the CA" "give the CA as PEM with --set ca=<file>" "$(printf '%s\n' "$E6" | sed -n 1p)"
has "...for Snowflake (no ca, no tls choice): says it cannot connect here, offers no require" "always verifies and its driver reads trust only from that store" "$(printf '%s\n' "$E6" | sed -n 2p)"
lacks "...and does not offer tls=require, which Snowflake does not have" "tls=require" "$(printf '%s\n' "$E6" | sed -n 2p)"
has "...MySQL keeps the ca advice" "give the CA as PEM with --set ca=<file>" "$(printf '%s\n' "$E6" | sed -n 3p)"
check "...and the error is filed as TLS, so the remedy is shown (measured: Snowflake fell to 'see the log')" "tls" "$(printf '%s\n' "$E6" | sed -n 4p)"

printf '\n== Snowflake: the loader trusts the container'"'"'s CA store ==\n'
# Measured on Exasol Personal 2.3.0 against a real account: the JDBC loader's
# Java trusts nothing ("trustAnchors parameter must be non-empty"), and the
# Snowflake driver reads trust only from the JVM's default store. With the
# kit's exakit.loader.TrustStoreDriver as the loader's main class, the same
# import reached Snowflake's sign-in. The fake fails a Snowflake read unless
# that main class and its jar are registered (loader_cacerts false).
SF_SET="--set account=myorg-acct1 --set database=SALES --set warehouse=COMPUTE_WH --set user=READER"
SFLOADER="$EXA/jdbc/SNOWFLAKE_JDBC_DRIVER"
db '{"loader_cacerts": false, "sources": {"myorg-acct1.snowflakecomputing.com": {"tables": ["ORDERS"]}}}'
run_secret "$SECRET" connect snowflake --name sf $SF_SET --secret-stdin
check "Snowflake on a loader without a CA store: exit 0" "0" "$RC"
has "...the loader is registered trusting the container's CA store" "registered for IMPORT FROM JDBC (trusting the language container's CA store)" "$OUT"
has "...its main class is the kit's, which hands over to the Snowflake driver" "DRIVERMAIN=exakit.loader.TrustStoreDriver" "$(cat "$SFLOADER/settings.cfg")"
has "...the Snowflake driver stays on the loader's classpath" "JAR=snowflake-jdbc-4.4.0.jar" "$(cat "$SFLOADER/settings.cfg")"
has "...with the kit's jar beside it" "JAR=exakit-loader.jar" "$(cat "$SFLOADER/settings.cfg")"
check "...which is staged there" "yes" "$([ -f "$SFLOADER/exakit-loader.jar" ] && echo yes || echo no)"
check "...built once in the database, the build script dropped" "1 no" \
    "$(dbq 'd.get("tls_builds", 0)') $(dbq '"EXAKIT_VS.EXAKIT_TLS_BUILD" in d["scripts"]' | tr A-Z a-z | sed 's/true/yes/;s/false/no/')"
run_secret "$SECRET" connect snowflake --name sf2 $SF_SET --set role=ANALYST --secret-stdin
check "a second Snowflake source: exit 0, the cached jar is reused, not rebuilt" "0 1" "$RC $(dbq 'd.get("tls_builds", 0)')"
has "...a role, when given, rides in the URL" "JDBC_QUERY_RESULT_FORMAT=JSON&role=ANALYST" "$(dbq 'd["connections"]["EXAKIT_SRC_SF2"]["url"]')"
lacks "...and none is sent when it is not" "role=" "$(dbq 'd["connections"]["EXAKIT_SRC_SF"]["url"]')"
run plan snowflake --name sf3 $SF_SET --set "role=A&warehouse=X"
check "...a role cannot add URL parameters (exit 2)" "2" "$RC"
run remove sf
check "removing one keeps the loader for the other" "yes yes" \
    "$([ -f "$SFLOADER/exakit-loader.jar" ] && echo yes || echo no) $([ -f "$SFLOADER/settings.cfg" ] && echo yes || echo no)"
run remove sf2
check "...the last one out removes the loader's jar and settings" "no no" \
    "$([ -f "$SFLOADER/exakit-loader.jar" ] && echo yes || echo no) $([ -f "$SFLOADER/settings.cfg" ] && echo yes || echo no)"
LOADERSRC="$ROOT/setup/virtual-schemas/java/exakit/loader/TrustStoreDriver.java"
check "the loader class ships as ASCII source, no binary" "0" "$(LC_ALL=C grep -c '[^[:print:][:space:]]' "$LOADERSRC")"
check "...defines no trust manager and disables nothing: it only names the CA store" "0" \
    "$(grep -c -E 'TrustManager|checkServerTrusted|HostnameVerifier|setDefault|insecure' "$LOADERSRC")"
has "...and never overrides a trust store someone already set" 'System.getProperty("javax.net.ssl.trustStore") == null' "$(cat "$LOADERSRC")"

printf '\n== BigQuery: the key as this source'"'"'s file in BucketFS ==\n'
# Measured against a real project (exakittest): the driver takes the key only
# as a file (OAuthPvtKeyPath) - in the CONNECTION's password it is refused -
# reads a 600 file in BucketFS, and needs the account's e-mail in the URL.
bqkey() { python3 - "$1" "$2" "$3" <<'PYK'
import json, sys
json.dump({"type": "service_account", "project_id": "proj", "private_key_id": sys.argv[2],
           "private_key": "-----BEGIN PRIVATE KEY-----\nMIIfakeKEYbody%s\n-----END PRIVATE KEY-----\n" % sys.argv[2],
           "client_email": sys.argv[3], "client_id": "1"}, open(sys.argv[1], "w"), indent=2)
PYK
}
bqkey "$WORK/bq1.json" kid1 reader@proj.iam.gserviceaccount.com
bqkey "$WORK/bq2.json" kid2 reader@proj.iam.gserviceaccount.com
BQ_SET="--set project=proj --set dataset=sales"
BQKEY="$EXA/bucketfs/bfsdefault/default/exakit/vs/keys/bq.json"
bqdb() { db '{"sources": {"www.googleapis.com": {"tables": ["customers", "orders"], "key_id": "'"$1"'"}}'"${2:-}"'}'; }
bqdb kid1
OUT="$(eng connect bigquery --name bq $BQ_SET --secret-stdin < "$WORK/bq1.json" 2>&1)"; RC=$?
check "BigQuery with its key file: exit 0" "0" "$RC"
has "...the key is staged as this source's file" "Key file staged for bq (owner-only on this computer)" "$OUT"
has "...and the CONNECTION is said to hold its path, not the key" "Connection EXAKIT_SRC_BQ created (it names the key file, not the key)" "$OUT"
BQURL="$(dbq 'd["connections"]["EXAKIT_SRC_BQ"]["url"]')"
has "...the URL names the account and the file's path" \
    "OAuthServiceAcctEmail=reader@proj.iam.gserviceaccount.com;OAuthPvtKeyPath=/buckets/bfsdefault/default/exakit/vs/keys/bq.json" "$BQURL"
lacks "...never the key" "PRIVATE KEY" "$BQURL"
check "...the CONNECTION has no user and no password" '["", ""]' "$(dbq '[d["connections"]["EXAKIT_SRC_BQ"]["user"], d["connections"]["EXAKIT_SRC_BQ"]["secret"]]')"
check "...the file is owner-only on this computer" "600" "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$BQKEY")"
check "...and holds the key as given" "kid1" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["private_key_id"])' "$BQKEY")"
lacks "...the private key is not printed" "MIIfakeKEYbody" "$OUT"
lacks "...nor recorded with the source" "MIIfakeKEYbody" "$(cat "$HOME_K"/sources/bq/*.json 2>/dev/null)"
lacks "...and nobody else may create scripts on a fresh kit, so no warning" "may create scripts" "$OUT"

python3 - "$STATE" <<'PYP'
import json, sys
d = json.load(open(sys.argv[1]))
d.update({"users": ["SYS", "MCP_READONLY", "ALICE", "BOB", "CAROL"],
          "role_privs": [["SYS", "DBA"], ["ALICE", "PREPROC_ADMIN"], ["BOB", "ANALYSTS"], ["ANALYSTS", "DEVS"], ["CAROL", "DBA"]],
          "script_privs": ["DBA", "PREPROC_ADMIN", "DEVS"]})
json.dump(d, open(sys.argv[1], "w"))
PYP
run check bq
has "check names who may create scripts, through nested roles, admins left out" "may: ALICE, BOB" "$OUT"
has "...and what to do" "Revoke CREATE SCRIPT from them" "$OUT"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["script_privs"]=["DBA","PUBLIC"]; json.dump(d, open(sys.argv[1],"w"))' "$STATE"
run check bq
has "a grant to PUBLIC names every non-admin user" "may: ALICE, BOB, MCP_READONLY" "$OUT"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); [d.pop(k) for k in ("users","role_privs","script_privs")]; json.dump(d, open(sys.argv[1],"w"))' "$STATE"

OUT="$(eng reauth bq --secret-stdin < "$WORK/bq2.json" 2>&1)"; RC=$?
check "reauth with a different key the source refuses: exit 1" "1" "$RC"
has "...the previous key is kept" "the source refused the new key, so the previous one was kept" "$OUT"
check "...on disk too, so the source still works" "kid1 ready" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["private_key_id"])' "$BQKEY") $(eng --json check bq 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["sources"]["www.googleapis.com"]["key_id"]="kid2"; json.dump(d, open(sys.argv[1],"w"))' "$STATE"
OUT="$(eng reauth bq --secret-stdin < "$WORK/bq2.json" 2>&1)"; RC=$?
check "reauth with the key the source accepts: exit 0" "0" "$RC"
check "...the file now holds it, still owner-only" "kid2 600" \
    "$(python3 -c 'import json,os,sys; print(json.load(open(sys.argv[1]))["private_key_id"], oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$BQKEY")"

run disconnect bq --dry-run
has "disconnect plans to drop the key file with the CONNECTION" "the key file /buckets/bfsdefault/default/exakit/vs/keys/bq.json" "$OUT"
run disconnect bq
check "...and does: a disconnected source keeps no key" "no" "$([ -f "$BQKEY" ] && echo yes || echo no)"
OUT="$(eng connect bigquery --name bq $BQ_SET --secret-stdin < "$WORK/bq2.json" 2>&1)"; RC=$?
check "reconnect with the key: exit 0, the file is back" "0 yes" "$RC $([ -f "$BQKEY" ] && echo yes || echo no)"
run remove bq
check "remove deletes the key file" "no" "$([ -f "$BQKEY" ] && echo yes || echo no)"

bqdb kid9
OUT="$(eng connect bigquery --name bq $BQ_SET --secret-stdin < "$WORK/bq1.json" 2>&1)"; RC=$?
check "a key the source refuses on first connect: exit 1, nothing kept" "1 {} no" "$RC $(dbq 'd["connections"]') $([ -f "$BQKEY" ] && echo yes || echo no)"
has "...said as a refused credential, the clock named as a cause" "a service-account sign-in is a token dated by the database's clock" "$OUT"
printf 'not json' > "$WORK/bqbad.json"
python3 -c 'import json,sys; json.dump({"type": "authorized_user", "client_id": "x"}, open(sys.argv[1], "w"))' "$WORK/bquser.json"
bqkey "$WORK/bqsemi.json" kid1 'a;OAuthPvtKeyPath=/x@proj.iam.gserviceaccount.com'
for case in "bqbad|must be the service-account key file" "bquser|is not a service-account key" "bqsemi|has no usable client_email"; do
    f="${case%%|*}"; want="${case#*|}"
    OUT="$(eng connect bigquery --name bq $BQ_SET --secret-stdin < "$WORK/$f.json" 2>&1)"; RC=$?
    check "$f is refused before anything is staged: exit 2, nothing kept" "2 {} no" "$RC $(dbq 'd["connections"]') $([ -f "$BQKEY" ] && echo yes || echo no)"
    has "...naming why" "$want" "$OUT"
done
BQCLS="$(python3 - "$ROOT" <<'PYC'
import sys
sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import sql
print(sql.classify("[Simba][JDBC](10100) Connection Refused: [Simba][JDBC](11640) Required Connection Key(s): OAuthPvtKeyPath"))
print(sql.classify("[Simba][BigQueryJDBCDriver](100004) HttpTransport IO error : Error getting access token for service account: 400 Bad Request"))
PYC
)"
check "a missing URL property is configuration, not unreachable (measured: 'Connection Refused' misfiled it)" "error" "$(printf '%s\n' "$BQCLS" | sed -n 1p)"
check "a refused token request is a rejected credential" "auth" "$(printf '%s\n' "$BQCLS" | sed -n 2p)"

printf '\n== MongoDB (Profile D): a native adapter in the Rust language container ==\n'
# Measured against Atlas (exasol-mongodb-vs 0.1.3, language-container-rs
# 0.33.0, aarch64): the .so's entry points are bound to the script names
# MONGODB_ADAPTER and MONGODB_SCAN, so every MongoDB source shares them; CREATE
# reads the collection's metadata, so a wrong password fails there.
MG_URI="mongodb+srv://cluster0.example.net/?authSource=admin"
MG_SET="--set uri=$MG_URI --set database=sample_mflix --set user=reader"
mgdb() { db '{"sources": {"cluster0.example.net": {"tables": ["MOVIES", "MOVIES_imdb", "MOVIES_genres_arr"], "secret": "'"$SECRET"'", "collections": ["sample_mflix.movies", "sample_mflix.theaters"]}}'"${1:-}"'}'; }
mgdb
run plan mongodb --name mg $MG_SET --set collection=movies
check "plan: exit 0" "0" "$RC"
has "...the Rust language container, not Java, is the prerequisite" "verify the Rust language container in the database" "$OUT"
has "...the scripts are named and shared" "create adapter script EXAKIT_VS.MONGODB_ADAPTER and its scan UDF EXAKIT_VS.MONGODB_SCAN (shared by every MongoDB source)" "$OUT"
check "...the adapter is this machine's build" "1" "$(printf '%s' "$OUT" | grep -c -E 'exasol-mongodb-vs-0.1.3-linux-(aarch64|x86_64).so')"
OUT="$(EXAKIT_VS_ARCH=x86_64 eng plan mongodb --name mg $MG_SET --set collection=movies 2>&1)"
has "...and the x86_64 one on x86_64" "exasol-mongodb-vs-0.1.3-linux-x86_64.so" "$OUT"
OUT="$(EXAKIT_VS_ARCH=aarch64 eng plan mongodb --name mg $MG_SET --set collection=movies 2>&1)"
has "...and the aarch64 one on ARM" "exasol-mongodb-vs-0.1.3-linux-aarch64.so" "$OUT"
run plan mongodb --name mg --set "uri=mongodb://reader:pw@h:27017/" --set database=d --set collection=c --set user=reader
has "a URI carrying user:password@ is refused - the password belongs in the CONNECTION" "the MongoDB URI carries credentials" "$OUT"
run plan mongodb --name mg --set "uri=postgres://h/" --set database=d --set collection=c --set user=reader
has "...and a URI that is not MongoDB's" "is not a valid mongodb-uri" "$OUT"
# The adapter (0.1.3) signs in against admin whatever the URI says: a reader
# defined in another database could never log in, so its authSource is refused
# before anything is staged, not left to fail at connect.
run plan mongodb --name mg --set "uri=mongodb+srv://cluster0.example.net/?retryWrites=true&authSource=sales" \
    --set database=sample_mflix --set collection=movies --set user=reader
check "--set uri with authSource=sales: refused, exit 2" "2" "$RC"
has "...in one line: the adapter signs in against admin, and the fix" \
    "the MongoDB adapter always signs in against the admin database, so an authSource other than admin cannot work: make the reader a user of admin and drop authSource or set it to admin" "$OUT"
run plan mongodb --name mg --set "uri=mongodb+srv://cluster0.example.net/?AUTHSOURCE=Sales" --set database=d --set collection=c --set user=reader
check "...the option's name in any case" "2" "$RC"
run plan mongodb --name mg $MG_SET --set collection=movies
check "authSource=admin is accepted" "0" "$RC"
run plan mongodb --name mg --set "uri=mongodb+srv://cluster0.example.net/" --set database=sample_mflix --set collection=movies --set user=reader
check "...and so is no authSource" "0" "$RC"

mgdb ', "rust": false'
run_secret "$SECRET" connect mongodb --name mg $MG_SET --set collection=movies --secret-stdin
check "without the Rust container: exit 23 (the shell offers to install it), nothing created" "23 {} {}" "$RC $(dbq 'd["connections"]') $(dbq 'd["virtual"]')"
has "...said plainly" "the Rust language container is not installed in the database (no RUST language alias)" "$OUT"

mgdb
run_secret "$SECRET" connect mongodb --name mg $MG_SET --set collection=movies --secret-stdin
check "connect: exit 0" "0" "$RC"
has "...the collection's tables" "Virtual schema VS_MG: 3 table(s)" "$OUT"
check "a native adapter has no Java probe to ask: the staged .so is given the settle time instead" "0" \
    "$(dbq 'sum("EXAKIT_FILES_PROBE_V1(" in s for s in d["statements"])')"
check "...the CONNECTION holds the URI, the user and the password" "[\"$MG_URI\", \"reader\", true]" \
    "$(dbq '[d["connections"]["EXAKIT_SRC_MG"]["url"], d["connections"]["EXAKIT_SRC_MG"]["user"], d["connections"]["EXAKIT_SRC_MG"]["secret"] == "'"$SECRET"'"]')"
MGA="$(dbq '[x for x in d["statements"] if "RUST ADAPTER SCRIPT" in x][-1]')"
has "...the adapter script keeps the name the .so exports" 'CREATE OR REPLACE RUST ADAPTER SCRIPT "EXAKIT_VS"."MONGODB_ADAPTER" AS' "$MGA"
has "...and loads the staged .so" '%udf_object /buckets/bfsdefault/default/exakit/vs/mongodb/0.1.3/exasol-mongodb-vs-0.1.3-linux-' "$MGA"
has "...the scan UDF too" 'CREATE OR REPLACE RUST SCALAR SCRIPT "EXAKIT_VS"."MONGODB_SCAN"(spec VARCHAR(2000000)) EMITS (...) AS' \
    "$(dbq '[x for x in d["statements"] if "MONGODB_SCAN" in x][-1]')"
has "...the virtual schema names the connection the adapter's way" "MONGODB_CONNECTION = 'EXAKIT_SRC_MG' DATABASE = 'sample_mflix' COLLECTION = 'movies'" \
    "$(dbq '[x for x in d["statements"] if x.startswith("CREATE VIRTUAL SCHEMA \"VS_MG\"")][-1]')"
lacks "...the password is not printed" "$SECRET" "$OUT"
OUT="$(eng --json list 2>/dev/null)"
check "list --json: every row keeps its keys and adds host and tls, nothing renamed" \
    "connector host last_check name needs_refresh schema status tls" \
    "$(printf '%s' "$OUT" | python3 -c 'import json, sys; print(" ".join(sorted(set(k for s in json.load(sys.stdin)["sources"] for k in s))))')"
check "...a MongoDB source: the URI's host, and verify for mongodb+srv://" "cluster0.example.net verify" \
    "$(printf '%s' "$OUT" | python3 -c 'import json, sys; s = [s for s in json.load(sys.stdin)["sources"] if s["name"] == "mg"][0]; print(s["host"], s["tls"])')"

run_secret "$SECRET" connect mongodb --name mgt $MG_SET --set collection=theaters --secret-stdin
check "a second MongoDB source: exit 0, the two scripts shared, not doubled" "0 1 1" \
    "$RC $(dbq 'd["scripts"].count("EXAKIT_VS.MONGODB_ADAPTER")') $(dbq 'd["scripts"].count("EXAKIT_VS.MONGODB_SCAN")')"
run_secret "$SECRET" connect mongodb --name mgx $MG_SET --set collection=nope --secret-stdin
check "a collection that is not there (or not readable): exit 1, the shared scripts kept for the others" "1 1 1" \
    "$RC $(dbq 'd["scripts"].count("EXAKIT_VS.MONGODB_ADAPTER")') $(dbq 'd["scripts"].count("EXAKIT_VS.MONGODB_SCAN")')"
has "...the adapter's words, and what they can mean" "a database the account may not read as a collection that 'does not exist'" "$OUT"

python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["sources"]["cluster0.example.net"]["secret"]="n3w-secret"; json.dump(d, open(sys.argv[1],"w"))' "$STATE"
run_secret "still-the-old-one" reauth mg --secret-stdin
check "reauth with a password the source refuses: exit 1" "1" "$RC"
has "...tried on a throwaway schema first, so the old one is kept" "the source refused the new credential, so the previous one was kept" "$OUT"
check "...nothing pending is left behind" "[] []" \
    "$(dbq '[c for c in d["connections"] if c.startswith("EXAKIT_PENDING_")]') $(dbq '[v for v in d["virtual"] if v.startswith("EXAKIT_PENDING_")]')"
check "...and the CONNECTION still holds the old password" "true" "$(dbq 'd["connections"]["EXAKIT_SRC_MG"]["secret"] == "'"$SECRET"'"')"
run_secret "n3w-secret" reauth mg --secret-stdin
check "reauth with the password the source accepts: exit 0" "0" "$RC"
has "...accepted on the trial, then replaced" "The source accepted the new credential" "$OUT"
# The Rust container runs the same /exaudf/exaudfclient: on Exasol Personal
# 2.4 a Rust source whose container is gone answers in Java's words. Every
# path that passes the database's kind on says Rust for a Rust adapter.
RUST24="VM error: The required executable '/exaudf/exaudfclient' does not exist in BucketFS"
kindof() { python3 -c 'import json,sys; print(json.load(sys.stdin)["kind"])'; }
python3 - "$STATE" "$RUST24" <<'PY'
import json, sys; d = json.load(open(sys.argv[1])); d["refresh_fail"] = ["VS_MG"]; d["refresh_error"] = sys.argv[2]; json.dump(d, open(sys.argv[1], "w"))
PY
check "a Rust source's refresh, its container gone: norust, not the Java fix" "norust" "$(eng --json refresh mg 2>/dev/null | kindof)"
python3 - "$STATE" "$RUST24" <<'PY'
import json, sys; d = json.load(open(sys.argv[1])); d.pop("refresh_fail"); d.pop("refresh_error"); d["vs_fail"] = sys.argv[2]; json.dump(d, open(sys.argv[1], "w"))
PY
check "...its reauth (a throwaway schema on the Rust adapter): norust too" "norust" \
    "$(printf '%s' "n3w-secret" | eng --json reauth mg --secret-stdin 2>/dev/null | kindof)"
python3 - "$STATE" <<'PY'
import json, sys; d = json.load(open(sys.argv[1])); d.pop("vs_fail"); json.dump(d, open(sys.argv[1], "w"))
PY

run_secret "wrong" connect mongodb --name mgbad $MG_SET --set collection=movies --secret-stdin
check "a wrong password on first connect: exit 1, nothing of its own kept" "1 false" "$RC $(dbq '"EXAKIT_SRC_MGBAD" in d["connections"]' | tr A-Z a-z)"
has "...the adapter's vague words come with what they can mean" "check the user and password, the access list and the database's role" "$OUT"

run remove mg --dry-run
lacks "removing one: the shared adapter is not in its plan" "MONGODB_ADAPTER" "$OUT"
run remove mg
check "...removed, the scripts kept for the other source" "0 1 1" \
    "$RC $(dbq 'd["scripts"].count("EXAKIT_VS.MONGODB_ADAPTER")') $(dbq 'd["scripts"].count("EXAKIT_VS.MONGODB_SCAN")')"
run remove mgt --dry-run
has "the last one out plans to drop the shared adapter" "adapter script EXAKIT_VS.MONGODB_ADAPTER (no other mongodb source uses it)" "$OUT"
has "...and the scan UDF" "import script EXAKIT_VS.MONGODB_SCAN (no other mongodb source uses it)" "$OUT"
run remove mgt
check "...and drops both" "[]" "$(dbq '[s for s in d["scripts"] if "MONGODB" in s]')"

printf '\n== a fresh database: MongoDB first, nothing else connected ==\n'
# Every adapter script goes into EXAKIT_VS, which only the Java probes made: a
# MongoDB source asks neither (no host, a Rust profile), so on a fresh
# database - or after the last source took the schema away - its CREATE ...
# SCRIPT went into a schema that did not exist ("schema EXAKIT_VS not found").
# Its own kit home and deployment, so no source of the cases above counts.
FR_SAVED_HOME="$HOME_K"; FR_SAVED_DEPLOY="$DEPLOY"; FR_SAVED_EXA="$EXA"
HOME_K="$WORK/kit-fresh"; DEPLOY="$WORK/deploy-fresh"; EXA="$DEPLOY/local/runtime/exa"
mkdir -p "$HOME_K" "$EXA/bucketfs/bfsdefault/default" "$EXA/jdbc"
cp -R "$FR_SAVED_HOME/cache" "$HOME_K/cache"
# "yes" when CREATE SCHEMA EXAKIT_VS came before the first Rust script, since statement $1.
schema_first() { dbq '(lambda s: "yes" if "CREATE SCHEMA EXAKIT_VS" in s and s.index("CREATE SCHEMA EXAKIT_VS") < min([i for i, x in enumerate(s) if x.startswith("CREATE OR REPLACE RUST")] + [len(s)]) else "no")(d["statements"]['"${1:-0}"':])'; }
fr_sources() { eng --json list 2>/dev/null | python3 -c 'import json, sys; print(json.dumps([s["name"] for s in json.load(sys.stdin)["sources"]]))'; }
db '{"sources": {"cluster0.example.net": {"tables": ["MOVIES"], "secret": "'"$SECRET"'"}, "pg.example.com": {"tables": ["ORDERS"]}}}'
run_secret "wrong" connect mongodb --name fr_bad $MG_SET --set collection=movies --secret-stdin
check "a wrong password, the first connect of all: exit 1, refused by the source after EXAKIT_VS and the scripts were made" \
    "1 yes" "$RC $(schema_first)"
lacks "...not by the database for a missing schema" "schema EXAKIT_VS not found" "$OUT"
check "...and the rollback leaves nothing: no source, CONNECTION, script or EXAKIT_VS" "[] {} [] []" \
    "$(fr_sources) $(dbq 'd["connections"]') $(dbq 'd["scripts"]') $(dbq 'd["schemas"]')"
FR0="$(dbq 'len(d["statements"])')"
run_secret "$SECRET" connect mongodb --name fr_m $MG_SET --set collection=movies --secret-stdin
check "MongoDB connected first on a fresh database: exit 0" "0" "$RC"
check "...EXAKIT_VS made before its adapter script, no Java probe asked" "yes 0" \
    "$(schema_first "$FR0") $(dbq 'sum("EXAKIT_DNS_PROBE_V2(" in s or "EXAKIT_FILES_PROBE_V1(" in s for s in d["statements"]['"$FR0"':])')"
check "...the adapter and its scan UDF in it" '["EXAKIT_VS.MONGODB_ADAPTER", "EXAKIT_VS.MONGODB_SCAN"]' "$(dbq 'sorted(d["scripts"])')"
run remove fr_m
check "the last source out drops EXAKIT_VS and everything in it" "0 [] []" "$RC $(dbq 'd["schemas"]') $(dbq 'd["scripts"]')"
# The other way to reach a database without EXAKIT_VS: another source made it, and left.
run_secret "$SECRET" connect postgresql --name fr_pg $PG_SET --secret-stdin; FR_RC="$RC"
run remove fr_pg
check "a PostgreSQL source connected and removed: EXAKIT_VS gone with it" "0 0 []" "$FR_RC $RC $(dbq 'd["schemas"]')"
FR1="$(dbq 'len(d["statements"])')"
run_secret "$SECRET" connect mongodb --name fr_m $MG_SET --set collection=movies --secret-stdin
check "...then MongoDB connects: exit 0, EXAKIT_VS made again first" "0 yes" "$RC $(schema_first "$FR1")"
run remove fr_m
check "...and leaves with it" "0 [] []" "$RC $(fr_sources) $(dbq 'd["schemas"]')"
HOME_K="$FR_SAVED_HOME"; DEPLOY="$FR_SAVED_DEPLOY"; EXA="$FR_SAVED_EXA"

check "the Rust container is pinned for both CPUs, size and SHA-256" "aarch64 x86_64" "$(python3 - "$ROOT" <<'PYR'
import json, re, sys
c = json.load(open(sys.argv[1] + "/setup/virtual-schemas/profiles/rust-native/profile.json"))["slc"]["custom"]
print(" ".join(sorted(a for a, p in c["arch"].items() if re.fullmatch(r"[0-9a-f]{64}", p["sha256"]) and p["size"] > 0
                      and p["url"].startswith("https://github.com/exasol-labs/language-container-rs/releases/download/"))))
PYR
)"
VSRUN="$(sed -n '/^_exakit_vs_run() {/,/^}/p' "$ROOT/setup/lib/virtual-schemas.sh")"
VSREPAIR="$(sed -n '/^_exakit_vs_repair() {/,/^}/p' "$ROOT/setup/lib/virtual-schemas.sh")"
VSRUST="$(sed -n '/^_exakit_vs_install_rust() {/,/^}/p' "$ROOT/setup/lib/virtual-schemas.sh")"
has "bash: exit 23 installs the Rust container" "23) _exakit_vs_install_rust ;;" "$VSREPAIR"
has "...then retries" 'case "$_evx_rc" in 20|21|23) ;; *) break ;; esac' "$VSRUN"
has "...it checks size and SHA-256 before installing" 'verify_sha256 "$_evr_dir/$_evr_asset" "$_evr_sha"' "$VSRUST"
has "PowerShell: its twin" 'if ($Code -eq 23) { return [bool](Install-ExakitVsRust) }' "$(cat "$ROOT/setup/lib/virtual-schemas.ps1")"

printf '\n== Databricks (Profile C): a Lua adapter with the kit'"'"'s certificate check ==\n'
# Measured on Exasol Personal 2.3.0 (adapter 1.0.2, driver 3.4.3, a real
# workspace): the database's LuaSec loads no CA file, so upstream calls the
# REST API unverified; the kit appends a check of the chain (pinned Mozilla
# bundle, from memory) and the host name. Rows come through the loader, which
# needs the kit's TrustStoreDriver as for Snowflake.
DBX_HOST="dbc-1234abcd-5678.cloud.databricks.com"
DBX_SET="--set host=$DBX_HOST --set http_path=/sql/1.0/warehouses/abc123def456ghi7 --set catalog=workspace --set schema=sales"
dbxdb() { db '{"loader_cacerts": false, "sources": {"'"$DBX_HOST"'": {"tables": ["CUSTOMER", "ORDERS"], "secret": "'"$SECRET"'"}}}'; }
# dbxsrc KEY JSON-VALUE: one property of the workspace, the rest of the state kept.
dbxsrc() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); s=d["sources"][sys.argv[2]]
s.pop(sys.argv[3], None) if sys.argv[4] == "null" else s.__setitem__(sys.argv[3], json.loads(sys.argv[4])); json.dump(d, open(sys.argv[1], "w"))' "$STATE" "$DBX_HOST" "$1" "$2"; }
dbxdb
run plan databricks --name dbx $DBX_SET
check "plan: exit 0" "0" "$RC"
has "...the CA bundle is a pinned download of its own" '"role": "trust", "asset": "cacert-2026-10-20.pem"' "$OUT"
has "...the plan says what the kit adds to the adapter" "plus the kit's check of the REST API's certificate and host name against the pinned CA bundle" "$OUT"
for bad in "http_path=/sql/1.0/warehouses/abc;UID=x" "catalog=main&x=1" "schema=a#b" "http_path=/api/2.0/x"; do
    run plan databricks --name dbx $DBX_SET --set "$bad"
    check "refused with exit 2 (it would reach the REST query or the URL): $bad" "2" "$RC"
done

run_secret "$SECRET" connect databricks --name dbx $DBX_SET --secret-stdin
check "connect: exit 0" "0" "$RC"
has "...two tables" "Virtual schema VS_DBX: 2 table(s); a bounded read succeeded" "$OUT"
check "...the CONNECTION: the URL with AuthMech=3, USER token, the token as its password" \
    "[\"jdbc:databricks://$DBX_HOST:443/default;transportMode=http;ssl=1;AuthMech=3;httpPath=/sql/1.0/warehouses/abc123def456ghi7;\", \"token\", true]" \
    "$(dbq '[d["connections"]["EXAKIT_SRC_DBX"]["url"], d["connections"]["EXAKIT_SRC_DBX"]["user"], d["connections"]["EXAKIT_SRC_DBX"]["secret"] == "'"$SECRET"'"]')"
DBXA="$(dbq '[x for x in d["statements"] if "LUA ADAPTER SCRIPT" in x][-1]')"
has "...a Lua adapter script" 'CREATE OR REPLACE LUA ADAPTER SCRIPT "EXAKIT_VS"."ADAPTER_DBX" AS' "$DBXA"
has "...upstream's preamble first" "table.insert(package.searchers," "$DBXA"
has "...then the dist file as pinned" "adapter-databricks" "$DBXA"
has "...then the kit's suffix, replacing only the socket factory" "http_client._create_socket_factory = function(args)" "$DBXA"
has "...with both certificates of the bundle in it" "QUJDRA==" "$DBXA"
has "...the second too" "RUZHSA==" "$DBXA"
lacks "...and none of the bundle's comments" "NetLock" "$DBXA"
lacks "...the marker is gone" "--@EXAKIT_CA_BUNDLE@" "$DBXA"
check "...no closing / (everything after AS is Lua)" "no" "$(printf '%s' "$DBXA" | grep -q -x '/' && echo yes || echo no)"
lacks "...the token is not in the script" "$SECRET" "$DBXA"
check "...nothing for the adapter is staged in BucketFS" "no" "$([ -d "$EXA/bucketfs/bfsdefault/default/exakit/vs/databricks" ] && echo yes || echo no)"
DBXCFG="$(cat "$EXA/jdbc/DATABRICKS/settings.cfg")"
has "...the loader driver is registered with the kit's main class" "DRIVERMAIN=exakit.loader.TrustStoreDriver" "$DBXCFG"
has "...and the Databricks driver beside it" "JAR=databricks-jdbc-3.4.3.jar" "$DBXCFG"
has "...joins are kept from the adapter (1.0.2 renders three tables as FROM \`\`)" "EXCLUDED_CAPABILITIES = 'JOIN, JOIN_CONDITION_EQUI" \
    "$(dbq '[x for x in d["statements"] if x.startswith("CREATE VIRTUAL SCHEMA \"VS_DBX\"")][-1]')"
lacks "...the token is not printed" "$SECRET" "$OUT"

run_secret "dapi-wrong" connect databricks --name dbxbad $DBX_SET --secret-stdin
check "a refused token: exit 1, nothing of its own kept" "1 false" "$RC $(dbq '"EXAKIT_SRC_DBXBAD" in d["connections"]' | tr A-Z a-z)"
has "...the REST API's own answer, not its URL and JSON" "E-VSDAB-5: the REST API answered HTTP 403: Invalid access token." "$OUT"
has "...filed as a rejected credential, with how to get a new token" "an expired or revoked token is refused the same way" "$OUT"

dbxsrc no_columns true
run_secret "$SECRET" connect databricks --name dbxs $DBX_SET --secret-stdin
check "a catalog answered without columns (samples): exit 1" "1" "$RC"
has "...the adapter's Lua error comes with what it means" "the built-in samples catalog does this" "$OUT"

dbxsrc no_columns null; dbxsrc fail '"tls"'
run_secret "$SECRET" connect databricks --name dbxt $DBX_SET --secret-stdin
check "a certificate the suffix refuses: exit 1, filed as TLS" "1" "$RC"
has "...in the suffix's words" "certificate verify failed: certificate has expired" "$OUT"

dbxsrc fail null
run_secret "dapi-wrong" reauth dbx --secret-stdin
check "reauth with a token the source refuses: exit 1, the old one kept" "1 true" \
    "$RC $(dbq 'd["connections"]["EXAKIT_SRC_DBX"]["secret"] == "'"$SECRET"'"' | tr A-Z a-z)"
has "...tried through the loader first, in the driver's short words" "DatabricksSQLException: HTTP 403: Invalid access token." "$OUT"
run_secret "$SECRET" reauth dbx --secret-stdin
check "reauth with the token it accepts: exit 0" "0" "$RC"
run remove dbx
check "remove: the script, schema and connection gone, the loader cleaned up" "false false false no" \
    "$(dbq '"EXAKIT_VS.ADAPTER_DBX" in d["scripts"]' | tr A-Z a-z) $(dbq '"VS_DBX" in d["virtual"]' | tr A-Z a-z) $(dbq '"EXAKIT_SRC_DBX" in d["connections"]' | tr A-Z a-z) $([ -f "$EXA/jdbc/DATABRICKS/settings.cfg" ] && echo yes || echo no)"

LUASFX="$ROOT/setup/virtual-schemas/lua/exakit_verified_tls.lua"
check "the suffix holds the bundle marker exactly once" "1" "$(grep -c -x -- '--@EXAKIT_CA_BUNDLE@' "$LUASFX")"
has "...verifies the chain with OpenSSL (cert:issued)" "root:issued(leaf, table.unpack(chain))" "$(cat "$LUASFX")"
has "...checks the host name against the certificate" "if not host_matches(leaf, host) then" "$(cat "$LUASFX")"
has "...sends SNI" "self.c:sni(host)" "$(cat "$LUASFX")"
has "...and refuses plain http" "refusing an unencrypted request" "$(cat "$LUASFX")"
check "the bundle is pinned from curl.se by size and SHA-256" "ok" "$(python3 - "$ROOT" <<'PYB'
import json, re, sys
t = json.load(open(sys.argv[1] + "/setup/virtual-schemas/connectors/databricks/connector.json"))["trust"]
print("ok" if re.fullmatch(r"[0-9a-f]{64}", t["sha256"]) and t["size"] > 100000
      and t["url"] == "https://curl.se/ca/%s" % t["asset"] else "bad")
PYB
)"

printf '\n== Lakehouse (Profile D): Iceberg on AWS Glue, four shared scripts ==\n'
# Measured on Exasol Personal 2.3.0 (lakehouse-engine-rs 0.57.3, aarch64, Glue
# in ap-south-1): the engine shares MongoDB's Rust container; the adapter calls
# LAKEHOUSE_SCAN and LAKEHOUSE_DISTRIBUTE_FILES by name in its own schema; a key
# AWS does not know and a database the key may not list are refused by name.
LK_KEY_ID="AKIAIOSFODNN7EXAMPLE"
LK_FILE="$WORK/lake-key.json"
printf '{"AccessKey": {"UserName": "reader", "AccessKeyId": "%s", "Status": "Active", "SecretAccessKey": "%s"}}' \
    "$LK_KEY_ID" "$SECRET-0123456789abcdefghijklmnop" > "$LK_FILE"
LK_SET="--set region=ap-south-1 --set database=sales_lake"
lkdb() { db '{"sources": {"glue.ap-south-1.amazonaws.com": {"key_id": "'"$LK_KEY_ID"'", "databases": {"sales_lake": ["customers", "orders"], "other_lake": ["events"], "locked": ["x"]}, "readable": ["sales_lake", "other_lake"]}}'"${1:-}"'}'; }
lkdb
run plan lakehouse --name lake $LK_SET
check "plan: exit 0" "0" "$RC"
has "...this machine's engine archive" "lakehouse-engine" "$OUT"
has "...the shared scripts by name" "EXAKIT_VS.LAKEHOUSE_SCAN, EXAKIT_VS.LAKEHOUSE_DISTRIBUTE_FILES, EXAKIT_VS.LAKEHOUSE_VERSION" "$OUT"
run plan lakehouse --name lake --set region=ap-south-1 --set database=sales.eu
check "a dotted database (the engine refuses one) is refused here, exit 2" "2" "$RC"
OUT="$(EXAKIT_VS_ARCH=x86_64 eng plan lakehouse --name lake $LK_SET 2>&1)"
has "...the x86_64 archive on x86_64" '"asset": "lakehouse-engine.tar.gz"' "$OUT"

lkdb ', "rust": false'
OUT="$(eng connect lakehouse --name lake $LK_SET --secret-stdin < "$LK_FILE" 2>&1)"; RC=$?
check "without the Rust container: exit 23, nothing created" "23 {} {}" "$RC $(dbq 'd["connections"]') $(dbq 'd["virtual"]')"
# Rust there, Java not (a fresh Exasol Personal 2.4 after the Rust install):
# the kit's own Java DNS probe of the Glue host fails, and that is Java's to
# install - it was read as Rust's (exit 23) before, which reinstalled Rust.
lkdb ', "java": "builtin"'
OUT="$(eng connect lakehouse --name lake $LK_SET --secret-stdin < "$LK_FILE" 2>&1)"; RC=$?
check "Rust there, Java missing (the DNS probe): exit 21, not 23" "21" "$RC"
has "...said as a missing Java" "Java is not installed in the database" "$OUT"

lkdb
OUT="$(eng connect lakehouse --name lake $LK_SET --secret-stdin < "$LK_FILE" 2>&1)"; RC=$?
check "connect with the create-access-key JSON on stdin: exit 0" "0" "$RC"
has "...the database's tables" "Virtual schema VS_LAKE: 2 table(s); a bounded read succeeded" "$OUT"
LKCON="$(dbq 'd["connections"]["EXAKIT_SRC_LAKE"]')"
check "...the CONNECTION: the Glue endpoint, no user" "[\"https://glue.ap-south-1.amazonaws.com\", \"\"]" \
    "$(dbq '[d["connections"]["EXAKIT_SRC_LAKE"]["url"], d["connections"]["EXAKIT_SRC_LAKE"]["user"]]')"
check "...its password: the engine's JSON fields, nothing else" '["access_key", "region", "secret_key"]' \
    "$(dbq 'sorted(__import__("json").loads(d["connections"]["EXAKIT_SRC_LAKE"]["secret"]))')"
LKSO="$EXA/bucketfs/bfsdefault/default/exakit/vs/lakehouse/0.57.3/liblakehouse_engine.so"
check "...only the .so is staged from the archive, as pinned" "yes no" \
    "$([ -f "$LKSO" ] && echo yes || echo no) $(ls "$EXA/bucketfs/bfsdefault/default/exakit/vs/lakehouse/0.57.3/" | grep -c 'tar.gz' | sed 's/^0$/no/;s/^[1-9].*/yes/')"
has "...the adapter keeps the name the engine exports" 'CREATE OR REPLACE RUST ADAPTER SCRIPT "EXAKIT_VS"."LAKEHOUSE_ADAPTER" AS' \
    "$(dbq '[x for x in d["statements"] if "RUST ADAPTER SCRIPT" in x][-1]')"
has "...and loads the staged .so" '%udf_object /buckets/bfsdefault/default/exakit/vs/lakehouse/0.57.3/liblakehouse_engine.so' \
    "$(dbq '[x for x in d["statements"] if "RUST ADAPTER SCRIPT" in x][-1]')"
has "...the scan script with the engine's signature" 'CREATE OR REPLACE RUST SCALAR SCRIPT "EXAKIT_VS"."LAKEHOUSE_SCAN"(common VARCHAR(2000000), files VARCHAR(2000000)) EMITS (...) AS' \
    "$(dbq '[x for x in d["statements"] if "LAKEHOUSE_SCAN" in x][-1]')"
LKLUA="$(dbq '[x for x in d["statements"] if "LAKEHOUSE_DISTRIBUTE_FILES" in x][-1]')"
has "...the distributor in Lua" 'CREATE OR REPLACE LUA SET SCRIPT "EXAKIT_VS"."LAKEHOUSE_DISTRIBUTE_FILES"(files VARCHAR(2000000)) EMITS (files VARCHAR(2000000)) AS' "$LKLUA"
check "...with no closing / (everything after AS is Lua)" "no" "$(printf '%s' "$LKLUA" | grep -q -x '/' && echo yes || echo no)"
has "...the version script" '"EXAKIT_VS"."LAKEHOUSE_VERSION"() RETURNS VARCHAR(100) AS' "$(dbq '[x for x in d["statements"] if "LAKEHOUSE_VERSION" in x][-1]')"
has "...the virtual schema names the catalog the engine's way" "CATALOG_CONNECTION = 'EXAKIT_SRC_LAKE' CATALOG_KIND = 'GLUE' NAMESPACE = 'sales_lake'" \
    "$(dbq '[x for x in d["statements"] if x.startswith("CREATE VIRTUAL SCHEMA \"VS_LAKE\"")][-1]')"
lacks "...the secret key is not printed" "$SECRET" "$OUT"

OUT="$(eng connect lakehouse --name lake2 --set region=ap-south-1 --set database=other_lake --secret-stdin < "$LK_FILE" 2>&1)"; RC=$?
check "a second lakehouse source: exit 0, the four scripts shared, not doubled" "0 1 1 1 1" \
    "$RC $(dbq 'd["scripts"].count("EXAKIT_VS.LAKEHOUSE_ADAPTER")') $(dbq 'd["scripts"].count("EXAKIT_VS.LAKEHOUSE_SCAN")') $(dbq 'd["scripts"].count("EXAKIT_VS.LAKEHOUSE_DISTRIBUTE_FILES")') $(dbq 'd["scripts"].count("EXAKIT_VS.LAKEHOUSE_VERSION")')"

OUT="$(eng connect lakehouse --name lakeno --set region=ap-south-1 --set database=locked --secret-stdin < "$LK_FILE" 2>&1)"; RC=$?
check "a database the key may not list: exit 1, the shared scripts kept, nothing of its own" "1 1 false" \
    "$RC $(dbq 'd["scripts"].count("EXAKIT_VS.LAKEHOUSE_SCAN")') $(dbq '"EXAKIT_SRC_LAKENO" in d["connections"]' | tr A-Z a-z)"
has "...filed as access denied, with what the key needs" "glue:GetDatabase, GetTables, GetTable and GetPartitions" "$OUT"
# Measured: a database 42 min behind (the laptop slept) got S3's 403 for every
# signed read, which the engine words as PermissionDenied - not a missing grant.
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["clock_skew"]=-2520; json.dump(d, open(sys.argv[1], "w"))' "$STATE"
OUT="$(eng connect lakehouse --name lakeclk --set region=ap-south-1 --set database=locked --secret-stdin < "$LK_FILE" 2>&1)"; RC=$?
has "a refusal with the clock 42 min off is filed as the clock, not a grant" "the database clock is too far from the store's for a signed request" "$OUT"
lacks "...so it does not send the reader after IAM grants" "GetPartitions on the database" "$OUT"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["clock_skew"]=-300; json.dump(d, open(sys.argv[1], "w"))' "$STATE"
OUT="$(eng connect lakehouse --name lakeclk --set region=ap-south-1 --set database=locked --secret-stdin < "$LK_FILE" 2>&1)"; RC=$?
has "...a clock 5 min off, inside the stores' window, leaves it access denied" "glue:GetDatabase, GetTables, GetTable and GetPartitions" "$OUT"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.pop("clock_skew"); json.dump(d, open(sys.argv[1], "w"))' "$STATE"

run_secret "$LK_KEY_ID" connect lakehouse --name lakebad $LK_SET --secret-stdin
check "a bare key id as the secret: refused as input, exit 2" "2" "$RC"
OUT="$(printf '{"AccessKey": {"AccessKeyId": "AKIAZZZZZZZZZZZZZZZZ", "SecretAccessKey": "%s"}}' "$SECRET-0123456789abcdefghijklmnop" \
    | eng connect lakehouse --name lakebad $LK_SET --secret-stdin 2>&1)"; RC=$?
check "a key AWS does not know: exit 1, nothing kept" "1 false" "$RC $(dbq '"EXAKIT_SRC_LAKEBAD" in d["connections"]' | tr A-Z a-z)"
has "...filed as a rejected credential" "the source rejected the credentials" "$OUT"

python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["sources"]["glue.ap-south-1.amazonaws.com"]["key_id"]="AKIANEWNEWNEWNEWNEW1"; json.dump(d, open(sys.argv[1],"w"))' "$STATE"
OUT="$(eng reauth lake --secret-stdin < "$LK_FILE" 2>&1)"; RC=$?
check "reauth with the key AWS now refuses: exit 1, the old CONNECTION kept" "1 $LK_KEY_ID" \
    "$RC $(dbq '__import__("json").loads(d["connections"]["EXAKIT_SRC_LAKE"]["secret"])["access_key"]')"
check "...nothing pending left behind" "[] []" \
    "$(dbq '[c for c in d["connections"] if c.startswith("EXAKIT_PENDING_")]') $(dbq '[v for v in d["virtual"] if v.startswith("EXAKIT_PENDING_")]')"
OUT="$(printf '{"AccessKey": {"AccessKeyId": "AKIANEWNEWNEWNEWNEW1", "SecretAccessKey": "%s"}}' "$NEWSECRET-0123456789abcdefghijk" \
    | eng reauth lake --secret-stdin 2>&1)"; RC=$?
check "reauth with the new key: exit 0, replaced" "0 AKIANEWNEWNEWNEWNEW1" \
    "$RC $(dbq '__import__("json").loads(d["connections"]["EXAKIT_SRC_LAKE"]["secret"])["access_key"]')"

run remove lake --dry-run
lacks "removing one: the shared adapter is not in its plan" "LAKEHOUSE_ADAPTER" "$OUT"
run remove lake
check "...removed, the scripts and the .so kept for the other source" "0 1 yes" \
    "$RC $(dbq 'd["scripts"].count("EXAKIT_VS.LAKEHOUSE_SCAN")') $([ -f "$LKSO" ] && echo yes || echo no)"
run remove lake2 --dry-run
for s in LAKEHOUSE_SCAN LAKEHOUSE_DISTRIBUTE_FILES LAKEHOUSE_VERSION; do
    has "the last one out plans to drop $s" "script EXAKIT_VS.$s (no other lakehouse source uses it)" "$OUT"
done
LKN="$(dbq 'len(d["statements"])')"
run remove lake2
# Dropped by name: the last source out also drops EXAKIT_VS, which would hide
# a script left behind whenever another kind of source keeps that schema.
check "...and drops the three scripts by name, the adapter, and the .so" "3 1 no" \
    "$(dbq 'len([x for x in d["statements"]['"$LKN"':] if x.startswith("DROP SCRIPT \"EXAKIT_VS\".\"LAKEHOUSE_")])') $(dbq 'len([x for x in d["statements"]['"$LKN"':] if x == "DROP ADAPTER SCRIPT \"EXAKIT_VS\".\"LAKEHOUSE_ADAPTER\""])') $([ -f "$LKSO" ] && echo yes || echo no)"
LKN="$(dbq 'len(d["statements"])')"
OUT="$(eng connect lakehouse --name lakefirst --set region=ap-south-1 --set database=locked --secret-stdin < "$LK_FILE" 2>&1)"; RC=$?
check "a refused FIRST lakehouse source: exit 1, the three scripts it created dropped by name" "1 3" \
    "$RC $(dbq 'len([x for x in d["statements"]['"$LKN"':] if x.startswith("DROP SCRIPT \"EXAKIT_VS\".\"LAKEHOUSE_")])')"

ART="$(python3 - "$ROOT" "$WORK" <<'PYA'
import hashlib, io, os, sys, tarfile
sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import artifacts
work = sys.argv[2]
def make(path, entries):
    with tarfile.open(path, "w:gz") as a:
        for name, data, kind in entries:
            info = tarfile.TarInfo(name)
            if kind == "link":
                info.type = tarfile.SYMTYPE; info.linkname = "/etc/passwd"; a.addfile(info)
            else:
                info.size = len(data); a.addfile(info, io.BytesIO(data))
good = b"engine"
make(work + "/a.tgz", [("udf/liblakehouse_engine.so", good, "file"), ("udf/other", b"x", "file")])
make(work + "/b.tgz", [("udf/liblakehouse_engine.so", b"", "link")])
sha = hashlib.sha256(good).hexdigest()
for label, src, size, digest in (("ok", "a.tgz", len(good), sha), ("tampered", "a.tgz", len(good), "0" * 64),
                                 ("link", "b.tgz", 0, sha), ("missing", "a.tgz", 1, sha)):
    member = "udf/liblakehouse_engine.so" if label != "missing" else "udf/nope.so"
    dest = "%s/out-%s/liblakehouse_engine.so" % (work, label)
    try:
        artifacts.stage_tar_member(os.path.join(work, src), member, size, digest, dest)
        print(label, "staged", sorted(os.listdir(os.path.dirname(dest))))
    except artifacts.ArtifactError as e:
        print(label, "refused", sorted(os.listdir(os.path.dirname(dest))) if os.path.isdir(os.path.dirname(dest)) else [])
PYA
)"
check "a tar member: staged when it matches its pin, nothing else extracted" "ok staged ['liblakehouse_engine.so']" "$(printf '%s\n' "$ART" | sed -n 1p)"
check "...a member that does not match is refused, nothing left behind" "tampered refused []" "$(printf '%s\n' "$ART" | sed -n 2p)"
check "...a link in its place is refused" "link refused []" "$(printf '%s\n' "$ART" | sed -n 3p)"
check "...an archive without it is refused" "missing refused []" "$(printf '%s\n' "$ART" | sed -n 4p)"
check "the engine is pinned for both CPUs: archive and .so, size and SHA-256" "aarch64 x86_64" "$(python3 - "$ROOT" <<'PYP'
import json, re, sys
a = json.load(open(sys.argv[1] + "/setup/virtual-schemas/connectors/lakehouse/connector.json"))["adapter"]
print(" ".join(sorted(k for k, p in a["arch"].items() if all(re.fullmatch(r"[0-9a-f]{64}", p[f]) for f in ("sha256", "member_sha256"))
                      and p["size"] > 0 and p["member_size"] > 0
                      and p["url"].startswith("https://github.com/exasol-labs/lakehouse-engine-rs/releases/download/v%s/" % a["version"]))))
PYP
)"

printf '\n== Lakehouse engine routes: Iceberg REST and Unity Catalog on the same adapter ==\n'
# Not measured live: the catalogs are simulated from the Iceberg REST spec and
# Databricks' error codes. What is pinned here is the kit's side: one engine,
# one set of scripts for every route, and a CONNECTION whose JSON the kit writes.
IR_TOKEN="t0ken-$SECRET"; export IR_TOKEN
UC_TOKEN="dapi0123456789abcdef-$SECRET"
MINIO_SECRET="minio-$SECRET-secret"
IR_SET="--set catalog_url=https://rest.example.com/api/catalog/ --set warehouse=s3://wh/ --set namespace=sales"
UC_SET="--set workspace_url=https://dbc-1234.cloud.databricks.com --set namespace=main.sales --set region=us-east-2"
MINIO_SET="--set catalog_url=http://192.168.64.1:8181 --set warehouse=lake --set namespace=sales --set endpoint=http://192.168.64.1:9000 --set access_key_id=minioadmin"
lhdb() {
    IR_TOKEN="$IR_TOKEN" UC_TOKEN="$UC_TOKEN" MINIO_SECRET="$MINIO_SECRET" LK_KEY_ID="$LK_KEY_ID" python3 - "$STATE" <<'PYLH'
import json, os, sys
e = os.environ
uc = lambda **kw: dict({"catalog": "unity", "token": e["UC_TOKEN"], "namespaces": {"main.sales": ["orders"]},
                        "region": "us-east-2"}, **kw)
json.dump({"sources": {
    "glue.ap-south-1.amazonaws.com": {"key_id": e["LK_KEY_ID"], "databases": {"sales_lake": ["customers", "orders"]}},
    "rest.example.com": {"catalog": "rest", "warehouse": "s3://wh/", "token": e["IR_TOKEN"],
                         "namespaces": {"sales": ["orders", "returns"], "ops": ["events"]}},
    "192.168.64.1": {"catalog": "rest", "warehouse": "lake", "key_id": "minioadmin", "secret_key": e["MINIO_SECRET"],
                     "namespaces": {"sales": ["orders"]}, "region": "us-east-1"},
    "dbc-1234.cloud.databricks.com": uc(),
    "dbc-closed.cloud.databricks.com": uc(fail="external"),
    "dbc-managed.cloud.databricks.com": uc(fail="managed"),
}}, open(sys.argv[1], "w"))
PYLH
}
lhdb
run resolve rest; has "rest resolves to the Iceberg REST route" '"connector": "iceberg-rest"' "$OUT"
run resolve unity; has "unity resolves to the Unity Catalog route" '"connector": "unity"' "$OUT"
run resolve lakehouse; has "lakehouse still resolves to Glue" '"connector": "lakehouse"' "$OUT"
run resolve glue; has "...and glue" '"connector": "lakehouse"' "$OUT"
run resolve iceberg; check "iceberg names two catalogs, so it asks: exit 2" "2" "$RC"; has "...Glue or REST" "choices: lakehouse, iceberg-rest" "$OUT"
run resolve unity-catalog; check "unity-catalog names two routes, so it asks: exit 2" "2" "$RC"; has "...the SQL warehouse or the engine" "choices: databricks, unity" "$OUT"
check "the three routes pin one engine: archive, member and companion scripts identical" "same" "$(python3 - "$ROOT" <<'PYS'
import json, sys
load = lambda c: json.load(open(sys.argv[1] + "/setup/virtual-schemas/connectors/%s/connector.json" % c))
docs = [load(c) for c in ("lakehouse", "iceberg-rest", "unity")]
keys = ("adapter", "shared_adapter", "companions", "version_script", "profile")
print("same" if all(all(d[k] == docs[0][k] for k in keys) for d in docs) and all(d.get("family", d["id"]) == "lakehouse" for d in docs) else "differ")
PYS
)"

run plan iceberg-rest --name rest1 $IR_SET
check "plan iceberg-rest: exit 0" "0" "$RC"
has "...GA, a candidate" '"tier": "GA", "status": "candidate"' "$OUT"
lacks "...with no Beta caveat any more" "not been run against a live" "$OUT"
has "...states the MCP exposure" "MCP read-only user can read every table of VS_REST1" "$OUT"
has "...the scripts shared with every lakehouse engine source" "shared by every lakehouse engine source (AWS Glue, Iceberg REST or Unity Catalog)" "$OUT"
PLAN_IR="$(printf '%s\n' "$OUT" | sed -n 's/^RESULT //p' | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["downloads"]))')"
run plan unity --name uc $UC_SET
check "plan unity: exit 0" "0" "$RC"
has "...GA, a candidate" '"tier": "GA", "status": "candidate"' "$OUT"
lacks "...with no Beta caveat any more" "not been run against a live" "$OUT"
check "no connector reports Beta: every tier in the catalog is GA" "GA" \
    "$(eng --json catalog </dev/null 2>/dev/null | python3 -c 'import json,sys; print(" ".join(sorted({c["tier"] for c in json.load(sys.stdin)["connectors"]})))')"
has "...states the MCP exposure" "MCP read-only user can read every table of VS_UC" "$OUT"
PLAN_UC="$(printf '%s\n' "$OUT" | sed -n 's/^RESULT //p' | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["downloads"]))')"
run plan lakehouse --name glake $LK_SET
PLAN_LK="$(printf '%s\n' "$OUT" | sed -n 's/^RESULT //p' | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["downloads"]))')"
check "...all three download the same pinned archive (one cache entry)" "$PLAN_LK $PLAN_LK" "$PLAN_IR $PLAN_UC"
has "...this machine's engine archive" "lakehouse-engine" "$PLAN_IR"
run plan iceberg-rest --name minio $MINIO_SET --set region=us-east-1
check "plan over http to this computer: exit 0" "0" "$RC"
has "...warns that it is plain http" "plain http: the catalog token or storage keys and the rows cross the network unencrypted" "$OUT"
check "URLs are normalized: https for a bare host, http only towards this computer or a private network" \
    "https://rest.example.com/api/catalog https://rest.example.com http://192.168.64.1:8181 http://host.containers.internal:8181 http://10.1.2.3 http://[fd00::1]:8181 http://minio:9000 public loopback loopback" \
    "$(python3 - "$ROOT" <<'PYU'
import sys; sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import plan
spec = {"name": "catalog_url", "kind": "catalog-url"}
out = [plan.check_value(spec, raw)[0] for raw in ("https://rest.example.com/api/catalog/", "rest.example.com",
       "HTTP://192.168.64.1:8181/", "http://host.containers.internal:8181", "http://10.1.2.3", "http://[fd00::1]:8181")]
out.append(plan.check_value({"name": "endpoint", "kind": "endpoint-url"}, "http://minio:9000")[0])
out += [plan.host_scope(h) for h in ("8.8.8.8", "127.0.0.2", "[::1]")]
print(" ".join(str(o) for o in out))
PYU
)"

# Refusals before anything is created.
run plan iceberg-rest --name rest1 --set catalog_url=https://rest.example.com --set namespace=sales
check "REST without a warehouse: exit 2" "2" "$RC"; has "...named" "warehouse is required" "$OUT"
run plan unity --name uc --set workspace_url=https://dbc-1234.cloud.databricks.com --set namespace=sales --set region=us-east-2
check "Unity namespace that is not catalog.schema: exit 2" "2" "$RC"; has "...said how" "namespace must be catalog.schema, e.g. main.sales" "$OUT"
run plan unity --name uc --set workspace_url=https://dbc-1234.cloud.databricks.com --set namespace=main.sales
check "Unity without a region: exit 2" "2" "$RC"; has "...named" "region is required" "$OUT"
run plan iceberg-rest --name rest1 --set catalog_url=http://rest.example.com --set warehouse=w --set namespace=sales
check "plain http to a public host: exit 2" "2" "$RC"; has "...said why" "is plain http to rest.example.com, a public host" "$OUT"
run plan iceberg-rest --name rest1 --set catalog_url=http://localhost:8181 --set warehouse=w --set namespace=sales
check "a catalog on localhost: exit 2" "2" "$RC"; has "...with the address the database sees this computer at" "on macOS 192.168.64.1, on Linux and WSL host.containers.internal" "$OUT"
run plan unity --name uc --set workspace_url=http://10.0.0.5 --set namespace=main.sales --set region=us-east-2
check "a Unity workspace over http, even a private one: exit 2" "2" "$RC"; has "...https only" "workspace_url must use https" "$OUT"
run plan iceberg-rest --name rest1 --set catalog_url=https://minioadmin:pw@rest.example.com --set warehouse=w --set namespace=sales
check "a catalog URL carrying credentials: exit 2" "2" "$RC"; lacks "...not echoed" "minioadmin:pw" "$OUT"
run plan iceberg-rest --name rest1 $IR_SET --set endpoint=https://minio.example.com:9000/bucket
check "a storage endpoint with a path: exit 2" "2" "$RC"
NBEFORE="$(dbq 'len(d.get("connections", {}))')"
run_secret "$MINIO_SECRET" connect iceberg-rest --name minio $MINIO_SET --secret-stdin
check "storage keys without a region: exit 2, nothing created" "2 $NBEFORE" "$RC $(dbq 'len(d.get("connections", {}))')"
has "...named" "region is required with an access key" "$OUT"
run_secret "$IR_TOKEN" connect iceberg-rest --name rest1 $IR_SET --set endpoint=https://minio.example.com --secret-stdin
check "a storage endpoint with a catalog token: exit 2" "2" "$RC"; has "...said why" "a storage endpoint goes with an access key" "$OUT"
lacks "...the token is not echoed" "$IR_TOKEN" "$OUT"

# Connect all three routes: one engine, one set of scripts.
OUT="$(eng connect lakehouse --name glake $LK_SET --secret-stdin < "$LK_FILE" 2>&1)"; RC=$?
check "a Glue source first: exit 0" "0" "$RC"
run_secret "$IR_TOKEN" connect iceberg-rest --name rest1 $IR_SET --secret-stdin
check "connect iceberg-rest with a catalog token: exit 0" "0" "$RC"
has "...the catalog's host probed from inside the database" "rest.example.com resolves and answers on port 443" "$OUT"
has "...the namespace's tables" "Virtual schema VS_REST1: 2 table(s); a bounded read succeeded" "$OUT"
check "...the CONNECTION: TO the catalog URL, no user" '["https://rest.example.com/api/catalog", ""]' \
    "$(dbq '[d["connections"]["EXAKIT_SRC_REST1"]["url"], d["connections"]["EXAKIT_SRC_REST1"]["user"]]')"
check "...its password: warehouse, token, vended credentials" '[["token", "use_vended_credentials", "warehouse"], true, "s3://wh/"]' \
    "$(dbq '(lambda c: [sorted(c), c["use_vended_credentials"], c["warehouse"]])(__import__("json").loads(d["connections"]["EXAKIT_SRC_REST1"]["secret"]))')"
LHVS="$(dbq '[x for x in d["statements"] if x.startswith("CREATE VIRTUAL SCHEMA \"VS_REST1\"")][-1]')"
has "...the virtual schema: the connection and the namespace" "WITH CATALOG_CONNECTION = 'EXAKIT_SRC_REST1' NAMESPACE = 'sales'" "$LHVS"
lacks "...no ALLOW_HTTP over https" "ALLOW_HTTP" "$LHVS"
lacks "...no catalog kind (REST is the engine's default)" "CATALOG_KIND" "$LHVS"
check "...the token only inside CONNECTION DDL" "0" \
    "$(dbq 'len([x for x in d["statements"] if (__import__("os").environ["IR_TOKEN"] in x or __import__("os").environ["IR_TOKEN"].replace(chr(39), chr(39) * 2) in x) and not x.startswith("CREATE CONNECTION")])')"
lacks "...not printed" "$IR_TOKEN" "$OUT"
check "...not in the kit's records" "0" "$(grep -rlF -- "$IR_TOKEN" "$HOME_K" | wc -l | tr -d ' ')"

run_secret "$MINIO_SECRET" connect iceberg-rest --name minio $MINIO_SET --set region=us-east-1 --secret-stdin
check "connect iceberg-rest with storage keys over http on this computer: exit 0" "0" "$RC"
has "...the catalog port probed" "192.168.64.1 resolves and answers on port 8181" "$OUT"
check "...its password: warehouse, keys, region, endpoint, path-style" \
    '[["access_key", "endpoint", "path_style", "region", "secret_key", "warehouse"], "minioadmin", "http://192.168.64.1:9000", true]' \
    "$(dbq '(lambda c: [sorted(c), c["access_key"], c["endpoint"], c["path_style"]])(__import__("json").loads(d["connections"]["EXAKIT_SRC_MINIO"]["secret"]))')"
has "...the virtual schema allows http" "NAMESPACE = 'sales' ALLOW_HTTP = 'true'" \
    "$(dbq '[x for x in d["statements"] if x.startswith("CREATE VIRTUAL SCHEMA \"VS_MINIO\"")][-1]')"
lacks "...the secret key is not printed" "$MINIO_SECRET" "$OUT"

run_secret "$UC_TOKEN" connect unity --name uc $UC_SET --secret-stdin
check "connect unity: exit 0" "0" "$RC"
check "...the CONNECTION: TO the workspace, no user" '["https://dbc-1234.cloud.databricks.com", ""]' \
    "$(dbq '[d["connections"]["EXAKIT_SRC_UC"]["url"], d["connections"]["EXAKIT_SRC_UC"]["user"]]')"
check "...its password: token, vended credentials, region" '[["region", "token", "use_vended_credentials"], "us-east-2", true]' \
    "$(dbq '(lambda c: [sorted(c), c["region"], c["use_vended_credentials"]])(__import__("json").loads(d["connections"]["EXAKIT_SRC_UC"]["secret"]))')"
has "...the virtual schema names Unity Catalog" "WITH CATALOG_CONNECTION = 'EXAKIT_SRC_UC' CATALOG_KIND = 'UNITY_CATALOG' NAMESPACE = 'main.sales'" \
    "$(dbq '[x for x in d["statements"] if x.startswith("CREATE VIRTUAL SCHEMA \"VS_UC\"")][-1]')"
has "...the tips: external data access" "Databricks Default Storage cannot be read from outside" "$OUT"
has "...and catalog-managed tables" "catalog-managed tables cannot be read by this adapter version" "$OUT"
lacks "...the token is not printed" "$UC_TOKEN" "$OUT"

check "four sources on three routes: the adapter and its three scripts once each" "1 1 1 1" \
    "$(dbq 'd["scripts"].count("EXAKIT_VS.LAKEHOUSE_ADAPTER")') $(dbq 'd["scripts"].count("EXAKIT_VS.LAKEHOUSE_SCAN")') $(dbq 'd["scripts"].count("EXAKIT_VS.LAKEHOUSE_DISTRIBUTE_FILES")') $(dbq 'd["scripts"].count("EXAKIT_VS.LAKEHOUSE_VERSION")')"
check "...one staged engine, in the family's folder" "lakehouse" "$(ls "$EXA/bucketfs/bfsdefault/default/exakit/vs/" | grep -E '^(lakehouse|iceberg-rest|unity)$' | tr '\n' ' ' | sed 's/ $//')"
check "...every route's adapter script loads that one file" "1" \
    "$(dbq 'len(set(x.split("%udf_object ")[1] for x in d["statements"] if "RUST ADAPTER SCRIPT" in x and "LAKEHOUSE_ADAPTER" in x))')"

# Failures, classified, nothing kept.
run_secret "wrong-token" connect iceberg-rest --name restbad $IR_SET --secret-stdin
check "a token the catalog refuses: exit 1, nothing kept" "1 false" "$RC $(dbq '"EXAKIT_SRC_RESTBAD" in d["connections"]' | tr A-Z a-z)"
has "...filed as a rejected credential" "the source rejected the credentials" "$OUT"
run_secret "wrong-token" connect unity --name ucbad $UC_SET --secret-stdin
check "a Unity token refused: exit 1, nothing kept" "1 false" "$RC $(dbq '"EXAKIT_SRC_UCBAD" in d["connections"]' | tr A-Z a-z)"
has "...filed as a rejected credential" "the source rejected the credentials" "$OUT"
run_secret "$IR_TOKEN" connect iceberg-rest --name restno --set catalog_url=https://rest.example.com/api/catalog --set warehouse=s3://wh/ --set namespace=nope --secret-stdin
check "a namespace the catalog does not have: exit 1, nothing kept" "1 false" "$RC $(dbq '"EXAKIT_SRC_RESTNO" in d["connections"]' | tr A-Z a-z)"
has "...named as a missing namespace" "the catalog has no such namespace that this credential can see" "$OUT"
run_secret "$UC_TOKEN" connect unity --name ucno --set workspace_url=https://dbc-1234.cloud.databricks.com --set namespace=main.nope --set region=us-east-2 --secret-stdin
check "a Unity schema that does not exist: exit 1" "1" "$RC"; has "...named as a missing namespace" "no such namespace" "$OUT"
run_secret "$UC_TOKEN" connect unity --name ucclosed --set workspace_url=https://dbc-closed.cloud.databricks.com --set namespace=main.sales --set region=us-east-2 --secret-stdin
check "a schema closed to outside engines: exit 1, nothing kept" "1 false" "$RC $(dbq '"EXAKIT_SRC_UCCLOSED" in d["connections"]' | tr A-Z a-z)"
has "...named as External Data Access, not a grant guess" "switch External Data Access on for the metastore" "$OUT"
has "...with the other route" "exakit connect databricks" "$OUT"
run_secret "$UC_TOKEN" connect unity --name ucmanaged --set workspace_url=https://dbc-managed.cloud.databricks.com --set namespace=main.sales --set region=us-east-2 --secret-stdin
check "a catalog-managed table: exit 1" "1" "$RC"; has "...named as not readable yet" "catalog-managed table, which this adapter version cannot read yet" "$OUT"
run_secret "$MINIO_SECRET" connect iceberg-rest --name minio2 $MINIO_SET --set region=eu-west-1 --secret-stdin
check "a bucket in another region: exit 1" "1" "$RC"; has "...named as the region" "connect again with --set region=<the bucket's region>" "$OUT"
check "...and the shared scripts are still there after every refusal" "1 1" \
    "$(dbq 'd["scripts"].count("EXAKIT_VS.LAKEHOUSE_ADAPTER")') $(dbq 'd["scripts"].count("EXAKIT_VS.LAKEHOUSE_SCAN")')"

lhdb_token() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["sources"]["rest.example.com"]["token"]=sys.argv[2]; json.dump(d, open(sys.argv[1],"w"))' "$STATE" "$1"; }
lhdb_token "n3w-$IR_TOKEN"
run_secret "n3w-$IR_TOKEN" reauth rest1 --secret-stdin
check "reauth iceberg-rest with the catalog's new token: exit 0" "0" "$RC"
has "...the new token in the CONNECTION" "n3w-t0ken" "$(dbq '__import__("json").loads(d["connections"]["EXAKIT_SRC_REST1"]["secret"])["token"]')"

# The last Glue source out must not take the scripts a REST or Unity source calls.
run remove glake --dry-run
lacks "removing the only Glue source: the shared adapter is not in its plan" "LAKEHOUSE_ADAPTER" "$OUT"
lacks "...nor its scripts" "LAKEHOUSE_SCAN" "$OUT"
run remove glake
check "...removed, the scripts and the engine kept for the REST and Unity sources" "0 1 1 1 1 yes" \
    "$RC $(dbq 'd["scripts"].count("EXAKIT_VS.LAKEHOUSE_ADAPTER")') $(dbq 'd["scripts"].count("EXAKIT_VS.LAKEHOUSE_SCAN")') $(dbq 'd["scripts"].count("EXAKIT_VS.LAKEHOUSE_DISTRIBUTE_FILES")') $(dbq 'd["scripts"].count("EXAKIT_VS.LAKEHOUSE_VERSION")') $([ -f "$LKSO" ] && echo yes || echo no)"
run check rest1
check "...the REST source still reads" "0" "$RC"
run remove rest1; run remove minio
check "removing the REST sources keeps them for Unity" "0 1 yes" "$RC $(dbq 'd["scripts"].count("EXAKIT_VS.LAKEHOUSE_SCAN")') $([ -f "$LKSO" ] && echo yes || echo no)"
run remove uc --dry-run
for s in LAKEHOUSE_SCAN LAKEHOUSE_DISTRIBUTE_FILES LAKEHOUSE_VERSION; do
    has "the last lakehouse engine source out plans to drop $s" "script EXAKIT_VS.$s (no other lakehouse source uses it)" "$OUT"
done
LKN="$(dbq 'len(d["statements"])')"
run remove uc
check "...and drops the three scripts, the adapter and the engine" "3 1 no" \
    "$(dbq 'len([x for x in d["statements"]['"$LKN"':] if x.startswith("DROP SCRIPT \"EXAKIT_VS\".\"LAKEHOUSE_")])') $(dbq 'len([x for x in d["statements"]['"$LKN"':] if x == "DROP ADAPTER SCRIPT \"EXAKIT_VS\".\"LAKEHOUSE_ADAPTER\""])') $([ -f "$LKSO" ] && echo yes || echo no)"

printf '\n== a private CA for Oracle: a wallet inside the connection ==\n'
# Measured against RDS Oracle 19c over TCPS: ojdbc 23 reads a trust-only PEM
# wallet from wallet_location=data:;base64,... - in both the loader and the
# adapter's runtime, with no file - and checks the host name (ORA-17965 by IP).
ORA_SET="--set host=ora.example.com --set port=2484 --set service=EXATEST --set schema=HR --set user=EXA_READER"
db '{"sources": {"ora.example.com": {"tables": ["EMPLOYEES"]}}}'
run plan oracle --name ora $ORA_SET --set ca="$CA/bundle.pem"
has "the plan says the bundle travels as a wallet in the connection" "(2 certificates, as a wallet inside the connection)" "$OUT"
run_secret "$SECRET" connect oracle --name ora $ORA_SET --set ca="$CA/bundle.pem" --secret-stdin
check "Oracle with a CA bundle: exit 0, with no handshake from this computer (ora.example.com is not reachable)" "0" "$RC"
OURL="$(dbq 'd["connections"]["EXAKIT_SRC_ORA"]["url"]')"
has "...TCPS, host name matched, the short wallet_location name (oracle.net. is a syntax error there)" \
    "jdbc:oracle:thin:@tcps://ora.example.com:2484/EXATEST?ssl_server_dn_match=true&wallet_location=data:;base64," "$OURL"
check "...the wallet is the whole bundle, exactly" "same" \
    "$(python3 -c 'import base64,sys; got=base64.b64decode(sys.argv[1].split("base64,",1)[1]).decode(); want=open(sys.argv[2]).read(); print("same" if got.split() == want.split() else "differs")' "$OURL" "$CA/bundle.pem")"
check "...and no file was staged for it" "no" "$([ -e "$EXA/bucketfs/bfsdefault/default/exakit/vs/tls/ora.jks" ] || [ -e "$EXA/jdbc/ORACLE/buckets" ] && echo yes || echo no)"
run_secret "$NEWSECRET" reauth ora --secret-stdin
has "reauth keeps the wallet in the URL" "wallet_location=data:;base64," "$(dbq 'd["connections"]["EXAKIT_SRC_ORA"]["url"]')"
run remove ora; check "...and remove is clean" "0" "$RC"

printf '\n== Profile B: S3 document files ==\n'
# Measured against a real bucket (Exasol Personal 2.3.0, adapter 5.0.0): the
# adapter and its import UDF come from one JAR, the CONNECTION holds JSON, the
# mapping is read from the bucket path, and each failure below is the text S3
# returned. The fake reads the staged mapping exactly where the adapter would.
MAPS="$WORK/edml"; mkdir -p "$MAPS"
for t in orders:data/orders/*.jsonl customers:data/customers/customers.csv events:data/events/event-*.json; do
    printf '{"$schema": "https://schemas.exasol.com/edml-2.1.0.json", "source": "%s", "destinationTable": "%s"}\n' \
        "${t#*:}" "$(printf '%s' "${t%%:*}" | tr 'a-z' 'A-Z')" > "$MAPS/${t%%:*}.json"
done
printf 'not a mapping\n' > "$MAPS/README.txt"
KEYID="AKIAEXAMPLEKEYID0001"; AWSSECRET="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
S3_SET="--set bucket=docs-bucket --set region=ap-south-1 --set mapping=$MAPS"
S3HOST="docs-bucket.s3.ap-south-1.amazonaws.com"
db '{"sources": {"'"$S3HOST"'": {"secret": "'"$AWSSECRET"'", "region": "ap-south-1"}}}'
run plan s3 --name docs $S3_SET
check "plan: exit 0" "0" "$RC"
has "...stages the mapping, naming its tables" '3 mapped tables: CUSTOMERS, EVENTS, ORDERS' "$OUT"
has "...names the shared import script" 'import script EXAKIT_VS.IMPORT_FROM_S3_DOCUMENT_FILES' "$OUT"
check "...downloads the adapter and nothing else (no JDBC driver)" "1" "$(printf '%s' "$OUT" | grep -c '"role":')"
run plan s3 --name docs --set bucket=my.dotted.bucket --set region=ap-south-1 --set mapping=$MAPS
has "a dotted bucket is refused: its HTTPS name fails the certificate" "does not match the S3 certificate" "$OUT"
run plan s3 --name docs --set bucket=docs-bucket --set region=cn-north-1 --set mapping=$MAPS
has "a China region is refused, by name" "China regions use other endpoints" "$OUT"
BADMAP="$WORK/badmap"; mkdir -p "$BADMAP"
printf '{"$schema": "https://schemas.exasol.com/edml-2.1.0.json", "source": "s3://docs-bucket/a.json", "destinationTable": "A"}\n' > "$BADMAP/a.json"
printf '{"$schema": "https://schemas.exasol.com/edml-2.1.0.json", "source": "b/*.json", "destinationTable": "a"}\n' > "$BADMAP/b.json"
printf '{"source": "c.json", "destinationTable": "C D"}\n' > "$BADMAP/c.json"
run plan s3 --name docs --set bucket=docs-bucket --set region=ap-south-1 --set mapping=$BADMAP
check "a bad mapping is refused before anything happens, exit 2" "2" "$RC"
has "...a source with s3:// is named" 'is the key inside the bucket, without s3://' "$OUT"
has "...two files mapping one table are named" 'a.json and b.json both map to table A' "$OUT"
has "...and a missing \$schema and a bad table name" 'c.json needs "$schema"' "$OUT"
has "...and a bad table name" 'c.json needs a "destinationTable" that is a plain SQL name' "$OUT"
run plan s3 --name docs $S3_SET --set access_key_id=not-a-key
has "a malformed access key ID is refused" "not a valid aws-key-id" "$OUT"

run_secret "$AWSSECRET" connect s3 --name docs $S3_SET --set access_key_id=$KEYID --secret-stdin
check "connect with the secret key on stdin: exit 0" "0" "$RC"
has "...every table is read" 'Virtual schema VS_DOCS: 3 table(s); a bounded read of each table succeeded' "$OUT"
check "...the CONNECTION holds the adapter's JSON, with bucket and region" \
    '{"awsAccessKeyId": "AKIAEXAMPLEKEYID0001", "awsSecretAccessKey": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "awsRegion": "ap-south-1", "s3Bucket": "docs-bucket"}' \
    "$(dbq 'd["connections"]["EXAKIT_SRC_DOCS"]["secret"]')"
check "...with no URL and no user" '["", ""]' "$(dbq '[d["connections"]["EXAKIT_SRC_DOCS"]["url"], d["connections"]["EXAKIT_SRC_DOCS"]["user"]]')"
lacks "...the secret key never reaches the output" "$AWSSECRET" "$OUT"
lacks "...nor the source's records" "$AWSSECRET" "$(cat "$HOME_K"/virtual-schemas/sources/docs/*.json 2>/dev/null) $(cat "$HOME_K"/virtual-schemas/*.json 2>/dev/null)"
STAGED="$EXA/bucketfs/bfsdefault/default/exakit/vs/mappings/docs"
check "...the mapping's .json files are staged in the kit's bucket folder, nothing else" "customers.json events.json orders.json" \
    "$(ls "$STAGED" | tr '\n' ' ' | sed 's/ $//')"
check "...and the virtual schema has the mapping's tables" '["CUSTOMERS", "EVENTS", "ORDERS"]' "$(dbq 'd["virtual"]["VS_DOCS"]["tables"]')"
VSQL="$(dbq '[x for x in d["statements"] if x.startswith("CREATE VIRTUAL SCHEMA")][-1]')"
has "...MAPPING names the bucket path the adapter reads (no /buckets)" "MAPPING = '/bfsdefault/default/exakit/vs/mappings/docs'" "$VSQL"
IMPORT="$(dbq '[x for x in d["statements"] if "IMPORT_FROM_S3_DOCUMENT_FILES" in x][-1]')"
has "...the import script has the adapter's signature" 'CREATE OR REPLACE JAVA SET SCRIPT "EXAKIT_VS"."IMPORT_FROM_S3_DOCUMENT_FILES"(DATA_LOADER VARCHAR(2000000), SCHEMA_MAPPING_REQUEST VARCHAR(2000000), CONNECTION_NAME VARCHAR(500)) EMITS(...) AS' "$IMPORT"
has "...runs the adapter's own UDF class from the same JAR" '%scriptclass com.exasol.adapter.document.UdfEntryPoint;' "$IMPORT"
check "...with telemetry off, after %scriptclass (the measured order)" "yes" \
    "$(printf '%s\n' "$IMPORT" | awk '/%scriptclass/{c=NR} /%env EXASOL_TELEMETRY_DISABLE=1;/{e=NR} END{print (c && e && c < e) ? "yes" : "no"}')"
ADQ="$(dbq '[x for x in d["statements"] if x.startswith("CREATE OR REPLACE JAVA ADAPTER SCRIPT \"EXAKIT_VS\".\"ADAPTER_DOCS\"")][-1]')"
has "...and the adapter script too" '%env EXASOL_TELEMETRY_DISABLE=1;' "$ADQ"
check "...no loader driver was registered" "" "$(ls "$EXA/jdbc" | grep -v java.security)"

printf '%s' '{"AccessKey": {"UserName": "reader", "AccessKeyId": "AKIAEXAMPLEKEYID0001", "Status": "Active", "SecretAccessKey": "'"$AWSSECRET"'"}}' > "$WORK/s3key.json"
OUT="$(eng connect s3 --name docs2 $S3_SET --secret-stdin < "$WORK/s3key.json" 2>&1)"; RC=$?
check "a second source from the JSON aws iam create-access-key prints: exit 0" "0" "$RC"
check "...both share the one import script" "1" "$(dbq 'd["scripts"].count("EXAKIT_VS.IMPORT_FROM_S3_DOCUMENT_FILES")')"
run remove docs --dry-run
lacks "removing one: the shared import script is not in its plan" "IMPORT_FROM_S3_DOCUMENT_FILES" "$OUT"
run remove docs
check "...removed, exit 0" "0" "$RC"
has "...and the other source keeps the import script" "EXAKIT_VS.IMPORT_FROM_S3_DOCUMENT_FILES" "$(dbq 'd["scripts"]')"
check "...its staged mapping is gone" "no" "$([ -d "$STAGED" ] && echo yes || echo no)"
run remove docs2 --dry-run
has "the last one out plans to drop the import script" "import script EXAKIT_VS.IMPORT_FROM_S3_DOCUMENT_FILES (no other s3 source uses it)" "$OUT"
run remove docs2
check "...and does" "[]" "$(dbq '[s for s in d["scripts"] if "IMPORT_FROM" in s]')"

db '{"sources": {"'"$S3HOST"'": {"secret": "'"$AWSSECRET"'", "empty": ["EVENTS"]}}}'
run_secret "$AWSSECRET" connect s3 --name docs $S3_SET --set access_key_id=$KEYID --secret-stdin
check "a table whose glob matches nothing still connects: exit 0" "0" "$RC"
has "...and is named, with where to look" 'No rows in EVENTS: their mapping'"'"'s source matches no objects' "$OUT"
run check docs
check "check names it too" '["EVENTS"]' "$(eng --json check docs 2>/dev/null | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("empty_tables")))')"
run remove docs

for case in "wrong secret|auth|rejected the credentials; nothing was kept" \
            "denied|denied|s3:ListBucket on the mapped prefixes" \
            "wrong region|region|connect again with --set region=<the bucket's region>"; do
    label="${case%%|*}"; rest="${case#*|}"; fail_kind="${rest%%|*}"; expect="${rest#*|}"
    case "$fail_kind" in
        auth) db '{"sources": {"'"$S3HOST"'": {"secret": "something-else-entirely-0000000000000000"}}}' ;;
        denied) db '{"sources": {"'"$S3HOST"'": {"fail": "denied"}}}' ;;
        region) db '{"sources": {"docs-bucket.s3.eu-central-1.amazonaws.com": {}}}' ;;
    esac
    run_secret "$AWSSECRET" connect s3 --name docs $S3_SET --set access_key_id=$KEYID --secret-stdin
    check "S3 $label: exit 1" "1" "$RC"
    has "...the fix is named" "$expect" "$OUT"
    check "...and nothing was kept: no connection, import script or mapping" '[{}, []] no' \
        "$(dbq '[d["connections"], [s for s in d["scripts"] if "IMPORT_FROM" in s]]') $([ -d "$STAGED" ] && echo yes || echo no)"
done
has "the SDK's own words reach the user, not the UDF wrapper" "AccessDeniedException: User: arn:aws:iam::1:user/reader is not authorized" \
    "$(db '{"sources": {"'"$S3HOST"'": {"fail": "denied"}}}'; run_secret "$AWSSECRET" connect s3 --name docs $S3_SET --set access_key_id=$KEYID --secret-stdin; printf '%s' "$OUT")"

db '{"sources": {"'"$S3HOST"'": {"secret": "'"$AWSSECRET"'"}}}'
run_secret "$AWSSECRET" connect s3 --name docs $S3_SET --set access_key_id=ASIAEXAMPLEKEYID0001 --secret-stdin
check "a temporary key without its session token is refused, exit 2" "2" "$RC"
has "...saying what to give" "need their session token" "$OUT"
printf '%s' '{"Credentials": {"AccessKeyId": "ASIAEXAMPLEKEYID0001", "SecretAccessKey": "'"$AWSSECRET"'", "SessionToken": "FwoGZXIvYXdzEXAMPLETOKEN", "Expiration": "2026-10-29T01:00:00Z"}}' > "$WORK/sts.json"
OUT="$(eng connect s3 --name docs $S3_SET --secret-stdin < "$WORK/sts.json" 2>&1)"; RC=$?
check "the JSON aws sts prints connects: exit 0" "0" "$RC"
has "...the token travels in the CONNECTION" '"awsSessionToken": "FwoGZXIvYXdzEXAMPLETOKEN"' "$(dbq 'd["connections"]["EXAKIT_SRC_DOCS"]["secret"]')"
has "...and the user hears that it expires, with the reauth" "temporary credentials expire" "$OUT"
lacks "...the token is not printed" "FwoGZXIvYXdzEXAMPLETOKEN" "$OUT"
NEWAWS="AnotherSecretKeyValue0000000000000000000"
db "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["sources"][sys.argv[2]]["secret"]=sys.argv[3]; print(json.dumps(d))' "$STATE" "$S3HOST" "$NEWAWS")"
printf '%s' '{"AccessKey": {"AccessKeyId": "AKIAEXAMPLEKEYID0002", "SecretAccessKey": "'"$NEWAWS"'"}}' > "$WORK/s3key2.json"
OUT="$(eng reauth docs --secret-stdin < "$WORK/s3key2.json" 2>&1)"; RC=$?
check "reauth with a new key file: exit 0" "0" "$RC"
has "...the CONNECTION holds the new key, the bucket and region kept" '{"awsAccessKeyId": "AKIAEXAMPLEKEYID0002", "awsSecretAccessKey": "AnotherSecretKeyValue0000000000000000000", "awsRegion": "ap-south-1", "s3Bucket": "docs-bucket"}' \
    "$(dbq 'd["connections"]["EXAKIT_SRC_DOCS"]["secret"]')"
has "...after a throwaway schema on a pending CONNECTION read it" "The source accepted the new credential" "$OUT"
has "...one row from each table, as connect reads a document source" 'SELECT * FROM "EXAKIT_PENDING_VS_DOCS"."ORDERS" LIMIT 1' \
    "$(dbq '" | ".join(d["statements"])')"
check "...nothing pending is left behind" "[]" "$(pending)"

# A typo in the new key: S3 refuses it, so the working one stays. This
# mapping has a CSV without fields, so the trial schema's CREATE reads already.
DOCSKEY="$(dbq 'd["connections"]["EXAKIT_SRC_DOCS"]["secret"]')"
TYPOAWS="AnotherSecretKeyValue000000000000000000O"
printf '%s' '{"AccessKey": {"AccessKeyId": "AKIAEXAMPLEKEYID0003", "SecretAccessKey": "'"$TYPOAWS"'"}}' > "$WORK/s3typo.json"
DN0="$(dbq 'len(d["statements"])')"
OUT="$(eng reauth docs --secret-stdin < "$WORK/s3typo.json" 2>&1)"; RC=$?
check "reauth with a key S3 refuses: exit 1, as every refused reauth" "1" "$RC"
has "...it says the previous one was kept" "the source refused the new credential, so the previous one was kept" "$OUT"
check "...the CONNECTION still holds the working key" "$DOCSKEY" "$(dbq 'd["connections"]["EXAKIT_SRC_DOCS"]["secret"]')"
check "...nothing pending is left behind" "[]" "$(pending)"
lacks "...the refused key is in none of the output" "$TYPOAWS" "$OUT"
check "...nor in any statement but the pending CONNECTION's" "[]" \
    "$(dbq '[s[:60] for s in d["statements"]['"$DN0"':] if "'"$TYPOAWS"'" in s and not s.startswith("CREATE OR REPLACE CONNECTION \"EXAKIT_PENDING_")]')"
run check docs; check "...and the source still checks ready" "0" "$RC"

# A mapping that names its fields: CREATE reads no object (measured on S3),
# so only the trial's read can catch the refused key - and does.
TYPED="$WORK/edml-typed"; mkdir -p "$TYPED"
printf '{"$schema": "https://schemas.exasol.com/edml-2.1.0.json", "source": "data/orders/*.jsonl", "destinationTable": "ORDERS", "mapping": {"fields": {"id": {"toDecimalMapping": {}}}}}\n' > "$TYPED/orders.json"
run_secret "$NEWAWS" connect s3 --name typed --set bucket=docs-bucket --set region=ap-south-1 --set mapping=$TYPED \
    --set access_key_id=AKIAEXAMPLEKEYID0002 --secret-stdin
check "a source whose mapping names its fields connects: exit 0" "0" "$RC"
OUT="$(eng reauth typed --secret-stdin < "$WORK/s3typo.json" 2>&1)"; RC=$?
check "...reauth with a key S3 refuses: exit 1, though the trial schema was created" "1 true" \
    "$RC $(dbq 'any(s.startswith("CREATE VIRTUAL SCHEMA \"EXAKIT_PENDING_VS_TYPED\"") for s in d["statements"])')"
has "...the read through it said no" 'SELECT * FROM "EXAKIT_PENDING_VS_TYPED"."ORDERS" LIMIT 1' "$(dbq '" | ".join(d["statements"])')"
check "...the working key kept, nothing pending" "AKIAEXAMPLEKEYID0002 []" \
    "$(dbq '__import__("json").loads(d["connections"]["EXAKIT_SRC_TYPED"]["secret"])["awsAccessKeyId"]') $(pending)"
run check typed; check "...and the source still checks ready" "0" "$RC"
run remove typed

# A source may be called <name>_pending: a trial for <name> never touches it.
run_secret "$NEWAWS" connect s3 --name docs_pending $S3_SET --set access_key_id=AKIAEXAMPLEKEYID0002 --secret-stdin
check "a source named docs_pending connects beside docs: exit 0" "0" "$RC"
DPKEY="$(dbq 'd["connections"]["EXAKIT_SRC_DOCS_PENDING"]["secret"]')"
eng reauth docs --secret-stdin < "$WORK/s3typo.json" >/dev/null 2>&1
OUT="$(eng reauth docs --secret-stdin < "$WORK/s3key2.json" 2>&1)"; RC=$?
check "...a refused and an accepted reauth of docs leave its schema alone" "0 true" "$RC $(dbq '"VS_DOCS_PENDING" in d["virtual"]')"
check "...and its CONNECTION" "$DPKEY" "$(dbq 'd["connections"]["EXAKIT_SRC_DOCS_PENDING"]["secret"]')"

# A reauth killed mid-trial (SIGKILL: no finally runs) leaves its trial schema
# and pending CONNECTION; disconnect and remove sweep them.
killed_trial() {
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
d["connections"]["EXAKIT_PENDING_EXAKIT_SRC_DOCS"] = dict(d["connections"].get("EXAKIT_SRC_DOCS") or {"url": "", "user": "", "secret": "{}"})
d["virtual"]["EXAKIT_PENDING_VS_DOCS"] = {"connection": "EXAKIT_PENDING_EXAKIT_SRC_DOCS", "tables": ["ORDERS"]}
json.dump(d, open(sys.argv[1], "w"))' "$STATE"
}
killed_trial
run disconnect docs
check "disconnect after a killed trial: exit 0, its pending credential and schema gone" "0 []" "$RC $(pending)"
killed_trial
DN0="$(dbq 'len(d["statements"])')"
run remove docs
check "remove after a killed trial: exit 0, nothing pending left" "0 []" "$RC $(pending)"
check "...the trial schema dropped before the adapter script it runs on" "true" \
    "$(dbq '(lambda s: s.index("DROP FORCE VIRTUAL SCHEMA IF EXISTS \"EXAKIT_PENDING_VS_DOCS\" CASCADE") < s.index("DROP ADAPTER SCRIPT \"EXAKIT_VS\".\"ADAPTER_DOCS\""))(d["statements"]['"$DN0"':])')"
check "...and docs_pending's CONNECTION and schema are still there" "true true" \
    "$(dbq '"EXAKIT_SRC_DOCS_PENDING" in d["connections"]') $(dbq '"VS_DOCS_PENDING" in d["virtual"]')"
run check docs_pending; check "...it still checks ready" "0" "$RC"
run remove docs_pending

printf '\n== Profile B: Azure Blob Storage document files ==\n'
# Measured against a real storage account (Exasol Personal 2.3.0, adapter
# 3.1.0): a container SAS with read + list works through the adapter's
# connection string, as does the account key; each failure below is the text
# Azure returned. The CSV mapping has no fields, so CREATE reads the container
# to infer them - and a failure there arrives wrapped in E-VSD-102.
AZACCT="docsacct"; AZHOST="$AZACCT.blob.core.windows.net"
AZKEY="$(printf 'QUFB%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21)QQ=="
AZSIG="abcSig%2Bdef%3D"
AZSAS="sv=2022-11-02&spr=https&se=2099-01-01T00%3A00Z&sr=c&sp=rl&sig=$AZSIG"
AZ_SET="--set account=$AZACCT --set container=vs-test --set mapping=$MAPS"
azdb() { db '{"sources": {"'"$AZHOST"'": {"key": "'"$AZKEY"'", "sas": {"vs-test": "'"$AZSIG"'"}, "containers": ["vs-test", "vs-private"]'"${1:-}"'}}}'; }
AZSTAGED="$EXA/bucketfs/bfsdefault/default/exakit/vs/mappings/azdocs"
azgone() { check "...and nothing was kept: no connection, import script or mapping" '[{}, []] no' \
    "$(dbq '[d["connections"], [s for s in d["scripts"] if "IMPORT_FROM" in s]]') $([ -d "$AZSTAGED" ] && echo yes || echo no)"; }

azdb
run plan azure --name azdocs $AZ_SET
check "plan: 'azure' finds the connector, exit 0" "0" "$RC"
has "...it is azure-blob" '"connector": "azure-blob"' "$OUT"
has "...resolves the account's blob endpoint first" "resolve $AZHOST" "$OUT"
has "...names the adapter's import script" 'import script EXAKIT_VS.IMPORT_FROM_AZURE_BLOB_STORAGE_DOCUMENT_FILES' "$OUT"
run plan azure-blob --name azdocs --set account=My_Account --set container=vs-test --set mapping=$MAPS
has "an account name that cannot exist is refused" "account='My_Account' is not a valid azure-account" "$OUT"
run plan azure-blob --name azdocs --set account=$AZACCT --set container=vs--test --set mapping=$MAPS
has "...and a container name" "container='vs--test' is not a valid azure-container" "$OUT"

run_secret "$AZSAS" connect azure-blob --name azdocs $AZ_SET --secret-stdin
check "connect with a container SAS on stdin: exit 0" "0" "$RC"
has "...every table is read" 'Virtual schema VS_AZDOCS: 3 table(s); a bounded read of each table succeeded' "$OUT"
check "...the CONNECTION holds the adapter's JSON: a connection string the kit built, and the container" \
    '{"absStorageAccountConnectionString": "BlobEndpoint=https://docsacct.blob.core.windows.net/;SharedAccessSignature='"$AZSAS"'", "absContainerName": "vs-test"}' \
    "$(dbq 'd["connections"]["EXAKIT_SRC_AZDOCS"]["secret"]')"
check "...with no URL and no user" '["", ""]' "$(dbq '[d["connections"]["EXAKIT_SRC_AZDOCS"]["url"], d["connections"]["EXAKIT_SRC_AZDOCS"]["user"]]')"
lacks "...the SAS signature never reaches the output" "$AZSIG" "$OUT"
lacks "...nor the source's records" "$AZSIG" "$(cat "$HOME_K"/virtual-schemas/sources/azdocs/*.json 2>/dev/null) $(cat "$HOME_K"/virtual-schemas/*.json 2>/dev/null)"
has "...the SAS's expiry is said, with this source's reauth" "this SAS expires at 2099-01-01 00:00 UTC; then give a new one with: exakit source reauth azdocs" "$OUT"
AZIMPORT="$(dbq '[x for x in d["statements"] if "IMPORT_FROM_AZURE_BLOB_STORAGE_DOCUMENT_FILES" in x][-1]')"
has "...the import script has the adapter's signature" 'CREATE OR REPLACE JAVA SET SCRIPT "EXAKIT_VS"."IMPORT_FROM_AZURE_BLOB_STORAGE_DOCUMENT_FILES"(DATA_LOADER VARCHAR(2000000), SCHEMA_MAPPING_REQUEST VARCHAR(2000000), CONNECTION_NAME VARCHAR(500)) EMITS(...) AS' "$AZIMPORT"
has "...from the Azure JAR, telemetry off" '%env EXASOL_TELEMETRY_DISABLE=1;' "$AZIMPORT"
has "...the JAR is the Azure adapter's" 'azure-blob-storage-3.1.0.jar' "$AZIMPORT"
check "...the mapping is staged for this source" "customers.json events.json orders.json" "$(ls "$AZSTAGED" | tr '\n' ' ' | sed 's/ $//')"

printf 'DefaultEndpointsProtocol=https;EndpointSuffix=core.windows.net;AccountName=%s;AccountKey=%s;BlobEndpoint=https://%s/;FileEndpoint=https://%s.file.core.windows.net/;QueueEndpoint=https://%s.queue.core.windows.net/;TableEndpoint=https://%s.table.core.windows.net/\n' \
    "$AZACCT" "$AZKEY" "$AZHOST" "$AZACCT" "$AZACCT" "$AZACCT" > "$WORK/azconn.txt"
OUT="$(eng connect azure-blob --name azkey $AZ_SET --secret-stdin < "$WORK/azconn.txt" 2>&1)"; RC=$?
check "the connection string az prints (every endpoint listed) connects: exit 0" "0" "$RC"
check "...the CONNECTION holds the account key form, HTTPS" \
    "DefaultEndpointsProtocol=https;AccountName=$AZACCT;AccountKey=$AZKEY;EndpointSuffix=core.windows.net" \
    "$(dbq '__import__("json").loads(d["connections"]["EXAKIT_SRC_AZKEY"]["secret"])["absStorageAccountConnectionString"]')"
has "...and the user hears what an account key opens" "an account key opens every container of $AZACCT, for writing too" "$OUT"
lacks "...the key is not printed" "$AZKEY" "$OUT"
check "...both sources share one import script" "1" "$(dbq 'd["scripts"].count("EXAKIT_VS.IMPORT_FROM_AZURE_BLOB_STORAGE_DOCUMENT_FILES")')"

# Reauth: a key, then a SAS the kit refuses (kept the key), then the SAS back.
run_secret "$AZKEY" reauth azdocs --secret-stdin
check "reauth with the bare account key: exit 0" "0" "$RC"
has "...the CONNECTION now holds the key" "AccountKey=$AZKEY" "$(dbq 'd["connections"]["EXAKIT_SRC_AZDOCS"]["secret"]')"
run_secret "${AZSAS/sp=rl/sp=r}" reauth azdocs --secret-stdin
check "reauth with a SAS that cannot list is refused here, exit 2" "2" "$RC"
has "...saying which permission is missing" "the SAS lacks list (l) permission" "$OUT"
lacks "...without sending anyone to the log" "exakit logs" "$OUT"
has "...and the working key is kept" "AccountKey=$AZKEY" "$(dbq 'd["connections"]["EXAKIT_SRC_AZDOCS"]["secret"]')"
AZWRONG="$(printf 'QkJC%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21)Qg=="
run_secret "$AZWRONG" reauth azdocs --secret-stdin
check "reauth with an account key Azure refuses: exit 1" "1" "$RC"
has "...it says the previous one was kept" "the source refused the new credential, so the previous one was kept" "$OUT"
check "...the working key kept, nothing pending" "true []" \
    "$(dbq '"AccountKey='"$AZKEY"'" in d["connections"]["EXAKIT_SRC_AZDOCS"]["secret"]') $(pending)"
lacks "...the refused key is not printed" "$AZWRONG" "$OUT"
run check azdocs; check "...and the source still checks ready" "0" "$RC"
run remove azkey --dry-run
lacks "removing one: the shared import script is not in its plan" "IMPORT_FROM_AZURE" "$OUT"
run remove azkey; run remove azdocs
check "the last one out drops the import script" "[]" "$(dbq '[s for s in d["scripts"] if "IMPORT_FROM" in s]')"

for case in "a SAS that cannot list|sp=r|the SAS lacks list (l) permission" \
            "an expired SAS|expired|the SAS expired at 2020-01-01T00:00Z" \
            "a blob SAS|blob|it needs to cover the container (sr=c)" \
            "an HTTP connection string|http|the kit reads only over HTTPS" \
            "another account's connection string|other|is for account otheracct, not docsacct" \
            "a password-like secret|junk|a SAS token (sv=...&sig=...) or the account key"; do
    label="${case%%|*}"; rest="${case#*|}"; form="${rest%%|*}"; expect="${rest#*|}"
    case "$form" in
        sp=r) cred="${AZSAS/sp=rl/sp=r}" ;;
        expired) cred="${AZSAS/2099/2020}" ;;
        blob) cred="${AZSAS/sr=c/sr=b}" ;;
        http) cred="DefaultEndpointsProtocol=http;AccountName=$AZACCT;AccountKey=$AZKEY" ;;
        other) cred="DefaultEndpointsProtocol=https;AccountName=otheracct;AccountKey=$AZKEY" ;;
        junk) cred="hunter2" ;;
    esac
    azdb
    run_secret "$cred" connect azure-blob --name azdocs $AZ_SET --secret-stdin
    check "$label is refused before anything is created, exit 2" "2" "$RC"
    has "...naming why" "$expect" "$OUT"
    check "...and nothing was created" '[{}, {}]' "$(dbq '[d["connections"], d["virtual"]]')"
done

for case in "wrong key|key|rejected the credentials; nothing was kept|AuthenticationFailed" \
            "a SAS made for another container|other|a SAS is valid only for the container it was made for|AuthenticationFailed" \
            "a missing container|missing|check the container name, then connect again|ContainerNotFound" \
            "a SAS without the permission|denied|a SAS with read (r) and list (l) on this container|AuthorizationPermissionMismatch"; do
    label="${case%%|*}"; rest="${case#*|}"; form="${rest%%|*}"; rest="${rest#*|}"; expect="${rest%%|*}"; code="${rest#*|}"
    cred="$AZSAS"; container=vs-test
    case "$form" in
        key) azdb; cred="DefaultEndpointsProtocol=https;AccountName=$AZACCT;AccountKey=$(printf 'QkJC%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21)QQ==" ;;
        other) azdb; container=vs-private ;;
        missing) azdb; cred="DefaultEndpointsProtocol=https;AccountName=$AZACCT;AccountKey=$AZKEY"; container=nosuch ;;
        denied) azdb ', "fail": "denied"' ;;
    esac
    run_secret "$cred" connect azure-blob --name azdocs --set account=$AZACCT --set container=$container --set mapping=$MAPS --secret-stdin
    check "Azure $label: exit 1" "1" "$RC"
    has "...the fix is named" "$expect" "$OUT"
    has "...Azure's own code is shown, under the adapter's" "E-VSD-102: Schema auto inference for source 'data/customers/customers.csv' failed. - caused by BlobStorageException: $code" "$OUT"
    lacks "...not the SDK's advice about logging" "Azure-Storage-Log-String-To-Sign" "$OUT"
    lacks "...nor the mitigations' empty heading" "Known mitigations:" "$OUT"
    azgone
done
printf '\n== a credential arrives byte for byte: UTF-8, a byte-order mark, base64 ==\n'
# Measured on the Windows CI runner: Windows PowerShell 5.1 piped a secret to
# Python with a byte-order mark and every non-ASCII character as '?', even
# with $OutputEncoding set. The bridge now sends it base64 (ASCII survives
# every code page); stdin is read as UTF-8 bytes, a mark or CRLF dropped.
U8SECRET="$(printf 'p\303\244ssw\303\266rd-\342\202\254-\346\227\245\346\234\254')"
ENC_SET="--set host=pg.example.com --set database=sales --set user=reader"
db '{"sources": {"pg.example.com": {"tables": ["ORDERS"]}}}'
OUT="$(printf '\357\273\277%s\r\n' "$U8SECRET" | eng connect postgresql --name enc $ENC_SET --secret-stdin 2>&1)"; RC=$?
check "a UTF-8 secret behind a byte-order mark, ending in CRLF: exit 0" "0" "$RC"
check "...stored as typed, without the mark or the line ending" "$U8SECRET" "$(dbq 'd["connections"]["EXAKIT_SRC_ENC"]["secret"]')"
run remove enc
B64="$(printf '%s' "$U8SECRET" | base64 | tr -d '\n')"
OUT="$(printf '\357\273\277%s\r\n' "$B64" | eng connect postgresql --name enc $ENC_SET --secret-stdin-base64 2>&1)"; RC=$?
check "the same secret as base64 (what the Windows bridge sends), mark and CRLF around it: exit 0" "0" "$RC"
check "...decoded byte for byte" "$U8SECRET" "$(dbq 'd["connections"]["EXAKIT_SRC_ENC"]["secret"]')"
lacks "...and neither form is printed" "$B64" "$OUT"
OUT="$(printf '%s' "$B64" | eng reauth enc --secret-stdin-base64 2>&1)"; RC=$?
check "reauth takes base64 too: exit 0" "0" "$RC"
run remove enc
OUT="$(printf 'not*base64' | eng connect postgresql --name enc $ENC_SET --secret-stdin-base64 2>&1)"; RC=$?
check "invalid base64 is bad input, exit 2, nothing created" "2 {}" "$RC $(dbq 'd["connections"]')"
has "...and says so" "not valid base64 UTF-8" "$OUT"

printf '\n== the hidden prompt hides from the first keystroke ==\n'
# Measured: with the prompt printed first and echo turned off after it, input
# typed the moment the prompt appeared was echoed in clear (expect, typing at
# once, printed the password). CI has no terminal, so the order is the test.
HIDDEN="$(sed -n '/^exakit_read_hidden() {/,/^}/p' "$ROOT/setup/lib/common.sh")"
check "echo goes off before the prompt is printed" "yes" \
    "$(printf '%s\n' "$HIDDEN" | awk '/stty -echo/{e=NR} /input hidden/{p=NR} END{print (e && p && e < p) ? "yes" : "no"}')"
has "...a terminal that cannot hide input is refused, not read in clear" "stty -echo < /dev/tty 2>/dev/null || return 1" "$HIDDEN"
has "...and the terminal's own state comes back, on Ctrl-C too" 'trap '"'"'stty "${_erh_saved:-echo}"' "$HIDDEN"
VSREAD="$(sed -n '/^_exakit_vs_read_secret() {/,/^}/p' "$ROOT/setup/lib/virtual-schemas.sh")"
has "the virtual-schema credential prompt uses it" "exakit_read_hidden" "$VSREAD"

printf '\n== the terminal form asks the engine, one answer at a time ==\n'
run inputs pg
has "inputs: the source name comes first" '"inputs": [{"name": "name", "label": "Name for this connection", "kind": "source-name"' "$OUT"
has "...then the connector's own, the credential flagged and never valued" '"name": "password", "label": "Password", "kind": "secret", "required": true, "default": "", "choices": [], "secret": true' "$OUT"
OUT="$(printf 'pg.example.com' | eng field pg host 2>&1)"; RC=$?
check "field: a good host is taken as it will be stored" '0 RESULT {"value": "pg.example.com"}' "$RC $OUT"
OUT="$(printf 'localhost' | eng field pg host 2>&1)"; RC=$?
check "...localhost is refused where it is typed, exit 2" "2" "$RC"
has "...in the words a scripted connect gets" "on macOS 192.168.64.1, on Linux and WSL host.containers.internal" "$OUT"
OUT="$(printf '' | eng field pg port 2>&1)"
check "...an empty answer takes the default" 'RESULT {"value": "5432"}' "$OUT"
OUT="$(printf '' | eng field pg host 2>&1)"; RC=$?
check "...and is refused where the input is required" "2 FAIL host is required (Host name or address)" "$RC $OUT"
OUT="$(printf 'Bad-Name' | eng field pg name 2>&1)"; RC=$?
check "...the source name keeps its rule" "2" "$RC"
OUT="$(printf 'cG9ydA==' | eng field pg tls --base64 2>&1)"; RC=$?
check "...the Windows bridge's base64 is decoded first (port is not a tls mode)" "2" "$RC"
OUT="$(printf 'dmVyaWZ5' | eng field pg tls --base64 2>&1)"
check "...and a good one passes" 'RESULT {"value": "verify"}' "$OUT"
OUT="$(printf 'x' | eng field pg password 2>&1)"; RC=$?
check "...a credential is never sent to be checked" "2" "$RC"

printf '\n== exakit connect on a terminal: menu, panel, review, live table ==\n'
# tty-replay.py runs the scenario under a real pty and replays the escape codes
# the way a terminal would, so what is asserted is what a person is left
# looking at: one menu, one panel per source however many redraws, one table.
TUI_SECRET='tUi-s3cret-Value'
export TUI_KIT="$HOME_K" TUI_STATE="$STATE" TUI_EXA="$EXA" TUI_DEFS="$DEFS" TUI_DEPLOY="$DEPLOY" TUI_LOG="$WORK/tui.log"
tui() { # tui <scenario> <title> <boxes> <keys> - the replay's report in TUI_OUT, its verdict in TUI_RC
    # The stream file (TTY_REPLAY_RAW) is this run's or none: a replay that dies
    # before writing it must not leave the last scenario's to be asserted on.
    [ -z "${TTY_REPLAY_RAW:-}" ] || rm -f "$TTY_REPLAY_RAW"
    TUI_OUT="$(TTY_REPLAY_COLS="${TUI_COLS:-100}" python3 "$ROOT/tests/lib/tty-replay.py" "$ROOT/tests/lib/$1" "$ROOT" "$2" "$4" "$3" 2>&1)"
    TUI_RC=$?
    if [ -n "${TTY_REPLAY_RAW:-}" ] && [ ! -f "$TTY_REPLAY_RAW" ]; then
        fail "the replay of $1 wrote no stream to $TTY_REPLAY_RAW"
        : > "$TTY_REPLAY_RAW"
    fi
    TUI_SCREEN="$(printf '%s\n' "$TUI_OUT" | sed -n '/=== FINAL SCREEN ===/,/=== tables on screen/p')"
    # A question that never came is said here, whatever the caller asserts next.
    case "$TUI_OUT" in
        *"=== WAIT FAILED"*) fail "the replay of $1 stopped: $(printf '%s\n' "$TUI_OUT" | sed -n 's/^=== WAIT FAILED: \(.*\) ===$/\1/p')"
                             printf '%s\n' "$TUI_OUT" | sed -n 's/^=== since the last key, the end: \(.*\) ===$/         last written: \1/p' ;;
    esac
}
# when <text> - a wait in the keystrokes: tty-replay.py types nothing more until
# <text> is on the screen (since the key before). Every question is waited for
# before it is answered: a key typed while the form is still busy - an engine
# round trip, a hidden prompt switching the terminal - is lost or answers the
# wrong question, and the busier the machine, the likelier.
when() { printf '\\x02%s\\x03' "$1"; }
# pasted <text> - text that goes in with one write, as a terminal hands over a
# paste ('\r' in it is a line break); plain ASCII.
pasted() { printf '\\x0e%s\\x0f' "$1"; }
# A connection string longer than a canonical terminal line (1023 bytes on
# macOS): a hidden prompt in canonical mode never saw its Enter.
LONGX="$(printf '%1450s' '' | tr ' ' x)"
MENU="$(when 'Enter to confirm')"                       # the menu, drawn and reading keys
Q_PASTE="$(when 'Connection string (hidden; Enter to type the fields):')"
Q_NAME="$(when 'Name for this connection *:')"
Q_HOST="$(when 'Host name or address *:')"
Q_PORT="$(when 'Port [')"
Q_DB="$(when 'Database *:')"
Q_SCHEMA="$(when 'Schema [public]:')"
Q_USER="$(when 'Reader account *:')"
Q_PW="$(when 'Password * (hidden')"
Q_TLS="$(when 'TLS (')"
Q_CA="$(when 'CA certificate file:')"
Q_SUM="$(when 'Number to change, Enter to continue')"
Q_GO="$(when 'now? [y/N]')"
if command -v python3 >/dev/null 2>&1; then
    db '{"sources": {"pg.example.com": {"tables": ["ORDERS", "CUSTOMERS"]}}}'
    # Space ticks PostgreSQL - the cursor starts on the first connector, there
    # is no "Select All" above it - Enter passes the connection string by, then
    # one wrong answer, corrected; Enter leaves the summary. The public IP lookup
    # is on (a file:// URL): the review says the address.
    TTY_REPLAY_RAW="$WORK/tui.raw" EXAKIT_NO_IP_LOOKUP= EXAKIT_PUBLIC_IP_URL="$IPURL" tui connect-tui-scenario.sh "1 of 1 · PostgreSQL" 3 \
        "$MENU $MENU\r$Q_PASTE\r${Q_NAME}tuione\r${Q_HOST}localhost\r${Q_HOST}pg.example.com\r$Q_PORT\r${Q_DB}sales\r$Q_SCHEMA\r${Q_USER}reader\r$Q_PW$TUI_SECRET\r$Q_TLS\r$Q_CA\r$Q_SUM\r${Q_GO}y\r"
    check "one menu, one panel and one table are left on screen, never stacked" "0" "$TUI_RC"
    check "the first line is this computer's public IP, before the menu's own line" \
        "    • This computer's public IP is 203.0.113.7: a source on the internet must allow it.|    • Tick one or more sources; the details for each are asked next." \
        "$(python3 -c 'import re, sys; t = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", open(sys.argv[1], encoding="utf-8").read()).replace("\r", ""); print("|".join([l for l in t.split("\n") if l.strip()][:2]))' "$WORK/tui.raw")"
    has "...the review names this computer's public IP for a source on the internet" \
        "tuione: This computer's public IP is 203.0.113.7" "$TUI_SCREEN"
    has "...the menu offers the connectors" "├─ PostgreSQL" "$TUI_SCREEN"
    has "...under the Source column" "Source" "$TUI_SCREEN"
    lacks "...no Version column" "Version" "$TUI_SCREEN"
    lacks "...no Release column" "Release" "$TUI_SCREEN"
    lacks "...no adapter version on a row" "4.1.0" "$TUI_SCREEN"
    lacks "...no tier on a row" " GA " "$TUI_SCREEN"
    lacks "...no Kind column any more" "REST + JDBC" "$TUI_SCREEN"
    has "...the panel shows every answer" "Host name or address *      pg.example.com" "$TUI_SCREEN"
    has "...the credential as given, never its value" "(given, hidden)" "$TUI_SCREEN"
    has "...the review says who can read the result" "MCP read-only user can read every table of VS_TUIONE" "$TUI_SCREEN"
    has "...and the row ends with the schema and its tables" "✓ VS_TUIONE · 2 tables" "$TUI_SCREEN"
    lacks "...the refused answer's line is gone once it was corrected" "would be the database itself" "$TUI_SCREEN"
    lacks "the credential is not on the screen" "$TUI_SECRET" "$TUI_OUT"
    check "...it reached the CONNECTION" "$TUI_SECRET" "$(dbq 'd["connections"]["EXAKIT_SRC_TUIONE"]["secret"]')"
    check "...and nowhere under the kit home" "" "$(grep -rl "$TUI_SECRET" "$HOME_K" 2>/dev/null)"

    python3 - "$STATE" <<'PY'
import json, sys; d = json.load(open(sys.argv[1])); d["sources"]["pg.example.com"] = {"tables": ["ORDERS"]}; json.dump(d, open(sys.argv[1], "w"))
PY
    OUT="$(printf 'tuione' | eng field pg name 2>&1)"; RC=$?
    check "field: a name already taken is refused before anything runs, exit 3" "3" "$RC"
    # Two sources at 80 columns, the second unreachable: one row each, and the
    # failure's whole sentence under the table rather than in a cell.
    TUI_COLS=80 tui connect-tui-scenario.sh "Connect 2 sources" 4 \
        "$MENU ${MENU}j$MENU $MENU\r$Q_PASTE\r${Q_NAME}tuitwo\r${Q_HOST}pg.example.com\r$Q_PORT\r${Q_DB}sales\r$Q_SCHEMA\r${Q_USER}reader\r${Q_PW}pw\r$Q_TLS\r$Q_CA\r$Q_SUM\r$Q_PASTE\r${Q_NAME}tuimy\r${Q_HOST}my.example.com\r$Q_PORT\r${Q_DB}shop\r${Q_USER}reader\r${Q_PW}pw\r$Q_TLS\r$Q_CA\r$Q_SUM\r${Q_GO}y\r"
    check "two sources: still one table" "0" "$TUI_RC"
    has "...the one that worked" "✓ VS_TUITWO · 1 table" "$TUI_SCREEN"
    has "...the one that did not, in a few words" "✗ the source did not answer" "$TUI_SCREEN"
    has "...and in the engine's words below the table" "tuimy did not connect:" "$TUI_SCREEN"
    check "...nothing kept for the failed one" "no" "$([ -d "$HOME_K/sources/tuimy" ] && echo yes || echo no)"

    # Java missing: the row says so, and below the table the kit installs it with
    # no question - picking the source was the permission - in one line that
    # says what and why, then the source runs again in a table of its own. The
    # real _exakit_vs_install_java runs; only the launcher and exakit stop and
    # start are stand-ins (TUI_FAKE_JAVA_INSTALL). An Enter pressed while the
    # table ran (its bar is up: a "%"; each connect takes two seconds here) is
    # thrown away, not typed into anything.
    python3 - "$STATE" <<'PY'
import json, sys; d = json.load(open(sys.argv[1])); d["java"] = False; json.dump(d, open(sys.argv[1], "w"))
PY
    export TUI_FAKE_CALLS="$WORK/fake-calls"
    TTY_REPLAY_RAW="$WORK/tui.raw" TUI_SLOW_CONNECT=2 TUI_FAKE_JAVA_INSTALL=1 tui connect-tui-scenario.sh "Connect again" 4 \
        "$MENU $MENU\r$Q_PASTE\r${Q_NAME}tuijava\r${Q_HOST}pg.example.com\r$Q_PORT\r${Q_DB}sales\r$Q_SCHEMA\r${Q_USER}reader\r${Q_PW}pw\r$Q_TLS\r$Q_CA\r$Q_SUM\r${Q_GO}y\r$(when '%')\r"
    check "a missing Java container: no question, then a table of its own" "0" "$TUI_RC"
    check "...the one y/N was Connect it now?" "1" "$(tr -d '\r' < "$WORK/tui.raw" | grep -c '\[y/N\]')"
    has "...the first table says what is missing" "✗ needs Java in the database" "$TUI_SCREEN"
    has "...one line says what the kit does and why" "Installing the Java language container for PostgreSQL: about 250 MiB, and the database restarts once" "$(tr -d '\r' < "$WORK/tui.raw")"
    lacks "...and asks nothing" "Install the Java language container now?" "$(cat "$WORK/tui.raw")"
    lacks "...no y/N after the connect question" "Java language container now? [y/N]" "$(cat "$WORK/tui.raw")"
    has "...the launcher installed it, with no restart of its own" "slc install java --no-restart" "$(cat "$TUI_FAKE_CALLS" 2>/dev/null)"
    has "...then the kit's own stop and start: the one restart" "exakit stop|exakit start" "$(tr '\n' '|' < "$TUI_FAKE_CALLS" 2>/dev/null)"
    has "...the install said done" "Java language container installed" "$TUI_SCREEN"
    has "...and the source connects" "✓ VS_TUIJAVA · 1 table" "$TUI_SCREEN"

    # The same at the line-by-line questions (a terminal without the drawn
    # form): "Connect now?" is the question, and the Java install after it is not.
    python3 - "$STATE" <<'PY'
import json, sys; d = json.load(open(sys.argv[1])); d["java"] = False; json.dump(d, open(sys.argv[1], "w"))
PY
    TTY_REPLAY_RAW="$WORK/tui.raw" TTY_REPLAY_CTTY=1 TUI_PLAIN=1 TUI_FAKE_JAVA_INSTALL=1 \
        TUI_ARGS="pg --name linejava --set host=pg.example.com --set database=sales --set user=reader" \
        tui connect-tui-scenario.sh "none" 0 \
        "$(when 'Port [5432]')\r$(when 'Schema [public]')\r$(when 'TLS (verify/require/disable) [verify]')\r$(when 'Enter to skip')\r$(when 'Connect now? [y/N]')y\r$(when 'Password (input hidden):')$TUI_SECRET\r"
    TUI_RAW="$(tr -d '\r' < "$WORK/tui.raw")"
    has "line by line, Java missing: one line says what the kit does and why" "Installing the Java language container for PostgreSQL: about 250 MiB" "$TUI_RAW"
    lacks "...and asks nothing" "Install the Java language container now?" "$TUI_RAW"
    check "...the one question was Connect now?" "1" "$(printf '%s\n' "$TUI_RAW" | grep -c '\[y/N\]')"
    check "...and the source connects after it" "$TUI_SECRET" "$(dbq 'd["connections"]["EXAKIT_SRC_LINEJAVA"]["secret"]')"

    # The command line names the connector and some answers: no menu, no
    # connection string asked for, those answers ticked, only the rest asked. The
    # credential from --password-file, picked in the summary, is kept on Enter.
    printf '%s' "$TUI_SECRET" > "$WORK/tui.pw"
    TTY_REPLAY_RAW="$WORK/tui.raw" \
    TUI_ARGS="pg --name tuiargs --set host=pg.example.com --set database=sales --set user=reader --password-file $WORK/tui.pw" \
        tui connect-tui-scenario.sh "1 of 1 · PostgreSQL" 2 "$Q_PORT\r$Q_SCHEMA\r$Q_TLS\r$Q_CA\r${Q_SUM}7\r$Q_PW\r$Q_SUM\r${Q_GO}y\r"
    check "a named connector skips the menu" "0" "$TUI_RC"
    lacks "...no menu" "Connect external sources" "$TUI_SCREEN"
    lacks "...no connection string asked for" "Connection string" "$(cat "$WORK/tui.raw")"
    has "...the given credential file is used, not asked for" "(read from a file)" "$TUI_SCREEN"
    has "...picked in the summary, Enter keeps it" "Password * (hidden, Enter keeps the one given):" "$(cat "$WORK/tui.raw")"
    has "...and it connects" "✓ VS_TUIARGS · 1 table" "$TUI_SCREEN"
    check "...with the file's credential" "$TUI_SECRET" "$(dbq 'd["connections"]["EXAKIT_SRC_TUIARGS"]["secret"]')"

    # Skip closes the menu with nothing done.
    # Skip sits below every connector of the catalog; the cursor steps over a
    # gated one.
    _skip_keys="$(python3 -c 'import json,sys; print("j" * sum(1 for e in json.load(open(sys.argv[1]))["connectors"] if e.get("status") != "gated"))' "$DEFS/catalog.json")"
    TTY_REPLAY_RAW="$WORK/tui.raw" tui connect-tui-scenario.sh "Connect external sources" 1 "$_skip_keys \r"
    has "Skip: nothing chosen, nothing changed" "Nothing was chosen; nothing was changed." "$TUI_SCREEN"
    check "EXAKIT_NO_IP_LOOKUP=1: no IP line, the menu's own line comes first" \
        "    • Tick one or more sources; the details for each are asked next." \
        "$(python3 -c 'import re, sys; t = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", open(sys.argv[1], encoding="utf-8").read()).replace("\r", ""); print([l for l in t.split("\n") if l.strip()][0])' "$WORK/tui.raw")"
    lacks "...nothing about the public IP anywhere" "public IP" "$(cat "$WORK/tui.raw")"
    has "the menu: the Source column alone" "│     Source " "$TUI_SCREEN"
    lacks "...no Status column in a menu that runs nothing" "Status" "$TUI_SCREEN"
    lacks "...no Version" "Version" "$TUI_SCREEN"
    lacks "...no Release" "Release" "$TUI_SCREEN"

    if command -v pwsh >/dev/null 2>&1; then
        # The PowerShell twin, under the same terminal model. pwsh starts slower:
        # the menu is waited for like every question.
        EXAKIT_NO_IP_LOOKUP= EXAKIT_PUBLIC_IP_URL="$IPURL" tui connect-tui-scenario-ps.sh "1 of 1 · PostgreSQL" 3 \
            "$MENU $MENU\r$Q_PASTE\r${Q_NAME}tuips\r${Q_HOST}localhost\r${Q_HOST}pg.example.com\r$Q_PORT\r${Q_DB}sales\r$Q_SCHEMA\r${Q_USER}reader\r$Q_PW$TUI_SECRET\r$Q_TLS\r$Q_CA\r$Q_SUM\r${Q_GO}y\r"
        check "PowerShell: one menu, one panel, one table" "0" "$TUI_RC"
        has "...its review names this computer's public IP too" "tuips: This computer's public IP is 203.0.113.7" "$TUI_SCREEN"
        has "...and the row ends with the schema" "✓ VS_TUIPS · 1 table" "$TUI_SCREEN"
        lacks "...the credential is not on the screen" "$TUI_SECRET" "$TUI_OUT"
        check "...it reached the CONNECTION" "$TUI_SECRET" "$(dbq 'd["connections"]["EXAKIT_SRC_TUIPS"]["secret"]')"
    else
        pass "PowerShell terminal flow: skipped (no pwsh)"
    fi

    # A 1500-character connection string pasted with a second line after it:
    # read whole at the hidden prompt, the second line answering nothing; then
    # Ctrl-D at the hidden password prompt is the end of input - the source
    # left out. Bash, then PowerShell.
    LONGURL="jdbc:postgresql://pg.example.com:5433/sales?user=reader&ApplicationName=$LONGX"
    TTY_REPLAY_RAW="$WORK/tui.raw" TUI_ARGS="pg" tui connect-tui-scenario.sh "1 of 1 · PostgreSQL" 1 \
        "${Q_PASTE}$(pasted "$LONGURL\rzz2nd\r")${Q_NAME}tuilong\r$Q_SCHEMA\r${Q_PW}\x04"
    check "a 1500-character paste with a second line, then Ctrl-D: one panel" "0" "$TUI_RC"
    has "...the long string was read whole: its port" "$(printf '%-26s  %s' Port '5433 (from the string)')" "$TUI_SCREEN"
    has "...the second line answered nothing: the name is the one typed" "Name for this connection *  tuilong" "$TUI_SCREEN"
    lacks "...and was never shown" "zz2nd" "$(cat "$WORK/tui.raw")"
    has "...Ctrl-D at the hidden prompt left the source out" "Left out: postgresql" "$TUI_SCREEN"
    if command -v pwsh >/dev/null 2>&1; then
        TTY_REPLAY_RAW="$WORK/tui.raw" tui connect-tui-scenario-ps.sh "1 of 1 · PostgreSQL" 2 \
            "$MENU $MENU\r${Q_PASTE}$(pasted "$LONGURL\rzz2nd\r")${Q_NAME}tuipslong\r$Q_SCHEMA\r${Q_PW}\x04"
        check "PowerShell: the same paste and Ctrl-D: one menu, one panel" "0" "$TUI_RC"
        has "...the long string was read whole" "$(printf '%-26s  %s' Port '5433 (from the string)')" "$TUI_SCREEN"
        has "...the second line answered nothing" "Name for this connection *  tuipslong" "$TUI_SCREEN"
        lacks "...and was never shown" "zz2nd" "$(cat "$WORK/tui.raw")"
        has "...Ctrl-D at the hidden prompt left the source out" "Left out: postgresql" "$TUI_SCREEN"
    else
        pass "PowerShell long paste: skipped (no pwsh)"
    fi
fi
# The twins carry the same flow.
for fn in Invoke-ExakitVsTui Invoke-ExakitVsPick Invoke-ExakitVsTuiForm Invoke-ExakitVsTuiRun Test-ExakitVsTuiOk; do
    has "PowerShell has $fn" "function $fn" "$(cat "$ROOT/setup/lib/virtual-schemas.ps1")"
done
has "Invoke-CmdConnect hands a console to it" "Invoke-ExakitVsTui -Source" "$(cat "$ROOT/setup/exakit.ps1")"
has "the menu starts on the first connector on both sides" "-StartRow 1" "$(cat "$ROOT/setup/lib/virtual-schemas.ps1")"
has "...and in bash" "UI_TABLE_MENU_START=1" "$(cat "$ROOT/setup/lib/virtual-schemas.sh")"

printf '\n== a kit update moves connected sources to the adapter it pins ==\n'
# An update changes a connector's pins (connector.json); a source connected
# earlier keeps running what its adapter script names until a check moves it.
# Its own kit home and deployment, so the files it proves are its own.
RP_SAVED_HOME="$HOME_K"; RP_SAVED_DEPLOY="$DEPLOY"; RP_SAVED_EXA="$EXA"
HOME_K="$WORK/kit-repin"; DEPLOY="$WORK/deploy-repin"; EXA="$DEPLOY/local/runtime/exa"
mkdir -p "$HOME_K" "$EXA/bucketfs/bfsdefault/default" "$EXA/jdbc"
cp -R "$RP_SAVED_HOME/cache" "$HOME_K/cache"
cp "$DEFS/connectors/postgresql/connector.json" "$WORK/pg-connector.json"
cp "$DEFS/connectors/mongodb/connector.json" "$WORK/mg-connector.json"
RP_VS="$EXA/bucketfs/bfsdefault/default/exakit/vs"
RP_LOADER="$EXA/jdbc/POSTGRES_JDBC_DRIVER"
rpstate() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"d": d}))' "$HOME_K/sources/$1/state.json" "$2"; }
rpreg() { python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["artifacts"]; print(json.dumps(sorted(next((v["consumers"] for k, v in r.items() if k.endswith(sys.argv[2])), []))))' "$HOME_K/sources/registry.json" "$1"; }
repin() {
    python3 - "$DEFS" "$HOME_K" "$@" <<'PY'
import hashlib, json, os, sys
defs, home, cid, version = sys.argv[1:5]
def seed(pin, data):
    pin["size"], pin["sha256"] = len(data), hashlib.sha256(data).hexdigest()
    folder = os.path.join(home, "cache", "virtual-schemas", pin["sha256"])
    os.makedirs(folder, exist_ok=True)
    open(os.path.join(folder, pin["asset"]), "wb").write(data)
path = os.path.join(defs, "connectors", cid, "connector.json")
doc = json.load(open(path))
old = doc["adapter"]["version"]
doc["adapter"]["version"] = version
if cid == "postgresql":
    doc["adapter"]["asset"] = doc["adapter"]["asset"].replace(old, version)
    seed(doc["adapter"], ("adapter-postgresql-" + version).encode())
    if len(sys.argv) > 5:
        doc["driver"]["asset"] = doc["driver"]["asset"].replace(doc["driver"]["version"], sys.argv[5])
        doc["driver"]["version"] = sys.argv[5]
        seed(doc["driver"], ("driver-postgresql-" + sys.argv[5]).encode())
else:
    for arch, pin in doc["adapter"]["arch"].items():
        pin["asset"] = pin["asset"].replace(old, version)
        seed(pin, ("adapter-mongodb-%s-%s" % (version, arch)).encode())
json.dump(doc, open(path, "w"), indent=2)
PY
}
db '{"sources": {"a.example.com": {"tables": ["T1"]}, "b.example.com": {"tables": ["T2"]}, "c.example.com": {"tables": ["T3"]},
                 "cluster0.example.net": {"tables": ["MOVIES"], "secret": "'"$SECRET"'"}}}'
RP_RC=""
for n in a b c; do
    run_secret "$SECRET" connect postgresql --name rp_$n --set host=$n.example.com --set database=$n --set user=reader --secret-stdin
    RP_RC="$RP_RC$RC"
done
run_secret "$SECRET" connect mongodb --name rp_m1 $MG_SET --set collection=movies --secret-stdin; RP_RC="$RP_RC$RC"
run_secret "$SECRET" connect mongodb --name rp_m2 $MG_SET --set collection=theaters --secret-stdin; RP_RC="$RP_RC$RC"
run disconnect rp_c; RP_RC="$RP_RC$RC"
check "three PostgreSQL sources (one disconnected) and two MongoDB sources connected" "000000" "$RP_RC"
run check rp_a
check "on the pins it was connected with, a check moves nothing" "0" "$RC"
lacks "...and says nothing of a move" "Moved" "$OUT"

OLD_JAR="$RP_VS/postgresql/4.1.0/virtual-schema-dist-14.1.0-postgresql-4.1.0.jar"
NEW_JAR="$RP_VS/postgresql/4.2.0/virtual-schema-dist-14.2.0-postgresql-4.2.0.jar"
OLD_DRV="$RP_VS/postgresql/driver-42.7.14/postgresql-42.7.14.jar"
repin postgresql 4.2.0 42.7.15
# rp_b's script cannot be re-created this time: it stays on the old adapter.
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["script_fail"]=["EXAKIT_VS.ADAPTER_RP_B"]; json.dump(d, open(sys.argv[1],"w"))' "$STATE"
N0="$(dbq 'len(d["statements"])')"
run check rp_a
check "after the update, check rp_a: exit 0" "0" "$RC"
has "...it moved, in plain words" "Moved rp_a from PostgreSQL adapter 4.1.0 to 4.2.0 and driver 42.7.14 to 42.7.15" "$OUT"
check "...the staging said once for the three sources" "1" "$(printf '%s\n' "$OUT" | grep -c 'Adapter 4.2.0 and driver 42.7.15 verified and staged')"
RPA_SQL="$(dbq '[s for s in d["statements"]['"$N0"':] if "ADAPTER SCRIPT \"EXAKIT_VS\".\"ADAPTER_RP_A\"" in s][-1]')"
has "...its script re-created over the new adapter" "%jar /buckets/bfsdefault/default/exakit/vs/postgresql/4.2.0/virtual-schema-dist-14.2.0-postgresql-4.2.0.jar;" "$RPA_SQL"
has "...and the new driver" "%jar /buckets/bfsdefault/default/exakit/vs/postgresql/driver-42.7.15/postgresql-42.7.15.jar;" "$RPA_SQL"
has "...with CREATE OR REPLACE" "CREATE OR REPLACE JAVA ADAPTER SCRIPT" "$RPA_SQL"
check "...its virtual schema refreshed, the new pins recorded, nothing left to refresh" "1 4.2.0 42.7.15 False" \
    "$(dbq 'sum(s == "ALTER VIRTUAL SCHEMA \"VS_RP_A\" REFRESH" for s in d["statements"]['"$N0"':])') $(rpstate rp_a 'd["pins"]["adapter_version"]') $(rpstate rp_a 'd["pins"]["driver_version"]') $(rpstate rp_a '"needs_refresh" in d')"
has "the disconnected source moved too (the connector's sources move together)" "Moved rp_c from PostgreSQL adapter 4.1.0 to 4.2.0" "$OUT"
check "...its script re-created, no refresh tried, needs_refresh recorded" "1 0 4.2.0 True" \
    "$(dbq 'sum("ADAPTER_RP_C" in s and "4.2.0" in s for s in d["statements"]['"$N0"':])') $(dbq 'sum("VS_RP_C" in s and "REFRESH" in s for s in d["statements"]['"$N0"':])') $(rpstate rp_c 'd["pins"]["adapter_version"]') $(rpstate rp_c 'd.get("needs_refresh")')"
has "...said with how it ends" "rp_c is disconnected: its virtual schema is refreshed when it is connected again" "$OUT"
has "a script that could not be re-created is said, with the retry" "Could not move rp_b to PostgreSQL adapter 4.2.0" "$OUT"
has "...and the command" "exakit source check rp_b" "$OUT"
check "...rp_b keeps its old pins" "4.1.0" "$(rpstate rp_b 'd["pins"]["adapter_version"]')"
check "the old adapter and driver stay while rp_b uses them, the new ones are staged" "yes yes yes" \
    "$([ -f "$OLD_JAR" ] && echo yes) $([ -f "$OLD_DRV" ] && echo yes) $([ -f "$NEW_JAR" ] && echo yes)"
check "...the registry names rp_b alone as the old adapter's consumer" '["rp_b"]' "$(rpreg postgresql/4.1.0/virtual-schema-dist-14.1.0-postgresql-4.1.0.jar)"
check "...and the new one's consumers are the moved sources" '["rp_a", "rp_c"]' "$(rpreg postgresql/4.2.0/virtual-schema-dist-14.2.0-postgresql-4.2.0.jar)"
check "the loader runs the new driver; the old one stays for rp_b" "JAR=postgresql-42.7.15.jar yes" \
    "$(grep '^JAR=' "$RP_LOADER/settings.cfg") $([ -f "$RP_LOADER/postgresql-42.7.14.jar" ] && echo yes)"

# Now rp_b's script can be re-created, but its source does not answer the refresh.
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.pop("script_fail"); d["refresh_fail"]=["VS_RP_B"]; json.dump(d, open(sys.argv[1],"w"))' "$STATE"
run --json check --all
has "check --all moves the one left behind" "Moved rp_b from PostgreSQL adapter 4.1.0 to 4.2.0" "$OUT"
has "...a refresh that fails is said, with the repair" "rp_b moved, but its virtual schema did not refresh" "$OUT"
has "...and the command" "repair it with: exakit source refresh rp_b" "$OUT"
check "...said once, though check --all reaches rp_b again" "1" "$(printf '%s\n' "$OUT" | grep -c 'rp_b moved')"
check "...its new pins are recorded all the same, marked needs_refresh" "4.2.0 True" \
    "$(rpstate rp_b 'd["pins"]["adapter_version"]') $(rpstate rp_b 'd.get("needs_refresh")')"
check "the last consumer gone: the old adapter, driver and loader jar are deleted, with their folders" "no no no no" \
    "$([ -f "$OLD_JAR" ] && echo yes || echo no) $([ -d "$RP_VS/postgresql/4.1.0" ] && echo yes || echo no) $([ -d "$RP_VS/postgresql/driver-42.7.14" ] && echo yes || echo no) $([ -f "$RP_LOADER/postgresql-42.7.14.jar" ] && echo yes || echo no)"
check "...the new files and the bucket stay" "yes yes yes" \
    "$([ -f "$NEW_JAR" ] && echo yes) $([ -f "$RP_LOADER/postgresql-42.7.15.jar" ] && echo yes) $([ -d "$EXA/bucketfs/bfsdefault/default" ] && echo yes)"
run --json list
has "list shows needs_refresh" '"needs_refresh": true' "$OUT"
run --json show rp_b
has "show shows it" '"needs_refresh": true' "$OUT"
run --json issues
has "issues names it with the repair" "exakit source refresh rp_b" "$OUT"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.pop("refresh_fail"); json.dump(d, open(sys.argv[1],"w"))' "$STATE"
run refresh rp_b
check "refresh clears needs_refresh" "0 False" "$RC $(rpstate rp_b '"needs_refresh" in d')"

N1="$(dbq 'len(d["statements"])')"
run --json check --all
lacks "a second check --all moves nothing" "Moved" "$OUT"
check "...and re-creates no script, refreshes no schema" "0" \
    "$(dbq 'sum("ADAPTER SCRIPT" in s or "REFRESH" in s for s in d["statements"]['"$N1"':])')"

run_secret "$SECRET" connect postgresql --name rp_c --secret-stdin
check "reconnecting the moved source: exit 0, its schema refreshed, needs_refresh cleared" "0 1 False 4.2.0" \
    "$RC $(dbq 'sum(s == "ALTER VIRTUAL SCHEMA \"VS_RP_C\" REFRESH" for s in d["statements"]['"$N1"':])') $(rpstate rp_c '"needs_refresh" in d') $(rpstate rp_c 'd["pins"]["adapter_version"]')"

# A pin that cannot be fetched (here: not HTTPS, never cached) moves nothing.
cp "$DEFS/connectors/postgresql/connector.json" "$WORK/pg-420.json"
python3 - "$DEFS/connectors/postgresql/connector.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["adapter"].update(version="9.9.9", asset="vs-9.9.9.jar", url="http://example.com/vs-9.9.9.jar", sha256="0" * 64, size=1)
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PY
CFG_BEFORE="$(cat "$RP_LOADER/settings.cfg")"
run check rp_a
check "an adapter that cannot be fetched: the check still runs, exit 0" "0" "$RC"
has "...the move is said not to have happened, with the retry" "Could not move the PostgreSQL sources rp_a, rp_b, rp_c to adapter 9.9.9" "$OUT"
check "...pins, staged files and the loader are as they were" "4.2.0 no yes" \
    "$(rpstate rp_a 'd["pins"]["adapter_version"]') $([ -d "$RP_VS/postgresql/9.9.9" ] && echo yes || echo no) $([ "$CFG_BEFORE" = "$(cat "$RP_LOADER/settings.cfg")" ] && echo yes)"
cp "$WORK/pg-420.json" "$DEFS/connectors/postgresql/connector.json"

# A shared adapter (MongoDB: one script every source runs) moves them all at once.
MG_OLD_DIR="$RP_VS/mongodb/0.1.3"
repin mongodb 0.1.4
N2="$(dbq 'len(d["statements"])')"
run check rp_m1
check "MongoDB after the update: exit 0" "0" "$RC"
has "...both sources moved" "Moved rp_m1 from MongoDB adapter 0.1.3 to 0.1.4" "$OUT"
has "...the other one too" "Moved rp_m2 from MongoDB adapter 0.1.3 to 0.1.4" "$OUT"
check "...the shared adapter and its scan UDF re-created once, both schemas refreshed" "1 1 1 1" \
    "$(dbq 'sum("RUST ADAPTER SCRIPT \"EXAKIT_VS\".\"MONGODB_ADAPTER\"" in s for s in d["statements"]['"$N2"':])') $(dbq 'sum("\"MONGODB_SCAN\"" in s and s.startswith("CREATE") for s in d["statements"]['"$N2"':])') $(dbq 'sum(s == "ALTER VIRTUAL SCHEMA \"VS_RP_M1\" REFRESH" for s in d["statements"]['"$N2"':])') $(dbq 'sum(s == "ALTER VIRTUAL SCHEMA \"VS_RP_M2\" REFRESH" for s in d["statements"]['"$N2"':])')"
has "...the adapter loads the new .so" "%udf_object /buckets/bfsdefault/default/exakit/vs/mongodb/0.1.4/exasol-mongodb-vs-0.1.4-linux-" \
    "$(dbq '[s for s in d["statements"]['"$N2"':] if "MONGODB_ADAPTER" in s][-1]')"
check "...both record the new pins; the old .so is deleted" "0.1.4 0.1.4 no" \
    "$(rpstate rp_m1 'd["pins"]["adapter_version"]') $(rpstate rp_m2 'd["pins"]["adapter_version"]') $([ -d "$MG_OLD_DIR" ] && echo yes || echo no)"
N3="$(dbq 'len(d["statements"])')"
run check rp_m2
lacks "...a second check moves nothing" "Moved" "$OUT"
check "...nor re-creates the script" "0" "$(dbq 'sum("MONGODB_ADAPTER" in s for s in d["statements"]['"$N3"':])')"

# A new connect re-creates the shared script with the pins of the day: the
# sources already there move with it, recorded as such.
repin mongodb 0.1.5
run_secret "$SECRET" connect mongodb --name rp_m3 $MG_SET --set collection=comments --secret-stdin
check "a new MongoDB connect after an update: exit 0" "0" "$RC"
has "...the sources already there moved first" "Moved rp_m1 from MongoDB adapter 0.1.4 to 0.1.5" "$OUT"
check "...all three record the pins the shared script runs; the old .so is gone" "0.1.5 0.1.5 0.1.5 no" \
    "$(rpstate rp_m1 'd["pins"]["adapter_version"]') $(rpstate rp_m2 'd["pins"]["adapter_version"]') $(rpstate rp_m3 'd["pins"]["adapter_version"]') $([ -d "$RP_VS/mongodb/0.1.4" ] && echo yes || echo no)"

cp "$WORK/pg-connector.json" "$DEFS/connectors/postgresql/connector.json"
cp "$WORK/mg-connector.json" "$DEFS/connectors/mongodb/connector.json"
HOME_K="$RP_SAVED_HOME"; DEPLOY="$RP_SAVED_DEPLOY"; EXA="$RP_SAVED_EXA"

printf '\n== a pasted connection string: exakit connect <connector> --url ==\n'
# eng paste reads the string on stdin and answers the inputs it names; each
# value passes the same check a --set gets. A credential in the string is never
# used or echoed, other parameters are dropped by name, and no message quotes
# the string.
pst() { # pst <connector> <string> - OUT, RC, VALS (the values, sorted JSON)
    OUT="$(printf '%s' "$2" | eng paste "$1" 2>&1)"; RC=$?
    VALS="$(printf '%s\n' "$OUT" | sed -n 's/^RESULT //p' | python3 -c 'import json, sys; print(json.dumps(json.load(sys.stdin)["values"], sort_keys=True))' 2>/dev/null)"
}
while IFS='|' read -r _c _u _v; do
    [ -n "$_c" ] || continue
    pst "$_c" "$_u"
    check "paste $_c: $_u" "0 $_v" "$RC $VALS"
done <<'EOF'
pg|jdbc:postgresql://pg.example.com:6432/sales?currentSchema=ops&sslmode=verify-full|{"database": "sales", "host": "pg.example.com", "port": "6432", "schema": "ops", "tls": "verify"}
pg|postgres://reader@pg.example.com/sales?sslmode=prefer|{"database": "sales", "host": "pg.example.com", "tls": "require", "user": "reader"}
pg|postgresql://pg.example.com/sales?user=bob&sslmode=disable|{"database": "sales", "host": "pg.example.com", "tls": "disable", "user": "bob"}
pg|pg.example.com:5433/sales|{"database": "sales", "host": "pg.example.com", "port": "5433"}
pg|postgres://reader@[2001:db8::5]:5432/sales?sslmode=verify-ca|{"database": "sales", "host": "2001:db8::5", "port": "5432", "tls": "verify", "user": "reader"}
mysql|jdbc:mysql://my.example.com:3307/shop?sslMode=VERIFY_CA&user=reader|{"database": "shop", "host": "my.example.com", "port": "3307", "tls": "verify", "user": "reader"}
mysql|mysql://reader@my.example.com/shop?sslMode=REQUIRED&useSSL=false|{"database": "shop", "host": "my.example.com", "tls": "require", "user": "reader"}
mysql|jdbc:mysql://my.example.com/shop?useSSL=false|{"database": "shop", "host": "my.example.com", "tls": "disable"}
mysql|jdbc:mysql://my.example.com/shop?sslMode=DISABLED|{"database": "shop", "host": "my.example.com", "tls": "disable"}
mssql|jdbc:sqlserver://sql.example.com:1433;databaseName=erp;encrypt=true;trustServerCertificate=true;user=reader|{"database": "erp", "host": "sql.example.com", "port": "1433", "tls": "require", "user": "reader"}
mssql|jdbc:sqlserver://sql.example.com;databaseName=erp;encrypt=strict;trustServerCertificate=true|{"database": "erp", "host": "sql.example.com", "tls": "verify"}
mssql|jdbc:sqlserver://sql.example.com;database=erp;encrypt=true|{"database": "erp", "host": "sql.example.com", "tls": "verify"}
mssql|jdbc:sqlserver://sql.example.com;databaseName=erp;encrypt=false|{"database": "erp", "host": "sql.example.com", "tls": "disable"}
mssql|jdbc:sqlserver://;serverName=sql.example.com;portNumber=1500;databaseName=erp|{"database": "erp", "host": "sql.example.com", "port": "1500"}
oracle|jdbc:oracle:thin:@//ora.example.com:1521/ORCLPDB1|{"host": "ora.example.com", "port": "1521", "service": "ORCLPDB1"}
oracle|jdbc:oracle:thin:@tcps://ora.example.com:2484/ORCLPDB1|{"host": "ora.example.com", "port": "2484", "service": "ORCLPDB1", "tls": "verify"}
oracle|ora.example.com:1521/ORCLPDB1|{"host": "ora.example.com", "port": "1521", "service": "ORCLPDB1"}
snowflake|jdbc:snowflake://myorg-acct.snowflakecomputing.com/?db=sales&warehouse=wh&schema=public&role=reader&user=bob|{"account": "myorg-acct", "database": "SALES", "role": "reader", "schema": "PUBLIC", "user": "bob", "warehouse": "WH"}
snowflake|https://myorg-acct.snowflakecomputing.com|{"account": "myorg-acct"}
databricks|jdbc:databricks://dbc-1234abcd-5678.cloud.databricks.com:443/default;transportMode=http;ssl=1;AuthMech=3;httpPath=/sql/1.0/warehouses/abc123;UID=token;ConnCatalog=main;ConnSchema=sales|{"catalog": "main", "host": "dbc-1234abcd-5678.cloud.databricks.com", "http_path": "/sql/1.0/warehouses/abc123", "schema": "sales"}
databricks|jdbc:spark://dbc-1234abcd-5678.cloud.databricks.com:443/default;httpPath=sql/protocolv1/o/123/0123-abc|{"host": "dbc-1234abcd-5678.cloud.databricks.com", "http_path": "/sql/protocolv1/o/123/0123-abc"}
mongodb|mongodb+srv://reader@cluster0.abc12.mongodb.net/movies?retryWrites=true&authSource=admin|{"database": "movies", "uri": "mongodb+srv://cluster0.abc12.mongodb.net/?retryWrites=true&authSource=admin", "user": "reader"}
mongodb|mongodb://h1.example.com:27017,h2.example.com:27017/films|{"database": "films", "uri": "mongodb://h1.example.com:27017,h2.example.com:27017"}
s3|s3://my-bucket/docs/|{"bucket": "my-bucket"}
s3|https://my-bucket.s3.eu-central-1.amazonaws.com/docs/a.json|{"bucket": "my-bucket", "region": "eu-central-1"}
azure|https://mystorage.blob.core.windows.net/data|{"account": "mystorage", "container": "data"}
azure|abfss://data@mystorage.dfs.core.windows.net/raw|{"account": "mystorage", "container": "data"}
bq|jdbc:bigquery://https://www.googleapis.com/bigquery/v2:443;ProjectId=my-project;OAuthType=0;DefaultDataset=sales|{"dataset": "sales", "project": "my-project"}
lakehouse|https://glue.eu-central-1.amazonaws.com|{"region": "eu-central-1"}
lakehouse|arn:aws:glue:eu-central-1:123456789012:database/sales_lake|{"database": "sales_lake", "region": "eu-central-1"}
iceberg-rest|https://catalog.example.com:8181/api/catalog/|{"catalog_url": "https://catalog.example.com:8181/api/catalog"}
unity|https://dbc-1234abcd-5678.cloud.databricks.com|{"workspace_url": "https://dbc-1234abcd-5678.cloud.databricks.com"}
EOF
check "every connector reads a connection string, into its own inputs only" "ok" "$(python3 - "$DEFS" <<'PY2'
import json, os, sys
for cid in sorted(os.listdir(os.path.join(sys.argv[1], "connectors"))):
    doc = json.load(open(os.path.join(sys.argv[1], "connectors", cid, "connector.json")))
    names = {s["name"] for s in doc["inputs"] if s["kind"] not in ("secret", "secret-file")}
    block = doc.get("paste")
    if not block or not block.get("forms") or not set(block.get("params", {}).values()) <= names \
            or block.get("path", "host") not in names | {"host"}:
        print("bad: " + cid); break
else:
    print("ok")
PY2
)"

PW='Hunter2-pa55'
for _case in "pg|postgres://reader:$PW@pg.example.com/sales" "pg|jdbc:postgresql://pg.example.com/sales?user=reader&password=$PW" \
             "mssql|jdbc:sqlserver://sql.example.com;databaseName=erp;user=reader;password=$PW" \
             "oracle|jdbc:oracle:thin:reader/$PW@//ora.example.com:1521/ORCLPDB1" \
             "snowflake|jdbc:snowflake://myorg-acct.snowflakecomputing.com/?db=sales&warehouse=wh&token=$PW" \
             "databricks|jdbc:databricks://dbc-1.cloud.databricks.com:443/default;httpPath=/sql/1.0/warehouses/abc;UID=token;PWD=$PW" \
             "mongodb|mongodb+srv://reader:$PW@cluster0.abc12.mongodb.net/movies?authMechanismProperties=AWS_SESSION_TOKEN:$PW" \
             "s3|https://my-bucket.s3.eu-central-1.amazonaws.com/a.json?X-Amz-Credential=AKIA&X-Amz-Signature=$PW" \
             "azure|https://mystorage.blob.core.windows.net/data?sv=2022-11-02&sp=rl&sig=$PW" \
             "azure|DefaultEndpointsProtocol=https;AccountName=mystorage;AccountKey=$PW;EndpointSuffix=core.windows.net" \
             "iceberg-rest|https://ak:$PW@catalog.example.com/api" "unity|https://dbc-1.cloud.databricks.com/?token=$PW"; do
    pst "${_case%%|*}" "${_case#*|}"
    check "a credential in the string is not used (${_case%%|*}), exit 0" "0" "$RC"
    lacks "...and is in none of the output" "$PW" "$OUT"
    has "...the note says it was ignored and is asked for separately" "it was not used. The credential is asked for separately" "$OUT"
    has "...and that the string was on the command line" "The string was on the command line" "$OUT"
done
lacks "a credential never becomes an input value" '"password"' "$VALS"
pst mongodb "mongodb+srv://reader:$PW@cluster0.abc12.mongodb.net/movies?retryWrites=true&authMechanismProperties=AWS_SESSION_TOKEN:$PW"
check "mongodb: the uri keeps no credentials and no path" '{"database": "movies", "uri": "mongodb+srv://cluster0.abc12.mongodb.net/?retryWrites=true", "user": "reader"}' "$VALS"
pst mongodb "mongodb+srv://reader@cluster0.abc12.mongodb.net/movies?retryWrites=true&authSource=sales"
check "mongodb: a string with authSource=sales is refused, exit 2 - the adapter signs in against admin" "2" "$RC"
has "...in one line, with the fix" \
    "the MongoDB adapter always signs in against the admin database, so an authSource other than admin cannot work: make the reader a user of admin and drop authSource or set it to admin" "$OUT"
lacks "...the value not quoted" "sales" "$OUT"
pst mongodb "mongodb+srv://reader@cluster0.abc12.mongodb.net/movies?authSource=admin"
check "mongodb: authSource=admin is read" '0 {"database": "movies", "uri": "mongodb+srv://cluster0.abc12.mongodb.net/?authSource=admin", "user": "reader"}' "$RC $VALS"
pst mongodb "mongodb+srv://reader@cluster0.abc12.mongodb.net/movies"
check "...and so is no authSource" '0 {"database": "movies", "uri": "mongodb+srv://cluster0.abc12.mongodb.net", "user": "reader"}' "$RC $VALS"
pst pg 'jdbc:postgresql://h/db?user=r&password=Abc&Xyz9'
lacks "a password with an unencoded & does not leak its tail as a setting's name" "Xyz9" "$OUT"
has "...the tail is counted instead" "1 more part of the connection string could not be read" "$OUT"
pst mysql 'jdbc:mysql://my.example.com/shop?user=r&password=Abc&Xyz9'
lacks "...MySQL too" "Xyz9" "$OUT"
pst pg 'jdbc:postgresql://pg.example.com/sales?ApplicationName=report-x9&sslrootcert=/etc/ca.pem&password=zz'
has "unknown parameters are dropped by name" "Not used from the connection string: ApplicationName, sslrootcert" "$OUT"
lacks "...never by value" "report-x9" "$OUT"
has "...and listed" '"dropped": ["ApplicationName", "sslrootcert", "password"]' "$OUT"
pst databricks 'jdbc:databricks://dbc-1.cloud.databricks.com:443/default;transportMode=http;ssl=1;AuthMech=3;httpPath=/sql/1.0/warehouses/abc;UID=token'
lacks "...what the kit sets itself is consumed without a note" "Not used" "$OUT"
pst bq 'jdbc:bigquery://https://www.googleapis.com/bigquery/v2:443;ProjectId=p1;OAuthPvtKeyPath=/keys/k.json;DefaultDataset=d1'
has "a key file's path is dropped by name, not taken for a credential" "Not used from the connection string: OAuthPvtKeyPath" "$OUT"
lacks "...so no credential note" "held a credential" "$OUT"

pst oracle 'jdbc:oracle:thin:@//ora.example.com:1521/ORCLPDB1'
has "oracle over plain TCP: tls is left at its default, with a note" "uses plain TCP; tls stays at verify" "$OUT"
lacks "...never silently downgraded" '"tls"' "$VALS"
pst pg 'postgres://pg.example.com/sales?sslmode=allow'
has "a TLS value the kit does not map is said, not guessed" "sslmode has a value the kit does not map; tls stays as asked (default verify)" "$OUT"
pst pg 'jdbc:postgresql://localhost:5432/sales'
check "localhost from the string is not taken, exit 0" '0 {"database": "sales", "port": "5432"}' "$RC $VALS"
has "...with the address to use instead" "on macOS 192.168.64.1" "$OUT"
printf '{"runtime": {"type": "personal", "engine": "docker"}}\n' > "$HOME_K/manifest.json"
export EXAKIT_VS_OS=Linux
pst pg 'jdbc:postgresql://localhost:5432/sales'
has "...on a Docker deployment, Docker's address, still said in full" "$DOCKER_HOST_WORDS" "$OUT"
unset EXAKIT_VS_OS
rm -f "$HOME_K/manifest.json"
pst pg 'postgres://pg.example.com:99999/sales'
has "a value that fails its check is named, not quoted" "port from the connection string is not used: it is not a valid port" "$OUT"
lacks "...(no value in the message)" "99999" "$OUT"

for _case in "oracle|jdbc:oracle:thin:@orahost-zz9.example.com:1521:ORCLZZ|Oracle SID" \
             "oracle|jdbc:oracle:thin:@(DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=orahost-zz9)(PORT=1521))(CONNECT_DATA=(SERVICE_NAME=s)))|TNS descriptor" \
             "mssql|jdbc:sqlserver://sqlhost-zz9.example.com\\SQLEXPRESS;databaseName=erp|named instance" \
             "mssql|jdbc:sqlserver://;serverName=sqlhost-zz9.example.com;instanceName=SQLEXPRESS|named instance" \
             "pg|jdbc:postgresql://pghost-zz9.example.com,pg2.example.com/sales|more than one host" \
             "pg|jdbc:mysql://pghost-zz9.example.com/sales|does not read this as a PostgreSQL connection string; it reads: jdbc:postgresql://" \
             "snowflake|https://app.snowflake.com/zz9/acct|not <account>.snowflakecomputing.com" \
             "s3|https://storage.googleapis.com/zz9-bucket|does not read this as a Amazon S3" \
             "pg|postgres://reader:pa?zz9;w@pg.example.com/sales|must be percent-encoded" \
             "pg|postgres://pg.example.com/sales zz9|on one line"; do
    _c="${_case%%|*}"; _r="${_case#*|}"; _u="${_r%|*}"; _why="${_r##*|}"
    pst "$_c" "$_u"
    check "refused, exit 2: $_why" "2" "$RC"
    has "...saying why" "$_why" "$OUT"
    lacks "...without quoting the string" "zz9" "$OUT"
done
OUT="$(printf '' | eng paste pg 2>&1)"; RC=$?
check "an empty string is refused" "2 FAIL no connection string was given" "$RC $OUT"
OUT="$(printf '%s' 'cG9zdGdyZXM6Ly9yZWFkZXJAcGcuZXhhbXBsZS5jb20vc2FsZXM=' | eng paste pg --base64 2>&1)"
has "the Windows bridge's base64 is decoded first" '"values": {"host": "pg.example.com", "database": "sales", "user": "reader"}' "$OUT"

# The shell path: cmd_connect with the shipping libraries and the real engine
# on the simulated database; the engine's arguments are recorded.
urlsh() {
    ( EXAKIT_HOME="$HOME_K"
      . "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/virtual-schemas.sh"
      _require_install() { :; }; exakit_init_logging() { EXAKIT_LOG_FILE="$WORK/url.log"; }
      command -v reject >/dev/null 2>&1 || reject() { printf '%s\n' "$*" >&2; exit 2; }
      pyexasol_venv_python() { command -v python3; }
      exakit_vs_engine() { printf '%s\n' "$*" >> "$WORK/url.argv"; eng "$@"; }
      "$@" ) 2>&1
}
db '{"sources": {"pg.example.com": {"tables": ["ORDERS"]}}}'
rm -f "$WORK/url.argv"
OUT="$(urlsh cmd_connect pg --name urlpg --url "postgres://reader:$PW@pg.example.com:5433/sales?sslmode=require" --set port=5432 --dry-run </dev/null)"; RC=$?
check "connect --url --dry-run: exit 0" "0" "$RC"
check "...the string went to paste on stdin; its inputs come before the command line's --set, which wins" \
    "paste pg|resolve pg|plan postgresql --name urlpg --set host=pg.example.com --set port=5433 --set database=sales --set user=reader --set tls=require --set port=5432|" \
    "$(tr '\n' '|' < "$WORK/url.argv")"
has "...its notes are shown" "The string was on the command line" "$OUT"
has "...the plan reflects it" "does NOT check the server's identity" "$OUT"
lacks "...the password is in no argument" "$PW" "$(cat "$WORK/url.argv")"
lacks "...and not in the output" "$PW" "$OUT"
lacks "...nor the log" "$PW" "$(cat "$WORK/url.log" 2>/dev/null)"
rm -f "$WORK/url.argv"
OUT="$(urlsh cmd_connect pg --name urlpg --url=postgres://pg.example.com/sales?sslmode=require --set tls=verify --set user=reader --dry-run </dev/null)"; RC=$?
check "--url=STRING works too, and --set tls overrides the string's sslmode" "0" "$RC"
lacks "...so no TLS warning" "does NOT check" "$OUT"
OUT="$(urlsh cmd_connect pg --name urlamp --url 'jdbc:postgresql://h/db?user=r&password=Abc&Xyz9' --dry-run </dev/null)"
lacks "--url: a password's unencoded & leaks no name either" "Xyz9" "$OUT"
OUT="$(urlsh cmd_connect --name urlpg --url postgres://pg.example.com/sales --dry-run </dev/null)"; RC=$?
check "--url without a connector is refused, exit 2" "2" "$RC"
has "...saying what it needs" "--url needs the source it is for" "$OUT"
rm -f "$WORK/url.argv"
OUT="$(urlsh cmd_connect oracle --name urlora --url 'jdbc:oracle:thin:@ora.example.com:1521:ORCL' --dry-run </dev/null)"; RC=$?
check "a refused string stops connect before any plan, exit 2" "2 paste oracle|" "$RC $(tr '\n' '|' < "$WORK/url.argv")"
printf '%s' "$PW" > "$WORK/url.pw"
OUT="$(urlsh cmd_connect pg --name urlsales --url 'jdbc:postgresql://pg.example.com/sales?user=reader' --password-file "$WORK/url.pw" --yes </dev/null)"; RC=$?
check "connect --url --yes with a password file: exit 0" "0" "$RC"
check "...the credential reached the CONNECTION from the file" "$PW" "$(dbq 'd["connections"]["EXAKIT_SRC_URLSALES"]["secret"]')"
has "...and the string's inputs are the ones recorded" '"host": "pg.example.com"' "$(cat "$HOME_K/sources/urlsales/"*.json 2>/dev/null)"

# On a terminal the panel opens with the string's answers in it.
printf '%s' "$TUI_SECRET" > "$WORK/tui.pw"
TUI_ARGS="pg --name tuiurl --url postgres://reader@pg.example.com/sales --password-file $WORK/tui.pw" \
    tui connect-tui-scenario.sh "1 of 1 · PostgreSQL" 2 "$Q_PORT\r$Q_SCHEMA\r$Q_TLS\r$Q_CA\r$Q_SUM\r${Q_GO}y\r"
check "the terminal flow with --url: one panel, one table" "0" "$TUI_RC"
has "...the panel holds the string's host" "Host name or address *      pg.example.com" "$TUI_SCREEN"
has "...and it connects" "✓ VS_TUIURL · 1 table" "$TUI_SCREEN"
has "PowerShell parses --url too" '$arg -eq "--url"' "$(cat "$ROOT/setup/exakit.ps1")"

printf '\n== the connect form: a red * for a required field, a pasted string, one answer changed ==\n'
# What a person sees on the way (TTY_REPLAY_RAW: the whole stream, colours out)
# as well as what the screen is left holding. The pasted string carries a
# password: it is read hidden, not used, the hidden prompt still asks, and the
# CONNECTION gets the typed one.
if command -v python3 >/dev/null 2>&1; then
    URLPW='Url-pa55-zz7'
    RAW="$WORK/tui.raw"
    # A PostgreSQL panel row: label, value. The label column holds a required
    # field's " *" (26: "Name for this connection *").
    prow() { printf '%-26s  %s' "$1" "$2"; }
    # Enter on a required name is refused; on an optional one with a default
    # (schema) it takes it, on one without (ca) it leaves it empty; 3 asks the
    # port again.
    TTY_REPLAY_RAW="$RAW" TUI_ARGS="pg" tui connect-tui-scenario.sh "1 of 1 · PostgreSQL" 2 \
        "${Q_PASTE}postgres://reader:$URLPW@pg.example.com:5433/sales\r$Q_NAME\r${Q_NAME}tuipaste\r$Q_SCHEMA\r$Q_PW\r$Q_PW$TUI_SECRET\r$Q_TLS\r$Q_CA\r${Q_SUM}3\r$(when 'Port (- clears it)')5432\r$Q_SUM\r${Q_GO}y\r"
    check "a pasted string, a refused Enter, one answer changed: one panel, one table" "0" "$TUI_RC"
    TUI_RAW="$(tr -d '\r' < "$RAW")"
    has "the panel marks a required field with a star after its label" "│     Host name or address *      " "$TUI_RAW"
    has "...an optional one has no star, and keeps its default" "$(prow Port '[5432]')" "$TUI_RAW"
    lacks "...no star on an optional one" "Port *" "$TUI_RAW"
    has "...one legend line in the box says what the star means" "│     * required " "$TUI_RAW"
    lacks "...and the words are gone" "(required)" "$TUI_RAW"
    lacks "...both of them" "(optional)" "$TUI_RAW"
    has "the first question is the connection string, read hidden" "Connection string (hidden; Enter to type the fields):" "$TUI_RAW"
    has "...its help names the forms the connector reads" "as it shows it: jdbc:postgresql://host:5432/db," "$TUI_RAW"
    has "...all of them" "postgres://user@host:5432/db or host[:port][/database]" "$TUI_RAW"
    lacks "...the string, password and all, is in nothing drawn" "$URLPW" "$TUI_RAW"
    has "the question ends in the star too" "Name for this connection *:" "$TUI_RAW"
    has "...Enter on an empty required field is refused, in one line" "Name for this connection is required" "$TUI_RAW"
    has "...an optional one shows the default Enter takes, no star" "Schema [public]:" "$TUI_RAW"
    has "the fields the string filled are marked" "$(prow 'Host name or address *' 'pg.example.com (from the string)')" "$TUI_SCREEN"
    lacks "...and not asked" "Host name or address *:" "$TUI_RAW"
    has "a password in the string: the note says it was not used" "(a password, token or key): it was not used." "$TUI_SCREEN"
    lacks "...without the command-line sentence a typed string does not earn" "The string was on the command line" "$TUI_RAW"
    has "...and the hidden prompt still asks for it" "Password * (hidden):" "$TUI_RAW"
    has "...whose empty answer is refused too" "Password is required; it stays in memory" "$TUI_RAW"
    has "the summary numbers every answer" "  3  $(prow Port '5433 (from the string)')" "$TUI_RAW"
    has "...asks for a number, Enter to go on" "Number to change, Enter to continue:" "$TUI_RAW"
    has "...the number asked that one field again, which can be taken back" "Port (- clears it) [5433]:" "$TUI_RAW"
    has "...and the changed answer is no longer the string's" "$(prow Port '5432      ')" "$TUI_SCREEN"
    has "an optional field left empty" "$(prow 'CA certificate file' '(none)')" "$TUI_SCREEN"
    has "...and it connects" "✓ VS_TUIPASTE" "$TUI_SCREEN"
    has "...with the port as changed" '"port": "5432"' "$(cat "$HOME_K/sources/tuipaste/"*.json 2>/dev/null)"
    check "the typed credential reached the CONNECTION, not the string's" "$TUI_SECRET" "$(dbq 'd["connections"]["EXAKIT_SRC_TUIPASTE"]["secret"]')"
    check "...the string's password is nowhere under the kit home or in the log" "" "$(grep -rl "$URLPW" "$HOME_K" "$WORK/tui.log" 2>/dev/null)"
    lacks "...and the credential typed is in none of what was drawn" "$TUI_SECRET" "$TUI_RAW"

    # A string that does not parse is said and asked again; Enter types the
    # fields. A plan that refuses one input goes straight back to that field.
    TTY_REPLAY_RAW="$RAW" TUI_PLAN_FAIL="host=old.example.com is not a host this test lets through" TUI_ARGS="pg" \
        tui connect-tui-scenario.sh "1 of 1 · PostgreSQL" 2 \
        "${Q_PASTE}not a url\r${Q_PASTE}jdbc:mysql://my.example.com/shop\r$Q_PASTE\r${Q_NAME}tuijump\r${Q_HOST}old.example.com\r$Q_PORT\r${Q_DB}sales\r$Q_SCHEMA\r${Q_USER}reader\r$Q_PW$TUI_SECRET\r$Q_TLS\r$Q_CA\r$Q_SUM\r$(when 'Host name or address * [old.example.com]:')pg.example.com\r$Q_SUM\r${Q_GO}y\r"
    check "a garbage string, then a plan refusing the host: one panel, one table" "0" "$TUI_RC"
    TUI_RAW="$(tr -d '\r' < "$RAW")"
    has "a string with a space is refused in the engine's words" "the connection string has a space, line break or control character in it" "$TUI_RAW"
    has "...so is another connector's" "the kit does not read this as a PostgreSQL connection string; it reads:" "$TUI_RAW"
    has "the plan's refusal is said above the field it names" "host=old.example.com is not a host this test lets through" "$TUI_RAW"
    has "...which is asked again, its answer the default" "Host name or address * [old.example.com]:" "$TUI_RAW"
    lacks "...instead of asking to change every answer" "Change the answers?" "$TUI_RAW"
    has "...and the summary after it offers to leave the source out" "Number to change, Enter to continue, skip to leave this source out" "$TUI_RAW"
    has "...and the new answer connects" "✓ VS_TUIJUMP" "$TUI_SCREEN"
    has "...from the corrected host" "$(prow 'Host name or address *' 'pg.example.com ')" "$TUI_SCREEN"

    # A refusal naming two inputs (ca needs tls=verify) opens the summary with its
    # reason; "-" takes the optional CA back; skip leaves the source out. (Root B:
    # the private-CA tests above move root A away.)
    TTY_REPLAY_RAW="$RAW" TUI_ARGS="pg" tui connect-tui-scenario.sh "1 of 1 · PostgreSQL" 1 \
        "$Q_PASTE\r${Q_NAME}tuica\r${Q_HOST}pg.example.com\r$Q_PORT\r${Q_DB}sales\r$Q_SCHEMA\r${Q_USER}reader\r${Q_PW}pw\r${Q_TLS}require\r${Q_CA}$CA/TestRootB.pem\r$Q_SUM\r${Q_SUM}9\r$(when 'CA certificate file (- clears it)')-\r${Q_SUM}skip\r"
    check "a refusal naming two inputs, a cleared answer, skip: one panel" "0" "$TUI_RC"
    TUI_RAW="$(tr -d '\r' < "$RAW")"
    has "...the summary comes back with the reason" "ca is used to verify the server, so it needs tls=verify (not require)" "$TUI_RAW"
    has "...an optional answer says how to take it back" "CA certificate file (- clears it)" "$TUI_RAW"
    has "...and - did" "  9  $(prow 'CA certificate file' '(none)')" "$TUI_RAW"
    has "...skip left the source out" "Left out: postgresql" "$TUI_SCREEN"
    has "...with nothing changed" "Nothing was changed." "$TUI_SCREEN"
    check "...and nothing kept" "no" "$([ -d "$HOME_K/sources/tuica" ] && echo yes || echo no)"

    # 56 columns: a row too narrow for its value and "(from the string)" drops
    # the mark, never overflows the panel (the replay counts the frames). The
    # review is declined: this is about the form. The hidden question is exactly
    # 56 columns wide, on a terminal that holds the wrap (xterm's kind): one row,
    # counted as one, or the next redraw climbs one line too far.
    TTY_REPLAY_WRAP=deferred TUI_COLS=56 TUI_ARGS="pg" tui connect-tui-scenario.sh "1 of 1 · PostgreSQL" 2 \
        "${Q_PASTE}postgres://reader:$URLPW@pg.example.com:5433/sales\r${Q_NAME}tuinarrow\r$Q_SCHEMA\r$Q_PW$TUI_SECRET\r$Q_TLS\r$Q_CA\r$Q_SUM\r${Q_GO}n\r"
    check "56 columns: one panel and the review, never stacked" "0" "$TUI_RC"
    has "...the value kept" "$(prow 'Host name or address *' 'pg.example.com')" "$TUI_SCREEN"
    lacks "...its mark dropped" "(from the string)" "$TUI_SCREEN"
    has "...and declined, nothing changed" "Nothing was changed." "$TUI_SCREEN"

    # The line-by-line questions (a terminal without the drawn form), on a pty
    # that is the scenario's /dev/tty, as a real terminal is.
    Q_LNAME="$(when 'Name for this connection (lower case, e.g. sales) *')"
    Q_LPASTE="$(when 'Connection string (Enter to type the fields) (input hidden):')"
    TTY_REPLAY_RAW="$RAW" TTY_REPLAY_CTTY=1 TUI_PLAIN=1 TUI_ARGS="pg" tui connect-tui-scenario.sh "none" 0 \
        "${Q_LPASTE}garbage string\r${Q_LPASTE}$(pasted "jdbc:postgresql://pg.example.com:5432/sales?user=reader&password=$URLPW&ApplicationName=$LONGX\rzz2nd\r")$Q_LNAME\r${Q_LNAME}linepg\r$(when 'Schema [public]')\r$(when 'TLS (verify/require/disable) [verify]')\r$(when 'Enter to skip')\r$(when 'Connect now? [y/N]')y\r$(when 'Password (input hidden):')$TUI_SECRET\r"
    TUI_RAW="$(tr -d '\r' < "$RAW")"
    has "line by line: the connection string is asked first, hidden" "Connection string (Enter to type the fields) (input hidden):" "$TUI_RAW"
    lacks "...the string, password and all, is in nothing drawn" "$URLPW" "$TUI_RAW"
    has "...a garbage string is said and asked again" "the connection string has a space, line break or control character in it" "$TUI_RAW"
    has "...the password in it noted, not used" "it was not used. The credential is asked for separately" "$TUI_RAW"
    lacks "...without the command-line sentence" "The string was on the command line" "$TUI_RAW"
    has "...what it filled is said" "From the connection string: database, host, port, user" "$TUI_RAW"
    lacks "...and not asked" "Host name or address" "$TUI_RAW"
    has "...one legend line above the questions says what the star means" "    * required" "$TUI_RAW"
    has "...a required question ends in the star" "Name for this connection (lower case, e.g. sales) *" "$TUI_RAW"
    has "...an optional one shows its default, no star" "Schema [public]" "$TUI_RAW"
    lacks "...no star on it" "Schema *" "$TUI_RAW"
    lacks "...and the words are gone" "(required)" "$TUI_RAW"
    lacks "...both of them" "(optional)" "$TUI_RAW"
    has "...an empty required answer is refused" "Name for this connection is required" "$TUI_RAW"
    has "...and the credential is asked hidden" "Password (input hidden):" "$TUI_RAW"
    lacks "...a 1500-character paste read whole, its second line answering nothing, never shown" "zz2nd" "$TUI_RAW"
    check "...the typed one reaches the CONNECTION" "$TUI_SECRET" "$(dbq 'd["connections"]["EXAKIT_SRC_LINEPG"]["secret"]')"
    lacks "...and is never shown" "$TUI_SECRET" "$TUI_RAW"
    check "...the string's password is nowhere under the kit home or in the log" "" "$(grep -rl "$URLPW" "$HOME_K" "$WORK/tui.log" 2>/dev/null)"

    # --dry-run at the same terminal asks as it always did: no marks, no
    # connection string.
    TTY_REPLAY_RAW="$RAW" TTY_REPLAY_CTTY=1 TUI_PLAIN=1 TUI_ARGS="pg --name linedry --set host=pg.example.com --dry-run" \
        tui connect-tui-scenario.sh "none" 0 \
        "$(when 'Port [5432]')\r$(when '? Database')sales\r$(when 'Schema [public]')\r$(when '? Reader account')reader\r$(when 'TLS (verify/require/disable) [verify]')\r$(when 'Enter to skip')\r"
    TUI_RAW="$(tr -d '\r' < "$RAW")"
    has "--dry-run on a terminal: the questions as before" "? Database " "$TUI_RAW"
    has "...and the plan" "Plan for linedry" "$TUI_RAW"
    lacks "...no star" "Database *" "$TUI_RAW"
    lacks "...no legend" "* required" "$TUI_RAW"
    lacks "...no connection string" "Connection string" "$TUI_RAW"

    # A pipe on stdin with a terminal behind /dev/tty: the questions come from
    # the terminal as they always did - no marks, no connection string - as on
    # Windows, where a redirected input is not interactive.
    TTY_REPLAY_RAW="$RAW" TTY_REPLAY_CTTY=1 TUI_STDIN=piped \
        TUI_ARGS="pg --name linepipe --set host=pg.example.com --set database=sales --set user=reader" \
        tui connect-tui-scenario.sh "none" 0 \
        "$(when 'Port [5432]')\r$(when 'Schema [public]')\r$(when 'TLS (verify/require/disable) [verify]')\r$(when 'Enter to skip')\r$(when 'Connect now? [y/N]')y\r$(when 'Password (input hidden):')$TUI_SECRET\r"
    TUI_RAW="$(tr -d '\r' < "$RAW")"
    has "stdin a pipe, /dev/tty a terminal: the questions as before" "Schema [public]" "$TUI_RAW"
    lacks "...no star" "Port *" "$TUI_RAW"
    lacks "...no legend" "* required" "$TUI_RAW"
    lacks "...no connection string" "Connection string" "$TUI_RAW"
    check "...and it connects" "$TUI_SECRET" "$(dbq 'd["connections"]["EXAKIT_SRC_LINEPIPE"]["secret"]')"

    # --password-stdin with the same terminal behind /dev/tty: the pipe is read
    # whole (without the flag it is read only when no terminal is), so the
    # hidden prompt never comes; the other questions still do.
    TTY_REPLAY_RAW="$RAW" TTY_REPLAY_CTTY=1 TUI_STDIN="$TUI_SECRET
" \
        TUI_ARGS="pg --name linestdin --set host=pg.example.com --set database=sales --set user=reader --password-stdin" \
        tui connect-tui-scenario.sh "none" 0 \
        "$(when 'Port [5432]')\r$(when 'Schema [public]')\r$(when 'TLS (verify/require/disable) [verify]')\r$(when 'Enter to skip')\r$(when 'Connect now? [y/N]')y\r"
    TUI_RAW="$(tr -d '\r' < "$RAW")"
    lacks "--password-stdin, /dev/tty a terminal: no hidden prompt" "(input hidden)" "$TUI_RAW"
    has "...the questions from the terminal as before" "Schema [public]" "$TUI_RAW"
    check "...the piped credential, its newline dropped, reaches the CONNECTION" "$TUI_SECRET" "$(dbq 'd["connections"]["EXAKIT_SRC_LINESTDIN"]["secret"]')"
    lacks "...and is never shown" "$TUI_SECRET" "$TUI_RAW"

    # --password-stdin with the terminal ON stdin: refused, nothing asked, nothing done.
    TTY_REPLAY_RAW="$RAW" TTY_REPLAY_CTTY=1 TUI_SAY_EXIT=1 \
        TUI_ARGS="pg --name ttystdin --set host=pg.example.com --set database=sales --set user=reader --password-stdin" \
        tui connect-tui-scenario.sh "none" 0 ""
    TUI_RAW="$(tr -d '\r' < "$RAW")"
    has "--password-stdin with a terminal on stdin: refused in one line" "--password-stdin reads the credential from standard input, which is a terminal here" "$TUI_RAW"
    has "...exit 2" "EXIT 2" "$TUI_RAW"
    lacks "...nothing asked" "Port [5432]" "$TUI_RAW"
    check "...nothing connected" "false" "$(dbq '"EXAKIT_SRC_TTYSTDIN" in d.get("connections", {})')"
fi
# The star itself: red from the palette's own UI_ERR where there is colour, a
# plain * where there is none (NO_COLOR here; EXAKIT_NO_FANCY and no terminal
# load the same plain palette). The real panel and the real line-by-line
# question, a PostgreSQL-like form of one required and one optional field.
starform() { # starform <colour:1|0> - the panel, the question, the legend; ESC shown as <E>
    ( if [ "$1" = 1 ]; then unset NO_COLOR; else NO_COLOR=1; export NO_COLOR; fi
      . "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/virtual-schemas.sh"
      [ "$1" = 1 ] && UI_ERR=$'\033[1;31m' UI_RESET=$'\033[0m'
      _EVT_COLS=80; _EVT_IN=72; _EVT_SP="$(printf '%160s' '')"; _EVT_HR="$(printf '%160s' '' | tr ' ' '-')"
      _EVT_NF=2; _EVT_LW=22; _EVT_NOTES=""
      _EVT_LAB=("Host name or address" "Port"); _EVT_KIND=(host port); _EVT_REQ=(1 ""); _EVT_DEF=("" 5432)
      _EVT_VAL=("" ""); _EVT_DONE=("" ""); _EVT_FROM=("" "")
      _exakit_vs_tui_frame "1 of 1" -1; printf '%s' "$_EVT_BUF"
      _exakit_prompt_tty() { printf 'stdin\n'; }
      prompt_text() { printf 'ASK %s [%s]\n' "$1" "$2" >&2; printf 'x\n'; }
      _exakit_vs_prompt "Host name or address" "" 1 1 >/dev/null
      _exakit_vs_prompt "Port" "5432" "" 1 >/dev/null
      _exakit_vs_legend ) 2>&1 | sed $'s/\033/<E>/g'
}
OUT="$(starform 0)"
has "no colour: a required field's label ends in a plain *" "|     Host name or address *" "$OUT"
has "...an optional one keeps its default, no star" "$(printf '|     %-22s  [5432]' Port)" "$OUT"
has "...the legend in the box" "|     * required" "$OUT"
has "...the question ends in the plain * too" "ASK Host name or address * []" "$OUT"
has "...an optional question: its default, no star" "ASK Port [5432]" "$OUT"
has "...and the line-by-line legend" "    * required" "$OUT"
lacks "...no colour code anywhere" "<E>" "$OUT"
lacks "...no (required) or (optional)" "(required)" "$OUT"
OUT="$(starform 1)"
has "colour: the star is the palette's red (UI_ERR)" "Host name or address<E>[0m <E>[1;31m*<E>[0m" "$OUT"
has "...in the question too" "ASK Host name or address <E>[1;31m*<E>[0m []" "$OUT"
has "...and the legend's" "<E>[1;31m*<E>[0m" "$OUT"

# Without a terminal - a pipe, --json - nothing is asked and nothing is marked.
OUT="$(printf '%s' "$SECRET" | urlsh cmd_connect pg --name pipeform $PG_SET)"; RC=$?
check "a pipe: the credential on stdin connects as before, exit 0" "0" "$RC"
lacks "...no marks" "* required" "$OUT"
lacks "...no connection string" "Connection string" "$OUT"
run remove pipeform
OUT="$(urlsh cmd_connect pg --name jsonform $PG_SET --dry-run --json </dev/null)"; RC=$?
check "--json: exit 0" "0" "$RC"
lacks "...no marks" "* required" "$OUT"
lacks "...no connection string" "Connection string" "$OUT"
# Which field a plan's refusal names: input names first, as whole words; labels
# only when no name is named, as whole words too; several named is -2 (the
# summary opens), none -1.
mkdir -p "$WORK/named"
printf 'PostgreSQL\nname|Name for this connection|source-name\nhost|Host name or address|host\nport|Port|port\nca|CA certificate file|ca-file\ntls|TLS|choice\nuri|MongoDB URI|mongodb-uri\nuser|Reader account|text\n' > "$WORK/named/fields"
rows() { ( . "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/virtual-schemas.sh"
           _EVT_COLS=56; _exakit_vs_tui_rows "$@" ) 2>/dev/null; }
check "a line exactly as wide as the terminal is one row: the terminal holds the wrap" "1" "$(rows 56)"
check "...a readline line that wide is two: readline forces the wrap" "2" "$(rows 56 readline)"
check "...one character wider is two either way" "2 2" "$(rows 57) $(rows 57 readline)"
named() { ( . "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/virtual-schemas.sh"
            _EVT_DIR="$WORK/named"; _exakit_vs_tui_named "$1" ) 2>/dev/null; }
check "a refusal naming host goes to host" "1" "$(named 'host is required (Host name or address)')"
check "...one naming ca and tls opens the summary" "-2" "$(named 'ca is used to verify the server, so it needs tls=verify (not require)')"
check "...Port is not in report or export" "-1" "$(named 'the report could not be exported')"
check "...a label counts when no name does, as a whole word in any case" "6" "$(named 'the reader account may not read this')"
check "...the source name is named as such, not by the bare word name" "0" "$(named 'the source name must be lower case')"
check "...so a value that is not a valid name names only its input" "2" "$(named "port='x y' is not a valid name")"
check "...the MongoDB URI with user: names uri and user, not user alone" "-2" \
    "$(named 'the MongoDB URI carries credentials (user:password@): give the user with --set user=...')"
for fn in Read-ExakitVsTuiField Invoke-ExakitVsTuiReview Invoke-ExakitVsTuiPaste Find-ExakitVsTuiNamed \
          Read-ExakitVsLineAnswer Read-ExakitVsLinePaste Get-ExakitVsPasteForms Format-ExakitVsPasteTyped \
          Read-ExakitVsHidden Format-ExakitVsTuiFit Clear-ExakitVsPendingKeys; do
    has "PowerShell has $fn" "function $fn" "$(cat "$ROOT/setup/lib/virtual-schemas.ps1")"
done
has "Invoke-CmdConnect asks for a connection string line by line" "Read-ExakitVsLinePaste -Connector" "$(cat "$ROOT/setup/exakit.ps1")"
has "...and marks its questions" "Read-ExakitVsLineAnswer -Question" "$(cat "$ROOT/setup/exakit.ps1")"

printf '\n== this computer'"'"'s public IP, for a source on the internet ==\n'
# The database's traffic leaves through this computer, so a cloud source's
# security group, firewall or IP access list must allow this computer's public
# IP. The engine asks for it once (publicip.py); here it reads a file:// URL.
ipeng() { EXAKIT_NO_IP_LOOKUP= EXAKIT_PUBLIC_IP_URL="${IP_URL:-$IPURL}" eng "$@"; }
pubip() { python3 -c 'import json,sys; print(json.load(sys.stdin).get("public_ip", "absent"))' 2>/dev/null; }
IPLINE="This computer's public IP is 203.0.113.7"
db '{"sources": {"pg.example.com": {"tables": ["ORDERS"]}}}'
OUT="$(ipeng plan pg --name ipsales $PG_SET 2>/dev/null)"; RC=$?
check "plan of a host on the internet: exit 0" "0" "$RC"
has "...one INFO line names the address and the host that must allow it" \
    "INFO $IPLINE: pg.example.com must allow it if it filters by address (security group, firewall or IP access list)" "$OUT"
check "...said once" "1" "$(printf '%s\n' "$OUT" | grep -c 'public IP')"
check "plan --json carries it as public_ip" "203.0.113.7" "$(ipeng --json plan pg --name ipsales $PG_SET 2>/dev/null | pubip)"
for host in 192.168.64.1 host.containers.internal 10.0.0.5 100.100.1.2 db; do
    OUT="$(ipeng plan pg --name ipsales --set host=$host --set database=sales --set user=reader 2>&1)"
    lacks "a host on this computer or a private network ($host): no public IP line" "public IP" "$OUT"
done
check "...and public_ip is null, never absent" "None" \
    "$(ipeng --json plan pg --name ipsales --set host=192.168.64.1 --set database=sales --set user=reader 2>/dev/null | pubip)"
check "a refused input: public_ip is null too" "2 None" \
    "$(ipeng --json plan pg --name ipsales --set host=pg.example.com > "$WORK/ip.json" 2>/dev/null; echo "$?") $(pubip < "$WORK/ip.json")"

# One rule for every connector, from its definition: the hosts it names, the
# host a cloud store's template builds, a MongoDB URI's hosts, a storage endpoint.
SCOPE="$(python3 - "$ROOT" <<'PYS'
import sys
sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import plan
# The shipped catalog: the copy in DEFS carries a test-only gated connector.
defs = plan.Definitions(sys.argv[1] + "/setup/virtual-schemas")
cases = [("postgresql", {"host": "pg.example.com"}), ("postgresql", {"host": "192.168.64.1"}),
         ("mysql", {"host": "db.abc.eu-west-1.rds.amazonaws.com"}), ("sqlserver", {"host": "10.1.2.3"}),
         ("oracle", {"host": "ora.example.com"}),
         ("s3", {"bucket": "docs-bucket", "region": "ap-south-1"}), ("azure-blob", {"account": "acct", "container": "c"}),
         ("snowflake", {"account": "myorg-acct1"}), ("bigquery", {"project": "p", "dataset": "d"}),
         ("databricks", {"host": "dbc-1.cloud.databricks.com"}), ("lakehouse", {"region": "eu-west-1"}),
         ("unity", {"workspace_url": "https://dbc-1.cloud.databricks.com"}),
         ("mongodb", {"uri": "mongodb+srv://cluster0.abcd.mongodb.net/"}),
         ("mongodb", {"uri": "mongodb://10.0.0.5:27017,10.0.0.6:27017/"}),
         ("mongodb", {"uri": "mongodb://10.0.0.5:27017,shard.example.com:27017/"}),
         ("iceberg-rest", {"catalog_url": "http://192.168.64.1:8181"}),
         ("iceberg-rest", {"catalog_url": "http://192.168.64.1:8181", "endpoint": "http://192.168.64.1:9000"}),
         ("iceberg-rest", {"catalog_url": "http://192.168.64.1:8181", "endpoint": "https://s3.example.com"}),
         ("iceberg-rest", {"catalog_url": "https://rest.example.com/api"})]
for cid, values in cases:
    print("%s=%s" % (cid, plan.public_host(defs.connector(cid), values)))
print(sorted(set(e["id"] for e in defs.entries()) - set(c for c, _ in cases)))
PYS
)"
check "public_host decides per connector, from its connector.json" \
    "postgresql=pg.example.com|postgresql=None|mysql=db.abc.eu-west-1.rds.amazonaws.com|sqlserver=None|oracle=ora.example.com|s3=docs-bucket.s3.ap-south-1.amazonaws.com|azure-blob=acct.blob.core.windows.net|snowflake=myorg-acct1.snowflakecomputing.com|bigquery=www.googleapis.com|databricks=dbc-1.cloud.databricks.com|lakehouse=glue.eu-west-1.amazonaws.com|unity=dbc-1.cloud.databricks.com|mongodb=cluster0.abcd.mongodb.net|mongodb=None|mongodb=shard.example.com|iceberg-rest=None|iceberg-rest=None|iceberg-rest=s3.example.com|iceberg-rest=rest.example.com|" \
    "$(printf '%s\n' "$SCOPE" | sed '$d' | tr '\n' '|')"
check "...and every connector in the catalog is decided here (a new one must be added)" "[]" "$(printf '%s\n' "$SCOPE" | tail -1)"

# exakit source list: where each source lives and its TLS level, one rule for
# every connector - its tls input; a MongoDB URI's own options; http:// is
# disable; a cloud store's HTTPS is verify; BigQuery is its project.
WHERE="$(python3 - "$ROOT" <<'PYW'
import sys
sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import lifecycle, plan
defs = plan.Definitions(sys.argv[1] + "/setup/virtual-schemas")
cases = [("postgresql", {"host": "pg.example.com", "tls": "verify"}), ("mysql", {"host": "my.example.com", "tls": "require"}),
         ("sqlserver", {"host": "sql.example.com", "tls": "disable"}), ("oracle", {"host": "ora.example.com"}),
         ("s3", {"bucket": "docs-bucket", "region": "ap-south-1"}), ("azure-blob", {"account": "acct", "container": "c"}),
         ("snowflake", {"account": "myorg-acct1"}), ("bigquery", {"project": "my-project", "dataset": "d"}),
         ("databricks", {"host": "dbc-1.cloud.databricks.com"}), ("lakehouse", {"region": "eu-west-1"}),
         ("unity", {"workspace_url": "https://dbc-1.cloud.databricks.com"}),
         ("iceberg-rest", {"catalog_url": "http://192.168.64.1:8181"}),
         ("iceberg-rest", {"catalog_url": "https://rest.example.com/api", "endpoint": "http://10.0.0.5:9000"}),
         ("mongodb", {"uri": "mongodb+srv://cluster0.abcd.mongodb.net/?authSource=admin"}),
         ("mongodb", {"uri": "mongodb://10.0.0.5:27017,10.0.0.6:27017/"}),
         ("mongodb", {"uri": "mongodb://10.0.0.5:27017/?tls=true&tlsAllowInvalidCertificates=true"}),
         ("mongodb", {"uri": "mongodb+srv://cluster0.abcd.mongodb.net/?ssl=false"})]
for cid, values in cases:
    c = defs.connector(cid)
    print("%s=%s/%s" % (cid, lifecycle.source_where(c, values), lifecycle.tls_level(c, values)))
print("gone=%s/%s" % (lifecycle.source_where(None, {"host": "h.example.com"}), lifecycle.tls_level(None, {})))
print(sorted(set(e["id"] for e in defs.entries()) - set(c for c, _ in cases)))
PYW
)"
check "list: host and tls per connector, from its connector.json" \
    "postgresql=pg.example.com/verify|mysql=my.example.com/require|sqlserver=sql.example.com/disable|oracle=ora.example.com/verify|s3=docs-bucket.s3.ap-south-1.amazonaws.com/verify|azure-blob=acct.blob.core.windows.net/verify|snowflake=myorg-acct1.snowflakecomputing.com/verify|bigquery=my-project/verify|databricks=dbc-1.cloud.databricks.com/verify|lakehouse=glue.eu-west-1.amazonaws.com/verify|unity=dbc-1.cloud.databricks.com/verify|iceberg-rest=192.168.64.1/disable|iceberg-rest=rest.example.com/disable|mongodb=cluster0.abcd.mongodb.net/verify|mongodb=10.0.0.5/disable|mongodb=10.0.0.5/require|mongodb=cluster0.abcd.mongodb.net/disable|gone=h.example.com/None|" \
    "$(printf '%s\n' "$WHERE" | sed '$d' | tr '\n' '|')"
check "...and every connector in the catalog is decided here (a new one must be added)" "[]" "$(printf '%s\n' "$WHERE" | tail -1)"
check "a cloud store with no host input: the plan names its endpoint" \
    "INFO $IPLINE: myorg-acct1.snowflakecomputing.com must allow it if it filters by address (security group, firewall or IP access list)" \
    "$(ipeng plan snowflake --name ipsf $SF_SET 2>/dev/null | grep '^INFO ')"

# The lookup is advice, never a step: it fails silently and never waits past 3 s.
printf 'not an address\n' > "$WORK/garbage-ip"
for bad in "an answer that is not an address|file://$WORK/garbage-ip" "no answer at all|file://$WORK/no-such-file"; do
    label="${bad%%|*}"; IP_URL="${bad#*|}"
    OUT="$(ipeng plan pg --name ipsales $PG_SET 2>/dev/null)"; RC=$?
    check "a lookup with $label: plan exit 0" "0" "$RC"
    lacks "...and nothing is said about it" "public IP" "$OUT"
    has "...one line goes to the log (stderr)" "public IP lookup:" "$(ipeng plan pg --name ipsales $PG_SET 2>&1 >/dev/null)"
    check "...public_ip is null" "None" "$(ipeng --json plan pg --name ipsales $PG_SET 2>/dev/null | pubip)"
done
unset IP_URL
python3 - "$WORK/blackhole.port" <<'PYB' &
import os, socket, sys
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(8)
open(sys.argv[1] + ".tmp", "w").write(str(s.getsockname()[1]))
os.rename(sys.argv[1] + ".tmp", sys.argv[1])
held = []
while True:
    held.append(s.accept()[0])        # accepted, never answered
PYB
BH_PID=$!
_bh_wait=0; while [ ! -s "$WORK/blackhole.port" ] && [ "$_bh_wait" -lt 50 ]; do sleep 0.1; _bh_wait=$((_bh_wait + 1)); done
BH_URL="http://127.0.0.1:$(cat "$WORK/blackhole.port")/"
_t0="$(date +%s)"; OUT="$(IP_URL="$BH_URL" ipeng plan pg --name ipsales $PG_SET 2>/dev/null)"; RC=$?; _t1="$(date +%s)"
check "a lookup that never answers: plan exit 0 within the 3 s budget" "0 yes" "$RC $([ $((_t1 - _t0)) -le 6 ] && echo yes || echo no)"
lacks "...and nothing is said about it" "public IP" "$OUT"
_t0="$(date +%s)"; OUT="$(EXAKIT_NO_IP_LOOKUP=1 EXAKIT_PUBLIC_IP_URL="$BH_URL" eng --json plan pg --name ipsales $PG_SET 2>&1)"; _t1="$(date +%s)"
check "EXAKIT_NO_IP_LOOKUP=1: nothing is asked (no wait on that same URL)" "yes" "$([ $((_t1 - _t0)) -le 2 ] && echo yes || echo no)"
lacks "...nothing is said or logged" "public IP" "$(printf '%s\n' "$OUT" | grep -v '"public_ip"')"
# Assigned first: bash 3.2 brace-expands a sed range with a brace in an
# address when it is passed straight as an argument (tests/bash32-guard.sh).
_null_ip="$(printf '%s\n' "$OUT" | sed -n '/^{/,$p' | pubip)"
check "...and public_ip is null" "None" "$_null_ip"
# The connect menu's first line: catalog --public-ip asks once, says it as one
# INFO line, and its answer is handed on to the rest of the command
# (_EXAKIT_VS_PUBLIC_IP), so a later plan does not ask again.
OUT="$(ipeng catalog --public-ip </dev/null 2>&1)"
check "catalog --public-ip: the menu's line, first" "INFO This computer's public IP is 203.0.113.7: a source on the internet must allow it." \
    "$(printf '%s\n' "$OUT" | head -n 1)"
check "...and --json carries it" "203.0.113.7" "$(ipeng --json catalog --public-ip </dev/null 2>/dev/null | pubip)"
OUT="$(EXAKIT_NO_IP_LOOKUP=1 EXAKIT_PUBLIC_IP_URL="$IPURL" eng catalog --public-ip </dev/null 2>&1)"
lacks "EXAKIT_NO_IP_LOOKUP=1: the menu says nothing about it" "public IP" "$OUT"
lacks "a catalog without --public-ip asks nothing" "public IP" "$(ipeng catalog </dev/null 2>&1)"
OUT="$(_EXAKIT_VS_PUBLIC_IP=198.51.100.9 IP_URL="file://$WORK/no-such-file" ipeng plan pg --name ipsales $PG_SET 2>&1)"
has "an answer handed on: the plan says it without asking (its URL would fail)" "This computer's public IP is 198.51.100.9: pg.example.com must allow it" "$OUT"
_t0="$(date +%s)"; OUT="$(_EXAKIT_VS_PUBLIC_IP=none IP_URL="$BH_URL" ipeng --json plan pg --name ipsales $PG_SET 2>/dev/null)"; _t1="$(date +%s)"
check "...a lookup that failed earlier: not asked again (no wait on a URL that never answers), public_ip null" "yes None" \
    "$([ $((_t1 - _t0)) -le 2 ] && echo yes || echo no) $(printf '%s\n' "$OUT" | pubip)"
kill "$BH_PID" 2>/dev/null; wait "$BH_PID" 2>/dev/null

# connect: the lookup runs beside it; a failed one changes nothing.
db '{"sources": {"pg.example.com": {"tables": ["ORDERS"]}}}'
OUT="$(printf '%s' "$SECRET" | IP_URL="file://$WORK/garbage-ip" ipeng --json connect pg --name ipfail $PG_SET --secret-stdin 2>/dev/null)"; RC=$?
check "a connect whose lookup fails proceeds: exit 0, public_ip null" "0 None" "$RC $(printf '%s' "$OUT" | pubip)"
run remove ipfail
printf '%s' "$SECRET" | ipeng --json connect pg --name ipok $PG_SET --secret-stdin > "$WORK/ip.json" 2> "$WORK/ip.err"; RC=$?
check "connect --json carries public_ip" "0 203.0.113.7" "$RC $(pubip < "$WORK/ip.json")"
lacks "...and does not repeat the plan's line" "public IP" "$(cat "$WORK/ip.err")"
# exakit source check: the source stops answering.
python3 - "$STATE" <<'PYU'
import json, sys; d = json.load(open(sys.argv[1])); d["unreachable"] = ["pg.example.com"]; json.dump(d, open(sys.argv[1], "w"))
PYU
OUT="$(ipeng check ipok 2>&1)"; RC=$?
check "check of a source on the internet that does not answer: exit 1" "1" "$RC"
has "...its fix names the address to allow" "Fix: the source did not answer from inside the database: check the host, port, firewall and VPN (allow this computer's public IP 203.0.113.7 in its security group, firewall or IP access list), then: exakit source check ipok" "$OUT"
lacks "...not the advice for a source on this computer" "listen beyond 127.0.0.1" "$OUT"
OUT="$(eng check ipok 2>&1)"
has "...with the lookup off, the fix is the one it always was" "(a source on this computer must listen beyond 127.0.0.1), then: exakit source check ipok" "$OUT"
run remove ipok
# connect: a first connect that cannot reach the source.
db '{"unreachable": ["slow.example.com", "10.0.0.9"]}'
OUT="$(printf '%s' "$SECRET" | ipeng connect mysql --name ipslow --set host=slow.example.com --set database=crm --set user=reader --secret-stdin 2>&1)"; RC=$?
check "connect to a host on the internet that does not answer: exit 1" "1" "$RC"
has "...its fix names the address to allow" "nothing was kept - check host, port, firewall and VPN (allow this computer's public IP 203.0.113.7 in its security group, firewall or IP access list), then connect again" "$OUT"
lacks "...not the advice for a source on this computer" "listen beyond 127.0.0.1" "$OUT"
check "...and --json says it as public_ip" "1 203.0.113.7" \
    "$(printf '%s' "$SECRET" | ipeng --json connect mysql --name ipslow --set host=slow.example.com --set database=crm --set user=reader --secret-stdin > "$WORK/ip.json" 2>/dev/null; echo "$?") $(pubip < "$WORK/ip.json")"
OUT="$(printf '%s' "$SECRET" | ipeng connect mysql --name ipslow --set host=10.0.0.9 --set database=crm --set user=reader --secret-stdin 2>&1)"; RC=$?
check "connect to a private host that does not answer: exit 1" "1" "$RC"
has "...keeps the advice for a source on this computer or a private network" "(a source on this computer must listen beyond 127.0.0.1), then connect again" "$OUT"
lacks "...and no public IP" "public IP" "$OUT"
# An address filter on an object store answers 403 (an S3 bucket policy on
# aws:SourceIp, an Azure storage firewall): denied, not unreachable.
db '{"sources": {"'"$S3HOST"'": {"fail": "denied"}}}'
OUT="$(printf '%s' "$AWSSECRET" | ipeng connect s3 --name ipdocs $S3_SET --set access_key_id=$KEYID --secret-stdin 2>&1)"; RC=$?
check "S3 denied: exit 1" "1" "$RC"
has "...the fix still names the grant" "s3:ListBucket on the mapped prefixes" "$OUT"
has "...and the address, for a bucket that filters by it" "and, if it filters by address, allow this computer's public IP 203.0.113.7 in its security group, firewall or IP access list, then connect again" "$OUT"
# A database on the internet that refuses the read for a missing grant: it
# let the address in and took the credentials, so the fix names the grant
# and never an address to allow.
PGGRANT="JDBC-Client-Error: Failed to receive MetaData for the given statement: ERROR: permission denied for table orders (Session: 1)"
db '{"sources": {"pg.example.com": {"tables": ["ORDERS"], "read_error": "'"$PGGRANT"'"}}}'
OUT="$(printf '%s' "$SECRET" | ipeng connect pg --name ipgrant $PG_SET --secret-stdin 2>&1)"; RC=$?
check "a read PostgreSQL refuses for a missing grant: exit 1" "1" "$RC"
has "...the fix names the connector's grant" "the source took the credentials, but the account lacks a privilege; nothing was kept - grant it what the message names (CONNECT on the database, USAGE on the schema and SELECT on its tables), then connect again" "$OUT"
lacks "...and no address to allow" "allow this computer's public IP" "$OUT"
check "...--json says kind privilege, and still carries public_ip" "1 privilege 203.0.113.7" \
    "$(printf '%s' "$SECRET" | ipeng --json connect pg --name ipgrant $PG_SET --secret-stdin > "$WORK/grant.json" 2>/dev/null; echo "$?") $(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["kind"], d["public_ip"])' < "$WORK/grant.json")"
# exakit source check: the grant is revoked after the source was connected.
db '{"sources": {"pg.example.com": {"tables": ["ORDERS"]}}}'
printf '%s' "$SECRET" | ipeng connect pg --name ipgrant $PG_SET --secret-stdin >/dev/null 2>&1
python3 - "$STATE" "$PGGRANT" <<'PYU'
import json, sys; d = json.load(open(sys.argv[1])); d["sources"]["pg.example.com"]["read_error"] = sys.argv[2]; json.dump(d, open(sys.argv[1], "w"))
PYU
OUT="$(ipeng check ipgrant 2>&1)"; RC=$?
check "check of a source whose grant was revoked: exit 1, recorded access-denied" "1 access-denied" \
    "$RC $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$HOME_K/sources/ipgrant/state.json" 2>/dev/null || echo unread)"
has "...its fix names the grant" "Fix: the source took the credentials, but the account lacks a privilege: grant it what the message names (CONNECT on the database, USAGE on the schema and SELECT on its tables), then: exakit source check ipgrant" "$OUT"
lacks "...and no address to allow" "allow this computer's public IP" "$OUT"
run remove ipgrant
# Snowflake answers for an object the role may not see as for one that is
# gone: the fix names both - refresh for a dropped table, the grant otherwise.
SFHOST="myorg-acct1.snowflakecomputing.com"
db '{"sources": {"'"$SFHOST"'": {"tables": ["ORDERS"]}}}'
printf '%s' "$SECRET" | ipeng connect snowflake --name ipsfgone $SF_SET --secret-stdin >/dev/null 2>&1
python3 - "$STATE" "$SFHOST" <<'PYU'
import json, sys; d = json.load(open(sys.argv[1]))
d["sources"][sys.argv[2]]["read_error"] = ("JDBC-Client-Error: Failed to receive MetaData for the given statement: SQL compilation "
                                           "error:\nObject 'SALES.PUBLIC.ORDERS' does not exist or not authorized. (Session: 1)")
json.dump(d, open(sys.argv[1], "w"))
PYU
OUT="$(ipeng check ipsfgone 2>&1)"; RC=$?
check "check of a Snowflake table gone or not granted: exit 1, recorded failed" "1 failed" \
    "$RC $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$HOME_K/sources/ipsfgone/state.json" 2>/dev/null || echo unread)"
has "...the error names the object, from the driver's second line" "Object 'SALES.PUBLIC.ORDERS' does not exist or not authorized." "$OUT"
has "...the fix names both causes" "it was dropped or renamed (then: exakit source refresh ipsfgone), or the account may not see it (grant it USAGE on the warehouse" "$OUT"
lacks "...and no address to allow" "allow this computer's public IP" "$OUT"
run remove ipsfgone

# The line-by-line path (a pipe, --yes, --dry-run) shows the plan's INFO line;
# --dry-run --json prints the plan with public_ip.
db '{"sources": {"pg.example.com": {"tables": ["ORDERS"]}}}'
OUT="$(EXAKIT_NO_IP_LOOKUP= EXAKIT_PUBLIC_IP_URL="$IPURL" urlsh cmd_connect pg --name iplines $PG_SET --dry-run </dev/null)"; RC=$?
check "exakit connect --dry-run (bash): exit 0" "0" "$RC"
has "...the plan's line is shown" "$IPLINE: pg.example.com must allow it" "$OUT"
OUT="$(EXAKIT_NO_IP_LOOKUP= EXAKIT_PUBLIC_IP_URL="$IPURL" urlsh cmd_connect pg --name iplines $PG_SET --dry-run --json </dev/null)"
check "exakit connect --dry-run --json (bash): public_ip, the output one object" "203.0.113.7" "$(printf '%s\n' "$OUT" | pubip)"
OUT="$(EXAKIT_NO_IP_LOOKUP= EXAKIT_PUBLIC_IP_URL="$IPURL" urlsh cmd_connect pg --name iplines --set host=192.168.64.1 --set database=sales --set user=reader --dry-run </dev/null)"
lacks "...a private host: no line" "public IP" "$OUT"

printf '\n== exakit connect --json: one object on stdout, whatever happens ==\n'
# For scripts and agents: a real connect, a dry run, and every refusal - the
# bridge's or the engine's - print exactly one JSON object on stdout, of one
# failure shape (ok false, error, kind, remedy, command, public_ip), with the
# documented exit code. Nothing is asked. stderr is kept apart here, so what
# is asserted is stdout alone.
jsonsh() { # jsonsh <stdin-file> <args...> - stdout in JOUT, stderr in JERR, exit in JRC
    _js_in="$1"; shift
    JOUT="$( ( EXAKIT_HOME="$HOME_K"
      . "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/virtual-schemas.sh"
      _require_install() { :; }; exakit_init_logging() { EXAKIT_LOG_FILE="$WORK/json.log"; }
      pyexasol_venv_python() { command -v python3; }
      exakit_vs_engine() { eng "$@"; }
      if [ "${JSON_JAVA_INSTALL:-}" = die ]; then
          # A download that fails its checksum: die, as verify_sha256 does.
          _exakit_vs_install_java() { die "The Java language container download did not match its checksum (test)."; }
      elif [ -n "${JSON_JAVA_INSTALL:-}" ]; then
          _exakit_vs_install_java() {
              info "Installing the Java language container (test)"
              _exakit_vs_confirm "Install the Java language container now?" || return 1
              python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["java"]=True; json.dump(d, open(sys.argv[1], "w"))' "$STATE"
          }
      fi
      cmd_connect "$@" ) < "$_js_in" 2> "$WORK/json.err" )"; JRC=$?
    JERR="$(cat "$WORK/json.err")"
}
# one <python expression over d> - prints it when stdout is exactly one JSON object, else NOT-ONE-OBJECT.
one() {
    printf '%s' "$JOUT" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except ValueError:
    print("NOT-ONE-OBJECT"); sys.exit()
print(eval(sys.argv[1], {"d": d}) if isinstance(d, dict) else "NOT-ONE-OBJECT")' "$1"
}
SHAPE='[d["ok"], d["kind"], bool(d["error"]), bool(d["remedy"]), "command" in d, "public_ip" in d]'
printf '%s' "$SECRET" > "$WORK/json.secret"
db '{"sources": {"pg.example.com": {"tables": ["ORDERS", "CUSTOMERS"]}}}'
jsonsh "$WORK/json.secret" pg --name jsonok $PG_SET --json
check "a real connect: exit 0, one object - the engine's result" "0 [True, 'jsonok', 'VS_JSONOK', None]" \
    "$JRC $(one '[d["ok"], d["name"], d["objects"]["schema"], d["public_ip"]]')"
lacks "...no query hint or Manage line on stdout" "Manage it with" "$JOUT"
lacks "...and the credential is nowhere in it" "$SECRET" "$JOUT$JERR"
# A credential kept off disk: --password-file <(pass show db) hands over a
# pipe, not a regular file. A named pipe stands in for it here (bash 3.2 closes
# a <(...) of its own as soon as a function it is given to runs a command;
# exakit, a process of its own, keeps the one its caller passed it).
mkfifo "$WORK/json.fifo"; ( printf '%s' "$SECRET" > "$WORK/json.fifo" ) & _jw=$!
jsonsh /dev/null pg --name jsonpipe $PG_SET --json --password-file "$WORK/json.fifo"
kill "$_jw" 2>/dev/null; wait "$_jw" 2>/dev/null; rm -f "$WORK/json.fifo"
check "a connect with --password-file a pipe: exit 0, one object" "0 [True, 'jsonpipe']" "$JRC $(one '[d["ok"], d["name"]]')"
run remove jsonpipe >/dev/null 2>&1
jsonsh /dev/null pg --name jsondry $PG_SET --dry-run --json
check "--dry-run --json: exit 0, one object - the plan" "0 [True, 'jsondry', 'GA', None]" \
    "$JRC $(one '[d["ok"], d["name"], d["tier"], d["public_ip"]]')"
lacks "...not the rendered plan before it" "Plan for" "$JOUT"
jsonsh /dev/null pg --name jsonurl --url "postgres://reader@pg.example.com:5433/sales" --dry-run --json
check "--url with --dry-run --json: one object, the string's host in the plan" "0 ['jsonurl', True]" \
    "$JRC $(one '[d["name"], "pg.example.com" in str(d["steps"])]')"
jsonsh /dev/null nosuchdb --name x --json
check "an unknown connector: exit 2, one failure object" "2 [False, 'input', True, True, True, True]" "$JRC $(one "$SHAPE")"
check "...its error is what happened, its command lists the connectors, the choices kept" \
    "['no source matches nosuchdb', 'exakit source catalog', True]" "$(one '[d["error"], d["command"], "postgresql" in d["choices"]]')"
jsonsh /dev/null pg --name jsonnopw $PG_SET --json
check "no credential (nothing on stdin): exit 2, one failure object, nothing asked" "2 [False, 'input', True, True, True, True]" "$JRC $(one "$SHAPE")"
has "...its remedy says how to give it" "--password-file" "$(one 'd["remedy"]')"
jsonsh /dev/null pg --name jsonbad --set host=pg.example.com --set database=sales --set user=reader --set port=70000 --json
check "a bad input: exit 2, one failure object" "2 [False, 'input', True, True, True, True]" "$JRC $(one "$SHAPE")"
jsonsh "$WORK/json.secret" pg --name jsonok $PG_SET --json
check "a name already taken: exit 3, one failure object" "3 [False, 'conflict', True, True, True, True]" "$JRC $(one "$SHAPE")"
check "...error is what happened, remedy the fix (once in each)" \
    "['a source named jsonok already exists (postgresql)', 'choose another name or remove it first: exakit source remove jsonok']" \
    "$(one '[d["error"], d["remedy"]]')"
jsonsh "$WORK/json.secret" gatedtest --name jsongt --set project=p --set dataset=d --json
check "a gated connector: exit 5, one failure object" "5 [False, 'gated', True, True, True, True]" "$JRC $(one "$SHAPE")"
jsonsh /dev/null pg --name x --bogus --json
check "an unknown option: exit 2, one failure object" "2 [False, 'input', True, True, True, True]" "$JRC $(one "$SHAPE")"
jsonsh /dev/null pg --json
check "no name: exit 2, one failure object" "2 [False, 'input', True, True, True, True]" "$JRC $(one "$SHAPE")"
jsonsh /dev/null --json
check "no source: exit 2, one failure object, never a question" "2 [False, 'input', True, True, True, True]" "$JRC $(one "$SHAPE")"
jsonsh /dev/null pg --name x --password=hunter2 --json
check "a credential as an argument: exit 2, one failure object" "2 [False, 'input', True, True, True, True]" "$JRC $(one "$SHAPE")"
lacks "...that does not repeat it" "hunter2" "$JOUT$JERR"
jsonsh /dev/null pg --name x $PG_SET --password-file "$WORK/no-such.pw" --json
check "an unreadable --password-file: exit 2, one failure object" "2 [False, 'input', True, True, True, True]" "$JRC $(one "$SHAPE")"
# A language container needs a database restart: without --yes, nothing is
# asked and the engine's answer stands; with --yes, the answer is the retry's.
db '{"sources": {"pg.example.com": {"tables": ["ORDERS"]}}, "java": false}'
JSON_JAVA_INSTALL=1 jsonsh "$WORK/json.secret" pg --name jsonjava $PG_SET --json
check "Java missing, no --yes: exit 21, one failure object" "21 [False, 'nojava', True, True, True, True]" "$JRC $(one "$SHAPE")"
has "...whose fix names --yes" "--yes" "$(one 'd["remedy"]')"
check "...nothing was installed" "false" "$(dbq 'd["java"]')"
JSON_JAVA_INSTALL=1 jsonsh "$WORK/json.secret" pg --name jsonjava $PG_SET --json --yes
check "Java missing, --yes: installed, retried, exit 0, one object - the retry's" "0 [True, 'jsonjava']" "$JRC $(one '[d["ok"], d["name"]]')"
has "...what the bridge said while it installed is on stderr" "Installing the Java language container (test)" "$JERR"
lacks "...not on stdout" "Installing the Java" "$JOUT"
# The same on a fresh Exasol Personal 2.4 (builtin_java, no client): the
# bridge's install path runs, where it used to stop at exit 1.
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["java"]="builtin"; json.dump(d, open(sys.argv[1], "w"))' "$STATE"
JSON_JAVA_INSTALL=1 jsonsh "$WORK/json.secret" pg --name jsonj24 $PG_SET --json
check "2.4 builtin_java, no --yes: exit 21, one failure object" "21 [False, 'nojava', True, True, True, True]" "$JRC $(one "$SHAPE")"
check "...nothing was installed" "builtin" "$(dbq 'd["java"]')"
JSON_JAVA_INSTALL=1 jsonsh "$WORK/json.secret" pg --name jsonj24 $PG_SET --json --yes
check "2.4 builtin_java, --yes: installed, retried, exit 0" "0 [True, 'jsonj24'] true" "$JRC $(one '[d["ok"], d["name"]]') $(dbq 'd["java"]')"
run remove jsonj24 >/dev/null 2>&1
# The bridge cannot run the engine at all: the same shape.
JOUT="$( ( EXAKIT_HOME="$HOME_K"; EXAKIT_PYEXASOL_VENV="$WORK/no-such-venv"
    . "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/pyexasol.sh"; . "$ROOT/setup/lib/virtual-schemas.sh"
    _require_install() { :; }; exakit_init_logging() { EXAKIT_LOG_FILE="$WORK/json.log"; }
    cmd_connect pg --name x $PG_SET --json ) < /dev/null 2>/dev/null )"; JRC=$?
check "no pyexasol to run the engine: exit 2, one failure object" "2 [False, 'setup', True, True, True, True]" "$JRC $(one "$SHAPE")"
check "...its command is the repair" "exakit update pyexasol" "$(one 'd["command"]')"
# source check answers with the same failure keys. The source now accepts
# another credential than the one it was connected with.
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["sources"]["pg.example.com"]["secret"]="rotated"; json.dump(d, open(sys.argv[1], "w"))' "$STATE"
OUT="$(eng --json check jsonjava 2>/dev/null)"
check "source check --json: the same failure keys, its command the reauth" \
    "[False, 'auth', True, True, 'exakit source reauth jsonjava']" \
    "$(JOUT="$OUT" one '[d["ok"], d["kind"], bool(d["error"]), bool(d["remedy"]), d["command"]]')"
OUT="$(eng --json issues 2>/dev/null)"
has "source issues --json: each row carries the command too" '"command": "exakit source reauth jsonjava"' "$OUT"
OUT="$(printf '%s' "$SECRET" | eng --json connect pg --name jsonauth $PG_SET --secret-stdin 2>"$WORK/json.err")"; RC=$?
check "a refused credential, engine --json: exit 1, kind auth, a first connect has no lifecycle command" "1 auth None" \
    "$RC $(JOUT="$OUT" one '" ".join(str(x) for x in [d["kind"], d["command"]])')"
lacks "...error is the driver's words, the fix is in remedy" "nothing was kept" "$(JOUT="$OUT" one 'd["error"]')"
has "...remedy" "nothing was kept" "$(JOUT="$OUT" one 'd["remedy"]')"
has "...the FAIL line on stderr still says both" "nothing was kept" "$(cat "$WORK/json.err")"
# A repair that dies (a download failing its size or checksum) ends only the
# repair: the first run's object is the answer, and no temporary file is left.
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["java"]=False; json.dump(d, open(sys.argv[1], "w"))' "$STATE"
mkdir -p "$WORK/json-tmp"
TMPDIR="$WORK/json-tmp" JSON_JAVA_INSTALL=die jsonsh "$WORK/json.secret" pg --name jsondie $PG_SET --json --yes
check "Java missing, --yes, the install dies: exit 21, one object - the first run's" "21 [False, 'nojava', True, True, True, True]" "$JRC $(one "$SHAPE")"
has "...the reason is on stderr" "did not match its checksum (test)" "$JERR"
check "...and no temporary file is left behind" "" "$(ls "$WORK/json-tmp" 2>/dev/null)"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["java"]=True; json.dump(d, open(sys.argv[1], "w"))' "$STATE"
TMPDIR="$WORK/no-such-tmp" jsonsh "$WORK/json.secret" pg --name jsontmp $PG_SET --json
check "no temporary file can be made: exit 1, one object (kind setup)" "1 [False, 'setup', True, True, True, True]" "$JRC $(one "$SHAPE")"
# The gate comes before the name, with --json as without: exit 5 both ways.
jsonsh /dev/null gatedtest --json
check "a gated connector and no name, --json: exit 5, one object" "5 [False, 'gated', True, True, True, True]" "$JRC $(one "$SHAPE")"
jsonsh /dev/null gatedtest
check "...and without --json: exit 5 too" "5" "$JRC"
jsonsh /dev/null pg --name Bad-Name $PG_SET --json
check "an invalid name, --json: exit 2, one object" "2 [False, 'input', True, True, True, True]" "$JRC $(one "$SHAPE")"
# Without --json an unreadable --password-file says what it always said.
: > "$WORK/json.log"
jsonsh /dev/null pg --name jsonnofile $PG_SET --password-file "$WORK/no-such.pw"
check "without --json, an unreadable --password-file: exit 2" "2" "$JRC"
has "...the reader's own line" "Cannot read $WORK/no-such.pw" "$JERR"
check "...logged as an error, not as a refusal card" "1 0" \
    "$(grep -c "ERROR Cannot read" "$WORK/json.log") $(grep -c "REJECT Cannot read" "$WORK/json.log")"
# --password-stdin under --json: the connect's one object, or the refusal's.
# The source takes any credential for these (the reauth tests below want
# "rotated" back, and get it after the encodings).
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["sources"]["pg.example.com"].pop("secret", None); json.dump(d, open(sys.argv[1], "w"))' "$STATE"
jsonsh "$WORK/json.secret" pg --name jsonstdin $PG_SET --password-stdin --json
check "--password-stdin --json: exit 0, one object - the connect" "0 [True, 'jsonstdin']" "$JRC $(one '[d["ok"], d["name"]]')"
check "...the piped credential is the CONNECTION's" "$SECRET" "$(dbq 'd["connections"]["EXAKIT_SRC_JSONSTDIN"]["secret"]')"
lacks "...and in neither stream" "$SECRET" "$JOUT$JERR"
run remove jsonstdin >/dev/null 2>&1
jsonsh /dev/null pg --name jsonstdin $PG_SET --password-stdin --json
check "--password-stdin --json, nothing on stdin: exit 2, one failure object" "2 [False, 'input', True, True, True, True]" "$JRC $(one "$SHAPE")"
check "...its error says what happened" "--password-stdin was given, but standard input was empty" "$(one 'd["error"]')"
jsonsh "$WORK/json.secret" pg --name jsonstdin $PG_SET --password-stdin --password-file "$WORK/json.secret" --json
check "--password-stdin with --password-file, --json: exit 2, one failure object" "2 [False, 'input', True, True, True, True]" "$JRC $(one "$SHAPE")"
check "...nothing connected" "false" "$(dbq '"EXAKIT_SRC_JSONSTDIN" in d["connections"]')"
# Review 10, end to end: every trailing line ending is dropped (the bridge
# drops one, the engine the rest), whichever way the credential came.
printf '%s\r\n\n\r\n' "$SECRET" > "$WORK/json.endings"
jsonsh "$WORK/json.endings" pg --name jsonends $PG_SET --password-stdin --json
check "review 10: --password-stdin, CRLF LF CRLF after it: the CONNECTION holds the credential alone" "0 $SECRET" \
    "$JRC $(dbq 'd["connections"]["EXAKIT_SRC_JSONENDS"]["secret"]')"
run remove jsonends >/dev/null 2>&1
jsonsh /dev/null pg --name jsonends $PG_SET --password-file "$WORK/json.endings" --json
check "review 10: --password-file, the same: the credential alone" "0 $SECRET" \
    "$JRC $(dbq 'd["connections"]["EXAKIT_SRC_JSONENDS"]["secret"]')"
run remove jsonends >/dev/null 2>&1
# Review 2 under --json: the one object names the problem, never the value.
for args in "--password-stdin=hunter2" "--passwd=hunter2" "--bogus=hunter2"; do
    : > "$WORK/json.log"
    jsonsh /dev/null pg --name jsonarg $PG_SET "$args" --json
    check "review 2, --json, $(printf '%s' "$args" | sed 's/hunter2/<v>/'): exit 2, one failure object" "2 [False, 'input', True, True, True, True]" "$JRC $(one "$SHAPE")"
    lacks "...the value in neither stream nor the log" "hunter2" "$JOUT$JERR$(cat "$WORK/json.log")"
done

printf '\n== a credential file or pipe: UTF-8 with or without a BOM, UTF-16 by its BOM ==\n'
# pässwörd€ written three ways; each reaches the CONNECTION as itself, through
# --password-file and --password-stdin alike. What is neither is refused, not
# guessed (it once fell back to the locale, which mangles it).
python3 - "$WORK" <<'PYENC'
import codecs, os, sys
pw = "p\u00e4ssw\u00f6rd\u20ac"
for name, data in (("utf8", (pw + "\n").encode("utf-8")), ("bom", codecs.BOM_UTF8 + (pw + "\r\n").encode("utf-8")),
                   ("utf16", codecs.BOM_UTF16_LE + (pw + "\r\n").encode("utf-16-le")),
                   ("latin1", (pw[:-1] + "\n").encode("latin-1"))):
    open(os.path.join(sys.argv[1], "enc-%s.pw" % name), "wb").write(data)
open(os.path.join(sys.argv[1], "enc-expected"), "wb").write(pw.encode("utf-8"))
# Review 1: UTF-16 with a stray byte (an odd count), and UTF-16 without its BOM.
open(os.path.join(sys.argv[1], "enc-utf16odd.pw"), "wb").write(codecs.BOM_UTF16_LE + "pass".encode("utf-16-le") + b"\n")
open(os.path.join(sys.argv[1], "enc-bomless16.pw"), "wb").write("pass\n".encode("utf-16-le"))
PYENC
ENCPW="$(cat "$WORK/enc-expected")"
for enc in utf8 bom utf16; do
    jsonsh /dev/null pg --name "encf$enc" $PG_SET --password-file "$WORK/enc-$enc.pw" --json
    check "--password-file in $enc: exit 0, the CONNECTION holds pässwörd€" "0 $ENCPW" \
        "$JRC $(dbq "d['connections']['EXAKIT_SRC_ENCF$(printf '%s' "$enc" | tr a-z A-Z)']['secret']")"
    jsonsh "$WORK/enc-$enc.pw" pg --name "encs$enc" $PG_SET --password-stdin --json
    check "--password-stdin in $enc: the same" "0 $ENCPW" \
        "$JRC $(dbq "d['connections']['EXAKIT_SRC_ENCS$(printf '%s' "$enc" | tr a-z A-Z)']['secret']")"
    run remove "encf$enc" >/dev/null 2>&1; run remove "encs$enc" >/dev/null 2>&1
done
jsonsh /dev/null pg --name enclatin $PG_SET --password-file "$WORK/enc-latin1.pw" --json
check "a Latin-1 file (neither UTF-8 nor UTF-16): exit 2, one failure object, nothing connected" \
    "2 [False, 'input', True, True, True, True] false" "$JRC $(one "$SHAPE") $(dbq '"EXAKIT_SRC_ENCLATIN" in d["connections"]')"
check "...its error says why" "the credential is not UTF-8 or UTF-16 text" "$(one 'd["error"]')"
# An extra word after the source is never repeated: it may be a credential.
jsonsh /dev/null pg Xtra-W0rd-Kept-Out --name jsonx $PG_SET --json
check "connect with an extra word: exit 2" "2" "$JRC"
lacks "...the word is not repeated" "Xtra-W0rd-Kept-Out" "$JOUT$JERR"
for enc in utf16odd bomless16; do
    jsonsh /dev/null pg --name "encf$enc" $PG_SET --password-file "$WORK/enc-$enc.pw" --json
    check "review 1: --password-file in $enc: exit 2, refused by the shell before \$( ), nothing connected" \
        "2 ['the credential is not UTF-8 or UTF-16 text', True] false" \
        "$JRC $(one '[d["error"], d.get("rejected")]') $(dbq "'EXAKIT_SRC_ENCF$(printf '%s' "$enc" | tr a-z A-Z)' in d['connections']")"
    jsonsh "$WORK/enc-$enc.pw" pg --name "encs$enc" $PG_SET --password-stdin --json
    check "review 1: --password-stdin in $enc: the same" "2 ['the credential is not UTF-8 or UTF-16 text', True] false" \
        "$JRC $(one '[d["error"], d.get("rejected")]') $(dbq "'EXAKIT_SRC_ENCS$(printf '%s' "$enc" | tr a-z A-Z)' in d['connections']")"
    OUT="$(eng --json connect pg --name "ence$enc" $PG_SET --secret-stdin < "$WORK/enc-$enc.pw" 2>/dev/null)"; RC=$?
    check "review 1: the engine (the terminal form's path) refuses $enc too" "2 the credential is not UTF-8 or UTF-16 text" \
        "$RC $(JOUT="$OUT" one 'd["error"]')"
done
OUT="$(eng connect pg --name enclatin $PG_SET --secret-stdin < "$WORK/enc-utf16.pw" 2>&1)"; RC=$?
check "the engine itself reads UTF-16 by its BOM (the terminal form hands it the file as it is)" "0 $ENCPW" \
    "$RC $(dbq 'd["connections"]["EXAKIT_SRC_ENCLATIN"]["secret"]')"
run remove enclatin >/dev/null 2>&1
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["sources"]["pg.example.com"]["secret"]="rotated"; json.dump(d, open(sys.argv[1], "w"))' "$STATE"

printf '\n== exakit source --json: one object of the same shape ==\n'
jsonsrc() { # jsonsrc <stdin-file> <args...> - cmd_source; stdout in JOUT, stderr in JERR, exit in JRC
    _js_in="$1"; shift
    JOUT="$( ( EXAKIT_HOME="$HOME_K"
      . "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/virtual-schemas.sh"
      _require_install() { :; }; exakit_init_logging() { EXAKIT_LOG_FILE="$WORK/json.log"; }
      pyexasol_venv_python() { command -v python3; }
      exakit_vs_engine() { printf '%s\n' "$*" >> "$WORK/json.argv"; eng "$@"; }
      cmd_source "$@" ) < "$_js_in" 2> "$WORK/json.err" )"; JRC=$?
    JERR="$(cat "$WORK/json.err")"
}
jsonsrc /dev/null show jsonjava Xtra-W0rd-Kept-Out --json
check "source with an extra name: exit 2" "2" "$JRC"
lacks "...the word is not repeated" "Xtra-W0rd-Kept-Out" "$JOUT$JERR"
printf 'rotated' > "$WORK/json.rotated"; printf 'not-it' > "$WORK/json.wrong"
rm -f "$WORK/json.argv"; : > "$WORK/json.log"
jsonsrc /dev/null reauth jsonjava --json --password-file "$WORK/json.rotated"
check "reauth --json: exit 0, one object - the engine's" "0 [True, 'ready']" "$JRC $(one '[d["ok"], d["status"]]')"
check "...the engine was asked with --json once" "--json show jsonjava|--json reauth jsonjava --secret-stdin|" "$(tr '\n' '|' < "$WORK/json.argv")"
lacks "...its events are not on the terminal" "OK " "$JERR"
has "...they are in the log" "OK " "$(cat "$WORK/json.log")"
# The same for a reauth: a pipe as --password-file (see the connect above).
mkfifo "$WORK/json.fifo"; ( printf 'rotated' > "$WORK/json.fifo" ) & _jw=$!
jsonsrc /dev/null reauth jsonjava --json --password-file "$WORK/json.fifo"
kill "$_jw" 2>/dev/null; wait "$_jw" 2>/dev/null; rm -f "$WORK/json.fifo"
check "reauth --json, --password-file a pipe: exit 0, one object" "0 [True, 'ready']" "$JRC $(one '[d["ok"], d["status"]]')"
jsonsrc "$WORK/json.rotated" reauth jsonjava --json --password-stdin
check "reauth --json --password-stdin: exit 0, one object" "0 [True, 'ready']" "$JRC $(one '[d["ok"], d["status"]]')"
jsonsrc /dev/null reauth jsonjava --json --password-stdin
check "reauth --json --password-stdin, nothing on stdin: exit 2, one failure object" "2 [False, 'input', True, True, True, True]" "$JRC $(one "$SHAPE")"
: > "$WORK/json.log"; rm -f "$WORK/json.argv"
jsonsrc /dev/null reauth jsonjava --password=hunter2 --json
check "review 2: source reauth --password=<v> --json: exit 2, one failure object, the engine never ran" "2 [False, 'input', True, True, True, True] no" \
    "$JRC $(one "$SHAPE") $([ -f "$WORK/json.argv" ] && echo yes || echo no)"
check "...the error names the problem" "a credential was given as an argument, where other users can read it in the process list" "$(one 'd["error"]')"
lacks "...not the value: stdout, stderr, the log" "hunter2" "$JOUT$JERR$(cat "$WORK/json.log")"
jsonsrc /dev/null list --bogus=hunter2 --json
check "review 2: source list --bogus=<v> --json: the option's name only" "2 unknown option '--bogus' for source list" "$JRC $(one 'd["error"]')"
jsonsrc /dev/null --json
check "source --json (no action): exit 0, the listing's one object" "0 True" "$JRC $(one 'd["ok"]')"
check "...whose rows carry host and tls" "pg.example.com verify" \
    "$(one '" ".join([[s["host"], s["tls"]] for s in d["sources"] if s["name"] == "jsonjava"][0])')"
COLUMNS=120 jsonsrc /dev/null list
has "source list, the real engine through the shell: the host and TLS level in its row" "pg.example.com  verify" \
    "$(printf '%s\n' "$JOUT" | grep '^  jsonjava ')"
# --json never asks, so it never takes silence for consent: a disconnect or
# remove without --yes changes nothing (exit 5), as without a terminal.
jsonsrc /dev/null remove jsonjava --json
check "source remove --json without --yes: exit 5, kind declined, the --yes form named" \
    "5 [False, 'declined', 'exakit source remove jsonjava --yes --json']" "$JRC $(one '[d["ok"], d["kind"], d["command"]]')"
jsonsrc /dev/null show jsonjava --json
check "...and the source is still there" "0 True" "$JRC $(one 'd["ok"]')"
jsonsrc /dev/null disconnect jsonjava --json
check "source disconnect --json without --yes: exit 5, kind declined" "5 declined" "$JRC $(one 'd["kind"]')"
jsonsrc /dev/null show jsonjava --json
check "...still connected" "0 True" "$JRC $(one 'd["ok"]')"
jsonsrc /dev/null reauth jsonjava --json --password-file "$WORK/json.wrong"
check "reauth --json with a credential the source refuses: one failure object" "[False, 'auth', True, True, True]" \
    "$(one '[d["ok"], d["kind"], bool(d["error"]), bool(d["remedy"]), "command" in d]')"
jsonsrc /dev/null reauth jsonjava --json --password-file "$WORK/json-tmp"
check "reauth --json, a --password-file that cannot be read: exit 2, one object" "2 [False, 'input', True, True, True, True]" "$JRC $(one "$SHAPE")"
jsonsrc /dev/null reauth jsonjava --json
check "reauth --json, no credential: exit 2, one object" "2 [False, 'input', True, True, True, True]" "$JRC $(one "$SHAPE")"
jsonsrc /dev/null reauth jsonjava --password-file "$WORK/no-such.pw"
check "reauth without --json, an unreadable file: exit 2, the reader's own line" "2 1" "$JRC $(printf '%s\n' "$JERR" | grep -c "Cannot read")"
for args in "bogus --json" "show --json" "check --json" "list --bogus --json" "show a b --json"; do
    # shellcheck disable=SC2086
    jsonsrc /dev/null $args
    check "source $args: exit 2, one failure object" "2 [False, 'input', True, True, True, True]" "$JRC $(one "$SHAPE")"
done
jsonsrc /dev/null show --json
check "...a missing name's command lists the sources" "exakit source list" "$(one 'd["command"]')"
jsonsrc /dev/null show nosuch --json
check "source show of no such source: exit 4, one object" "4 [False, 'missing', 'exakit source list']" "$JRC $(one '[d["ok"], d["kind"], d["command"]]')"

run remove jsonok
run remove jsonjava

printf '\n== the engine never answers --json with a traceback ==\n'
BROKEN="$WORK/broken-defs"; cp -R "$DEFS" "$BROKEN"; printf '{"connectors": [' > "$BROKEN/catalog.json"
OUT="$(python3 "$ROOT/setup/virtual-schemas/engine/cli.py" --defs "$BROKEN" --kit-home "$HOME_K" --json catalog 2>"$WORK/json.err")"; RC=$?
check "an unexpected exception: exit 1, one object, kind internal" "1 [False, 'internal', True, None]" \
    "$RC $(JOUT="$OUT" one '[d["ok"], d["kind"], "\n" not in d["error"], d["command"]]')"
has "...the traceback is on stderr (the shells keep it in the log)" "Traceback (most recent call last)" "$(cat "$WORK/json.err")"
lacks "...and not on stdout" "Traceback" "$OUT"
OUT="$(python3 "$ROOT/setup/virtual-schemas/engine/cli.py" --defs "$BROKEN" --kit-home "$HOME_K" catalog 2>/dev/null)"; RC=$?
check "...without --json: one FAIL line for the bridge to render, exit 1" "1 1" "$RC $(printf '%s\n' "$OUT" | grep -c '^FAIL the engine failed unexpectedly: ')"
OUT="$(python3 "$ROOT/setup/virtual-schemas/engine/cli.py" --defs "$BROKEN" --kit-home "$HOME_K" --json no-such-command 2>/dev/null)"; RC=$?
check "arguments the engine does not take, with --json: exit 2, one object" "2 [False, 'input']" "$RC $(JOUT="$OUT" one '[d["ok"], d["kind"]]')"
# A copy of the engine with no setup/core beside it (it imports core/state.py).
mkdir -p "$WORK/lonely/a"; cp -R "$ROOT/setup/virtual-schemas/engine" "$WORK/lonely/a/engine"
OUT="$(python3 "$WORK/lonely/a/engine/cli.py" --defs x --kit-home y --json list 2>/dev/null)"; RC=$?
check "an engine that cannot even import (a kit copy updated by halves): exit 1, one object" "1 [False, 'internal']" \
    "$RC $(JOUT="$OUT" one '[d["ok"], d["kind"]]')"

printf '\n== the day log (exakit logs virtual-schemas): every statement, no secret ==\n'
# engine/vslog.py: one file a day under <kit home>/logs, owner-only, the files
# of more than 14 days ago pruned; every statement the engine sends and every
# event it says, redacted of the run's secrets and of every credential shape.
# Last in the suite, so the sweep below reads every run above.
TODAY="$(python3 -c 'import datetime; print(datetime.date.today().strftime("%Y%m%d"))')"
VSLOG="$HOME_K/logs/virtual-schemas-$TODAY.log"
check "one file a day under the kit's log folder" "virtual-schemas-$TODAY.log" "$(ls "$HOME_K/logs" | grep '^virtual-schemas-' | tr '\n' ' ' | sed 's/ $//')"
check "...owner-only (mode 600)" "600" "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$VSLOG")"
check "...every statement the engine sent: the happy path's CONNECTION, its credential as ***" "yes" \
    "$(grep -qE "\] connect sales SQL +CREATE CONNECTION \"EXAKIT_SRC_SALES\" TO 'jdbc:postgresql://pg\.example\.com:5432/sales[^']*' USER 'reader' IDENTIFIED BY '\*\*\*'$" "$VSLOG" && echo yes || echo no)"
check "...a multi-line statement's further lines marked |" "yes" \
    "$(grep -qE '\] connect sales \| +%scriptclass com\.exasol\.adapter\.RequestDispatcher;' "$VSLOG" && echo yes || echo no)"
check "...the engine's own events, as the screen showed them" "yes" \
    "$(grep -qE '\] connect sales OK +Virtual schema VS_SALES: ' "$VSLOG" && echo yes || echo no)"
check "...a failed statement's answer, classified" "yes" \
    "$(grep -qE '\] reauth sales SQLERR \[auth\] ' "$VSLOG" && echo yes || echo no)"
check "...each run framed by START and END, with its exit code" "yes" \
    "$(grep -qE '\] reauth sales START +reauth sales --secret-stdin \(dsn 127\.0\.0\.1:8563, user sys\)$' "$VSLOG" && \
       grep -qE '\] reauth sales END +exit 1, kind auth \(' "$VSLOG" && echo yes || echo no)"
check "...not the lookups and the form's checks (catalog, resolve, inputs, field)" "0" \
    "$(grep -cE '\] (catalog|resolve|inputs|field) ' "$VSLOG")"
# Every credential the suite handed the engine, in every connector's shape:
# passwords, a quote doubled in SQL, tokens, AWS and Azure keys, a SAS, a
# service-account key, the refused ones too.
for needle in s3cr3t n3w-T0ken n3w-secret still-the-old-one AnotherSecretKeyValue wJalrXUtnFEMI QUFBQUFBQUFB \
              QkJDQkJDQkJD abcSig Hunter2-pa55 hunter2 MIIfakeKEYbody dapi-wrong; do
    check "no credential of the suite's runs is in it: $needle" "" "$(grep -l -- "$needle" "$HOME_K"/logs/virtual-schemas-*.log 2>/dev/null)"
done

# A driver's message that quotes credentials the run never knew, in the three
# shapes a credential takes in SQL and URLs: the patterns catch them.
python3 - "$STATE" <<'PYECHO'
import json, sys
json.dump({"sources": {"pg.example.com": {"tables": ["ORDERS"], "fail": "echo", "message":
    "JDBC-Client-Error: Connecting to 'jdbc:postgresql://reader:Leak-Uri-1@pg.example.com:5432/sales"
    "?password=Leak-Param-2&ssl=true' failed\nCaused by: org.postgresql.util.PSQLException: the session "
    "ran CREATE USER x IDENTIFIED BY 'Leak-Ident-3' and ;pwd=Leak-Pwd-4;"}}}, open(sys.argv[1], "w"))
PYECHO
run_secret "$SECRET" connect postgresql --name leak $PG_SET --secret-stdin
check "a source whose driver quotes credentials: the connect fails" "1" "$RC"
for needle in Leak-Uri-1 Leak-Param-2 Leak-Ident-3 Leak-Pwd-4; do
    lacks "...$needle is in no line of the log" "$needle" "$(cat "$VSLOG")"
done
has "...user:password@ keeps the user" "jdbc:postgresql://reader:***@pg.example.com:5432/sales" "$(grep '\] connect leak ' "$VSLOG")"
has "...?password= keeps the name" "?password=***&ssl=true" "$(grep '\] connect leak ' "$VSLOG")"
has "...the cause under it is kept, redacted" "IDENTIFIED BY '***' and ;pwd=***;" "$(grep '\] connect leak SQLERR' "$VSLOG")"
# Review 2: the same message reached the screen's FAIL line, the kit's main
# log (error -> _exakit_log_file) and --json's error through sql.redact,
# which knew only IDENTIFIED BY: ;pwd=Leak-Pwd-4; stood.
for needle in Leak-Uri-1 Leak-Param-2 Leak-Ident-3 Leak-Pwd-4; do
    lacks "review 2: $needle is not on the screen's FAIL line" "$needle" "$OUT"
done
has "review 2: ...which still says what failed" "PSQLException: the session ran CREATE USER x IDENTIFIED BY '***' and ;pwd=***;" "$OUT"
OUT="$(printf '%s' "$SECRET" | eng --json connect postgresql --name leak $PG_SET --secret-stdin 2>/dev/null)"
check "review 2: --json: the error field holds none of them" "[False, False, False, False]" \
    "$(JOUT="$OUT" one '[n in d["error"] for n in ("Leak-Uri-1", "Leak-Param-2", "Leak-Ident-3", "Leak-Pwd-4")]')"

# Through the shell, as a person runs it: the credential from --password-file,
# and the log named once when the command fails.
logsh() {
    ( EXAKIT_HOME="$HOME_K"
      . "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/virtual-schemas.sh"
      _require_install() { :; }; exakit_init_logging() { EXAKIT_LOG_FILE="$WORK/vslog-setup.log"; }
      pyexasol_venv_python() { command -v python3; }
      exakit_vs_engine() { eng "$@"; }
      "$@" ) 2>&1
}
LOGLINE="Log (every SQL statement, secrets redacted): $VSLOG"
db '{"sources": {"pg.example.com": {"tables": ["ORDERS"], "secret": "Right-0ne-pw"}}}'
printf '%s' 'Pw-File-0nly-9' > "$WORK/vslog-wrong.pw"
printf '%s' 'Right-0ne-pw' > "$WORK/vslog-right.pw"
OUT="$(logsh cmd_connect pg --name logpw $PG_SET --password-file "$WORK/vslog-wrong.pw" </dev/null)"; RC=$?
check "exakit connect, a --password-file the source refuses: exit 1" "1" "$RC"
check "...the log's path said once" "1" "$(printf '%s\n' "$OUT" | grep -cF "$LOGLINE")"
check "...as the last line" "$LOGLINE" "$(printf '%s\n' "$OUT" | tail -n 1 | sed 's/^ *[^ ]* //')"
check "...the run is in it" "yes" "$(grep -qE "\] connect logpw SQL +CREATE CONNECTION .* IDENTIFIED BY '\*\*\*'$" "$VSLOG" && echo yes || echo no)"
lacks "...the password from the file is in no log" "Pw-File-0nly-9" "$(cat "$HOME_K"/logs/* "$WORK/vslog-setup.log" 2>/dev/null)"
OUT="$(logsh cmd_connect pg --name logok $PG_SET --password-file "$WORK/vslog-right.pw" </dev/null)"; RC=$?
check "a connect that succeeds: exit 0, no log line" "0 0" "$RC $(printf '%s\n' "$OUT" | grep -cF 'Log (every SQL')"
lacks "...its password is in no log either" "Right-0ne-pw" "$(cat "$HOME_K"/logs/* "$WORK/vslog-setup.log" 2>/dev/null)"
OUT="$(logsh cmd_connect nosuchdb --name x </dev/null)"; RC=$?
check "a refusal the engine never logged (an unknown connector): no log line" "2 0" "$RC $(printf '%s\n' "$OUT" | grep -cF 'Log (every SQL')"
# The source stops answering; what the database holds stays as it is.
srcfail() { python3 -c 'import json,sys
d = json.load(open(sys.argv[1])); s = d["sources"]["pg.example.com"]
s.update(fail=sys.argv[2]) if sys.argv[2] else s.pop("fail", None)
json.dump(d, open(sys.argv[1], "w"))' "$STATE" "$1"; }
srcfail unreachable
OUT="$(logsh cmd_source check logok </dev/null)"; RC=$?
check "exakit source check of a source that fails: exit 1, the log's path once" "1 1" "$RC $(printf '%s\n' "$OUT" | grep -cF "$LOGLINE")"
srcfail ""
# --json: stdout stays the one object; the path goes to stderr.
jsonsh /dev/null pg --name logjson $PG_SET --password-file "$WORK/vslog-wrong.pw" --json
check "connect --json that fails: one object on stdout, the path once on stderr" "1 [False, 'auth'] 1" \
    "$JRC $(one '[d["ok"], d["kind"]]') $(printf '%s\n' "$JERR" | grep -cF "$LOGLINE")"
lacks "...and not on stdout" "Log (every SQL" "$JOUT"
lacks "...the password from the file is in no log" "Pw-File-0nly-9" "$(cat "$HOME_K"/logs/* "$WORK/json.log" 2>/dev/null)"
run remove logok

# exakit logs: the day log is one of its targets, through the real entry point.
LOGS_JSON="$(EXAKIT_HOME="$HOME_K" bash "$ROOT/setup/exakit" logs --json 2>/dev/null)"
check "exakit logs lists it: target virtual-schemas, the newest day file" "$VSLOG" \
    "$(printf '%s' "$LOGS_JSON" | python3 -c 'import json,sys; print(next((t["path"] for t in json.load(sys.stdin)["targets"] if t["target"] == "virtual-schemas"), ""))' 2>/dev/null)"
check "...and exakit logs virtual-schemas --path names it" "$VSLOG" "$(EXAKIT_HOME="$HOME_K" bash "$ROOT/setup/exakit" logs virtual-schemas --path 2>/dev/null)"

# The module itself: the shapes, a long statement, the pruning, the mode.
UNIT="$(python3 - "$ROOT" "$WORK/vslog-unit" <<'PYUNIT'
import datetime, hashlib, os, sys
sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import vslog
folder = sys.argv[2]
os.makedirs(folder)
today = datetime.date.today()
def day(days):
    path = os.path.join(folder, "virtual-schemas-%s.log" % (today - datetime.timedelta(days=days)).strftime("%Y%m%d"))
    open(path, "w").close()
    return path
day(20); day(15); day(14); day(3)
os.chmod(day(0), 0o644)
open(os.path.join(folder, "install-20200101-000000.log"), "w").close()
log = vslog.RunLog(folder, "connect", "unit")
log.secret("Run-Known-0")
long_sql = "CREATE LUA ADAPTER SCRIPT X AS\n" + "-- lua\n" * 1000 + "-- the-tail-marker\n/"
log.statement(long_sql)
log.statement("CREATE CONNECTION C TO 'jdbc:x://h' USER 'r' IDENTIFIED BY 'Lit-''Pw-1'")
log.write("INFO", "jdbc:sqlserver://h:1433;databaseName=d;password=Semi-Pw-2;encrypt=true")
log.write("INFO", "https://acct.blob.core.windows.net/c?sv=1&sig=Sas-Sig-3&sp=r")
log.write("INFO", "mongodb+srv://reader:Uri-Pw-4@cluster0.example.net/db")
log.write("INFO", 'CREATE USER u IDENTIFIED BY "Quoted-Pw-5"')
log.write("INFO", "a token=Tok-6 and AccountKey=Key-7== and the run's own Run-Known-0, as JSON \"Run-Known-0\"")
log.write("INFO", "s3://bucket/path?X-Amz-Signature=Amz-8&X-Amz-Date=1")
log.close()
text = open(log.path).read()
print("names " + " ".join(sorted(os.listdir(folder))))
print("mode " + oct(os.stat(log.path).st_mode & 0o777)[2:])
print("leaks " + " ".join(n for n in ("Lit-", "Pw-1", "Semi-Pw-2", "Sas-Sig-3", "Uri-Pw-4", "Quoted-Pw-5", "Tok-6",
                                      "Key-7", "Run-Known-0", "Amz-8") if n in text))
redacted = vslog.redact(long_sql)
sql_lines = [l for l in text.splitlines() if " connect unit SQL " in l or " connect unit | " in l]
print("digest %s %s %s" % ("CREATE LUA ADAPTER SCRIPT X AS" in sql_lines[0],
                           sql_lines[len(redacted[:vslog.HEAD].splitlines()) - 1].endswith(
                               " ... [%d characters, sha256 %s]" % (len(redacted), hashlib.sha256(redacted.encode()).hexdigest())),
                           "the-tail-marker" not in text))
print(text)
PYUNIT
)"
check "the files of more than 14 days ago are pruned, the others kept" \
    "names install-20200101-000000.log $(python3 -c 'import datetime as d; t=d.date.today(); print(" ".join("virtual-schemas-%s.log" % (t - d.timedelta(days=n)).strftime("%Y%m%d") for n in (14, 3, 0)))')" \
    "$(printf '%s\n' "$UNIT" | grep '^names ')"
check "...a day file made with a wider mode is owner-only once written" "mode 600" "$(printf '%s\n' "$UNIT" | grep '^mode ')"
check "every credential shape and every known secret is redacted" "leaks " "$(printf '%s\n' "$UNIT" | grep '^leaks ')"
has "...user:password@ in a URI" "mongodb+srv://reader:***@cluster0.example.net/db" "$UNIT"
has "...IDENTIFIED BY '...', a doubled quote inside" "IDENTIFIED BY '***'" "$UNIT"
has "...IDENTIFIED BY \"...\"" 'IDENTIFIED BY "***"' "$UNIT"
has "...;password= and &sig=" ";password=***;encrypt=true" "$UNIT"
has "...&sig=" "&sig=***&sp=r" "$UNIT"
has "...X-Amz-Signature=" "X-Amz-Signature=***&X-Amz-Date=1" "$UNIT"
check "a statement over 4000 characters: its head, then the sha256 of the whole; not the rest" "digest True True True" \
    "$(printf '%s\n' "$UNIT" | grep '^digest ')"

printf '\n== the day log: the security review'"'"'s findings, each with its own input ==\n'
# Review 1: a --password-file holding two lines. pyexasol prints a failed
# statement back in its query => field, IDENTIFIED BY '<both lines>' and all;
# redacting the driver's text line by line never matched the whole secret.
python3 - "$STATE" <<'PYML'
import json, sys
json.dump({"sources": {"pg.example.com": {"tables": ["ORDERS"]}},
           "connection_fail": "insufficient privileges for creating connection"}, open(sys.argv[1], "w"))
PYML
printf 'Hunter22\n# rotated 2026-11' > "$WORK/vslog-multiline.pw"
OUT="$(logsh cmd_connect pg --name multiline $PG_SET --password-file "$WORK/vslog-multiline.pw" </dev/null)"; RC=$?
check "review 1: a --password-file holding 'Hunter22<newline># rotated 2026-11', CREATE CONNECTION refused: exit 1" "1" "$RC"
check "review 1: ...the driver's query => field is in the log, the literal as ***" "yes" \
    "$(grep -qE "\] connect multiline SQLERR +query +=> +CREATE CONNECTION \"EXAKIT_SRC_MULTILINE\" .* IDENTIFIED BY '\*\*\*'$" "$VSLOG" && echo yes || echo no)"
for needle in Hunter22 "rotated 2026-11"; do
    lacks "review 1: ...'$needle' is in no log" "$needle" "$(cat "$HOME_K"/logs/* "$WORK/vslog-setup.log" 2>/dev/null)"
    lacks "review 1: ...nor on the screen" "$needle" "$OUT"
done

# Review 2 through the shell: the kit's main log (error -> _exakit_log_file).
python3 - "$STATE" <<'PYECHO2'
import json, sys
json.dump({"sources": {"pg.example.com": {"tables": ["ORDERS"], "fail": "echo", "message":
    "Caused by: org.postgresql.util.PSQLException: the session ran ;pwd=Leak-Pwd-4; for mongodb://reader:Tr0ub4dor&3xyz@host"}}},
    open(sys.argv[1], "w"))
PYECHO2
: > "$WORK/vslog-setup.log"
OUT="$(logsh cmd_connect pg --name leakmain $PG_SET --password-file "$WORK/vslog-right.pw" </dev/null)"; RC=$?
check "review 2: a connect whose driver quotes credentials, through the shell: exit 1" "1" "$RC"
has "review 2: ...the kit's main log has its FAIL line" "PSQLException" "$(cat "$WORK/vslog-setup.log")"
for needle in Leak-Pwd-4 Tr0ub4d; do
    lacks "review 2: ...without $needle (main log, screen)" "$needle" "$(cat "$WORK/vslog-setup.log")$OUT"
done

# Review 8: a short password replaced only where it stands alone.
db '{"sources": {"pg.example.com": {"tables": ["ORDERS"], "secret": "postgres"}}}'
run_secret postgres connect postgresql --name pgshort $PG_SET --secret-stdin
check "review 8: the password 'postgres': connected" "0" "$RC"
check "review 8: ...jdbc:postgresql:// is whole in the log, the literal ***" "yes" \
    "$(grep -qE "\] connect pgshort SQL +CREATE CONNECTION \"EXAKIT_SRC_PGSHORT\" TO 'jdbc:postgresql://pg\.example\.com:5432/sales[^']*' USER 'reader' IDENTIFIED BY '\*\*\*'$" "$VSLOG" && echo yes || echo no)"
run remove pgshort

# Review 4: START names the --set keys, never their values (validated or not).
run plan postgresql --name review4 --set "uri=mongodb://u:pa/ssWORD@host/db" --set "uri=mongodb://alice@x.com:SECRWORD@host/db" \
    --set secret_key=SKWORD --set "catalog_url=https://cat.example.com/api?apikey=KEYWORD" --set user=scott/tigerWORD
check "review 4: a plan with values that hold credentials: refused, exit 2" "2" "$RC"
check "review 4: ...START names the keys" "yes" \
    "$(grep -qE '\] plan review4 START +plan postgresql --name review4 --set uri=\.\.\. --set uri=\.\.\. --set secret_key=\*\*\* --set catalog_url=\.\.\. --set user=\.\.\. \(dsn' "$VSLOG" && echo yes || echo no)"
lacks "review 4: ...and no value: not one of ssWORD SECRWORD SKWORD KEYWORD tigerWORD" "WORD" "$(grep '\] plan review4 ' "$VSLOG")"

# The module itself, with the review's exact inputs.
cat > "$WORK/vslog-review.py" <<'PYREVIEW'
import contextlib, datetime, hashlib, io, os, signal, sys, time, traceback
engine = sys.argv[1] + "/setup/virtual-schemas/engine"
sys.path.insert(0, engine)
import vslog, sql
base = sys.argv[2]
os.makedirs(base)
today = datetime.date.today().strftime("%Y%m%d")
signal.alarm(60)  # a FIFO that blocked would hang the suite

def logged(name, **secrets_and_calls):
    folder = os.path.join(base, name)
    log = vslog.RunLog(folder, "connect", name)
    return log, folder

def text_of(log):
    log.close()
    return open(log.path, encoding="utf-8", errors="surrogateescape").read()

# 1: a multi-line secret, registered, printed back across lines; unregistered
# (check, refresh: no secret), the open literal across lines; a PEM line by line.
log, _ = logged("r1")
log.secret("Hunter22\n# rotated 2026-11")
log.failed("insufficient privileges", "error", "(\n    message     =>  insufficient privileges\n"
           "    query       =>  CREATE CONNECTION \"C\" TO 'x' USER 'u' IDENTIFIED BY 'Hunter22\n# rotated 2026-11'\n)")
log2, _ = logged("r1b")
log2.failed("insufficient privileges", "error", "query => CREATE CONNECTION \"C\" TO 'x' USER 'u' IDENTIFIED BY "
            "'Unknown-Line-One\nUnknown-Line-Two'\n)")
pem = "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC\nBKcwggSjAgEAAoIBAQC7\n-----END PRIVATE KEY-----\n"
log3, _ = logged("r1c")
log3.secret(pem)
log3.failed("key rejected", "auth", "key rejected:\n  > MIIEvQIBADANBgkqhkiG9w0BAQEFAASC\n  > BKcwggSjAgEAAoIBAQC7\n")
t1, t2, t3 = text_of(log), text_of(log2), text_of(log3)
print("r1 " + " ".join(str(n in t) for n, t in (("Hunter22", t1), ("rotated 2026-11", t1), ("Unknown-Line", t2),
                                                ("MIIEvQIBADANBgkqhkiG9w0BAQEFAASC", t3), ("BKcwggSjAgEAAoIBAQC7", t3))))

# 2: sql.redact - the patterns, before the cut at MAX_ERROR; classify unchanged.
leak = sql.redact(Exception("Caused by: org.postgresql.util.PSQLException: the session ran ;pwd=Leak-Pwd-4; now"), [])
cut = sql.redact(Exception("x" * 570 + " mongodb://reader:Tr0ub4dor&3xyz@host/db"), [])
print("r2 %s %s %s" % ("Leak-Pwd-4" in leak, "Tr0ub4d" in cut, len(cut) <= sql.MAX_ERROR))
kinds = []
for message in ('FATAL: password authentication failed for user "reader"',
                "Access denied for user 'reader'@'10.0.0.9' (using password: YES)",
                "S3Exception: The request signature we calculated does not match the signature you provided.",
                "Invalid access token",
                "Server failed to authenticate the request. https://acct.blob.core.windows.net/c?sv=1&sig=SigVal123&sp=r",
                "Programmatic access token is invalid: https://h.example.com/api?token=TokVal123"):
    shown = sql.redact(Exception(message), [])
    kinds.append("%s=%s%s" % (sql.classify(message), sql.classify(shown),
                              "!" if "SigVal123" in shown or "TokVal123" in shown else ""))
print("r2kinds " + " ".join(kinds))

# 3: a driver line over 4000 characters, a registered secret across character 1000.
log, _ = logged("r3")
line = "X" * 990 + "Straddle-Pw-0123456789" + "Y" * 4000
log.failed("too long", "error", line, secrets=["Straddle-Pw-0123456789"])
text = text_of(log)
redacted = "X" * 990 + "***" + "Y" * 4000
print("r3 %s %s %s" % ("Straddle" in text, hashlib.sha256(redacted.encode()).hexdigest() in text,
                       hashlib.sha256(line.encode()).hexdigest() in text))

# 5: the shapes and the forms the first patterns missed.
shapes = [("sslpassword=Rv5a", "Rv5a"), ("trustStorePassword=Rv5b", "Rv5b"), ("db_password=Rv5c", "Rv5c"),
          ("Auth_AccessToken=Rv5d", "Rv5d"), ("private_key_file_pwd=Rv5e", "Rv5e"), ("password:dapiRv5f", "Rv5f"),
          ('{"password": "Rv5g"}', "Rv5g"), ('"awsSecretAccessKey":"abc\\/defRv5h"', "Rv5h"), ("PWD = Rv5i", "Rv5i"),
          ("password= Rv5j", "Rv5j"), ("key=Rv5k", "Rv5k"), ("api_key=Rv5l", "Rv5l"), ("credential=id:Rv5m", "Rv5m"),
          ("jdbc:oracle:thin:scott/tigerRv5n@//h:1521/svc", "Rv5n"), ("password={pa;ssRv5o}", "ssRv5o"),
          ("mongodb://u:pa/ssRv5p@host/db", "Rv5p"), ("mongodb://alice@x.com:Rv5q@host/db", "Rv5q")]
missed = [s for s, n in shapes if n in vslog.redact(s)]
kept = [vslog.redact(s) for s in ("sslpassword=x", "password={pa;ss}", "mongodb://alice@x.com:p@host/db")]
secret = "Pa  ss/w~rd-16"
written = ["Pa++ss%2Fw~rd-16", "Pa%20%20ss%2fw~rd-16", "Pa++ss%2Fw%7Erd-16", "Pa  ss\\/w~rd-16", "Pa ss/w~rd-16"]
missed += [w for w in written if "rd-16" in vslog.redact("x " + w + " y", [secret])]
print("r5 missed:%s" % "|".join(missed))
print("r5 kept " + " ".join(kept))

# 6: the day file a link or a FIFO: no log, the target untouched, no wait.
link = os.path.join(base, "r6link"); os.makedirs(link)
target = os.path.join(base, "elsewhere.txt"); open(target, "w").write("keep\n"); os.chmod(target, 0o644)
os.symlink(target, os.path.join(link, "virtual-schemas-%s.log" % today))
log = vslog.RunLog(link, "connect", "r6"); log.write("INFO", "x"); log.close()
fifo = os.path.join(base, "r6fifo"); os.makedirs(fifo)
os.mkfifo(os.path.join(fifo, "virtual-schemas-%s.log" % today))
started = time.time(); log2 = vslog.RunLog(fifo, "connect", "r6"); log2.write("INFO", "x"); log2.close()
print("r6 %s %s %s %s %s" % (log.path, oct(os.stat(target).st_mode & 0o777)[2:], open(target).read() == "keep\n",
                             log2.path, time.time() - started < 2))

# 8: short secrets only where they stand alone.
log, _ = logged("sales")
log.secret("postgres", "a")
log.statement("CREATE CONNECTION \"C\" TO 'jdbc:postgresql://pg.example.com:5432/sales' USER 'reader' IDENTIFIED BY 'postgres'")
log.write("INFO", "reader sales a postgres")
text = text_of(log)
print("r8 %s %s %s" % ("jdbc:postgresql://pg.example.com:5432/sales' USER 'reader' IDENTIFIED BY '***'" in text,
                       " connect sales INFO   reader sales *** ***" in text, "postgres'" in text))

# 9: a lone surrogate in a long text; the driver's exception never chained.
log, _ = logged("r9")
log.statement("SELECT '" + "x" * 5000 + "\udc80'")
log.failed("m", "error", "E" * 5000 + "\udc80")
# Built from parts: a traceback prints source lines, and this file's own
# must not be what a check finds.
chain9 = "Chain-" + "Pw-9"
statement9 = "CREATE CONNECTION C TO 'x' USER 'u' IDENTIFIED BY '%s'" % chain9
class Backend(object):
    def execute(self, sql_text):
        raise Exception("E" * 5000 + "\udc80 query => " + sql_text)
    query = execute
try:
    sql.Database(Backend(), log).execute(statement9, [chain9])
    raised = "nothing"
except Exception as error:
    raised = "%s/%s" % (type(error).__name__, error.__suppress_context__)
    trace = "".join(traceback.format_exception(type(error), error, error.__traceback__))
text = text_of(log)
print("r9 %s %s %s %s" % (raised, chain9 in trace, "sha256" in text, chain9 in text))
import cli, lifecycle
chain7, chain8, run99 = "Chain-" + "Pw-7", "Chain-" + "Pw-8", "Run-" + "Secret-99"
def boom(self, *args, **kwargs):
    try:
        raise Exception("query => CREATE CONNECTION C TO 'x' USER 'u' IDENTIFIED BY '%s' and %s" % (chain7, run99))
    except Exception:
        raise RuntimeError("unexpected, password=" + chain8)
lifecycle.Engine.connect = boom
kit = os.path.join(base, "r9kit"); os.makedirs(kit)
sys.stdin = io.TextIOWrapper(io.BytesIO(run99.encode()))
err, out = io.StringIO(), io.StringIO()
with contextlib.redirect_stderr(err), contextlib.redirect_stdout(out):
    code = cli.main(["--defs", sys.argv[3], "--kit-home", kit, "--deployment-dir", base, "--dsn", "127.0.0.1:8563", "--password-file", "/nonexistent",
                     "connect", "postgresql", "--name", "chain", "--set", "host=pg.example.com", "--set", "database=sales",
                     "--set", "user=reader", "--secret-stdin"])
day = open(os.path.join(kit, "logs", "virtual-schemas-%s.log" % today)).read()
everything = err.getvalue() + out.getvalue() + day
print("r9cli %d %s %s %s" % (code, "RuntimeError" in err.getvalue(),
                             "Traceback (most recent call last)" in err.getvalue(),
                             [n for n in (chain7, chain8, run99) if n in everything]))

# 10: linear time on what a hostile source could send (80k characters each).
slow = []
for hostile in ("a." * 40000, "a://" * 20000, "x:y@" * 20000, "password=" * 9000, 'password:"' * 8000, '"' * 80000,
                "{" * 80000, "pwd={" * 16000, "jdbc:oracle:thin:" * 4800, "IDENTIFIED BY '" * 5400, "a" * 80000):
    started = time.time()
    vslog.redact(hostile, ["Hunter22-long-secret", "short"])
    sql.redact(Exception(hostile), ["Hunter22-long-secret"])
    if time.time() - started > 1.0:
        slow.append(hostile[:12])
print("r10 slow:%s" % "|".join(slow))
PYREVIEW
REVIEW="$(python3 "$WORK/vslog-review.py" "$ROOT" "$WORK/vslog-review" "$DEFS" 2>&1)"
check "review 1: a registered multi-line secret printed across lines; an unregistered literal across lines; a PEM line by line: none in the log" \
    "r1 False False False False False" "$(printf '%s\n' "$REVIEW" | grep '^r1 ')"
check "review 2: sql.redact applies the patterns before the cut at 600 (;pwd=Leak-Pwd-4;, mongodb://reader:Tr0ub4dor&3xyz@host)" \
    "r2 False False True" "$(printf '%s\n' "$REVIEW" | grep '^r2 ')"
check "review 2: ...and every class is the same after it (password auth, using password: YES, signature, access token, sig=, token=)" \
    "r2kinds auth=auth auth=auth auth=auth auth=auth auth=auth auth=auth" "$(printf '%s\n' "$REVIEW" | grep '^r2kinds ')"
check "review 3: a driver line over 4000 characters, a secret across character 1000: redacted before the cut and the sha256" \
    "r3 False True False" "$(printf '%s\n' "$REVIEW" | grep '^r3 ')"
check "review 5: sslpassword= trustStorePassword= db_password= Auth_AccessToken= private_key_file_pwd= password: JSON PWD = key= api_key= credential= Oracle braces user@ forms" \
    "r5 missed:" "$(printf '%s\n' "$REVIEW" | grep '^r5 missed')"
check "review 5: ...the names kept, braces closed, the user kept" "r5 kept sslpassword=*** password={***} mongodb://alice@x.com:***@host/db" \
    "$(printf '%s\n' "$REVIEW" | grep '^r5 kept')"
check "review 6: a day file that is a link: no log, the target's mode and text untouched; a FIFO: no log, no wait" \
    "r6 None 644 True None True" "$(printf '%s\n' "$REVIEW" | grep '^r6 ')"
check "review 8: the passwords 'postgres' and 'a': jdbc:postgresql:// and sales/reader whole, the literal and lone words ***" \
    "r8 True True False" "$(printf '%s\n' "$REVIEW" | grep '^r8 ')"
check "review 9: a lone surrogate in a long text: the DbError raised, without the driver's exception, logged digested, redacted" \
    "r9 DbError/True False True False" "$(printf '%s\n' "$REVIEW" | grep '^r9 ')"
check "review 9: ...an unexpected fault while handling a driver's exception: its traceback unchained and redacted, everywhere" \
    "r9cli 1 True True []" "$(printf '%s\n' "$REVIEW" | grep '^r9cli ')"
check "review 10: every pattern linear: 80k hostile characters each under 1 s" "r10 slow:" "$(printf '%s\n' "$REVIEW" | grep '^r10 ')"

printf '\n== the day log: the second review'"'"'s findings, each with its own input ==\n'
# Second review 5: a CREATE VIRTUAL SCHEMA carries no secret of its own, yet
# its adapter can echo what the CONNECTION holds. The screen, --json and the
# log were redacted only with the failing statement's secrets.
python3 - "$STATE" <<'PYVSFAIL'
import json, sys
json.dump({"sources": {"pg.example.com": {"tables": ["ORDERS"]}},
           "vs_fail": "E-VSPG-9: the adapter could not log in with <s3cr3t-Pa55'word> as the password"}, open(sys.argv[1], "w"))
PYVSFAIL
run_secret "$SECRET" connect postgresql --name vsecho $PG_SET --secret-stdin
check "second review 5: a CREATE VIRTUAL SCHEMA failure echoing the run's credential: exit 1" "1" "$RC"
has "second review 5: ...its message is on the screen" "E-VSPG-9: the adapter could not log in with <***> as the password" "$OUT"
lacks "second review 5: ...without the credential" "s3cr3t" "$OUT"
OUT="$(printf '%s' "$SECRET" | eng --json connect postgresql --name vsecho $PG_SET --secret-stdin 2>/dev/null)"
check "second review 5: ...nor in --json's error" "[True, False]" "$(JOUT="$OUT" one '["E-VSPG-9" in d["error"], "s3cr3t" in d["error"]]')"
lacks "second review 5: ...nor in the log" "s3cr3t" "$(cat "$VSLOG")"

cat > "$WORK/vslog-review2.py" <<'PYREVIEW2'
import datetime, os, sys, time
sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import vslog, sql
base = sys.argv[2]
os.makedirs(base)
R = vslog.redact

# 1: a short secret right after an escape is still alone; inside a word it is not.
texts = ["url=jdbc%3Apostgresql%3A%2F%2Freader%3AHunter2%40host", '{"msg": "line1\\nHunter2\\nline3"}', '"a\\tHunter2"']
print("s1 leaks:%s" % "|".join(t for t in texts if "Hunter2" in R(t, ["Hunter2"])))
print("s1 kept %s %s" % ("jdbc%3Apostgresql" in R("url=jdbc%3Apostgresql%3A%2F%2Fpostgres%40h", ["postgres"]),
                         R("sales reader a", ["a"])))

# 2: the engine names the day in local Gregorian digits; an empty file a
# bridge made ready in another calendar is pruned, one with lines is kept.
print("s2 " + vslog.day_name(datetime.date(2026, 11, 9)))
today = datetime.date.today()
folder = os.path.join(base, "s2")
os.makedirs(folder)
open(os.path.join(folder, "virtual-schemas-%04d%02d%02d.log" % (today.year + 543, today.month, min(today.day, 28))), "w").close()
with open(os.path.join(folder, "virtual-schemas-%04d%02d%02d.log" % (today.year + 1, 1, 1)), "w") as handle:
    handle.write("a line\n")
vslog.RunLog(folder, "list", None).close()
print("s2 left " + " ".join(sorted(os.listdir(folder))))

# 3: user:password@ with no length cap and up to the last @.
jwt = "eyJ" + "A" * 700 + "." + "B" * 790 + "Z"
long_user = "https://" + "u" * 300 + ":Long-User-Pw9@git.example.com/x"
at_inside = "https://u:" + "p" * 1100 + "@Tail-Of-Pw8@host/x"
print("s3 leaks:%s" % "|".join(n for n, t in (("jwt", "https://oauth2:%s@git.example.com" % jwt), ("user", long_user),
                                                ("at", at_inside))
                                if any(w in R(t) for w in ("AAAA", "Long-User-Pw9", "Tail-Of-Pw8", "pppp"))))
print("s3 kept " + R("https://oauth2:%s@git.example.com" % jwt))

# 4: CamelCase names, a Python repr, Authorization; error codes and flags kept.
# Each shape with the value that must go (": tok" - the value, not the name).
shapes = [("AccessToken: abc123", "abc123"), ("SessionToken: tok", ": tok"), ("ClientSecret: s3cr3t", "s3cr3t"),
          ("DbPassword: pw1", "pw1"), ("X-Auth-Token: abc123", "abc123"),
          ("{'password': 'Hunter22', 'token': 'dapi123'}", "Hunter22"), ("{'password': 'Hunter22', 'token': 'dapi123'}", "dapi123"),
          ("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.e30.sig4", "eyJhbGci"), ("Authorization: Basic dXNlcjpwYXNzd29yZDQ=", "dXNlcjpw")]
print("s4 leaks:%s" % "|".join(s for s, v in shapes if v in R(s)))
print("s4 shown " + " ~ ".join(R(s) for s in ("AccessToken: abc123", "{'password': 'Hunter22', 'token': 'dapi123'}",
                                               "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.e30.sig4")))
readable = ["ExpiredToken: The security token included in the request is expired",
            "InvalidToken: The provided token is malformed", "NoSuchKey: The specified key does not exist.",
            "Access denied for user 'r'@'h' (using password: YES)", "(using password: NO)"]
print("s4 changed:%s" % "|".join(r for r in readable if R(r) != r))
print("s4 thrift " + R("TOpenSessionReq(username:token, password:dapiXYZ)"))
kinds = []
for message in ("Access denied for user 'r'@'h' (using password: YES)", "ExpiredToken: The security token included in the request is expired"):
    kinds.append("%s=%s" % (sql.classify(message), sql.classify(sql.redact(Exception(message), []))))
print("s4 kinds " + " ".join(kinds))

# 5: a value credential() derived, registered with the run, echoed by a
# statement that carries no secrets of its own.
class Backend(object):
    def execute(self, sql_text):
        raise Exception("E-VSS3-4: the adapter refused key [" + "Derived-" + "Key-77]")
log = vslog.RunLog(os.path.join(base, "s5"), "connect", "s5")
log.secret("Derived-" + "Key-77")
try:
    sql.Database(Backend(), log).execute("CREATE VIRTUAL SCHEMA \"VS_S5\" USING X WITH CONNECTION_NAME = 'C'")
except sql.DbError as error:
    print("s5 %s" % error)

# The new scanners stay linear (80k characters each).
slow = []
for hostile in ("a://b:" * 13000 + "@", "jdbc:oracle:thin:a/" * 4000 + "@", "https://u:" + "p@" * 40000, "Bearer " * 11000,
                "Authorization: " * 5000, "'password':" * 7000, "AccessToken: " * 6000, "a\\n" * 26000, "%3A" * 26000):
    started = time.time()
    R(hostile, ["Hunter2", "Hunter22-long-secret"])
    if time.time() - started > 1.0:
        slow.append(hostile[:12])
print("s6 slow:%s" % "|".join(slow))
PYREVIEW2
REVIEW2="$(python3 "$WORK/vslog-review2.py" "$ROOT" "$WORK/vslog-review2" 2>&1)"
check "second review 1: the short secret Hunter2 after %3A, after \\n, after \\t: redacted" "s1 leaks:" "$(printf '%s\n' "$REVIEW2" | grep '^s1 leaks')"
check "second review 1: ...and still not inside a word (postgres in jdbc%3Apostgresql, a in sales and reader)" \
    "s1 kept True sales reader ***" "$(printf '%s\n' "$REVIEW2" | grep '^s1 kept')"
check "second review 2: the engine names the day in local Gregorian digits" "s2 virtual-schemas-20261109.log" "$(printf '%s\n' "$REVIEW2" | grep '^s2 virtual')"
check "second review 2: ...an empty file dated in another calendar is pruned, a written future one kept" \
    "s2 left $(python3 -c 'import datetime as d; t=d.date.today(); print("virtual-schemas-%04d%02d%02d.log virtual-schemas-%04d0101.log" % (t.year, t.month, t.day, t.year + 1))')" \
    "$(printf '%s\n' "$REVIEW2" | grep '^s2 left')"
check "second review 3: https://oauth2:<1500-character JWT>@, a 300-character user, a password with @: redacted, no length cap" \
    "s3 leaks:" "$(printf '%s\n' "$REVIEW2" | grep '^s3 leaks')"
check "second review 3: ...the user and host kept" "s3 kept https://oauth2:***@git.example.com" "$(printf '%s\n' "$REVIEW2" | grep '^s3 kept')"
check "second review 4: AccessToken: SessionToken: ClientSecret: DbPassword: X-Auth-Token: a Python repr, Authorization Bearer and Basic" \
    "s4 leaks:" "$(printf '%s\n' "$REVIEW2" | grep '^s4 leaks')"
check "second review 4: ...the names and the scheme kept" \
    "s4 shown AccessToken: *** ~ {'password': '***', 'token': '***'} ~ Authorization: Bearer ***" "$(printf '%s\n' "$REVIEW2" | grep '^s4 shown')"
check "second review 4: ...ExpiredToken: InvalidToken: NoSuchKey: and using password: YES / NO unchanged" "s4 changed:" \
    "$(printf '%s\n' "$REVIEW2" | grep '^s4 changed')"
check "second review 4: ...a Thrift password:...) keeps its closing )" "s4 thrift TOpenSessionReq(username:token, password:***)" \
    "$(printf '%s\n' "$REVIEW2" | grep '^s4 thrift')"
check "second review 4: ...and the classes stay" "s4 kinds auth=auth auth=auth" "$(printf '%s\n' "$REVIEW2" | grep '^s4 kinds')"
check "second review 5: a derived value the run registered, echoed by a statement with no secrets of its own: redacted" \
    "s5 E-VSS3-4: the adapter refused key [***]" "$(printf '%s\n' "$REVIEW2" | grep '^s5 ')"
check "second review 3/4: the new scanners stay linear: 80k hostile characters each under 1 s" "s6 slow:" "$(printf '%s\n' "$REVIEW2" | grep '^s6 ')"

printf '\n== the engine runs isolated: python -I ==\n'
# A module planted on PYTHONPATH named like one the engine imports (argparse,
# its first) runs inside the process that holds the credential - unless the
# interpreter is isolated. The control first: without -I it runs.
PLANT="$WORK/planted"; mkdir -p "$PLANT"
printf 'import os\nopen(os.environ["EXAKIT_PLANT_MARK"], "w").write("planted")\nraise SystemExit(97)\n' > "$PLANT/argparse.py"
rm -f "$WORK/plant.mark"
PYTHONPATH="$PLANT" EXAKIT_PLANT_MARK="$WORK/plant.mark" python3 "$ROOT/setup/virtual-schemas/engine/cli.py" \
    --defs "$DEFS" --kit-home "$HOME_K" resolve pg >/dev/null 2>&1; RC=$?
check "control: without -I a planted argparse on PYTHONPATH runs in the engine" "97 yes" "$RC $([ -f "$WORK/plant.mark" ] && echo yes || echo no)"
rm -f "$WORK/plant.mark"
OUT="$( ( EXAKIT_HOME="$HOME_K"
    . "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/virtual-schemas.sh"
    pyexasol_venv_python() { command -v python3; }
    exakit_vs_defs() { printf '%s\n' "$DEFS"; }
    manifest_get() { return 1; }
    export PYTHONPATH="$PLANT" EXAKIT_PLANT_MARK="$WORK/plant.mark"
    exakit_vs_engine resolve pg ) 2>&1 )"; RC=$?
check "exakit_vs_engine: the planted module is ignored, the engine still imports its own and answers" \
    '0 RESULT {"connector": "postgresql"} no' "$RC $OUT $([ -f "$WORK/plant.mark" ] && echo yes || echo no)"
OUT="$( ( EXAKIT_HOME="$HOME_K"
    . "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/virtual-schemas.sh"
    pyexasol_venv_python() { command -v python3; }
    export PYTHONPATH="$PLANT" EXAKIT_PLANT_MARK="$WORK/plant.mark"
    printf 'k\n' | _exakit_vs_secret_text ) 2>&1 )"
check "...and the shell's credential reader is isolated too" "k no" "$OUT $([ -f "$WORK/plant.mark" ] && echo yes || echo no)"
check "every engine run goes through exakit_vs_engine: cli.py is named once, run by _exakit_vs_python (-I)" "1 1 1" \
    "$(grep -c 'engine/cli\.py"' "$ROOT/setup/lib/virtual-schemas.sh") $(grep -c '_exakit_vs_python "$_eve_py" "$_eve_defs/engine/cli.py"' "$ROOT/setup/lib/virtual-schemas.sh") $(grep -c 'exec "$_evy_bin" -I "$@"' "$ROOT/setup/lib/virtual-schemas.sh")"

# Review 3: -I does not cover PYTHONEXECUTABLE. A macOS framework build takes
# its program path from it, so sys.prefix - and the site-packages whose .pth
# files run at startup - become a planted venv's. The control first; a Python
# that ignores the variable (Linux, a non-framework build) cannot show it.
PYV="$(python3 -c 'import sys; print("python%d.%d" % sys.version_info[:2])')"
PEX="$WORK/pyexe"; mkdir -p "$PEX/bin" "$PEX/lib/$PYV/site-packages"
printf 'home = %s\n' "$(python3 -c 'import os, sys; print(os.path.dirname(os.path.realpath(sys.executable)))')" > "$PEX/pyvenv.cfg"
printf 'import os; open(os.environ["EXAKIT_PLANT_MARK"], "w").write("pth")\n' > "$PEX/lib/$PYV/site-packages/plant.pth"
rm -f "$WORK/plant.mark"
PYTHONEXECUTABLE="$PEX/bin/python" EXAKIT_PLANT_MARK="$WORK/plant.mark" python3 -I -c 'pass' 2>/dev/null
if [ -f "$WORK/plant.mark" ]; then
    pass "review 3 control: this python3 runs a planted .pth under -I through PYTHONEXECUTABLE"
    rm -f "$WORK/plant.mark"
    OUT="$( ( EXAKIT_HOME="$HOME_K"
        . "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/virtual-schemas.sh"
        pyexasol_venv_python() { command -v python3; }
        exakit_vs_defs() { printf '%s\n' "$DEFS"; }
        manifest_get() { return 1; }
        export PYTHONEXECUTABLE="$PEX/bin/python" __PYVENV_LAUNCHER__="$PEX/bin/python" EXAKIT_PLANT_MARK="$WORK/plant.mark"
        exakit_vs_engine resolve pg; printf 'k' | _exakit_vs_secret_text; printf ' %s' "$PYTHONEXECUTABLE" ) 2>&1 )"; RC=$?
    check "review 3: the engine and the credential reader run without it: no .pth ran, both answered, the caller keeps it" \
        "0 RESULT {\"connector\": \"postgresql\"} k $PEX/bin/python no" "$RC $(printf '%s' "$OUT" | tr '\n' ' ' | sed 's/  */ /g') $([ -f "$WORK/plant.mark" ] && echo yes || echo no)"
else
    pass "review 3: this python3 ignores PYTHONEXECUTABLE under -I (not a macOS framework build): nothing to show here"
fi

# Review 4: the credential reader runs on the kit's pyexasol only. Without it,
# that is what the command says - never "standard input was empty".
OUT="$( ( EXAKIT_HOME="$HOME_K"
    . "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/virtual-schemas.sh"
    _require_install() { :; }; exakit_init_logging() { EXAKIT_LOG_FILE="$WORK/json.log"; }
    pyexasol_venv_python() { printf '%s\n' "$WORK/no-such-venv/bin/python"; }
    exakit_vs_engine() { echo "ENGINE RAN" >&2; return 0; }
    printf 'pw' | cmd_connect pg --name nopy --password-stdin --json ) 2>/dev/null )"; RC=$?
check "review 4: no kit Python to read the credential: exit 2, one object, kind setup, the repair named" \
    "2 ['setup', \"the credential is read with the kit's pyexasol, which did not run\", 'exakit update pyexasol']" \
    "$RC $(JOUT="$OUT" one '[d["kind"], d["error"], d["command"]]')"
_reader_range='/^_exakit_vs_secret_text()/,/^}/p'
check "...and the reader never falls back to another Python (no run_python_any)" "0" \
    "$(sed -n "$_reader_range" "$ROOT/setup/lib/virtual-schemas.sh" | grep -c run_python_any)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
