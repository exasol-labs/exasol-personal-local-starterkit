"""The same offline argument reference reaches human and JSON help."""
import json
import os
import re
import shutil
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
                    flags = set(re.findall(r'--[a-z][a-z-]*', cmd.get('options', '')))
                    documented = set(re.findall(r'--[a-z][a-z-]*', ' '.join(
                        p['name'] for p in cmd['parameters'])))
                    self.assertFalse(flags - documented, flags - documented)
                    for param in cmd['parameters']:
                        self.assertTrue(param['name'])
                        self.assertTrue(param['description'])
                        self.assertIn('default', param)
                        self.assertIsInstance(param['required'], bool)

    def test_every_registered_addon_has_a_help_document(self):
        script = ('source "$1/setup/lib/common.sh"; exakit_marketplace_addons')
        result = subprocess.run(['bash', '-c', script, 'help-test', str(ROOT)],
                                capture_output=True, text=True, check=True, timeout=15)
        registered = {line.split('|')[0] for line in result.stdout.splitlines() if '|' in line}
        documented = {p.stem for p in (ROOT / 'setup/help').glob('*.json')
                      if json.loads(p.read_text()).get('kind') == 'addon'}
        self.assertTrue(registered)
        self.assertEqual(registered, documented)

    def test_shared_lifecycle_arguments_cannot_drift(self):
        cli = json.loads((ROOT / 'setup/help/exakit.json').read_text())
        canonical = {c['command']: c for c in cli['commands']}
        def shape(command):
            # Contextual descriptions/examples can vary, accepted arguments cannot.
            return [(p['name'], p['required'], p['default'], p.get('choices'))
                    for p in command['parameters']]
        for path in (ROOT / 'setup/help').glob('*.json'):
            doc = json.loads(path.read_text())
            if doc.get('kind') != 'addon':
                continue
            for action in ['marketplace', 'update', 'uninstall']:
                with self.subTest(addon=doc['id'], action=action):
                    command = next(c for c in doc['commands'] if c['command'] == 'exakit ' + action)
                    self.assertEqual(shape(command), shape(canonical[action]))

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

    def test_multiword_help_forms_resolve_the_same_action(self):
        for words in [('model', 'put'), ('mlflow', 'start'), ('rust-udf', 'build'),
                      ('notebook', 'stop', 'marimo')]:
            with self.subTest(words=words):
                direct = json.loads(self.help(*words, '--help', '--json'))
                spaced = json.loads(self.help('help', *words, '--json'))
                quoted = json.loads(self.help('help', 'exakit ' + ' '.join(words), '--json'))
                self.assertEqual(direct, spaced)
                self.assertEqual(spaced['commands'], quoted['commands'])
                self.assertEqual(spaced['commands'][0]['invocation'], 'exakit ' + ' '.join(words))
                self.assertIn('parameters', spaced['commands'][0])

    def test_catalog_is_self_contained_and_canonical(self):
        rows = json.loads(self.help('catalog', '--json'))['commands']
        invocations = [r['invocation'] for r in rows]
        self.assertEqual(len(invocations), len(set(invocations)))
        self.assertNotIn('dbt-exasol dbt-exasol', invocations)
        self.assertIn('dbt-exasol', invocations)
        for row in rows:
            self.assertTrue(row['usage'].startswith(row['invocation']))
            self.assertEqual(row['help_command'], 'exakit help "' + row['invocation'] + '" --json')
        put = next(r for r in rows if r['invocation'] == 'exakit model put')
        self.assertTrue(any('--yes' in p['name'] for p in put['parameters']))
        self.assertTrue(put['examples'])
        start = next(r for r in rows if r['invocation'] == 'exakit mlflow start')
        self.assertTrue(any('--port' in p['name'] for p in start['parameters']))
        self.assertFalse(any('--tracking-uri' in p['name'] for p in start['parameters']))
        filtered = json.loads(self.help('catalog', 'udf-devkit', '--json'))
        self.assertGreater(filtered['count'], 0)
        self.assertTrue(all('invocation' in r for r in filtered['commands']))
        self.assertTrue(all('udf-devkit' in r['topics'] for r in filtered['commands']))

    def test_every_addon_uses_the_same_management_commands(self):
        for path in (ROOT / 'setup/help').glob('*.json'):
            doc = json.loads(path.read_text())
            if doc.get('kind') != 'addon':
                continue
            addon = doc['id']
            result = json.loads(self.help('--help', addon, '--json'))
            self.assertEqual(result['management']['install'], 'exakit marketplace ' + addon)
            self.assertEqual(result['management']['uninstall_preview'], 'exakit uninstall ' + addon + ' --dry-run')
            self.assertIn('Manage this add-on', self.help('help', addon))

    def test_unknown_child_is_rejected_without_guessing_a_parent(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run(['bash', str(ROOT / 'setup/exakit'), 'help', 'model',
                                     'imaginary-action', '--json'], capture_output=True, text=True,
                                    env=dict(os.environ, HOME=tmp, EXAKIT_HOME=tmp + '/kit'), timeout=20)
            self.assertEqual(result.returncode, 2)
            error = json.loads(result.stdout)
            self.assertFalse(error['ok'])
            self.assertEqual(error['commands'], [])
            self.assertEqual(error['remedy'], 'exakit catalog --json')
            self.assertFalse(Path(tmp, 'kit').exists())

    @unittest.skipUnless(shutil.which('pwsh'), 'PowerShell is not available')
    def test_powershell_and_shell_discovery_are_identical(self):
        # The entire JSON contract, not just a selection of strings.
        for topic in ['all', 'udf-devkit', 'exakit model put', 'mlflow start',
                      'notebook stop marimo', 'model imaginary-action']:
            with self.subTest(topic=topic), tempfile.TemporaryDirectory() as tmp:
                code = ("$script:LibDir='" + str(ROOT / 'setup/lib').replace("'", "''") + "'; "
                        "$script:ExakitHome='" + tmp + "/kit'; . (Join-Path $script:LibDir 'help.ps1'); "
                        "Show-ExakitHelpJson -Which '" + topic + "' -CommandHelp")
                ps = subprocess.run(['pwsh', '-NoProfile', '-Command', code], text=True,
                                    capture_output=True, timeout=40)
                self.assertEqual(ps.returncode, 0, ps.stderr)
                env = dict(os.environ, HOME=tmp, EXAKIT_HOME=tmp + '/kit', EXAKIT_NO_UPDATE_NOTICE='1')
                sh = subprocess.run(['bash', str(ROOT / 'setup/exakit'), 'help', topic, '--json'],
                                    text=True, capture_output=True, env=env, timeout=20)
                self.assertEqual(json.loads(ps.stdout), json.loads(sh.stdout))

    @unittest.skipUnless(shutil.which('pwsh'), 'PowerShell is not available')
    def test_powershell_entrypoint_preserves_action_and_exit_code(self):
        for args, expected_code in [(['model', 'put', '--help', '--json'], 0),
                                    (['help', 'notebook', 'stop', 'marimo', '--json'], 0),
                                    (['help', 'model', 'imaginary-action', '--json'], 2)]:
            with self.subTest(args=args), tempfile.TemporaryDirectory() as tmp:
                env = dict(os.environ, HOME=tmp, EXAKIT_HOME=tmp + '/kit', EXAKIT_NO_UPDATE_NOTICE='1')
                ps = subprocess.run(['pwsh', '-NoProfile', '-File', str(ROOT / 'setup/exakit.ps1'), *args],
                                    text=True, capture_output=True, env=env, timeout=40)
                sh = subprocess.run(['bash', str(ROOT / 'setup/exakit'), *args],
                                    text=True, capture_output=True, env=env, timeout=20)
                self.assertEqual(ps.returncode, expected_code, ps.stderr)
                self.assertEqual(json.loads(ps.stdout), json.loads(sh.stdout))
                self.assertFalse(Path(tmp, 'kit').exists())

    @unittest.skipUnless(shutil.which('pwsh'), 'PowerShell is not available')
    def test_future_addon_is_discovered_without_editing_renderers(self):
        with tempfile.TemporaryDirectory() as tmp:
            lib = Path(tmp, 'setup/lib')
            help_dir = lib.parent / 'help'
            lib.mkdir(parents=True)
            help_dir.mkdir()
            doc = {'id': 'future-addon', 'kind': 'addon', 'invocation_prefix': 'future-cli',
                   'commands': [{'command': 'inspect', 'options': '[--json]', 'summary': 'Inspect.',
                                 'parameters': [{'name': '--json', 'required': False,
                                                 'default': 'off', 'description': 'Return JSON.'}],
                                 'examples': ['future-cli inspect --json']}]}
            (help_dir / 'future-addon.json').write_text(json.dumps(doc))
            sh_code = ('exakit_can_run_python() { return 0; }; run_python() { python3 "$@"; }; '
                       '_lib_dir="$1"; source "$2"; exakit_help_render command-json "future-cli inspect"')
            sh = subprocess.run(['bash', '-c', sh_code, 'help-test', str(lib), str(ROOT / 'setup/lib/help.sh')],
                                capture_output=True, text=True, check=True, timeout=20)
            ps_code = ("$script:LibDir='" + str(lib) + "'; . '" + str(ROOT / 'setup/lib/help.ps1') +
                       "'; Show-ExakitHelpJson 'future-cli inspect' -CommandHelp")
            ps = subprocess.run(['pwsh', '-NoProfile', '-Command', ps_code],
                                capture_output=True, text=True, check=True, timeout=40)
            result = json.loads(sh.stdout)
            self.assertEqual(result, json.loads(ps.stdout))
            self.assertEqual(result['commands'][0]['invocation'], 'future-cli inspect')


if __name__ == '__main__':
    unittest.main()
