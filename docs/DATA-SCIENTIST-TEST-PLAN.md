# Data Scientist: clean machine to every feature (Mac)

One pass, in order, from an empty machine: the persona screen, the data, the notebooks, your own
file, Ask with a model, Langfuse tracing, a shared dashboard, then the UDF side (Python training,
MLflow, Rust scoring). Tick the checklist at the bottom as you go and note the time where it asks.

> Terminal = the Mac Terminal app. Copy one grey box at a time and wait for it to finish.
> Never paste a password or API key into a notebook. Keys go in Terminal only.

What you need before you start:

- your GitHub token for the private staging repository
- **Docker Desktop or Colima running** (only for Part 9, the Rust build) - start it yourself
- optional: **Ollama** with one chat model pulled (Part 6), and a **Langfuse** project's keys (Part 7)

---

## Part 0. Clean everything

This deletes the kit's database, data, add-ons, notebooks and AI-client entries. Copy anything you
want to keep first.

```bash
EXAKIT_UNINSTALL_NOTEBOOKS=remove ~/.local/bin/exakit uninstall
```

In the menu choose **EVERYTHING**, then confirm.

Check nothing is left - each command must print **nothing**:

```bash
ls -d ~/.exasol-starter-kit ~/.exasol/personal/deployments/default 2>/dev/null
ls ~/.local/bin | grep -E '^(exakit|exasol|exapump|dash-server)$'
launchctl list | grep exakit
ls ~/Library/LaunchAgents | grep exakit
```

If something is still listed, write it in the checklist (that is a finding) before you go on.

---

## Part 1. Install and the persona screen

Note the time, then:

```bash
export GITHUB_TOKEN=<your token>
```

```bash
curl -fsSL https://www.exasol.com/install/starter-kit.sh | EXAKIT_REPO=ranjanm-chn/exasol-personal-local-starterkit-backup EXAKIT_REF=feat/descriptor-approve EXAKIT_VERSION_POLICY=pinned sh
```

When it asks **What will you use this machine for?**:

| Check | Expected |
|---|---|
| Rows | **Data Scientist**, **ML Engineer**, **General** - General is ticked |
| Looks | the same frame, colours and `[✓]` boxes as the other kit menus (no different-looking window) |
| Click a row | its tick turns on or off; nothing else happens |
| Mouse wheel | the terminal scrolls back; the menu does not stick on screen |
| Resize the window | the earlier output stays; the menu redraws once |

Tick **Data Scientist**, untick **General**, press **Enter**.

Watch the rest:

| Check | Expected |
|---|---|
| Steps 1-6 | Launcher, database (about 2 minutes), exapump, AI bridge, pyexasol, exakit helper - each `[ok]` |
| Datasets | Esophageal posts, Banking complaints, Bank marketing, ADE corpus, PubMed abstracts, Medication sigs - each "loaded and verified" |
| After the data | a spinner ("Getting the add-ons ready" / "Opening the add-ons") - never a silent pause |
| Add-ons table, while choosing | columns **Add-on, Version, Description**; dash-server and notebook ticked; notebook's JupyterLab / Marimo / Positron rows under it |
| Add-ons table, after Enter | columns **Add-on, Version, Status** only - the Description is gone; a progress bar with % and the step above the active row |
| End | `[ok] Your starter kit is ready to use.` |

Write down the minutes from start to the end line (goal: **under 10**).

---

## Part 2. Check the install

```bash
exakit status
exakit persona plan data-scientist
```

- Runtime **running**, Database **reachable**, Autostart **enabled**
- Add-ons: **dash-server running** (http://127.0.0.1:5100), **notebook installed**
- persona plan: **nothing pending**

Row counts:

```bash
exakit sql "SELECT 'Esophageal' D, COUNT(*) N FROM ESOPHAGEAL.ESOPHAGEAL_POSTS UNION ALL SELECT 'Banking', COUNT(*) FROM BANKING.BANKING_COMPLAINTS UNION ALL SELECT 'Bank marketing', COUNT(*) FROM BANKMKT.BANK_CLIENTS UNION ALL SELECT 'ADE', COUNT(*) FROM ADE.ADE_SENTENCES UNION ALL SELECT 'PubMed', COUNT(*) FROM PUBMED.PUBMED_ABSTRACTS UNION ALL SELECT 'Sigs', COUNT(*) FROM MEDSIGS.MEDICATION_SIGS"
```

Expected: Esophageal **40987**, Banking **214742**, Bank marketing **45211**, ADE **20960**, PubMed **1409**, Sigs **50**.

Settings file - every setting is listed with its default:

```bash
grep -c '^# EXAKIT_' ~/.exasol-starter-kit/exakit.env
```

A number above 50. To change one, remove the `# ` in front of its line.

Personal details removed from Esophageal (forum quotes, post/member numbers, Reddit names; `u/user` is the
scrubber's own placeholder) - prints **0**:

```bash
exakit sql "SELECT COUNT(*) AS LEFT_OVER FROM ESOPHAGEAL.ESOPHAGEAL_POSTS WHERE MESSAGE REGEXP_LIKE '(?is).*(\[quote=|\b(post|member):\s*[0-9]|(^|[^a-z0-9/])/?u/(?!user\b)[a-z0-9_-]{3,}).*'"
```

Dash Server: open http://127.0.0.1:5100 - **no "Demo Dashboard"** (Total dashboards **0**).

---

## Part 3. The notebooks (JupyterLab)

```bash
exakit notebook
```

Choose **JupyterLab**. Kernel top right: **Exasol (Starter Kit)**.

### 3.1 Quickstart

**starter-kit-notebooks → data-scientist → 00_quickstart.ipynb** → **Run → Run All Cells**.

- It prints a **workflow id** (`wf-2026...`) - write it down; paste it into `WORKFLOW_ID = ...` in each later notebook.
- The descriptor is **approved** (shipped) or shows a role form; if a form, look it over, click **Approve descriptor**.
- The last cells show rows. Minutes from install start to these rows (goal **under 10**): note it.

### 3.2 Role picker shows the drafted roles

New notebook (**File → New → Notebook**, kernel Exasol (Starter Kit)):

```python
import exakit_nb as nb
d = nb.describe("esophageal_posts")
d.show()
```

- Each column has a **role** (key, time, measure, category, flag, text, identifier, other), **confidence**, **evidence**.
- Slots: key `POST_ID`, time `CREATED_TIME`, text `MESSAGE`, category `SOCIAL_NETWORK`, entity `SOURCE_DOMAIN`; **target empty**.
- Open the role-review form (the quickstart's picker): every dropdown shows the drafted role, none blank.

```python
d.slot(target="IS_NEGATIVE")
ds = d.approve()
d.approve()          # second time: "nothing was written"
d.set(TITLE="wrong") # must refuse and list the eight roles
```

### 3.3 Approve from Terminal and see the roles in your AI client

```bash
exakit describe banking_complaints --approve --role target=MONETARY_RELIEF
exakit describe bank_marketing --approve --role target=SUBSCRIBED
exakit describe ade_corpus --approve --role target=HAS_ADE
exakit describe bank_marketing --versions
```

Each prints **Approved ... v1** and **Published as EXAKIT_SEMANTIC...**. Banking: time **DATE_RECEIVED**, no text column (it says why).

Quit and reopen Claude, then ask: *"List the views in schema EXAKIT_SEMANTIC and describe ESOPHAGEAL__ESOPHAGEAL_POSTS with each column's role."* Every column shows `role=...`.

### 3.4 Explore

**data-scientist → 01_explore.ipynb** → Run All. Charts, a local scikit-learn result, the handoff at the end.
Then set `DATASET = "banking_complaints"` and run again: it works; the text step **skips and says why**.
Once more with `DATASET = "ade_corpus"`.

### 3.5 The same in Marimo

```bash
exakit notebook
```

Choose **Marimo**. Open **data-scientist/00_quickstart.py** and **01_explore.py**; both run. The role picker
there also shows the drafted roles.

---

## Part 4. Your own file

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
d = nb.describe("MY_DATA.TICKETS"); d.show()
```

- `CUSTOMER_EMAIL`: **identifier**, **sensitive** (never charted or sent to a model), in no slot
- slots: key `TICKET_ID`, time `OPENED_ON`, text `BODY`, category `CHANNEL`

```python
d.slot(target="ESCALATED"); ds = d.approve()
```

Run **01_explore** with `DATASET = "my_data_tickets"` - unchanged otherwise.

Change the table and describe again:

```bash
exakit sql "ALTER TABLE MY_DATA.TICKETS ADD COLUMN PRIORITY VARCHAR(10)"
```

```python
d2 = nb.describe("MY_DATA.TICKETS"); d2.show()
```

Draft **v2**: `PRIORITY` flagged as changed; every other choice (target too) kept.

---

## Part 5. Ask your data (no model)

**data-scientist → 02_ask_your_data.ipynb**, keep `DRAFT_WITH_MODEL = False` → Run All.
It shows supplied SQL; set `APPROVE_SQL = True`, run that cell: the result comes back through the
**read-only** user.

---

## Part 6. A model: Ask drafting and Explore themes (optional, needs a model server)

Ollama example (any server in `notebook/MODEL-PROVIDERS.md` works the same way):

```bash
ollama list
```

```bash
exakit notebook stop
export EXAKIT_MODEL_ID="<a name from ollama list>"
export EXAKIT_PROVIDER_BASE_URL="http://localhost:11434/v1/"
exakit notebook
```

In a notebook: `import exakit_nb as nb; nb.model_settings()` - shows the model and URL, never a key.

- **02_ask_your_data**: `DRAFT_WITH_MODEL = True` → Run All. You get proposed SQL with assumptions and
  doubts; nothing runs until `APPROVE_SQL = True`. Check the answer against the SQL yourself.
- **01_explore**: `USE_AI_THEMES = True` → run the themes cell. Short summaries of a few texts appear.

A small local model may write wrong SQL - that is a finding about the model, not the kit. Note it.

---

## Part 7. Langfuse tracing (optional, needs a Langfuse project)

The notebook server must be **restarted** from a Terminal that has the keys:

```bash
exakit notebook stop
read -r -s "LANGFUSE_SECRET_KEY?Langfuse secret key: "; printf '\n'
export LANGFUSE_SECRET_KEY
export LANGFUSE_PUBLIC_KEY="<pk-lf-...>"
export LANGFUSE_BASE_URL="https://cloud.langfuse.com"
exakit notebook
```

(Keep the Part 6 model variables in the same Terminal.) Run **01_explore** with `USE_AI_THEMES = True`.

In Langfuse: a trace for the workflow with the model calls, their input/output, token usage, and tags for
the **workflow id**, **dataset/descriptor** and **database session**. Without the keys the notebook says
"tracing is off" and runs unchanged.

---

## Part 8. Share a dashboard (Dash Server)

**data-scientist → 03_share.ipynb**, paste your workflow id → Run All.

- It prints the SQL and a **preview URL** - open it: filters, Top N, sort, two charts, summary cards, a table you can export.
- Compare its counts with the printed SQL. Only then set `FIGURES_CHECKED = True` and run the last cell.
- It prints the **live URL** (`/apps/esophageal-posts-category-overview`).

Open http://127.0.0.1:5100:

- your dashboard is listed with the line **"From the approved esophageal_posts data, descriptor v1."**
  (never "Live Exasol dashboard backed by profile starter-kit")
- there is **no Demo Dashboard**

Ask Claude: *"Build a dashboard of Banking complaints per product on Dash Server."* It uses the dash-server
tools and gives you a URL.

---

## Part 9. UDFs: Python training, MLflow, Rust scoring

The UDF tools are the **udf-devkit** add-on, which comes with the ML Engineer persona. Add it on top -
your data and notebooks stay:

```bash
exakit persona add ml-engineer
exakit persona plan ml-engineer
exakit mlflow status
```

- It installs the Python UDF container (asks before the **database restart**; about 10 minutes the first time).
- persona plan: **nothing pending**; MLflow **running** at http://127.0.0.1:5000.
- `launchctl list | grep exakit` shows **com.exasol.exakit.udf-devkit** with **0** in the middle column.

### 9.1 Python UDF check and training

JupyterLab: **ml-engineer → 00_quickstart.ipynb** → Run All (connection, container and MLflow checks pass).

**ml-engineer → 01_train.ipynb** → Run All with `DATASET = "esophageal_posts"`, then again with
`DATASET = "bank_marketing"` and `CLASS_WEIGHT = "balanced"`.

```bash
exakit mlflow url
```

Open it: both runs, with metrics, `training.sql`, the model, and tags `exasol.session_id` /
`exasol.statement_id` and the model's **SHA-256** (`exasol.model_sha256`); a model over 1 MB comes back in parts and
the digest still matches.

### 9.2 Bucket files

```bash
printf 'bucket check\n' > ~/bucket-check.txt
exakit model put ~/bucket-check.txt
exakit model list
exakit model rm bucket-check.txt
```

`put` prints `/buckets/bfsdefault/default/models/bucket-check.txt`; list shows it; rm removes it.

### 9.3 Rust scoring (Docker or Colima must be running)

```bash
docker info >/dev/null && echo docker ok
```

**ml-engineer → 02_rust_score.ipynb**, `DATASET = "esophageal_posts"` → Run All.

- It creates, builds (in a Linux container) and deploys the Rust scoring UDF.
- It compares Rust scores with the Python model on `TEST_ROWS` held-out rows: **labels agree**, the maximum
  probability difference is tiny (below 1e-9).
- If it stops with "the shared bucket is unavailable": that is the fallback. Set
  `ALLOW_DATABASE_RESTART = True` only if a restart is fine now, run again - it packages the library into the
  RUST container, restarts the database once, then scores. Run it a **second** time: it **reuses** the
  container (no restart).

The same from Terminal:

```bash
exakit rust-udf new score_check
exakit rust-udf build score_check
exakit rust-udf deploy score_check
```

### 9.4 Score a model trained elsewhere

**ml-engineer → 03_score_external_model.ipynb** → Run All. The in-database predictions equal the local ones
on the held-out rows.

### 9.5 Useful lessons

Run **useful-notebooks → data-scientist → 01_sql_and_dataframes**, **02_decision_tree_baseline** and
**ml-engineer → 01_udf_package_check**, **02_decision_tree_udf**. Each runs to the end.

---

## Part 10. Logs, privacy, restart

```bash
exakit workflow list
exakit workflow show <your workflow id>
```

You see draft, approve, ask, share and train events, each with its SQL.

No password in any notebook, descriptor or log - **no output is good**:

```bash
PWFILE=$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('~/.exasol-starter-kit/manifest.json')))['runtime']['password_file'])")
grep -rIlF -f "$PWFILE" ~/.exasol-starter-kit/notebooks ~/.exasol-starter-kit/descriptors ~/.exasol-starter-kit/workflows ~/.exasol-starter-kit/logs ~/Library/Jupyter/kernels 2>/dev/null
```

Restart the Mac (or log out and in). Then:

```bash
exakit status
launchctl list | grep exakit
```

Database **running**, Dash Server **running**, MLflow **running**; every exakit entry shows **0**.

---

## Part 11. Remove pieces again

```bash
exakit persona remove ml-engineer
exakit uninstall udf-devkit --dry-run
exakit uninstall notebook --dry-run
```

- persona remove keeps shared data and add-ons the Data Scientist still uses.
- `--dry-run` lists what would go and changes nothing.

---

## Checklist

| Part | What | ✓ | Note (minutes, message) |
|---|---|---|---|
| 0 | clean: four checks print nothing | | |
| 1 | persona screen: look, click, wheel, resize, Enter | | |
| 1 | six datasets loaded; spinner after data | | |
| 1 | add-ons table: Description while choosing, Version + Status while installing | | |
| 1 | install minutes | | min: |
| 2 | status, nothing pending, row counts, env file, Esophageal check 0, no demo dashboard | | |
| 3.1 | quickstart rows; minutes from install start | | min: |
| 3.2 | drafted roles in picker; approve v1; second approve writes nothing; wrong role refused | | |
| 3.3 | Terminal approvals; AI client shows roles | | |
| 3.4 | Explore on Esophageal, Banking, ADE | | |
| 3.5 | Marimo quickstart and explore | | |
| 4 | own file: email sensitive; explore; v2 keeps choices | | |
| 5 | Ask without a model, approved SQL runs read-only | | |
| 6 | model: Ask draft and themes | | model: |
| 7 | Langfuse trace with workflow/dataset/session tags | | |
| 8 | Share preview → confirmed live; catalog line; no demo; Claude-built dashboard | | |
| 9 | ml-engineer added, udf-devkit autostart 0, MLflow running | | |
| 9.1 | two training runs in MLflow with digest | | |
| 9.2 | bucket put / list / rm | | |
| 9.3 | Rust scores match Python; fallback consent and reuse | | |
| 9.4 | external model scores match | | |
| 9.5 | four useful lessons | | |
| 10 | workflow events; password scan empty; all running after restart | | |
| 11 | persona remove keeps data; dry runs change nothing | | |

If something fails: copy the message, then run `exakit status` and `exakit logs setup --lines 100`, and
keep both outputs with the checklist.
