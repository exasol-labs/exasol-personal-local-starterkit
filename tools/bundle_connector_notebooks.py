"""Vendor the complete official example tree and build explicit-run Marimo apps.

Usage: python3 tools/bundle_connector_notebooks.py /path/to/notebook-connector
No network or deployment operations: the source is a reviewed local checkout.
"""
from __future__ import annotations
import hashlib
import json
import posixpath
import re
import shutil
import subprocess
import sys
import textwrap
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / 'notebook/examples'
KERNEL = {'display_name': 'Exasol (Starter Kit)', 'language': 'python', 'name': 'exasol-starter-kit'}
NOTES = {
 'cloud': 'Reference only: cloud storage and virtual-schema integration belong to separate work. These cells are not enabled by the local kit.',
 'gpu_in_udf': 'Requires a GPU-capable Exasol host and GPU SLC. The local Mac kit does not provision these.',
 'transformers': 'Requires a configured Transformers Extension, model downloads and its language container. These services are not installed by opening a notebook.',
 'text_ai': 'Requires a configured Text AI Extension and its database objects. These services are not installed by opening a notebook.',
 'script_languages_container': 'Requires Docker or Podman, SLC tooling and substantial free disk. Container installation can restart the database. Prefer exakit udf-build for the kit flow.',
 'sklearn': 'Load the matching Abalone or Telescope data notebook first. Prediction requires udf-devkit and the PYTHON3_ML runtime. Models use the local file bucket.',
 'data': 'Downloads the tutorial dataset when you run the loader. Tutorial tables are kept in EXAKIT_EXAMPLES, separately from the persona datasets.',
 'ibis': 'Requires the US_FLIGHTS and US_AIRLINES tutorial tables. Run first_steps or the flight data loader first.',
 'jupysql': 'Requires the US_FLIGHTS and US_AIRLINES tutorial tables. SQL magics are supported in Jupyter and the Marimo cell runner.',
 'pyexasol': 'Requires the flight tutorial tables. Reads and writes tutorial tables and local export files.',
 '(start)': 'Uses the kit encrypted connection. Database examples use EXAKIT_EXAMPLES. Later sections may need tutorial downloads or the ML UDF add-on.'}

def markdown(text):
 return {'cell_type':'markdown','metadata':{},'source':text.splitlines(keepends=True)}

def code(text):
 return {'cell_type':'code','metadata':{},'source':text.splitlines(keepends=True),'execution_count':None,'outputs':[]}

def adapt(source, relative):
 if 'access_store.get_access_store' in source:
  return 'print("Using the Starter Kit encrypted connection; tutorial schema: EXAKIT_EXAMPLES.")'
 if relative == 'main_config.ipynb':
  return 'print("The starter kit already manages the local connection and database. No replacement database is created.")'
 source = source.replace('from exasol.nb_connector.connections import', 'from exakit.nb.example_runtime import')
 source = source.replace('from exasol.nb_connector.sklearn_version_check import', 'from exakit.nb.example_runtime import')
 source = source.replace('jupysql.init(ai_lab_config)', 'jupysql_init(ai_lab_config)')
 source = source.replace('from exasol.nb_connector.ui.common import jupysql', 'from exakit.nb.example_runtime import init_sql as jupysql_init')
 source = re.sub(r'CREATE(\s+OR\s+REPLACE)?\s+PYTHON3\b', lambda m:m.group(0)[:-7]+'PYTHON3_ML', source, flags=re.I)
 if relative == 'jupysql/quickstart.ipynb':
  if source.strip().startswith(('pip install','%pip install','!pip install')):
   return 'import sql\nprint("JupySQL and the Exasol dialect are supplied by the notebook environment.")'
  if 'from sqlalchemy.engine import URL' in source:
   return 'from exakit.nb.example_runtime import init_sql\nengine = init_sql(ai_lab_config)'
  if 'DATABASE_URL' in source or '%sql $url_object' in source:
   return 'print("Using the starter-kit SQL engine; no database credentials are placed in environment variables.")'
 return source

def marimo_links(text, relative):
 def link(match):
  href=match.group(1)
  if '://' in href or href.startswith('#'): return match.group(0)
  normalized=posixpath.normpath(posixpath.join(posixpath.dirname(relative),href))
  return '](/?file='+quote('exasol-examples/'+normalized[:-6]+'.py')+')'
 text=re.sub(r'\]\(([^)]+\.ipynb)\)',link,text)
 def image(match):
  src=match.group(1)
  if '://' in src or src.startswith('data:'): return match.group(0)
  normalized=posixpath.normpath(posixpath.join(posixpath.dirname(relative),src))
  return 'src="/public/exasol-examples/'+quote(normalized)+'"'
 return re.sub(r'src="([^"]+)"',image,text)

def marimo_app(doc, relative):
 lines=['import marimo', '', '__generated_with = "0.25.2"', 'app = marimo.App()', '',
        '@app.cell', 'def _():', '    import marimo as mo',
        '    from exakit.nb.example_runtime import Lesson, render',
        '    lesson = Lesson('+repr(relative)+')', '    return lesson, mo, render', '']
 step=0
 for cell in doc['cells']:
  text=''.join(cell['source']).strip()
  if not text: continue
  if cell['cell_type']=='markdown':
   text=marimo_links(text,relative)
   escaped = text.replace("\\", "\\\\").replace('"""', '\\"\\"\\"')
   lines += ['@app.cell(hide_code=True)', 'def _(mo):', '    mo.md("""', textwrap.indent(escaped, '    '), '    """)', '    return', '']
  elif cell['cell_type']=='code':
   step+=1; e=f'editor_{step:03d}';r=f'run_{step:03d}'
   lines += ['@app.cell','def _(mo):',f'    {e} = mo.ui.code_editor(value={text!r}, language="python", min_height=100)',
             f'    {r} = mo.ui.run_button(label="Run cell {step}")',f'    mo.vstack([{e}, {r}])',f'    return {e}, {r}','',
             '@app.cell',f'def _({e}, lesson, mo, render, {r}):',f'    mo.stop(not {r}.value)',
             f'    render(mo, lesson.run({e}.value))','    return','']
 lines += ['if __name__ == "__main__":','    app.run()','']
 return '\n'.join(lines)

def build(source):
 tree=source/'exasol/nb_connector/resources/notebooks'
 revision=subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip()
 entries=[]; assets=[]
 for path in sorted(tree.rglob('*')):
  if not path.is_file():continue
  relative=path.relative_to(tree).as_posix()
  if path.suffix!='.ipynb':
   for front in ('jupyter','marimo'):
    target=DEST/front/relative;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(path,target)
   if path.suffix.lower() in ('.png','.svg','.jpg','.jpeg','.gif'):
    target=DEST/'marimo/public/exasol-examples'/relative;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(path,target)
   assets.append(relative);continue
  original=json.loads(path.read_text()); category=relative.split('/')[0] if '/' in relative else '(start)'
  title=next((line.lstrip('# ').strip() for c in original['cells'] if c['cell_type']=='markdown' for line in ''.join(c['source']).splitlines() if line.startswith('# ')),path.stem.replace('_',' ').title())
  note=NOTES[category]
  header=f'# Bundled Exasol lesson: {title}\n\n{note}\n\nRun cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.\n\nFor dashboards use the kit Data Scientist 03_share flow on Dash Server.\n\nSource: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/{revision}/exasol/nb_connector/resources/notebooks/{relative}). MIT license: LICENSE.txt.'
  cells=[markdown(header),code('from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), '+repr(relative)+')')]
  for cell in original['cells']:
   cell=json.loads(json.dumps(cell));cell.pop('id',None)
   if cell['cell_type']=='code':
    raw=''.join(cell['source']); changed=adapt(raw,relative)
    if changed!=raw and not any(word in raw for word in ('password=', 'dsn=', '127.0.0.1', 'localhost', ':8563', 'sk-')):cell.setdefault('metadata',{})['exakit_original_source']=raw
    cell.update(source=changed.splitlines(keepends=True),execution_count=None,outputs=[])
   cells.append(cell)
  for i,c in enumerate(cells):c['id']='exasol-'+hashlib.sha256((relative+str(i)).encode()).hexdigest()[:16]
  doc={'cells':cells,'metadata':{'kernelspec':KERNEL,'language_info':{'name':'python'},'exakit_source':{'repository':'exasol/notebook-connector','revision':revision,'path':relative}},'nbformat':4,'nbformat_minor':5}
  output=DEST/'jupyter'/relative;output.parent.mkdir(parents=True,exist_ok=True);output.write_text(json.dumps(doc,indent=1,ensure_ascii=False)+'\n')
  output=DEST/'marimo'/Path(relative).with_suffix('.py');output.parent.mkdir(parents=True,exist_ok=True);output.write_text(marimo_app(doc,relative))
  entries.append({'path':relative,'title':title,'category':category,'requirements':note,'source_sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'cells':len(original['cells'])})
 index=['# Exasol example library','',f'All {len(entries)} notebooks from the official Notebook Connector collection are bundled here, with their supporting files.','',
        'Start with main_config, then first_steps. Data loaders prepare the tables used by the SQL, Ibis and scikit-learn lessons. Tutorial tables use EXAKIT_EXAMPLES.','',
        'Marimo: run the editable cells in order using each cell\'s Run button. This preserves Python variables and SQL magics without automatically running downloads or installation commands. Jupyter widget controls are available in the matching Jupyter version.','',
        'GPU, Transformers, Text AI and custom SLC tutorials need additional setup and are marked below. Cloud and external-source examples are reference only; the starter kit does not configure those integrations.','']
 for category in NOTES:
  selected=[e for e in entries if e['category']==category]
  if not selected:continue
  index += ['## '+('Getting started' if category=='(start)' else category.replace('_',' ').title()),'',NOTES[category],'']
  index += [f"- [{e['title']}]({e['path']})" for e in selected];index+=['']
 text='\n'.join(index)
 doc={'cells':[markdown(text)],'metadata':{'kernelspec':KERNEL,'language_info':{'name':'python'}},'nbformat':4,'nbformat_minor':5}
 (DEST/'jupyter/00_library.ipynb').write_text(json.dumps(doc,indent=1)+'\n')
 (DEST/'marimo/00_library.py').write_text(marimo_app(doc,'00_library.ipynb'))
 for front in ('jupyter','marimo'):shutil.copyfile(source/'LICENSE',DEST/front/'LICENSE.txt')
 (DEST/'manifest.json').write_text(json.dumps({'schema_version':1,'revision':revision,'repository':'https://github.com/exasol/notebook-connector','notebooks':entries,'assets':assets},indent=2)+'\n')
 print(f'Bundled {len(entries)} notebooks for Jupyter and Marimo, plus {len(assets)} supporting files, from {revision}.')

if __name__=='__main__':build(Path(sys.argv[1]))
