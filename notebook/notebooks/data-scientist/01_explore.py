# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown]
# # Prepare, explore, model, validate
#
# **Dataset:** the one you approved last (else `amazon_sales`). Change `DATASET` for `fraud_transactions` or your own file.
#
# ![Steps 3 Prepare, 4 Explore, 5 Model and 6 Validate of nine: Access, Understand, Prepare, Explore, Model, Validate, Ask with AI, Share, Hand off](journey:3,4,5,6)
#
# Each query is built from the approved column map, so no cell names a column. If the data has no date or no text, the step that needs it skips and says why. All settings are in the first cell. The AI step at the end is optional and off.

# %%
DATASET = None   # None: the dataset approved last in a quickstart (else amazon_sales); or "fraud_transactions", or your own file ("~/my-data/transactions.csv", roles beside it)
USE_AI_THEMES = False  # True: your model sorts the texts into themes (needs a text column and EXAKIT_MODEL_ID; see the AI step below)
USE_JOINED = False     # True: approve the schema map and create the joined view proposed under Prepare (several tables), and explore that
USE_PREPARED = False   # True: create the typed, cleaned view proposed under Prepare and explore that instead (nothing is created before)

# %% [markdown]
# ## Optional · Your AI model and Langfuse
#
# Only the AI step at the end needs this.
#
# - **In the cell:** `MODEL_ID`, `PROVIDER_BASE_URL` (any Chat Completions endpoint, listed in `MODEL-PROVIDERS.md`) and `LANGFUSE_BASE_URL` (where calls are traced).
# - **Not in the cell:** the API key and the two Langfuse keys. A hidden box asks for them. They stay in this kernel only.
# - **Not sure what to set?** Run `nb.model_setup()`. It asks for anything missing, with the keys in a hidden box, and prints the terminal lines that set them for every notebook.

# %%
import exakit.nb as nb

MODEL_ID = ""           # e.g. "claude-opus-5-5"; empty: no model (or the one set before `exakit notebook`)
PROVIDER_BASE_URL = ""  # e.g. "https://api.anthropic.com/v1/" - any Chat Completions endpoint (MODEL-PROVIDERS.md lists more)
LANGFUSE_BASE_URL = ""  # e.g. "https://cloud.langfuse.com"; empty: the model calls are not traced
nb.use_model(MODEL_ID, PROVIDER_BASE_URL, LANGFUSE_BASE_URL)

# %% [markdown]
# ## Step 2, continued · Your column map
#
# Every query below is built from this map. A draft map is enough here.

# %%
import os
import exakit.nb as nb

workflow_id = nb.continue_workflow("explore")   # the quickstart's workflow, or the last one: nothing to paste
connection = nb.connect()
dataset_id = nb.chosen_dataset(DATASET)
loaded_dataset = nb.review_roles(connection, dataset_id).dataset(draft_ok=True)   # the table as loaded; `dataset` below is what the steps read
nb.show_roles(loaded_dataset)

# %% [markdown]
# ## Step 3 · Prepare the data
#
# Three checks: is the data clean, does it link to other tables, are the column types correct. They only propose. The table never changes. A view is created only when you set it in the first cell.

# %% [markdown]
# ### Is the data clean?
#
# Finds repeated IDs, empty cells, placeholders such as "Unknown" and a rare label, and says what each does to a result. It changes nothing. `fraud_transactions` has all of them.

# %%
findings = nb.data_checks(connection, loaded_dataset)
findings

# %% [markdown]
# ### Linked tables
#
# Shows the tables that link to this one, with the evidence for each link. A link adds the other table's columns without adding rows.
#
# To correct a link: `schema_map.unlink("TABLE.COLUMN")` or `schema_map.link("TABLE.COLUMN", "TABLE.KEY")`.

# %%
schema_map = nb.describe_schema(connection, loaded_dataset)
schema_map

# %% [markdown]
# The joined view combines this table with every linked table. Read the joins and the SQL. To use it, set `USE_JOINED = True` in the first cell and run again. The view goes into `EXAKIT_PREPARED`, and the steps below read it.

# %%
joined_view_proposal = schema_map.joined_view(loaded_dataset)
joined_dataset = joined_view_proposal.create(connection) if USE_JOINED and joined_view_proposal.needed else loaded_dataset
joined_view_proposal

# %% [markdown]
# ### A typed, cleaned view
#
# Proposes a view with correct types (numbers, dates), blanks and placeholders as NULL, and exact copies removed. The table never changes.
#
# Read what changes. To use it, set `USE_PREPARED = True` in the first cell and run again. The view goes into `EXAKIT_PREPARED`, and the steps below read it.

# %%
typed_view_proposal = nb.typed_view(connection, joined_dataset)
dataset = typed_view_proposal.create(connection) if USE_PREPARED and typed_view_proposal.needed else joined_dataset   # the dataset every step below reads
typed_view_proposal

# %% [markdown]
# ## Step 4 · Explore
#
# Compares the groups and follows the outcome over time. Each query shows its SQL, then the result and a short note.

# %% [markdown]
# ### Columns for the steps below
#
# A role that the data does not have is `None`. A step that needs it skips and says why.

# %%
ENTITY_COLUMN = dataset.col("entity") if dataset.has("entity") else None
CATEGORY_COLUMN = dataset.col("category") if dataset.has("category") else None
TEXT_SQL = dataset.text_sql() if dataset.has("text") else None
DATE_COLUMN = dataset.col("date") if dataset.has("date") else None      # a role no column fits is None here, never guessed
LABEL_COLUMN = dataset.col("label") if dataset.has("label") else None
missing_roles = {missing["role"]: missing["reason"] for missing in dataset.missing if not dataset.has(missing["role"])}
missing_line = "; ".join(f"no {role} role: {reason}" for role, reason in missing_roles.items())
for role in ("entity", "category", "date", "label", "text"):
    if role in missing_roles:
        print(f"No {role} role ({missing_roles[role]}): steps that need it explain why they skip below.")

# %% [markdown]
# ### Compare groups
#
# The 10 largest entities by category: the row count and the % where the label is 1.

# %%
landscape = landscape_grid = None
# Result columns are named after the data (SHIP_STATE, ORDER_LINES, CANCELLED_PCT); a note under each result says
# what its numbers mean.
COUNT_HEADER = nb.count_name(dataset)
ENTITY_HEADER = nb.name(ENTITY_COLUMN) if ENTITY_COLUMN else None
CATEGORY_HEADER = nb.name(CATEGORY_COLUMN) if CATEGORY_COLUMN else None
LABEL_PCT_HEADER = nb.name(LABEL_COLUMN, "PCT") if LABEL_COLUMN else None
if not all(dataset.has(role) for role in ("entity", "category", "label")):
    print(f"Skipped - the landscape needs entity, category and label roles ({missing_line}).")
else:
    overall_rate = nb.sql(connection, f"SELECT COUNT(*) AS N, ROUND(100 * AVG({LABEL_COLUMN}), 1) AS PCT FROM {dataset.fact_table}")
    landscape = nb.sql(connection, f"""
WITH TOP_ENTITIES AS (
    SELECT {ENTITY_COLUMN} AS ENTITY, COUNT(*) AS N_ROWS
    FROM {dataset.fact_table}
    GROUP BY {ENTITY_COLUMN}
    ORDER BY N_ROWS DESC
    LIMIT 10)
SELECT T.ENTITY AS {ENTITY_HEADER},
       F.{CATEGORY_COLUMN} AS {CATEGORY_HEADER},
       COUNT(*) AS {COUNT_HEADER},
       ROUND(100 * AVG(F.{LABEL_COLUMN}), 1) AS {LABEL_PCT_HEADER}
FROM {dataset.fact_table} F
JOIN TOP_ENTITIES T ON F.{ENTITY_COLUMN} = T.ENTITY
GROUP BY T.ENTITY, F.{CATEGORY_COLUMN}
ORDER BY T.ENTITY, {COUNT_HEADER} DESC""")
    nb.show_sql()
    nb.note_groups(landscape, dataset, (ENTITY_HEADER, CATEGORY_HEADER), COUNT_HEADER, LABEL_PCT_HEADER, overall=(overall_rate["N"][0], overall_rate["PCT"][0]))
    landscape_grid = landscape.pivot_table(index=ENTITY_HEADER, columns=CATEGORY_HEADER, values=COUNT_HEADER, fill_value=0, aggfunc="sum")
landscape

# %% [markdown]
# The same counts as a grid: one row per entity, one column per category.

# %%
landscape_grid

# %% [markdown]
# ### Over time
#
# Rows per day, month or year, and the % where the label is 1. Needs the date and label roles.

# %%
over_time = None
if not (dataset.has("date") and dataset.has("label")):
    print(f"Skipped - rows and label rate per period need the date and label roles ({missing_line}).")
else:
    date_span = nb.sql(connection, f"SELECT DAYS_BETWEEN(MAX({DATE_COLUMN}), MIN({DATE_COLUMN})) AS DAYS FROM {dataset.fact_table}")
    span_days = int(date_span["DAYS"][0] or 0)
    period = "DAY" if span_days <= 62 else "MONTH" if span_days <= 3 * 366 else "YEAR"

    over_time = nb.sql(connection, f"""
SELECT CAST(DATE_TRUNC('{period}', {DATE_COLUMN}) AS DATE) AS {period}_START,
       COUNT(*) AS {COUNT_HEADER},
       ROUND(100 * AVG({LABEL_COLUMN}), 1) AS {LABEL_PCT_HEADER}
FROM {dataset.fact_table}
GROUP BY 1
ORDER BY 1""")
    nb.show_sql()
    nb.note_trend(over_time, dataset, f"{period}_START", COUNT_HEADER, LABEL_PCT_HEADER)
over_time

# %% [markdown]
# ## Step 5 · Train a model
#
# Trains a small model on this computer to predict the label. First, it removes the columns that give the answer away.

# %% [markdown]
# ### Remove columns that give the answer away
#
# A column written after the outcome (an order's status after cancellation) predicts the label perfectly on old rows and fails on new rows. This cell flags those columns. The model does not use them.

# %%
LEAKING_COLUMNS = nb.leakage_check(connection, dataset)

# %% [markdown]
# ### Train a baseline model
#
# The simplest useful model. It shows how much the data can predict. It trains on three quarters of the rows and keeps one quarter for step 6.
#
# Inputs: the category, the entity and the month (when there is a date). It reads the newest 20,000 rows, or the first 20,000 by key, so a rerun reads the same rows. Needs a label and a category or entity.
#
# Method: one-hot features, logistic regression with balanced class weights, stratified split with a fixed seed.

# %%
MODEL_ROW_LIMIT = 20000
# The features the model reads, each only when its role exists and does not give the label away: the category and the
# entity as text, then the month of the date.
USE_CATEGORY = dataset.has("category") and CATEGORY_COLUMN.strip('"') not in LEAKING_COLUMNS
USE_ENTITY = dataset.has("entity") and ENTITY_COLUMN.strip('"') not in LEAKING_COLUMNS
CATEGORY_FEATURE = f"CAST({dataset.col('category')} AS VARCHAR(2000)) AS CATEGORY_,\n       " if USE_CATEGORY else ""
ENTITY_FEATURE = f"CAST({dataset.col('entity')} AS VARCHAR(2000)) AS ENTITY_,\n       " if USE_ENTITY else ""
MONTH_FEATURE = f"EXTRACT(MONTH FROM {dataset.col('date')}) AS MONTH_,\n       " if dataset.has("date") else ""
# Which rows: the newest by date, else the first by the key - the same rows on every rerun either way.
KEY_COLUMN = dataset.descriptor.slots.get("key")
ROW_ORDER = f"{dataset.col('date')} DESC" if dataset.has("date") else (f'"{KEY_COLUMN}"' if KEY_COLUMN else "1")

model = None
if not (dataset.has("label") and (USE_CATEGORY or USE_ENTITY)):
    print(f"Skipped - the small model predicts the label from the category and entity, which needs a label and a "
          f"category or entity role that does not give the label away ({missing_line or 'see the cell above'}).")
else:
    # What each feature is called on screen: the column it comes from, or "month".
    FEATURE_LABELS = {"MONTH_": "month", "CATEGORY_": (CATEGORY_COLUMN or "").strip('"'), "ENTITY_": (ENTITY_COLUMN or "").strip('"')}
    if not DATE_COLUMN:
        print("No date: the model reads the first rows by the key and leaves the month out.")
    model_rows = nb.sql(connection, f"""
SELECT {CATEGORY_FEATURE}{ENTITY_FEATURE}{MONTH_FEATURE}{LABEL_COLUMN} AS LABEL_
FROM {dataset.fact_table}
WHERE {LABEL_COLUMN} IS NOT NULL
ORDER BY {ROW_ORDER}
LIMIT {MODEL_ROW_LIMIT}""")
    nb.show_sql()

    from sklearn.linear_model import LogisticRegression
    from sklearn.model_selection import train_test_split
    from sklearn.pipeline import Pipeline
    from sklearn.preprocessing import OneHotEncoder

    feature_columns = [name for name in ("CATEGORY_", "ENTITY_", "MONTH_") if name in model_rows.columns]
    feature_values, label_values = model_rows[feature_columns].fillna("(none)").astype(str), model_rows["LABEL_"].astype(int)
    train_features, test_features, train_labels, test_labels = train_test_split(feature_values, label_values, test_size=0.25, random_state=0, stratify=label_values)
    model = Pipeline([
        ("onehot", OneHotEncoder(handle_unknown="ignore")),
        ("classifier", LogisticRegression(max_iter=1000, class_weight="balanced")),
    ])
    model.fit(train_features, train_labels)
    print(f"Trained on {len(train_labels):,} rows; {len(test_labels):,} rows kept back for the test in step 6.")

# %% [markdown]
# ## Step 6 · Validate
#
# Scores the model on the quarter of rows it did not see. Then lists the values it uses most.

# %% [markdown]
# ### Score on unseen rows
#
# ROC AUC: 0.5 is a guess, 1.0 is perfect. The note compares it with always predicting the most common answer.

# %%
roc_auc = None
if model is not None:
    from sklearn.metrics import roc_auc_score

    roc_auc = roc_auc_score(test_labels, model.predict_proba(test_features)[:, 1])
    print(f"ROC AUC on the held-out quarter: {roc_auc:.3f}")
    nb.note_model(roc_auc, dataset, len(model_rows), label_values.mean())

# %% [markdown]
# ### What it uses most
#
# The strongest values in each direction. Treat them as leads, not proof. A value with few rows can look strong by chance.

# %%
import numpy as np

if model is not None:
    feature_names = model.named_steps["onehot"].get_feature_names_out(feature_columns)
    feature_weights = model.named_steps["classifier"].coef_[0]
    weight_order = np.argsort(feature_weights)

    def describe_feature(name):
        feature, value = name.split("_", 1)[0] + "_", name.split("__", 1)[1]
        return f"{FEATURE_LABELS[feature]} = {value}"

    CLUES_PER_SIDE = min(8, len(feature_names) // 2)        # each side its own values: few values are split, never shown twice
    print(f"Make {LABEL_COLUMN} = 1 more likely:", ", ".join(describe_feature(feature_name) for feature_name in feature_names[weight_order[-CLUES_PER_SIDE:]][::-1]))
    print(f"Make {LABEL_COLUMN} = 1 less likely:", ", ".join(describe_feature(feature_name) for feature_name in feature_names[weight_order[:CLUES_PER_SIDE]]))

# %% [markdown]
# ## Optional · Themes in the label-1 texts (AI)
#
# Needs a text column. The practice datasets have none, so this step skips.
#
# Your model groups the newest texts on each side of the label into themes. A theme on one side only is a lead.
#
# To turn it on, fill in the model cell above and run it. Then set `USE_AI_THEMES = True` in the first cell. It makes two model calls. A live source asks before it sends anything. With `LANGFUSE_BASE_URL` set, both calls go into one trace, `explore-themes`.

# %%
SAMPLE_TEXTS = 20      # per side: the newest texts where the label is 1, and as many where it is 0
text_sample = themes = None
NEWEST_FIRST = f"{dataset.col('date')} DESC" if dataset.has("date") else dataset.col("entity") if dataset.has("entity") else "1"
PER_LABEL = f"PARTITION BY {dataset.col('label')} " if dataset.has("label") else ""
LABELLED_ONLY = f" AND {dataset.col('label')} IS NOT NULL" if dataset.has("label") else ""
if not dataset.has("text"):
    print(f"Skipped - the themes need a text role ({missing_line}).")
else:
    TEXT_SAMPLE_SQL = f"""
SELECT {LABEL_COLUMN or 'NULL'} AS LABEL_, {TEXT_SQL} AS TEXT_
FROM {dataset.fact_table}
WHERE LENGTH(TRIM({TEXT_SQL})) > 0{LABELLED_ONLY}
QUALIFY ROW_NUMBER() OVER ({PER_LABEL}ORDER BY {NEWEST_FIRST}) <= {SAMPLE_TEXTS}"""
    text_sample = nb.sql(connection, TEXT_SAMPLE_SQL)
    nb.show_sql()
    if not USE_AI_THEMES:
        print("The AI step is off: above is the sample it would read. To run it, switch USE_AI_THEMES on in the first "
              "cell. Everything else in this notebook runs without a model.")
    else:
        model_endpoint = nb.model_client()
        if model_endpoint is not None and nb.confirm_send(dataset, len(text_sample)):
            themes = nb.themes(connection, dataset, text_sample, model_endpoint, sql=TEXT_SAMPLE_SQL)
themes if themes is not None else text_sample

# %% [markdown]
# ## Next: step 7
#
# Note one finding to check. Then open `02_ask_your_data.ipynb` and ask a question in plain English. For other data, change `DATASET` and run again.

