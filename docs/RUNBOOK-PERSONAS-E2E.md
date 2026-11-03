# Persona end-to-end runbook: fresh install and an existing kit

For Sheetal's own end-to-end run on a Mac, against the Sprint 1 plan (High Level Development Plan v3.0). It covers
the items due now:

| Plan item | What is proved here | Sections |
|---|---|---|
| Gantt #5 / Sprint 1 #9 - notebook add-on (DS-1), due 3 Nov | JupyterLab opens connected, rows back in a notebook, no secret in generated files | A3, A4 |
| Gantt #6 / Sprint 1 #10-#11 - datasets, descriptor, describe and approve (DS-2, DS-5), due 4 Nov | the three reference datasets load and check; the descriptor drafts, corrects, approves and publishes; your own file gets the same | A2, A5-A8 |
| Gantt #7 / Sprint 1 #12 - workflow id and log (X-1) | one workflow id on the draft, the approval and the SQL; no secret in the log | A9 |
| Sprint 1 #20 / Sprint 2 #7 - both persona files (P-1) | a clean install gives exactly the persona's datasets and add-ons; plan clean | A2, A10, B |

Run **Part A** on a clean machine (or after a full uninstall) and **Part B** on the kit you already have. Record
each check in the table at the end. Use Terminal for shell commands and the **Exasol (Starter Kit)** kernel for
notebook cells. Never paste a password anywhere: the commands below only ever print file names.

## 0. The candidate

```bash
cd /Users/sheetaldharshan.a/Desktop/starterkit-0.2.0-descriptor
git branch --show-current
git log -1 --oneline
```

Expect branch `feat/descriptor-approve`. Write the commit down in the results table. The reference datasets' release
assets are **not published yet**, so the install must come from this checkout (`EXAKIT_LOCAL_KIT`): the kit then
loads the CSVs from the checkout after checking their SHA-256. Keep `EXAKIT_VERSION_POLICY=pinned` in this shell.

```bash
export PATH="$HOME/.local/bin:$PATH"
export EXAKIT_VERSION_POLICY=pinned
export KIT="$PWD"
```

## Part A - fresh installation

### A1. Clean reset (only if a kit is installed; destructive - you run it)

```bash
EXAKIT_UNINSTALL_NOTEBOOKS=remove exakit uninstall --dry-run
```

Read the plan. If it is right:

```bash
EXAKIT_UNINSTALL_NOTEBOOKS=remove exakit uninstall
```

Choose **EVERYTHING** and confirm. Skip A1 if `exakit` is not installed.

### A2. Install with the Data Scientist persona, and time it

```bash
date
curl -fsSL https://www.exasol.com/install/starter-kit.sh | EXAKIT_LOCAL_KIT="$KIT" EXAKIT_PERSONA=data-scientist EXAKIT_NOTEBOOK_FRONTENDS=jupyterlab,marimo sh
date
```

The log must say it uses the **local kit checkout**. Then:

```bash
exakit status
exakit persona plan data-scientist
exakit sql "SELECT 'esophageal_posts' AS DATASET, COUNT(*) AS N FROM ESOPHAGEAL.ESOPHAGEAL_POSTS UNION ALL SELECT 'banking_complaints', COUNT(*) FROM BANKING.BANKING_COMPLAINTS UNION ALL SELECT 'bank_marketing', COUNT(*) FROM BANKMKT.BANK_CLIENTS"
```

Pass (P1.1, DS2.1): status running; the plan says nothing is pending; counts **40,987**, **6,754** and **45,211**;
add-ons: notebook. The install output shows each dataset's verify script as OK (Esophageal also runs a privacy check:
no handle, link or e-mail left in its text).

### A3. Notebook add-on (DS-1)

```bash
exakit notebook check
exakit notebook
```

`check` proves the connection and starts nothing. `exakit notebook` opens JupyterLab logged in, on
`starter-kit-notebooks/`. Open `data-scientist/00_quickstart.ipynb` and run all cells. Note the time from the
`date` before the install to the first rows in the notebook.

Pass (DS1.1): rows back in the notebook under **10 minutes** from install start; the quickstart prints a workflow
id and the sample's roles.

### A4. No credentials in generated files (DS1.2, X1.2)

```bash
PWFILE=$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('~/.exasol-starter-kit/manifest.json')))['runtime']['password_file'])")
grep -rIlF -f "$PWFILE" ~/.exasol-starter-kit/notebooks ~/.exasol-starter-kit/descriptors ~/.exasol-starter-kit/workflows ~/Library/Jupyter/kernels 2>/dev/null && echo "FOUND - stop and report" || echo "no password in notebooks, descriptors, workflows or kernels"
```

Pass: the second message. (The command prints file names only, never the password.)

### A5. Describe and approve a shipped dataset (DS-5) - notebook

New notebook on the **Exasol (Starter Kit)** kernel:

```python
import exakit_nb as nb
d = nb.describe("esophageal_posts")
d.show()
```

Check against `data/datasets/esophageal_posts/descriptor.yaml` in the checkout:

- every column has one of the eight roles (key, time, measure, category, flag, text, identifier, other) with its
  confidence and evidence; low-confidence rows are listed first;
- slots: key `POST_ID`, time `CREATED_TIME`, text `MESSAGE`, category `SOCIAL_NETWORK`, entity `SOURCE_DOMAIN`;
  **target empty** ("set by the user; never drafted") - DS5.3.
- `d.doc["source"]["schema_digest"]` equals the shipped file's `schema_digest`. **If it differs, write both down**:
  the shipped digest is computed from the CREATE TABLE types, and the database may name a type differently (for
  example `TIMESTAMP(3)`); that is a finding to fix before RC1.

Correct and approve:

```python
d.slot(target="IS_NEGATIVE")
d.set(TITLE="text")                  # try an unknown role too: d.set(TITLE="ninth") must fail and list the roles
ds = d.approve()
ds.status, ds.version
```

Pass (DS5.2, DS2.5): `approved`, `1`; it prints `Published as EXAKIT_SEMANTIC.ESOPHAGEAL__ESOPHAGEAL_POSTS`.
Run `d.approve()` again: "already says this; nothing was written". Then:

```bash
ls ~/.exasol-starter-kit/descriptors/ESOPHAGEAL.ESOPHAGEAL_POSTS/
exakit describe esophageal_posts --versions
exakit sql "SELECT COLUMN_NAME, COLUMN_COMMENT FROM EXA_ALL_COLUMNS WHERE COLUMN_SCHEMA = 'EXAKIT_SEMANTIC' AND COLUMN_TABLE = 'ESOPHAGEAL__ESOPHAGEAL_POSTS' ORDER BY COLUMN_ORDINAL_POSITION"
```

Pass: `v1.yaml`, `current.yaml` and `v1.profile.json`; every column comment starts with `role=`.

**Agents see the roles (DS5.4, plan #4):** in Claude Desktop or Claude Code connected through the kit's MCP server,
ask: *"Describe the view EXAKIT_SEMANTIC.ESOPHAGEAL__ESOPHAGEAL_POSTS and list each column's role."* Pass: the
answer quotes the `role=...` comments. Your own table `ESOPHAGEAL.ESOPHAGEAL_POSTS` carries **no** new comment.

### A6. The same from the command line (both datasets of banking)

```bash
exakit describe BANKING.BANKING_COMPLAINTS --id banking_complaints
exakit describe banking_complaints --approve --role target=MONETARY_RELIEF
exakit describe BANKMKT.BANK_CLIENTS --id bank_marketing
exakit describe bank_marketing --approve --role label=SUBSCRIBED
exakit describe bank_marketing --show
```

Pass: banking drafts text **empty** ("no text column": the CFPB no longer publishes narratives) and time
`DATE_SENT_TO_COMPANY`; bank marketing drafts time, text and entity empty with their reasons; `label=` is accepted as
the old name of `target=`. Wrong input exits 2 with the reason: `exakit describe bank_marketing --approve --role owner=X`.

### A7. Your own file - upload and describe (DS-2, DS2.3)

Make a small CSV with an e-mail column (sensitive) and a 0/1 outcome:

```bash
mkdir -p ~/my-data && python3 - <<'PY'
import csv, datetime, os, random
random.seed(1)
with open(os.path.expanduser("~/my-data/tickets.csv"), "w", newline="") as f:
    w = csv.writer(f); w.writerow(["TICKET_ID", "OPENED_ON", "CHANNEL", "CUSTOMER_EMAIL", "ESCALATED", "BODY"])
    for i in range(1500):
        w.writerow([1000 + i, (datetime.date(2025, 1, 1) + datetime.timedelta(days=i % 300)).isoformat(),
                    ["web", "phone", "mail"][i % 3], f"customer{i % 400}@example.org", int(random.random() < 0.1),
                    f"Ticket {i}: the {['invoice', 'delivery', 'password', 'refund'][i % 4]} problem is still open after {i % 9} days"])
PY
```

In a notebook:

```python
import exakit_nb as nb
nb.load_own_file("~/my-data/tickets.csv", "MY_DATA.TICKETS")
d = nb.describe("MY_DATA.TICKETS")
d.show()
d.slot(target="ESCALATED")
ds = d.approve()
```

Pass: `CUSTOMER_EMAIL` is `identifier` and **sensitive**, never a slot; `TICKET_ID` key, `OPENED_ON` time, `BODY`
text, `CHANNEL` category; target empty until you set it. Then open `data-scientist/01_explore.ipynb`, set
`DATASET = "my_data_tickets"` and run it: it runs unchanged (DS2.3); steps that need an empty slot (here the
entity) skip and say why.

Change the table and describe again (carry-over):

```bash
exakit sql "ALTER TABLE MY_DATA.TICKETS ADD COLUMN PRIORITY VARCHAR(10)"
```

```python
d2 = nb.describe("MY_DATA.TICKETS"); d2.show()
```

Pass: a draft **v2**; `PRIORITY` flagged "changed since v1"; the other columns and the target keep your v1 choices;
v1 is still approved until you approve v2.

### A8. A draft is refused where an approval is needed (DS2.5)

```python
draft = nb.describe("MY_DATA.TICKETS", force=True)
draft.save("/tmp/tickets.draft.yaml")
nb.dataset(conn := nb.connect(), "/tmp/tickets.draft.yaml").require_approved("training")
```

Pass: `DescriptorNotApproved` naming how to approve it.

### A9. Workflow id and log (X-1)

The quickstart's first cell printed a workflow id. Then:

```bash
exakit workflow list
exakit workflow show <the id>
```

Pass: the lines `describe.draft` and `describe.approve` (with the table and version) and the SQL statements of the
run, under that one id. A4's grep already proved the log holds no password.

### A10. Add the ML Engineer persona

```bash
exakit persona add ml-engineer
exakit persona plan ml-engineer
exakit mlflow status
```

Pass: nothing pending; udf-devkit installed with the Python container (the smoke UDF passed in the output); MLflow
running (else `exakit mlflow start`). Open `ml-engineer/00_quickstart.ipynb`, then `01_train.ipynb` with
`DATASET = "esophageal_posts"`; the run appears in MLflow (`exakit mlflow url`) with the descriptor version and
data digest tags. Repeat `01_train` with `DATASET = "bank_marketing"`.

## Part B - the kit you already have

### B1. Before

```bash
exakit version
exakit persona plan
exakit status
```

Write down the version, the personas recorded and the datasets loaded.

### B2. Bring the candidate onto the existing kit

```bash
curl -fsSL https://www.exasol.com/install/starter-kit.sh | EXAKIT_LOCAL_KIT="$KIT" sh
```

The installer resumes: it keeps the database, its data and your MCP configuration and replaces the kit's code with
the checkout. Then:

```bash
exakit persona add data-scientist
exakit persona plan data-scientist
```

Pass: Esophageal and Bank marketing load, Banking is "already loaded"; nothing pending; your existing data and
notebooks are still there. An older kit's `pharma_trials` schema stays in the database untouched (remove it yourself
when you no longer need it); descriptors you approved before under `~/.exasol-starter-kit/descriptors/<id>/` still
read.

### B3. The same checks

Run A3 to A9 on this kit, then A10 (`exakit persona add ml-engineer`).

## Results

| Check | Plan / AC | Pass? | Time / note |
|---|---|---|---|
| Candidate commit | - | | |
| A2 install + datasets + plan | P1.1, DS2.1 | | install minutes: |
| A3 rows in the notebook | DS1.1 | | minutes from install start: |
| A4 no password in files | DS1.2, X1.2 | | |
| A5 draft, correct, approve, publish | DS5.1-5.3, DS2.5 | | schema digest equal? |
| A5 agents see the roles | DS5.4, plan #4 | | |
| A6 CLI on both banking datasets | DS-5 | | |
| A7 own file: sensitive column, explore unchanged | DS2.3 | | |
| A7 carry-over to v2 | DS-5 step 4 | | |
| A8 draft refused | DS2.5 | | |
| A9 workflow lines | X1.1 | | |
| A10 ML Engineer persona, train, MLflow | P1.1, ML-2 | | |
| B2 existing kit keeps data, adds personas | Sprint 1 #19 | | |

## Known gaps in this candidate

- **First live load of the new datasets.** Esophageal posts and Bank marketing were checked offline
  (`tools/dataset_check.py --offline`, the unit tests), never loaded into a database yet. Watch A2: if a load or a
  verify line fails (most likely the `CREATED_TIME` timestamps, or the privacy check's regular expression), copy the
  message into the results - `exakit data-load esophageal_posts --force` retries one dataset.
- The reference datasets' release assets are not published: installs must use `EXAKIT_LOCAL_KIT` until they are.
- Esophageal posts: third-party social media content; **terms not confirmed** (`terms.confirmed: false`). Personal
  data is removed, but forum posts can still name first names. Owner decision before release.
- Banking complaints has no text column: the CFPB no longer publishes narratives, so the text steps skip on Banking.
- Semantic fusion (Part 2 of the descriptor plan: Semantic Views model, the fused entity) is not built yet.
- Windows: run the same sections in PowerShell with `$env:EXAKIT_LOCAL_KIT = 'C:\path\to\checkout'` and
  `irm https://www.exasol.com/install/starter-kit.ps1 | iex`; not yet run.
