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
# Start with the bundled sample: `SAMPLE = "esophageal_posts"` (social posts) or `"banking_complaints"` (complaints). It loads once and is reused. Keep `SOURCE = None` for this walkthrough.

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
# ## Approve the column roles
#
# A **role** tells the notebooks how to use a column. The kit suggests roles with its reasons.
#
# | Role | Meaning | Esophageal | Banking |
# |---|---|---|---|
# | `entity` | Who or what to compare | `SOURCE_DOMAIN` | `COMPANY` |
# | `category` | Groups to compare | `SOCIAL_NETWORK` | `PRODUCT` |
# | `date` | Event time | `START_DATE` | `DATE_RECEIVED` |
# | `label` | Outcome to predict | `IS_NEGATIVE` | `MONETARY_RELIEF` |
# | `text` | Free text | `MESSAGE` | none |
#
# The **label** matters most: it is what a model learns to predict.
#
# **Do now:** check the dropdowns, leave unrelated columns as **—**, click **Approve descriptor**. The next cell waits for it. Explore, Ask, Train and Share use this approved map.
#
# Plain Python: `review.approve({"COLUMN": "role", ...})`.

# %% tags=["review"]
review = nb.review_roles(conn, ds)

# %% tags=["review"]
ds = review.dataset()
nb.show_roles(ds)
