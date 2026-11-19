"""A credential the driver reads only from a file: BigQuery's service-account key.

Simba's BigQuery driver (1.7.0.1001) takes the key only as a file path
(OAuthPvtKeyPath) or inline in the URL; measured on Exasol Personal, a key in
the CONNECTION's password is refused ("Required Connection Key(s):
OAuthPvtKeyPath"). So the kit writes the key to BucketFS, one file per source,
0644 so the UDF can read it on Linux too (lifecycle.write_key), and the
URL names its path - never the key. Any database user who may create scripts
can read BucketFS, so the kit names such users (lifecycle.script_readers).

Checked here before anything is staged: that the text is a service-account
key, and an e-mail address the URL can carry without changing its meaning.
"""

import json
import re

# The account's address goes into the JDBC URL, so it may not carry the URL's
# own separators: ';' or a quote would add or end a property.
EMAIL = re.compile(r"^[A-Za-z0-9._-]+@[a-z0-9.-]+\.gserviceaccount\.com$")


class KeyFileError(Exception):
    pass


def service_account(secret):
    """(e-mail, project id, the key text, every string to redact) for a valid key."""
    text = (secret or "").strip()
    try:
        doc = json.loads(text)
    except ValueError:
        raise KeyFileError("the credential must be the service-account key file (JSON) Google Cloud created, "
                           "e.g. gcloud iam service-accounts keys create key.json --iam-account=<account>")
    if not isinstance(doc, dict) or doc.get("type") != "service_account":
        raise KeyFileError("the key file is not a service-account key (its \"type\" is not \"service_account\")")
    email = str(doc.get("client_email", ""))
    if not EMAIL.match(email):
        raise KeyFileError("the key file has no usable client_email (expected <name>@<project>.iam.gserviceaccount.com)")
    private = str(doc.get("private_key", ""))
    if "-----BEGIN PRIVATE KEY-----" not in private:
        raise KeyFileError("the key file has no private key")
    hidden = [h for h in (secret, text, private, private.replace("\n", "\\n"), str(doc.get("private_key_id", ""))) if h]
    return email, str(doc.get("project_id", "")), text + "\n", hidden
