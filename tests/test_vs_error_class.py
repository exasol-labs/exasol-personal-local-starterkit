"""(run: python3 tests/test_vs_error_class.py) How the source engine reads a database's error (setup/virtual-schemas/
engine/sql.py): the class of a failure comes from what went wrong, never from the connection string the message
quotes, and a message the database cut before its reason says so instead of guessing."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "setup" / "virtual-schemas" / "engine"))

import sql  # noqa: E402

CA = "-----BEGIN%20CERTIFICATE-----%0A" + "MIIFazCCA1OgAwIBAgIRAIIQz7DS%2BQON%2F" * 60 + "%0A-----END%20CERTIFICATE-----%0A"
URL = ("jdbc:postgresql://db.example.com:5432/shop?sslmode=verify-full&sslfactory="
       "org.postgresql.ssl.SingleCertValidatingFactory&sslfactoryarg=" + CA)


def cut(message: str, limit: int = 2040) -> str:
    """A message as the database returns it: some 2,000 characters, then "..." and the session."""
    return message[:limit] + "... (Session: 1881629674401234944)"


class ConnectionStringTest(unittest.TestCase):
    def test_a_strings_own_words_do_not_name_the_class(self):
        """The string holds a certificate, "ssl" and "TLS"-like words; the reason after it is what counts."""
        after = {"password authentication failed for user \"reader\"": "auth",
                 "FATAL: database \"shop\" does not exist": "schema_missing",
                 "PKIX path building failed: unable to find valid certification path": "tls",
                 "java.net.UnknownHostException: db.example.com": "dns"}
        for reason, kind in after.items():
            with self.subTest(reason=reason):
                self.assertEqual(kind, sql.classify("JDBC-Client-Error: Connecting to '%s': %s" % (URL, reason)))
        self.assertEqual("error", sql.classify("JDBC-Client-Error: Connecting to '%s'" % URL))
        self.assertEqual("tls", sql.classify("the certificate did not verify"))            # said outside a string: counts

    def test_a_message_cut_before_its_reason_says_so_and_guesses_nothing(self):
        """Measured live (PostgreSQL, verify, ISRG Root X1): the database cut its message inside the string, the kit
        read the string's CERTIFICATE and said the certificate did not verify. The reason is unknown: it says that,
        how to read it, and names no class."""
        whole = "JDBC-Client-Error: Connecting to '%s': password authentication failed for user \"reader\"" % URL
        self.assertGreater(len(whole), 2100)
        raw = cut(whole)
        self.assertNotIn("password authentication", raw)                                   # the reason is gone
        self.assertTrue(sql.cut_in_string(raw))
        pyexasol = "%s\n(\n    message     =>  %s\n    dsn         =>  127.0.0.1:8563\n    code        =>  ETL-5\n)" % (raw, raw)
        for text in (raw, pyexasol):
            shown = sql.redact(text, set())
            with self.subTest(wrapped=text is pyexasol):
                self.assertEqual(sql.CUT, shown)
                self.assertNotIn("BEGIN", shown)
                self.assertEqual("error", sql.classify_raw(shown, text))
        self.assertLessEqual(len(sql.CUT), sql.MAX_ERROR)
        self.assertIn("--set tls=require", sql.CUT)

    def test_a_whole_message_is_left_as_it_is(self):
        short = "JDBC-Client-Error: Connecting to 'jdbc:postgresql://db.example.com:5432/shop?sslmode=require': " \
                "password authentication failed for user \"reader\" (Session: 12)"
        self.assertFalse(sql.cut_in_string(short))
        self.assertIn("password authentication failed", sql.redact(short, set()))
        self.assertEqual("auth", sql.classify_raw(sql.redact(short, set()), short))
        self.assertFalse(sql.cut_in_string("E-VSPG-3: Unable to read 'ORDERS'"))            # a quoted name is no string

    def test_a_whole_message_with_a_ca_keeps_the_reason_and_drops_the_url(self):
        """M-02, measured live (RDS PostgreSQL, verify with the region's CA, a wrong password): the database's
        message was whole, but the URL with the PEM in it filled MAX_ERROR, so the reason was cut and the class
        was "error". The person reads the reason and the class is auth; neither the PEM nor the URL is shown."""
        pem = "-----BEGIN%20CERTIFICATE-----%0A" + "MIIEBjCCAu6gAwIBAgIJAMc0ZzaSUK51" * 46 + "%0A-----END%20CERTIFICATE-----%0A"
        url = ("jdbc:postgresql://db.example.com:5432/shop?sslmode=verify-full&sslfactory="
               "org.postgresql.ssl.SingleCertValidatingFactory&sslfactoryarg=" + pem)
        whole = ("JDBC-Client-Error: Connecting to '%s' as user='reader' failed: FATAL: password authentication "
                 "failed for user \"reader\" (Session: 1882294987072274432)" % url)
        self.assertLess(len(whole), 2000)                                                  # not cut by the database
        pyexasol = "%s\n(\n    message     =>  %s\n    dsn         =>  127.0.0.1:8563\n    code        =>  ETL-5\n)" % (whole, whole)
        for text in (whole, pyexasol):
            shown = sql.redact(text, set())
            with self.subTest(wrapped=text is pyexasol):
                self.assertIn("password authentication failed for user \"reader\"", shown)
                self.assertNotIn("BEGIN", shown)
                self.assertNotIn("jdbc:", shown)
                self.assertNotIn("db.example.com", shown)
                self.assertEqual("auth", sql.classify_raw(shown, text))

    def test_an_unquoted_ca_and_the_sql_state_alone(self):
        """The PEM is masked where no quotes close the URL, and PostgreSQL's SQL state 28P01 is a refused login."""
        pem = "-----BEGIN%20CERTIFICATE-----%0A" + "MIIEBjCCAu6gAwIBAgIJAMc0ZzaSUK51" * 46 + "%0A-----END%20CERTIFICATE-----%0A"
        shown = sql.redact("Caused by: org.postgresql.util.PSQLException: sslfactoryarg=%s rejected" % pem, set())
        self.assertNotIn("BEGIN", shown)
        self.assertIn("sslfactoryarg=<CA> rejected", shown)
        # SEC-03: the placeholder names no certificate, so it is no TLS fault of its own.
        self.assertEqual("error", sql.classify(shown))
        self.assertEqual("auth", sql.classify("ERROR: login refused (SQLState: 28P01)"))

    def test_a_wrong_password_with_a_ca_is_auth_however_the_url_is_quoted(self):
        """SEC-03: only a single-quoted 'jdbc:...' was said as "the source"; a double-quoted or an unquoted URL kept
        its PEM, masked as "<CA certificate>", and a wrong password then read as a certificate fault (tls)."""
        pem = "-----BEGIN%20CERTIFICATE-----%0A" + "MIIEBjCCAu6gAwIBAgIJAMc0ZzaSUK51" * 20 + "%0A-----END%20CERTIFICATE-----%0A"
        url = ("jdbc:postgresql://db.example.com:5432/shop?sslmode=verify-full&sslfactory="
               "org.postgresql.ssl.SingleCertValidatingFactory&sslfactoryarg=" + pem + "&password=Wr0ngPa55")
        reasons = ("FATAL: password authentication failed for user \"reader\"", "28P01")
        for quote in ("'", '"', ""):
            for reason in reasons:
                text = "E-VSPG-3: Unable to connect to %s%s%s failed: %s (Session: 12)" % (quote, url, quote, reason)
                shown = sql.redact(text, {"Wr0ngPa55"})
                with self.subTest(quote=quote, reason=reason):
                    self.assertEqual("auth", sql.classify_raw(shown, text))
                    self.assertIn("Unable to connect to the source failed: " + reason, shown)
                    for gone in ("BEGIN", "CERTIFICATE", "jdbc:", "db.example.com", "Wr0ngPa55"):
                        self.assertNotIn(gone, shown)
        # An unquoted URL ends where the sentence does: its full stop stays.
        self.assertEqual("Unable to connect to the source. Login failed for user 'reader'.",
                         sql.redact("Unable to connect to jdbc:sqlserver://h:1433;databaseName=shop. "
                                    "Login failed for user 'reader'.", set()))


class MissingDatabaseTest(unittest.TestCase):
    """C-03 and C-04, measured live (0.3.0, 20 Nov): a database name the source does not have is not "error" and not
    a refused login. MySQL's scope check already said schema_missing for it."""

    def test_postgresql_names_a_missing_database_schema_missing(self):
        """C-03: pgjdbc's FATAL 3D000, quoted under the JDBC wrapper: it was "error", "see the log"."""
        text = ("JDBC-Client-Error: Connecting to 'jdbc:postgresql://postgres.example.com:5432/nosuchdb?sslmode=require' "
                "as user='reader' failed: FATAL: database \"nosuchdb\" does not exist")
        self.assertEqual("schema_missing", sql.classify(text))
        self.assertEqual("schema_missing", sql.classify("ERROR: no such database (SQLState: 3D000)"))
        # Snowflake's words for an ungranted database stay missing_or_denied, and a missing grant stays privilege.
        self.assertEqual("missing_or_denied", sql.classify("SQL compilation error: Database 'X' does not exist or not "
                                                           "authorized."))
        self.assertEqual("missing_or_denied", sql.classify('Database "X" does not exist or not authorized.'))
        self.assertEqual("privilege", sql.classify('FATAL: permission denied for database "shop"'))

    def test_sql_server_names_a_database_it_cannot_open_missing_or_denied(self):
        """C-04: SQL Server error 4060 ends with "Login failed for user", which read as a wrong password (auth). The
        login was taken: the database does not exist, or the login has no user in it."""
        text = ("JDBC-Client-Error: Connecting to 'jdbc:sqlserver://sqlserver.example.com:1433;databaseName=nosuchdb;"
                "encrypt=true;trustServerCertificate=true' as user='reader' failed: Cannot open database \"nosuchdb\" "
                "requested by the login. The login failed. ClientConnectionId:eb6d162f-a2f2-419f-9bc7-46c765c2da64, "
                "Login failed for user 'reader'. ClientConnectionId:eb6d162f-a2f2-419f-9bc7-46c765c2da64")
        self.assertEqual("missing_or_denied", sql.classify(text))
        self.assertEqual("missing_or_denied", sql.classify_raw(sql.redact(text, set()), text))
        # A wrong password alone is still auth.
        self.assertEqual("auth", sql.classify("Login failed for user 'reader'. ClientConnectionId:eb6d162f"))


class ObjectStoreAnswerTest(unittest.TestCase):
    """C-06, measured live (0.3.0, 20 Nov, lakehouse catalog none x files s3, a prefix the key may not list): the
    engine's one line ended at S3's XML declaration, so the class was "error", "see the log". S3's code is under it."""

    HEAD = ("VM error: F-UDF-CL-RUST-9001: UDF error: failed to list 'private': Generic S3 error: Error performing list "
            "request: Error performing GET https://s3.ap-south-1.amazonaws.com/docs-bucket?delimiter=%2F&list-type=2&"
            "prefix=private%2F in 89.889958ms - Server returned non-2xx status code: 403 Forbidden: "
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")

    def wrapped(self, body):
        text = self.HEAD + body
        return text, "%s\n(\n    message     =>  %s\n    dsn         =>  127.0.0.1:8563\n    code        =>  ETL-5\n)" % (text, text)

    def test_a_denied_prefix_is_denied(self):
        for text in self.wrapped("<Error><Code>AccessDenied</Code><Message>Access Denied</Message>"
                                 "<RequestId>R1</RequestId></Error>"):
            shown = sql.redact(text, set())
            with self.subTest(wrapped="message" in text):
                self.assertIn("403 Forbidden - caused by S3 AccessDenied: Access Denied", shown)
                self.assertNotIn("<?xml", shown)
                self.assertEqual("denied", sql.classify_raw(shown, text))

    def test_a_wrong_secret_under_the_same_403_is_auth(self):
        """S3 answers a wrong secret with 403 too: its code, not the status, names the class."""
        text = self.wrapped("<Error><Code>SignatureDoesNotMatch</Code><Message>The request signature we calculated "
                            "does not match the signature you provided.</Message></Error>")[0]
        self.assertEqual("auth", sql.classify_raw(sql.redact(text, set()), text))

    def test_without_a_body_the_line_is_left_as_it_is(self):
        text = self.HEAD.rstrip("\n")
        self.assertIn("403 Forbidden: <?xml", sql.redact(text, set()))
        self.assertEqual("error", sql.classify_raw(sql.redact(text, set()), text))


class CutForTheConnectorTest(unittest.TestCase):
    """C-02, measured live (0.3.0, 20 Nov, Oracle, a wrong service name with a CA): the cut message said "connect once
    with --set tls=require", which Oracle refuses (its tls is verify or disable)."""

    @staticmethod
    def connector(name):
        import json
        return json.loads((ROOT / "setup" / "virtual-schemas" / "connectors" / name / "connector.json").read_text())

    def test_oracle_is_told_what_to_check_not_tls_require(self):
        words = sql.cut_words(self.connector("oracle"))
        self.assertNotIn("tls=require", words.replace("has no tls=require", ""))
        self.assertIn("Oracle has no tls=require to read the reason with", words)
        self.assertIn("the service name as the listener knows it, the host, and the TCPS port (often 2484)", words)
        self.assertIn("the CA file holds the root that signs the server's certificate", words)
        self.assertTrue(words.startswith(sql.CUT[:60]))                       # still read as a cut message
        self.assertLessEqual(len(words), sql.MAX_ERROR)

    def test_a_connector_with_require_keeps_the_require_advice(self):
        for name in ("postgresql", "mysql", "sqlserver"):
            with self.subTest(connector=name):
                self.assertEqual(sql.CUT, sql.cut_words(self.connector(name)))


if __name__ == "__main__":
    unittest.main()
