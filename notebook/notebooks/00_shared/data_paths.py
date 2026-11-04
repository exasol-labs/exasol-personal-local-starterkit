# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown]
# # Shared start: connect, load, describe
#
# **Dataset:** Esophageal or Banking. **Run time:** about ten minutes on a first load.
#
# Both persona quickstarts include these cells.

# %% [markdown] tags=["connect"]
# ## Connect
#
# Uses the kit's saved connection, then lists the schemas. No password in the notebook.

# %% tags=["connect"]
import exakit.nb as nb

conn = nb.connect()
nb.check_connection(conn)

# %% tags=["connect"]
nb.list_schemas(conn)

# %% [markdown] tags=["load"]
# ## Choose a dataset
#
# Start with the bundled sample: `SAMPLE = "esophageal_posts"` (social posts) or `"banking_complaints"` (complaints). It loads once and is reused, and the later notebooks carry on with the dataset you approve here (their `DATASET = None`). Keep `SOURCE = None` for this walkthrough.

# %% tags=["load"]
SAMPLE = "esophageal_posts"   # or "banking_complaints", or None
sample = nb.load_sample(conn, SAMPLE)

# %% [markdown] tags=["load"]
# **Your own file (optional):** set `OWN_FILE` (CSV, Parquet or JSON) and `OWN_TABLE`. A missing path is skipped.

# %% tags=["load"]
OWN_FILE = "~/my-data/transactions.csv"   # .csv, .parquet or .json
OWN_TABLE = "MY_DATA.TRANSACTIONS"
own = nb.load_own_file(OWN_FILE, OWN_TABLE, conn=conn, missing_ok=True)

# %% [markdown] tags=["load"]
# **A connected source (optional):** set `SOURCE = "SCHEMA.TABLE"` for a virtual-schema table. `None` skips it.

# %% tags=["load"]
SOURCE = None   # e.g. "VS_SALES.ORDERS"
source = nb.load_source(conn, SOURCE)

# %% [markdown] tags=["load"]
# The data used from here on: the source, else your file, else the sample.

# %% tags=["load"]
ds = nb.first(source, own, sample)

# %% [markdown] tags=["review"]
# ## Approve the column map
#
# The column map tells the notebooks what each column is. The kit suggests it from the data and shows why. It has two parts.
#
# **1. A role for every column**, one of eight: `key` (one per row), `time`, `measure` (a number to add up), `category` (a few repeated values), `flag` (yes/no), `text`, `identifier` (names or codes, never grouped) and `other`.
#
# **2. The slots**: the one column the notebooks use for each job.
#
# | Slot | What the notebooks use it for | Esophageal | Banking |
# |---|---|---|---|
# | `key` | One row | `POST_ID` | `COMPLAINT_ID` |
# | `time` | Trends, earlier and later | `CREATED_TIME` | `DATE_RECEIVED` |
# | `text` | Words to explore | `MESSAGE` | — |
# | `target` | The outcome to predict | `IS_NEGATIVE` | `MONETARY_RELIEF` |
# | `category` | Groups to compare | `SOCIAL_NETWORK` | `PRODUCT` |
# | `entity` | Who or what a row is about | `SOURCE_DOMAIN` | `COMPANY` |
#
# The **target** matters most: the kit never guesses it, you choose it. Leave a slot as **—** when no column fits.
#
# **Do now:** check the dropdowns, click **Approve descriptor**, then run the next cell. If the map is already approved and you change nothing, no click is needed. The later notebooks use this approved map.
#
# Plain Python: `review.approve({"COLUMN": "role"}, {"target": "COLUMN"})`.

# %% tags=["review"]
review = nb.review_roles(conn, ds)

# %% tags=["review"]
ds = review.dataset()
nb.show_roles(ds)
