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
# **Dataset:** the one you approved last (else `amazon_sales`); change `DATASET` for `walmart_sales`, `fraud_transactions` or your own file.
#
# **The journey:** 1 Access → 2 Understand → **3 Prepare → 4 Explore → 5 Model → 6 Validate** → 7 Ask with AI → 8 Share → 9 Hand off. **This notebook: steps 3 to 6.**
#
# Check the data is clean, compare groups and follow outcomes over time, train a small model and find out, honestly, how good it is. Every query is built from the dataset's approved column map, so nothing here names a column: change `DATASET` and every cell follows. A step whose role the data does not have (no date in `fraud_transactions`, no text in any of the three) skips and says why.
#
# Optional, for data with a text column: `USE_AI_THEMES = True` lets your model say what the label-1 texts are about, traced to Langfuse when it is set up.

# %%
DATASET = None   # None: the dataset approved last in a quickstart (else amazon_sales); or "walmart_sales", "fraud_transactions", or your own file ("~/my-data/transactions.csv", roles beside it)
USE_AI_THEMES = False  # True: your model sorts the texts into themes (needs a text column and EXAKIT_MODEL_ID; see the AI step below)
USE_JOINED = False     # True: approve the schema map and create the joined view proposed under Prepare (several tables), and explore that
USE_PREPARED = False   # True: create the typed, cleaned view proposed under Prepare and explore that instead (nothing is created before)

# %% [markdown]
# ## Optional · Your AI model and Langfuse
#
# > **What is this?** Where you tell the notebook which AI model to use (for the text step at the end), and where to record its calls (Langfuse: what was sent, the answer, the cost).
# > We set it here so you need no terminal: fill in the plain values and run the cell; the keys are asked for in a hidden box.
# > The keys stay in this notebook's kernel only - never in this file - and are gone when it stops. Left empty, the cell changes nothing.

# %%
import exakit.nb as nb

MODEL_ID = ""           # e.g. "claude-opus-5-5"; empty: no model (or the one set before `exakit notebook`)
PROVIDER_BASE_URL = ""  # e.g. "https://api.anthropic.com/v1/" - any Chat Completions endpoint (MODEL-PROVIDERS.md lists more)
LANGFUSE_BASE_URL = ""  # e.g. "https://cloud.langfuse.com"; empty: the model calls are not traced
nb.use_model(MODEL_ID, PROVIDER_BASE_URL, LANGFUSE_BASE_URL)

# %% [markdown]
# ## Step 2, continued · The column map you approved
#
# > **The column map (descriptor), again:** it says which column is the key, the time, the groups and the outcome (label).
# > Every query below is built from it, so the same notebook runs on any dataset whose map you approved.
#
# `DATASET` is a sample ID or a file path with its descriptor beside it. A draft map is enough here.
#
# Everything you set is in the first cell: run it, then this one. Steps whose roles are missing skip and say why.

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
# > **What happens here?** Three looks at the data before anything is computed from it: is it clean (repeats, gaps, placeholders), does it link to other tables, and are its columns in the types they should be. Each look only *proposes*; the table is never changed, and a cleaned or joined view is created only when you say so in the first cell.

# %% [markdown]
# ### Is the data clean?
#
# > **Why check first?** A rate or a model is only as good as the rows under it. Repeated ids count twice, empty cells
# > drop out of averages, a value like "Unknown" poses as a category, and a rare label makes a lazy model look accurate.
# > This cell finds each of those from the column map, says what it does to a result, and changes nothing.
#
# Read each line before trusting a number below. `fraud_transactions` is messy on purpose: it has all of them.

# %%
findings = nb.data_checks(connection, loaded_dataset)
findings

# %% [markdown]
# ### Several tables: the schema around it
#
# > **What is a schema map?** The tables that sit beside this one, and how they link: a column that holds another
# > table's key (an order's customer number, a customer's country) is a many-to-one link, so following it adds that
# > table's columns to each row without multiplying rows. The map names each link with its evidence.
#
# The map below is found from the data: a link the database declares, or a column that names another table's key and whose every value is in it. Correct it with `schema_map.unlink("TABLE.COLUMN")` or `schema_map.link("TABLE.COLUMN", "TABLE.KEY")`.

# %%
schema_map = nb.describe_schema(connection, loaded_dataset)
schema_map

# %% [markdown]
# The joined view: this table with every table its links reach, as one view. Read the joins and the SQL; to use it, set `USE_JOINED = True` in the first cell and run again. The schema map is then approved (its links published for agents), the view is created in `EXAKIT_PREPARED`, gets its own approved column map, and every step below reads it. A table that links nowhere has nothing to join.

# %%
joined_view_proposal = schema_map.joined_view(loaded_dataset)
joined_dataset = joined_view_proposal.create(connection) if USE_JOINED and joined_view_proposal.needed else loaded_dataset
joined_view_proposal

# %% [markdown]
# ### A typed, cleaned view
#
# > **What is a typed view?** A view over the table with each column in the type its values really have - numbers stored
# > as text become numbers, dates become dates - blanks and placeholders as NULL, and exact copies dropped.
# > The table itself is never changed; the view is proposed here, shown with its SQL, and created only when you say so.
#
# Read what would change below. To use it, set `USE_PREPARED = True` in the first cell and run again: the view is created in `EXAKIT_PREPARED`, gets its own approved column map (the same roles), and every step below reads it.

# %%
typed_view_proposal = nb.typed_view(connection, joined_dataset)
dataset = typed_view_proposal.create(connection) if USE_PREPARED and typed_view_proposal.needed else joined_dataset   # the dataset every step below reads
typed_view_proposal

# %% [markdown]
# ## Step 4 · Explore
#
# > **What happens here?** The first real questions: how do the groups compare, and how does the outcome move over time. Each answer is one query, printed before its result, with a note in plain words under it.

# %% [markdown]
# ### The columns the steps below use
#
# Each step takes its columns from the column map: a role the data does not have is `None` here, and the steps that need it skip and say why.

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
# The 10 biggest entities, split by category: how many rows each has and, for each, the % where the label is 1. The note under the result says what it means.

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
# The same counts as a grid: one row per entity, one column per category, each cell the number of rows.

# %%
landscape_grid

# %% [markdown]
# ### Over time
#
# How many rows per day, month or year (picked from the date span), and the % where the label is 1. Needs date and label roles. The note under the result says what it means.

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
# ## Step 5 · Train a model to predict
#
# > **What happens here?** A small model learns to tell label 1 from label 0 from the columns the map names, on this computer, in seconds. First, though, any column that already *knows* the answer is set aside - otherwise the model only learns to read it.

# %% [markdown]
# ### Leave out columns that give the answer away
#
# > **What is leakage?** A column written after the outcome - an order's status once it was cancelled - predicts the
# > label perfectly and makes any model look brilliant, then fails on new rows where it is not known yet.
# > This cell flags every column whose values (almost) decide the label on their own; the model below leaves them out.

# %%
LEAKING_COLUMNS = nb.leakage_check(connection, dataset)

# %% [markdown]
# ### Train a small baseline model
#
# > **What is a baseline model?** The simplest model worth trying, to see how much the data can tell at all.
# > It learns from most rows and keeps a quarter back, unseen, for the test in the next step.
# > If it is barely better than guessing there, a bigger model is unlikely to rescue the idea.
#
# The model learns from what the column map names: the category, the entity and, when the data has a date, its month (a column the cell above flagged is left out). With a date it uses the newest 20,000 rows; without one, the first 20,000 by the key, so a rerun reads the same rows. It needs a label and a category or entity.
#
# Technical: one-hot features, logistic regression with balanced class weights, a stratified split with a fixed seed.

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
# > **What happens here?** The model is graded on the quarter of rows it never saw, like a test with new questions, and the score is put into words. Then the values it leans on are listed, as clues to check - not as proof.

# %% [markdown]
# ### How good is it, honestly
#
# Runs only when the model above ran. The score is ROC AUC on the held-out quarter: 0.5 is guessing, 1.0 is perfect. The note under it says what that means for this data, and what "always predicting the common answer" would already get right - the baseline a model has to beat.

# %%
roc_auc = None
if model is not None:
    from sklearn.metrics import roc_auc_score

    roc_auc = roc_auc_score(test_labels, model.predict_proba(test_features)[:, 1])
    print(f"ROC AUC on the held-out quarter: {roc_auc:.3f}")
    nb.note_model(roc_auc, dataset, len(model_rows), label_values.mean())

# %% [markdown]
# ### What it leans on
#
# Runs only when the model above ran. The values the model leans on most, each way: a category, an entity or a month. They are clues, not proof: a value with few rows can look strong by chance.

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
# ## Optional · What the label-1 texts are about (AI)
#
# Needs a text column: on the three sample datasets (`amazon_sales`, `walmart_sales`, `fraud_transactions`) it skips and says why. Your model reads the newest texts on each side of the label (label `= 1` and `= 0`) and sorts each side into a few themes. A theme found on one side only is the clue. The note under the result says how to read it.
#
# To switch it on: fill in the model cell at the top (*Optional · Your AI model and Langfuse*) and run it, then `USE_AI_THEMES = True` in the first cell. Two model calls, a few cents. A live source asks before anything is sent.
#
# With `LANGFUSE_BASE_URL` filled in there too, both calls are one trace, `explore-themes`, with what was sent, the answer, tokens, cost, time and two scores (`valid_json`, `texts_placed`): run it with another model and compare the two traces.
#
# Rather set them for every notebook? Export `EXAKIT_MODEL_ID`, `EXAKIT_PROVIDER_BASE_URL`, `EXAKIT_PROVIDER_API_KEY` and the `LANGFUSE_*` keys in the terminal before `exakit notebook` (the README in the notebooks folder shows how).

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
# Keep one finding worth validating. Then open `02_ask_your_data.ipynb` to ask the data a question in plain English, with an AI model drafting the SQL if you want one. To rerun this notebook on other data, change `DATASET`.
