# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown]
# # The shared cells: connect, and bring data in
#
# Both quickstarts are built with these cells (`data-scientist/00_quickstart` and `ml-engineer/00_quickstart`), so the
# two cannot drift apart. Open your persona's quickstart rather than this notebook; it runs on its own all the same.
#
# **Dataset:** the Pharma sample (`pharma_trials`) unless you pick another below. **Loaded beforehand:** nothing.
# **Run time:** about ten minutes, most of it loading the sample the first time.

# %% [markdown] tags=["connect"]
# ## Connected?
#
# The kernel **Exasol (Starter Kit)** opens the database from the kit's encrypted store: there is no host, user or
# password in this notebook. The second cell lists what the database holds; a virtual schema is a connected source.

# %% tags=["connect"]
import exakit.nb as nb

conn = nb.connect()
nb.check_connection(conn)

# %% tags=["connect"]
nb.list_schemas(conn)

# %% [markdown] tags=["load"]
# ## Bring data in: one cell for each way
#
# Set up the ones you want; a cell you leave as it is says so and skips. The data used from here on is the first
# that loaded, in this order: a connected source, your own file, the sample dataset.
#
# **A sample dataset** the kit ships: `pharma_trials` (ClinicalTrials.gov studies) or `banking_complaints` (CFPB
# consumer complaints). The cell loads it with `exakit data-load` the first time (a few minutes) and uses it as it is
# after that. `None` skips it.

# %% tags=["load"]
SAMPLE = "pharma_trials"   # or "banking_complaints", or None
sample = nb.load_sample(conn, SAMPLE)

# %% [markdown] tags=["load"]
# **Your own file**: CSV, Parquet or JSON (an array of records, or one record per line). Name the table it goes into.
# The next cell profiles its columns and lets you choose their roles; you do not have to write a descriptor.

# %% tags=["load"]
OWN_FILE = "~/my-data/transactions.csv"   # .csv, .parquet or .json
OWN_TABLE = "MY_DATA.TRANSACTIONS"
own = nb.load_own_file(OWN_FILE, OWN_TABLE, conn=conn, missing_ok=True)

# %% [markdown] tags=["load"]
# **A connected source**: a table in a virtual schema, an external database Exasol reads live. Name it as
# SCHEMA.TABLE; the next cell profiles a sample and lets you review the roles. With no source connected, it skips.

# %% tags=["load"]
SOURCE = None   # e.g. "VS_SALES.ORDERS"
source = nb.load_source(conn, SOURCE)

# %% [markdown] tags=["load"]
# The data used from here on. A source wins over your file, which wins over the sample:

# %% tags=["load"]
ds = nb.first(source, own, sample)

# %% [markdown] tags=["review"]
# ## Review and approve the roles
#
# The kit profiles the chosen table and shows the evidence behind each proposed role: one dropdown per column,
# labelled with its type, null share and distinct values or span, the runner-up for its role under it. Pick a role
# for each column, then click **Approve descriptor**. The next cell waits for your approval; it does not run on a
# draft (in Marimo it stops until the button is clicked, then runs on its own). In a plain Python session, call
# `review.approve({"COLUMN": "role", ...})` instead. A headless run (`EXAKIT_NB_AUTO_APPROVE=1`) approves only a
# proposal equal to the current approved version, writing nothing; any other proposal stays a draft and the run
# says why (`=force` approves it anyway).

# %% tags=["review"]
review = nb.review_roles(conn, ds)

# %% tags=["review"]
ds = review.dataset()
nb.show_roles(ds)
