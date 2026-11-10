"""Generated-output scanning detects actual values, escaped notebook output and nested credential fields."""
import importlib.util
import json
from pathlib import Path
import unittest
import tempfile

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location("artifact_scan",ROOT/"tools/artifact_scan.py")
scan=importlib.util.module_from_spec(spec);spec.loader.exec_module(scan)


class ArtifactScanTest(unittest.TestCase):
    VALUES={"database_dsn":"db.example:8563","database_user":"sys","provider_api_key":"dummy-private-key"}
    def test_exact_values_are_detected_without_returning_them(self):
        for field,value in self.VALUES.items():
            text='"'+value+'"'
            found=scan.inspect_text(text,self.VALUES)
            self.assertIn(field,found)
            self.assertNotIn(value,str(found))
    def test_escaped_notebook_outputs_are_decoded(self):
        text=json.dumps({"outputs":[{"text":'user => sys\ndsn => db.example:8563'}]})
        self.assertEqual(scan.inspect_text(text,self.VALUES),['database_dsn','database_user'])
    def test_nested_unknown_key_value_is_still_a_credential_field(self):
        text=json.dumps({"metadata":{"api_key":"previously-unknown-dummy"}})
        self.assertIn('credential_field',scan.inspect_text(text,{}))
    def test_encoded_metadata_is_also_inspected(self):
        text=json.dumps({"outputs":[{"text":json.dumps({"metadata":{"api_key":"unknown-key"}})}]})
        self.assertIn("credential_field",scan.inspect_text(text,{}))
    def test_common_password_is_not_a_substring_match_in_a_module_or_path(self):
        values={"database_password_0":"example"}
        self.assertEqual(scan.inspect_text('import example.nb; ~/.example-starter-kit',values),[])
        self.assertEqual(scan.inspect_text('password => example',values),['database_password_0'])
        self.assertEqual(scan.inspect_text('{"password":"example"}',values),['credential_field','database_password_0'])

    def test_manifest_includes_host_and_both_database_users(self):
        with tempfile.TemporaryDirectory() as temporary:
            home=Path(temporary)
            (home/"manifest.json").write_text(json.dumps({"runtime":{"dsn":"demo-db.example:8563","user":"SYS"},
                "components":{"mcp_server":{"connection":{"user":"DEMO_READONLY"}}}}))
            values=scan.credential_values(home)
            for text in ('host=demo-db.example','"demo-db.example"','user => DEMO_READONLY'):
                self.assertTrue(scan.inspect_text(text,values))
            self.assertEqual(scan.inspect_text('http://demo-db.example:5100/preview/test',values),[])

    def test_configuration_names_and_unrelated_service_urls_are_allowed(self):
        text='import sys\nEXAKIT_PROVIDER_API_KEY\nhttp://db.example:5100/preview/demo\n'
        self.assertEqual(scan.inspect_text(text,self.VALUES),[])


if __name__=='__main__':unittest.main()
