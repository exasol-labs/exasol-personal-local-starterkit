# Manual gate plan: G3, the complete Data Scientist journey

G3 tests all twelve steps in `.plan/requirements.md` §2.1 with three new practitioners. The pass rule is **two of three complete the journey uncoached within 20 minutes**. This plan records evidence; it is not a claim that the gate has passed. Run after the database, notebook, read-only MCP user and Dash Server are healthy. Run the Windows session when a Windows machine is available; the user's current priority is the macOS production path.

| Item | Rule |
|---|---|
| Participants | Three new Data Scientists, at least one Pharma and one Banking background; record OS and chip/build |
| Clock | Start at the install command; stop only when the live dashboard health check succeeds and the user finds its URL |
| Assistance | Observer may say “keep going” and the time left; no commands, cell names, hints or fixes |
| Pass | 2/3 finish all steps in ≤20:00, show an approved SQL query, compare preview figures, and promote the same healthy revision |
| Failure | Any skipped step, unapproved query, missing workflow event, unpublished dashboard, or time >20:00 |

## Preparation (outside the clock)

1. Give each participant a clean supported machine, a small CSV they own, an available model endpoint, and a Langfuse project. Set keys before screen recording and keep credentials out of screenshots. Confirm the prerequisite Docker/Podman machine and disk/RAM with the installer preflight. Do not preinstall the kit, preload data, or start Dash Server: those are journey steps.
2. Arrange a way to capture the screen, a visible timer, and a note sheet. Record informed consent before recording. The observer records errors and where the participant looked, without fixing them during the timed run.
3. Use a kit build containing `02_ask_your_data` and `03_share`. Keep `tests/manual/gate-g1.md` for the detailed steps 1–5 and 7–9 protocol; G3 adds Ask, figure validation, and Share.

## Timed script and evidence

| Step | Participant outcome to observe | Evidence / AC | Start–end |
|---|---|---|---|
| 1 Install | Installs `data-scientist` persona without a menu and sees first prompt | Install log, persona plan | ____–____ |
| 2 Load | Pharma and Banking archives are digest-checked and loaded | `exakit data-load` output | ____–____ |
| 3 Open | Notebook kernel connects and returns rows without displaying credentials | First query and kernel name | ____–____ |
| 4 Draft | Describes a sample table with evidence per proposed role | Draft descriptor, evidence | ____–____ |
| 5 Approve | Corrects/approves roles; first query runs and SQL is visible | Descriptor version and row output | ____–____ |
| 6 Ask | Enters a question, reviews or edits the proposed SQL, explicitly approves the exact query, then gets an answer | Proposal digest, SQL, row count, doubts; check read-only MCP user | ____–____ |
| 7 Explore | Uses `01_explore` with the same descriptor | Printed SQL, result | ____–____ |
| 8 Trace | Finds one trace with model calls and descriptor/workflow tags | Langfuse trace id and URL | ____–____ |
| 9 Own data | Loads own CSV, approves roles, changes `DATASET`, reruns exploration, writes handoff | Own descriptor, query, handoff | ____–____ |
| 10 Validate | Compares a proposed dashboard figure against the SQL's returned values | SQL text and sampled figure values | ____–____ |
| 11 Dashboard | Opens healthy Dash Server preview, explicitly confirms figures, promotes that revision, opens live URL | Preview and live health checks; `exakit status --json` `urls.dash-server` | ____–____ |
| 12 Gate | Shows all items in one workflow log and explains the result | `exakit workflow show <id> --json`; elapsed time | ____–____ |

The observer must verify that **no query runs before Ask approval**; the Share preview uses the kit's validated read-only profile; the live revision number equals the healthy preview revision; and the workflow log connects descriptor version, SQL digest, trace, handoff and dashboard revision. For dashboard figures, use the printed approved SQL and the read-only Exasol MCP result. The dashboard must be on Dash Server, reachable at the URL reported by `exakit status --json`.

## Result sheet

| Participant | Background | Platform | Total | Last step | Pass/fail | Blocking error and time | Workflow id | Preview/live revision |
|---|---|---|---:|---:|---|---|---|---|
| P1 | | | | | | | | |
| P2 | | | | | | | | |
| P3 | | | | | | | | |

**Gate G3:** ____ of 3 passed (needs 2). Date ____ Observer ____.

After each session, capture `exakit status --json`, the workflow log, approved SQL, Dash Server health results, and any error text. Redact credentials and row data before sharing the evidence. Classify failures as kit, documentation, environment, or participant. An environment failure voids that run; repeat it with a new participant after the environment is fixed. A kit or documentation failure counts against the gate.
