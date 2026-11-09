"""Definitions, input validation and the plan shown before anything changes.

A connector's definition (connectors/<id>/connector.json) is data: its
inputs, pinned artifacts, loader registration, JDBC URL template, TLS modes
and virtual schema properties. Everything a user types is validated here by
kind before it reaches a template, and the templates only ever see validated
values - nothing a user types is interpolated into SQL unchecked.
"""

import base64
import difflib
import ipaddress
import json
import os
import platform
import re

import document
import tlsca

KINDS = {
    "host": re.compile(r"^(?=.{1,253}$)([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$"
                       r"|^\d{1,3}(\.\d{1,3}){3}$|^\[?[0-9A-Fa-f:]+\]?$"),
    "name": re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_$.-]{0,127}$"),
    "account": re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$"),
    "text": re.compile(r"^[^\x00-\x1f'\"\\]{1,128}$"),
    # No dots: a dotted bucket's virtual-hosted name (a.b.s3.<region>.amazonaws.com)
    # does not match the S3 certificate, and path-style access is not offered.
    "s3-bucket": re.compile(r"^(?!xn--)[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$"),
    "aws-region": re.compile(r"^[a-z]{2}(-gov)?-[a-z]+-\d{1,2}$"),
    "aws-key-id": document.KEY_ID,
    "azure-account": document.AZURE_ACCOUNT,
    "azure-container": document.AZURE_CONTAINER,
    # Host list, path and options only: the credentials go into the CONNECTION.
    "mongodb-uri": re.compile(r"^mongodb(\+srv)?://[A-Za-z0-9.,:\[\]_-]+(/[A-Za-z0-9._~%&=?,:/+-]*)?$"),
    "mongo-name": re.compile(r"^[^\x00-\x1f'\"\\$/\s]{1,120}$"),
    # The adapter puts these into a REST query string unencoded and the path
    # into the JDBC URL, so neither may carry & # ? ; or a quote.
    # Glue database names: letters, digits, _ and -; no dot (one database is
    # one NAMESPACE, and the engine refuses a dotted one).
    "glue-database": re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_-]{0,254}$"),
    "databricks-name": re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_-]{0,254}$"),
    "databricks-http-path": re.compile(r"^/sql/1\.0/warehouses/[A-Za-z0-9]{1,64}$|^/sql/protocolv1/o/\d{1,20}/[A-Za-z0-9-]{1,64}$"),
    # The lakehouse engine over an Iceberg REST catalog or Unity Catalog. These
    # go into the CONNECTION's JSON and the NAMESPACE property, never a URL.
    "iceberg-namespace": re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_-]{0,254}(\.[A-Za-z0-9_][A-Za-z0-9_-]{0,254}){0,3}$"),
    "unity-namespace": re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_-]{0,254}\.[A-Za-z0-9_][A-Za-z0-9_-]{0,254}$"),
    "warehouse": re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.:/=+@~-]{0,511}$"),
    # An S3-compatible store's region is any short name (MinIO: us-east-1).
    "storage-region": re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$"),
    "access-key": re.compile(r"^[A-Za-z0-9_.+/=-]{3,128}$"),
}

# URL inputs (check_url): a catalog may be plain http on this computer or a
# private network; a workspace is https only; a storage endpoint has no path.
URL_KINDS = ("catalog-url", "https-url", "endpoint-url")
URL = re.compile(r"^(https?)://(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9.-]+)(?::(\d{1,5}))?(/[A-Za-z0-9._~%/+:=-]*)?$", re.I)
PRIVATE_SUFFIXES = (".internal", ".local", ".lan", ".home.arpa")
SHARED_ADDRESS = ipaddress.ip_network("100.64.0.0/10")   # carrier-grade NAT, Tailscale


def machine_arch():
    """The CPU architecture the database runs on - Exasol Personal runs on the
    host's (an arm64 Mac runs an aarch64 VM). EXAKIT_VS_ARCH overrides it."""
    arch = (os.environ.get("EXAKIT_VS_ARCH") or platform.machine()).lower()
    return {"arm64": "aarch64", "aarch64": "aarch64", "amd64": "x86_64", "x86_64": "x86_64"}.get(arch, arch)


def resolve_arch(pin):
    """A pin with per-architecture assets, as the one for this machine."""
    if not pin or "arch" not in pin:
        return pin
    arch = machine_arch()
    if arch not in pin["arch"]:
        raise PlanError("this connector has no build for %s (only %s)" % (arch, ", ".join(sorted(pin["arch"]))))
    flat = {k: v for k, v in pin.items() if k != "arch"}
    flat.update(pin["arch"][arch])
    return flat


# Inside the database, loopback is the database's own runtime. Measured on
# Exasol Personal (macOS): a UDF reaches the internet, the Mac as 192.168.64.1
# (its resolver's address) and host.containers.internal - which there is the
# launcher's Linux VM, not the Mac. On Linux Podman it is the host itself.
LOOPBACK = ("localhost", "127.0.0.1", "::1", "0.0.0.0", "localhost.localdomain")
LOOPBACK_ADVICE = ("host=localhost would be the database itself, not this computer. For a source running on this "
                   "computer use the address the database sees it at - on macOS 192.168.64.1, on Linux and WSL "
                   "host.containers.internal - and make the source listen on that interface, not only on 127.0.0.1")


def host_scope(host):
    """'loopback' (inside the database: the database itself), 'private' (this
    computer as the database sees it, or a private network) or 'public'."""
    bare = host.strip("[]").lower().rstrip(".")
    if bare in LOOPBACK:
        return "loopback"
    try:
        ip = ipaddress.ip_address(bare)
    except ValueError:
        # A single-label name or a private suffix (host.containers.internal) is
        # not on the internet; any other name is taken to be.
        return "private" if "." not in bare or bare.endswith(PRIVATE_SUFFIXES) else "public"
    if ip.is_loopback or ip.is_unspecified:
        return "loopback"
    if ip.is_private or ip.is_link_local or (ip.version == 4 and ip in SHARED_ADDRESS):
        return "private"
    return "public"


def check_url(name, raw, kind):
    """A URL input as (normalized URL, None) or (None, the problem). A bare
    host is https: plain http is only ever the user's explicit choice, and
    only towards this computer or a private network."""
    if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://[^/?#]*@", raw):
        return None, ("%s carries credentials (user:password@): the key and the secret go into the CONNECTION, "
                      "the secret on standard input" % name)
    if not re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://", raw):
        raw = "https://" + raw
    m = URL.match(raw)
    example = "https://minio.example.com:9000" if kind == "endpoint-url" else "https://catalog.example.com[:port][/path]"
    if not m:
        return None, "%s must be a URL such as %s, not %r" % (name, example, raw)
    scheme, host, port, path = m.group(1).lower(), m.group(2).strip("[]").lower(), m.group(3), (m.group(4) or "").rstrip("/")
    if not KINDS["host"].match(host):
        return None, "%s has a host that is not valid: %r" % (name, host)
    if port and not 0 < int(port) < 65536:
        return None, "%s has a port that is not a port number: %s" % (name, port)
    if kind == "endpoint-url" and path:
        return None, "%s is a scheme, host and port only (e.g. %s), without a path" % (name, example)
    scope = host_scope(host)
    if scope == "loopback":
        return None, ("%s points at %s, which inside the database is the database itself, not this computer. %s"
                      % (name, host, LOOPBACK_ADVICE.split(". ", 1)[1]))
    if scheme == "http" and kind == "https-url":
        return None, "%s must use https: the token would cross the network unencrypted" % name
    if scheme == "http" and scope == "public":
        return None, ("%s is plain http to %s, a public host: the credential and the rows would cross the internet "
                      "unencrypted - use https. Plain http is accepted only for this computer (on macOS "
                      "192.168.64.1, on Linux and WSL host.containers.internal) or a private network" % (name, host))
    netloc = "[%s]" % host if ":" in host else host
    return "%s://%s%s%s" % (scheme, netloc, ":" + port if port else "", path), None


def plain_http(connector, values):
    """Does any URL input of this source use plain http?"""
    return any(spec["kind"] in URL_KINDS and str(values.get(spec["name"], "")).startswith("http://")
               for spec in connector.get("inputs", []))


class PlanError(Exception):
    """Input the plan refuses. remedy and command, when given, are the fix in
    words and the one exakit command that is the fix (--json carries them);
    said is the FAIL line, the message unless the fix belongs in it."""
    def __init__(self, message, code=2, choices=None, remedy=None, command=None, said=None):
        super().__init__(message)
        self.code = code
        self.choices = choices or []
        self.remedy = remedy
        self.command = command
        self.said = said or message


class Definitions(object):
    def __init__(self, root):
        self.root = root
        self.catalog = self._load("catalog.json")

    def _load(self, *parts):
        with open(os.path.join(self.root, *parts), encoding="utf-8") as handle:
            return json.load(handle)

    def entries(self):
        return list(self.catalog["connectors"])

    def entry(self, connector_id):
        for item in self.entries():
            if item["id"] == connector_id:
                return item
        raise PlanError("unknown connector %s" % connector_id)

    def connector(self, connector_id):
        doc = self._load("connectors", connector_id, "connector.json")
        if doc.get("adapter") and "arch" in doc["adapter"]:
            doc["adapter"] = resolve_arch(doc["adapter"])
        return doc

    def profile(self, profile_id):
        return self._load("profiles", profile_id, "profile.json")

    def resolve(self, query):
        """A connector id from a name, an id or an alias; ambiguity is refused with the choices."""
        q = re.sub(r"[\s_]+", "-", (query or "").strip().lower())
        if not q:
            raise PlanError("name a source to connect, for example: exakit connect postgresql",
                            choices=[e["id"] for e in self.entries()],
                            remedy="name one of the choices; every connector with its aliases: exakit source catalog",
                            command="exakit source catalog")
        exact = [e for e in self.entries()
                 if q in [e["id"], e["name"].lower().replace(" ", "-")] + [a.lower() for a in e.get("aliases", [])]]
        if len(exact) == 1:
            return exact[0]["id"]
        partial = [e for e in self.entries()
                   if any(q in key for key in [e["id"], e["name"].lower()] + e.get("aliases", []))]
        if len(partial) == 1:
            return partial[0]["id"]
        if len(partial) > 1:
            raise PlanError("%s matches more than one source" % query, choices=[e["id"] for e in partial],
                            remedy="name one of the choices exactly")
        keys = {}
        for e in self.entries():
            for key in [e["id"], e["name"].lower()] + e.get("aliases", []):
                keys[key] = e["id"]
        close = difflib.get_close_matches(q, list(keys), n=3, cutoff=0.6)
        raise PlanError("no source matches %s" % query, choices=sorted(set(keys[c] for c in close))
                        or [e["id"] for e in self.entries()],
                        remedy="name one of the choices; every connector with its aliases: exakit source catalog",
                        command="exakit source catalog")


def objects(name, connector=None):
    upper = name.upper()
    # A native adapter's entry point is bound to its script name, so its
    # sources share one script under that name (Profile D).
    script = (connector or {}).get("shared_adapter") or "ADAPTER_%s" % upper
    return {"connection": "EXAKIT_SRC_%s" % upper, "schema": "VS_%s" % upper,
            "script_schema": "EXAKIT_VS", "script": script}


def mongo_auth_source(uri):
    """The refusal for a MongoDB URI whose authSource is not admin, else None.
    exasol-mongodb-vs 0.1.3 signs in against admin whatever the URI says (the
    CONNECTION's user and password replace any authSource), so a reader defined
    in another database could never log in: said now, not as a refused login at
    connect. Never quotes the value - it may come from a pasted string."""
    from urllib.parse import unquote
    for segment in str(uri).partition("?")[2].split("&"):
        key, _, value = segment.partition("=")
        if unquote(key).strip().lower() == "authsource" and unquote(value).strip() not in ("", "admin"):
            return ("the MongoDB adapter always signs in against the admin database, so an authSource other than "
                    "admin cannot work: make the reader a user of admin and drop authSource or set it to admin")
    return None


def check_value(spec, raw):
    """One input's value checked by its kind: (value, None), or (None, the problem).

    validate_inputs applies it to every input; the terminal form asks it about
    one answer at a time (cli.py field), so a wrong value is said where it was
    typed, in the same words a scripted connect would get."""
    name, kind = spec["name"], spec["kind"]
    raw = str(raw).strip()
    if kind == "port":
        if not raw.isdigit() or not 0 < int(raw) < 65536:
            return None, "%s must be a port number, not %r" % (name, raw)
    elif kind == "choice":
        if raw not in spec["choices"]:
            return None, "%s must be one of %s, not %r" % (name, ", ".join(spec["choices"]), raw)
    elif kind == "ca-file":
        raw = os.path.abspath(os.path.expanduser(raw))
        try:
            tlsca.certificates(raw)
        except tlsca.CaError as error:
            return None, str(error)
    elif kind == "edml":
        raw = os.path.abspath(os.path.expanduser(raw))
        try:
            document.load_mappings(raw)
        except document.DocumentError as error:
            return None, str(error)
    elif kind == "mongodb-uri" and "@" in raw.split("://", 1)[-1].split("/", 1)[0]:
        return None, ("the MongoDB URI carries credentials (user:password@): give the user with --set user=... "
                      "and the password on standard input, so the database keeps it hidden")
    elif kind in URL_KINDS:
        raw, problem = check_url(name, raw, kind)
        if problem:
            return None, problem
    elif kind == "unity-namespace" and not KINDS[kind].match(raw):
        return None, "%s must be catalog.schema, e.g. main.sales (not %r)" % (name, raw)
    elif kind == "s3-bucket" and "." in raw:
        return None, ("bucket %s has dots: its HTTPS name does not match the S3 certificate, and the kit "
                      "reads only over verified HTTPS" % raw)
    elif kind in KINDS and not KINDS[kind].match(raw):
        return None, "%s=%r is not a valid %s" % (name, raw, kind)
    if kind == "aws-region" and raw.startswith("cn-"):
        return None, "the China regions use other endpoints, which this connector does not reach"
    if kind == "mongodb-uri" and mongo_auth_source(raw):
        return None, mongo_auth_source(raw)
    if kind == "host" and raw.strip("[]").lower() in LOOPBACK:
        return None, LOOPBACK_ADVICE
    if kind == "host":
        # Stored bare; jdbc_url adds the brackets an IPv6 literal needs in
        # a URL, and the route probe resolves the bare form.
        raw = raw.strip("[]")
    return (raw.upper() if spec.get("upper") else raw), None


def validate_inputs(connector, given):
    """Defaults applied, every value checked by kind; secrets are not taken here."""
    values, problems = {}, []
    known = {spec["name"] for spec in connector["inputs"]}
    for key in given:
        if key not in known:
            problems.append("%s is not an input of %s (inputs: %s)" % (key, connector["id"], ", ".join(sorted(known))))
    for spec in connector["inputs"]:
        name, kind = spec["name"], spec["kind"]
        if kind in ("secret", "secret-file"):
            continue
        raw = given.get(name)
        if raw is None or raw == "":
            if "default" in spec:
                raw = spec["default"]
            elif spec.get("required"):
                problems.append("%s is required (%s)" % (name, spec.get("label", name)))
                continue
            else:
                continue
        value, problem = check_value(spec, raw)
        if problem:
            problems.append(problem)
            continue
        values[name] = value
    if values.get("ca") and values.get("tls", "verify") != "verify":
        # A CA only means something to a check; with require or disable it
        # would read as protection that is not there.
        problems.append("ca is used to verify the server, so it needs tls=verify (not %s)" % values["tls"])
    if problems:
        raise PlanError("; ".join(problems))
    return values


def secret_input(connector):
    for spec in connector["inputs"]:
        if spec["kind"] in ("secret", "secret-file"):
            return spec
    return None


def source_host(connector, values):
    if connector.get("host_from"):
        # The host of a URL input (a catalog's): the route check probes it.
        m = URL.match(str(values.get(connector["host_from"], "")))
        return m.group(2).strip("[]") if m else ""
    template = connector.get("host") or "{host}"
    try:
        return template.format(**values)
    except KeyError:
        return ""


def reached_hosts(connector, values):
    """Every host a source is reached at, as given: its host (a template's, or
    the host of the URL input it names), the host of any other URL input (a
    storage endpoint) and each host of a MongoDB URI. Empty when it names none."""
    hosts = [source_host(connector, values)]
    for spec in connector.get("inputs", []):
        raw = str(values.get(spec["name"]) or "")
        if not raw:
            continue
        if spec["kind"] in URL_KINDS:
            m = URL.match(raw)
            if m:
                hosts.append(m.group(2))
        elif spec["kind"] == "mongodb-uri":
            for item in raw.split("://", 1)[-1].split("/", 1)[0].split(","):
                hosts.append(item[1:item.find("]")] if item.startswith("[") else item.split(":", 1)[0])
    seen = []
    for host in hosts:
        host = host.strip("[]")
        if host and host not in seen:
            seen.append(host)
    return seen


def public_host(connector, values):
    """The first host of this source that is on the internet, or None when every
    one is this computer or a private network (host_scope). A source on the
    internet sees the database's traffic come from this computer's public IP, so
    that is the address its firewall or IP access list must allow.

    One rule for every connector, read from its connector.json: the hosts a
    host-based source names, and the fixed host a cloud store's template builds
    (S3, Azure, Snowflake, BigQuery, Glue) - all public. An Iceberg REST catalog
    or an S3-compatible endpoint on this computer or a private network is not;
    one with no endpoint is judged by its catalog alone, since the storage it
    vends is not known before it is asked."""
    for host in reached_hosts(connector, values):
        if host_scope(host) == "public":
            return host
    return None


def source_port(connector, values):
    if connector.get("host_from"):
        m = URL.match(str(values.get(connector["host_from"], "")))
        if m and m.group(3):
            return int(m.group(3))
        return 80 if m and m.group(1).lower() == "http" else 443
    return int(values.get("port") or 443)


def jdbc_url(connector, values, extra=None):
    """The source's JDBC URL. extra["ca_pem"] is the one certificate chosen
    from the `ca` input (tlsca.choose); with it, verify trusts that CA."""
    fields = dict(values)
    if ":" in fields.get("host", ""):
        fields["host"] = "[%s]" % fields["host"]
    fields.update(extra or {})
    if connector.get("tls"):
        if fields.get("ca_pem") and connector.get("tls_ca"):
            if connector.get("ca_encoding") == "base64-bundle":
                # The whole bundle, base64: ojdbc 23 reads a PEM wallet from a
                # data: URI (wallet_location=data:;base64,...), trust-only.
                value = base64.b64encode(fields["ca_pem"].encode("ascii")).decode("ascii")
            else:
                value = tlsca.url_value(fields["ca_pem"])
            fields["tls"] = connector["tls_ca"].format(**dict(fields, ca_pem=value))
        elif fields.get("truststore") and connector.get("tls_truststore"):
            fields["tls"] = connector["tls_truststore"].format(**fields)
        elif fields.get("ca_pem") and connector.get("tls_class"):
            fields["tls"] = connector["tls_class"].format(tls_arg=tlsca.class_arg(values["host"], fields["ca_pem"]))
        else:
            fields["tls"] = connector["tls"][values.get("tls", "verify")].format(**fields)
    # An optional input adds its parameter only when given ({opt_<input>} in
    # the template): an empty role= would ask the driver for a role named "".
    for key, fragment in (connector.get("url_optional") or {}).items():
        fields["opt_" + key] = fragment.format(**fields) if fields.get(key) else ""
    return connector["url"].format(**fields)


def tls_warning(connector, values):
    if plain_http(connector, values):
        return ("plain http: the catalog token or storage keys and the rows cross the network unencrypted "
                "(accepted for this computer or a private network only)")
    mode = values.get("tls")
    if mode == "require":
        return "TLS encrypts the connection but does NOT check the server's identity"
    if mode == "disable":
        return "TLS is off: credentials and rows cross the network unencrypted"
    return None


def describe(defs, connector_id, name, values, runtime, cache, store):
    """The plan, as data: what is downloaded, staged, created - before any of it happens."""
    connector = defs.connector(connector_id)
    entry = defs.entry(connector_id)
    names = objects(name, connector)
    profile = defs.profile(connector["profile"])
    downloads = []
    for role in ("adapter", "trust", "driver"):
        pin = connector.get(role)
        if not pin:
            continue
        downloads.append({"role": role, "asset": pin["asset"], "version": pin["version"], "bytes": pin["size"],
                          "cached": cache.has(pin), "license": pin["license"]})
    if profile["slc"]["language"] == "rust":
        steps = ["verify the Rust language container in the database (exakit connect installs it with your "
                 "consent: %s %s, one restart)" % (profile["slc"]["custom"]["upstream"], profile["slc"]["custom"]["version"])]
    else:
        steps = ["verify Java and its DNS in the database (resolve %s)" % (source_host(connector, values) or "the source")]
    if connector.get("etl"):
        steps.append("register loader driver %s" % connector["etl"]["drivername"])
    if values.get("ca"):
        count = len(tlsca.certificates(values["ca"]))
        if connector.get("tls_truststore"):
            how = "%d certificate%s, in a truststore for the adapter and the loader" % (count, "" if count == 1 else "s")
        elif connector.get("ca_encoding") == "base64-bundle":
            how = "%d certificate%s, as a wallet inside the connection" % (count, "" if count == 1 else "s")
        elif connector.get("tls_class"):
            how = ("%d certificate%s, checked with the host name by the kit's TLS helper class"
                   % (count, "" if count == 1 else "s"))
        elif count == 1:
            how = "1 certificate"
        else:
            how = ("%d certificates; a verified handshake from this computer picks the one that signs %s"
                   % (count, source_host(connector, values)))
        steps.append("trust the CA in %s for this source only (%s)" % (values["ca"], how))
    if values.get("mapping"):
        tables = document.load_mappings(values["mapping"])
        steps += ["stage the mapping from %s (%d mapped table%s: %s)" % (values["mapping"], len(tables),
                                                                "" if len(tables) == 1 else "s",
                                                                ", ".join(t["table"] for t in tables)),
                  "create CONNECTION %s (the credential as JSON, inside the database only)" % names["connection"],
                  "create adapter script %s.%s and its import script %s.%s"
                  % (names["script_schema"], names["script"], names["script_schema"], connector["import_script"]),
                  "create virtual schema %s" % names["schema"],
                  "verify every table with a bounded read"]
    elif profile["adapter_script"].get("language") == "LUA":
        steps += ["create CONNECTION %s (the token as its password, inside the database only)" % names["connection"],
                  "create Lua adapter script %s.%s: upstream's file unchanged, plus the kit's check of the REST "
                  "API's certificate and host name against the pinned CA bundle (upstream turns it off)"
                  % (names["script_schema"], names["script"]),
                  "create virtual schema %s" % names["schema"],
                  "verify metadata and one bounded read"]
    elif connector.get("companions"):
        steps += ["create CONNECTION %s%s" % (names["connection"], " (the credential as JSON, inside the database only)"
                                              if connector.get("credential") else ""),
                  "create adapter script %s.%s and its scripts %s (shared by every %s)"
                  % (names["script_schema"], names["script"],
                     ", ".join("%s.%s" % (names["script_schema"], s["name"]) for s in connector["companions"]),
                     connector.get("shared_by") or "%s source" % connector["name"]),
                  "create virtual schema %s" % names["schema"],
                  "verify metadata and one bounded read"]
    elif connector.get("shared_adapter"):
        steps += ["create CONNECTION %s" % names["connection"],
                  "create adapter script %s.%s and its scan UDF %s.%s (shared by every %s source)"
                  % (names["script_schema"], names["script"], names["script_schema"], connector["import_script"],
                     connector["name"]),
                  "create virtual schema %s" % names["schema"],
                  "verify metadata and one bounded read"]
    else:
        steps += ["create CONNECTION %s" % names["connection"],
                  "create adapter script %s.%s" % (names["script_schema"], names["script"]),
                  "create virtual schema %s" % names["schema"],
                  "verify metadata and one bounded read"]
    plan = {
        "connector": connector_id, "name": name, "tier": entry["tier"], "status": entry["status"],
        "objects": names, "downloads": downloads, "steps": steps,
        "download_bytes": sum(d["bytes"] for d in downloads if not d["cached"]),
        "exposure": "the kit's MCP read-only user can read every table of %s (SELECT ANY TABLE)" % names["schema"],
        "restart": False,
        "warnings": [w for w in [tls_warning(connector, values), entry.get("caveat")] if w],
        "gate": entry.get("gate") if entry["status"] == "gated" else None,
    }
    if store.exists(name):
        plan["existing"] = store.status(name).get("status", "unknown")
    return plan
