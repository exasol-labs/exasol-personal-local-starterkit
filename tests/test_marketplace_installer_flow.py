"""The installer keeps persona, data, then closing marketplace order."""

import json
import os
import subprocess
import tempfile
from unittest.mock import Mock

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'marketplace'))
from installer_flow import plan
from persona_services import start_services
from runtime import KitContext, Manifest


class InstallerFlowTest(unittest.TestCase):
    def test_question_then_selected_persona_preselects_data_and_addons(self):
        self.assertEqual([('question', '', '')], plan(ROOT, {}, interactive=True))
        actions = plan(ROOT, {'EXAKIT_PERSONA': 'ml-engineer'}, phase='selected')
        self.assertIn(('set', 'EXAKIT_DATASETS_PRESELECT', 'pharma_trials,banking_complaints'), actions)
        self.assertIn(('set', 'EXAKIT_MARKETPLACE_PRESELECT', 'notebook,udf-devkit'), actions)
        self.assertIn(('record', 'ml-engineer', ''), actions)
        self.assertEqual(('data', '', ''), actions[-1])
        self.assertNotIn('install', [action[0] for action in actions])

    def test_headless_and_cancel_keep_default_data_without_persona_record(self):
        for phase in ('begin', 'selected'):
            self.assertEqual([('set', 'EXAKIT_DATASETS_PRESELECT', 'tpch,energy,weather'),
                              ('data', '', '')], plan(ROOT, {}, phase=phase))

    def test_explicit_answers_do_not_reopen_question_or_change_preselection(self):
        env = {'EXAKIT_DATASETS': 'tpch', 'EXAKIT_MARKETPLACE_ADDONS': 'none',
               'EXAKIT_DATASETS_PRESELECT': 'weather'}
        self.assertEqual([('data', '', '')], plan(ROOT, env, interactive=True))
        env['EXAKIT_PERSONA'] = 'data-scientist'
        actions = plan(ROOT, env, phase='selected')
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
            env.update(EXAKIT_HOME=folder, EXAKIT_PERSONA='ml-engineer')
            result = subprocess.run([sys.executable, str(ROOT / 'marketplace/installer_flow.py'),
                '--phase', 'selected'], env=env, text=True, capture_output=True, timeout=10)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual('data||', result.stdout.splitlines()[-1])
            manifest = json.loads((Path(folder) / 'manifest.json').read_text())
            self.assertEqual('ml-engineer', manifest['persona']['id'])
            self.assertNotIn('components', manifest)

    def test_services_require_both_addons_and_return_retry_on_failure(self):
        with tempfile.TemporaryDirectory() as folder:
            manifest = Path(folder) / 'manifest.json'
            manifest.write_text('{}')
            ctx = KitContext(ROOT, Path(folder), Path(folder) / 'bin', Manifest(manifest), Path('uv'))
            run = Mock(return_value=False)
            self.assertEqual([], start_services(ctx, ['mlflow'], run, ['udf-devkit']))
            run.assert_not_called()
            failures = start_services(ctx, ['mlflow'], run, ['udf-devkit', 'notebook'])
            self.assertEqual([('MLflow service', 'exakit mlflow start')], failures)
            run.assert_called_once_with('mlflow', ['start'])

    def test_installer_services_accept_owned_receipts_but_not_external_ones(self):
        with tempfile.TemporaryDirectory() as folder:
            manifest = Path(folder) / 'manifest.json'
            manifest.write_text('{}')
            ctx = KitContext(ROOT, Path(folder), Path(folder) / 'bin', Manifest(manifest), Path('uv'))
            run = Mock(return_value=True)
            ctx.manifest.set_many({'components.udf_devkit.ownership': 'user',
                                   'components.notebook.ownership': 'kit'})
            start_services(ctx, ['mlflow'], run)
            run.assert_not_called()
            ctx.manifest.set_many({'components.udf_devkit.ownership': 'kit'})
            self.assertEqual([], start_services(ctx, ['mlflow'], run))
            run.assert_called_once_with('mlflow', ['start'])


if __name__ == '__main__':
    unittest.main()
