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

    **Dataset:** `amazon_sales` by default; change `DATASET` for `walmart_sales` or your own file. **How long:** about two minutes.

    Compare groups and follow outcomes over time, then fit a small local model from the category, entity and month and see which values it leans on. With a text column, your own model can also say what the texts are about: `amazon_sales` and `walmart_sales` have no text column, so that step skips and says why.

    Optional, for data with a text column: `USE_AI_THEMES = True` lets your model say what the label-1 texts are about, traced to Langfuse when it is set up.
    """)
    return


@app.cell
def _():
    DATASET = None   # None: the dataset approved last in a quickstart (else amazon_sales); or "walmart_sales", or your own file ("~/my-data/transactions.csv", roles beside it)
    USE_AI_THEMES = False  # True: your model sorts the texts into themes (needs a text column and EXAKIT_MODEL_ID; see the AI step below)
    WORKFLOW_ID = None  # paste the quickstart's wf-... id to continue its log
    return DATASET, USE_AI_THEMES, WORKFLOW_ID


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
def _(DATASET, WORKFLOW_ID):
    import os
    import exakit.nb as nb
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
    skipped = {m['role']: m['reason'] for m in ds.missing if not ds.has(m['role'])}  # a role no column fits is None here, never guessed
    missing_line = '; '.join((f'no {role} role: {reason}' for role, reason in skipped.items()))
    for role in ('entity', 'category', 'date', 'label', 'text'):
        if role in skipped:
            print(f'No {role} role ({skipped[role]}): steps that need it explain why they skip below.')
    return CATEGORY, DATE, ENTITY, LABEL, TEXT, conn, ds, missing_line, nb


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
    ## Small baseline model

    > **What is a baseline model?** The simplest model worth trying, to see how much the data can tell at all.
    > It learns from most rows and is graded on rows it never saw, like a test with new questions.
    > If it is barely better than guessing, a bigger model is unlikely to rescue the idea.

    A small model learns to tell label 1 from label 0 from three things every row has: its category, its entity and the month of its date (in `amazon_sales`: the product category, the state it shipped to and the month; in `walmart_sales`: the store and the month). It uses up to 20,000 recent rows, is checked on a quarter it has not seen, and the note says how good it is in plain words. It needs a date, a label and a category or entity.

    Technical: one-hot category, entity and month, logistic regression; the score is ROC AUC (0.5 = guessing).
    """)
    return


@app.cell
def _(CATEGORY, DATE, ENTITY, LABEL, conn, ds, missing_line, nb):
    SAMPLE = 20000
    # The features the model reads, each only when its role exists: the category and the entity as text, then the month.
    CATEGORY_FEATURE = f"CAST({ds.col('category')} AS VARCHAR(2000)) AS CATEGORY_,\n       " if ds.has("category") else ""
    ENTITY_FEATURE = f"CAST({ds.col('entity')} AS VARCHAR(2000)) AS ENTITY_,\n       " if ds.has("entity") else ""

    model = None
    if not (ds.has("date") and ds.has("label") and (ds.has("category") or ds.has("entity"))):
        print(f"Skipped - the small model predicts the label from the category, entity and month of the newest {SAMPLE} rows, "
              f"which needs a date, a label and a category or entity role ({missing_line}).")
    else:
        # What each feature is called on screen: the column it comes from, or "month".
        READABLE = {"MONTH_": "month", "CATEGORY_": (CATEGORY or "").strip('"'), "ENTITY_": (ENTITY or "").strip('"')}
        rows = nb.sql(conn, f"""
    SELECT {CATEGORY_FEATURE}{ENTITY_FEATURE}EXTRACT(MONTH FROM {DATE}) AS MONTH_,
           {LABEL} AS LABEL_
    FROM {ds.fact_table}
    WHERE {LABEL} IS NOT NULL
    ORDER BY {DATE} DESC
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

        print(f"Make {LABEL} = 1 more likely:", ", ".join(said(n) for n in names[order[-8:]][::-1]))
        print(f"Make {LABEL} = 1 less likely:", ", ".join(said(n) for n in names[order[:8]]))
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Optional: what the label-1 texts are about

    Needs a text column: on `amazon_sales` and `walmart_sales` it skips and says why. Your model reads the newest texts on each side of the label (label `= 1` and `= 0`) and sorts each side into a few themes. A theme found on one side only is the clue. The note under the result says how to read it.

    To switch it on: set `EXAKIT_MODEL_ID`, `EXAKIT_PROVIDER_BASE_URL` and `EXAKIT_PROVIDER_API_KEY` before `exakit notebook`, then `USE_AI_THEMES = True` in the first cell. Two model calls, a few cents. A live source asks before anything is sent.

    With `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` and `LANGFUSE_BASE_URL` set too, both calls are one trace, `explore-themes`, with what was sent, the answer, tokens, cost, time and two scores (`valid_json`, `texts_placed`): run it with another model and compare the two traces.

    **JupyterLab already running?** It only reads these settings when it starts: an `export` in another terminal, or a kernel restart, does not reach it (and `exakit.env` refuses keys on purpose). In a terminal, save your notebooks, then:

    ```bash
    read -rsp "API key: " EXAKIT_PROVIDER_API_KEY; echo
    export EXAKIT_MODEL_ID=claude-opus-5-5 EXAKIT_PROVIDER_BASE_URL=https://api.anthropic.com/v1/ EXAKIT_PROVIDER_API_KEY
    exakit notebook stop && exakit notebook
    ```

    The Langfuse keys go the same way (`read -rsp` for the two keys, `LANGFUSE_BASE_URL` in the `export`). They last until that JupyterLab stops.
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
