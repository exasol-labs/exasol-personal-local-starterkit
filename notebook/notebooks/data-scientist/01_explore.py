# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown]
# # Explore
#
# **Dataset:** `esophageal_posts` by default; change `DATASET` for `banking_complaints` or your own file. **How long:** about two minutes.
#
# Compare groups, follow outcomes over time, fit a small local model, and see what the texts are about.
#
# Optional: `USE_AI_THEMES = True` lets your model say what the label-1 texts are about, traced to Langfuse when it is set up.

# %%
DATASET = "esophageal_posts"   # or "banking_complaints", or your own file ("~/my-data/transactions.csv", roles beside it)
USE_AI_THEMES = False  # True: your model sorts the texts into themes (needs EXAKIT_MODEL_ID; see the AI step below)
WORKFLOW_ID = None  # paste the quickstart's wf-... id to continue its log

# %% [markdown]
# ## Load the column map
#
# `DATASET` is a sample ID or a file path with its descriptor beside it. A draft map is enough here.
#
# Everything you set is in the first cell: run it, then this one. Steps whose roles are missing skip and say why.

# %%
import os
import exakit.nb as nb

wid = nb.workflow("explore", resume=WORKFLOW_ID or os.environ.get("EXAKIT_WORKFLOW_ID"))
conn = nb.connect()
ds = nb.review_roles(conn, DATASET).dataset(draft_ok=True)
nb.show_roles(ds)

ENTITY = ds.col("entity") if ds.has("entity") else None
CATEGORY = ds.col("category") if ds.has("category") else None
TEXT = ds.text_sql() if ds.has("text") else None
DATE = ds.col("date") if ds.has("date") else None      # a role no column fits is None here, never guessed
LABEL = ds.col("label") if ds.has("label") else None
skipped = {m["role"]: m["reason"] for m in ds.missing if not ds.has(m["role"])}
missing_line = "; ".join(f"no {role} role: {reason}" for role, reason in skipped.items())
for role in ("entity", "category", "date", "label", "text"):
    if role in skipped:
        print(f"No {role} role ({skipped[role]}): steps that need it explain why they skip below.")

# %% [markdown]
# ## Compare groups
#
# The 10 biggest entities, split by category: how many rows each has and, for each, the % where the label is 1. The note under the result says what it means.

# %%
landscape = pivot = None
# Result columns are named after the data (SOURCE_DOMAIN, POSTS, IS_NEGATIVE_PCT); a note under each result says
# what its numbers mean.
COUNT = nb.count_name(ds)
E = nb.name(ENTITY) if ENTITY else None
C = nb.name(CATEGORY) if CATEGORY else None
PCT = nb.name(LABEL, "PCT") if LABEL else None
if not all(ds.has(role) for role in ("entity", "category", "label")):
    print(f"Skipped - the landscape needs entity, category and label roles ({missing_line}).")
else:
    overall = nb.sql(conn, f"SELECT COUNT(*) AS N, ROUND(100 * AVG({LABEL}), 1) AS PCT FROM {ds.fact_table}")
    landscape = nb.sql(conn, f"""
WITH TOP_ENTITIES AS (
    SELECT {ENTITY} AS ENTITY, COUNT(*) AS N_ROWS
    FROM {ds.fact_table}
    GROUP BY {ENTITY}
    ORDER BY N_ROWS DESC
    LIMIT 10)
SELECT T.ENTITY AS {E},
       F.{CATEGORY} AS {C},
       COUNT(*) AS {COUNT},
       ROUND(100 * AVG(F.{LABEL}), 1) AS {PCT}
FROM {ds.fact_table} F
JOIN TOP_ENTITIES T ON F.{ENTITY} = T.ENTITY
GROUP BY T.ENTITY, F.{CATEGORY}
ORDER BY T.ENTITY, {COUNT} DESC""")
    nb.show_sql()
    nb.note_groups(landscape, ds, (E, C), COUNT, PCT, overall=(overall["N"][0], overall["PCT"][0]))
    pivot = landscape.pivot_table(index=E, columns=C, values=COUNT, fill_value=0, aggfunc="sum")
landscape

# %% [markdown]
# The same counts as a grid: one row per entity, one column per category, each cell the number of rows.

# %%
pivot

# %% [markdown]
# ## Over time
#
# How many rows per day, month or year (picked from the date span), and the % where the label is 1. Needs date and label roles. The note under the result says what it means.

# %%
over_time = None
if not (ds.has("date") and ds.has("label")):
    print(f"Skipped - rows and label rate per period need the date and label roles ({missing_line}).")
else:
    span = nb.sql(conn, f"SELECT DAYS_BETWEEN(MAX({DATE}), MIN({DATE})) AS DAYS FROM {ds.fact_table}")
    days = int(span["DAYS"][0] or 0)
    period = "DAY" if days <= 62 else "MONTH" if days <= 3 * 366 else "YEAR"

    over_time = nb.sql(conn, f"""
SELECT CAST(DATE_TRUNC('{period}', {DATE}) AS DATE) AS {period}_START,
       COUNT(*) AS {COUNT},
       ROUND(100 * AVG({LABEL}), 1) AS {PCT}
FROM {ds.fact_table}
GROUP BY 1
ORDER BY 1""")
    nb.show_sql()
    nb.note_trend(over_time, ds, f"{period}_START", COUNT, PCT)
over_time

# %% [markdown]
# ## Small baseline model
#
# A small model learns to tell label 1 from label 0 using the text and the category, on up to 20,000 recent rows, and is checked on a quarter it has not seen. The note says how good it is in plain words.
#
# Technical: TF-IDF text + one-hot category, logistic regression; the score is ROC AUC (0.5 = guessing).

# %%
SAMPLE = 20000

model = None
if not all(ds.has(role) for role in ("entity", "category", "text", "date", "label")):
    print(f"Skipped - the small model predicts the label from the newest {SAMPLE} rows, which needs entity, category, text, label and date "
          f"roles ({missing_line}).")
else:
    rows = nb.sql(conn, f"""
SELECT {TEXT} AS TEXT_,
       CAST({CATEGORY} AS VARCHAR(2000)) AS CATEGORY_,
       {LABEL} AS LABEL_
FROM {ds.fact_table}
WHERE {LABEL} IS NOT NULL
ORDER BY {DATE} DESC, {ENTITY}
LIMIT {SAMPLE}""")
    nb.show_sql()

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
    print(f"ROC AUC on the held-out quarter: {auc:.3f}")
    nb.note_model(auc, ds, len(rows), y.mean())

# %% [markdown]
# ## Model clues
#
# The words the model leans on most, each way. They are clues, not proof: drop a word that is boilerplate (it appears in every text) or a leak (it gives the answer away, like the label's own name).

# %%
import numpy as np

if model is not None:
    names = model.named_steps["features"].get_feature_names_out()
    weights = model.named_steps["classifier"].coef_[0]
    order = np.argsort(weights)
    print(f"Make {LABEL} = 1 more likely:", ", ".join(n.split("__", 1)[1] for n in names[order[-12:]][::-1]))
    print(f"Make {LABEL} = 1 less likely:", ", ".join(n.split("__", 1)[1] for n in names[order[:12]]))

# %% [markdown]
# ## Optional: what the label-1 texts are about
#
# Your model reads the newest texts on each side of the label (`IS_NEGATIVE = 1` and `= 0`) and sorts each side into a few themes. A theme found on one side only is the clue. The note under the result says how to read it.
#
# To switch it on: set `EXAKIT_MODEL_ID`, `EXAKIT_PROVIDER_BASE_URL` and `EXAKIT_PROVIDER_API_KEY` before `exakit notebook`, then `USE_AI_THEMES = True` in the first cell. Two model calls, a few cents. A live source asks before anything is sent.
#
# With `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` and `LANGFUSE_BASE_URL` set too, both calls are one trace, `explore-themes`, with what was sent, the answer, tokens, cost, time and two scores (`valid_json`, `texts_placed`): run it with another model and compare the two traces.

# %%
SAMPLE_TEXTS = 20      # per side: the newest texts where the label is 1, and as many where it is 0
text_sample = themes = None
NEWEST = f"{ds.col('date')} DESC" if ds.has("date") else ds.col("entity") if ds.has("entity") else "1"
SIDES = f"PARTITION BY {ds.col('label')} " if ds.has("label") else ""
LABELLED = f" AND {ds.col('label')} IS NOT NULL" if ds.has("label") else ""
if not ds.has("text"):
    print(f"Skipped - the themes need a text role ({missing_line}).")
else:
    SAMPLE_SQL = f"""
SELECT {LABEL or 'NULL'} AS LABEL_, {TEXT} AS TEXT_
FROM {ds.fact_table}
WHERE LENGTH(TRIM({TEXT})) > 0{LABELLED}
QUALIFY ROW_NUMBER() OVER ({SIDES}ORDER BY {NEWEST}) <= {SAMPLE_TEXTS}"""
    text_sample = nb.sql(conn, SAMPLE_SQL)
    nb.show_sql()
    if not USE_AI_THEMES:
        print("The AI step is off: above is the sample it would read. To run it, switch USE_AI_THEMES on in the first "
              "cell. Everything else in this notebook runs without a model.")
    else:
        endpoint = nb.model_client()
        if endpoint is not None and nb.confirm_send(ds, len(text_sample)):
            themes = nb.themes(conn, ds, text_sample, endpoint, sql=SAMPLE_SQL)
themes if themes is not None else text_sample

# %% [markdown]
# ## Decide what to test next
#
# Keep one finding worth validating. To rerun on other data, change `DATASET`.
