# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown]
# # Ask your data with AI
#
# **Dataset:** the one you approved last (else `amazon_sales`), `fraud_transactions` or your own approved descriptor.
#
# **The journey:** 1 Access → 2 Understand → 3 Prepare → 4 Explore → 5 Model → 6 Validate → **7 Ask with AI** → 8 Share → 9 Hand off. **This notebook: step 7.**
#
# Ask a question in plain English, review the SQL proposed for it, approve it, then run it read-only. It continues the quickstart's workflow log on its own.
#
# Optional: `DRAFT_WITH_MODEL = True` lets your model draft the SQL from the approved column map: every column with its role, evidence and note (no rows are sent). Set the model up in the cell *Your AI model and Langfuse* below - an external one (Claude, OpenAI, ...) or one running on your own machine (Ollama) both work.

# %%
import exakit.nb as nb

DATASET = None  # None: the dataset approved last in a quickstart (else amazon_sales); or "fraud_transactions", or your own approved descriptor
QUESTION = "How many rows are in each category?"
DRAFT_WITH_MODEL = False  # True: your model drafts the SQL (set it up in the model cell below); no rows are sent

dataset_id = nb.chosen_dataset(DATASET)
nb.continue_workflow("questions")   # the quickstart's workflow, or the last one: nothing to paste

connection = nb.connect()
dataset = nb.dataset(connection, dataset_id)
dataset.require_approved("ask")
nb.show_roles(dataset)

# %% [markdown]
# ## Step 7 · Ask your data with AI
#
# > **What happens here?** You ask in words; the notebook (or your AI model) turns the question into SQL from the approved column map; you read that SQL and approve it; only then does it run, with read-only rights. The model never sees your rows - only the column map - and every call can be recorded in Langfuse so you can see what was sent, what came back and what it cost.

# %% [markdown]
# ### Your AI model and Langfuse (optional)
#
# Only the AI steps need this (the SQL draft, with `DRAFT_WITH_MODEL = True`). Skip it and everything else runs.
#
# - **Plain values go in the cell:** `MODEL_ID`, `PROVIDER_BASE_URL` (any Chat Completions endpoint: Claude, OpenAI, or Ollama on your own machine - `MODEL-PROVIDERS.md` lists them) and `LANGFUSE_BASE_URL` (where the calls are recorded: what was sent, the answer, the cost).
# - **Secrets never go in the cell.** When you run it, a hidden box asks for the model's API key and the two Langfuse keys (Enter skips one). They live in this kernel only - not in this file, its outputs or on disk - and are gone when the kernel stops.
# - **Or once for every notebook:** `nb.model_setup()` prints the few lines to run in a terminal on this machine.
#
# The cell answers in one line: the model, whether it has a key, and whether Langfuse is tracing.
# %%
MODEL_ID = ""           # e.g. "claude-opus-5-5"; empty: no model (or the one set before `exakit notebook`)
PROVIDER_BASE_URL = ""  # e.g. "https://api.anthropic.com/v1/" - any Chat Completions endpoint (MODEL-PROVIDERS.md lists more)
LANGFUSE_BASE_URL = ""  # e.g. "https://cloud.langfuse.com"; empty: the model calls are not traced
nb.use_model(MODEL_ID, PROVIDER_BASE_URL, LANGFUSE_BASE_URL)

# %% [markdown]
# ### Review the proposal
#
# Read the SQL, what the model assumed and what it says to check. With the starter SQL (`DRAFT_WITH_MODEL = False`), changing `QUESTION` alone changes nothing; edit the SQL instead: `proposal.edit("SELECT ...")`.

# %%
GROUP_ROLE, GROUP_COLUMN = dataset.group_by()   # the category, else the entity, else the target
GROUP_HEADER, COUNT_HEADER = nb.name(GROUP_COLUMN), nb.count_name(dataset)       # columns named after the data: CATEGORY, ORDER_LINES
starter_sql = f"SELECT {GROUP_COLUMN} AS {GROUP_HEADER}, COUNT(*) AS {COUNT_HEADER} FROM {dataset.fact_table} GROUP BY 1 ORDER BY {COUNT_HEADER} DESC"
if GROUP_ROLE != "category":
    print(f"{dataset.id} has no category; the starter SQL counts rows per {GROUP_ROLE} ({GROUP_COLUMN}).")
proposal = nb.ask(dataset, QUESTION, proposed_sql=None if DRAFT_WITH_MODEL else starter_sql)
proposal

# %% [markdown]
# ### Approve and run
#
# > **Why approve a query?** A query written for you, by the starter SQL or by a model, can be subtly wrong: the wrong column, a missing filter.
# > You read it and say yes first; only that exact text then runs.
# > It runs with read-only rights, so it can never change your data.
#
# Nothing runs while `APPROVE_SQL = False`. After review, set `APPROVE_SQL = True` and rerun.
#
# Only the exact approved SQL runs, as the read-only user. `proposal.edit(...)` clears the approval.

# %%
APPROVE_SQL = False
if APPROVE_SQL:
    proposal.approve()
    answer = proposal.run()
    print(f"{len(answer)} rows. Check the figures against the SQL above.")
else:
    answer = None
    print("Not approved: no query ran. Review the proposal above, then set APPROVE_SQL = True and run this cell again.")
answer

# %% [markdown]
# ## Next: steps 8 and 9
#
# Open `03_share.ipynb`: publish a dashboard others can open, then hand the whole piece of work off in one bundle.
