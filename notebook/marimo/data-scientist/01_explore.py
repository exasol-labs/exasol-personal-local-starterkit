import marimo

__generated_with = "0.25.2"
app = marimo.App()


@app.cell
def _():
    import marimo as mo

    return (mo,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    # Explore

    **Dataset:** the one you approved last (else `amazon_sales`); change `DATASET` for `walmart_sales`, `fraud_transactions` or your own file. **How long:** about two minutes.

    Check the data is clean, compare groups and follow outcomes over time, check no column gives the answer away, then fit a small local model from the category, entity and (when there is a date) the month, and see which values it leans on. Every query is built from the dataset's approved column map, so nothing here names a column: change `DATASET` and every cell follows. A step whose role the data does not have (no date in `fraud_transactions`, no text in any of the three) skips and says why.

    Optional, for data with a text column: `USE_AI_THEMES = True` lets your model say what the label-1 texts are about, traced to Langfuse when it is set up.
    """)
    return


@app.cell
def _():
    DATASET = None   # None: the dataset approved last in a quickstart (else amazon_sales); or "walmart_sales", "fraud_transactions", or your own file ("~/my-data/transactions.csv", roles beside it)
    USE_AI_THEMES = False  # True: your model sorts the texts into themes (needs a text column and EXAKIT_MODEL_ID; see the AI step below)
    WORKFLOW_ID = None  # paste the quickstart's wf-... id to continue its log
    return DATASET, USE_AI_THEMES, WORKFLOW_ID


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Optional: your model and Langfuse

    > **What is this?** Where you tell the notebook which AI model to use, and where to record its calls (Langfuse: what was sent, the answer, the cost).
    > We set it here so you need no terminal: fill in the plain values and run the cell; the keys are asked for in a hidden box.
    > The keys stay in this notebook's kernel only - never in this file - and are gone when it stops. Left empty, the cell changes nothing.
    """)
    return


@app.cell
def _():
    import exakit.nb as nb

    MODEL_ID = ""           # e.g. "claude-opus-5-5"; empty: no model (or the one set before `exakit notebook`)
    PROVIDER_BASE_URL = ""  # e.g. "https://api.anthropic.com/v1/" - any Chat Completions endpoint (MODEL-PROVIDERS.md lists more)
    LANGFUSE_BASE_URL = ""  # e.g. "https://cloud.langfuse.com"; empty: the model calls are not traced
    nb.use_model(MODEL_ID, PROVIDER_BASE_URL, LANGFUSE_BASE_URL)
    return (nb,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Load the column map

    > **The column map (descriptor), again:** it says which column is the key, the time, the groups and the outcome (label).
    > Every query below is built from it, so the same notebook runs on any dataset whose map you approved.

    `DATASET` is a sample ID or a file path with its descriptor beside it. A draft map is enough here.

    Everything you set is in the first cell: run it, then this one. Steps whose roles are missing skip and say why.
    """)
    return


@app.cell
def _(DATASET, WORKFLOW_ID, nb):
    import os
    wid = nb.workflow('explore', resume=WORKFLOW_ID or os.environ.get('EXAKIT_WORKFLOW_ID'))
    conn = nb.connect()
    DATASET_1 = nb.chosen_dataset(DATASET)
    ds = nb.review_roles(conn, DATASET_1).dataset(draft_ok=True)
    nb.show_roles(ds)
    ENTITY = ds.col('entity') if ds.has('entity') else None
    CATEGORY = ds.col('category') if ds.has('category') else None
    TEXT = ds.text_sql() if ds.has('text') else None
    DATE = ds.col('date') if ds.has('date') else None
    LABEL = ds.col('label') if ds.has('label') else None
    skipped = {m['role']: m['reason'] for m in ds.missing if not ds.has(m['role'])}
    missing_line = '; '.join((f'no {role} role: {reason}' for role, reason in skipped.items()))  # a role no column fits is None here, never guessed
    for role in ('entity', 'category', 'date', 'label', 'text'):
        if role in skipped:
            print(f'No {role} role ({skipped[role]}): steps that need it explain why they skip below.')
    return CATEGORY, DATE, ENTITY, LABEL, TEXT, conn, ds, missing_line


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Prepare: is the data clean?

    > **Why check first?** A rate or a model is only as good as the rows under it. Repeated ids count twice, empty cells
    > drop out of averages, a value like "Unknown" poses as a category, and a rare label makes a lazy model look accurate.
    > This cell finds each of those from the column map, says what it does to a result, and changes nothing.

    Read each line before trusting a number below. `fraud_transactions` is messy on purpose: it has all of them.
    """)
    return


@app.cell
def _(conn, ds, nb):
    findings = nb.data_checks(conn, ds)
    findings
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Compare groups

    The 10 biggest entities, split by category: how many rows each has and, for each, the % where the label is 1. The note under the result says what it means.
    """)
    return


@app.cell
def _(CATEGORY, ENTITY, LABEL, conn, ds, missing_line, nb):
    landscape = pivot = None
    # Result columns are named after the data (SHIP_STATE, ORDER_LINES, CANCELLED_PCT); a note under each result says
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
    return COUNT, PCT, pivot


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    The same counts as a grid: one row per entity, one column per category, each cell the number of rows.
    """)
    return


@app.cell
def _(pivot):
    pivot
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Over time

    How many rows per day, month or year (picked from the date span), and the % where the label is 1. Needs date and label roles. The note under the result says what it means.
    """)
    return


@app.cell
def _(COUNT, DATE, LABEL, PCT, conn, ds, missing_line, nb):
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
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Validate: does a column give the answer away?

    > **What is leakage?** A column written after the outcome - an order's status once it was cancelled - predicts the
    > label perfectly and makes any model look brilliant, then fails on new rows where it is not known yet.
    > This cell flags every column whose values (almost) decide the label on their own; the model below leaves them out.
    """)
    return


@app.cell
def _(conn, ds, nb):
    LEAKED = nb.leakage_check(conn, ds)
    return (LEAKED,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Small baseline model

    > **What is a baseline model?** The simplest model worth trying, to see how much the data can tell at all.
    > It learns from most rows and is graded on rows it never saw, like a test with new questions.
    > If it is barely better than guessing, a bigger model is unlikely to rescue the idea.

    A small model learns to tell label 1 from label 0 from what the column map names: the category, the entity and, when the data has a date, its month (a column the cell above flagged is left out). With a date it uses the newest 20,000 rows; without one, the first 20,000 by the key, so a rerun reads the same rows. It is checked on a quarter it has not seen, and the note says how good it is in plain words. It needs a label and a category or entity.

    Technical: one-hot features, logistic regression with balanced class weights, a stratified split with a fixed seed; the score is ROC AUC (0.5 = guessing).
    """)
    return


@app.cell
def _(CATEGORY, DATE, ENTITY, LABEL, LEAKED, conn, ds, missing_line, nb):
    SAMPLE = 20000
    # The features the model reads, each only when its role exists and does not give the label away: the category and the
    # entity as text, then the month of the date.
    USE_CATEGORY = ds.has("category") and CATEGORY.strip('"') not in LEAKED
    USE_ENTITY = ds.has("entity") and ENTITY.strip('"') not in LEAKED
    CATEGORY_FEATURE = f"CAST({ds.col('category')} AS VARCHAR(2000)) AS CATEGORY_,\n       " if USE_CATEGORY else ""
    ENTITY_FEATURE = f"CAST({ds.col('entity')} AS VARCHAR(2000)) AS ENTITY_,\n       " if USE_ENTITY else ""
    MONTH_FEATURE = f"EXTRACT(MONTH FROM {ds.col('date')}) AS MONTH_,\n       " if ds.has("date") else ""
    # Which rows: the newest by date, else the first by the key - the same rows on every rerun either way.
    KEY = ds.descriptor.slots.get("key")
    ORDER = f"{ds.col('date')} DESC" if ds.has("date") else (f'"{KEY}"' if KEY else "1")

    model = None
    if not (ds.has("label") and (USE_CATEGORY or USE_ENTITY)):
        print(f"Skipped - the small model predicts the label from the category and entity, which needs a label and a "
              f"category or entity role that does not give the label away ({missing_line or 'see the cell above'}).")
    else:
        # What each feature is called on screen: the column it comes from, or "month".
        READABLE = {"MONTH_": "month", "CATEGORY_": (CATEGORY or "").strip('"'), "ENTITY_": (ENTITY or "").strip('"')}
        if not DATE:
            print("No date: the model reads the first rows by the key and leaves the month out.")
        rows = nb.sql(conn, f"""
    SELECT {CATEGORY_FEATURE}{ENTITY_FEATURE}{MONTH_FEATURE}{LABEL} AS LABEL_
    FROM {ds.fact_table}
    WHERE {LABEL} IS NOT NULL
    ORDER BY {ORDER}
    LIMIT {SAMPLE}""")
        nb.show_sql()

        from sklearn.linear_model import LogisticRegression
        from sklearn.metrics import roc_auc_score
        from sklearn.model_selection import train_test_split
        from sklearn.pipeline import Pipeline
        from sklearn.preprocessing import OneHotEncoder

        features = [name for name in ("CATEGORY_", "ENTITY_", "MONTH_") if name in rows.columns]
        X, y = rows[features].fillna("(none)").astype(str), rows["LABEL_"].astype(int)
        X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.25, random_state=0, stratify=y)
        model = Pipeline([
            ("onehot", OneHotEncoder(handle_unknown="ignore")),
            ("classifier", LogisticRegression(max_iter=1000, class_weight="balanced")),
        ])
        model.fit(X_train, y_train)
        auc = roc_auc_score(y_test, model.predict_proba(X_test)[:, 1])
        print(f"ROC AUC on the held-out quarter: {auc:.3f}")
        nb.note_model(auc, ds, len(rows), y.mean())
    return READABLE, features, model


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Model clues

    Runs only when the model above ran. The values the model leans on most, each way: a category, an entity or a month. They are clues, not proof: a value with few rows can look strong by chance.
    """)
    return


@app.cell
def _(LABEL, READABLE, features, model):
    import numpy as np

    if model is not None:
        names = model.named_steps["onehot"].get_feature_names_out(features)
        weights = model.named_steps["classifier"].coef_[0]
        order = np.argsort(weights)

        def said(name):
            feature, value = name.split("_", 1)[0] + "_", name.split("__", 1)[1]
            return f"{READABLE[feature]} = {value}"

        TOP = min(8, len(names) // 2)        # each side its own values: few values are split, never shown twice
        print(f"Make {LABEL} = 1 more likely:", ", ".join(said(n) for n in names[order[-TOP:]][::-1]))
        print(f"Make {LABEL} = 1 less likely:", ", ".join(said(n) for n in names[order[:TOP]]))
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Optional: what the label-1 texts are about

    Needs a text column: on the three sample datasets (`amazon_sales`, `walmart_sales`, `fraud_transactions`) it skips and says why. Your model reads the newest texts on each side of the label (label `= 1` and `= 0`) and sorts each side into a few themes. A theme found on one side only is the clue. The note under the result says how to read it.

    To switch it on: fill in the model cell at the top (*Optional: your model and Langfuse*) and run it, then `USE_AI_THEMES = True` in the first cell. Two model calls, a few cents. A live source asks before anything is sent.

    With `LANGFUSE_BASE_URL` filled in there too, both calls are one trace, `explore-themes`, with what was sent, the answer, tokens, cost, time and two scores (`valid_json`, `texts_placed`): run it with another model and compare the two traces.

    Rather set them for every notebook? Export `EXAKIT_MODEL_ID`, `EXAKIT_PROVIDER_BASE_URL`, `EXAKIT_PROVIDER_API_KEY` and the `LANGFUSE_*` keys in the terminal before `exakit notebook` (the README in the notebooks folder shows how).
    """)
    return


@app.cell
def _(LABEL, TEXT, USE_AI_THEMES, conn, ds, missing_line, nb):
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
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Decide what to test next

    Keep one finding worth validating. To rerun on other data, change `DATASET`.
    """)
    return


if __name__ == "__main__":
    app.run()
