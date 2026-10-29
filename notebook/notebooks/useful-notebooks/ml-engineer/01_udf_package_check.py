# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown]
# # Check the packages inside a Python UDF
#
# **Dataset:** Pharma or Banking; **How long:** two minutes. Compare the notebook's
# Python packages with the packages actually imported by the database runtime.
# Adapted from the Notebook Connector / AI Lab runtime and scikit-learn lessons.
# Sources and MIT license: `EXAMPLE-GUIDE.md`.

# %%
import exakit.nb as nb

DATASET = "pharma_trials"  # or "banking_complaints"
CONTAINER = nb.ml_train.udf_container()
conn = nb.connect()
ds = nb.dataset(conn, DATASET).require_approved("UDF package check")
nb.workflow("udf-package-check")
if not nb.check_container(conn, alias=CONTAINER):
    raise RuntimeError("Install the ML packages with: exakit udf-use default")

# %% [markdown]
# ## Import the libraries inside Exasol
#
# This script runs in the UDF container. Installing a library in Jupyter's
# environment alone does not make it available here. The ML-ready alias is
# preferred automatically; EXAKIT_UDF_CONTAINER can select another installed one.

# %%
package_script = f'''CREATE OR REPLACE {CONTAINER} SCALAR SCRIPT EXAKIT_EXAMPLES.ML_PACKAGES(x DOUBLE)
RETURNS VARCHAR(20000) AS
import json, platform
import sklearn, pandas, numpy, scipy, joblib
def run(ctx):
    return json.dumps({{"python": platform.python_version(), "scikit-learn": sklearn.__version__,
                       "pandas": pandas.__version__, "numpy": numpy.__version__,
                       "scipy": scipy.__version__, "joblib": joblib.__version__}})
'''
conn.execute("CREATE SCHEMA IF NOT EXISTS EXAKIT_EXAMPLES")
print(package_script)
conn.execute(package_script)
packages_sql = "SELECT EXAKIT_EXAMPLES.ML_PACKAGES(1) AS PACKAGES"
print(packages_sql)
runtime_packages = nb.sql(conn, packages_sql)
print(runtime_packages.iloc[0]["PACKAGES"])
