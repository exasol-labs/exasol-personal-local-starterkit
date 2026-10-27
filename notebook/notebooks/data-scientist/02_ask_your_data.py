# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown]
# # Ask your data
#
# - **Dataset:** Pharma, Banking, or your own approved descriptor.
# - **How long:** about five minutes to draft, inspect, approve and validate one question.
#
# Draft a question from an **approved** descriptor. Read the SQL and assumptions first. Edit the SQL if needed;
# approval applies to the exact text you reviewed. Only then does it run, using the kit's dedicated read-only identity.
# The SQL, row count and any model doubts are recorded under the active workflow id.

# %%
import exakit.nb as nb

DATASET = "pharma_trials"  # or "banking_complaints", or your own approved descriptor
QUESTION = "How many rows are in each category?"
DRAFT_WITH_MODEL = False  # set True after EXAKIT_NB_MODEL is configured; no rows are sent to draft SQL

conn = nb.connect()
ds = nb.dataset(conn, DATASET)
ds.require_approved("ask")
nb.show_roles(ds)

# %% [markdown]
# ## Draft and inspect
#
# The starter query uses the descriptor's category role. With DRAFT_WITH_MODEL=True, the opted-in model proposes SQL
# from the question, table and roles. It receives no table rows. The model may be wrong; check every table and number.

# %%
starter_sql = f"SELECT {ds.col('category')} AS CATEGORY, COUNT(*) AS N FROM {ds.fact_table} GROUP BY 1 ORDER BY N DESC"
proposal = nb.ask(ds, QUESTION, proposed_sql=None if DRAFT_WITH_MODEL else starter_sql)
print("Assumptions:", proposal.assumptions or "none")
print("Doubts:", proposal.doubts or "none")

# %% [markdown]
# ## Approve this SQL, then run
#
# Edit `proposal.edit("SELECT …")` if needed. Set APPROVE_SQL=True only after reading the printed query. Editing it
# afterwards removes approval. A Draft descriptor, write statement, or unapproved query is refused.

# %%
APPROVE_SQL = False
if APPROVE_SQL:
    proposal.approve()
    answer = proposal.run()
    print(f"{len(answer)} rows returned. Check the figures against the SQL printed above.")
    print(answer)
else:
    print("SQL not approved; no query ran. Review it and set APPROVE_SQL=True to continue.")
