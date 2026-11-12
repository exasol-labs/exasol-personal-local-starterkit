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
                 "FATAL: database \"shop\" does not exist": "error",
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


if __name__ == "__main__":
    unittest.main()
