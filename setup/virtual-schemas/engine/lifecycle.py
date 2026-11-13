"""Connect, check, reauth, refresh, disconnect and remove one named source.

Every operation takes the sources lock, journals its steps, and on failure
undoes only what THIS attempt created - never an object it did not make, never
a file another source still uses. A multi-step setup is not one transaction,
and nothing here pretends it is: an interrupted run leaves a journal the next
run reports, and its objects carry the kit's names so it can finish or clean up.

Object names for a source <name>:
    CONNECTION       EXAKIT_SRC_<NAME>      the credential, readable only through SQL privileges
    virtual schema   VS_<NAME>              the tables a user queries
    adapter script   EXAKIT_VS.ADAPTER_<NAME>
A document-files source (profile B) also has a mapping staged in the kit's
bucket folder under mappings/<name>/, and shares its connector's import script
(EXAKIT_VS.<import_script>, a name the adapter fixes) with the other sources of
that connector; the last of them out drops it.
The EXAKIT_VS schema, made before the first script goes into it, also holds the
DNS probe, and is dropped with the last source.
"""

import hashlib
import os
import re
import shlex
import time

import artifacts
import document
import edml_draft
import plan as planner
import sources
import sql
import tlsca
import keyfile
import luaadapter
import publicip
import tlshelper
import vslog

PROBE = "EXAKIT_DNS_PROBE_V2"
FILES = "EXAKIT_FILES_PROBE_V1"
# A file written to the bucket on this computer reaches the database a moment
# later (measured on Exasol Personal 2.3.0, whose runtime is a VM reading the
# folder over a VirtioFS share): a jar staged and loaded within the same
# second failed with "Java VM cannot find <jar>", the same jar loaded a second
# later. The Java probe is asked until it sees every staged file, for at most
# VISIBLE_TIMEOUT seconds; a native adapter, with no Java to ask, is given
# SETTLE seconds. Both are read from the environment for the test suite only.
VISIBLE_TIMEOUT = float(os.environ.get("EXAKIT_VS_VISIBLE_TIMEOUT", "20"))
SETTLE = float(os.environ.get("EXAKIT_VS_SETTLE_SECONDS", "2"))

# Inputs a re-point does not change in place (Engine.repoint): a mapping is
# staged per source, and a CA is chosen and staged by the connect that trusted
# it. Neither file is read again when it is not given.
REPOINT_FIXED_KINDS = ("edml", "ca-file")

EXIT = {"ok": 0, "failed": 1, "input": 2, "conflict": 3, "missing": 4, "gated": 5,
        "dns": 20, "nojava": 21, "unreachable_db": 22, "norust": 23}

# A Java the database cannot run, in the kit's words (sql.NOJAVA has the database's).
JAVA_MISSING = "Java is not installed in the database (its language container is missing)"

# Status recorded for a failure kind (sql.classify).
STATUS_FOR = {"auth": "auth-failed", "tls": "tls-failed", "unreachable": "unreachable", "nohost": "unreachable",
              "dns": "dns-failed", "nojava": "failed", "error": "failed", "denied": "access-denied",
              "region": "failed", "nobucket": "failed", "clock": "failed", "norust": "failed",
              "schema_missing": "failed", "external": "access-denied", "managed": "failed",
              "privilege": "access-denied", "missing_or_denied": "failed", "sandbox": "failed",
              "catalog": "failed"}

REMEDY_FOR = {
    "auth": "the source rejected the credentials: exakit source reauth {name}",
    "tls": "the source's certificate or host name did not verify; fix the server certificate or trust its CA, then: exakit source check {name}",
    "unreachable": "the source did not answer from inside the database: check the host, port, firewall and VPN (a source on this computer must listen beyond 127.0.0.1), then: exakit source check {name}",
    "nohost": "the host name no longer resolves: check it (a private name may need a VPN), then: exakit source check {name}",
    "dns": "Java in the database could not resolve the host name; restart the database - exakit stop, then exakit start (the start gives Java the deployment's DNS) - then: exakit source check {name}",
    "nojava": "exakit connect installs the Java language container with one database restart - asked on a terminal, --yes for a script - or run: exasol slc install java",
    "norust": "exakit connect installs the Rust language container with one database restart - asked on a terminal, --yes for a script",
    "unreachable_db": "the local database did not answer: start it (exakit start), then try again",
    "denied": "the account signs in but may not read this data: grant it what the message names ({access}), then: exakit source check {name}",
    "privilege": "the source took the credentials, but the account lacks a privilege: grant it what the message names ({access}), then: exakit source check {name}",
    "missing_or_denied": "the source answers that the object the message names does not exist for this account - it was dropped or renamed (then: exakit source refresh {name}), or the account may not see it (grant it {access}); then: exakit source check {name}",
    "region": "the bucket is in another region: exakit source disconnect {name} --yes, then exakit connect <connector> --name {name} --set region=<the bucket's region> with the credential again",
    "nobucket": "the {store} does not exist under that name: check it, then remove and connect again",
    "clock": "the database clock is too far from the store's for a signed request; restart the database (exakit stop, then exakit start), then: exakit source check {name}",
    "schema_missing": "the schema the source was connected with is gone or no longer visible to the account; check it at the source, then: exakit source check {name}",
    "external": "Unity Catalog does not let engines outside Databricks read this schema's files: the metastore needs External Data Access switched on and the token's user EXTERNAL USE SCHEMA on the schema (a schema on Databricks Default Storage can never be read from outside) - or read it through the SQL warehouse: exakit connect databricks; then: exakit source check {name}",
    "managed": "a table here is a Databricks catalog-managed table, which this adapter version cannot read yet; read it through the SQL warehouse instead: exakit connect databricks",
    "sandbox": "the database's Java sandbox stopped the driver before it reached the source (it tried a file or a connection the sandbox does not allow) - not the network or the credentials; update the kit (exakit update), or connect with tls=verify and --set ca=<PEM file>, then: exakit source check {name}",
    "catalog": "the catalog does not know warehouse {warehouse} - give the catalog's name (e.g. exakit_uc for Databricks), then: exakit source check {name}",
    "error": "see the log: exakit logs",
}

def shell_word(text):
    """text as one word of the shell the command is typed in: POSIX quoting,
    or PowerShell's when the Windows bridge says so (EXAKIT_VS_QUOTE) - for
    a command an answer names, to be run as it stands."""
    if os.environ.get("EXAKIT_VS_QUOTE") == "powershell":
        return text if re.match(r"^[A-Za-z0-9_+=:./-]+$", text) else "'%s'" % text.replace("'", "''")
    return shlex.quote(text)


def remedy_text(kind, table=None):
    """The fix for a kind as a template, from table (REMEDY_FOR by default).
    Java without DNS has one fix on every engine, a stop and a start: Podman
    and macOS repair the running container after the start, and on Docker the
    start links the language container image before it mounts it (read-only;
    setup/lib/personal-slc-dns.py)."""
    table = REMEDY_FOR if table is None else table
    return table.get(kind, table["error"])


# The one exakit command that IS the fix, for the kinds that have one (--json
# carries it as `command`, null for the rest). A first connect has no source
# yet, so the lifecycle commands do not apply to it (connect passes first=True).
COMMAND_FOR = {"auth": "exakit source reauth {name}", "unreachable_db": "exakit start"}


def command_for(kind, name, first=False):
    if first and kind != "unreachable_db":
        return None
    text = COMMAND_FOR.get(kind)
    return text.format(name=name) if text else None



def tls_fix(connector):
    """What fixes a TLS failure for this connector: the CA where it takes one,
    tls=require only where it has that level (Oracle has none)."""
    choices = next((spec.get("choices", []) for spec in connector["inputs"] if spec["name"] == "tls"), [])
    fix = "fix the server certificate"
    if any(spec["kind"] == "ca-file" for spec in connector["inputs"]):
        fix += " or give the CA that signs it with --set ca=<PEM file or bundle>"
    if "require" in choices:
        fix += " (tls=require encrypts without checking it - only knowingly)"
    return fix


def catalog_warehouse(message):
    """The warehouse a catalog-config failure names, quoted, or "it was given"."""
    m = re.search(r"catalog config for warehouse '([^']*)'", str(message or ""))
    return "'%s'" % m.group(1) if m else "it was given"


def no_region_bucket(message):
    """For an S3 request made with no region (sql.NOREGION), the bucket it
    was for, quoted - or "" when the message is not one."""
    text = str(message or "")
    if not re.search(sql.NOREGION, text, re.I):
        return ""
    m = re.search(r"s3\.\.amazonaws\.com/([a-z0-9][a-z0-9.-]{1,61}[a-z0-9])/", text, re.I) \
        or re.search(r"//([a-z0-9][a-z0-9.-]{1,61}[a-z0-9])\.s3\.\.amazonaws\.com", text, re.I) \
        or re.search(r"s3://([a-z0-9][a-z0-9.-]{1,61}[a-z0-9])/", text, re.I)
    return "'%s'" % m.group(1) if m else "the bucket"


def find_region(bucket):
    """Where the bucket's region is found, for a fix that asks for it."""
    named = bucket.strip("'") if bucket.startswith("'") else "<bucket>"
    return ("the bucket is in the s3:// URL of the table's storage (for Unity Catalog: the external location, "
            "Catalog > External data > External locations); its region is under S3 > the bucket > Properties "
            "in the AWS console, or: aws s3api get-bucket-location --bucket %s (null means us-east-1)" % named)


def no_region_remedy(message, name, first, connector_id="lakehouse"):
    """The fix for vended S3 credentials used with no region given."""
    bucket = no_region_bucket(message)
    said = "the catalog vended S3 credentials but no region was given, so %s could not be reached" % bucket
    if first:
        return "%s; nothing was kept - connect again with --set region=<the bucket's region>: %s" \
            % (said, find_region(bucket))
    return ("%s: exakit source disconnect %s --yes, then exakit connect %s --name %s "
            "--set region=<the bucket's region> with the credential again; %s"
            % (said, name, connector_id, name, find_region(bucket)))


# An object store refusing the key it was given (S3: a wrong secret, an
# unknown key id; Azure: a wrong key or SAS) - against a catalog's login.
STORAGE_REFUSED = (r"SignatureDoesNotMatch|signature we calculated does not match|InvalidAccessKeyId|"
                   r"Access Key Id you provided does not exist|AuthenticationFailed|"
                   r"Server failed to authenticate the request")


def refused_secret(connector, message):
    """For a lakehouse source's auth failure, the secret its words name and
    the flag that gives it: (who, label, "--storage-secret-file", other) when
    the store refused its key and the combination has a storage secret of
    its own, else (who, label, "--password-file", other) for the one secret
    on --password-file (the catalog's login; with no catalog or with Glue,
    the storage key too). other is the second secret's (label, flag) of a
    two-secret combination, since a reauth writes both. None for any other connector, or when the
    combination is not known (the whole document, not one combination)."""
    if connector.get("auth") != "lakehouse" or connector.get("settings"):
        return None
    main = next((s for s in connector.get("inputs", []) if s["name"] == "secret"), None)
    storage = planner.storage_secret_input(connector)
    if main is None:
        return None
    if re.search(STORAGE_REFUSED, str(message or ""), re.I):
        if storage:
            return "store", plain_label(storage["label"]), "--storage-secret-file", \
                (plain_label(main["label"]), "--password-file")
        if main.get("role") in ("storage", "aws"):
            return ("store" if main["role"] == "storage" else "AWS"), plain_label(main["label"]), "--password-file", None
        return None
    return ("AWS" if main.get("role") == "aws" else "catalog"), plain_label(main["label"]), "--password-file", \
        (plain_label(storage["label"]), "--storage-secret-file") if storage else None


def plain_label(label):
    """An input's label inside a sentence: 'secret access key', 'Databricks token'."""
    return label if label.split(" ", 1)[0] in ("Databricks", "SAS") else label[:1].lower() + label[1:]


def refused_words(refused):
    """'the store refused the secret access key', or the catalog's login."""
    return "%s refused the %s" % (refused[0] if refused[0] == "AWS" else "the " + refused[0], refused[1])


def remedy_for(kind, name, connector, message=None):
    """The fix for a failure class, in the words of the connector's store.
    An error_hint given as {"match", "text"} is said only for a message it
    matches; a plain string, for every unclassified failure."""
    if kind == "region" and no_region_bucket(message):
        return no_region_remedy(message, name, first=False, connector_id=connector.get("id", "lakehouse"))
    text = remedy_text(kind).format(
        name=name, access=connector.get("access", "read access"), store=connector.get("store", "bucket"),
        warehouse=catalog_warehouse(message))
    refused = refused_secret(connector, message) if kind == "auth" else None
    if refused:
        args = {refused[2]: "<file with the right %s>" % refused[1]}
        if refused[3]:
            args[refused[3][1]] = "<%s file>" % refused[3][0]
        text = "%s: exakit source reauth %s %s%s" % (
            refused_words(refused), name,
            " ".join("%s %s" % (flag, args[flag]) for flag in ("--password-file", "--storage-secret-file") if flag in args),
            " (a reauth writes both)" if refused[3] else "")
    elif kind == "auth" and connector.get("auth_hint"):
        text += "; %s" % connector["auth_hint"]
    hint = connector.get("error_hint")
    if isinstance(hint, dict):
        hint = hint["text"] if re.search(hint["match"], str(message or "")) else None
    if kind == "error" and hint:
        text = "%s; %s" % (hint, text)
    return text


# Failures an address filter in front of the source causes: no answer at all (a
# security group or firewall drops the connection), or a refusal - an S3 bucket
# policy on aws:SourceIp or an Azure storage firewall answers 403, read as
# denied. Their remedy names this computer's public IP: the address the source
# sees, since the database's traffic leaves through this computer. Not
# "privilege" or "missing_or_denied": a database answers those to a statement,
# after the address was let through and the credentials taken.
ADDRESS_KINDS = ("unreachable", "denied")
LISTEN_ADVICE = "(a source on this computer must listen beyond 127.0.0.1)"


def allow_ip(remedy, kind, ip):
    """The remedy, naming the public IP to allow; unchanged without one. For a
    source on the internet the address replaces the advice for one on this
    computer."""
    if not ip or kind not in ADDRESS_KINDS:
        return remedy
    clause = "allow this computer's public IP %s in its security group, firewall or IP access list" % ip
    if LISTEN_ADVICE in remedy:
        return remedy.replace(LISTEN_ADVICE, "(%s)" % clause)
    head, sep, tail = remedy.rpartition(", then")
    if not sep:
        return "%s; if it filters by address, %s" % (remedy, clause)
    return "%s and, if it filters by address, %s%s%s" % (head, clause, sep, tail)

# Seconds the database clock may be off this computer's before it is named.
# Measured on Exasol Personal (macOS): the VM's clock does not catch up after
# the Mac sleeps - 2 h 26 min, 1 h 25 min and 32 min behind on one laptop - and
# an RDS certificate issued that morning then failed as not yet valid.
CLOCK_LIMIT = 120
# How far off a signed request may be before S3 and Azure refuse it.
SIGNED_LIMIT = 15 * 60


def clock_words(seconds):
    """'33 min behind', '1 h 25 min ahead of' - twin of exakit_clock_skew_words."""
    direction = "behind" if seconds < 0 else "ahead of"
    minutes = (abs(int(seconds)) + 30) // 60
    if minutes >= 60:
        return "%d h %d min %s" % (minutes // 60, minutes % 60, direction)
    return "%d min %s" % (minutes, direction)


def tls_remedy(message, connector, clock=None):
    """The specific fix for a TLS failure, when the driver's words say which
    one it is; None leaves the general remedy. Both cases were measured live
    against RDS: the CA a JVM does not hold, and a database clock left behind
    by a laptop that hibernated. clock is the measured skew in words when it
    is past CLOCK_LIMIT, so a validity failure names the cause, not a guess."""
    text = str(message)
    has_ca = any(spec["kind"] == "ca-file" for spec in connector["inputs"])
    has_tls = any(spec["name"] == "tls" for spec in connector["inputs"])
    if re.search(r"trustAnchors parameter must be non-empty|Could not load trustJKS keystore", text, re.I):
        # Measured on Exasol Personal 2.3.0: the JDBC loader runs the language
        # container's Java outside it, and that Java's cacerts is an absolute
        # symlink into the container's /etc - so the loader trusts nothing.
        # MySQL's Connector/J says it as "Could not load trustJKS keystore
        # from null" (measured on 2.4).
        return ("the database's JDBC loader has no CA store of its own (an Exasol Personal issue), so it cannot "
                "verify any certificate without one given to it" +
                ("; give the CA as PEM with --set ca=<file> - for a public CA too, its root certificate"
                 if has_ca else "; this connector cannot take a CA yet - tls=require encrypts without verifying, "
                 "only if the user accepts that" if has_tls else
                 "; this connector always verifies and its driver reads trust only from that store, so it cannot "
                 "connect on this database until the loader has one"))
    if re.search(r"validity check failed|NotYetValid|not yet valid|CertificateExpired|has expired", text, re.I):
        if clock:
            return ("the database clock is %s this computer, so the certificate is outside its validity dates "
                    "by it - restart the database (exakit stop, then exakit start) and retry" % clock)
        return ("a certificate is outside its validity dates by the database's clock; if this computer slept or "
                "hibernated, the database clock may be behind - restart it (exakit stop, then exakit start) and retry")
    if (re.search(r"PKIX path building failed|unable to find valid certification path|"
                  r"Path does not chain with any of the trust anchors", text, re.I) and has_ca):
        return ("the database does not trust the certificate authority that signed the source's certificate - "
                "managed databases (AWS RDS, Azure) and company servers use their own; download that CA as PEM "
                "and give it with --set ca=<file>")
    return None


def tips(connector, name, schema):
    """What a reader needs to query this kind of source: how its names arrive
    and which types change on the way (connector.json "tips", each measured
    on a live source)."""
    return [t.replace("<schema>", schema).replace("<name>", name) for t in connector.get("tips", [])]


def table_ddl(schema, table, columns, into=""):
    """One virtual table as an Exasol CREATE TABLE, every name quoted (a
    MongoDB field carries '|' and mixed case), and a commented line that
    copies the rows into it. Without into it targets the session's schema."""
    target = "%s.%s" % (sql.ident(into), sql.ident(table)) if into else sql.ident(table)
    lines = ",\n".join("    %s %s%s" % (sql.ident(c["name"]), c["type"], "" if c["nullable"] else " NOT NULL")
                        for c in columns)
    copy_to = target if into else "<schema>.%s" % sql.ident(table)
    return ("-- %s.%s as Exasol sees it\nCREATE TABLE %s (\n%s\n);\n-- a local copy: INSERT INTO %s SELECT * FROM %s.%s;\n"
            % (schema, sql.ident(table), target, lines, copy_to, schema, sql.ident(table)))


def example_query(schema, tables):
    """A first query on a real table, its name quoted when Exasol would
    otherwise upper-case it: SELECT * FROM VS_X."actor" LIMIT 10."""
    if not tables:
        return "SELECT * FROM %s.<table> LIMIT 10" % schema
    table = sorted(tables)[0]
    shown = table if re.match(r"^[A-Z][A-Z0-9_]*$", table) else sql.ident(table)
    return "SELECT * FROM %s.%s LIMIT 10" % (schema, shown)


def source_where(connector, values):
    """Where a source lives, for its listing: the host it is reached at (a cloud
    store's names its bucket, account or workspace), or the connector's "where"
    when every source of its kind shares one API host (BigQuery: the project).
    The host input as given when the connector's definition is gone."""
    if not connector:
        return str(values.get("host") or "")
    if connector.get("where"):
        try:
            return connector["where"].format(**values)
        except KeyError:
            return ""
    hosts = planner.reached_hosts(connector, values)
    return hosts[0] if hosts else ""


# MongoDB URI options that keep TLS on but stop the certificate or host check.
MONGO_UNCHECKED = ("tlsinsecure", "tlsallowinvalidcertificates", "tlsallowinvalidhostnames")


def tls_level(connector, values):
    """A source's TLS in the tls input's words: verify, require or disable; None
    when the connector's definition is gone. A connector without that input:
    a MongoDB URI says it (mongodb+srv:// is TLS unless tls=false, and
    tlsInsecure and its kin encrypt without checking), an http:// URL input is
    disable, and every other one reaches its source over HTTPS or TLS only,
    the certificate checked."""
    if not connector:
        return None
    for spec in connector.get("inputs", []):
        if spec["name"] == "tls":
            return values.get("tls") or spec.get("default") or "verify"
    for spec in connector.get("inputs", []):
        if spec["kind"] != "mongodb-uri":
            continue
        uri = str(values.get(spec["name"]) or "")
        options = {}
        for segment in uri.partition("?")[2].split("&"):
            key, _, value = segment.partition("=")
            options[key.strip().lower()] = value.strip().lower()
        on = uri.lower().startswith("mongodb+srv://")
        for key in ("ssl", "tls"):  # tls, the current spelling, wins
            if key in options:
                on = options[key] == "true"
        if not on:
            return "disable"
        return "require" if any(options.get(key) == "true" for key in MONGO_UNCHECKED) else "verify"
    return "disable" if planner.plain_http(connector, values) else "verify"


def in_use_words(users):
    """Why a shared object stays: the virtual schemas still on it, or that
    the database could not say."""
    if users is None:
        return "the database could not list its virtual schemas, so it may still be in use"
    shown = ", ".join(users[:5]) + (" and %d more" % (len(users) - 5) if len(users) > 5 else "")
    return "virtual schema%s %s still use%s it" % ("" if len(users) == 1 else "s", shown,
                                                   "s" if len(users) == 1 else "")


class Failure(Exception):
    """A failure the engine names. str() is what happened; kind is its class;
    remedy the fix in words and command the one exakit command that is the
    fix, when there is one (--json carries all four). said is what a person
    reads on the FAIL line: the message, or the message and its fix in one
    sentence, as the kit has always said them."""
    def __init__(self, message, code, kind="error", remedy=None, command=None, said=None):
        super().__init__(message)
        self.code = code
        self.kind = kind
        self.remedy = remedy
        self.command = command
        self.said = said or message


class ScopeFailure(Failure):
    """The schema check's own answer: what the source has, and the fix, so
    connect adds only that nothing was kept."""
    def __init__(self, message, kind, remedy):
        super().__init__(message, EXIT["failed"], kind, remedy=remedy, said="%s; %s" % (message, remedy))


def draft_into(connector, values, secret, folder):
    """edml_draft.draft for a connector's inputs and credential, its failure a
    Failure (kind draft) that says to give a mapping instead."""
    prefix = planner.draft_prefix(connector, values) or ""
    try:
        return edml_draft.draft(edml_draft.store_for(connector["id"], values, secret), folder, prefix)
    except (edml_draft.DraftError, document.DocumentError) as error:
        remedy = "give a mapping path instead (--set mapping=<folder>)"
        if "(s3:ListBucket)" in str(error) and not prefix:
            # A key limited to a prefix, as the kit advises, may list only that folder.
            remedy += ", or the bucket folder the key may list (--set mapping=auto:<folder>/, e.g. auto:data/)"
        if re.search(r"\((s3:\w+|it needs \w+ \(\w\))\)", str(error)):
            remedy += ", or add that right"
        message = "the mapping could not be drafted: %s" % error
        raise Failure(message, EXIT["input"], "draft", remedy=remedy, said="%s - %s" % (message, remedy))


class Engine(object):
    def __init__(self, args, emit, log=None):
        self.args = args
        self.emit = emit
        # The run's log (vslog): the session writes every statement to it.
        self.log = log if log is not None else vslog.NULL
        self.defs = planner.Definitions(args.defs)
        self.store = sources.Store(args.kit_home)
        self.cache = artifacts.Cache(args.kit_home, log=lambda text: emit("INFO", text))
        self.profile = self.defs.profile("java-jdbc")
        # Every profile stages into the same bucket folder (profile.json).
        self.runtime = artifacts.Runtime(args.deployment_dir or "", self.profile["bucket"])
        self._db = None
        # The second secret of a lakehouse combination with two (a catalog
        # login and storage keys): set by cli.py from --secret-pair-base64,
        # never from an argument. None when the command carried one secret.
        self.storage_secret = None

    # --- the database --------------------------------------------------------------
    def clock(self):
        """The database clock's skew from this computer's, in words, when it is
        past CLOCK_LIMIT; else None. Measured once per run with POSIX_TIME()
        (the epoch in any session time zone); None too when it cannot be."""
        if not hasattr(self, "_clock"):
            self._clock = None
            try:
                before = time.time()
                rows = self.db().query("SELECT POSIX_TIME() AS T")
                skew = float(rows[0]["T"]) - (before + time.time()) / 2
                self._skew = skew
                if abs(skew) >= CLOCK_LIMIT:
                    self._clock = clock_words(skew)
            except (Failure, sql.DbError, LookupError, TypeError, ValueError):
                pass
        return self._clock

    def signed_kind(self, kind, connector):
        """A store that signs each request with the time (S3, Glue, Azure
        with a key or SAS) refuses one more than 15 minutes off its own clock.
        It does not always say so: the lakehouse engine reports the S3 refusal
        as "PermissionDenied ... status: 403" (measured, a database 42 min
        behind after the laptop slept), which reads like a missing grant.
        With the clock that far off, the clock is the cause to name."""
        if kind not in ("error", "denied", "auth") or connector.get("auth") not in ("aws-keys", "azure-sas-or-key", "lakehouse"):
            return kind
        self.clock()
        return "clock" if abs(getattr(self, "_skew", 0)) >= SIGNED_LIMIT else kind

    def language_kind(self, kind, connector, error):
        """nojava from a source's own adapter (a database error) is norust
        when that adapter runs in the Rust container: neither "No usable
        script language container" nor Exasol Personal 2.4's missing
        /exaudf/exaudfclient (sql.NOJAVA) says which language is missing, and
        the Rust one runs the same client. The kit's Java probes answer with
        a Failure (java_query), which stays Java's. Every path that passes a
        database error's kind on asks this."""
        if kind != "nojava" or not isinstance(error, sql.DbError):
            return kind
        profile = self.defs.profile(connector["profile"]) if connector.get("profile") else {}
        return "norust" if (profile.get("slc") or {}).get("language") == "rust" else kind

    def warn_clock(self):
        if self.clock():
            self.emit("WARN", "The database clock is %s this computer, and certificates are checked by it - a TLS "
                              "source can fail as not yet valid. Restart the database (exakit stop, then exakit "
                              "start) to resync it" % self.clock())

    def db(self):
        if self._db is None:
            try:
                self._db = sql.connect(self.args.dsn, self.args.user, self.args.password_file, log=self.log)
            except sql.DbError as error:
                raise Failure("the local database is not reachable: %s" % error, EXIT["unreachable_db"],
                              "unreachable_db", remedy=REMEDY_FOR["unreachable_db"], command="exakit start")
        return self._db

    def close(self):
        if self._db is not None:
            self._db.close()

    # --- this computer's public IP (publicip) ------------------------------------------
    def egress(self, connector, values, wait=True):
        """(this computer's public IP, the source's host on the internet) for a
        source on the internet (planner.public_host); (None, None) for one on
        this computer or a private network, and the IP None while it is not
        known. wait=False only starts the lookup."""
        host = planner.public_host(connector, values)
        if not host:
            return None, None
        self._egress_host = host
        publicip.start()
        return (publicip.get() if wait else None), host

    def public_ip(self):
        """This run's answer for a source on the internet, else None (--json)."""
        return publicip.get() if getattr(self, "_egress_host", None) else None

    def exists(self, kind, *names):
        db = self.db()
        if kind == "connection":
            rows = db.query("SELECT CONNECTION_NAME FROM EXA_DBA_CONNECTIONS WHERE CONNECTION_NAME = %s"
                            % sql.literal(names[0]))
        elif kind == "schema":
            rows = db.query("SELECT SCHEMA_NAME FROM EXA_SCHEMAS WHERE SCHEMA_NAME = %s" % sql.literal(names[0]))
        else:
            rows = db.query("SELECT SCRIPT_NAME FROM EXA_ALL_SCRIPTS WHERE SCRIPT_SCHEMA = %s AND SCRIPT_NAME = %s"
                            % (sql.literal(names[0]), sql.literal(names[1])))
        return bool(rows)

    # --- prerequisites ---------------------------------------------------------------
    def ensure_script_schema(self):
        """EXAKIT_VS, the schema every script the kit creates goes into, made
        when it is missing: on a fresh database, or after the last source took
        it away. Not the Java probes' alone - a MongoDB source asks neither
        (no host, a Rust profile). It is the kit's, not one source's, so it is
        never journaled: drop_kit_schema_if_unused takes it with the last
        source, after a failed first connect too."""
        if not self.exists("schema", "EXAKIT_VS"):
            self.db().execute("CREATE SCHEMA EXAKIT_VS")

    def create_script(self, statement):
        """An adapter or companion script, never before its schema."""
        self.ensure_script_schema()
        self.db().execute(statement)

    def ensure_probe(self):
        """EXAKIT_VS and its Java DNS probe; tells a missing Java container apart."""
        self.ensure_script_schema()
        db = self.db()
        try:
            db.execute(
                "CREATE OR REPLACE JAVA SCALAR SCRIPT EXAKIT_VS.%s(h VARCHAR(253), p DECIMAL(5,0)) "
                "RETURNS VARCHAR(400) AS\n"
                "import java.net.*;\n"
                "class %s { static String run(ExaMetadata exa, ExaIterator ctx) throws Exception {\n"
                "  String h = ctx.getString(\"h\"); int p = ctx.getInteger(\"p\");\n"
                "  InetAddress a;\n"
                "  try { a = InetAddress.getByName(h); } catch (Exception e) {\n"
                "    String conf = \"\";\n"
                "    try { conf = new String(java.nio.file.Files.readAllBytes(java.nio.file.Paths.get(\"/etc/resolv.conf\"))); } catch (Exception f) { }\n"
                "    return (conf.contains(\"nameserver\") ? \"dns \" : \"nodns \") + e.getClass().getSimpleName(); }\n"
                "  try (Socket s = new Socket()) { s.connect(new InetSocketAddress(a, p), 5000); return \"ok \" + a.getHostAddress(); }\n"
                "  catch (Exception e) { return \"tcp \" + a.getHostAddress() + \" \" + e.getClass().getSimpleName(); } } }\n"
                "/" % (PROBE, PROBE))
            # The staged files the database sees: newline-separated /buckets
            # paths in, the ones it does not see yet out (see await_staged).
            db.execute(
                "CREATE OR REPLACE JAVA SCALAR SCRIPT EXAKIT_VS.%s(p VARCHAR(2000000)) RETURNS VARCHAR(2000000) AS\n"
                "class %s { static String run(ExaMetadata exa, ExaIterator ctx) throws Exception {\n"
                "  StringBuilder missing = new StringBuilder();\n"
                "  for (String path : ctx.getString(\"p\").split(\"\\n\")) {\n"
                "    if (path.length() > 0 && !new java.io.File(path).isFile()) {\n"
                "      if (missing.length() > 0) missing.append(\"\\n\");\n"
                "      missing.append(path); } }\n"
                "  return missing.toString(); } }\n"
                "/" % (FILES, FILES))
        except sql.DbError as error:
            if error.kind == "nojava":
                # Either database's words (sql.NOJAVA): no usable container,
                # or Personal 2.4's builtin_java without its client in BucketFS.
                raise Failure(JAVA_MISSING, EXIT["nojava"], "nojava")
            raise Failure("the DNS probe could not be created: %s" % error, EXIT["failed"])

    def ensure_language(self, profile):
        """A custom language container (Rust) is known by its alias in
        SCRIPT_LANGUAGES - measured: RUST=localzmq+protobuf:///.../custom-rust
        appears once it is installed and the database restarted."""
        slc = profile.get("slc") or {}
        if slc.get("language") != "rust":
            return
        rows = self.db().query("SELECT SYSTEM_VALUE FROM EXA_PARAMETERS WHERE PARAMETER_NAME = 'SCRIPT_LANGUAGES'")
        value = (rows[0].get("SYSTEM_VALUE") if rows else "") or ""
        if not re.search(r"(^|\s)%s=" % re.escape(slc["alias"]), value):
            raise Failure("the Rust language container is not installed in the database (no %s language alias)"
                          % slc["alias"], EXIT["norust"], "norust")

    def missing_languages(self, need):
        """Which of the language containers in `need` (java, rust) the database
        lacks, asked before anything is connected: Rust by its alias, as
        ensure_language asks; Java by running the kit's own file probe on a
        path that is not a file (an empty one is NULL to the database), which
        touches no network."""
        missing = []
        if "java" in need:
            try:
                self.ensure_probe()
                self.java_query("SELECT EXAKIT_VS.%s('-') AS R" % FILES)
            except Failure as error:
                if error.kind != "nojava":
                    raise
                missing.append("java")
        if "rust" in need:
            try:
                self.ensure_language(self.defs.profile("rust-native"))
            except Failure as error:
                if error.kind != "norust":
                    raise
                missing.append("rust")
        return missing

    def probe(self, host, port):
        """'ok <ip>' | 'dns ...' | 'tcp <ip> ...', from inside the database's Java."""
        self.ensure_probe()
        rows = self.java_query("SELECT EXAKIT_VS.%s(%s, %d) AS R" % (PROBE, sql.literal(host), int(port)))
        return (rows[0].get("R") if rows else "") or ""

    def java_query(self, statement):
        """One of the kit's own Java scripts (the probes), whose missing Java is
        Java's whatever the source's adapter runs in: a Failure, which
        language_kind never reads as Rust. Personal 2.4 creates a Java script
        with builtin_java and fails only when it runs."""
        try:
            return self.db().query(statement)
        except sql.DbError as error:
            if error.kind == "nojava":
                raise Failure(JAVA_MISSING, EXIT["nojava"], "nojava") from None
            raise

    def await_staged(self, used, written, profile):
        """Nothing is created over a file the database does not see yet (the
        constants above say why). `used` are the /buckets paths the source's
        scripts and URL name, `written` the host paths this command just
        wrote: the Java probe is asked until it sees every one of them. A
        profile without that probe (a native adapter) gets SETTLE seconds
        when it wrote something new. Files outside the bucket (the loader's)
        are the database's own and need no wait."""
        fresh = [p for p in dict.fromkeys(self.runtime.sql_path(h) for h in written) if p]
        paths = [p for p in dict.fromkeys([u for u in used if u.startswith("/buckets/")] + fresh)]
        if not paths:
            return
        if not (profile.get("slc") or {}).get("needs_dns"):
            if fresh:
                time.sleep(SETTLE)
            return
        self.ensure_probe()
        started = time.time()
        while True:
            rows = self.java_query("SELECT EXAKIT_VS.%s(%s) AS R" % (FILES, sql.literal("\n".join(paths))))
            missing = [p for p in ((rows[0].get("R") if rows else "") or "").split("\n") if p]
            waited = time.time() - started
            if not missing:
                if waited >= 0.5:
                    self.emit("INFO", "Waited %.1f s for the database to see the staged file%s"
                              % (waited, "" if len(paths) == 1 else "s"))
                return
            if waited >= VISIBLE_TIMEOUT:
                raise Failure("the database does not see %s after %.0f s (written under %s); check that the database "
                              "runs from this deployment folder, then connect again"
                              % (missing[0], VISIBLE_TIMEOUT, os.path.dirname(self.runtime.bucket_dir())),
                              EXIT["failed"])
            time.sleep(0.5)

    def choose_ca(self, connector, values):
        """The one certificate the source's CONNECTION will trust, or None
        when no `ca` was given. Fails as kind tls: a wrong CA is a TLS problem."""
        if not values.get("ca"):
            return None
        try:
            certs = tlsca.certificates(values["ca"])
            if connector.get("tls_truststore") or connector.get("tls_class") or \
                    connector.get("ca_encoding") == "base64-bundle":
                # A truststore or the helper holds the whole bundle; Java picks the signer.
                return "".join(certs)
            pem = tlsca.choose(certs, values["host"], values.get("port"), connector.get("ca_probe"), values["ca"])
        except tlsca.CaError as error:
            failure = Failure(str(error), EXIT["failed"], "tls", said="%s; nothing was kept" % error,
                              remedy="nothing was kept - correct the CA file (--set ca=<PEM file or bundle>), "
                                     "then connect again")
            failure.complete = True  # it already says what to do
            raise failure
        if len(certs) > 1:
            self.emit("OK", "Picked the certificate in %s that signs %s (1 of %d, verified handshake)"
                      % (values["ca"], values["host"], len(certs)))
        return pem

    def stage_truststore(self, connector, name, ca_pem, created):
        """For drivers that read trust only from a file (Connector/J,
        mssql-jdbc): one JKS per source, written twice, and the RELATIVE path
        that finds both copies.

        Measured on Exasol Personal: the adapter (a Java UDF) runs with
        user.dir "/" and sees the bucket only at /buckets/...; the loader runs
        in the database container with its driver folder as the working
        directory and sees the bucket at /exa/bucketfs/..., not /buckets. No
        absolute path reaches both, so the path is relative, and the loader's
        copy sits under its own driver folder at that same relative path."""
        if not ca_pem or not connector.get("tls_truststore"):
            return None
        data = tlsca.jks(tlsca.certificates_from_text(ca_pem))
        relative = self.runtime.bucket_sql("tls", name + ".jks").lstrip("/")
        targets = [self.runtime.bucket_dir("tls", name + ".jks")]
        if connector.get("etl"):
            targets.append(os.path.join(self.runtime.loader_dir(connector["etl"]["drivername"]), *relative.split("/")))
        digest = hashlib.sha256(data).hexdigest()
        for path in targets:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as handle:
                handle.write(data)
            self.store.add_consumer(path, digest, name, True)
            if path not in created["files"]:
                created["files"].append(path)
        return relative

    def key_file(self, name):
        return self.runtime.bucket_dir("keys", name + ".json")

    def write_key(self, path, text):
        """Owner-only on this computer; the adapter reads it all the same (measured)."""
        os.makedirs(os.path.dirname(path), exist_ok=True)
        partial = path + ".part"
        fd = os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(partial, 0o600)
        os.replace(partial, path)

    def stage_key(self, name, text, created):
        """The service-account key as this source's file in BucketFS; the path the URL names."""
        path = self.key_file(name)
        self.write_key(path, text)
        self.store.add_consumer(path, hashlib.sha256(text.encode("utf-8")).hexdigest(), name, True)
        if path not in created["files"]:
            created["files"].append(path)
        return self.runtime.bucket_sql("keys", name + ".json")

    def script_readers(self):
        """Users other than administrators who may create scripts - and so
        could read any file in BucketFS, a key file included. Roles are
        followed through grants; PUBLIC counts for every user."""
        db = self.db()
        holders = {r["GRANTEE"] for r in db.query(
            "SELECT GRANTEE FROM EXA_DBA_SYS_PRIVS WHERE PRIVILEGE IN ('CREATE SCRIPT', 'CREATE ANY SCRIPT')")}
        grants = {}
        for row in db.query("SELECT GRANTEE, GRANTED_ROLE FROM EXA_DBA_ROLE_PRIVS"):
            grants.setdefault(row["GRANTEE"], set()).add(row["GRANTED_ROLE"])
        readers = []
        for user in sorted(r["USER_NAME"] for r in db.query("SELECT USER_NAME FROM EXA_DBA_USERS")):
            seen, todo = set(), [user, "PUBLIC"]
            while todo:
                current = todo.pop()
                if current not in seen:
                    seen.add(current)
                    todo.extend(grants.get(current, ()))
            if user != "SYS" and "DBA" not in seen and seen & holders:
                readers.append(user)
        return readers

    def warn_key_readers(self, connector, name):
        if not connector.get("secret_as_file"):
            return
        try:
            readers = self.script_readers()
        except sql.DbError as error:
            self.emit("WARN", "Could not list who may create scripts (%s); any such user can read %s's key file"
                      % (error, name))
            return
        if readers:
            self.emit("WARN", "%s's key file is in BucketFS, which any user who may create scripts can read - and %s "
                      "may: %s. Revoke CREATE SCRIPT from them, or accept that they can read this key"
                      % (name, "this user" if len(readers) == 1 else "these users", ", ".join(readers)))

    @staticmethod
    def drafts(connector):
        """True for a connector whose mapping the kit drafts when none is given."""
        return any(spec["kind"] == "edml" and spec.get("draft") for spec in connector["inputs"])

    def draft_mapping(self, connector, values, secret, name):
        """(folder, draft) for a connect without a mapping: drafted from the
        bucket or container (edml_draft) into <kit home>/sources/<name>/edml,
        its tables said in one summary. A store that cannot be listed is a
        failure that says to give a mapping folder instead."""
        where = connector.get("store", "bucket")
        self.emit("INFO", "Drafting the mapping from the %s..." % where)
        result = draft_into(connector, values, secret, self.store.path(name, "edml"))
        self.emit("OK", "Mapping drafted from the %s: %d table%s in %s" % (
            where, len(result["tables"]), "" if len(result["tables"]) == 1 else "s", result["folder"]))
        for line in edml_draft.summary_lines(result):
            self.emit("INFO", "  " + line)
        for note in result["notes"]:
            self.emit("WARN", note)
        return result["folder"], result

    def stage_mapping(self, values, name, created):
        """The EDML files, copied into mappings/<name>/ in the kit's bucket
        folder; the MAPPING property that names that folder for the adapter
        (a bucket path, without /buckets - measured)."""
        try:
            files = document.mapping_files(values["mapping"])
        except (document.DocumentError, OSError) as error:
            raise Failure(str(error), EXIT["input"])
        folder = self.runtime.bucket_dir("mappings", name)
        if os.path.isdir(folder):
            # Left by an earlier connect of this name: the mapping given now is the one that counts.
            for stale in os.listdir(folder):
                if not any(stale == n for n, _ in files) and stale.endswith(".json"):
                    os.remove(os.path.join(folder, stale))
        for file_name, text in files:
            path = os.path.join(folder, file_name)
            os.makedirs(folder, exist_ok=True)
            with open(path, "w", encoding="utf-8", newline="\n") as handle:
                handle.write(text)
            self.store.add_consumer(path, hashlib.sha256(text.encode("utf-8")).hexdigest(), name, True)
            if path not in created["files"]:
                created["files"].append(path)
        self.emit("OK", "Mapping staged: %d file%s from %s" % (len(files), "" if len(files) == 1 else "s",
                                                                values["mapping"]))
        return self.runtime.bucket_sql("mappings", name)[len("/buckets"):]

    def require_route(self, connector, values, name):
        host = planner.source_host(connector, values)
        if not host:
            return
        port = planner.source_port(connector, values)
        answer = self.probe(host, port)
        if answer.startswith("nodns"):
            # The language container has no resolver at all (Exasol Personal's
            # empty /etc/resolv.conf): repairable, so the shell repairs and retries.
            raise Failure("Java in the database has no DNS resolver, so it cannot resolve %s" % host, EXIT["dns"], "dns")
        if answer.startswith("dns"):
            raise Failure("the host name %s does not resolve" % host, EXIT["failed"], "nohost")
        if answer.startswith("tcp"):
            raise Failure("%s:%d is not reachable from inside the database (%s)" % (host, port, answer[4:]),
                          EXIT["failed"], "unreachable")
        self.emit("OK", "%s resolves and answers on port %d from inside the database (%s)" % (host, port, answer[3:]))

    # --- artifacts ------------------------------------------------------------------
    def stage(self, connector, name, created):
        """Fetch, verify and stage the adapter and driver; record this source as their consumer."""
        if not self.runtime.available():
            raise Failure("the deployment's runtime directory is missing (%s)" % self.runtime.exa, EXIT["failed"])
        # Connectors of one family (lakehouse: every catalog and store) run
        # the same pinned engine, staged once under the family's folder, so
        # the shared adapter script always points at a file all of them keep.
        cid = connector.get("family") or connector["id"]
        adapter_pin, driver_pin = connector["adapter"], connector.get("driver")
        jars = []
        adapter_src = self.cache.fetch(adapter_pin)
        lua = self.defs.profile(connector["profile"])["adapter_script"].get("language") == "LUA"
        if lua:
            # A Lua adapter's text goes into CREATE SCRIPT (adapter_sql reads
            # these verified cache copies); the database reads no file of it.
            jars += [adapter_src, self.cache.fetch(connector["trust"])]
        else:
            staged = adapter_pin["asset"]
            if adapter_pin.get("bundle") == "tar.gz":
                # A release archive: only its pinned member is staged.
                staged = os.path.basename(adapter_pin["member"])
                dest = self.runtime.bucket_dir(cid, adapter_pin["version"], staged)
                made = artifacts.stage_tar_member(adapter_src, adapter_pin["member"], adapter_pin["member_size"],
                                                  adapter_pin["member_sha256"], dest)
                digest = adapter_pin["member_sha256"]
            else:
                dest = self.runtime.bucket_dir(cid, adapter_pin["version"], staged)
                made = artifacts.stage_file(adapter_src, dest)
                digest = adapter_pin["sha256"]
            self.store.add_consumer(dest, digest, name, made)
            if made:
                created["files"].append(dest)
                self.store.save_journal(name, dict(self.store.journal(name) or {}, created=created))
            jars.append(self.runtime.bucket_sql(cid, adapter_pin["version"], staged))
        if not driver_pin:
            # A document-files adapter carries its store's SDK; nothing else to stage.
            self.emit("OK", "Adapter %s verified and staged" % adapter_pin["version"])
            return jars
        driver_src = self.cache.fetch(driver_pin)
        if driver_pin.get("bundle") == "zip":
            bundle_dir = self.runtime.bucket_dir(cid, "driver-" + driver_pin["version"])
            for jar in artifacts.stage_zip(driver_src, bundle_dir):
                jars.append(self.runtime.bucket_sql(cid, "driver-" + driver_pin["version"], jar))
                self.store.add_consumer(os.path.join(bundle_dir, jar), driver_pin["sha256"], name, True)
                created["files"].append(os.path.join(bundle_dir, jar))
        elif not lua:
            # The Java adapter loads the driver too; a Lua one only the loader does.
            dest = self.runtime.bucket_dir(cid, "driver-" + driver_pin["version"], driver_pin["asset"])
            made = artifacts.stage_file(driver_src, dest)
            self.store.add_consumer(dest, driver_pin["sha256"], name, made)
            if made:
                created["files"].append(dest)
            jars.append(self.runtime.bucket_sql(cid, "driver-" + driver_pin["version"], driver_pin["asset"]))
        helper = None
        if connector.get("tls_class"):
            # Staged for every source of this connector, so the loader's
            # settings.cfg never changes with which source uses a CA.
            self.ensure_script_schema()     # the helper is built by a script in it
            try:
                helper = tlshelper.jar(self.db(), self.defs.root, self.cache.root)
            except tlshelper.HelperError as error:
                raise Failure(str(error), EXIT["failed"])
            folder = "tls-helper-" + os.path.basename(os.path.dirname(helper))[:12]
            dest = self.runtime.bucket_dir(cid, folder, tlshelper.JAR_NAME)
            made = artifacts.stage_file(helper, dest)
            self.store.add_consumer(dest, artifacts.sha256_file(helper), name, made)
            if made:
                created["files"].append(dest)
            jars.append(self.runtime.bucket_sql(cid, folder, tlshelper.JAR_NAME))
        self.emit("OK", "Adapter %s and driver %s verified and staged" % (adapter_pin["version"], driver_pin["version"]))
        etl = connector.get("etl")
        loader_helper = None
        if etl and etl.get("trust_store") == "container":
            # The driver trusts only the JVM's default store, which the loader
            # lacks; the kit's main class points it at the container's own.
            self.ensure_script_schema()     # the helper is built by a script in it
            try:
                loader_helper = tlshelper.jar(self.db(), self.defs.root, self.cache.root, "loader")
            except tlshelper.HelperError as error:
                raise Failure(str(error), EXIT["failed"])
        if etl:
            loader = self.runtime.loader_dir(etl["drivername"])
            extra = ([tlshelper.JAR_NAME] if helper else []) + ([tlshelper.LOADER_JAR] if loader_helper else [])
            settings = artifacts.settings_cfg(dict(etl, main=tlshelper.LOADER_MAIN) if loader_helper else etl,
                                              driver_pin["asset"], extra)
            cfg = os.path.join(loader, "settings.cfg")
            if os.path.isfile(cfg):
                with open(cfg, encoding="utf-8") as handle:
                    current = handle.read()
                if current != settings and not self.store.consumers(cfg):
                    raise Failure("a loader driver %s is already registered and was not set up by the kit; it was "
                                  "left unchanged" % etl["drivername"], EXIT["conflict"], "conflict",
                                  remedy="the kit does not replace a driver registration it did not make; remove "
                                         "that one from the database's JDBC drivers if nothing uses it, then "
                                         "connect again")
            made_jar = artifacts.stage_file(driver_src, os.path.join(loader, driver_pin["asset"]))
            os.makedirs(loader, exist_ok=True)
            made_cfg = not os.path.isfile(cfg)
            with open(cfg, "w", encoding="utf-8", newline="\n") as handle:
                handle.write(settings)
            self.store.add_consumer(os.path.join(loader, driver_pin["asset"]), driver_pin["sha256"], name, made_jar)
            self.store.add_consumer(cfg, "settings", name, made_cfg)
            if made_jar:
                created["files"].append(os.path.join(loader, driver_pin["asset"]))
            if made_cfg:
                created["files"].append(cfg)
            for built, jar_name in ((helper, tlshelper.JAR_NAME), (loader_helper, tlshelper.LOADER_JAR)):
                if not built:
                    continue
                dest = os.path.join(loader, jar_name)
                made = artifacts.stage_file(built, dest)
                self.store.add_consumer(dest, artifacts.sha256_file(built), name, made)
                if made:
                    created["files"].append(dest)
            self.emit("OK", "Loader driver %s registered for IMPORT FROM JDBC%s"
                      % (etl["drivername"], " (trusting the language container's CA store)" if loader_helper else ""))
        return jars

    # --- SQL ------------------------------------------------------------------------
    def create_connection(self, names, url, user, secret, replace=False, hidden=()):
        verb = "CREATE OR REPLACE CONNECTION" if replace else "CREATE CONNECTION"
        statement = "%s %s TO %s" % (verb, sql.ident(names["connection"]), sql.literal(url))
        if user is not None:
            statement += " USER %s IDENTIFIED BY %s" % (sql.literal(user), sql.literal(secret))
        self.db().execute(statement, secrets=[secret] + list(hidden))

    def credential(self, connector, values, secret):
        """(url, user, secret, hidden, notes) for the CONNECTION: a JDBC URL with
        the user's password, or - for a document source - an empty URL and
        user with the credential JSON as the secret. Every secret here is the
        run log's from now on (vslog), whatever writes it next."""
        self.log.secret(secret)
        if self.storage_secret:
            self.log.secret(self.storage_secret)
        if connector.get("secret_as_file"):
            # The key goes to a file in BucketFS, never into the CONNECTION:
            # no user, no password, and the URL names only the file's path.
            try:
                _email, _project, text, hidden = keyfile.service_account(secret)
            except keyfile.KeyFileError as error:
                failure = Failure(str(error), EXIT["input"])
                failure.complete = True
                raise failure
            self.log.secret(text, *hidden)
            return None, None, text, hidden, []
        if connector.get("credential"):
            try:
                text, hidden, notes = document.credential(connector["credential"], values, secret,
                                                          storage=self.storage_secret)
            except document.DocumentError as error:
                failure = Failure(str(error), EXIT["input"])
                failure.complete = True  # the credential's own problem, named; nothing ran
                raise failure
            self.log.secret(text, *hidden)
            # A document adapter names no address; a lakehouse catalog's is its endpoint.
            url = connector["url"].format(**values) if connector.get("url") else ""
            return url, "", text, hidden, notes
        # A connector with one fixed account name (Databricks: "token") takes
        # no user input.
        return None, connector.get("user", values.get("user")), secret, [], []

    def require_storage_secret(self, connector, what):
        """A combination with two secrets (planner.storage_secret_input) needs
        the second one too: refused, kind input, before anything changes."""
        spec = planner.storage_secret_input(connector)
        if spec and not self.storage_secret:
            label = spec.get("label", "storage secret").lower()
            message = "%s needs the storage's %s as well as the catalog's credential" % (what, label)
            remedy = ("give it with --storage-secret-file <file> (a file holding only the %s), or answer the hidden "
                      "prompt at a terminal; it is never taken as an argument" % label)
            raise Failure(message, EXIT["input"], "input", remedy=remedy, said="%s: %s" % (message, remedy))

    def adapter_sql(self, names, jars, profile=None):
        script = (profile or self.profile)["adapter_script"]
        if script.get("language") == "LUA":
            try:
                text = luaadapter.body(self.defs.root, script["suffix"], jars[0], jars[1])
            except (luaadapter.LuaAdapterError, OSError, UnicodeDecodeError) as error:
                raise Failure("the Lua adapter could not be assembled: %s" % error, EXIT["failed"])
            # No closing "/": everything after AS is the Lua program.
            return "CREATE OR REPLACE LUA ADAPTER SCRIPT %s.%s AS\n%s" % (
                sql.ident(names["script_schema"]), sql.ident(names["script"]), text)
        if script.get("language") == "RUST":
            # The .so's entry point is bound to this script's name (measured).
            return "CREATE OR REPLACE RUST ADAPTER SCRIPT %s.%s AS\n%%udf_object %s;\n/" % (
                sql.ident(names["script_schema"]), sql.ident(names["script"]), jars[0])
        lines = ["CREATE OR REPLACE JAVA ADAPTER SCRIPT %s.%s AS"
                 % (sql.ident(names["script_schema"]), sql.ident(names["script"])),
                 "  %%scriptclass %s;" % script["scriptclass"]]
        lines += ["  %%env %s;" % env for env in script.get("env", [])]
        lines += ["  %%jar %s;" % jar for jar in jars]
        return "\n".join(lines) + "\n/"

    @staticmethod
    def companions(connector, profile):
        """The scripts an adapter calls by fixed names in its own schema, shared
        by every source of the connector: a document adapter's or MongoDB's one
        import script (its signature from the profile), or a connector's own
        list (Lakehouse: scan, distributor, version)."""
        if connector.get("companions"):
            return connector["companions"]
        if connector.get("import_script"):
            return [dict(profile["import_script"], name=connector["import_script"])]
        return []

    def companion_sql(self, spec, names, jars):
        target = "%s.%s" % (sql.ident(names["script_schema"]), sql.ident(spec["name"]))
        if spec.get("language") == "RUST":
            return "CREATE OR REPLACE RUST %s SCRIPT %s%s AS\n%%udf_object %s;\n/" % (
                spec["type"], target, spec["signature"], jars[0])
        if spec.get("language") == "LUA":
            # Everything after AS is the Lua program: no closing "/".
            return "CREATE OR REPLACE LUA %s SCRIPT %s%s AS\n%s" % (spec["type"], target, spec["signature"], spec["body"])
        return self.import_sql_java(spec, names, jars)

    def import_sql_java(self, script, names, jars):
        """The document adapter's import UDF: the name, parameters and EMITS(...)
        its adapter calls (from the adapter's user guide)."""
        lines = ["CREATE OR REPLACE JAVA SET SCRIPT %s.%s(DATA_LOADER VARCHAR(2000000), "
                 "SCHEMA_MAPPING_REQUEST VARCHAR(2000000), CONNECTION_NAME VARCHAR(500)) EMITS(...) AS"
                 % (sql.ident(names["script_schema"]), sql.ident(script["name"])),
                 "  %%scriptclass %s;" % script["scriptclass"]]
        lines += ["  %%env %s;" % env for env in script.get("env", [])]
        lines += ["  %%jar %s;" % jar for jar in jars]
        return "\n".join(lines) + "\n/"

    def import_script_users(self, connector_id, besides):
        """Other sources that share this connector's scripts: of the same
        connector, or of any connector on the same shared adapter script
        (every lakehouse source runs LAKEHOUSE_ADAPTER and its
        companions), so the last Glue source out does not drop what a REST
        or Unity source still calls."""
        shared = self._shared_adapter(connector_id)
        users = []
        for n in self.store.names():
            other = self.store.config(n).get("connector")
            if n != besides and (other == connector_id or (shared and other and self._shared_adapter(other) == shared)):
                users.append(n)
        return users

    def _shared_adapter(self, connector_id):
        try:
            return self.defs.connector(connector_id).get("shared_adapter")
        except (OSError, ValueError, planner.PlanError):
            return None

    def virtual_adapters(self, besides=()):
        """[(virtual schema, adapter script schema, adapter script name)] for
        every virtual schema in the DATABASE but those in besides - not the
        registry's answer: a kit home deleted, lost or reinstalled, or another
        one, leaves virtual schemas no source record names, still running the
        shared adapters. An adapter a row does not name is (None, None); None
        means the database could not say."""
        try:
            rows = self.db().query("SELECT * FROM SYS.EXA_ALL_VIRTUAL_SCHEMAS")
        except (Failure, sql.DbError) as error:
            self.log.write("INFO", "could not list the virtual schemas in the database: %s" % error)
            return None
        skip = set(str(b).upper() for b in besides)
        found = []
        for row in rows:
            vs = str(row.get("SCHEMA_NAME") or "")
            if vs.upper() in skip:
                continue
            owner, adapter = row.get("ADAPTER_SCRIPT_SCHEMA"), row.get("ADAPTER_SCRIPT_NAME")
            if not (owner and adapter) and row.get("ADAPTER_SCRIPT"):
                # Older releases name it in one column, SCHEMA.SCRIPT.
                owner, _, adapter = str(row["ADAPTER_SCRIPT"]).replace('"', "").rpartition(".")
            found.append((vs, str(owner).upper() if owner else None, str(adapter).upper() if adapter else None))
        return found

    def adapter_users(self, script_schema, script=None, besides=()):
        """The virtual schemas in the database, other than besides, on the
        adapter script_schema.script (on any script there when script is
        None). One whose adapter cannot be read counts as a user; None when
        the database cannot say. Either way the shared object stays."""
        found = self.virtual_adapters(besides)
        if found is None:
            return None
        return sorted(vs for vs, owner, adapter in found
                      if owner is None or adapter is None or
                      (owner == script_schema.upper() and (script is None or adapter == script.upper())))

    def companion_users(self, connector, names, besides=()):
        """The virtual schemas in the database that may call this connector's
        companion scripts: those on its shared adapter; for a connector whose
        sources each have their own adapter (S3, Azure Blob share one import
        script), any on a kit script but those known to be another
        connector's - on another connector's shared adapter, or a registered
        source of another connector. None when the database cannot say."""
        if connector.get("shared_adapter"):
            return self.adapter_users(names["script_schema"], connector["shared_adapter"], besides)
        found = self.virtual_adapters(besides)
        if found is None:
            return None
        others = set()
        for entry in self.defs.entries():
            if entry["id"] != connector.get("id") and self._shared_adapter(entry["id"]):
                others.add(self._shared_adapter(entry["id"]).upper())
        foreign = set()
        for n in self.store.names():
            config = self.store.config(n)
            if config.get("connector") != connector.get("id"):
                foreign.add(config["objects"]["schema"].upper())
        return sorted(vs for vs, owner, adapter in found
                      if owner is None or adapter is None or
                      (owner == names["script_schema"].upper() and adapter not in others
                       and vs.upper() not in foreign))

    def drop_shared(self, statement, what, kept):
        """Drop one shared object; a refusal is a note in kept, never the end
        of the command - the source's own objects are already gone."""
        try:
            self.db().execute(statement)
            return True
        except sql.DbError as error:
            kept.append("%s (the database refused the drop: %s)" % (what, error))
            return False

    @staticmethod
    def vs_properties(connector, names, values, extra=None):
        """The virtual schema's properties, in order, as (key, value): its
        CONNECTION's name first, then the connector's own from the inputs."""
        props = [(connector.get("connection_property", "CONNECTION_NAME"), names["connection"])]
        fields = dict(values, **(extra or {}))
        for key, template in connector["vs_properties"].items():
            props.append((key, template.format(**fields)))
        if planner.plain_http(connector, values):
            # The lakehouse engine refuses an http catalog or store unless told.
            for key, value in (connector.get("vs_when_http") or {}).items():
                props.append((key, value))
        return props

    def vs_sql(self, connector, names, values, extra=None):
        return "CREATE VIRTUAL SCHEMA %s USING %s.%s WITH %s" % (
            sql.ident(names["schema"]), sql.ident(names["script_schema"]), sql.ident(names["script"]),
            " ".join("%s = %s" % (key, sql.literal(value))
                     for key, value in self.vs_properties(connector, names, values, extra)))

    def check_scope(self, connector, names, values):
        """Is the schema (MySQL: the database) there, and may the account use
        it? Asked through the loader before any script or virtual schema
        exists: Exasol does not ask, and a virtual schema over a name the
        source does not have is created empty, which reads as success."""
        spec = connector.get("schema_check")
        if not spec or not connector.get("etl"):
            return
        value = values.get(spec["input"], "")
        statement = spec["statement"].replace("{v}", sql.literal(value))
        rows = self.db().query("SELECT * FROM (IMPORT FROM JDBC AT %s STATEMENT %s)"
                               % (sql.ident(names["connection"]), sql.literal(statement)))
        answer = str(list(rows[0].values())[0]) if rows and rows[0] else ""
        label = "database" if spec["input"] == "database" else "schema"
        if answer == "ok":
            self.emit("OK", "The source has %s %s, and the account may use it" % (label, value))
            return
        if answer.startswith("case:"):
            other = answer[5:]
            raise ScopeFailure("the source has no %s %s, but it has %s (%s)"
                               % (label, value, other, spec.get("case", "names differ in case")), "schema_missing",
                               "give it as the source spells it: --set %s=%s" % (spec["input"], other))
        if answer == "denied":
            raise ScopeFailure("the account may not use %s %s" % (label, value), "privilege",
                               "grant it USAGE on the %s (and SELECT on its tables)" % label)
        raise ScopeFailure("the source has no %s %s that this account can see" % (label, value), "schema_missing",
                           "check the name and that the account has access to it")

    def tables(self, schema):
        return [r.get("TABLE_NAME") for r in self.db().query(
            "SELECT TABLE_NAME FROM EXA_DBA_VIRTUAL_TABLES WHERE TABLE_SCHEMA = %s ORDER BY TABLE_NAME"
            % sql.literal(schema))]

    def bounded_read(self, schema, tables):
        """One row through the adapter and the loader; the rows are never printed."""
        if not tables:
            return False
        self.db().query("SELECT * FROM %s.%s LIMIT 1" % (sql.ident(schema), sql.ident(tables[0])))
        return True

    # A document source's tables each read their own objects, so each is read;
    # beyond this many, the rest wait for a query.
    READ_ALL_LIMIT = 25

    def read_each(self, schema, tables):
        """A document source: one row from every table. Measured on S3: a source
        glob that matches no object reads as an empty table, not an error -
        those tables are returned so the user hears of them."""
        empty = []
        for table in tables[:self.READ_ALL_LIMIT]:
            rows = self.db().query("SELECT * FROM %s.%s LIMIT 1" % (sql.ident(schema), sql.ident(table)))
            if not rows:
                empty.append(table)
        return empty

    def verify(self, connector, schema):
        """(tables, read, evidence words, empty tables) for a connected source."""
        tables = self.tables(schema)
        if any(spec["kind"] == "edml" for spec in connector["inputs"]) and tables:
            empty = self.read_each(schema, tables)
            read = len(tables) > len(empty)
            if empty:
                self.emit("WARN", "No rows in %s: their mapping's source matches no objects, or they are empty - "
                                  "check the \"source\" in the mapping" % ", ".join(empty))
            return tables, read, "a bounded read of each table", empty
        return tables, self.bounded_read(schema, tables), "a bounded read", []

    # --- operations -----------------------------------------------------------------
    def connect(self, connector_id, name, given, secret, dry_run=False, plan_only=False, secret_given=False):
        # The gate first, as the shells' own resolve says it: a gated
        # connector is exit 5 whatever else is wrong with the command.
        entry = self.defs.entry(connector_id)
        if entry["status"] == "gated":
            raise Failure("%s is not available yet: %s" % (entry["name"], entry["gate"]), EXIT["gated"], "gated")
        if not name:
            raise Failure("the connection has no name", EXIT["input"], "input",
                          remedy="give it one with --name (lower case letters, digits and _, a letter first, e.g. sales)")
        if not sources.NAME.match(name):
            raise Failure("the source name must be lower case letters, digits and _ (start with a letter, at most 40), "
                          "e.g. sales", EXIT["input"])
        connector = self.defs.connector(connector_id)
        profile = self.defs.profile(connector["profile"])
        if self.store.exists(name):
            current = self.store.config(name)
            if current["connector"] != connector_id:
                # Said by the plan too, before a credential is asked for: a
                # name is one source, and one connector's inputs mean nothing
                # to another's.
                fix = "choose another name or remove it first: exakit source remove %s" % name
                taken = "a source named %s already exists (%s), so it cannot be connected as %s" % (
                    name, current["connector"], connector_id)
                raise Failure(taken, EXIT["conflict"], "conflict", remedy=fix, said="%s; %s" % (taken, fix))
            if self.store.status(name).get("status") != "disconnected":
                # A source that is connected is updated in place: its new
                # address (and a new credential, when one is given) tried
                # before anything changes, its CONNECTION and VS_<NAME> kept.
                return self.repoint(connector_id, name, given, secret, preview=plan_only or dry_run,
                                    secret_given=secret_given or bool(secret))
            # Reconnecting: the recorded inputs stand unless one is given
            # again, so "exakit connect <connector> --name N" plus the
            # credential is the whole command - the one disconnect names.
            given = dict(current.get("inputs") or {}, **given)
        values = planner.validate_inputs(connector, given)
        # One combination of a connector with settings (lakehouse): its flat
        # definition from here on - its inputs, address and properties.
        connector = self.defs.connector(connector_id, values)
        names = planner.objects(name, connector)
        description = planner.describe(self.defs, connector_id, name, values, self.runtime, self.cache, self.store)
        description["action"] = "reconnect" if self.store.exists(name) else "connect"
        # Asked now, in the background: a plan waits for the answer; a connect
        # only when its result or a network failure's remedy names it.
        self.egress(connector, values, wait=False)
        if plan_only or dry_run:
            ip, host = self.egress(connector, values)
            description["public_ip"] = ip
            if ip:
                self.emit("INFO", publicip.advice(ip, host))
            return description
        reconnect = False
        if self.store.exists(name):
            current = self.store.config(name)
            if self.store.status(name).get("status") != "disconnected" or current["connector"] != connector_id:
                fix = "choose another name or remove it first: exakit source remove %s" % name
                taken = "a source named %s already exists (%s)" % (name, current["connector"])
                raise Failure(taken, EXIT["conflict"], "conflict", remedy=fix, said="%s; %s" % (taken, fix))
            reconnect = True
        spec = planner.secret_input(connector)
        if spec and not secret:
            raise Failure("%s needs %s on standard input (it is never taken as an argument)"
                          % (connector_id, spec["label"].lower()), EXIT["input"], "input",
                          remedy="pipe it on standard input or give it with --password-file <file>")
        self.require_storage_secret(connector, "connect")
        created = {"files": [], "connection": False, "script": False, "schema": False}
        drafted = None
        journal = {"operation": "reconnect" if reconnect else "connect", "connector": connector_id,
                   "started": sources.now(), "created": created}
        with self.store.lock():
            # An earlier attempt that was killed part way (Ctrl-C, a closed
            # lid) left its journal - and its objects, which carry the kit's
            # names and would otherwise read as someone else's. The journal
            # says exactly what that attempt made; that is undone first.
            if not reconnect:
                self.recover_interrupted(name, names)
            if reconnect or self.shares_scripts(connector):
                # After a kit update: a reconnect keeps the adapter script it
                # had, and a shared script re-created below would move every
                # other source of the connector unrecorded - so they move first.
                self.move_forward(connector_id, only=[name])
            self.store.save_journal(name, journal)

            def made(flag):
                created[flag] = True
                self.store.save_journal(name, journal)

            try:
                if not reconnect:
                    for kind, label in (("connection", names["connection"]), ("schema", names["schema"])):
                        if self.exists(kind, label):
                            raise Failure("%s %s already exists in the database and is not a source the kit set up; "
                                          "it was left unchanged" % (kind, label), EXIT["conflict"], "conflict",
                                          remedy="choose another name for the source (--name)")
                # Checked first: a malformed credential is named here, not as a
                # Java stack from inside the database after files were staged.
                url, user, conn_secret, hidden, notes = self.credential(connector, values, secret)
                if planner.draft_prefix(connector, values) is not None and not reconnect:
                    # No mapping given: drafted from the bucket with the credential just checked.
                    values["mapping"], drafted = self.draft_mapping(connector, values, secret, name)
                self.warn_clock()
                self.ensure_language(profile)
                self.require_route(connector, values, name)
                ca_pem = self.choose_ca(connector, values)
                jars = self.stage(connector, name, created)
                truststore = self.stage_truststore(connector, name, ca_pem, created)
                mapping_path = None
                if values.get("mapping") and not reconnect:
                    mapping_path = self.stage_mapping(values, name, created)
                key_path = sa_email = None
                if connector.get("secret_as_file"):
                    sa_email = keyfile.service_account(conn_secret)[0]
                    key_path = self.stage_key(name, conn_secret, created)
                    conn_secret = None
                    self.emit("OK", "Key file staged for %s (owner-only on this computer)" % name)
                self.await_staged(jars + ([key_path] if key_path else []), created["files"], profile)
                if url is None:
                    url = planner.jdbc_url(connector, values, {"ca_pem": ca_pem, "truststore": truststore,
                                                               "key_path": key_path, "sa_email": sa_email})
                self.create_connection(names, url, user, conn_secret, replace=reconnect, hidden=hidden)
                if not reconnect:
                    made("connection")
                elif self.store.status(name).get("needs_refresh"):
                    # Moved to a new adapter while disconnected: its metadata
                    # is read again now that the adapter can reach the source.
                    self.db().execute("ALTER VIRTUAL SCHEMA %s REFRESH" % sql.ident(names["schema"]))
                    self.emit("OK", "Virtual schema %s refreshed for adapter %s"
                              % (names["schema"], connector["adapter"]["version"]))
                self.emit("OK", "Connection %s created (%s)" % (names["connection"], "it names the key file, not the key"
                                                                     if key_path else "the credential lives only in the database"))
                self.check_scope(connector, names, values)
                if not reconnect:
                    shared_before = connector.get("shared_adapter") and \
                        self.exists("script", names["script_schema"], names["script"])
                    self.create_script(self.adapter_sql(names, jars, profile))
                    if not shared_before:
                        made("script")
                    for spec in self.companions(connector, profile):
                        if not self.exists("script", names["script_schema"], spec["name"]):
                            created.setdefault("companions", []).append(spec["name"])
                            self.store.save_journal(name, journal)
                        self.create_script(self.companion_sql(spec, names, jars))
                    self.db().execute(self.vs_sql(connector, names, values, {"mapping_path": mapping_path}))
                    made("schema")
                self.warn_key_readers(connector, name)
                tables, read, how, empty = self.verify(connector, names["schema"])
                for note in notes:
                    self.emit("INFO", note.replace("<name>", name))
                if read:
                    self.emit("OK", "Virtual schema %s: %d table(s); %s succeeded" % (names["schema"], len(tables), how))
                else:
                    self.emit("WARN", "Virtual schema %s connected, but the source shows no tables for this scope"
                              % names["schema"])
            except (Failure, sql.DbError, artifacts.ArtifactError, OSError) as error:
                self.undo(names, created, name)
                self.store.clear_journal(name)
                if reconnect:
                    self.store.update_status(name, status="disconnected")
                else:
                    # A first attempt leaves no record at all - not even the
                    # empty folder its journal lived in.
                    self.store.delete_source(name)
                    self.drop_kit_schema_if_unused()
                kind = self.signed_kind(getattr(error, "kind", "error"), connector)
                code = getattr(error, "code", EXIT["failed"])
                if isinstance(error, sql.DbError):
                    code = EXIT["dns"] if kind == "dns" else EXIT["nojava"] if kind == "nojava" else EXIT["failed"]
                if self.language_kind(kind, connector, error) == "norust":
                    kind, code = "norust", EXIT["norust"]
                # A first connect has no source record yet, so the lifecycle
                # commands do not apply: nothing was left behind, and the fix is
                # the same command with corrected input.
                remedy = remedy_for(kind, name, connector, error)
                if getattr(error, "complete", False):
                    # Its own words say what to do; --json still gets the fix as remedy.
                    if error.remedy is None:
                        error.remedy = "nothing was kept - correct it, then run the same exakit connect again"
                    raise error
                if isinstance(error, ScopeFailure):
                    again = "nothing was kept - connect again with the corrected name"
                    raise Failure(str(error), code, kind, remedy="%s; %s" % (error.remedy, again),
                                  said="%s; %s" % (error.said, again))
                specific = tls_remedy(error, connector, self.clock()) if kind == "tls" else None
                if specific:
                    remedy = "the source's certificate did not verify; nothing was kept - %s, then connect again" % specific
                elif not reconnect and kind in ("auth", "tls", "unreachable", "nohost", "denied", "region", "nobucket",
                                                "clock", "external", "managed", "schema_missing", "privilege",
                                                "missing_or_denied", "sandbox", "catalog"):
                    remedy = {"denied": "the account signs in but may not read this data; nothing was kept - grant it what the message names (%s), then connect again" % connector.get("access", "read access"),
                              "privilege": "the source took the credentials, but the account lacks a privilege; nothing was kept - grant it what the message names (%s), then connect again" % connector.get("access", "read access"),
                              "missing_or_denied": "the source answers that the object the message names does not exist for this account; nothing was kept - check that name as the source spells it, or grant the account %s, then connect again" % connector.get("access", "read access"),
                              "region": "the bucket is in another region; nothing was kept - connect again with --set region=<the bucket's region>",
                              "nobucket": "nothing was kept - check the %s name, then connect again" % connector.get("store", "bucket"),
                              "clock": "the database clock is too far from the store's for a signed request; nothing was kept - restart the database (exakit stop, then exakit start), then connect again",
                              "auth": "the source rejected the credentials; nothing was kept - correct them and run the same exakit connect again"
                                      + ("; %s" % connector["auth_hint"] if connector.get("auth_hint") else ""),
                              "tls": "the source's certificate or host name did not verify; nothing was kept - %s, then connect again" % tls_fix(connector),
                              "unreachable": "the source did not answer from inside the database; nothing was kept - check host, port, firewall and VPN (a source on this computer must listen beyond 127.0.0.1), then connect again",
                              "nohost": "nothing was kept - check the spelling (a private name may need a VPN), then connect again",
                              "external": "Unity Catalog does not let engines outside Databricks read this schema's files; nothing was kept - switch External Data Access on for the metastore and grant the token's user EXTERNAL USE SCHEMA on the schema (a schema on Databricks Default Storage can never be read from outside), or read it through the SQL warehouse: exakit connect databricks",
                              "managed": "a table here is a Databricks catalog-managed table, which this adapter version cannot read yet; nothing was kept - read it through the SQL warehouse instead: exakit connect databricks",
                              "catalog": "the catalog does not know warehouse %s; nothing was kept - give the catalog's name (e.g. exakit_uc for Databricks, the catalog name for Polaris), not a URL, then connect again" % catalog_warehouse(error),
                              "sandbox": "the database's Java sandbox stopped the driver before it reached the source - not the network or the credentials; nothing was kept - update the kit (exakit update), or connect with tls=verify and --set ca=<PEM file>, then connect again",
                              "schema_missing": "the catalog has no such namespace that this credential can see; nothing was kept - check the namespace (and the warehouse), then connect again"}[kind]
                refused = refused_secret(connector, error) if kind == "auth" and not reconnect else None
                if refused:
                    remedy = ("%s; nothing was kept - correct the file given with %s%s and run the same exakit "
                              "connect again" % (refused_words(refused), refused[2],
                                                 " (or what --password-stdin read)" if refused[2] == "--password-file" else ""))
                if kind == "region" and no_region_bucket(error) and not reconnect:
                    remedy = no_region_remedy(error, name, first=True)
                if kind in ADDRESS_KINDS:
                    remedy = allow_ip(remedy, kind, self.egress(connector, values)[0])
                command = command_for(kind, name, first=True)
                if isinstance(error, Failure):
                    # A failure that names its own fix keeps it.
                    if error.remedy:
                        raise Failure(str(error), code, kind, remedy=error.remedy, command=error.command or command,
                                      said="%s; %s" % (error, error.remedy))
                    # The kit's own words already say what happened (the route
                    # check); only the driver's raw text needs it restated.
                    raise Failure(str(error), code, kind, remedy=remedy, command=command,
                                  said="%s; %s" % (error, remedy.split("; ", 1)[-1]))
                # A catalog-config failure is said in the kit's words alone: the
                # VM's raw text (in the log and in error) helps nobody here.
                raise Failure(str(error), code, kind, remedy=remedy, command=command,
                              said=remedy if kind == "catalog" else "%s (%s)" % (error, remedy))
            pins = self.pins(connector)
            record = {"schema_version": 1, "id": name, "connector": connector_id,
                      "profile": connector["profile"], "inputs": values, "objects": names,
                      "created_at": self.store.config(name).get("created_at") if reconnect else sources.now()}
            if ca_pem:
                # Kept with the source, so reauth rebuilds the same URL even
                # after the file it came from has moved.
                record["tls_ca"] = ca_pem
            if truststore:
                record["tls_truststore"] = truststore
            if key_path:
                record["key_file"] = key_path
                record["sa_email"] = sa_email
            self.store.save_config(name, record)
            self.store.save_status(name, {"status": "ready", "pins": pins, "tables": len(tables),
                                          "last_check": {"at": sources.now(), "outcome": "ok",
                                                         "evidence": ("metadata and %s" % how) if read else "metadata",
                                                         "empty_tables": empty}})
            self.store.clear_journal(name)
        return {"name": name, "connector": connector_id, "action": "reconnected" if reconnect else "connected",
                "objects": names, "tables": len(tables), "status": "ready",
                "example": example_query(names["schema"], tables), "tips": tips(connector, name, names["schema"]),
                "public_ip": self.egress(connector, values)[0], **({"mapping_draft": drafted} if drafted else {})}

    # --- re-pointing a connected source -------------------------------------------
    # `exakit connect <connector> --name N` for a source N that is connected
    # (not disconnected) updates it in place: when the source moved to a new
    # host, port or database, the recorded inputs stand and what is given
    # replaces them, and VS_<NAME> keeps its name, so saved queries and views
    # keep working. The credential is given again, every time: the database
    # never returns a CONNECTION's password, and changing only its address
    # clears it - measured on Exasol 2026.2.0-nano.8, ALTER CONNECTION X TO
    # '<url>' without USER/IDENTIFIED BY leaves USER_NAME NULL and the password
    # empty. So a re-point never alters a CONNECTION in place: the new address
    # and credential are tried on a pending CONNECTION first, and only then
    # swapped in (the old one renamed aside until the re-point is verified).
    #
    # The journal says how far a re-point got, and holds the inputs from
    # before and after it (never a credential), so an interrupted one is put
    # back - or, once it committed, finished - by the next command on the
    # source (settle): connect, reauth, check, refresh, disconnect, remove.
    # Steps, each marked in the journal before it is taken:
    #   swapped    the CONNECTION renamed aside and the new one created
    #   props_set  the virtual schema's changed properties SET
    #   refreshed  the virtual schema REFRESHed
    #   committed  verified; the record is then written, the old CONNECTION dropped

    @staticmethod
    def previous(names):
        """Where a re-point keeps a source's CONNECTION aside while the new one
        is verified. Outside the EXAKIT_SRC_ names, as the pending trial's are."""
        return dict(names, connection="EXAKIT_PREVIOUS_" + names["connection"])

    def repoint_values(self, connector, old, given):
        """The source's inputs after the re-point, checked as connect checks
        them (a loopback host refused with its advice, a credential given with
        --set refused): the recorded ones with the given ones over them. A
        recorded CA or mapping file is not read again unless it is given anew -
        it may be gone, and what it held was staged with the source when it
        connected."""
        specs = {spec["name"]: spec for spec in connector["inputs"]}
        recorded = dict((key, value) for key, value in old.items() if key in specs)
        unread = dict((key, value) for key, value in recorded.items()
                      if specs[key]["kind"] in REPOINT_FIXED_KINDS and key not in given)
        trimmed = dict(connector, inputs=[spec for spec in connector["inputs"] if spec["name"] not in unread])
        values = planner.validate_inputs(trimmed, dict((k, v) for k, v in dict(recorded, **given).items()
                                                       if k not in unread))
        values.update(unread)
        if values.get("ca") and values.get("tls", "verify") != "verify":
            raise planner.PlanError("ca is used to verify the server, so it needs tls=verify (not %s)" % values["tls"])
        return values

    @staticmethod
    def repoint_extra(config, connector, runtime, name):
        """What the source's URL and properties were built with besides its
        inputs: the CA and truststore it trusts, its key file, its mapping."""
        extra = {"ca_pem": config.get("tls_ca"), "truststore": config.get("tls_truststore"),
                 "key_path": config.get("key_file"), "sa_email": config.get("sa_email")}
        if any(spec["kind"] == "edml" for spec in connector["inputs"]):
            extra["mapping_path"] = runtime.bucket_sql("mappings", name)[len("/buckets"):]
        return extra

    def changed_properties(self, connector, names, before, after, extra):
        """The virtual schema properties that differ between two sets of
        inputs, as (key, value before, value after); "" where one set has none
        (an http URL adds the lakehouse engine's ALLOW_HTTP, say)."""
        old = dict(self.vs_properties(connector, names, before, extra))
        new = dict(self.vs_properties(connector, names, after, extra))
        keys = [k for k in list(old) + [k for k in new if k not in old] if old.get(k) != new.get(k)]
        return [(k, old.get(k, ""), new.get(k, "")) for k in keys]

    @staticmethod
    def where_words(connector, values):
        """Where a source is, as a person reads it: its host and port (a
        cloud store's name), then the database, schema or namespace it reads."""
        place = source_where(connector, values) or connector["id"]
        port = values.get("port")
        if port and place == values.get("host"):
            place = "%s:%s" % (place, port)
        # A lakehouse source's "catalog" is its setting (unity, glue), not a name it reads.
        keys = ("database", "service", "schema", "namespace", "dataset", "collection") if \
            connector.get("settings_chosen") else ("database", "service", "catalog", "schema", "namespace", "dataset",
                                                   "collection")
        scope = [str(values[k]) for k in keys if values.get(k)]
        return "%s (%s)" % (place, "/".join(scope)) if scope else place

    def interrupted_repoint(self, name):
        journal = self.store.journal(name) or {}
        return journal.get("operation") == "repoint"

    def repoint(self, connector_id, name, given, secret, preview=False, secret_given=False):
        if not preview:
            # What an interrupted re-point left is settled first, so what
            # follows is planned from the source as it really is.
            self.settle(name)
        config = self.store.config(name)
        old = dict(config.get("inputs") or {})
        connector = self.defs.connector(connector_id)
        if connector.get("settings"):
            # The combination after the re-point: the recorded settings with
            # any given over them, checked as a connect checks them.
            merged = dict(old, **given)
            connector = self.defs.connector(connector_id, dict(merged, **planner.choose_settings(connector, merged)))
        entry = self.defs.entry(connector_id)
        names = config["objects"]
        values = self.repoint_values(connector, old, given)
        changes = []
        for spec in connector["inputs"]:
            key = spec["name"]
            if spec["kind"] in ("secret", "secret-file") or old.get(key) == values.get(key):
                continue
            changes.append({"input": key, "from": old.get(key), "to": values.get(key)})
        credential = bool(secret) or secret_given
        kinds = dict((spec["name"], spec["kind"]) for spec in connector["inputs"])
        fixed = [c["input"] for c in changes if kinds[c["input"]] in REPOINT_FIXED_KINDS or c["input"] == "tls"]
        if fixed:
            how = ("its mapping is staged for the source: exakit source remove %s, then connect it again with the new "
                   "one" % name) if any(kinds[k] == "edml" for k in fixed) else (
                  "the CA and TLS level are set by the connect that trusted them: exakit source disconnect %s --yes, "
                  "then exakit connect %s --name %s with the new ones and the credential" % (name, connector_id, name))
            raise Failure("%s cannot be changed in place for %s" % (" and ".join(fixed), name), EXIT["input"], "input",
                          remedy="nothing was changed - %s" % how,
                          said="%s cannot be changed in place for %s; nothing was changed - %s" % (
                              " and ".join(fixed), name, how))
        if not changes and not credential:
            return self.repoint_unchanged(connector_id, connector, name, names, values, preview)
        if connector.get("secret_as_file"):
            # Its key is a file the kit staged for the source, read by the
            # driver from the path the CONNECTION names: a re-point cannot
            # swap it as it swaps a CONNECTION, so it is not offered.
            how = ("a new key alone: exakit source reauth %s --password-file <key.json>; another project or dataset: "
                   "exakit source remove %s --yes, then exakit connect %s --name %s with them and the key file"
                   % (name, name, connector_id, name))
            raise Failure("%s cannot be re-pointed in place: its key is a file staged for it" % name, EXIT["input"],
                          "input", remedy="nothing was changed - %s" % how,
                          said="%s cannot be re-pointed in place (its key is a file staged for it); nothing was "
                               "changed - %s" % (name, how))
        extra = self.repoint_extra(config, connector, self.runtime, name)
        props = self.changed_properties(connector, names, old, values, extra)
        if preview:
            return self.repoint_plan(connector_id, connector, entry, name, names, values, changes, props)
        if secret:
            self.require_storage_secret(connector, "re-pointing %s" % name)
        if not secret:
            spec = planner.secret_input(connector) or {"label": "credential"}
            what = spec.get("label", "credential").lower()
            fix = ("give it with --password-file <file> or pipe it in with --password-stdin, then run the same "
                   "exakit connect again")
            raise Failure("re-pointing %s needs its %s again: the database never returns a stored one, and moving a "
                          "CONNECTION clears it" % (name, what), EXIT["input"], "input",
                          remedy="nothing was changed - %s" % fix,
                          said="re-pointing %s needs its %s again (the database never returns a stored one); nothing "
                               "was changed - %s" % (name, what, fix))
        return self.repoint_apply(connector_id, connector, name, names, old, values, changes, secret, extra, props)

    def repoint_unchanged(self, connector_id, connector, name, names, values, preview):
        """The same inputs and no credential: nothing to change and nothing
        sent to the source. The answer says the source's real state - not
        ready is a failure (exit 1), with its fix - and, outside a plan, the
        tables and a first query, as a connect's does (read from the local
        catalog, not the source)."""
        status = self.store.status(name)
        state = status.get("status", "unknown")
        note = ("Nothing to change: %s already reads from %s with these inputs, and no credential was given; %s "
                "stays as it is" % (name, self.where_words(connector, values), names["schema"]))
        result = {"action": "unchanged", "name": name, "connector": connector_id, "objects": names, "status": state,
                  "changes": [], "note": note, "tables": status.get("tables"),
                  "tips": tips(connector, name, names["schema"])}
        if preview:
            if self.interrupted_repoint(name):
                result["interrupted"] = True
                result["warnings"] = ["an earlier re-point of %s was interrupted: exakit connect puts it back before "
                                      "anything else (and so does exakit source check %s)" % (name, name)]
            return result
        try:
            tables = self.tables(names["schema"])
        except (Failure, sql.DbError):
            tables = []
        result["tables"] = len(tables) if tables else status.get("tables")
        result["example"] = example_query(names["schema"], tables)
        if state == "ready":
            self.emit("INFO", note)
            return result
        check = status.get("last_check") or {}
        kind = check.get("kind") or "error"
        result.update(error="%s is %s (its last check: %s); nothing was changed" % (
                          name, state, check.get("evidence") or "none"),
                      kind=kind, remedy=remedy_for(kind, name, connector, check.get("evidence")),
                      command="exakit source check %s" % name)
        self.emit("WARN", "%s; %s is %s - fix: %s" % (note, name, state, result["remedy"]))
        return result

    def repoint_plan(self, connector_id, connector, entry, name, names, values, changes, props):
        """The re-point as data, before any of it happens: what changes, from
        what to what, and that the credential is given again."""
        steps = []
        host = planner.source_host(connector, values)
        if host:
            steps.append("check from inside the database that %s resolves and answers on port %d"
                         % (host, planner.source_port(connector, values)))
        steps += ["try the %s on a pending CONNECTION first - %s is not touched while it is tried"
                  % ("new address with the credential given" if changes else "credential given", names["connection"]),
                  "swap it in for %s, the previous one kept aside until the re-point is verified" % names["connection"]]
        if connector.get("etl") and connector.get("schema_check"):
            steps.insert(1, "check that the source has %s %s and the account may use it"
                         % (connector["schema_check"]["input"], values.get(connector["schema_check"]["input"], "")))
        if props:
            steps.append("set %s's %s" % (names["schema"], ", ".join(k for k, _, _ in props)))
        steps += ["refresh %s in place: it keeps its name, so saved queries and views keep working" % names["schema"],
                  "verify metadata and one bounded read; on any failure everything is put back, the CONNECTION first"]
        warnings = [w for w in [planner.tls_warning(connector, values), entry.get("caveat")] if w]
        plan = {"action": "repoint", "connector": connector_id, "name": name, "tier": entry["tier"],
                "status": entry["status"], "existing": self.store.status(name).get("status", "unknown"),
                "objects": names, "changes": changes, "credential": "required", "downloads": [], "download_bytes": 0,
                "steps": steps, "restart": False, "gate": None,
                "exposure": "the kit's MCP read-only user can read every table of %s (SELECT ANY TABLE)"
                            % names["schema"],
                "warnings": warnings,
                "command": "exakit connect %s --name %s%s" % (connector_id, name, "".join(
                    " --set " + shell_word("%s=%s" % (c["input"], "" if c["to"] is None else c["to"]))
                    for c in changes))}
        if self.interrupted_repoint(name):
            plan["interrupted"] = True
            warnings.append("an earlier re-point of %s was interrupted: it is put back before this one starts" % name)
        ip, where = self.egress(connector, values)
        plan["public_ip"] = ip
        if ip:
            self.emit("INFO", publicip.advice(ip, where))
        return plan

    def repoint_trial(self, connector, names, values, extra, url, user, secret, hidden):
        """The new address and credential tried on a pending CONNECTION, made
        and dropped here, so the source itself is not touched: one statement
        through the loader (and the schema check) for a JDBC source, else a
        throwaway virtual schema on the source's adapter - read too, for a
        document source."""
        db = self.db()
        trial = self.pending(names)
        secrets = [secret] + list(hidden)
        try:
            # What a trial killed part way left (Ctrl-C, a closed lid) goes first.
            self.drop_pending(names)
            self.create_connection(trial, url, user, secret, replace=True, hidden=hidden)
            if connector.get("etl"):
                db.query("SELECT * FROM (IMPORT FROM JDBC AT %s STATEMENT %s)"
                         % (sql.ident(trial["connection"]), sql.literal(connector.get("probe_sql", "SELECT 1"))),
                         secrets=secrets)
                self.check_scope(connector, trial, values)
            else:
                db.execute(self.vs_sql(connector, trial, values, extra), secrets=secrets)
                if any(spec["kind"] == "edml" for spec in connector["inputs"]):
                    for table in self.tables(trial["schema"])[:self.READ_ALL_LIMIT]:
                        db.query("SELECT * FROM %s.%s LIMIT 1" % (sql.ident(trial["schema"]), sql.ident(table)),
                                 secrets=secrets)
        finally:
            self.drop_pending(names)
        self.emit("OK", "The source accepted the credential given at %s" % self.where_words(connector, values))

    def repoint_undo(self, connector, names, done, props, refresh):
        """Put back what a re-point changed: the CONNECTION first - a SET or
        a REFRESH makes the adapter read through it, so done before it is back
        they would read the new address - then the properties, then the table
        list when nothing re-read it. done: the steps taken (swapped,
        props_set, refreshed); props: (key, before, after). The list of what
        could not be put back, empty when the source is as it was."""
        left = []
        if not (done.get("swapped") or done.get("props_set") or refresh):
            return left
        db = self.db()
        live = sql.ident(names["connection"])
        aside = self.previous(names)["connection"]
        if done.get("swapped") and self.exists("connection", aside):
            # Present only once the RENAME happened: before it, the source's
            # own CONNECTION was never touched.
            try:
                db.execute("DROP CONNECTION IF EXISTS %s" % live)
                db.execute("RENAME CONNECTION %s TO %s" % (sql.ident(aside), live))
            except sql.DbError as error:
                self.emit("WARN", "could not put back %s: %s" % (names["connection"], error))
                # The properties and the table list would be read through
                # the wrong CONNECTION: they wait for the next attempt.
                return ["its CONNECTION"] + (["its properties"] if done.get("props_set") else [])
        reread = False
        if done.get("props_set") and props:
            try:
                db.execute("ALTER VIRTUAL SCHEMA %s SET %s" % (sql.ident(names["schema"]), " ".join(
                    "%s = %s" % (key, sql.literal(before)) for key, before, _ in props)))
                reread = True
            except sql.DbError as error:
                left.append("its properties")
                self.emit("WARN", "could not put back the properties of %s: %s" % (names["schema"], error))
        if refresh and not reread and not left:
            try:
                db.execute("ALTER VIRTUAL SCHEMA %s REFRESH" % sql.ident(names["schema"]))
            except sql.DbError as error:
                left.append("its table list")
                self.emit("WARN", "could not read %s's table list again from its previous address: %s"
                          % (names["schema"], error))
        return left

    def repoint_commit(self, name, config, journal):
        """Finish a verified re-point: the record first, then the CONNECTION
        kept aside dropped. True when nothing is left to do."""
        after = journal.get("inputs_after")
        if after and (config.get("inputs") or {}) != after:
            self.store.save_config(name, dict(config, inputs=after))
            self.store.update_status(name, status="ready", repointed_at=sources.now())
        try:
            self.db().execute("DROP CONNECTION IF EXISTS %s" % sql.ident(self.previous(config["objects"])["connection"]))
        except sql.DbError as error:
            self.emit("WARN", "the previous CONNECTION of %s could not be dropped yet (%s); the next exakit command on it "
                              "tries again" % (name, error))
            return False
        return True

    def settle(self, name, tolerate=False):
        """Put back what an interrupted re-point of name left, or finish it
        when it had committed (see the block comment). Raises a Failure when
        something cannot be put back - the journal stays, and the next command
        tries again - unless tolerate (disconnect, remove: they drop it all)."""
        if not self.interrupted_repoint(name):
            return
        with self.store.lock():
            journal = self.store.journal(name)
            if not journal or journal.get("operation") != "repoint":
                return
            config = self.store.config(name)
            connector = self.defs.connector(config["connector"], config.get("inputs") or {})
            names = config["objects"]
            if journal.get("committed"):
                self.emit("INFO", "An earlier re-point of %s was interrupted after it was verified; finishing it" % name)
                if self.repoint_commit(name, config, journal):
                    self.store.clear_journal(name)
                return
            self.emit("INFO", "An earlier re-point of %s was interrupted; putting back what it changed first" % name)
            before = journal.get("inputs_before") or config.get("inputs") or {}
            after = journal.get("inputs_after") or before
            extra = self.repoint_extra(config, connector, self.runtime, name)
            props = self.changed_properties(connector, names, before, after, extra)
            left = self.repoint_undo(connector, names, journal, props,
                                     refresh=bool(journal.get("refreshed") or journal.get("props_set")))
            if not left:
                self.store.clear_journal(name)
                return
            what = " and ".join(left)
            self.record_check(name, "failed", "an interrupted re-point: %s could not be put back" % what)
            if tolerate:
                return
            raise Failure("an earlier re-point of %s was interrupted, and %s could not be put back" % (name, what),
                          EXIT["failed"], "error",
                          remedy="nothing else was changed; see the log (exakit logs), then try again with: exakit "
                                 "source check %s" % name, command="exakit source check %s" % name)

    def repoint_failure(self, error, connector, name, values, old_where, left):
        """The Failure a re-point ends with: what happened, its class and the
        fix, saying that nothing changed - or, when something could not be put
        back, what."""
        kind = self.signed_kind(getattr(error, "kind", "error"), connector)
        code = getattr(error, "code", EXIT["failed"])
        if isinstance(error, sql.DbError):
            code = EXIT["dns"] if kind == "dns" else EXIT["nojava"] if kind == "nojava" else EXIT["failed"]
        if self.language_kind(kind, connector, error) == "norust":
            kind, code = "norust", EXIT["norust"]
        kept = "nothing was changed - %s still reads from %s" % (name, old_where)
        if left:
            kept = ("%s could not be put back after the failure, so %s is recorded as failed and the next exakit "
                    "command on it tries again (exakit source check %s)" % (" and ".join(left), name, name))
        again = "then run the same exakit connect again"
        access = connector.get("access", "read access")
        if isinstance(error, ScopeFailure):
            remedy = "%s; %s" % (error.remedy, kept)
        elif isinstance(error, Failure) and error.remedy:
            remedy = error.remedy if not left else "%s; %s" % (error.remedy, kept)
        else:
            remedy = {
                "auth": "the source at the new address refused the credential given; %s. Correct it, %s"
                        % (kept, again),
                "unreachable": "the new address did not answer from inside the database; %s. Check the host, port, "
                               "firewall and VPN %s, %s" % (kept, LISTEN_ADVICE, again),
                "nohost": "the new host name does not resolve; %s. Check its spelling (a private name may need a "
                          "VPN), %s" % (kept, again),
                "tls": "the new address's certificate or host name did not verify; %s. Fix the server certificate, %s"
                       % (kept, again),
                "denied": "the account signs in but may not read this data at the new address; %s. Grant it what the "
                          "message names (%s), %s" % (kept, access, again),
                "privilege": "the source took the credential, but the account lacks a privilege at the new address; "
                             "%s. Grant it what the message names (%s), %s" % (kept, access, again),
                "missing_or_denied": "the new address answers that the object the message names does not exist for "
                                     "this account; %s. Check that name as the source spells it, or grant the account "
                                     "%s, %s" % (kept, access, again),
                "schema_missing": "the new address has no such namespace that this credential can see; %s. Check it, "
                                  "%s" % (kept, again),
            }.get(kind)
            if kind == "tls":
                specific = tls_remedy(error, connector, self.clock())
                if specific:
                    remedy = "%s; %s" % (kept, specific.replace(
                        "give it with --set ca=<file>", "a CA is given by a reconnect: exakit source disconnect %s "
                        "--yes, then exakit connect %s --name %s --set ca=<file> with the new address and the "
                        "credential" % (name, connector["id"], name)))
            if remedy is None:
                remedy = "%s; %s" % (kept, remedy_text(kind).format(name=name, access=access,
                                                                      store=connector.get("store", "bucket"),
                                                                      warehouse=catalog_warehouse(error)))
            if kind in ADDRESS_KINDS:
                remedy = allow_ip(remedy, kind, self.egress(connector, values)[0])
        return Failure(str(error), code, kind, remedy=remedy, said="%s; %s" % (error, remedy))

    def repoint_apply(self, connector_id, connector, name, names, old, values, changes, secret, extra, props):
        old_where = self.where_words(connector, old)
        url, user, conn_secret, hidden, notes = self.credential(connector, values, secret)
        if url is None:
            url = planner.jdbc_url(connector, values, extra)
        with self.store.lock():
            self.settle(name)
            # Planned from the record read before the lock: another exakit
            # command may have changed the source since, and this re-point,
            # made over the old inputs, would silently undo that.
            current = self.store.config(name)
            if (current.get("inputs") or {}) != old or self.store.status(name).get("status") == "disconnected":
                raise Failure("%s was changed by another exakit command while this one ran" % name, EXIT["conflict"],
                              "conflict", remedy="nothing was changed - run the same exakit connect again: its plan is "
                                                 "made from the source as it is now",
                              said="%s was changed by another exakit command while this one ran; nothing was changed - "
                                   "run the same exakit connect again" % name)
            config = current
            journal = {"operation": "repoint", "connector": connector_id, "started": sources.now(),
                       "inputs_before": old, "inputs_after": values}
            self.store.save_journal(name, journal)
            done = {}

            def mark(flag):
                journal[flag] = True
                self.store.save_journal(name, journal)

            live = sql.ident(names["connection"])
            aside = sql.ident(self.previous(names)["connection"])
            try:
                self.warn_clock()
                # Nothing of the source changes before these: the route, then
                # the new address and credential tried on a pending CONNECTION.
                self.require_route(connector, values, name)
                self.repoint_trial(connector, names, values, extra, url, user, conn_secret, hidden)
                self.db().execute("DROP CONNECTION IF EXISTS %s" % aside)
                # Marked before the RENAME: a kill between the two leaves the
                # journal saying so, and the CONNECTION kept aside is found.
                mark("swapped")
                done["swapped"] = True
                self.db().execute("RENAME CONNECTION %s TO %s" % (live, aside))
                self.create_connection(names, url, user, conn_secret, hidden=hidden)
                self.emit("OK", "Connection %s now holds the new %s (the previous one is kept aside until this is "
                                "verified)" % (names["connection"], "address and credential" if changes else "credential"))
                if props:
                    mark("props_set")
                    self.db().execute("ALTER VIRTUAL SCHEMA %s SET %s" % (sql.ident(names["schema"]), " ".join(
                        "%s = %s" % (key, sql.literal(after)) for key, _, after in props)))
                    done["props_set"] = True
                mark("refreshed")
                self.db().execute("ALTER VIRTUAL SCHEMA %s REFRESH" % sql.ident(names["schema"]))
                done["refreshed"] = True
                tables, read, how, empty = self.verify(connector, names["schema"])
            except (Failure, sql.DbError, artifacts.ArtifactError, planner.PlanError, OSError) as error:
                left = self.repoint_undo(connector, names, done, props, refresh=done.get("refreshed", False))
                failure = self.repoint_failure(error, connector, name, values, old_where, left)
                if left:
                    # Kept: the next command on the source tries again.
                    # "failed", whatever the failure's class: the source is
                    # neither as it was nor as asked.
                    self.record_check(name, "failed", "an unfinished re-point: %s could not be put back"
                                      % " and ".join(left))
                else:
                    self.store.clear_journal(name)
                raise failure
            # Verified: from here on the re-point is finished, not undone.
            mark("committed")
            self.store.save_config(name, dict(config, inputs=values))
            status = self.store.status(name)
            status.pop("needs_refresh", None)
            status.update(status="ready", tables=len(tables), repointed_at=sources.now(),
                          last_check={"at": sources.now(), "outcome": "ok",
                                      "evidence": ("metadata and %s" % how) if read else "metadata",
                                      "empty_tables": empty})
            self.store.save_status(name, status)
            if self.repoint_commit(name, self.store.config(name), journal):
                self.store.clear_journal(name)
        for note in notes:
            self.emit("INFO", note.replace("<name>", name))
        moved_words = "; ".join("%s %s -> %s" % (c["input"], "(none)" if c["from"] is None else c["from"],
                                                 "(none)" if c["to"] is None else c["to"]) for c in changes)
        self.emit("OK", "Re-pointed %s%s with the credential given; %s kept its name (%d table%s)" % (
            name, " (%s)" % moved_words if moved_words else "", names["schema"], len(tables),
            "" if len(tables) == 1 else "s"))
        return {"action": "repointed", "name": name, "connector": connector_id, "objects": names,
                "changes": changes, "credential": "replaced", "tables": len(tables),
                "status": "ready", "example": example_query(names["schema"], tables),
                "tips": tips(connector, name, names["schema"]), "public_ip": self.egress(connector, values)[0]}

    def recover_interrupted(self, name, names):
        """Undo what an interrupted first connect recorded in its journal."""
        journal = self.store.journal(name)
        if not journal or self.store.exists(name):
            return
        created = journal.get("created") or {}
        if not any(created.get(flag) for flag in ("connection", "script", "schema")) and not created.get("files"):
            self.store.clear_journal(name)
            return
        self.emit("INFO", "An earlier connect of %s was interrupted; removing what it created first" % name)
        created.setdefault("files", [])
        self.db()
        self.undo(names, created, name)
        self.store.clear_journal(name)

    def undo(self, names, created, name):
        """Compensate exactly what this attempt created, newest first."""
        db = self._db
        if db is not None:
            for flag, statement in (("schema", "DROP FORCE VIRTUAL SCHEMA %s CASCADE" % sql.ident(names["schema"])),
                                    ("script", "DROP ADAPTER SCRIPT %s.%s" % (sql.ident(names["script_schema"]),
                                                                               sql.ident(names["script"]))),
                                    ("connection", "DROP CONNECTION %s" % sql.ident(names["connection"]))):
                if created.get(flag):
                    try:
                        db.execute(statement)
                    except sql.DbError as error:
                        self.emit("WARN", "could not undo %s: %s" % (flag, error))
                if flag == "script":
                    # Made by this attempt, so no other source shares them yet.
                    # (A journal from before companions names one import_script.)
                    for script in created.get("companions") or \
                            ([created["import_script"]] if created.get("import_script") else []):
                        try:
                            db.execute("DROP SCRIPT %s.%s" % (sql.ident(names["script_schema"]), sql.ident(script)))
                        except sql.DbError as error:
                            self.emit("WARN", "could not undo the script %s: %s" % (script, error))
        if not self.store.exists(name):
            for path in self.store.release(name):
                if path in created["files"] and os.path.isfile(path):
                    os.remove(path)
                    self.prune(os.path.dirname(path))

    def record_check(self, name, outcome, evidence, kind=None):
        status = "ready" if outcome == "ok" else STATUS_FOR.get(kind or "error", "failed")
        self.store.update_status(name, status=status, last_check={"at": sources.now(), "outcome": outcome,
                                                                  "kind": kind, "evidence": evidence})
        return status

    def check(self, name):
        config = self.store.config(name)
        try:
            # An interrupted re-point is put back before the source is read.
            self.settle(name)
        except Failure as error:
            return {"name": name, "status": "failed", "kind": error.kind, "error": str(error),
                    "remedy": error.remedy, "command": error.command}
        # After a kit update, the connector's sources move to what it pins now
        # (exakit source check --all is the step the update names).
        try:
            moved = self.move_forward(config["connector"])
        except (OSError, ValueError, planner.PlanError) as error:
            # A definition this kit no longer reads: the check below says more.
            self.emit("WARN", "Could not compare %s with the %s adapter this kit pins: %s"
                      % (name, config["connector"], error))
            moved = []
        if self.store.status(name).get("status") == "disconnected":
            result = {"name": name, "status": "disconnected", "skipped": True}
            if self.store.status(name).get("needs_refresh"):
                result["needs_refresh"] = True
            return result
        connector = self.defs.connector(config["connector"], config.get("inputs") or {})
        names = config["objects"]
        try:
            self.warn_clock()
            self.require_route(connector, config["inputs"], name)
            self.warn_key_readers(connector, name)
            tables, read, how, empty = self.verify(connector, names["schema"])
        except (Failure, sql.DbError) as error:
            kind = self.language_kind(self.signed_kind(getattr(error, "kind", "error"), connector), connector, error)
            status = self.record_check(name, "failed", str(error), kind)
            remedy = remedy_for(kind, name, connector, error)
            specific = tls_remedy(error, connector, self.clock()) if kind == "tls" else None
            if specific:
                remedy = "%s; then: exakit source check %s" % (specific.replace(
                    "give it with --set ca=<file>", "reconnect with it: exakit source disconnect %s --yes, then "
                    "exakit connect %s --name %s --set ca=<file>" % (name, config["connector"], name)), name)
            if kind in ADDRESS_KINDS:
                remedy = allow_ip(remedy, kind, self.egress(connector, config["inputs"])[0])
            # Said here, not only in the result: a failed check exits 1, and
            # the reason has to reach a reader who gets no RESULT line.
            self.emit("FAIL", "%s is %s: %s" % (name, status, error))
            self.emit("INFO", "Fix: %s" % remedy)
            return {"name": name, "status": status, "kind": kind, "error": str(error), "remedy": remedy,
                    "command": command_for(kind, name)}
        evidence = "metadata and %s (%d tables)" % (how, len(tables)) if read else "metadata only (no tables in scope)"
        self.record_check(name, "ok", evidence)
        result = {"name": name, "status": "ready", "evidence": evidence}
        if empty:
            result["empty_tables"] = empty
        just_moved = name in moved or name in getattr(self, "_moved", ())
        if just_moved:
            result["moved"] = True
        if self.store.status(name).get("needs_refresh"):
            result["needs_refresh"] = True
            if not just_moved:     # a move in this run that failed to refresh has said so
                self.emit("WARN", "%s moved to a new adapter and its metadata is not refreshed yet: exakit source "
                                  "refresh %s" % (name, name))
        return result

    def reauth(self, name, secret):
        self.settle(name)
        config = self.store.config(name)
        if self.store.status(name).get("status") == "disconnected":
            fix = "reconnect it with: exakit connect %s --name %s" % (config["connector"], name)
            raise Failure("%s is disconnected" % name, EXIT["conflict"], "conflict", remedy=fix,
                          said="%s is disconnected; %s" % (name, fix))
        if not secret:
            raise Failure("reauth needs the new credential on standard input", EXIT["input"], "input",
                          remedy="pipe it on standard input or give it with --password-file <file>")
        connector = self.defs.connector(config["connector"], config.get("inputs") or {})
        inputs = dict(config["inputs"])
        # Both secrets of a combination with two: the CONNECTION's JSON is
        # written whole, and the database never returns the one kept.
        self.require_storage_secret(connector, "reauth of %s" % name)
        if connector.get("secret_as_file"):
            return self.reauth_key(name, config, connector, secret)
        if connector.get("credential") and secret.lstrip().startswith("{"):
            # A new credential file names its own key; the recorded key ID is the old one.
            inputs.pop("access_key_id", None)
        url, user, secret, hidden, notes = self.credential(connector, inputs, secret)
        if url is None:
            url = planner.jdbc_url(connector, inputs, {"ca_pem": config.get("tls_ca"),
                                                       "truststore": config.get("tls_truststore")})
        with self.store.lock():
            # Tried before it replaces anything: a typo here must not break a
            # source that still works. The new credential goes into a pending
            # CONNECTION, one trivial statement runs through the loader with
            # it, and only an accepted credential replaces the old one.
            self.try_credential(connector, config["objects"], url, user, secret, inputs, hidden, name)
            try:
                self.create_connection(config["objects"], url, user, secret, replace=True, hidden=hidden)
            except sql.DbError as error:
                raise Failure("the credential could not be replaced: %s" % error, EXIT["failed"])
        self.emit("OK", "Credential replaced in %s" % config["objects"]["connection"])
        for note in notes:
            self.emit("INFO", note.replace("<name>", name))
        return self.check(name)

    def reauth_key(self, name, config, connector, secret):
        """A new key file, tried by the check before it is kept: when the
        source refuses it, the previous file and CONNECTION come back."""
        url, user, text, hidden, notes = self.credential(connector, config["inputs"], secret)
        email = keyfile.service_account(text)[0]
        path = self.key_file(name)
        with open(path, encoding="utf-8") as handle:
            previous = handle.read()
        old_url = planner.jdbc_url(connector, config["inputs"], {"key_path": config["key_file"],
                                                                  "sa_email": config["sa_email"]})
        new_url = planner.jdbc_url(connector, config["inputs"], {"key_path": config["key_file"], "sa_email": email})
        profile = self.defs.profile(connector["profile"])
        with self.store.lock():
            self.write_key(path, text)
            self.await_staged([], [path], profile)
            self.create_connection(config["objects"], new_url, None, None, replace=True, hidden=hidden)
            result = self.check(name)
            if result.get("status") != "ready":
                self.write_key(path, previous)
                self.await_staged([], [path], profile)
                self.create_connection(config["objects"], old_url, None, None, replace=True)
                self.check(name)
                raise Failure("the source refused the new key, so the previous one was kept: %s"
                              % result.get("error", "the check failed"), EXIT["failed"], result.get("kind", "error"))
            config["sa_email"] = email
            self.store.save_config(name, config)
            self.store.add_consumer(path, hashlib.sha256(text.encode("utf-8")).hexdigest(), name, False)
        self.emit("OK", "Key file replaced for %s" % name)
        return result

    @staticmethod
    def pending(names):
        """The objects a reauth tries a new credential through. Named outside
        the kit's EXAKIT_SRC_ and VS_ names: a source may be called
        <name>_pending, and its own CONNECTION and virtual schema must never
        be what a trial for <name> replaces or drops."""
        return dict(names, connection="EXAKIT_PENDING_" + names["connection"],
                    schema="EXAKIT_PENDING_" + names["schema"])

    def drop_pending(self, names):
        """Drop what a reauth trial made, if it is there: after the trial, and
        wherever a trial killed part way may have left it (the next reauth,
        disconnect, remove). The schema goes first and without calling its
        adapter back (FORCE): it runs on the source's adapter script."""
        pending = self.pending(names)
        for statement in ("DROP FORCE VIRTUAL SCHEMA IF EXISTS %s CASCADE" % sql.ident(pending["schema"]),
                          "DROP CONNECTION IF EXISTS %s" % sql.ident(pending["connection"])):
            try:
                self.db().execute(statement)
            except (sql.DbError, Failure):
                pass

    def drop_previous(self, name, names):
        """Drop the CONNECTION a re-point kept aside, if one is there, with
        the journal that names it: disconnect and remove keep no credential."""
        try:
            self.db().execute("DROP CONNECTION IF EXISTS %s" % sql.ident(self.previous(names)["connection"]))
        except (sql.DbError, Failure):
            pass
        if self.interrupted_repoint(name):
            self.store.clear_journal(name)

    def try_credential(self, connector, names, url, user, secret, values=None, hidden=(), name=None):
        if not connector.get("etl"):
            if connector.get("shared_adapter"):
                self.try_through_schema(connector, names, url, user, secret, values or {}, hidden)
            elif any(spec["kind"] == "edml" for spec in connector["inputs"]):
                # A document source (S3, Azure Blob): its own adapter script,
                # over the mapping connect staged for it.
                mapping = self.runtime.bucket_sql("mappings", name)[len("/buckets"):]
                self.try_through_schema(connector, names, url, user, secret,
                                        dict(values or {}, mapping_path=mapping), hidden, read=True)
            return      # no loader driver to try it through (a VALUES connector)
        pending = self.pending(names)
        try:
            self.create_connection(pending, url, user, secret, replace=True, hidden=hidden)
            self.db().query("SELECT * FROM (IMPORT FROM JDBC AT %s STATEMENT %s)"
                            % (sql.ident(pending["connection"]), sql.literal(connector.get("probe_sql", "SELECT 1"))),
                            secrets=[secret] + list(hidden))
        except sql.DbError as error:
            raise Failure("the source refused the new credential, so the previous one was kept: %s" % error,
                          EXIT["failed"], self.language_kind(error.kind, connector, error))
        finally:
            try:
                self.db().execute("DROP CONNECTION IF EXISTS %s" % sql.ident(pending["connection"]))
            except sql.DbError:
                pass
        self.emit("OK", "The source accepted the new credential")

    def try_through_schema(self, connector, names, url, user, secret, values, hidden=(), read=False):
        """A native adapter reads metadata when its virtual schema is created
        (measured: MongoDB with a wrong password fails at CREATE), so a
        throwaway schema on a pending CONNECTION tries the new credential.
        A document adapter reads no object at CREATE when the mapping names
        its fields (measured on S3), so with read the throwaway schema is also
        read - one row from each table, as connect proves a document source."""
        pending = self.pending(names)
        db = self.db()
        secrets = [secret] + list(hidden)
        # What a trial killed part way left (Ctrl-C, a closed lid) goes first.
        self.drop_pending(names)
        try:
            self.create_connection(pending, url, user, secret, replace=True, hidden=hidden)
            db.execute(self.vs_sql(connector, pending, values), secrets=secrets)
            if read:
                for table in self.tables(pending["schema"])[:self.READ_ALL_LIMIT]:
                    db.query("SELECT * FROM %s.%s LIMIT 1" % (sql.ident(pending["schema"]), sql.ident(table)),
                             secrets=secrets)
        except sql.DbError as error:
            raise Failure("the source refused the new credential, so the previous one was kept: %s" % error,
                          EXIT["failed"], self.language_kind(error.kind, connector, error))
        finally:
            self.drop_pending(names)
        self.emit("OK", "The source accepted the new credential")

    def refresh(self, name):
        self.settle(name)
        config = self.store.config(name)
        schema = config["objects"]["schema"]
        try:
            self.db().execute("ALTER VIRTUAL SCHEMA %s REFRESH" % sql.ident(schema))
        except sql.DbError as error:
            connector = self.defs.connector(config["connector"], config.get("inputs") or {})
            raise Failure("the metadata refresh failed: %s" % error, EXIT["failed"],
                          self.language_kind(error.kind, connector, error))
        count = len(self.tables(schema))
        status = self.store.status(name)
        status.pop("needs_refresh", None)
        status.update(tables=count, refreshed_at=sources.now())
        self.store.save_status(name, status)
        return {"name": name, "tables": count}

    def describe(self, name, table="", ddl=False, into=""):
        """The tables and columns of a source as Exasol sees them, read from
        the database's own catalog: nothing reaches the source, so it costs
        nothing there (a Databricks warehouse is not woken) and works for a
        disconnected source too. ddl adds CREATE TABLE statements to make a
        local copy; into names the schema they target."""
        config = self.store.config(name)
        schema = config["objects"]["schema"]
        if into and not re.match(r"^[A-Za-z_][A-Za-z0-9_]{0,127}$", into):
            raise Failure("--schema takes a plain schema name (letters, digits and _), not %r" % into, EXIT["input"])
        if not self.exists("schema", schema):
            raise Failure("the virtual schema %s is gone; create it again from the stored connection with: "
                          "exakit source check %s" % (schema, name), EXIT["failed"])
        rows = self.db().query(
            "SELECT COLUMN_TABLE, COLUMN_NAME, COLUMN_TYPE, COLUMN_IS_NULLABLE FROM SYS.EXA_ALL_COLUMNS "
            "WHERE COLUMN_SCHEMA = %s ORDER BY COLUMN_TABLE, COLUMN_ORDINAL_POSITION" % sql.literal(schema))
        tables = {}
        for row in rows:
            # Nullable unless the catalog says otherwise: a wrong NOT NULL
            # would refuse rows the source holds.
            nullable = row.get("COLUMN_IS_NULLABLE") not in (False, "FALSE", "false", 0)
            tables.setdefault(row["COLUMN_TABLE"], []).append(
                {"name": row["COLUMN_NAME"], "type": row["COLUMN_TYPE"], "nullable": nullable})
        if table:
            # As typed, else ignoring case - but never a guess between two.
            hits = [table] if table in tables else [t for t in tables if t.upper() == table.upper()]
            if len(hits) != 1:
                listed = ", ".join(sorted(tables)) or "none"
                if hits:
                    raise Failure("%s matches %d tables in %s (%s); give it with its exact case"
                                  % (table, len(hits), schema, ", ".join(sorted(hits))), EXIT["input"])
                raise Failure("%s has no table %s (its tables: %s); a table added at the source appears after: "
                              "exakit source refresh %s" % (schema, table, listed, name), EXIT["input"])
            tables = {hits[0]: tables[hits[0]]}
        out = []
        for name_t in sorted(tables):
            entry = {"name": name_t, "columns": tables[name_t]}
            if ddl:
                entry["ddl"] = table_ddl(schema, name_t, tables[name_t], into)
            out.append(entry)
        return {"name": name, "schema": schema, "tables": out}

    # --- moving sources to the adapter the connector pins now -----------------------
    @staticmethod
    def pins(connector):
        """What a source records as running: its connector's adapter and driver pins."""
        driver = connector.get("driver") or {}
        return {"adapter": connector["adapter"]["sha256"], "driver": driver.get("sha256"),
                "adapter_version": connector["adapter"]["version"], "driver_version": driver.get("version")}

    @staticmethod
    def shares_scripts(connector):
        """Every source of the connector runs one adapter script (a native
        adapter bound to its name) or shares companion scripts: re-creating
        one of them moves all of those sources at once."""
        return bool(connector.get("shared_adapter") or connector.get("companions") or connector.get("import_script"))

    def move_forward(self, connector_id, only=None):
        """Move the sources of a connector to the adapter and driver it pins now.

        A kit update can change a connector's pins (connector.json); a source
        connected earlier keeps running what its adapter script names until
        it is moved: the current files staged, its script re-created over
        them, its virtual schema refreshed, the new pins recorded, and the old
        files given up - deleted once no source uses them, and only when the
        kit made them. A script shared by the connector's sources moves them
        all together. `only` limits the move to those names, unless the
        connector shares its scripts. A source already on the current pins is
        left alone, so a second run does nothing. Returns the names moved."""
        connector = self.defs.connector(connector_id)
        current = self.pins(connector)
        shared = self.shares_scripts(connector)
        with self.store.lock():
            stale = []
            for name in self.store.names():
                pins = self.store.status(name).get("pins")
                if self.store.config(name).get("connector") != connector_id or not pins or pins == current:
                    continue
                if only is not None and not shared and name not in only:
                    continue
                stale.append(name)
            if not stale:
                return []
            return self._move(connector, current, stale)

    def _stage_tracked(self, connector, name, created, touched):
        """stage(), noting every path it records this source as a consumer of."""
        record = self.store.add_consumer

        def add(path, digest, consumer, made):
            touched.append(path)
            record(path, digest, consumer, made)
        self.store.add_consumer = add
        try:
            return self.stage(connector, name, created)
        finally:
            del self.store.add_consumer

    def _artifact_file(self, connector, path):
        """A file stage() puts in place for a connector's pins: under its own
        bucket folder, or a jar directly in its loader folder. A source's key,
        mapping or truststore copy, and the loader's settings.cfg, are not."""
        path = os.path.normpath(path)
        if path.startswith(os.path.normpath(self.runtime.bucket_dir(connector["id"])) + os.sep):
            return True
        etl = connector.get("etl")
        return bool(etl) and os.path.basename(path) != "settings.cfg" and \
            os.path.dirname(path) == os.path.normpath(self.runtime.loader_dir(etl["drivername"]))

    def _unstage(self, attempt, made):
        """Give up what one move attempt staged for its source: its consumption
        of the files it added, and those files once unused when this run made them."""
        fresh = [p for p in dict.fromkeys(attempt["touched"]) if p not in attempt["before"]]
        for path in self.store.release_paths(attempt["name"], fresh):
            if path in made and os.path.isfile(path):
                os.remove(path)
                self.prune(os.path.dirname(path))

    @staticmethod
    def _change_words(old, new):
        parts = []
        if old.get("adapter") != new["adapter"]:
            parts.append("adapter %s to %s" % (old.get("adapter_version") or "unknown", new["adapter_version"]))
        if old.get("driver") != new["driver"]:
            parts.append("driver %s to %s" % (old.get("driver_version") or "none", new["driver_version"] or "none"))
        return " and ".join(parts) or "adapter %s to %s" % (old.get("adapter_version"), new["adapter_version"])

    def _move(self, connector, current, stale):
        cid = connector["id"]
        label = self.defs.entry(cid)["name"]
        profile = self.defs.profile(connector["profile"])
        etl = connector.get("etl")
        cfg = os.path.join(self.runtime.loader_dir(etl["drivername"]), "settings.cfg") if etl else None
        cfg_text = None
        if cfg and os.path.isfile(cfg):
            # stage() rewrites the loader's settings.cfg for the new driver;
            # a move that does not happen puts the previous one back.
            with open(cfg, encoding="utf-8") as handle:
                cfg_text = handle.read()
        attempts, made = [], set()

        def give_up(undone):
            for attempt in undone:
                self._unstage(attempt, made)

        def restore_cfg():
            if cfg_text is not None:
                with open(cfg, "w", encoding="utf-8", newline="\n") as handle:
                    handle.write(cfg_text)

        try:
            for name in stale:
                registry = self.store.registry().get("artifacts", {})
                attempt = {"name": name, "touched": [], "created": {"files": []},
                           "before": {p for p, e in registry.items() if name in e.get("consumers", [])}}
                attempts.append(attempt)
                journal = self.store.journal(name)
                emit = self.emit
                if len(attempts) > 1:
                    # The same files for every source: their staging is said once.
                    self.emit = lambda level, text: None if level == "OK" else emit(level, text)
                try:
                    attempt["jars"] = self._stage_tracked(connector, name, attempt["created"], attempt["touched"])
                finally:
                    self.emit = emit
                    made.update(attempt["created"]["files"])
                    # stage() notes what it made in the source's journal, for
                    # an interrupted first connect; a move leaves it as it was.
                    if journal is None:
                        self.store.clear_journal(name)
                    else:
                        self.store.save_journal(name, journal)
            jars = attempts[0]["jars"]
            self.await_staged(jars, sorted(made), profile)
            names = self.store.config(stale[0])["objects"]
            if connector.get("shared_adapter"):
                self.create_script(self.adapter_sql(names, jars, profile))
            for spec in self.companions(connector, profile):
                self.create_script(self.companion_sql(spec, names, jars))
        except (Failure, sql.DbError, artifacts.ArtifactError, planner.PlanError, OSError) as error:
            give_up(attempts)
            restore_cfg()
            self.emit("WARN", "Could not move the %s source%s %s to adapter %s (%s); %s the adapter %s had - retry "
                              "with: exakit source check --all"
                      % (label, "" if len(stale) == 1 else "s", ", ".join(stale), current["adapter_version"], error,
                         "it keeps" if len(stale) == 1 else "they keep", "it" if len(stale) == 1 else "they"))
            return []
        moved = []
        for attempt in attempts:
            name = attempt["name"]
            if not connector.get("shared_adapter"):
                try:
                    self.create_script(self.adapter_sql(self.store.config(name)["objects"], attempt["jars"], profile))
                except (Failure, sql.DbError) as error:
                    give_up([attempt])
                    self.emit("WARN", "Could not move %s to %s adapter %s (%s); it keeps the adapter it had - retry "
                                      "with: exakit source check %s" % (name, label, current["adapter_version"], error, name))
                    continue
            moved.append(attempt)
        if not moved:
            restore_cfg()
            return []
        for attempt in moved:
            name = attempt["name"]
            status = self.store.status(name)
            old = status.get("pins") or {}
            # Recorded before the refresh: the script already runs the new files.
            self.store.update_status(name, pins=current, needs_refresh=True)
            gone = [p for p in attempt["before"] if p not in attempt["touched"] and self._artifact_file(connector, p)]
            for path in self.store.release_paths(name, gone):
                if os.path.isfile(path):
                    os.remove(path)
                    self.prune(os.path.dirname(path))
            self.emit("OK", "Moved %s from %s %s" % (name, label, self._change_words(old, current)))
            if status.get("status") == "disconnected":
                self.emit("INFO", "%s is disconnected: its virtual schema is refreshed when it is connected again "
                                  "(exakit connect %s --name %s)" % (name, cid, name))
                continue
            try:
                self.refresh(name)
            except (Failure, sql.DbError) as error:
                self.emit("WARN", "%s moved, but its virtual schema did not refresh (%s); repair it with: exakit source "
                                  "refresh %s" % (name, error, name))
        names = [attempt["name"] for attempt in moved]
        self._moved = getattr(self, "_moved", set()) | set(names)
        return names

    def disconnect(self, name, dry_run=False):
        config = self.store.config(name)
        connection = config["objects"]["connection"]
        drop = ["CONNECTION %s" % connection]
        if config.get("key_file"):
            # The key file is the credential: a disconnected source keeps none.
            drop.append("the key file %s" % config["key_file"])
        plan = {"name": name, "drop": drop,
                "keep": ["virtual schema %s" % config["objects"]["schema"], "adapter script", "staged files",
                         "the source record (marked disconnected)"],
                "note": "queries on %s fail until it is reconnected; sessions already running are not cancelled, "
                        "and nothing is revoked at the source" % config["objects"]["schema"]}
        if dry_run:
            return plan
        with self.store.lock():
            self.settle(name, tolerate=True)
            if self.exists("connection", connection):
                self.db().execute("DROP CONNECTION %s" % sql.ident(connection))
            # A disconnected source keeps no credential: not even one a reauth
            # killed mid-try left pending, or a re-point kept aside.
            self.drop_pending(config["objects"])
            self.drop_previous(name, config["objects"])
            if config.get("key_file") and os.path.isfile(self.key_file(name)):
                os.remove(self.key_file(name))
            self.store.update_status(name, status="disconnected", disconnected_at=sources.now())
        return plan

    def remove(self, name, dry_run=False):
        config = self.store.config(name)
        names = config["objects"]
        registry = self.store.registry().get("artifacts", {})
        mine = [path for path, entry in registry.items() if name in entry.get("consumers", [])]
        reclaim = [path for path in mine if registry[path].get("owned") and registry[path].get("consumers") == [name]]
        connector = self.defs.connector(config["connector"], config.get("inputs") or {})
        shared = [spec["name"] for spec in self.companions(connector, self.defs.profile(connector["profile"]))]
        last = bool(shared) and not self.import_script_users(config["connector"], name)
        own_adapter = not connector.get("shared_adapter") or last
        # The registry knows this kit home's sources only: the database says
        # which virtual schemas still run a shared script (a lost or another
        # kit home's), and those keep it. When the database cannot say (a
        # dry run with it down too), every shared script is kept.
        mine_vs = (names["schema"], self.pending(names)["schema"])
        kept = []
        if own_adapter:
            users = self.adapter_users(names["script_schema"], names["script"], mine_vs)
            if users is None or users:
                own_adapter = False
                kept.append("adapter script %s.%s (%s)" % (names["script_schema"], names["script"],
                                                          in_use_words(users)))
        if last:
            users = self.companion_users(connector, names, mine_vs)
            if users is None or users:
                last = False
                kept += ["script %s.%s (%s)" % (names["script_schema"], script, in_use_words(users))
                         for script in shared]
        kind = "import script" if connector.get("import_script") else "script"
        family = connector.get("family") or config["connector"]
        plan = {"name": name, "drop": ["virtual schema %s" % names["schema"]] +
                                      (["adapter script %s.%s%s" % (names["script_schema"], names["script"],
                                                                    " (no other %s source uses it)" % family
                                                                    if connector.get("shared_adapter") else "")]
                                       if own_adapter else []) +
                                      (["%s %s.%s (no other %s source uses it)"
                                        % (kind, names["script_schema"], script, family)
                                        for script in shared] if last else []) +
                                      ["CONNECTION %s" % names["connection"]],
                "delete_files": reclaim, "keep_files": [p for p in mine if p not in reclaim],
                "note": "remote data and source accounts are never touched"}
        if kept:
            # Both front ends show keep as "keeps:", as disconnect's. Its
            # adapter's files stay with the script that loads them.
            plan["keep"] = list(kept)
            plan["delete_files"] = [p for p in reclaim if self.per_source_file(p, name)]
            plan["keep_files"] = [p for p in mine if p not in plan["delete_files"]]
        if dry_run:
            return plan
        with self.store.lock():
            self.settle(name, tolerate=True)
            db = self.db()
            connection_present = self.exists("connection", names["connection"])
            if self.exists("schema", names["schema"]):
                # With the CONNECTION gone the adapter cannot be called back to
                # clean up, so the drop skips that callback (FORCE) - for this
                # kit-owned schema only.
                force = "" if connection_present else "FORCE "
                db.execute("DROP %sVIRTUAL SCHEMA %s CASCADE" % (force, sql.ident(names["schema"])))
            # A reauth killed mid-try can leave its trial schema, on this
            # source's adapter script, and its pending credential behind -
            # and a re-point its previous CONNECTION.
            self.drop_pending(names)
            self.drop_previous(name, names)
            # The source's own objects first - its virtual schema, then its
            # CONNECTION - so a shared script kept or refused below never
            # leaves half a source behind.
            if connection_present:
                db.execute("DROP CONNECTION %s" % sql.ident(names["connection"]))
            # A reauth killed mid-try can leave its pending credential behind.
            # An earlier kit named it <connection>_PENDING - the live
            # CONNECTION of a source called <name>_pending, which stays.
            if not self.store.exists(name + "_pending"):
                db.execute("DROP CONNECTION IF EXISTS %s" % sql.ident(names["connection"] + "_PENDING"))
            if own_adapter and self.exists("script", names["script_schema"], names["script"]):
                self.drop_shared("DROP ADAPTER SCRIPT %s.%s" % (sql.ident(names["script_schema"]),
                                                                sql.ident(names["script"])),
                                 "adapter script %s.%s" % (names["script_schema"], names["script"]), kept)
            for script in shared if last else []:
                if self.exists("script", names["script_schema"], script):
                    self.drop_shared("DROP SCRIPT %s.%s" % (sql.ident(names["script_schema"]), sql.ident(script)),
                                     "script %s.%s" % (names["script_schema"], script), kept)
            released = self.store.release(name)
            for path in released:
                if kept and not self.per_source_file(path, name):
                    continue        # a kept script still loads it
                if os.path.isfile(path):
                    os.remove(path)
                    self.prune(os.path.dirname(path))
            self.store.delete_source(name)
            self.drop_kit_schema_if_unused(kept)
            for note in kept:
                self.emit("INFO", "Kept the shared %s" % note)
            if kept:
                plan["keep"] = list(kept)
        return plan

    def per_source_file(self, path, name):
        """A file only this source ever reads: its own mappings folder."""
        own = os.path.join(self.runtime.bucket_dir("mappings", name), "")
        return os.path.abspath(path).startswith(os.path.abspath(own))

    def drop_kit_schema_if_unused(self, kept=None):
        """EXAKIT_VS (the adapters and the DNS probe) goes with the last
        source - when the DATABASE agrees nothing uses it. An empty registry
        is not proof: a lost, reinstalled or other kit home leaves virtual
        schemas on these adapters. So never DROP SCHEMA ... CASCADE: with no
        virtual schema on any of its scripts, each script is dropped by name,
        then the schema alone, which Exasol refuses while anything is left
        in it. Whatever stays is a note in kept (remove reports it), or only
        the run log's (a failed first connect)."""
        if self.store.names() or self._db is None:
            return
        note = (lambda text: kept.append(text)) if kept is not None else \
            (lambda text: self.log.write("INFO", "kept the shared " + text))
        try:
            if self.exists("schema", "EXAKIT_VS"):
                users = self.adapter_users("EXAKIT_VS")
                if users is None or users:
                    note("schema EXAKIT_VS (%s)" % in_use_words(users))
                    return
                for row in self._db.query("SELECT SCRIPT_NAME, SCRIPT_TYPE FROM EXA_ALL_SCRIPTS "
                                          "WHERE SCRIPT_SCHEMA = 'EXAKIT_VS' ORDER BY SCRIPT_NAME"):
                    adapter = "ADAPTER " if str(row.get("SCRIPT_TYPE") or "").upper() == "ADAPTER" else ""
                    self._db.execute("DROP %sSCRIPT %s.%s" % (adapter, sql.ident("EXAKIT_VS"),
                                                              sql.ident(row["SCRIPT_NAME"])))
                self._db.execute("DROP SCHEMA EXAKIT_VS")
        except (Failure, sql.DbError) as error:
            note("schema EXAKIT_VS (the database refused the drop: %s)" % error)
        # The kit's own empty folders go too - exakit/vs and exakit, never the
        # bucket above them (on Personal a bucket directory IS the bucket).
        for folder in (self.runtime.bucket_dir(), os.path.dirname(self.runtime.bucket_dir())):
            try:
                os.rmdir(folder)
            except OSError:
                break

    def prune(self, folder):
        """Remove empty folders the kit made, up to - never including - its roots.

        The roots are the kit's own bucket folder (exakit/vs) and the loader's
        jdbc folder. Climbing past them would remove an empty bucket
        directory, and on Exasol Personal a bucket directory IS the bucket.
        """
        stops = {os.path.normpath(self.runtime.bucket_dir()), os.path.normpath(os.path.join(self.runtime.exa, "jdbc"))}
        folder = os.path.normpath(folder)
        while folder not in stops and any(folder.startswith(stop + os.sep) for stop in stops):
            try:
                os.rmdir(folder)
            except OSError:
                return
            folder = os.path.dirname(folder)

    def listing(self):
        """One row a source. host is where it lives (source_where), tls its TLS
        level (tls_level: null when its connector is no longer defined)."""
        rows = []
        for name in self.store.names():
            config = self.store.config(name)
            status = self.store.status(name)
            try:
                connector = self.defs.connector(config["connector"], config.get("inputs") or {})
            except (OSError, ValueError, planner.PlanError):
                connector = None
            values = config.get("inputs") or {}
            rows.append({"name": name, "connector": config["connector"],
                         "connector_name": (connector or {}).get("label") or config["connector"],
                         "schema": config["objects"]["schema"],
                         "status": status.get("status", "unknown"), "last_check": status.get("last_check"),
                         "needs_refresh": bool(status.get("needs_refresh")),
                         "host": source_where(connector, values), "tls": tls_level(connector, values)})
        return rows

    def show(self, name):
        config = self.store.config(name)
        status = self.store.status(name)
        try:
            connector = self.defs.connector(config["connector"], config.get("inputs") or {})
        except (OSError, ValueError):
            connector = {}
        label = connector.get("label") if connector else None
        if not label:
            try:
                label = self.defs.entry(config["connector"])["name"]
            except (planner.PlanError, KeyError):
                label = config["connector"]
        return {"name": name, "connector": config["connector"], "connector_name": label, "inputs": config["inputs"],
                "objects": config["objects"], "status": status.get("status", "unknown"),
                "pins": status.get("pins"), "needs_refresh": True if status.get("needs_refresh") else None,
                "tables": status.get("tables"), "last_check": status.get("last_check"),
                "journal": self.store.journal(name), "tips": tips(connector, name, config["objects"]["schema"]),
                # The label of a second secret (a lakehouse combination with a
                # catalog login and storage keys): reauth needs both; else null.
                "storage_secret": (planner.storage_secret_input(connector or {}) or {}).get("label")}

    def issues(self, status_filter=None):
        rows = []
        for row in self.listing():
            if row["status"] == "ready" and row["needs_refresh"] and not status_filter:
                rows.append(dict(row, remedy="it moved to a new adapter and its metadata is not refreshed yet: "
                                             "exakit source refresh %s" % row["name"],
                                 command="exakit source refresh %s" % row["name"]))
                continue
            if row["status"] in ("ready", "disconnected"):
                continue
            if status_filter and row["status"] != status_filter:
                continue
            check = row.get("last_check") or {}
            try:
                connector = self.defs.connector(row["connector"], self.store.config(row["name"]).get("inputs") or {})
            except (OSError, ValueError):
                connector = {}
            rows.append(dict(row, remedy=remedy_for(check.get("kind") or "error", row["name"], connector,
                                                                check.get("evidence")),
                             command=command_for(check.get("kind") or "error", row["name"])))
        return rows
