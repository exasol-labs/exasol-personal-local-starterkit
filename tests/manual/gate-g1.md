# Manual gate plan: G1, the Data Scientist's first thirty minutes

Gate G1 of the v0.5 plan (`.plan/requirements.md` §2.1 step 12, §3 DS-1..DS-5; `.plan/design.md` §12). Three practitioners each run the Data Scientist flow, steps 1–5 and 7–9, on a machine they have never used the kit on, with nobody helping. The automated suites prove the cells run; this plan proves a person can.

| Item | Detail |
|---|---|
| Branch | `feat/persona-v05-completion` (or the release it becomes) |
| Covers | §2.1 steps 1 Install, 2 Load data, 3 Open notebook, 4 Draft, 5 Approve, 7 Explore, 8 Text step traced, 9 Own data (steps 6, 10, 11 are G3) |
| Pass criterion | **2 of 3 participants finish all eight steps within 30 minutes**, uncoached. A participant who stops at any step, or passes 30:00 before step 9's rerun shows rows, fails. |
| Participants | three practitioners; at least one Pharma and one Banking background; at least one macOS and one Windows machine; none has installed this kit before |
| Observer | one per session; records, never coaches (§1.3) |
| Budget per participant | 30 min: ≈10 connect (steps 1–3) · 5 describe (4–5) · 10 explore (7–8) · 5 own data (9) |

## 0. Before the sessions

### 0.1 Recruitment checklist

| # | Check | Done |
|---|---|---|
| R1 | Three practitioners booked, 45-minute slots (30 timed + 15 setup/debrief) | |
| R2 | Roles: at least one Pharma, at least one Banking (record which) | |
| R3 | Platforms: at least one macOS (Apple silicon or Intel, record which), at least one Windows 11 | |
| R4 | Each has a Langfuse project they own (Cloud, or self-hosted ≥ 4.59) and its public + secret key to hand | |
| R5 | Each has a model endpoint: a local Ollama with one pulled model, or their own OpenAI-compatible endpoint and key | |
| R6 | Each brings one CSV of their own (≤ 50 MB, a header row, a date column, a 0/1 or yes/no column, one free-text column, one categorical column). A file without a date or text column still works but exercises the "missing role" path; note it. | |
| R7 | Consent form (0.2) signed before recording starts | |
| R8 | Recording set up (0.2): screen + audio, timer visible | |

### 0.2 Consent and recording

Consent text, read and signed before the clock starts:

> I agree that this session is screen- and audio-recorded to evaluate the Exasol starter kit, not me. The recording and my notes are kept by the kit team only, for this evaluation, and are deleted on request. My database password, Langfuse keys and model API key are never shown on the recording: I type them in a terminal the recording does not capture, or into environment variables set before recording starts. I can stop at any time.

Recording: screen capture of the participant's terminal and browser; a visible stopwatch started at the first install keystroke. Secrets are set in a terminal window **before** recording starts (0.3 step 4) and that window is closed; only `exakit` output, JupyterLab and the Langfuse UI are recorded. Never record `env`, `set`, or the credentials folder.

### 0.3 Machine preparation (observer, before the participant arrives)

Clean machine: no `~/.exasol-starter-kit`, no `exakit` on PATH, no Podman/Docker deployment from an earlier kit, 16 GB RAM, ≥ 20 GB free. Then:

1. Confirm the preflight passes without installing anything:
   - macOS: `curl -fsSL https://www.exasol.com/install/starter-kit.sh | EXAKIT_PREFLIGHT=1 sh`
   - Windows (PowerShell): `$env:EXAKIT_PREFLIGHT = '1'; irm https://www.exasol.com/install/starter-kit.ps1 | iex`
2. Put the participant's CSV at `~/g1/<name>.csv` (Windows: `$HOME\g1\<name>.csv`). Note its path on the results sheet.
3. Ollama (if used): `ollama pull llama3.1` finished; `ollama serve` running; `curl http://127.0.0.1:11434/v1/models` answers.
4. **Not recorded**, in a terminal the participant will use for everything: set the variables below with the participant's own values, then start recording. The notebook reads them at `exakit notebook` time, so they must be set in the shell that runs it.

   macOS (`~/.zshrc` for the session, or `export` in the window):
   ```sh
   export LANGFUSE_BASE_URL="https://cloud.langfuse.com"   # or the self-hosted URL
   export LANGFUSE_PUBLIC_KEY="pk-lf-..."
   export LANGFUSE_SECRET_KEY="sk-lf-..."
   export EXAKIT_NB_MODEL="llama3.1"                        # or the participant's model name
   export OPENAI_BASE_URL="http://127.0.0.1:11434/v1"       # Ollama; or their endpoint
   export OPENAI_API_KEY="ollama"                           # Ollama ignores it; their key otherwise
   ```
   Windows (same window that will run the install):
   ```powershell
   $env:LANGFUSE_BASE_URL = "https://cloud.langfuse.com"; $env:LANGFUSE_PUBLIC_KEY = "pk-lf-..."; $env:LANGFUSE_SECRET_KEY = "sk-lf-..."
   $env:EXAKIT_NB_MODEL = "llama3.1"; $env:OPENAI_BASE_URL = "http://127.0.0.1:11434/v1"; $env:OPENAI_API_KEY = "ollama"
   ```
5. Clear the terminal (`clear` / `cls`). Start the recording and the stopwatch when the participant presses Enter on step 1.

### 0.4 What the participant gets

One printed card, nothing else:

> You are a data scientist. Install the Exasol starter kit for your role, open its notebooks, describe and approve the sample data, explore it, and then do the same with the CSV at `~/g1/<name>.csv`. The install command is: *(macOS)* `curl -fsSL https://www.exasol.com/install/starter-kit.sh | EXAKIT_PERSONA=data-scientist sh` · *(Windows)* `$env:EXAKIT_PERSONA = 'data-scientist'; irm https://www.exasol.com/install/starter-kit.ps1 | iex`. Everything else is on screen. Say out loud what you are thinking.

## 1. Rules for the observer

**1.1 May say:** the one sentence per step in §2 ("Told"), read exactly; "keep going"; "say what you are looking for"; the time left at 15:00 and 25:00.

**1.2 May not say:** any command, file name, cell, button, menu item or environment variable; whether something worked; where to look; "try again". If the participant asks a question, answer "what would you try?" and write the question down verbatim: that question is the finding.

**1.3 Never resolve a stumble.** If the participant is stuck for 3 minutes, note the time, ask "what would you try?", and let them continue or give up. A give-up ends the attempt at that step: record the step reached and keep the session going untimed only if the participant wants to, marked *after give-up* on the sheet.

**1.4 Record per step:** start/end time, every question asked, every terminal error line, every place they scrolled back, every doc page they opened.

## 2. The timed script

Each step: *Told* (the one neutral sentence), *Sees* (exact strings from the sources on this branch), *Proves* (AC), a timing box, observer notes. The clock runs from step 1 to step 9's rerun rows; set-up between steps counts.

### Step 1 Install (budget: steps 1–3 ≈ 10:00)

- **Told:** "Install the kit for your role with the command on the card."
- **Sees:** the installer's step panels; a compatibility line (`Compatibility check passed (...)`); `Deploying Exasol Personal locally`; the datasets loaded (`pharma_trials`, `banking_complaints`); `Checksum verified: ...` lines for the release assets; at the end the persona's first prompt: `Open the Data Scientist quickstart: run exakit notebook and open data-scientist/00_quickstart.ipynb.` Nothing asks a question: the persona answers datasets, AI clients (`all`) and the add-on (`notebook`).
- **Proves:** P-1 (AC-P1.1); start of AC-DS1.1.
- **Timing:** start ____ end ____ (install wall time ____)
- **Observer notes:** did the install ask anything (it must not); did the participant wait on a long step or think it hung (note the step and the minute); did they lose the first-prompt line by clearing the screen; was `exakit` on PATH in the same window afterwards (macOS: a new shell may be needed; Windows: `exakit.cmd`).

### Step 2 Load data

- **Told:** "Make sure the sample data is loaded."
- **Sees:** `exakit data-load pharma_trials` (or `banking_complaints`) returns `0` with the dataset already there (the persona install loaded both), or loads it: a checksummed archive is downloaded, `SHA-256 and every file's digest` verified, every file listed with its table and rows. The bare `exakit data-load` menu lists the bundled datasets with the two reference datasets and `Skip`.
- **Proves:** AC-DS2.1 (load < 5 min, digest verified). If the persona install already loaded both, take the load time from `exakit logs setup --lines 200` after the session.
- **Timing:** start ____ end ____ (load time, if it loaded here ____)
- **Observer notes:** did they find `data-load` (from `exakit` with no arguments, `exakit --help`, or the README); did the menu's `Skip` row confuse them; did they try to load their own CSV here (fine; note it, and whether they then also do it in the notebook at step 9).

### Step 3 Open the notebook, connected

- **Told:** "Open the notebooks and run the quickstart until you see rows from the database."
- **Sees:** `exakit notebook` prints `JupyterLab is running: http://127.0.0.1:8888...` (`... (stop it with: exakit notebook stop)`) and the browser opens logged in: no token typed. In `data-scientist/00_quickstart.ipynb` the kernel is **Exasol (Starter Kit)**. The connect cell prints `Connected: Exasol <version>, session <id>.`; the next lists schemas including `PHARMA` and `BANKING`. The sample cell prints `pharma_trials is loaded (PHARMA.PHARMA_TRIALS).`; the own-file cell prints `No file at ~/my-data/transactions.csv: set it to your CSV, Parquet or JSON file to load that - skipped.`; the source cell prints `No external source is connected (there is no virtual schema in the database): skipped.`
- **Proves:** AC-DS1.1 (clean machine to rows ≤ 10 min macOS / 15 min Windows: **stop the AC-DS1.1 clock at the first-query rows in step 5**), AC-DS1.2 (ask them: "is there a password anywhere in this notebook?" - expected: no), AC-DS1.5 (connection written at launch).
- **Timing:** start ____ end ____
- **Observer notes:** did they run cells top to bottom or jump; did the own-file `skipped` line read as an error to them; did they edit `OWN_FILE` now (step 9 early: allowed, note it); did the browser open or did they have to paste the URL.

### Step 4 Draft (budget: steps 4–5 ≈ 5:00)

- **Told:** "Review what the kit proposes for the data's roles."
- **Sees:** the review cell `review = nb.review_roles(conn, ds)` prints the draft table headed `PHARMA.PHARMA_TRIALS - draft descriptor 'pharma_trials' (version 1, draft, owner <os user>)` with columns `role  column  evidence  runner-up`, one row per role (`entity LEAD_SPONSOR`, `category PHASE`, `date START_DATE`, `label TERMINATED`, `text BRIEF_SUMMARY`), a `profiled N of N rows in K statements` line, then one dropdown per column and a green **Approve descriptor** button. (For the Banking sample the table is `BANKING.BANKING_COMPLAINTS`.)
- **Proves:** AC-DS5.1 (draft equals the shipped roles), AC-DS5.5 (draft is the same with or without a model), AC-DS3.4 first half.
- **Timing:** start ____ end ____
- **Observer notes:** did they read the evidence column or go straight to the button; did they understand "runner-up"; did they try to run the next cell before approving (it raises `Review the proposed roles and click Approve descriptor, or call review.approve({...}) first.` - record whether that message got them back).

### Step 5 Approve, then the first query

- **Told:** "Change anything you disagree with, approve the roles, and get the first query's rows."
- **Sees:** after **Approve descriptor** with the proposed roles unchanged: `v1 is already approved with these roles` then `Approved pharma_trials v1. Run the next cell.` (the kit ships pharma_trials as approved v1, so nothing is written). With one role corrected: `Approved pharma_trials v2 (owner <user>, digest sha256:...): ~/.exasol-starter-kit/...` then `Approved pharma_trials v2. Run the next cell.` The next cell prints `pharma_trials: one row of PHARMA.PHARMA_TRIALS per observation; descriptor sha256 ...` and the five roles. The first query prints its SQL (`SELECT PHASE AS CATEGORY, COUNT(*) AS N, ...`) and a table of up to 10 rows.
- **Proves:** AC-DS5.2 (version n+1, owner, digest, Approved - only when a role was corrected; otherwise step 9's own file proves it), AC-DS5.4 (roles in column comments; observer checks after the session with `exakit describe pharma_trials --comments`), AC-DS3.4 (**approved descriptor + first query ≤ 8 min from opening the quickstart**), AC-DS2.5 (nothing ran on a draft), AC-DS1.1 ends here.
- **Timing:** start ____ end ____ · **AC-DS1.1 total (install start → first rows): ____** · **AC-DS3.4 (quickstart open → first rows): ____**
- **Observer notes:** did they change a role before approving (which, why); did the `Could not approve: ...` line appear (record it verbatim); did they look for a file to edit (the YAML they never have to touch).

### Step 7 Explore (budget: steps 7–8 ≈ 10:00)

- **Told:** "Open the explore notebook and run it on the same data."
- **Sees:** `01_explore.ipynb`, `DATASET = "pharma_trials"` as it ships. The connect cell prints the roles line; the landscape cell prints a `WITH TOP_ENTITIES AS (...)` statement and a pivot of sponsors by phase; the over-time cell prints a `DATE_TRUNC` statement and a table; the model cell prints `<N> rows, <p>% with label 1; ROC AUC on the held-out quarter: 0.xxx (0.5 is guessing)`; then `towards 1: ...` / `towards 0: ...`.
- **Proves:** DS-3 (AC-DS3.2: one assignment, SQL visible before every result).
- **Timing:** start ____ end ____ (model cell wall time ____)
- **Observer notes:** did they notice the `DATASET` line; did they read any printed SQL; did the scikit-learn cell's wait worry them; any `ImportError` (record the package).

### Step 8 Text step, traced

- **Told:** "Run the text step, then find its trace in your Langfuse project."
- **Sees:** the sample SQL is printed; the cell runs the model over 5 rows and the table gains a `THEME` column. **Nothing prints when tracing is on.** If a variable is missing: `No model endpoint (EXAKIT_NB_MODEL not set before exakit notebook); the text step is skipped.` or `tracing is off (set LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY and LANGFUSE_BASE_URL before exakit notebook); the cell runs as usual.` - both are an **environment** failure of 0.3, not the participant's. In Langfuse: one trace named `explore-text-step` with five generation calls (input, output, token usage, latency), tags `exasol-starter-kit`, `exasol.dataset=pharma_trials`, `exasol.descriptor=...`, `exasol.descriptor_version=1` (`2` after a correction in step 5), `exasol.session_id=...`, and metadata with the sample SQL.
- **Proves:** AC-DS4.5 (practitioner sees the trace), AC-DS4.1 (one trace, every call, tagged), AC-DS4.3 (observer: no key in the output or the trace).
- **Timing:** start ____ end ____ · **trace seen at ____**
- **Observer notes:** how they found the trace (session view, tag filter, time); whether they expected the notebook to link to it (it does not); `exasol.workflow_id` is absent because no workflow was started - note if they ask about it.

### Step 9 Own data: describe, approve, rerun (budget ≈ 5:00)

- **Told:** "Now do the same with your own file: the CSV on the card."
- **Sees:** the expected path is back in `00_quickstart.ipynb`: set `OWN_FILE = "~/g1/<name>.csv"` and `OWN_TABLE` (e.g. `"MY_DATA.<NAME>"`), run the load cells (the file is loaded through `exakit data-load`, with its table and row count printed), `ds = nb.first(source, own, sample)` now picks the file; the review cell prints `MY_DATA.<NAME> - draft descriptor '<name>' (version 1, draft, owner ...)` with evidence per role and, for a role no column fits, `missing: <reason>`; after **Approve descriptor**: `Approved <name> v1. Run the next cell.` and `Approved roles saved beside <name>.csv: ~/g1/<name>.descriptor.yaml`. The first query runs on their table. Then in `01_explore.ipynb` they set `DATASET = "~/g1/<name>.csv"` and run everything again: the same SQL on their columns. The last cell prints `Handoff written: ~/.exasol-starter-kit/handoffs/...` and `It holds descriptor <name> v1, the feature view ...; ml-engineer/01_train starts from it.`
- **Proves:** AC-DS3.3 (**uncoached swap**), AC-DS3.4 (own-file path through the same cell), AC-DS5.3 (a missing role is named and the dependent step skipped with the reason), AC-DS2.3, handoff written (T9).
- **Timing:** start ____ end ____ · **rerun rows at ____ (gate clock stops here)**
- **Observer notes:** did they change the quickstart's `OWN_FILE` or the explore's `DATASET` first (both are documented; only the quickstart path approves roles - if they went to explore first, record the error they got and whether they recovered uncoached); did a role come out `missing`, and did they understand the reason; did a column need a correction in the picker (which); did the swap leave any SQL edited by hand (it must not).

## 3. Timing sheet

One row per step, one column per participant. Budgets from §2.1 of the requirements (≈ 10 / 5 / 10 / 5).

| Step | Budget | P1 (___, macOS/Win, Pharma/Banking) | P2 | P3 |
|---|---|---|---|---|
| 1 Install | | | | |
| 2 Load data | | | | |
| 3 Notebook connected | ≤ 10:00 cumulative | | | |
| 4 Draft | | | | |
| 5 Approve + first rows | ≤ 15:00 cumulative | | | |
| 7 Explore | | | | |
| 8 Text step traced | ≤ 25:00 cumulative | | | |
| 9 Own data rerun | ≤ 30:00 cumulative | | | |
| **Total** | **30:00** | | | |
| Result | | pass / fail at step __ | | |

## 4. When something fails

### 4.1 Classification (one per failure, decided after the session, not during)

| Class | Meaning | Example |
|---|---|---|
| **Kit defect** | the kit did not do what the sources say it does | a cell raises; `Approve descriptor` prints `Could not approve: ...`; no trace arrives although the variables were set |
| **Doc gap** | the kit worked but the participant could not find the next thing to do from what is on screen | could not find `exakit notebook`; went to explore before approving the own file's roles and did not recover |
| **Environment** | 0.3 was incomplete or the machine differs | a `LANGFUSE_*` variable missing; Ollama not running; Podman machine not started on Windows; `exakit` not on PATH |
| **Participant** | gave up or mis-typed, with the right information in front of them | typed the wrong path twice and stopped |

A kit defect or doc gap counts against the gate. An environment failure voids that participant's run: fix it and rerun with a fresh participant. A participant failure counts against the gate too (that is what the gate measures); record what was on screen.

### 4.2 Capture on every failure (observer, after the clock stops)

```sh
exakit status
exakit status --json
exakit logs setup --lines 200
exakit logs notebook
exakit workflow list                 # expected empty in G1: no notebook starts a workflow; note if not
exakit describe pharma_trials --versions
exakit describe <name> --versions    # the own file's id, if step 9 was reached
```
On Windows the same commands in PowerShell. Also: a screenshot of the failing cell with its output, the Langfuse trace page (or the empty project) for step 8, and the participant's verbatim last question. Store under `g1-results/<date>-P<n>/`. Never copy `~/.exasol-starter-kit/credentials/` or the environment.

## 5. Data to hand back

| Measure | AC | Source | P1 | P2 | P3 |
|---|---|---|---|---|---|
| Install start → first rows (min) | AC-DS1.1 (≤ 10 macOS / ≤ 15 Windows) | step 5 box | | | |
| Dataset load time (s), digest verified | AC-DS2.1 (< 5 min) | step 2 box or `exakit logs setup` | | | |
| Quickstart open → approved descriptor + first query (min) | AC-DS3.4 (≤ 8) | step 5 box | | | |
| Trace seen in own Langfuse (yes/no, minute) | AC-DS4.5 | step 8 box | | | |
| Own-file swap done uncoached (yes/no) | AC-DS3.3 | step 9 | | | |
| Missing role named, step skipped with reason (yes/no/n.a.) | AC-DS5.3 | step 9 | | | |
| Password or key visible anywhere (must be no) | AC-DS1.2, AC-DS4.3 | steps 3, 8 | | | |
| Total time (min) | G1 ≤ 30 | sheet | | | |

Write the three AC-DS1.1 / DS2.1 / DS3.4 numbers into `.plan/requirements.md` §3 (the coordinator does this; the plan is the source).

## 6. Results

| Participant | Role | Platform (chip / Windows build) | Model endpoint | Langfuse | Steps done | Total | Pass / Fail | Failure class + step | Notes |
|---|---|---|---|---|---|---|---|---|---|
| P1 | | | | | | | | | |
| P2 | | | | | | | | | |
| P3 | | | | | | | | | |

**Gate G1:** ____ of 3 passed → **PASS / FAIL** (needs 2). Date ____ Observer ____
