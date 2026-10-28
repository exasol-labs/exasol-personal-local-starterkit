"""Complete shipped inventory, preserved upstream lessons and the Marimo cell runner."""
import ast
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'notebook/package'))
from exakit_nb import example_runtime as runtime

LIBRARY = ROOT / 'notebook/examples'

class LibraryTest(unittest.TestCase):
    def test_every_upstream_notebook_has_both_frontends_and_all_original_cells(self):
        manifest = json.loads((LIBRARY / 'manifest.json').read_text())
        self.assertEqual(len(manifest['notebooks']), 50)
        self.assertEqual(len({e['path'] for e in manifest['notebooks']}), 50)
        paths = {p.relative_to(LIBRARY/'jupyter').as_posix() for p in (LIBRARY/'jupyter').rglob('*.ipynb')}
        self.assertEqual(paths, {e['path'] for e in manifest['notebooks']} | {'00_library.ipynb'})
        for entry in manifest['notebooks']:
            with self.subTest(notebook=entry['path']):
                doc=json.loads((LIBRARY/'jupyter'/entry['path']).read_text())
                self.assertEqual(len(doc['cells']), entry['cells']+2)
                self.assertEqual(doc['metadata']['exakit_source']['revision'], manifest['revision'])
                self.assertEqual(doc['metadata']['kernelspec']['name'], 'exasol-starter-kit')
                for cell in doc['cells']:
                    if cell['cell_type']=='code': self.assertEqual(cell['outputs'], [])
                marimo=LIBRARY/'marimo'/Path(entry['path']).with_suffix('.py')
                text=marimo.read_text(); ast.parse(text)
                steps=sum(c['cell_type']=='code' and bool(''.join(c['source']).strip()) for c in doc['cells'])
                self.assertEqual(text.count('mo.ui.run_button('), steps)
                self.assertEqual(text.count('mo.stop(not run_'), steps)
                self.assertNotIn('app._unparsable_cell', text)
        for asset in manifest['assets']:
            self.assertEqual((LIBRARY/'jupyter'/asset).read_bytes(), (LIBRARY/'marimo'/asset).read_bytes())

    def test_configuration_repr_contains_no_credentials_and_does_not_change_the_store(self):
        store=mock.Mock(); store.get.return_value='not-for-display'
        config=runtime.ExampleConfig(store)
        self.assertEqual(config.db_schema,'EXAKIT_EXAMPLES')
        self.assertNotIn('not-for-display',repr(config))
        store.set.assert_not_called()

    def test_reference_and_unconfigured_advanced_lessons_do_not_open_a_connection(self):
        with mock.patch.dict(os.environ,{},clear=True), mock.patch('exakit_nb.connect') as connection:
            for name in ['cloud/02_s3_vs_reuters.ipynb','gpu_in_udf/setup.ipynb','transformers/te_init.ipynb']:
                with self.subTest(notebook=name), self.assertRaises(RuntimeError): runtime.bootstrap({},name)
            connection.assert_not_called()

    def test_local_bucket_keeps_files_in_the_example_folder(self):
        with tempfile.TemporaryDirectory() as tmp:
            bucket=runtime.LocalBucket(tmp,'/buckets/bfsdefault/default/exasol-examples')
            bucket.upload('models/test.bin',b'contents')
            self.assertEqual((Path(tmp)/'models/test.bin').read_bytes(),b'contents')
            self.assertEqual((bucket/'models/test.bin').as_udf_path(),'/buckets/bfsdefault/default/exasol-examples/models/test.bin')
            with self.assertRaises(ValueError): bucket/'../outside'

@unittest.skipUnless(importlib.util.find_spec('IPython'),'IPython is supplied by the notebook environment')
class RunnerTest(unittest.TestCase):
    def test_python_and_ipython_magics_share_state_and_restore_the_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            before=Path.cwd(); lesson=runtime.Lesson('test.ipynb',tmp)
            self.assertIsNone(lesson.run('value = 41')['error'])
            self.assertIn('42',lesson.run('print(value+1)')['stdout'])
            result=lesson.run('%%writefile marker.txt\nmarker contents')
            self.assertIsNone(result['error'])
            self.assertEqual((Path(tmp)/'marker.txt').read_text().strip(),'marker contents')
            self.assertEqual(Path.cwd(),before)
            self.assertTrue(lesson.run('raise ValueError("test failure")')['error'])
            self.assertIn('41',lesson.run('print(value)')['stdout'])
            second=runtime.Lesson('test.ipynb',tmp)
            self.assertTrue(second.run('print(value)')['error'])

    @unittest.skipUnless(importlib.util.find_spec("nbformat"), "nbformat is supplied by JupyterLab")
    def test_run_magic_uses_the_matching_bundled_jupyter_utility(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)/'notebooks/marimo/exasol-examples'
            (root/'data').mkdir(parents=True)
            utility=Path(tmp)/'notebooks/starter-kit-notebooks/exasol-examples/data/utils/helper.ipynb'
            utility.parent.mkdir(parents=True)
            utility.write_text(json.dumps({'nbformat':4,'nbformat_minor':5,'metadata':{},'cells':[{'id':'helper','cell_type':'code','metadata':{},'execution_count':None,'outputs':[],'source':'shared_value=73'}]}))
            lesson=runtime.Lesson('data/example.ipynb',root)
            self.assertIsNone(lesson.run('%run utils/helper.ipynb')['error'])
            self.assertIn('73',lesson.run('print(shared_value)')['stdout'])

if __name__=='__main__':unittest.main()
