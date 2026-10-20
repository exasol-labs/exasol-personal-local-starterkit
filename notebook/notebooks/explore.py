# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown]
# # Explore a dataset
#
# This notebook runs on any dataset that has a **descriptor**: a small JSON file naming which column plays each role -
# the *entity* a row is about, the *category* to compare, the *date*, the *label* to predict (0 or 1) and the *text*.
# Every query below is built from those roles and printed before its result, so you always see the SQL behind a number.
#
# **Change one line to change the data.** `pharma_trials` and `banking_complaints` ship with the kit
# (`exakit data-load pharma_trials`). For your own CSV or Parquet file: load it with `exakit data-load <file>`, write a
# `descriptor.json` for its table (see `data/datasets/README.md` in the kit), and put the descriptor's path here.

# %%
DATASET = "pharma_trials"   # or "banking_complaints", or "~/my-data/descriptor.json"

# %% [markdown]
# ## Connect and read the descriptor
#
# The connection comes from the kit's kernel; there is no host, user or password in this notebook. The descriptor is
# checked by the kit's own rules and against the database: a role that names a missing table or column stops here.

# %%
import exakit_nb

conn = exakit_nb.connect()
ds = exakit_nb.dataset(conn, DATASET)

print(f"{ds.id}: one row of {ds.fact_table} per observation (descriptor sha256 {ds.digest[:12]}…)")
for role, column in ds.roles():
    print(f"  {role:<9} {column}")

ENTITY, CATEGORY, DATE, LABEL = ds.col("entity"), ds.col("category"), ds.col("date"), ds.col("label")
TEXT = ds.text_sql()

# %% [markdown]
# ## The landscape
#
# How many rows each category has, and how often the label is 1 in it.

# %%
landscape = exakit_nb.sql(conn, f"""
SELECT {CATEGORY} AS CATEGORY,
       COUNT(*) AS N,
       SUM({LABEL}) AS LABEL_1,
       ROUND(100 * AVG({LABEL}), 1) AS LABEL_1_PCT
FROM {ds.fact_table}
GROUP BY {CATEGORY}
ORDER BY N DESC""")
exakit_nb.show_sql()
landscape

# %% [markdown]
# Over time: rows and label rate per period. The period follows the span of the data - days for a few weeks,
# months for a few years, years beyond that.

# %%
span = exakit_nb.sql(conn, f"SELECT DAYS_BETWEEN(MAX({DATE}), MIN({DATE})) AS DAYS FROM {ds.fact_table}")
days = int(span["DAYS"][0] or 0)
period = "DAY" if days <= 62 else "MONTH" if days <= 3 * 366 else "YEAR"

over_time = exakit_nb.sql(conn, f"""
SELECT CAST(DATE_TRUNC('{period}', {DATE}) AS DATE) AS PERIOD,
       COUNT(*) AS N,
       ROUND(100 * AVG({LABEL}), 1) AS LABEL_1_PCT
FROM {ds.fact_table}
GROUP BY 1
ORDER BY 1""")
exakit_nb.show_sql()
over_time

# %% [markdown]
# The entities with the most rows, and their label rate.

# %%
entities = exakit_nb.sql(conn, f"""
SELECT {ENTITY} AS ENTITY,
       COUNT(*) AS N,
       ROUND(100 * AVG({LABEL}), 1) AS LABEL_1_PCT
FROM {ds.fact_table}
GROUP BY {ENTITY}
ORDER BY N DESC, ENTITY
LIMIT 10""")
exakit_nb.show_sql()
entities

# %% [markdown]
# How much text there is per row.

# %%
text_size = exakit_nb.sql(conn, f"""
SELECT ROUND(AVG(LENGTH({TEXT})), 0) AS AVG_CHARS,
       MEDIAN(LENGTH({TEXT})) AS MEDIAN_CHARS,
       MAX(LENGTH({TEXT})) AS MAX_CHARS,
       SUM(CASE WHEN LENGTH(TRIM({TEXT})) = 0 THEN 1 ELSE 0 END) AS EMPTY_ROWS
FROM {ds.fact_table}""")
exakit_nb.show_sql()
text_size

# %% [markdown]
# ## A small model, on this computer
#
# Can the text and the category predict the label? A logistic regression over word counts, trained on this machine
# with scikit-learn - no model service needed. The rows come from the database with the SQL printed below.

# %%
SAMPLE = 20000

rows = exakit_nb.sql(conn, f"""
SELECT {TEXT} AS TEXT_,
       CAST({CATEGORY} AS VARCHAR(2000)) AS CATEGORY_,
       {LABEL} AS LABEL_
FROM {ds.fact_table}
WHERE {LABEL} IS NOT NULL
ORDER BY {DATE} DESC, {ENTITY}
LIMIT {SAMPLE}""")
exakit_nb.show_sql()

from sklearn.compose import ColumnTransformer
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score
from sklearn.model_selection import train_test_split
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder

X, y = rows[["TEXT_", "CATEGORY_"]].fillna(""), rows["LABEL_"].astype(int)
X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.25, random_state=0, stratify=y)
model = Pipeline([
    ("features", ColumnTransformer([
        ("text", TfidfVectorizer(max_features=20000, ngram_range=(1, 2), min_df=2, stop_words="english"), "TEXT_"),
        ("category", OneHotEncoder(handle_unknown="ignore"), ["CATEGORY_"]),
    ])),
    ("classifier", LogisticRegression(max_iter=1000, class_weight="balanced")),
])
model.fit(X_train, y_train)
auc = roc_auc_score(y_test, model.predict_proba(X_test)[:, 1])
print(f"{len(rows)} rows, {y.mean():.1%} with label 1; ROC AUC on the held-out quarter: {auc:.3f} (0.5 is guessing)")

# %% [markdown]
# The words that push a prediction towards 1 and towards 0:

# %%
import numpy as np

names = model.named_steps["features"].get_feature_names_out()
weights = model.named_steps["classifier"].coef_[0]
order = np.argsort(weights)
print("towards 1:", ", ".join(n.split("__", 1)[1] for n in names[order[-12:]][::-1]))
print("towards 0:", ", ".join(n.split("__", 1)[1] for n in names[order[:12]]))

# %% [markdown]
# ## The text step, with your own model
#
# A few rows' text goes to **your** model endpoint, which names each row's theme in a few words. Set these before
# `exakit notebook` to turn it on (nothing is sent otherwise):
#
# - `EXAKIT_NB_MODEL` - the model name, e.g. `gpt-4o-mini`, or `llama3.1` on a local Ollama
# - `OPENAI_BASE_URL` and `OPENAI_API_KEY` - the endpoint and its key, as the OpenAI client reads them
#
# With `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` and `LANGFUSE_HOST` set too, the calls are one trace in your
# Langfuse project, tagged with the dataset, the descriptor's digest, the database session and the SQL. Without them
# the step runs untraced.

# %%
SAMPLE_TEXTS = 5

sample = exakit_nb.sql(conn, f"""
SELECT {ENTITY} AS ENTITY, {LABEL} AS LABEL_, {TEXT} AS TEXT_
FROM {ds.fact_table}
WHERE LENGTH(TRIM({TEXT})) > 0
ORDER BY {LABEL} DESC, {DATE} DESC, {ENTITY}
LIMIT {SAMPLE_TEXTS}""")
exakit_nb.show_sql()

endpoint = exakit_nb.model_client()
if endpoint is not None:
    client, model_name = endpoint
    themes = []
    with exakit_nb.trace(conn, "explore-text-step", dataset=ds):
        for text in sample["TEXT_"]:
            answer = client.chat.completions.create(
                model=model_name,
                messages=[{"role": "system", "content": "Name the theme of the text in at most five words."},
                          {"role": "user", "content": text[:4000]}])
            themes.append(answer.choices[0].message.content.strip())
    sample["THEME"] = themes
sample

# %% [markdown]
# ## Next
#
# - Change `DATASET` at the top and run everything again: the same cells work on any described dataset.
# - Train inside the database with a Python UDF: the `udf-devkit` add-on (`exakit marketplace udf-devkit`).
