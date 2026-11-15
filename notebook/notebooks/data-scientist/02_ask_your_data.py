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

# %% [markdown]
# | Setting | What it does |
# |---|---|
# | `DATASET` | `None`: the dataset approved last |
# | `QUESTION` | your question in words |
# | `DRAFT_WITH_MODEL` | `True`: your AI model drafts the SQL; no rows are sent |
# | `ASK_RULES` | changes to how the AI drafts: the order of the ways it tries and every word of its instructions; `nb.ask_rules()` lists them |
# | `DRAFT_RULES` | changes to the no-AI drafter, such as `{"MIN_GROUP_ROWS": 10, "SYNONYMS": {"amount": ["revenue", "turnover"]}}`; `nb.draft_rules()` lists them |
# | `INSIGHT_RULES` | changes to the insights, such as `{"TOP": 5, "OUTLIER_IQR": 3}`; `nb.insight_rules()` lists them |

# %%
import exakit.nb as nb

DATASET = None
QUESTION = "How many rows are in each category?"
DRAFT_WITH_MODEL = False
ASK_RULES = {}
DRAFT_RULES = {}
INSIGHT_RULES = {}

dataset_id = nb.chosen_dataset(DATASET)
nb.continue_workflow("questions")

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

# %% [markdown]
# `MODEL_ID`, for example `"claude-opus-5-5"`; `PROVIDER_BASE_URL`, any Chat Completions address; `LANGFUSE_BASE_URL`, where the calls are traced. Empty: no model.

# %%
MODEL_ID = ""
PROVIDER_BASE_URL = ""
LANGFUSE_BASE_URL = ""
nb.use_model(MODEL_ID, PROVIDER_BASE_URL, LANGFUSE_BASE_URL)

# %% [markdown]
# ### Review the proposal
#
# Read the SQL, the model's assumptions and its checks. With the starter SQL (`DRAFT_WITH_MODEL = False`), a new `QUESTION` does not change the SQL. Edit the SQL instead: `proposal.edit("SELECT ...")`.

# %% [markdown]
# `DRAFT_WITH_RULES = True`: the kit's rules draft the question, no AI model needed. `EDITED_SQL`: your own SQL for it, which you then approve.

# %%
GROUP_ROLE, GROUP_COLUMN = dataset.group_by()
GROUP_HEADER, COUNT_HEADER = nb.name(GROUP_COLUMN), nb.count_name(dataset)
starter_sql = f"SELECT {GROUP_COLUMN} AS {GROUP_HEADER}, COUNT(*) AS {COUNT_HEADER} FROM {dataset.fact_table} GROUP BY 1 ORDER BY {COUNT_HEADER} DESC"
if GROUP_ROLE != "category":
    print(f"{dataset.id} has no category; the starter SQL counts rows per {GROUP_ROLE} ({GROUP_COLUMN}).")
DRAFT_WITH_RULES = False
if DRAFT_WITH_RULES:
    proposal = nb.draft_question(connection, dataset, QUESTION, rules=DRAFT_RULES)
else:
    proposal = nb.ask(dataset, QUESTION, proposed_sql=None if DRAFT_WITH_MODEL else starter_sql, conn=connection, rules=ASK_RULES)
EDITED_SQL = ""
if EDITED_SQL:
    proposal.edit(EDITED_SQL)
proposal

# %%
examples = nb.example_questions(dataset)
examples

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
currency = nb.currency_of(connection, dataset)
nb.formatted(answer, dataset, currency) if answer is not None else None

# %% [markdown]
# ### What the answer says, and keeping it
#
# `nb.insights` writes the answer out in sentences by fixed rules (the largest and smallest, shares, the change over time, values far from the rest): no model and no new query. Pin the answer to a page of a dashboard (`nb.pin`): `03_share` publishes the pages as one dashboard with tabs and filters. When it was answered from the semantic model, `proposal.verify(connection)` keeps it in the model as a verified question: asked again, here or in an AI client, it is answered with this reviewed request.

# %% [markdown]
# `PIN_TO`: a dashboard and a page, such as `("sales-overview", "Revenue")`. `KEEP_AS_VERIFIED = True` keeps the question as a trusted question.

# %%
PIN_TO = None
KEEP_AS_VERIFIED = False
if answer is not None:
    insights = nb.insights(answer, rules=INSIGHT_RULES)
    print("\n".join(insights))
    if PIN_TO:
        pinned = nb.pin(proposal, answer, board=PIN_TO[0], page=PIN_TO[1])
    if KEEP_AS_VERIFIED:
        verified = proposal.verify(connection)

# %% [markdown]
# ## Next: steps 8 and 9
#
# Open `03_share` to publish a dashboard and hand off the work.

