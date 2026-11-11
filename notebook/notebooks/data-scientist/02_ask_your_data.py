# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown] tags=["exakit-guide-hint"]
# <div class="guide-start-hint">
#
# **Step 3 · Ask in plain words.** Click into the cell below and press **Shift + Enter** to open it: a question drafted into SQL, run only after you approve it. Its **Guided / Code** switch, top right, shows the code behind this page.
#
# </div>

# %% tags=["exakit-guide", "skip-ci"]
# Ask in plain words: the guided view of this page. Guided / Code, top right, switches to the code cells below.
import exakit.guide as guide

guide.ask()

# %% [markdown] tags=["exakit-code-start"]
# # The code behind this page
#
# <div class="guide-code-start"></div>
#
# The same steps as the cards above, as cells you can read, change and run one by one. **Code**, at the top right of a card, opens this section; **Guided** closes it again.

# %% [markdown]
# ## Ask your data with AI
#
# **Dataset:** the one you approved last (else `amazon_sales`), `fraud_transactions` or your own approved descriptor.
#
# ![Step 7 Ask with AI of nine: Access, Understand, Prepare, Explore, Model, Validate, Ask with AI, Share, Hand off](journey:7)
#
# Ask a question in plain English. Read the proposed SQL, approve it, then run it read-only.
#
# Optional: set `DRAFT_WITH_MODEL = True` to let your model write the SQL. The model gets the column map only, never rows.

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
# ## Step 7 · Ask your data
#
# 1. You ask a question.
# 2. The starter SQL or your model writes the query from the column map.
# 3. You read and approve the query.
# 4. The query runs with read-only rights.
#
# With Langfuse set up, each model call is traced: what was sent, the answer and the cost.

# %% [markdown]
# ### Your AI model and Langfuse (optional)
#
# Only `DRAFT_WITH_MODEL = True` needs this.
#
# - **In the cell:** `MODEL_ID`, `PROVIDER_BASE_URL` (any Chat Completions endpoint, listed in `MODEL-PROVIDERS.md`) and `LANGFUSE_BASE_URL` (where calls are traced).
# - **Not in the cell:** the API key and the two Langfuse keys. A hidden box asks for them. They stay in this kernel only.
# - **Not sure what to set?** Run `nb.model_setup()`. It asks for anything missing, with the keys in a hidden box, and prints the terminal lines that set them for every notebook.

# %%
MODEL_ID = ""           # e.g. "claude-opus-5-5"; empty: no model (or the one set before `exakit notebook`)
PROVIDER_BASE_URL = ""  # e.g. "https://api.anthropic.com/v1/" - any Chat Completions endpoint (MODEL-PROVIDERS.md lists more)
LANGFUSE_BASE_URL = ""  # e.g. "https://cloud.langfuse.com"; empty: the model calls are not traced
nb.use_model(MODEL_ID, PROVIDER_BASE_URL, LANGFUSE_BASE_URL)

# %% [markdown]
# ### Review the proposal
#
# Read the SQL, the model's assumptions and its checks. With the starter SQL (`DRAFT_WITH_MODEL = False`), a new `QUESTION` does not change the SQL. Edit the SQL instead: `proposal.edit("SELECT ...")`.

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
# A proposed query can be wrong: a wrong column, a missing filter. Read it before you approve it.
#
# 1. Set `APPROVE_SQL = True`.
# 2. Run the cell again.
#
# Only the exact approved SQL runs, as the read-only user. `proposal.edit(...)` removes the approval.

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
# Open `03_share` to publish a dashboard and hand off the work.

