"""What `exakit source` and `exakit source <name>` put on screen.

The shells draw; this module decides the words, so bash and PowerShell show
the same card and the same menu. Nothing here reaches the database, and no
answer carries a secret: a credential is never recorded in a source's files,
and a secret input is skipped by its kind as well.

    card(engine, name, details)  one source: its labelled rows, the notes
                                 (the connector's tips), a first query, and
                                 its fix when it is not ready
    cards(engine)                every source, one row each, for the picker

`exakit source show --json` stays engine.show's answer, unchanged: scripts and
agents read it. These answers are only for the terminal (the shells ask with
the engine's `card` and `cards` commands).
"""

import datetime
import os

import lifecycle

# A short reason for a source that is not ready, by the class of its last
# failed check, with the menu action that is its fix and that action's words.
# The full remedy (lifecycle.remedy_for) stays in `exakit source issues`.
FIX_FOR_KIND = {
    "auth": ("{secret} rejected", "reauth", "enter the new {secret_lower}"),
    "tls": ("certificate did not verify", "check", "test it again once the certificate is trusted"),
    "unreachable": ("did not answer", "check", "test it again once it is reachable"),
    "nohost": ("host name not found", "repoint", "move it to the right host"),
    "dns": ("the database could not resolve the host", "check", "restart the database, then test it again"),
    "denied": ("access denied", "check", "test it again once the account may read it"),
    "privilege": ("a privilege is missing", "check", "test it again once it is granted"),
    "external": ("access denied", "check", "test it again once the account may read it"),
    "missing_or_denied": ("a table is gone or hidden", "refresh", "pick up the tables as they are now"),
    "schema_missing": ("its schema is gone", "check", "test it again once the schema is back"),
    "region": ("the bucket is in another region", "repoint", "give the bucket's region"),
    "clock": ("the database clock is off", "check", "restart the database, then test it again"),
    "nojava": ("Java is not installed in the database", "check", "test it again after exakit connect installs it"),
    "norust": ("the Rust container is not installed", "check", "test it again after exakit connect installs it"),
}
FIX_DEFAULT = ("the last check failed", "check", "test it again")

# Labels for inputs whose definition label is a sentence (connector.json keeps
# the long one for the form, where it is a question).
SHORT_LABEL = {
    "uri": "URI", "user": "Reader", "http_path": "HTTP path", "catalog_url": "Catalog URL",
    "workspace_url": "Workspace URL", "access_key_id": "Access key ID", "mapping": "EDML mapping",
    "ca": "CA file", "region": "Region", "endpoint": "Endpoint", "account": "Account",
    "container": "Container", "project": "Project", "bucket": "Bucket", "namespace": "Namespace",
    "warehouse": "Warehouse", "service": "Service", "tls": "TLS", "role": "Role", "schema": "Source schema",
}
SECRET_KINDS = ("secret", "secret-file")
# The inputs that say where a source is: what "Move to a new host" asks for
# again (each with its value as the default), before the re-point connect.
ADDRESS_KINDS = ("host", "port", "mongodb-uri", "account", "catalog-url", "https-url", "s3-bucket",
                 "azure-account", "aws-region")
MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")


def short_label(spec):
    if spec["name"] in SHORT_LABEL:
        return SHORT_LABEL[spec["name"]]
    label = spec.get("label") or spec["name"]
    for cut in (" (", " - ", ": ", "; ", ", "):
        label = label.split(cut)[0]
    return label


def when(stamp):
    """An ISO time as this computer's local "10 Nov 17:11"; "" when unreadable."""
    try:
        at = datetime.datetime.strptime(str(stamp)[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        return ""
    local = at.astimezone()
    return "%d %s %02d:%02d" % (local.day, MONTHS[local.month - 1], local.hour, local.minute)


def secret_words(connector):
    """The connector's credential in a few words: "Password", "Personal access token"."""
    for spec in connector.get("inputs", []):
        if spec["kind"] == "secret":
            words = spec.get("label") or "credential"
            for cut in (" (", ", ", " - "):
                words = words.split(cut)[0]
            return words
    return "Credential"


def lower_first(words):
    """"Password" -> "password"; an acronym ("SAS token") keeps its case."""
    if len(words) > 1 and words[1].islower():
        return words[0].lower() + words[1:]
    return words


def state_of(status, check, needs_refresh, connector):
    """(ready, reason, fix): fix is None or {"action", "label"}."""
    if status == "ready" and needs_refresh:
        return False, "needs a refresh after the adapter update", {
            "action": "refresh", "label": "needs a refresh - pick up the tables with the new adapter"}
    if status == "ready":
        return True, "ready", None
    if status == "disconnected":
        return False, "disconnected", {"action": "reconnect", "label": "disconnected - connect it again"}
    reason, action, words = FIX_FOR_KIND.get((check or {}).get("kind") or "", FIX_DEFAULT)
    secret = secret_words(connector)
    reason = reason.format(secret=secret, secret_lower=lower_first(secret))
    words = words.format(secret=secret, secret_lower=lower_first(secret))
    reason = lower_first(reason)
    return False, reason, {"action": action, "label": "%s - %s" % (reason, words)}


def plural(n, word):
    return "%d %s%s" % (n, word, "" if n == 1 else "s")


def connector_of(engine, connector_id, values=None):
    try:
        return engine.defs.connector(connector_id, values)
    except (OSError, ValueError, KeyError, lifecycle.planner.PlanError):
        return {}


def connector_name(engine, connector_id, connector=None):
    """The catalog's name, or a combination's own ("Lakehouse · Unity Catalog · Azure ADLS Gen2")."""
    if connector and connector.get("label"):
        return connector["label"]
    try:
        return engine.defs.entry(connector_id)["name"]
    except (KeyError, OSError, ValueError, lifecycle.planner.PlanError):
        return connector_id


def tilde(path):
    home = os.path.expanduser("~")
    return "~" + path[len(home):] if home and path.startswith(home + os.sep) else path


def card(engine, name, details=False):
    shown = engine.show(name)
    values = shown.get("inputs") or {}
    connector = connector_of(engine, shown["connector"], values)
    check = shown.get("last_check") or {}
    ready, reason, fix = state_of(shown["status"], check, shown.get("needs_refresh"), connector)
    status = [reason]
    if shown.get("tables") is not None:
        status.append(plural(shown["tables"], "table"))
    if check.get("at"):
        status.append("checked %s (%s)" % (when(check["at"]), check.get("outcome") or "?"))
    else:
        status.append("never checked")
    schema = shown["objects"]["schema"]
    # The Status row's parts: the shells join them with their own separator
    # (a middle dot where the console renders one) and put the tick or cross first.
    rows = [["Status", ""], ["Schema", schema]]
    where = lifecycle.source_where(connector, values)
    if where and values.get("port") and where == values.get("host"):
        where = "%s:%s" % (where, values["port"])
    if where:
        rows.append(["Host", where])
    for spec in connector.get("inputs", []):
        if spec["kind"] in SECRET_KINDS or spec["name"] in ("host", "port"):
            continue
        value = values.get(spec["name"])
        if value in (None, ""):
            continue
        value = str(value)
        if spec.get("setting") and value in spec.get("choices", []):
            # A lakehouse setting by its label: "Unity Catalog", not unity.
            value = spec["choice_labels"][spec["choices"].index(value)]
        if spec["kind"] in ("ca-file", "edml"):
            value = tilde(value)
        rows.append([short_label(spec), value])
    address = [{"input": spec["name"], "label": short_label(spec), "value": str(values.get(spec["name"]) or "")}
               for spec in connector.get("inputs", []) if spec["kind"] in ADDRESS_KINDS]
    pins = shown.get("pins") or {}
    if pins.get("adapter_version"):
        adapter = pins["adapter_version"] + (" (verified)" if pins.get("adapter") else "")
        if pins.get("driver_version"):
            adapter += ", driver %s" % pins["driver_version"]
        rows.append(["Adapter", adapter])
    if details:
        objects = shown["objects"]
        rows.append(["Connection", objects.get("connection") or "-"])
        rows.append(["Script", "%s.%s" % (objects.get("script_schema"), objects.get("script"))])
        if pins.get("adapter"):
            rows.append(["Adapter SHA", pins["adapter"]])
        if pins.get("driver"):
            rows.append(["Driver SHA", pins["driver"]])
    remedy = None
    if not ready and shown["status"] != "disconnected":
        remedy = lifecycle.remedy_for(check.get("kind") or "error", name, connector, check.get("evidence"))
        if shown["status"] == "ready":  # needs_refresh
            remedy = "it moved to a new adapter and its metadata is not refreshed yet: exakit source refresh %s" % name
    return {"name": name, "connector": shown["connector"],
            "connector_name": connector_name(engine, shown["connector"], connector),
            "status": shown["status"], "ready": ready, "reason": reason, "status_parts": status, "fix": fix, "remedy": remedy,
            "rows": rows, "address": address, "notes": shown.get("tips") or [],
            "example": "SELECT * FROM %s.<table> LIMIT 10" % schema}


def cards(engine):
    out = []
    for row in engine.listing():
        connector = connector_of(engine, row["connector"], engine.store.config(row["name"]).get("inputs") or {})
        ready, reason, fix = state_of(row["status"], row.get("last_check"), row.get("needs_refresh"), connector)
        out.append({"name": row["name"], "connector": row["connector"],
                    "connector_name": connector_name(engine, row["connector"], connector),
                    "ready": ready, "reason": reason, "fix": fix,
                    "tables": engine.store.status(row["name"]).get("tables")})
    return {"sources": out}

