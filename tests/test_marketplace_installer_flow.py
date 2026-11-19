"""The installer keeps persona, data, then closing marketplace order."""

import json
import os
import subprocess
import tempfile

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'marketplace'))
sys.path.insert(0, str(ROOT / 'tests'))
from installer_flow import plan
from release_kit import kit_with_hidden_parts_on

# The release ships General alone; a persona named explicitly is still the kit's rule, proved on the fixture
# personas (analyst, engineer) of tests/release_kit.py.
_KIT_DIR = tempfile.TemporaryDirectory()
KIT = kit_with_hidden_parts_on(Path(_KIT_DIR.name) / 'kit')


def tearDownModule():
    _KIT_DIR.cleanup()


class InstallerFlowTest(unittest.TestCase):
    def test_the_install_never_asks_and_sets_up_general_quietly(self):
        actions = plan(ROOT, {}, interactive=True)
        self.assertEqual([('set', 'EXAKIT_PERSONA', 'general'),
                          ('set', 'EXAKIT_DATASETS_PRESELECT', 'retail_sales,bank_transaction'),
                          ('record', 'general', ''), ('set', 'EXAKIT_PERSONA_ACTIVE', '1'),
                          ('data', '', '')], actions)
        self.assertNotIn('question', [action[0] for action in actions])
        self.assertNotIn('notice', [action[0] for action in actions], "no persona is named on screen")
        self.assertEqual(actions, plan(ROOT, {}), "headless: the same")

    def test_a_persona_named_explicitly_still_preselects_its_data_and_addons(self):
        actions = plan(KIT, {'EXAKIT_PERSONA': 'engineer'}, phase='selected')
        self.assertIn(('set', 'EXAKIT_DATASETS_PRESELECT', 'orders_demo,payments_demo'), actions)
        self.assertIn(('set', 'EXAKIT_MARKETPLACE_PRESELECT', 'dbt-exasol,exasol-scheduler'), actions)
        self.assertIn(('record', 'engineer', ''), actions)
        self.assertEqual(('data', '', ''), actions[-1])
        self.assertNotIn('install', [action[0] for action in actions])

    def test_selected_without_a_persona_keeps_default_data_without_record(self):
        self.assertEqual([('set', 'EXAKIT_DATASETS_PRESELECT', 'retail_sales,bank_transaction'),
                          ('data', '', '')], plan(ROOT, {}, phase='selected'))

    def test_explicit_answers_do_not_change_preselection(self):
        env = {'EXAKIT_DATASETS': 'tpch', 'EXAKIT_MARKETPLACE_ADDONS': 'none',
               'EXAKIT_DATASETS_PRESELECT': 'weather'}
        actions = plan(ROOT, env, interactive=True)
        self.assertEqual([('set', 'EXAKIT_PERSONA', 'general'), ('record', 'general', ''),
                          ('set', 'EXAKIT_PERSONA_ACTIVE', '1'), ('data', '', '')], actions)
        env['EXAKIT_PERSONA'] = 'analyst'
        actions = plan(KIT, env, phase='selected')
        self.assertFalse(any(action[0] == 'set' and action[1].endswith('PRESELECT') for action in actions))

    def test_failed_prerequisites_never_ask_or_record_persona(self):
        self.assertEqual([], plan(ROOT, {}, interactive=True, runtime_failed=True))
        self.assertEqual([('data', '', '')], plan(ROOT, {}, interactive=True, exapump_failed=True))

    def test_unknown_selection_warns_and_returns_to_default_data(self):
        actions = plan(ROOT, {'EXAKIT_PERSONA': 'not-a-persona'}, phase='selected')
        self.assertEqual('warning', actions[0][0])
        self.assertIn(('set', 'EXAKIT_PERSONA', ''), actions)
        self.assertFalse(any(action[0] == 'record' for action in actions))
        self.assertEqual(('data', '', ''), actions[-1])

    def test_selected_cli_records_membership_without_loading_data(self):
        with tempfile.TemporaryDirectory(prefix='persona flow ') as folder:
            (Path(folder) / 'manifest.json').write_text('{}')
            env = {key: value for key, value in os.environ.items() if not key.startswith('EXAKIT_')}
            env.update(EXAKIT_HOME=folder, EXAKIT_PERSONA='engineer')
            result = subprocess.run([sys.executable, str(KIT / 'marketplace/installer_flow.py'),
                '--phase', 'selected'], env=env, text=True, capture_output=True, timeout=10)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual('data||', result.stdout.splitlines()[-1])
            manifest = json.loads((Path(folder) / 'manifest.json').read_text())
            self.assertEqual('engineer', manifest['persona']['id'])
            self.assertNotIn('components', manifest)


if __name__ == '__main__':
    unittest.main()
