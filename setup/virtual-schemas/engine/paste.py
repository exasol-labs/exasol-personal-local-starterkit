"""A pasted connection string, read into a connector's inputs.

`exakit connect <connector> --url <string>` hands the string to
`cli.py paste CONNECTOR` on standard input - never as an argument, since a
string often carries a password. What it names becomes the connector's
inputs, each checked by plan.check_value as if it had been typed with --set;
the shell puts them before the command line's own --set pairs, so those win.

The connector's "paste" block in connector.json says which strings it reads:

    schemes    the prefixes before "://" it accepts (jdbc:postgresql, postgres)
    style      url (the default), oracle, mongodb, s3, azure or glue
    bare       true: a plain host[:port][/path] is read as well
    host       the input the host fills (default host); host_suffix, when set,
               must end the host and is cut off it (Snowflake's account)
    path       the input the first path segment fills
    endpoint   "skip": what comes before the first ";" is not read (BigQuery)
    params     parameter (lower case) -> input, earlier entries winning
    map        parameter -> {its value (lower case) -> the input's value, or
               null for "consumed, no change"}
    implied    parameters the kit sets itself: consumed without a note
    secret     more parameter names that carry a credential
    tls        a named rule over several parameters (sqlserver)
    instance   the refusal for a SQL Server named instance (host\\instance)
    forms      the accepted forms, for the message that refuses another one

A credential in the string - user:password@, or a parameter named like one -
is never used, stored or echoed: a note says it was ignored and asked for
separately. Every other parameter the kit does not read is dropped by name
(never by value). Messages never quote the string.
"""

import re

from urllib.parse import unquote

import plan as planner

# A parameter whose name holds one of these is a credential.
SECRET_WORDS = ("password", "passwd", "pwd", "secret", "token", "sig", "signature", "credential", "key")
# Only a name that looks like one is ever echoed; anything else might be a
# piece of a password that was pasted without its percent-encoding.
PARAM_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_.-]{0,63}$")
BARE = re.compile(r"^[A-Za-z0-9.\-_\[\]:%@\\]+(/[^;?#]*)?$")

SECRET_NOTE = ("The connection string held a credential (a password, token or key): it was not used. The "
               "credential is asked for separately (hidden prompt, --password-file or standard input) and kept "
               "only inside the database. The string was on the command line, where other local users and the "
               "shell history can see it - if this computer is shared, change that credential.")


def _first(text, chars):
    """The index of the first of chars in text, or len(text)."""
    found = [text.find(c) for c in chars if c in text]
    return min(found) if found else len(text)


class Reading(object):
    def __init__(self, connector, block):
        self.connector = connector
        self.block = block
        self.specs = {s["name"]: s for s in connector["inputs"] if s["kind"] not in ("secret", "secret-file")}
        self.values = {}
        self.events = []
        self.dropped = []
        self.secret = False

    def refuse(self, why):
        raise planner.PlanError(why)

    def not_a_form(self):
        forms = self.block.get("forms") or []
        self.refuse("the kit does not read this as a %s connection string%s" % (
            self.connector["name"], "; it reads: " + ", ".join(forms) if forms else ""))

    def put(self, name, value):
        """The first value an input gets is kept; an empty one is no value."""
        if name in self.specs and name not in self.values and value not in (None, ""):
            self.values[name] = value

    def note(self, level, text):
        self.events.append((level, text))

    def drop(self, name):
        self.dropped.append(name)

    def is_secret(self, name):
        low = name.lower()
        if low.endswith(("path", "file")):
            return False  # where a key is, not the key: OAuthPvtKeyPath
        return low in [s.lower() for s in self.block.get("secret", [])] or any(w in low for w in SECRET_WORDS)

    def userinfo(self, info, separator=":"):
        user, sep, password = info.partition(separator)
        if sep and password:
            self.secret = True
        self.put("user", unquote(user).strip())

    def host_port(self, authority):
        if not authority:
            return
        if "\\" in authority and self.block.get("instance"):
            self.refuse(self.block["instance"])
        if "," in authority:
            self.refuse("the connection string names more than one host; give the one to use with --set host=...")
        if authority.startswith("["):
            end = authority.find("]")
            if end < 0:
                self.not_a_form()
            host, rest = authority[1:end], authority[end + 1:]
            port = rest[1:] if rest.startswith(":") else ""
        elif authority.count(":") == 1:
            host, port = authority.split(":")
        else:
            host, port = authority, ""
        host = unquote(host).strip()
        suffix = self.block.get("host_suffix")
        if suffix:
            if not host.lower().endswith(suffix) or len(host) == len(suffix):
                self.refuse("the host is not <account>%s" % suffix)
            host = host[:-len(suffix)]
        self.put(self.block.get("host", "host"), host)
        if port:
            self.put("port", port)

    def params(self, pairs):
        """pairs: (name, value) in the string's order. Mapped ones fill inputs,
        the rest are credentials, implied, or dropped by name."""
        found = {}
        names = {}
        for name, value in pairs:
            if not name:
                continue
            found[name.lower()] = value
            names.setdefault(name.lower(), name)
        if self.block.get("instance") and ("instancename" in found or "\\" in found.get("servername", "")):
            self.refuse(self.block["instance"])
        rule = self.block.get("tls")
        if rule:
            RULES[rule](self, found)
        mapping = self.block.get("params", {})
        for param, target in mapping.items():
            if param not in found:
                continue
            value = found[param]
            table = self.block.get("map", {}).get(param)
            if table is not None and value != "":
                if value.lower() not in table:
                    spec = self.specs.get(target, {})
                    self.note("INFO", "%s has a value the kit does not map; %s stays as asked (default %s)"
                              % (names[param], target, spec.get("default", "none")))
                    continue
                value = table[value.lower()]
                if value is None:
                    continue
            if self.specs.get(target, {}).get("kind") == "databricks-http-path" and value and not value.startswith("/"):
                value = "/" + value
            self.put(target, value)
        implied = [p.lower() for p in self.block.get("implied", [])]
        for low, name in names.items():
            if low in mapping or low in implied or low in CONSUMED.get(rule, ()):
                continue
            if self.is_secret(name):
                self.secret = True
            self.drop(name)

    def result(self):
        values = {}
        for name in [s["name"] for s in self.connector["inputs"]]:
            if name not in self.values:
                continue
            value, problem = planner.check_value(self.specs[name], self.values[name])
            if problem:
                if problem != planner.LOOPBACK_ADVICE:
                    # Not quoted: a password pasted without its percent-encoding
                    # can be misread as a host or a port.
                    problem = "it is not a valid %s" % self.specs[name]["kind"]
                self.note("WARN", "%s from the connection string is not used: %s" % (name, problem))
                continue
            values[name] = value
        notes = []
        if self.secret:
            notes.append(("WARN", SECRET_NOTE))
        shown = [n for n in self.dropped if PARAM_NAME.match(n) and not self.is_secret(n)]
        hidden = len([n for n in self.dropped if not PARAM_NAME.match(n)])
        if shown:
            notes.append(("INFO", "Not used from the connection string: %s (settings the kit makes itself or does "
                                  "not offer)" % ", ".join(shown)))
        if hidden:
            notes.append(("INFO", "%d more part%s of the connection string could not be read and %s not used"
                                  % (hidden, "" if hidden == 1 else "s", "was" if hidden == 1 else "were")))
        notes = notes + self.events
        if values:
            notes.append(("INFO", "From the connection string: %s" % ", ".join(sorted(values))))
        return {"values": values, "notes": [text for _, text in notes],
                "dropped": [n if PARAM_NAME.match(n) else "?" for n in self.dropped], "events": notes}


# --- the parameters a rule reads together -------------------------------------

def tls_sqlserver(reading, found):
    """encrypt and trustServerCertificate together: true with a trusted
    certificate is require, true or strict is verify, false is disable."""
    encrypt, trust = found.get("encrypt"), (found.get("trustservercertificate") or "").lower()
    if encrypt is None and not trust:
        return
    mode = {"true": "on", "yes": "on", "mandatory": "on", "strict": "strict",
            "false": "off", "no": "off", "optional": "off"}.get((encrypt or "true").lower())
    if mode is None:
        reading.note("INFO", "encrypt has a value the kit does not map; tls stays as asked (default verify)")
    elif mode == "off":
        reading.put("tls", "disable")
    elif mode == "strict":
        reading.put("tls", "verify")
    elif trust in ("true", "yes"):
        reading.put("tls", "require")
    elif encrypt is not None:
        reading.put("tls", "verify")


RULES = {"sqlserver": tls_sqlserver}
CONSUMED = {"sqlserver": ("encrypt", "trustservercertificate")}


# --- the styles -----------------------------------------------------------------

def split_tail(reading, tail):
    """userinfo@authority/path;k=v;k=v?k=v&k=v, the userinfo applied:
    (authority, path, [(name, value)], [raw query segments])."""
    cut = _first(tail, ";?")
    at = tail.rfind("@", 0, cut)
    if at < 0 and "@" in tail[cut:]:
        # user:pa?ss@host - a password with an unencoded ? or ; reads as a
        # query; host:5432?user=me@example.com does not.
        head = tail[:tail.find("@")]
        colon = head.find(":")
        if colon >= 0 and "/" not in head and not tail[colon + 1:cut].isdigit():
            reading.refuse("the connection string could not be read: a password with characters such as ? ; / or # "
                           "must be percent-encoded - better, leave the password out of the string")
    if at >= 0:
        reading.userinfo(tail[:at])
        tail = tail[at + 1:]
    tail = tail.split("#", 1)[0]
    if reading.block.get("endpoint") == "skip":
        authority, path, tail = "", "", tail[_first(tail, ";"):]
    else:
        cut = _first(tail, "/;?")
        authority, tail = tail[:cut], tail[cut:]
        path = ""
        if tail.startswith("/"):
            cut = _first(tail, ";?")
            path, tail = tail[1:cut], tail[cut:]
    query_at = tail.find("?")
    semi, query = (tail[:query_at], tail[query_at + 1:]) if query_at >= 0 else (tail, "")
    pairs, raw = [], []
    for segment in semi.split(";"):
        if segment.strip():
            name, _, value = segment.partition("=")
            pairs.append((unquote(name).strip(), unquote(value).strip()))
    for segment in query.split("&"):
        if segment.strip():
            name, _, value = segment.partition("=")
            pairs.append((unquote(name).strip(), unquote(value).strip()))
            raw.append(segment)
    return authority, path, pairs, raw


def scheme_tail(reading, text):
    """What follows "<scheme>://" for an accepted scheme; the text itself for
    a bare host when the connector reads one; else a refusal."""
    low = text.lower()
    for scheme in reading.block.get("schemes", []):
        if low.startswith(scheme.lower() + "://"):
            return scheme.lower(), text[len(scheme) + 3:]
    if reading.block.get("bare") and "://" not in text and not low.startswith("jdbc:") and BARE.match(text):
        return "", text
    reading.not_a_form()


def style_url(reading, text):
    _, tail = scheme_tail(reading, text)
    authority, path, pairs, _ = split_tail(reading, tail)
    reading.host_port(authority)
    if reading.block.get("path") and path:
        reading.put(reading.block["path"], unquote(path.split("/")[0]).strip())
    reading.params(pairs)


def style_oracle(reading, text):
    low = text.lower()
    if low.startswith("jdbc:oracle:thin:"):
        rest = text[len("jdbc:oracle:thin:"):]
        at = rest.rfind("@")
        if at < 0:
            reading.not_a_form()
        if rest[:at]:
            reading.userinfo(rest[:at], "/")
        desc = rest[at + 1:].strip()
    elif reading.block.get("bare") and "://" not in text and not low.startswith("jdbc:"):
        desc = text
    else:
        reading.not_a_form()
    if desc.startswith("("):
        reading.refuse("a TNS descriptor (DESCRIPTION=...) is not read; give host, port and service with "
                       "--set host=... --set port=... --set service=...")
    plain = True
    for prefix, tls in (("tcps://", "verify"), ("tcp://", None), ("//", None)):
        if desc.lower().startswith(prefix):
            desc = desc[len(prefix):]
            if tls:
                plain = False
                reading.put("tls", tls)
            break
    desc, _, query = desc.partition("?")
    authority, slash, service = desc.partition("/")
    if not slash and authority.count(":") == 2 and not authority.startswith("["):
        reading.refuse("the connection string names an Oracle SID (host:port:SID); the kit connects by service "
                       "name - give it with --set service=... (SELECT value FROM v$parameter WHERE name = "
                       "'service_names')")
    reading.host_port(authority)
    reading.put("service", re.split(r"[:/]", service)[0].strip())
    pairs = []
    for segment in query.split("&"):
        if segment.strip():
            name, _, value = segment.partition("=")
            pairs.append((unquote(name).strip(), value))
    reading.params(pairs)
    if plain and "tls" in reading.specs:
        reading.note("INFO", "The connection string uses plain TCP; tls stays at verify (TCPS, the kit's default). "
                             "If the listener offers no TCPS, connect with --set tls=disable.")


def style_mongodb(reading, text):
    scheme, tail = scheme_tail(reading, text)
    authority, path, pairs, raw = split_tail(reading, tail)
    if not authority:
        reading.not_a_form()
    reading.put("database", unquote(path.split("/")[0]).strip())
    kept = []
    for segment in raw:
        name = unquote(segment.partition("=")[0]).strip()
        if reading.is_secret(name):
            reading.secret = True
            reading.drop(name)
        else:
            kept.append(segment)
    reading.put("uri", "%s://%s%s" % (scheme, authority, "/?" + "&".join(kept) if kept else ""))


def style_s3(reading, text):
    low = text.lower()
    for scheme in ("s3://", "s3a://", "s3n://"):
        if low.startswith(scheme):
            bucket, _, key = text[len(scheme):].partition("/")
            reading.put("bucket", bucket.strip())
            break
    else:
        if not low.startswith("https://"):
            reading.not_a_form()
        tail = text[len("https://"):].split("#", 1)[0]
        tail, _, query = tail.partition("?")
        host, _, key = tail.partition("/")
        host = host.lower().split(":")[0]
        if query:
            reading.secret = True
        virtual = re.match(r"^(.+)\.s3(?:[.-]dualstack)?(?:[.-]([a-z0-9-]+))?\.amazonaws\.com$", host)
        path_style = re.match(r"^s3(?:[.-]dualstack)?(?:[.-]([a-z0-9-]+))?\.amazonaws\.com$", host)
        if path_style:
            bucket, _, key = key.partition("/")
            reading.put("bucket", bucket)
            region = path_style.group(1)
        elif virtual:
            reading.put("bucket", virtual.group(1))
            region = virtual.group(2)
        else:
            reading.not_a_form()
        if region:
            reading.put("region", region)
    if key.strip("/"):
        reading.note("INFO", "The path after the bucket is not used: the mapping names the files to read.")


def style_azure(reading, text):
    low = text.lower()
    if "://" not in text and "accountname=" in low:
        # A storage connection string: AccountName=...;AccountKey=...
        pairs = []
        for segment in text.split(";"):
            if segment.strip():
                name, _, value = segment.partition("=")
                pairs.append((name.strip(), value.strip()))
        reading.params(pairs)
        return
    match = re.match(r"^(abfss?|wasbs?)://([^@/]+)@([^/?#]+)(.*)$", text, re.I)
    if match:
        reading.put("container", match.group(2))
        host, rest = match.group(3).lower(), match.group(4)
        key = rest.split("?")[0]
    elif low.startswith("https://"):
        tail = text[len("https://"):].split("#", 1)[0]
        tail, _, query = tail.partition("?")
        host, _, path = tail.partition("/")
        host = host.lower()
        container, _, key = path.partition("/")
        reading.put("container", container)
        if query:
            reading.secret = True
    else:
        reading.not_a_form()
    account = re.match(r"^([a-z0-9]+)\.(blob|dfs)\.core\.windows\.net$", host)
    if not account:
        reading.refuse("the host is not <account>.blob.core.windows.net")
    reading.put("account", account.group(1))
    if key.strip("/"):
        reading.note("INFO", "The path after the container is not used: the mapping names the files to read.")


def style_glue(reading, text):
    arn = re.match(r"^arn:aws:glue:([a-z0-9-]+):\d*:(catalog|database/([^/]+)|table/([^/]+)/.*)$", text)
    if arn:
        reading.put("region", arn.group(1))
        reading.put("database", arn.group(3) or arn.group(4))
        return
    low = text.lower()
    tail = text[len("https://"):] if low.startswith("https://") else text
    host = re.split(r"[/?#:]", tail, 1)[0].lower()
    match = re.match(r"^glue(?:-fips)?\.([a-z0-9-]+)\.amazonaws\.com$", host)
    if not match:
        reading.not_a_form()
    reading.put("region", match.group(1))


STYLES = {"url": style_url, "oracle": style_oracle, "mongodb": style_mongodb, "s3": style_s3,
          "azure": style_azure, "glue": style_glue}


def read(connector, text):
    """The inputs a connection string names: {"values", "notes", "dropped",
    "events"}. A string the connector cannot read is a PlanError that does
    not quote it."""
    block = connector.get("paste")
    if not block:
        raise planner.PlanError("%s takes no connection string; give its inputs with --set KEY=VALUE"
                                % connector["name"])
    text = (text or "").strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "'\"":
        text = text[1:-1].strip()
    if not text:
        raise planner.PlanError("no connection string was given")
    if re.search(r"[\x00-\x1f\x7f\s]", text):
        raise planner.PlanError("the connection string has a space, line break or control character in it; "
                                "give it on one line, as the source shows it")
    reading = Reading(connector, block)
    STYLES[block.get("style", "url")](reading, text)
    return reading.result()
