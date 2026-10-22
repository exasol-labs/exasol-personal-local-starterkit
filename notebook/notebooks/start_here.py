# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown]
# # Start here
#
# This notebook is connected to your local Exasol database by the Starter Kit.
# It runs on the kernel **Exasol (Starter Kit)**, which `exakit notebook` registered: there is no host, user or password in it.

# %%
import exakit_nb

conn = exakit_nb.connect()
exakit_nb.sql(conn, "SELECT CURRENT_TIMESTAMP AS NOW, CURRENT_SESSION AS SESSION_ID")

# %% [markdown]
# ## What is in the database
#
# The schemas, including the sample datasets the kit loaded.

# %%
exakit_nb.sql(conn, "SELECT SCHEMA_NAME FROM SYS.EXA_SCHEMAS ORDER BY 1")

# %% [markdown]
# Every result can be traced back to the statement that produced it:

# %%
exakit_nb.show_sql()

# %% [markdown]
# ## Next
#
# - Load your own CSV or Parquet file from a terminal: `exakit data-load <file>`
# - Run Python inside the database: `exakit udf-setup` (the udf-devkit add-on)
