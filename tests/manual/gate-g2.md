# Manual gate plan: G2, the ML Engineer's first forty-five minutes

Gate G2 of the v0.5 plan (`.plan/requirements.md` §2.2 steps 1–8 and 10–11, §3 ML-1..ML-5; `.plan/design.md` §5–§9, §12). Three ML engineers each run the ML Engineer flow on a machine they have never used the kit on, with nobody helping. The automated suites prove the commands and cells run; this plan proves a person can. **G2 core** (steps 1–8) decides the gate. **Optional G2** (steps 10–11) runs afterwards and never holds the core back.

| Item | Detail |
|---|---|
| Branch | `feat/persona-flow` (or the release it becomes) |
| Covers | §2.2 steps 1 Install, 2 Runtime, 3 Check, 4 Handoff, 5 Train (Python), 6 Score (Rust), 7 Track, 8 Validate · optional 10 Model drop, 11 its gate |
| Pass criterion (core) | **2 of 3 participants finish steps 1–8 within 45 minutes**, uncoached, the kit starting MLflow inside that time. The Rust participant's step 6 counts in their 45 minutes. A participant who stops at any step, or passes 45:00 before step 8's second run shows identical metrics, fails. |
| Pass criterion (optional) | **2 of 3 score a model they trained outside the kit** (step 10). Runs only if AC-ML4.1 (the bucket-directory check) passed on both gate platforms; not timed against the core. |
| Participants | three ML engineers; **at least one chooses Rust**; at least one macOS and one Windows machine; none has installed this kit before |
| Observer | one per session; records, never coaches (§1) |
| Budget per participant | 45 min: ≈15 prepare (steps 1–3) · 15 build (4–6) · 15 prove (7–8) |

> **Pending T18/T19.** Step 6 (Rust scoring: `exakit rust-udf` and `02_rust_score.ipynb`) is written here against `.plan/design.md` §8, because neither exists on the branch yet. Run the gate only after T18 and T19 land, or run it without a Rust participant and mark the result *core minus Rust* (it then does not satisfy the gate's "at least one choosing Rust"). Every string in step 6 is marked *(expected)*: replace it with the shipped text when T18/T19 merge.

## 0. Before the sessions

### 0.1 Recruitment checklist

| # | Check | Done |
|---|---|---|
| R1 | Three ML engineers booked, 60-minute slots (45 timed + 15 setup/debrief) | |
| R2 | At least one chooses **Rust** (record who); the others Python | |
| R3 | Platforms: at least one macOS (Apple silicon, record the chip), at least one Windows 11 x86_64 (record the build) | |
| R4 | The Rust participant's machine has Docker or Podman running (the Rust build runs in a container on macOS, design §8) | |
| R5 | For the optional G2: each brings one scikit-learn model they trained elsewhere, saved with `pickle` or `joblib` (≤ 500 MB), plus the column names and types it expects | |
| R6 | Consent form (0.2) signed before recording starts | |
| R7 | Recording set up (0.2): screen + audio, timer visible | |

### 0.2 Consent and recording

Consent text, read and signed before the clock starts:

> I agree that this session is screen- and audio-recorded to evaluate the Exasol starter kit, not me. The recording and my notes are kept by the kit team only, for this evaluation, and are deleted on request. No password, token or key of mine is shown on the recording: anything secret is set before recording starts. I can stop at any time.

Recording: screen capture of the participant's terminal, browser (JupyterLab and the MLflow UI); a visible stopwatch started at the first install keystroke. Never record `env`, `set`, or the kit's `credentials` folder.

### 0.3 Machine preparation (observer, before the participant arrives)

Clean machine: no `~/.exasol-starter-kit`, no `exakit` on PATH, no Podman/Docker deployment from an earlier kit, 16 GB RAM, ≥ 30 GB free (the Python container is ≈ 860 MB, the database restarts once per container). Then:

1. Confirm the preflight passes without installing anything:
   - macOS: `curl -fsSL https://www.exasol.com/install/starter-kit.sh | EXAKIT_PREFLIGHT=1 sh`
   - Windows (PowerShell): `$env:EXAKIT_PREFLIGHT = '1'; irm https://www.exasol.com/install/starter-kit.ps1 | iex`
2. Nothing on port 5000 (the kit's MLflow takes the first free port from 5000; another server there is fine, but note it): macOS `lsof -i :5000`, Windows `Get-NetTCPConnection -LocalPort 5000`.
3. Optional G2: put the participant's model at `~/g2/<name>.pkl` (Windows: `$HOME\g2\<name>.pkl`); note its columns on the results sheet.
4. Clear the terminal. Start the recording and the stopwatch when the participant presses Enter on step 1.

The **handoff** (step 4) is the Data Scientist's: an ML engineer on a fresh machine has none, and `01_train` stops without one. The participant writes it themselves inside the clock by running the Data Scientist's `01_explore.ipynb` (that is how the plan's flow hands work over). Do **not** pre-seed it: record how long it takes, because it is the slowest unknown in the budget (see contradiction C3 at the end).

### 0.4 What the participant gets

One printed card, nothing else:

> You are an ML engineer. Install the Exasol starter kit for your role, set up the UDF runtime in your language, train a model on the sample data inside the database from the Data Scientist's handoff, and find the run in MLflow with everything needed to repeat it - then repeat it and check it gives the same numbers. The install command is: *(macOS)* `curl -fsSL https://www.exasol.com/install/starter-kit.sh | EXAKIT_PERSONA=ml-engineer sh` · *(Windows)* `$env:EXAKIT_PERSONA = 'ml-engineer'; irm https://www.exasol.com/install/starter-kit.ps1 | iex`. If you work in Rust, add `EXAKIT_UDF_LANGUAGE=rust` (macOS: before `sh`; Windows: `$env:EXAKIT_UDF_LANGUAGE = 'rust'` first) and score the same model in Rust at the end. Everything else is on screen. Say out loud what you are thinking.

## 1. Rules for the observer

**1.1 May say:** the one sentence per step in §2 ("Told"), read exactly; "keep going"; "say what you are looking for"; the time left at 20:00, 35:00 and 40:00.

**1.2 May not say:** any command, file name, cell, button, menu item, alias or environment variable; whether something worked; where to look; "try again". If the participant asks a question, answer "what would you try?" and write the question down verbatim: that question is the finding.

**1.3 Never resolve a stumble.** Stuck for 3 minutes: note the time, ask "what would you try?", let them continue or give up. A give-up ends the attempt at that step; any further work is *after give-up* on the sheet.

**1.4 Every container install restarts the database** and says so before it asks. That wait is the kit's, not the participant's: record its length, it stays inside the clock.

**1.5 Record per step:** start/end time, every question, every terminal error line, every scroll-back, every doc page opened.

## 2. The timed script

Each step: *Told* (one neutral sentence), *Sees* (exact strings from the sources on this branch, commit noted), *Proves* (AC), a timing box, observer notes. The clock runs from step 1 to step 8's second run.

### Step 1 Install (budget: steps 1–3 ≈ 15:00)

- **Told:** "Install the kit for your role with the command on the card."
- **Sees:** the installer's step panels; `Compatibility check passed (...)`; `Deploying Exasol Personal locally`; both datasets loaded (`pharma_trials`, `banking_complaints`) with `Checksum verified: ...`; the add-ons `notebook` and `udf-devkit` installed without a question. The UDF dev kit then sets up the language the persona answers (`udf_language: python` unless `EXAKIT_UDF_LANGUAGE` says otherwise, 3540104):
  - Python: `Installing the official PYTHON3 container restarts the database ...` (answered by the install), `Waiting for the database to answer after the restart`, then `Python UDFs run on PYTHON3 (Python 3.12.x)` and one line per package.
  - Rust: the container row is picked and verified - `Container for rust on <x86_64|aarch64>, database <version>: lc-rust-0.33.0[-aarch64].tar.gz`, `Verified lc-rust-0.33.0... (sha256 ..., <size> bytes)` - then `Rust UDFs: the RUST container is installed (rustc 1.98.1, exasol-udf-sdk 0.33.0)` and `The Rust smoke UDF arrives with the next kit step; until then: exasol slc list shows RUST` *(until T14 ships the smoke UDF)*.
  - The persona's service: `MLflow: running at http://127.0.0.1:5000` (cb01ae2; the port is the first free one from 5000). At the very end the first prompt: `Open the ML Engineer quickstart: run exakit notebook and open ml-engineer/00_quickstart.ipynb.`
- **Proves:** P-1 (AC-P1.1: exactly the listed datasets and add-ons, MLflow started; observer checks `exakit persona plan` shows nothing pending after the session), AC-ML1.1 start (UDF in the chosen language ≤ 15 min, clock to step 3's container check).
- **Timing:** start ____ end ____ (install wall time ____, database restart(s) ____)
- **Observer notes:** did anything ask a question (it must not); did they think a restart had hung (minute); did the Rust participant notice the Rust line; **did the Rust participant get a Python container at all** (see C1).

### Step 2 Runtime in the chosen language

- **Told:** "Make sure your UDF runtime is ready."
- **Sees (Python):** if the install's container passed, nothing more is needed; `exakit udf-setup` says `The official PYTHON3 container is already installed` and runs the smoke again. If a training package is missing, the step-3 check names `exakit udf-use default`, which installs the matrix's prebuilt container (3540104): `Container for python on <arch>, database <version>: standard-EXASOL-all-python-3.12_release_<x64|arm64>_12.0.0.tar.gz`, the download (≈ 860 MB, `checked against its SHA-256`), `Verified ...`, the restart, and the smoke listing `scikit-learn 1.9.0`, `pandas 2.3.3`, `numpy 2.4.6`, `scipy 1.18.0` under alias `PYTHON3_ML`.
- **Sees (Rust):** `exakit udf-setup --language rust` again reports the RUST container; training still needs Python, so the Rust participant also needs the Python container (`exakit udf-setup`) before step 5 - C1.
- **Proves:** AC-ML1.2 (prebuilt container per architecture, pinned versions reported, if `udf-use default` ran), AC-ML1.5 (Rust container under alias RUST; its smoke UDF is pending T14), AC-ML1.6 (any failure names language + step: with `--json`, `{"ok": false, "language": ..., "step": ..., "reason": ..., "remedy": ...}`).
- **Timing:** start ____ end ____
- **Observer notes:** which command they found and from where (`exakit` with no arguments, `exakit help udf-devkit`, the quickstart's fix line); a second database restart and its length.

### Step 3 Check: container, MLflow, bucket directory

- **Told:** "Open the notebooks and run the ML Engineer quickstart's checks."
- **Sees:** `exakit notebook` opens JupyterLab logged in; `ml-engineer/00_quickstart.ipynb`, kernel **Exasol (Starter Kit)**. One line per check (9723391, `exakit_nb/checks.py`):
  - `ok   container: the smoke UDF answers on PYTHON3: Python 3.12.x, scikit-learn <v>, pandas <v>, numpy <v>.` - or `FAIL container: Python ... on PYTHON3 lacks <packages>. Fix: exakit udf-use default (the pre-built container with them), or exakit udf-build <requirements.txt>.` - or `FAIL container: the smoke UDF on PYTHON3 did not run (<database message>). Fix: exakit udf-setup installs the Python container ...`
  - `ok   mlflow: the server at http://127.0.0.1:5000 answers.` - or `FAIL mlflow: ... Fix: exakit mlflow start`
  - `ok   bucket directory: <folder>, read by UDFs at /buckets/bfsdefault/default; 0 model file(s) in it; a UDF sees it.`
  - then the shared loader and review cells (as G1 steps 3–5; `pharma_trials` ships approved) and `A first query` with its SQL and up to 10 rows.
- **Proves:** AC-ML3.3 (three checks, one cell each, the fix named), AC-ML1.1 ends at the container `ok` line, AC-ML4.1 is re-observed (the `a UDF sees it` half).
- **Timing:** start ____ end ____ · **AC-ML1.1 (install start → container ok): ____ (≤ 15:00)**
- **Observer notes:** did a FAIL line's fix get them unstuck uncoached (which); C2 if the fix was `udf-use default`.

### Step 4 Handoff (budget: steps 4–6 ≈ 15:00)

- **Told:** "Get the Data Scientist's handoff for the Pharma data."
- **Sees:** the expected path is the Data Scientist's `data-scientist/01_explore.ipynb` run to its last cell: `Handoff written: ~/.exasol-starter-kit/handoffs/pharma_trials-v1.json` and `It holds descriptor pharma_trials v1, the feature view STARTER_KIT.PHARMA_TRIALS_FEATURES_V1 (<n> features), the label TERMINATED (positive: ...) and a time split; ml-engineer/01_train starts from it.` If they open `01_train` first, its first cell stops with `No handoff for descriptor pharma_trials in ~/.exasol-starter-kit/handoffs: run 01_explore on it, or ...`.
- **Proves:** AC-ML3.5 first half (training starts from a handoff, without opening the descriptor).
- **Timing:** start ____ end ____ · **time spent in explore: ____**
- **Observer notes:** did they go to `01_train` first, and did the error message get them to explore; did the explore text step's skipped-model line confuse them (no model endpoint is set in G2: expected `the text step is skipped`).

### Step 5 Train, Python

- **Told:** "Train the model from the handoff."
- **Sees:** `ml-engineer/01_train.ipynb` with `DATASET = "pharma_trials"` as it ships (9723391). The first cell prints `handoff: pharma_trials v1; <N> rows; time split` and `data digest: sha256:...`. The feature cell prints the view SQL, `features (<k>): ...` and the training SELECT. The training cell (`with exasol_mlflow.start_run(...) as run: run.execute(plan.training_sql)`) prints `run <run id> in http://127.0.0.1:5000`, `accuracy: 0.xxxx`, `macro-F1: 0.xxxx; majority baseline: 0.xxxx` and `beats baseline`. The artefact cell prints `model: .../model/model.pkl` and `coefficients: .../coefficients.json`.
- **Proves:** ML-3 training (time split 80/20 by the date role, fixed `SEED = 0`, logistic regression in a Python UDF under `start_run`), AC-ML3.4 first half (beats the majority baseline on macro-F1), AC-ML2.2 (the UDF has no network or credentials: nothing to configure).
- **Timing:** start ____ end ____ (training cell wall time ____)
- **Observer notes:** did they read the training SQL; did the `does not beat baseline` line appear (dataset? record it: a kit defect for the reference data); any `ContractError` or `TrackingUnavailable` text (verbatim).

### Step 6 Score, Rust — *pending T18/T19* (Rust participant only)

- **Told:** "Score the same model in Rust and compare it with Python."
- **Sees (expected, design §8):** `exakit rust-udf new <name>` creates `~/.exasol-starter-kit/rust-udfs/<name>/` (Cargo project pinned to `exasol-udf-sdk` 0.33.0, scoring over `coefficients.json`); `exakit rust-udf build <name>` builds in `rust:1.98.1-trixie` on macOS (Docker or Podman; refused with exit 5 naming the missing runtime otherwise) and runs `cargo exasol-udf validate` (a different rustc is refused with both versions shown); `exakit rust-udf deploy <name>` copies `lib<name>.so` into the bucket directory and creates `CREATE OR REPLACE RUST SCALAR SCRIPT ... AS %udf_object /buckets/bfsdefault/default/udf/lib<name>.so;`. `ml-engineer/02_rust_score.ipynb` scores the test set with the exported coefficients and reports that labels agree on every row and probabilities within 1e-9.
- **Proves:** AC-ML5.1 (new, build, deploy on both platforms), AC-ML5.2 (parity), AC-ML5.3 (the scoring run in MLflow with language, container alias + digest, rustc, Cargo.lock digest).
- **Timing:** start ____ end ____ (build wall time ____)
- **Observer notes:** container runtime prerequisite understood; the validate step's message if it refused; any hand edit of the generated project.

### Step 7 Track (budget: steps 7–8 ≈ 15:00)

- **Told:** "Find the run in MLflow, with what you would need to repeat it."
- **Sees:** `exakit mlflow url` prints `http://127.0.0.1:5000` (`exakit mlflow status` → `MLflow: running at ...`); in the MLflow UI, experiment `exasol-starter-kit`, run `pharma_trials-v1-logistic`: params (`seed`, `C`, ...), metrics `accuracy`, `macro_f1`, `baseline_macro_f1`, artefacts `training.sql`, `model/model.pkl` (+ `model.pkl.provenance.json`), `coefficients.json`, and tags (b220403): `exasol.kit_version`, `exasol.launcher_version`, `exasol.db_version`, `exasol.deployment`, `exasol.language`, `exasol.container_digest`, `exasol.package_versions`, `exasol.descriptor_id`, `exasol.descriptor_version`, `exasol.data_digest`, `exasol.session_id`, `exasol.statement_id`, `exasol.run_key`. `exasol.workflow_id` appears only when a workflow was started (neither ML notebook starts one: C6).
- **Proves:** AC-ML2.1 (one run: params, metrics, SQL artefact, model artefact, environment tags), AC-ML3.2 (an uncoached engineer sees the run in MLflow).
- **Timing:** start ____ end ____ · **run found at ____**
- **Observer notes:** how they found the address (the training cell's printed URL, `exakit mlflow url`, the quickstart's check line); which tag they pointed to as "what I need to repeat it".

### Step 8 Validate: repeat and compare

- **Told:** "Repeat the training and show it gives the same numbers."
- **Sees:** re-running the training cell with `SEED = 0` unchanged: a second run in the same experiment with the same `exasol.data_digest` and identical `accuracy`, `macro_f1` and `baseline_macro_f1` (compare in the MLflow UI, or the printed lines).
- **Proves:** AC-ML3.4 second half (same seed + same data digest → identical metrics).
- **Timing:** start ____ end ____ · **second run's metrics shown at ____ (core gate clock stops here)**
- **Observer notes:** did they change anything before re-running (C, the seed - record it; a changed C is a new experiment, not a repeat); how they compared (UI compare view, eyeballing).

### Step 10 Model drop — optional G2 (only if AC-ML4.1 passed)

- **Told:** "Bring the model you trained elsewhere into the database and score the sample data with it."
- **Sees:** `exakit model put ~/g2/<name>.pkl` copies it to `models/<name>.pkl` in the bucket directory and prints the `/buckets/bfsdefault/default/models/<name>.pkl` path; an outside pickle carries `Only load pickle or joblib models from a source you trust.` (a model put from `01_train`'s artefact folder does not: its provenance record travels with it); a file over 500 MB is refused before anything is copied; a different file under the same name is refused unless `--replace`. `exakit model list` lists it; `ml-engineer/03_score_external_model.ipynb` renders the scoring UDF from the template and checks the database's predictions against the same model run in the notebook on a held-out sample. Clean-up: `exakit model rm <name>.pkl`; `exakit model prune` previews unreferenced old models, `--yes` removes them (b67f63d, 9ccbec4).
- **Proves:** AC-ML4.4 (an engineer scores a model trained outside the kit), AC-ML4.2 (template predictions equal the client model), AC-ML4.3 (atomic copy, digest-guarded replace, no credentials).
- **Timing:** start ____ end ____ (untimed against the core)
- **Observer notes:** did their model's input columns map onto the sample's (record what they had to change); did the trust warning register.

### Step 11 Optional G2 result

Two of three succeed at step 10 → optional G2 passes. It never changes the core result.

## 3. Timing sheet

| Step | Budget | P1 (___, macOS/Win, Python/Rust) | P2 | P3 |
|---|---|---|---|---|
| 1 Install (incl. restart) | | | | |
| 2 Runtime | | | | |
| 3 Checks ok | ≤ 15:00 cumulative | | | |
| 4 Handoff (explore) | | | | |
| 5 Train | | | | |
| 6 Rust score (Rust only) | ≤ 30:00 cumulative | | | |
| 7 Track | | | | |
| 8 Validate | ≤ 45:00 cumulative | | | |
| **Total (core)** | **45:00** | | | |
| Result (core) | | pass / fail at step __ | | |
| 10 Model drop (optional) | untimed | | | |

## 4. When something fails

### 4.1 Classification (after the session)

| Class | Meaning | Example |
|---|---|---|
| **Kit defect** | the kit did not do what the sources say | a check prints `ok` but training fails on the same container; no run in MLflow although the training cell printed a run id |
| **Doc gap** | the kit worked but the participant could not find the next thing to do from what is on screen | went to `01_train` first and did not get to explore; did not find `exakit mlflow url` |
| **Environment** | 0.3 incomplete or the machine differs | Docker/Podman not running for the Rust build; another MLflow on port 5000; Podman machine stopped on Windows |
| **Participant** | gave up or mis-typed with the right information in front of them | edited the training SQL by hand and broke it |

A kit defect or doc gap counts against the gate. An environment failure voids that run: fix it and rerun with a fresh participant. A participant failure counts against the gate.

### 4.2 Capture on every failure (observer, after the clock stops)

```sh
exakit status
exakit status --json
exakit logs setup --lines 200
exakit logs notebook
exakit logs mlflow
exakit mlflow status --json
exakit udf-use --list
exakit udf-setup --json            # Python; add --language rust for the Rust participant
exakit model list --json
exakit persona plan
```
On Windows the same in PowerShell. Also: a screenshot of the failing cell and its output, the MLflow run page, and the participant's verbatim last question. Store under `g2-results/<date>-P<n>/`. Never copy `~/.exasol-starter-kit/credentials/` or the environment.

## 5. Data to hand back

| Measure | AC | Source | P1 | P2 | P3 |
|---|---|---|---|---|---|
| Install start → container `ok` (min) | AC-ML1.1 (≤ 15) | step 3 box | | | |
| Database restarts and their length | ML-1 | steps 1–2 | | | |
| Time spent writing the handoff (explore) (min) | budget check, C3 | step 4 box | | | |
| Beats majority baseline on macro-F1 (yes/no, values) | AC-ML3.4 | step 5 | | | |
| Run found in MLflow uncoached (yes/no, minute) | AC-ML3.2 | step 7 | | | |
| Second run's metrics identical (yes/no) | AC-ML3.4 | step 8 | | | |
| Rust parity: labels equal, max \|Δp\| | AC-ML5.2 | step 6 | | | |
| Total time, core (min) | G2 ≤ 45 | sheet | | | |
| Outside model scored, predictions match (optional) | AC-ML4.4, AC-ML4.2 | step 10 | | | |

The coordinator writes the AC-ML1.1 and AC-ML3.4 numbers into `.plan/requirements.md` §3.

## 6. Results

| Participant | Language | Platform (chip / Windows build) | Steps done | Total (core) | Core pass / fail | Failure class + step | Optional G2 | Notes |
|---|---|---|---|---|---|---|---|---|
| P1 | | | | | | | | |
| P2 | | | | | | | | |
| P3 | | | | | | | | |

**Gate G2 core:** ____ of 3 passed → **PASS / FAIL** (needs 2, at least one Rust participant among the three). **Optional G2:** ____ of 3 → PASS / FAIL / not run (AC-ML4.1 failed). Date ____ Observer ____

## 7. Contradictions found while writing this plan (for the plan owner)

Checked against the branch at the commits named above; each is a place where a participant following the screen would not reach the step's "Sees".

- **C1 · A Rust install has no Python container, but training is Python-only.** `EXAKIT_UDF_LANGUAGE=rust` makes `udf_devkit_install` set up only the RUST container (`setup/lib/udf-devkit.sh`, 3540104); ML-3 trains in a Python UDF for everyone (design §7, App. A "training stays in Python"). The Rust participant's step 3 then shows `FAIL container: the smoke UDF on PYTHON3 did not run`, and fixing it (`exakit udf-setup`) costs a second database restart inside the 45 minutes. Requirements §2.2 step 1 says "runtime per EXAKIT_UDF_LANGUAGE" and design §5 says "two languages installed → both aliases kept". Suggested: a Rust install also installs the Python container (rust *adds*, never replaces).
- **C2 · The container check's own fix does not lead back to `ok`.** `nb.check_container` and the training template both default to alias `PYTHON3` (`exakit_nb/checks.py`, `udf/templates/render.py`). When PYTHON3 lacks a training package, the fix line says `exakit udf-use default`, which installs alias `PYTHON3_ML` - but neither `00_quickstart` nor `01_train` reads or sets the alias, so the check stays `FAIL` and training targets PYTHON3. Suggested: one `CONTAINER = "PYTHON3"` assignment in both notebooks (or detect `PYTHON3_ML` when installed), and the check's fix naming it. Moot only if the official PYTHON3 always carries scikit-learn, pandas and numpy - confirm on both platforms in the first dry run.
- **C3 · An ML engineer starts with no handoff.** `01_train` stops with `No handoff ... run 01_explore on it` on a fresh machine (`exakit_nb/handoff.py read_handoff`). Requirements §2.2 step 4 allows a handoff "built from an approved descriptor", and `nb.handoff_from(conn, ds)` exists, but no cell offers it; the ML quickstart's last cell says to run the Data Scientist's explore first. The gate therefore spends part of the 45 minutes in another persona's notebook. Suggested: `01_train`'s first cell falls back to `handoff_from(conn, ds)` with a printed note when no handoff exists (and still refuses a stale one).
- **C4 · No workflow id on G2 runs.** `start_run` tags `exasol.workflow_id` only when a workflow is active; no ML notebook calls `nb.workflow()`, so AC-X1.1's "MLflow run carries the workflow id" is not exercised by the ML path. Suggested: `00_quickstart` (both personas) starts a workflow in its first cell, as design §3 already says.
- **C5 · `02_rust_score.ipynb` is referenced before it exists.** `01_train`'s last cell points to it "when a Rust container is installed"; it arrives with T19. Fine once T19 lands; until then the link leads nowhere.
- **C6 · The persona still describes a Python-only role.** `personas/ml-engineer.json` summary: "Train models inside the database with Python UDFs ..."; the doc's ML Engineer is "Python or Rust". The picker is where a Rust user decides; suggest naming both.
- **C7 · Requirements §2.2 statuses are stale.** Steps 1, 2, 4, 5, 8 and 10 are marked PARTIAL/MISSING for work that has landed (cb01ae2, e65fd05, 3540104, 9723391, b67f63d, 9ccbec4). Coordinator's file.
