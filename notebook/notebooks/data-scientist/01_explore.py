# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown] tags=["exakit-guide-hint"]
# <div class="guide-start-hint">
#
# **Step 2 · Understand, explore and predict.** Click into the cell below and press **Shift + Enter** to open it: what each column means and the semantic views over your data, then checks, a cleaned view, groups and trends, and a first model. Its **Guided / Code** switch, top right, shows the code behind this page.
#
# </div>

# %% tags=["exakit-guide", "skip-ci"]
import exakit.guide as guide

guide.explore()

# %% [markdown] tags=["exakit-code-start"]
# # The code behind this page
#
# <div class="guide-code-start"></div>
#
# The same steps as the cards above, as cells you can read, change and run one by one. **Code**, at the top right of a card, opens this section; **Guided** closes it again.

# %% [markdown]
# ## Understand, prepare, explore, model, validate
#
# **Dataset:** the tables chosen in the quickstart (else the one approved last, else `amazon_sales`). Set `DATASET` for `fraud_transactions` or your own file.
#
# ![Steps 2 Understand, 3 Prepare, 4 Explore, 5 Model and 6 Validate . All steps: Access, Understand, Prepare, Explore, Model, Validate, Ask with AI, Share, Hand off](journey:2,3,4,5,6)
#
# Each query is built from the approved column map, so no cell names a column. If the data has no date or no text, the step that needs it skips and says why. Settings are in the first cell. The AI model has its own cell. The AI step at the end is optional and off.

# %% [markdown]
# | Setting | What it does |
# |---|---|
# | `DATASET` | `None`: the tables chosen in the quickstart; or `"fraud_transactions"`, or a file of your own |
# | `USE_AI_THEMES` | `True`: your AI model sorts the texts into themes |
# | `USE_JOINED`, `USE_PREPARED` | `True`: create the joined or the cleaned view proposed under Prepare, and explore that |
# | `JOINED_SQL`, `CLEANING_SQL` | your own version of that view: the CREATE VIEW printed under Prepare, edited |
# | `PLACEHOLDER_VALUES` | values that mean "not known"; `word*` matches anything starting with the word |
# | `RARE_TARGET` | a target in fewer rows than this share is rare: judge a model by ROC AUC |
# | `DATE_FORMATS`, `TIMESTAMP_FORMATS` | how a date written as text is read |
# | `DROP_COPIES`, `CAST_TYPES` | the cleaned view drops copied rows, and gives text columns of numbers or dates their type |
# | `GIVES_IT_AWAY` | a value whose target rate is this or more (or one minus this or less) decides the target |

# %%
DATASET = None
USE_AI_THEMES = False
USE_JOINED = False
USE_PREPARED = False
JOINED_SQL = None
CLEANING_SQL = None
PLACEHOLDER_VALUES = ["unknown*", "invalid*", "n/a", "na", "none", "null", "nil", "missing", "not available",
                      "not known", "not set", "undefined", "-", "?", "tbd", "#n/a"]
RARE_TARGET = 0.10
DATE_FORMATS = ["YYYY-MM-DD", "DD-MM-YYYY", "DD.MM.YYYY", "MM/DD/YYYY", "DD/MM/YYYY"]
TIMESTAMP_FORMATS = ["YYYY-MM-DD HH24:MI:SS", "YYYY-MM-DD HH24:MI"]
DROP_COPIES = True
CAST_TYPES = True
GIVES_IT_AWAY = 0.99

# %% [markdown]
# ## Optional · Your AI model and Langfuse
#
# Only the AI step at the end needs this.
#
# - **In the cell:** `MODEL_ID`, `PROVIDER_BASE_URL` (any Chat Completions endpoint, listed in `MODEL-PROVIDERS.md`) and `LANGFUSE_BASE_URL` (where calls are traced).
# - **Not in the cell:** the API key and the two Langfuse keys. A hidden box asks for them. They stay in this kernel only.
# - **Not sure what to set?** Run `nb.model_setup()`. It asks for anything missing, with the keys in a hidden box, and prints the terminal lines that set them for every notebook.

# %% [markdown]
# `MODEL_ID`, for example `"claude-opus-5-5"`; `PROVIDER_BASE_URL`, any Chat Completions address; `LANGFUSE_BASE_URL`, where the calls are traced. Empty: no model.

# %%
import exakit.nb as nb

MODEL_ID = ""
PROVIDER_BASE_URL = ""
LANGFUSE_BASE_URL = ""
nb.use_model(MODEL_ID, PROVIDER_BASE_URL, LANGFUSE_BASE_URL)

# %% [markdown]
# ## Step 2 · Understand the data
#
# The tables chosen in the quickstart, opened again here. For each you approve the column map: the key, the date, the groups and the outcome. The kit proposes it and shows the least certain columns first. Approving it publishes the table in **Exasol Semantic Views**, the database's semantic layer, and the model over all your tables is built from the same choices. Every later step reads this map, so the same notebooks run on any table.

# %%
import os
import exakit.nb as nb

workflow_id = nb.continue_workflow("explore")
connection = nb.connect()
chosen_tables = nb.open_chosen(connection)
if DATASET or not chosen_tables:
    chosen_data = nb.chosen_dataset(DATASET)
else:
    chosen_data = next(iter(chosen_tables.values()))

# %% [include] ../00_shared/data_paths.py review


# %% [markdown]
# ### Approve every table at once
#
# With several tables chosen - six tables of one source, say - you do not have to approve them one by one. `nb.schema_review` says what to look at across all of them: the columns the kit guessed at, and the ones it marked personal data. `nb.approve_all` then approves every table as drafted, with the columns you change in `ALL_CHOICES`, and updates the semantic model once per source instead of once per table. What to predict is not set here: it stays each table's own choice.

# %%
APPROVE_ALL = False
ALL_CHOICES = None
if APPROVE_ALL and chosen_tables:
    role_reviews = {table: nb.review_roles(connection, data) for table, data in chosen_tables.items()}
    schema_summary = nb.schema_review(role_reviews)
    print(f"{len(schema_summary['check'])} columns to look at, {len(schema_summary['sensitive'])} marked personal data, "
          f"{schema_summary['fine']} look fine.")
    approved_all = nb.approve_all(role_reviews, ALL_CHOICES)
    dataset = approved_all[str(chosen_data.fact_table)]

# %% [markdown]
# ### Add another source
#
# Fusion: data from several places in one model. Every source connected with `exakit connect` (S3, Snowflake, MongoDB, PostgreSQL and the rest) is listed here, read live where it lives. Name a table of one in `ADD_SOURCE` to add it to the tables above; the card's **Add a source or table** does the same and connects a new source too.

# %%
sources = nb.sources()
ADD_SOURCE = ""
if ADD_SOURCE:
    source_data = nb.load_source(connection, ADD_SOURCE)
    chosen_tables[str(source_data.fact_table)] = source_data
    remembered = nb.remember_chosen(chosen_tables)
print("Sources: " + (", ".join(f"{s['schema']} ({s.get('connector_name') or s.get('connector')})" for s in sources) or "none connected yet"))

# %% [markdown]
# ### A first result
#
# Rows per group, and the % where the target is 1 when the map has a target. Each query shows its SQL before the result.

# %%
missing_roles = {missing["role"]: missing["reason"] for missing in dataset.missing}
GROUP_ROLE, GROUP_COLUMN = dataset.group_by()
if GROUP_ROLE != "category":
    print(f"No category ({missing_roles.get('category', 'none approved')}): rows are counted per {GROUP_ROLE} instead.")
if "label" in missing_roles:
    print(f"No target ({missing_roles['label']}): the target rate is left out. Later steps that need it say so.")
GROUP_HEADER, COUNT_HEADER = nb.name(GROUP_COLUMN), nb.count_name(dataset)
LABEL_PCT_HEADER = nb.name(dataset.col("label"), "PCT") if dataset.has("label") and GROUP_ROLE != "label" else None
LABEL_RATE_SQL = f",\n       ROUND(100 * AVG({dataset.col('label')}), 1) AS {LABEL_PCT_HEADER}" if LABEL_PCT_HEADER else ""
first_rows = nb.sql(connection, f"""
SELECT {GROUP_COLUMN} AS {GROUP_HEADER},
       COUNT(*) AS {COUNT_HEADER}{LABEL_RATE_SQL}
FROM {dataset.fact_table}
GROUP BY {GROUP_COLUMN}
ORDER BY {COUNT_HEADER} DESC
LIMIT 10""")
nb.show_sql()
overall_rate = nb.sql(connection, f"SELECT COUNT(*) AS N, ROUND(100 * AVG({dataset.col('label')}), 1) AS PCT FROM {dataset.fact_table}") if LABEL_PCT_HEADER else None
nb.note_groups(first_rows, dataset, GROUP_HEADER, COUNT_HEADER, LABEL_PCT_HEADER, overall=(overall_rate["N"][0], overall_rate["PCT"][0]) if LABEL_PCT_HEADER else None)
first_rows

# %%
loaded_dataset = role_review.dataset(draft_ok=True)

# %% [markdown]
# ## Step 3 · Prepare the data
#
# Three checks: is the data clean, does it link to other tables, are the column types correct. They only propose. The table never changes. A view is created only when you set it in the first cell.

# %% [markdown]
# ### Is the data clean?
#
# Finds repeated IDs, empty cells, placeholders such as "Unknown" and a rare target, and says what each does to a result. It changes nothing. What counts as a placeholder and when a target is rare are `PLACEHOLDER_VALUES` and `RARE_TARGET` in the first cell. `fraud_transactions` has all of them.

# %%
findings = nb.data_checks(connection, loaded_dataset, placeholder_values=PLACEHOLDER_VALUES, rare=RARE_TARGET)
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
# The joined view combines this table with every linked table. Read the joins and the SQL. To change the SQL, copy it into `JOINED_SQL` in the first cell and edit it there. To use it, set `USE_JOINED = True` in the first cell and run the cells below again (Marimo reruns them for you). The view goes into `EXAKIT_PREPARED`, and the steps below read it.

# %%
joined_view_proposal = schema_map.joined_view(loaded_dataset)
joined_dataset = (joined_view_proposal.create(connection, sql=JOINED_SQL) if USE_JOINED and joined_view_proposal.needed
                  else loaded_dataset)
joined_view_proposal

# %% [markdown]
# ### A typed, cleaned view
#
# Proposes a view with correct types (numbers, dates), blanks and placeholders as NULL, and exact copies removed. The table never changes.
#
# Read what changes. The rules are in the first cell (`PLACEHOLDER_VALUES`, `DATE_FORMATS`, `DROP_COPIES`, `CAST_TYPES`): change one and run this cell again. To change the SQL itself, copy it into `CLEANING_SQL` in the first cell and edit it there. To use it, set `USE_PREPARED = True` in the first cell and run the cells below again (Marimo reruns them for you). The view goes into `EXAKIT_PREPARED`, and the steps below read it.

# %%
typed_view_proposal = nb.typed_view(connection, joined_dataset, placeholder_values=PLACEHOLDER_VALUES, date_formats=DATE_FORMATS,
                                    timestamp_formats=TIMESTAMP_FORMATS, drop_copies=DROP_COPIES, cast_types=CAST_TYPES)
dataset = (typed_view_proposal.create(connection, sql=CLEANING_SQL)
           if USE_PREPARED and (typed_view_proposal.needed or CLEANING_SQL) else joined_dataset)
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
DATE_COLUMN = dataset.col("date") if dataset.has("date") else None
LABEL_COLUMN = dataset.col("label") if dataset.has("label") else None
missing_roles = {missing["role"]: missing["reason"] for missing in dataset.missing if not dataset.has(missing["role"])}
SHOWN = {"date": "time", "label": "target"}
missing_line = "; ".join(f"no {SHOWN.get(role, role)}: {reason}" for role, reason in missing_roles.items())
for role in ("entity", "category", "date", "label", "text"):
    if role in missing_roles:
        print(f"No {SHOWN.get(role, role)} ({missing_roles[role]}): steps that need it explain why they skip below.")

# %% [markdown]
# ### Compare groups
#
# The 10 largest entities by category: the row count and the % where the target is 1.

# %%
landscape = landscape_grid = None
COUNT_HEADER = nb.count_name(dataset)
ENTITY_HEADER = nb.name(ENTITY_COLUMN) if ENTITY_COLUMN else None
CATEGORY_HEADER = nb.name(CATEGORY_COLUMN) if CATEGORY_COLUMN else None
LABEL_PCT_HEADER = nb.name(LABEL_COLUMN, "PCT") if LABEL_COLUMN else None
if not all(dataset.has(role) for role in ("entity", "category", "label")):
    print(f"Skipped - the landscape needs an entity, a category and a target ({missing_line}).")
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
# ### Compare by a group of a linked table
#
# When this table links to another table (the links you saved in step 2), its rows can be compared by a group kept there, such as orders by the customer's segment. `nb.linked_groups` lists those groups, each with the table and system it comes from. With no saved link the list is empty and this cell does nothing.

# %%
linked = nb.linked_groups(dataset)
LINKED_GROUP = linked[0] if linked else None
groups = None
if LINKED_GROUP:
    GROUP_HEADER = nb.name(LINKED_GROUP["column"])
    groups = nb.sql(connection, f"""
SELECT b."{LINKED_GROUP['column']}" AS {GROUP_HEADER},
       COUNT(*) AS {COUNT_HEADER}
FROM {dataset.fact_table} a
JOIN {LINKED_GROUP['table']} b ON a."{LINKED_GROUP['link_column']}" = b."{LINKED_GROUP['key']}"
GROUP BY 1
ORDER BY 2 DESC
LIMIT 15""")
    nb.show_sql()
print("\n".join(g["label"] for g in linked) or "No linked table with a group.")
groups

# %% [markdown]
# ### Over time
#
# Rows per day, month or year, and the % where the target is 1. Needs a time and a target.

# %%
over_time = None
if not (dataset.has("date") and dataset.has("label")):
    print(f"Skipped - rows and target rate per period need a time and a target ({missing_line}).")
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
# Trains a small model on this computer to predict the target. First, it removes the columns that give the answer away.

# %% [markdown]
# ### Remove columns that give the answer away
#
# A column written after the outcome (an order's status after cancellation) predicts the target perfectly on old rows and fails on new rows. This cell flags those columns. The model does not use them.

# %%
LEAKING_COLUMNS = nb.leakage_check(connection, dataset, pure=GIVES_IT_AWAY)

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
USE_CATEGORY = dataset.has("category") and CATEGORY_COLUMN.strip('"') not in LEAKING_COLUMNS
USE_ENTITY = dataset.has("entity") and ENTITY_COLUMN.strip('"') not in LEAKING_COLUMNS
CATEGORY_FEATURE = f"CAST({dataset.col('category')} AS VARCHAR(2000)) AS CATEGORY_,\n       " if USE_CATEGORY else ""
ENTITY_FEATURE = f"CAST({dataset.col('entity')} AS VARCHAR(2000)) AS ENTITY_,\n       " if USE_ENTITY else ""
MONTH_FEATURE = f"EXTRACT(MONTH FROM {dataset.col('date')}) AS MONTH_,\n       " if dataset.has("date") else ""
KEY_COLUMN = dataset.descriptor.slots.get("key")
ROW_ORDER = f"{dataset.col('date')} DESC" if dataset.has("date") else (f'"{KEY_COLUMN}"' if KEY_COLUMN else "1")

model = None
if not (dataset.has("label") and (USE_CATEGORY or USE_ENTITY)):
    print(f"Skipped - the small model predicts the target from the category and entity, so it needs a target and a "
          f"category or entity that does not give the target away ({missing_line or 'see the cell above'}).")
else:
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

    CLUES_PER_SIDE = min(8, len(feature_names) // 2)
    print(f"Make {LABEL_COLUMN} = 1 more likely:", ", ".join(describe_feature(feature_name) for feature_name in feature_names[weight_order[-CLUES_PER_SIDE:]][::-1]))
    print(f"Make {LABEL_COLUMN} = 1 less likely:", ", ".join(describe_feature(feature_name) for feature_name in feature_names[weight_order[:CLUES_PER_SIDE]]))

# %% [markdown]
# ### The model lab (optional)
#
# What the **Build a model** card runs: one task - predict yes or no, predict a number, find natural groups or find unusual rows - with every model of that task trained on the same split ("all"), or one model you name. Columns that give the answer away and personal data are left out. Then feature ideas, each tried on the same split before it is kept.

# %% tags=["skip-ci"]
LAB_TASK = "predict_yes_no"
lab_data = nb.lab_data(connection, dataset)
kept_features = {}
lab = nb.model_lab(connection, dataset, LAB_TASK, model="all", target_number=None, data=lab_data, features=kept_features)
print(lab.note or lab)
lab.board if LAB_TASK in ("predict_yes_no", "predict_number") else lab.result

# %% tags=["skip-ci"]
ideas = nb.feature_ideas(lab, ai=False, conn=connection)
for index, idea in enumerate(ideas[:3] if LAB_TASK in ("predict_yes_no", "predict_number") else []):
    tried = nb.try_feature(lab, ideas[index])
    print(f"{idea.title}: {tried['text']}")
    if tried["verdict"] == "helps":
        kept_features[ideas[index].id] = tried["series"]
    else:
        kept_features.pop(ideas[index].id, None)
kept_features

# %% [markdown]
# ## Optional · Themes in the texts where the target is 1 (AI)
#
# Needs a text column. The practice datasets have none, so this step skips.
#
# Your model groups the newest texts where the target is 1 and where it is 0 into themes. A theme on one side only is a lead.
#
# To turn it on, fill in the model cell above and run it. Then set `USE_AI_THEMES = True` in the first cell. It makes two model calls. A live source asks before it sends anything. With `LANGFUSE_BASE_URL` set, both calls go into one trace, `explore-themes`.

# %%
SAMPLE_TEXTS = 20
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
# Note one finding to check. Then open `02_ask_your_data` and ask a question in plain English. For other data, change `DATASET` and run again.

