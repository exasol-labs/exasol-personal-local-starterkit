"""The same offline argument reference reaches human and JSON help."""
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class AddonHelpTest(unittest.TestCase):
    def help(self, *args):
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, HOME=tmp, EXAKIT_HOME=tmp + '/kit',
                       EXAKIT_NO_UPDATE_NOTICE='1', EXAKIT_NO_FANCY='1')
            result = subprocess.run(['bash', str(ROOT / 'setup/exakit'), *args],
                                    env=env, text=True, capture_output=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(Path(tmp, 'kit').exists(), 'reading help must not install anything')
            return result.stdout

    def test_all_addons_have_argument_descriptions_and_examples(self):
        for path in (ROOT / 'setup/help').glob('*.json'):
            doc = json.loads(path.read_text())
            if doc.get('kind') != 'addon':
                continue
            for cmd in doc['commands']:
                with self.subTest(addon=doc['id'], command=cmd['command']):
                    self.assertIn('parameters', cmd)
                    self.assertTrue(cmd.get('examples'))
                    for param in cmd['parameters']:
                        self.assertTrue(param['name'])
                        self.assertTrue(param['description'])
                        self.assertIn('default', param)

    def test_udf_topic_shows_real_flags_and_positional_parameters(self):
        text = self.help('--help', 'udf-devkit')
        self.assertIn('Parameters and options', text)
        self.assertIn('requirements.txt', text)
        self.assertIn('Every package must be pinned', text)
        self.assertIn('exakit model inspect', text)
        self.assertIn('exakit mlflow replay', text)
        self.assertIn('EXAKIT_UDF_INSTALL_TIMEOUT', text)
        self.assertNotIn('--requirements', text)  # this is a positional file, not a flag

    def test_individual_command_documents_supported_trust_confirmation(self):
        text = self.help('model', 'put', '--help')
        self.assertIn('--yes', text)
        self.assertIn('trust', text.lower())

    def test_native_command_name_is_not_duplicated(self):
        text = self.help('--help', 'dbt-exasol')
        self.assertNotIn('dbt-exasol dbt-exasol', text)

    def test_udf_parser_flags_cannot_disappear_from_the_reference(self):
        source = (ROOT / 'setup/lib/udf-devkit.sh').read_text()
        doc = json.loads((ROOT / 'setup/help/udf-devkit.json').read_text())
        commands = {c['command']: c for c in doc['commands']}
        functions = {'cmd_udf_setup': 'udf-setup', 'cmd_udf_use': 'udf-use',
                     'cmd_udf_build': 'udf-build', '_cmd_model_put': 'model put',
                     '_cmd_model_inspect': 'model inspect', '_cmd_model_list': 'model list',
                     '_cmd_model_rm': 'model rm', '_cmd_model_prune': 'model prune',
                     '_cmd_model_template': 'model template'}
        for function, command in functions.items():
            with self.subTest(command=command):
                match = re.search(r'^' + function + r'\(\) \{\n(.*?)^}', source, re.M | re.S)
                self.assertIsNotNone(match)
                alternatives = re.findall(r'^\s*([-\w|]+)\)', match[1], re.M)
                accepted = set(re.findall(r'--[a-z][a-z-]*', ' '.join(alternatives)))
                documented = set(re.findall(r'--[a-z][a-z-]*', ' '.join(
                    p['name'] for p in commands['exakit ' + command]['parameters'])))
                self.assertFalse(accepted - documented, accepted - documented)

    def test_json_and_all_command_help_preserve_reference(self):
        doc = json.loads(self.help('help', 'udf-devkit', '--json'))
        commands = doc.get('commands', doc.get('documents', {}).get('udf-devkit', {}).get('commands', []))
        self.assertTrue(commands)
        if isinstance(commands[0], dict) and 'tool' in commands[0]:
            commands = doc['documents']['udf-devkit']['commands']
        put = next(c for c in commands if c['command'] == 'exakit model put')
        self.assertTrue(any('--yes' in p['name'] for p in put['parameters']))


if __name__ == '__main__':
    unittest.main()
