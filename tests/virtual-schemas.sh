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
]:
    print(sql.classify(text))
PYC
)"
check "each real message lands in its class" "unreachable|unreachable|unreachable|unreachable|auth|auth|tls|nojava|dns|" \
    "$(printf '%s\n' "$CLASSES" | tr '\n' '|')"
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
check "every connector names the rights it needs at the source, and the denied fix says them" "ok" \
    "$(python3 - "$ROOT" <<'PYC'
import json, os, sys
sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import lifecycle
root = os.path.join(sys.argv[1], "setup", "virtual-schemas")
for entry in json.load(open(os.path.join(root, "catalog.json")))["connectors"]:
    doc = json.load(open(os.path.join(root, "connectors", entry["id"], "connector.json")))
    access = doc.get("access", "").strip()
    if not access or "(%s)" % access not in lifecycle.remedy_for("denied", "src", doc):
        print("bad: " + entry["id"]); break
else:
    print("ok")
PYC
)"
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
      exakit_vs_engine() {
          printf '%s\n' "$*" >> "$B/argv"
          [ -t 0 ] || cat >> "$B/stdin"
          _n="$(wc -l < "$B/argv" | tr -d ' ')"
          _code="$(sed -n "${_n}p" "$B/codes" 2>/dev/null)"
          if [ "$1" = resolve ] && [ -f "$B/gated" ]; then echo "FAIL BigQuery is not available yet: gated"; return 5; fi
          case "$1" in check) echo 'RESULT {"checks": []}' ;; remove|disconnect) echo 'RESULT {"name": "sales", "drop": ["virtual schema VS_SALES", "CONNECTION EXAKIT_SRC_SALES"], "keep": [], "delete_files": ["a.jar"], "keep_files": ["b.jar"], "note": "nothing is revoked at the source"}' ;; show) echo "FAIL no source named $2 (see: exakit source list)" ;; resolve) echo 'RESULT {"connector": "postgresql"}' ;; plan) echo 'RESULT {"name": "x", "connector": "postgresql", "tier": "GA", "status": "candidate", "downloads": [], "steps": [], "exposure": "e", "warnings": []}' ;; esac
          return "${_code:-0}"
      }
      personal_slc_dns_repair() { echo "REPAIRED" >> "$B/argv"; return 0; }
      _exakit_vs_install_java() { echo "JAVA-ASKED" >> "$B/argv"; return 1; }
      "$@" ) 2>&1
}
reset_bridge() { rm -f "$B/argv" "$B/stdin" "$B/codes"; printf '%s\n' "$@" > "$B/codes"; }

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
reset_bridge 0 0 21
OUT="$(bridge cmd_connect pg --name sales --set host=h --password-file "$B/pw" </dev/null)"; RC=$?
check "exit 21: the Java install is offered; declined, nothing retried" "21 1" "$RC $(grep -c '^connect' "$B/argv")"
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
has "...Beta, a candidate" '"tier": "Beta", "status": "candidate"' "$OUT"
has "...says it is untested live" "not been run against a live Iceberg REST catalog" "$OUT"
has "...states the MCP exposure" "MCP read-only user can read every table of VS_REST1" "$OUT"
has "...the scripts shared with every lakehouse engine source" "shared by every lakehouse engine source (AWS Glue, Iceberg REST or Unity Catalog)" "$OUT"
PLAN_IR="$(printf '%s\n' "$OUT" | sed -n 's/^RESULT //p' | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["downloads"]))')"
run plan unity --name uc $UC_SET
check "plan unity: exit 0" "0" "$RC"
has "...says it is untested live" "not been run against a live Unity Catalog" "$OUT"
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
    TUI_OUT="$(TTY_REPLAY_COLS="${TUI_COLS:-100}" python3 "$ROOT/tests/lib/tty-replay.py" "$ROOT/tests/lib/$1" "$ROOT" "$2" "$4" "$3" 2>&1)"
    TUI_RC=$?
    TUI_SCREEN="$(printf '%s\n' "$TUI_OUT" | sed -n '/=== FINAL SCREEN ===/,/=== tables on screen/p')"
}
if command -v python3 >/dev/null 2>&1; then
    db '{"sources": {"pg.example.com": {"tables": ["ORDERS", "CUSTOMERS"]}}}'
    # Space ticks PostgreSQL - the cursor starts on the first connector, there
    # is no "Select All" above it - then one wrong answer, corrected. The public
    # IP lookup is on (a file:// URL): the review says the address.
    EXAKIT_NO_IP_LOOKUP= EXAKIT_PUBLIC_IP_URL="$IPURL" tui connect-tui-scenario.sh "1 of 1 · PostgreSQL" 3 \
        " \rtuione\rlocalhost\rpg.example.com\r\rsales\r\rreader\r$TUI_SECRET\r\r\ry\r"
    check "one menu, one panel and one table are left on screen, never stacked" "0" "$TUI_RC"
    has "...the review names this computer's public IP for a source on the internet" \
        "tuione: This computer's public IP is 203.0.113.7" "$TUI_SCREEN"
    has "...the menu offers the connectors" "├─ PostgreSQL" "$TUI_SCREEN"
    has "...with the adapter version each one pins" "4.1.0" "$TUI_SCREEN"
    has "...and its release" "GA" "$TUI_SCREEN"
    has "...under the three column heads" "Version" "$TUI_SCREEN"
    lacks "...no Kind column any more" "REST + JDBC" "$TUI_SCREEN"
    has "...the panel shows every answer" "Host name or address      pg.example.com" "$TUI_SCREEN"
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
        " j \rtuitwo\rpg.example.com\r\rsales\r\rreader\rpw\r\r\rtuimy\rmy.example.com\r\rshop\rreader\rpw\r\r\ry\r"
    check "two sources: still one table" "0" "$TUI_RC"
    has "...the one that worked" "✓ VS_TUITWO · 1 table" "$TUI_SCREEN"
    has "...the one that did not, in a few words" "✗ the source did not answer" "$TUI_SCREEN"
    has "...and in the engine's words below the table" "tuimy did not connect:" "$TUI_SCREEN"
    check "...nothing kept for the failed one" "no" "$([ -d "$HOME_K/sources/tuimy" ] && echo yes || echo no)"

    # Java missing: the row says so, the question comes once below the table, and
    # an Enter pressed while the table ran does not answer it.
    python3 - "$STATE" <<'PY'
import json, sys; d = json.load(open(sys.argv[1])); d["java"] = False; json.dump(d, open(sys.argv[1], "w"))
PY
    TUI_FAKE_JAVA_INSTALL=1 tui connect-tui-scenario.sh "Connect again" 4 \
        " \rtuijava\rpg.example.com\r\rsales\r\rreader\rpw\r\r\ry\r\r\x01\x01\x01y\r"
    check "a missing Java container: one question, then a table of its own" "0" "$TUI_RC"
    has "...the first table says what is missing" "✗ needs Java in the database" "$TUI_SCREEN"
    has "...the answer was the one typed after the question" "Java language container installed" "$TUI_SCREEN"
    has "...and the source connects" "✓ VS_TUIJAVA · 1 table" "$TUI_SCREEN"

    # The command line names the connector and some answers: no menu, those
    # answers ticked, only the rest asked.
    printf '%s' "$TUI_SECRET" > "$WORK/tui.pw"
    TUI_ARGS="pg --name tuiargs --set host=pg.example.com --set database=sales --set user=reader --password-file $WORK/tui.pw" \
        tui connect-tui-scenario.sh "1 of 1 · PostgreSQL" 2 "\r\r\r\ry\r"
    check "a named connector skips the menu" "0" "$TUI_RC"
    lacks "...no menu" "Connect external sources" "$TUI_SCREEN"
    has "...the given credential file is used, not asked for" "(read from a file)" "$TUI_SCREEN"
    has "...and it connects" "✓ VS_TUIARGS · 1 table" "$TUI_SCREEN"

    # Skip closes the menu with nothing done.
    # Skip sits below every connector of the catalog (GA and Beta); the cursor
    # steps over a gated one.
    _skip_keys="$(python3 -c 'import json,sys; print("j" * sum(1 for e in json.load(open(sys.argv[1]))["connectors"] if e.get("status") != "gated"))' "$DEFS/catalog.json")"
    tui connect-tui-scenario.sh "Connect external sources" 1 "$_skip_keys \r"
    has "Skip: nothing chosen, nothing changed" "Nothing was chosen; nothing was changed." "$TUI_SCREEN"

    if command -v pwsh >/dev/null 2>&1; then
        # The PowerShell twin, under the same terminal model. pwsh starts slower,
        # hence the pauses (\x01) before the first key.
        EXAKIT_NO_IP_LOOKUP= EXAKIT_PUBLIC_IP_URL="$IPURL" tui connect-tui-scenario-ps.sh "1 of 1 · PostgreSQL" 3 \
            "\x01\x01\x01 \rtuips\rlocalhost\rpg.example.com\r\rsales\r\rreader\r$TUI_SECRET\r\r\ry\r"
        check "PowerShell: one menu, one panel, one table" "0" "$TUI_RC"
        has "...its review names this computer's public IP too" "tuips: This computer's public IP is 203.0.113.7" "$TUI_SCREEN"
        has "...and the row ends with the schema" "✓ VS_TUIPS · 1 table" "$TUI_SCREEN"
        lacks "...the credential is not on the screen" "$TUI_SECRET" "$TUI_OUT"
        check "...it reached the CONNECTION" "$TUI_SECRET" "$(dbq 'd["connections"]["EXAKIT_SRC_TUIPS"]["secret"]')"
    else
        pass "PowerShell terminal flow: skipped (no pwsh)"
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
    tui connect-tui-scenario.sh "1 of 1 · PostgreSQL" 2 "\r\r\r\ry\r"
check "the terminal flow with --url: one panel, one table" "0" "$TUI_RC"
has "...the panel holds the string's host" "Host name or address      pg.example.com" "$TUI_SCREEN"
has "...and it connects" "✓ VS_TUIURL · 1 table" "$TUI_SCREEN"
has "PowerShell parses --url too" '$arg -eq "--url"' "$(cat "$ROOT/setup/exakit.ps1")"

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
check "...and public_ip is null" "None" "$(printf '%s\n' "$OUT" | sed -n '/^{/,$p' | pubip)"
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

printf '\n== exakit source --json: one object of the same shape ==\n'
jsonsrc() { # jsonsrc <stdin-file> <args...> - cmd_source; stdout in JOUT, stderr in JERR, exit in JRC
    _js_in="$1"; shift
    JOUT="$( ( EXAKIT_HOME="$HOME_K"
      . "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/virtual-schemas.sh"
      _require_install() { :; }; exakit_init_logging() { EXAKIT_LOG_FILE="$WORK/json.log"; }
      exakit_vs_engine() { printf '%s\n' "$*" >> "$WORK/json.argv"; eng "$@"; }
      cmd_source "$@" ) < "$_js_in" 2> "$WORK/json.err" )"; JRC=$?
    JERR="$(cat "$WORK/json.err")"
}
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
jsonsrc /dev/null --json
check "source --json (no action): exit 0, the listing's one object" "0 True" "$JRC $(one 'd["ok"]')"
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
