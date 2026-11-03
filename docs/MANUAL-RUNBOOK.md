# Test the starter kit yourself (Mac)

Two ways in - pick one:

- **Path A - fresh install**: start from nothing (or wipe your kit first).
- **Path B - the kit you already have**: keep your data, add the new version on top.

Both end with the same tests: **Data Scientist**, **your own file**, **ML Engineer**.
Tick each line in the checklist at the bottom as you go.

> Terminal = the Mac Terminal app. Notebook = JupyterLab in your browser.
> Copy one grey box at a time, press Enter, and wait until it finishes.

---

## Before you start (both paths)

1. Open **Terminal**.
2. Go to the kit folder and check you are on the right version:

   ```bash
   cd ~/Desktop/starterkit-0.2.0-descriptor
   git log -1 --oneline
   ```

   You see one line starting with a commit number. Write it in the checklist.

3. Set up this Terminal window (do this again if you open a new window):

   ```bash
   export PATH="$HOME/.local/bin:$PATH"
   export EXAKIT_VERSION_POLICY=pinned
   export KIT="$PWD"
   ```

---

## Path A - fresh install

### A1. Wipe the old kit (skip if you have none)

This deletes the kit's database and notebooks. Save anything you need first.

```bash
EXAKIT_UNINSTALL_NOTEBOOKS=remove exakit uninstall
```

In the menu choose **EVERYTHING**, then confirm.

### A2. Install with the Data Scientist persona

Note the time, then run:

```bash
curl -fsSL https://www.exasol.com/install/starter-kit.sh | EXAKIT_LOCAL_KIT="$KIT" EXAKIT_PERSONA=data-scientist EXAKIT_NOTEBOOK_FRONTENDS=jupyterlab,marimo sh
```

Wait until it says it is done (a few minutes). Near the top it should say **Using local kit checkout**.

Want to see the persona screen as well? Run the same command **without** `EXAKIT_PERSONA=data-scientist`. When it asks *What will you use this machine for?*:

- three rows: **Data Scientist**, **ML Engineer**, **General** - General is ticked
- click a row: its tick turns on or off; nothing else happens
- scroll with the mouse wheel: the terminal scrolls, the screen does not stick
- press **Enter**: the install goes on
- the add-on screen after the data looks like the data table: same frame, same progress bar

Your settings: open `~/.exasol-starter-kit/exakit.env`. Every setting is there with its default; remove the `# ` in front of a line to change it.

Go to **Check the install** below.

---

## Path B - the kit you already have

### B1. Note what you have

```bash
exakit version
exakit persona plan
```

Write down the version and the personas shown.

### B2. Put the new version on your kit

```bash
curl -fsSL https://www.exasol.com/install/starter-kit.sh | EXAKIT_LOCAL_KIT="$KIT" sh
```

It keeps your database, data and AI-client settings.

### B3. Add the Data Scientist persona

```bash
exakit persona add data-scientist
```

You should see the new datasets download and load (Esophageal posts, Bank marketing, ADE corpus, PubMed abstracts, Medication sigs); Banking loads its new twelve months.

---

## Check the install (both paths)

```bash
exakit status
exakit persona plan data-scientist
exakit sql "SELECT 'Esophageal' AS DATA, COUNT(*) AS ROWS_ FROM ESOPHAGEAL.ESOPHAGEAL_POSTS UNION ALL SELECT 'Banking', COUNT(*) FROM BANKING.BANKING_COMPLAINTS UNION ALL SELECT 'Bank marketing', COUNT(*) FROM BANKMKT.BANK_CLIENTS UNION ALL SELECT 'ADE', COUNT(*) FROM ADE.ADE_SENTENCES UNION ALL SELECT 'PubMed', COUNT(*) FROM PUBMED.PUBMED_ABSTRACTS UNION ALL SELECT 'Sigs', COUNT(*) FROM MEDSIGS.MEDICATION_SIGS"
```

You should see:

- status: **running**
- persona plan: **nothing pending**
- rows: Esophageal **40987**, Banking **214742**, Bank marketing **45211**, ADE **20960**, PubMed **1409**, Sigs **50**

If a dataset is missing: `exakit data-load esophageal_posts` (or `bank_marketing`, `banking_complaints`, `ade_corpus`, `pubmed_abstracts`, `medication_sigs`).

---

## 1. Data Scientist

### 1.1 Open the notebooks

```bash
exakit notebook
```

Choose **JupyterLab**. Your browser opens.

In the left panel open: **starter-kit-notebooks → data-scientist → 00_quickstart.ipynb**.
Top right, the kernel must say **Exasol (Starter Kit)**.

### 1.2 Run the quickstart

Menu **Run → Run All Cells**.

- It prints a **workflow id** (looks like `wf-20261103-...`). Write it down.
- It says the sample's descriptor is **approved: nothing to review** (it ships approved). If instead a small form
  shows each column's role, look it over and click **Approve descriptor**.
- The last cells show rows from the data.

From the install start to these rows should take **under 10 minutes**.

### 1.3 Describe and approve a dataset yourself

In JupyterLab: **File → New → Notebook**, pick **Exasol (Starter Kit)**. Paste into the first cell and run it (Shift+Enter):

```python
import exakit_nb as nb
d = nb.describe("esophageal_posts")
d.show()
```

You see a table: every column with a **role**, **confidence** and **evidence**. The line at the top shows the **slots**:

- key `POST_ID`, time `CREATED_TIME`, text `MESSAGE`, category `SOCIAL_NETWORK`, entity `SOURCE_DOMAIN`
- **target is empty** (the kit never guesses it)

Next cell:

```python
d.slot(target="IS_NEGATIVE")
ds = d.approve()
```

You see **Approved ... v1** and **Published as EXAKIT_SEMANTIC.ESOPHAGEAL__ESOPHAGEAL_POSTS**.

Run `d.approve()` once more: it says **nothing was written** (nothing changed).

Try a wrong role - it must refuse and list the right ones:

```python
d.set(TITLE="wrong")
```

### 1.4 Ask your AI client about the roles

First refresh the AI-client setup so it lists views, then **quit and reopen Claude**:

```bash
exakit mcp-setup
```

In Claude (connected to the kit), ask:

*"Describe the view EXAKIT_SEMANTIC.ESOPHAGEAL__ESOPHAGEAL_POSTS and list each column's role."*

The answer should show `role=...` for each column. Then ask *"List the views in the schema EXAKIT_SEMANTIC."* -
the view must be in the list (Claude finds it without being told its name).

### 1.5 The same from Terminal (Banking and Bank marketing)

```bash
exakit describe BANKING.BANKING_COMPLAINTS --id banking_complaints
exakit describe banking_complaints --approve --role target=MONETARY_RELIEF
exakit describe BANKMKT.BANK_CLIENTS --id bank_marketing
exakit describe bank_marketing --approve --role target=SUBSCRIBED
exakit describe bank_marketing --versions
```

Each approve prints **Approved ... v1**. Banking's time column is **DATE_RECEIVED** and it has **no text** column;
Bank marketing has **no time or text** column - each says why.

### 1.6 Explore

Open **data-scientist → 01_explore.ipynb** and **Run All Cells**. Charts and a model result appear. Then change the first line to `DATASET = "banking_complaints"` and run again - it works without other changes (the text step skips and says why).

---

## 2. Your own file

### 2.1 Make a test file

In Terminal:

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

### 2.2 Load it, describe it, approve it

In a notebook cell:

```python
import exakit_nb as nb
nb.load_own_file("~/my-data/tickets.csv", "MY_DATA.TICKETS")
d = nb.describe("MY_DATA.TICKETS")
d.show()
```

Check:

- `CUSTOMER_EMAIL` is **identifier** and marked **sensitive** (personal data - never charted or sent to a model)
- slots: key `TICKET_ID`, time `OPENED_ON`, text `BODY`, category `CHANNEL`

Then:

```python
d.slot(target="ESCALATED")
ds = d.approve()
```

### 2.3 Explore your file

Open **01_explore.ipynb**, change the first line to `DATASET = "my_data_tickets"` and **Run All Cells**. It runs unchanged.

### 2.4 Change the table and describe again

```bash
exakit sql "ALTER TABLE MY_DATA.TICKETS ADD COLUMN PRIORITY VARCHAR(10)"
```

```python
d2 = nb.describe("MY_DATA.TICKETS")
d2.show()
```

You get a **draft v2**: `PRIORITY` is marked **changed since v1**, everything else keeps your choices (target too).

---

## 3. Workflow log

```bash
exakit workflow list
exakit workflow show YOUR_WORKFLOW_ID
```

(Use the id you wrote down in 1.2.) You see lines for the descriptor **draft** and **approve** and the SQL that ran.

No password anywhere - this prints only file names, so **no output is good**:

```bash
PWFILE=$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('~/.exasol-starter-kit/manifest.json')))['runtime']['password_file'])")
grep -rIlF -f "$PWFILE" ~/.exasol-starter-kit/notebooks ~/.exasol-starter-kit/descriptors ~/.exasol-starter-kit/workflows ~/Library/Jupyter/kernels 2>/dev/null
```

---

## 4. ML Engineer

### 4.1 Add the persona

```bash
exakit persona add ml-engineer
exakit persona plan ml-engineer
exakit mlflow status
```

- persona plan: **nothing pending**
- MLflow: **running** (if not: `exakit mlflow start`)

The first time it installs the Python UDF container - this can take ~10 minutes and restarts the database once.

### 4.2 Train

In JupyterLab open **ml-engineer → 00_quickstart.ipynb** → **Run All Cells** (connection, container and MLflow checks pass).

Then open **ml-engineer → 01_train.ipynb**, keep `DATASET = "esophageal_posts"` → **Run All Cells**.

```bash
exakit mlflow url
```

Open that address in the browser: the run is there with its metrics and tags.

Repeat **01_train** with `DATASET = "bank_marketing"`.

---

## 5. More checks

### 5.1 Usage telemetry is off

```bash
grep -l "EXASOL_TELEMETRY_DISABLE" ~/Library/Jupyter/kernels/*/kernel.json
exakit mcp-setup
grep -l "EXASOL_TELEMETRY_DISABLE" ~/.claude.json "$HOME/Library/Application Support/Claude/claude_desktop_config.json" 2>/dev/null
```

Each command prints a file name: the notebook kernel and your AI clients' setup carry the switch that turns
Exasol's usage reporting off.

### 5.2 UDFs can read the bucket folder

```bash
printf 'bucket check\n' > ~/bucket-check.txt
exakit model put ~/bucket-check.txt
exakit model list
exakit model rm bucket-check.txt
```

`model put` prints the path a UDF reads it from (`/buckets/bfsdefault/default/models/bucket-check.txt`).
The full check with a UDF that reads the file back is in `tests/manual/bucket-check.md` (passed on Mac, 3 Nov).

---

## 6. Finish

```bash
exakit notebook stop
exakit stop
```

Next time: `exakit start`, then `exakit notebook`.

If something fails: copy the message, then run `exakit status` and `exakit logs setup --lines 100` and keep the output.

---

## Checklist

| Step | What you checked | ✓ | Note (time, message) |
|---|---|---|---|
| Before you start | commit number | | |
| A2 / B2-B3 | install finished, datasets loaded | | minutes: |
| Check the install | running, nothing pending, 40987 / 6754 / 45211 rows | | |
| 1.2 | quickstart rows under 10 minutes | | minutes: |
| 1.3 | describe → approve v1 → published; second approve writes nothing; wrong role refused | | |
| 1.4 | AI client shows the roles | | |
| 1.5 | Banking and Bank marketing approved from Terminal | | |
| 1.6 | Explore runs on Esophageal and Banking | | |
| 2.2 | own file: email is sensitive; approved | | |
| 2.3 | Explore runs on your file | | |
| 2.4 | changed table → draft v2, choices kept | | |
| 3 | workflow lines; password check prints nothing | | |
| 4.1 | ML Engineer added, MLflow running | | |
| 4.2 | train runs in MLflow (Esophageal, Bank marketing) | | |
| 5.1 | telemetry switch in kernel and AI-client setup | | |
| 5.2 | bucket file put, listed and removed | | |

## Good to know

- This version installs only **from this folder** (`EXAKIT_LOCAL_KIT`) - the new datasets are not published online yet.
- **First time the new datasets load on a real database.** If a load or check fails at A2/B3, copy the message into the checklist; `exakit data-load esophageal_posts --force` retries one dataset.
- **Banking has no text** (the source stopped publishing complaint texts) - text steps skip on Banking.
- **Esophageal posts** are other people's public posts with personal details removed; the terms are still to be confirmed before release.
- **Windows** (later): in PowerShell, `$env:EXAKIT_LOCAL_KIT = 'C:\path\to\checkout'`, then `irm https://www.exasol.com/install/starter-kit.ps1 | iex`, then the same steps.
- One pass from a clean machine through every Data Scientist feature, UDFs, Rust and Langfuse included: [DATA-SCIENTIST-TEST-PLAN.md](DATA-SCIENTIST-TEST-PLAN.md).
- Deeper checks (Rust scoring, Share dashboards, Marimo, all file formats, Langfuse): [ACCEPTANCE-REMAINING.md](ACCEPTANCE-REMAINING.md).
