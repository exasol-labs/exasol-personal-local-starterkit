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

    **Dataset:** `esophageal_posts` by default; change `DATASET` for `banking_complaints` or your own file. **How long:** about two minutes.

    Compare groups, follow outcomes over time, fit a small local model, then write a handoff for the ML Engineer.

    Optional: `USE_AI_THEMES = True` adds LLM text themes (needs a model endpoint).
    """)
    return


@app.cell
def _():
    DATASET = "esophageal_posts"   # or "banking_complaints", or your own file ("~/my-data/transactions.csv", roles beside it)
    USE_AI_THEMES = False  # optional LLM summaries; configure your endpoint before enabling
    return DATASET, USE_AI_THEMES


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Load the column map

    `DATASET` is a sample ID or a file path with its descriptor beside it. A draft map is enough here; the handoff needs an approved one.

    Set `WORKFLOW_ID` to the quickstart's ID to keep one log. Steps whose roles are missing skip and say why.
    """)
    return


@app.cell
def _(DATASET):
    import os
    import exakit.nb as nb

    WORKFLOW_ID = None  # paste the quickstart's wf-... id to continue its log
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
    return CATEGORY, DATE, ENTITY, LABEL, TEXT, conn, ds, missing_line, nb


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Compare groups

    Top 10 entities, split by category. `N` = rows, `LABEL_1_PCT` = % with label 1. Descriptive, not causal.
    """)
    return


@app.cell
def _(CATEGORY, ENTITY, LABEL, conn, ds, missing_line, nb):
    landscape = pivot = None
    if not all(ds.has(role) for role in ("entity", "category", "label")):
        print(f"Skipped - the landscape needs entity, category and label roles ({missing_line}).")
    else:
        landscape = nb.sql(conn, f"""
    WITH TOP_ENTITIES AS (
        SELECT {ENTITY} AS ENTITY, COUNT(*) AS N_ROWS
        FROM {ds.fact_table}
        GROUP BY {ENTITY}
        ORDER BY N_ROWS DESC
        LIMIT 10)
    SELECT T.ENTITY,
           F.{CATEGORY} AS CATEGORY,
           COUNT(*) AS N,
           ROUND(100 * AVG(F.{LABEL}), 1) AS LABEL_1_PCT
    FROM {ds.fact_table} F
    JOIN TOP_ENTITIES T ON F.{ENTITY} = T.ENTITY
    GROUP BY T.ENTITY, F.{CATEGORY}
    ORDER BY T.ENTITY, N DESC""")
        nb.show_sql()
        pivot = landscape.pivot_table(index="ENTITY", columns="CATEGORY", values="N", fill_value=0, aggfunc="sum")
    landscape
    return (pivot,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    The same counts, one column per category.
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

    Rows and label rate per day, month or year (picked from the date span). Needs date and label roles.
    """)
    return


@app.cell
def _(DATE, LABEL, conn, ds, missing_line, nb):
    over_time = None
    if not (ds.has("date") and ds.has("label")):
        print(f"Skipped - rows and label rate per period need the date and label roles ({missing_line}).")
    else:
        span = nb.sql(conn, f"SELECT DAYS_BETWEEN(MAX({DATE}), MIN({DATE})) AS DAYS FROM {ds.fact_table}")
        days = int(span["DAYS"][0] or 0)
        period = "DAY" if days <= 62 else "MONTH" if days <= 3 * 366 else "YEAR"

        over_time = nb.sql(conn, f"""
    SELECT CAST(DATE_TRUNC('{period}', {DATE}) AS DATE) AS PERIOD,
           COUNT(*) AS N,
           ROUND(100 * AVG({LABEL}), 1) AS LABEL_1_PCT
    FROM {ds.fact_table}
    GROUP BY 1
    ORDER BY 1""")
        nb.show_sql()
    over_time
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Small baseline model

    TF-IDF text + one-hot category, logistic regression, on up to 20,000 recent labelled rows; a quarter held out. ROC AUC 0.5 = guessing.
    """)
    return


@app.cell
def _(CATEGORY, DATE, ENTITY, LABEL, TEXT, conn, ds, missing_line, nb):
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
        print(f"{len(rows)} rows, {y.mean():.1%} with label 1; ROC AUC on the held-out quarter: {auc:.3f} (0.5 is guessing)")
    return (model,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Model clues

    Top words pushing predictions toward 1 and toward 0. Check they are real signals, not boilerplate or leaks.
    """)
    return


@app.cell
def _(model):
    import numpy as np

    if model is not None:
        names = model.named_steps["features"].get_feature_names_out()
        weights = model.named_steps["classifier"].coef_[0]
        order = np.argsort(weights)
        print("towards 1:", ", ".join(n.split("__", 1)[1] for n in names[order[-12:]][::-1]))
        print("towards 0:", ", ".join(n.split("__", 1)[1] for n in names[order[:12]]))
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Optional: AI themes

    Set `EXAKIT_MODEL_ID`, `EXAKIT_PROVIDER_BASE_URL` and `EXAKIT_PROVIDER_API_KEY` before starting the kernel, then `USE_AI_THEMES = True`. Setup: the README in the notebooks folder.

    Sends up to five texts to your model (a live source asks first). Themes are suggestions to check.

    Optional tracing: set `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` and `LANGFUSE_BASE_URL`. Keep keys in the environment.
    """)
    return


@app.cell
def _(ENTITY, TEXT, USE_AI_THEMES, conn, ds, missing_line, nb):
    SAMPLE_TEXTS = 5
    text_sample = None
    LABEL_COL = f"{ds.col('label')} AS LABEL_, " if ds.has("label") else ""
    SAMPLE_ORDER = ", ".join([f"{ds.col(role)} DESC" for role in ("label", "date") if ds.has(role)] + ([ENTITY] if ENTITY else ([TEXT] if TEXT else [])))
    if not ds.has("text"):
        print(f"Skipped - the text sample needs a text role ({missing_line}).")
    else:
        SAMPLE_SQL = f"""
        SELECT {ENTITY or 'NULL'} AS ENTITY, {LABEL_COL}{TEXT} AS TEXT_
        FROM {ds.fact_table}
        WHERE LENGTH(TRIM({TEXT})) > 0
        ORDER BY {SAMPLE_ORDER}
        LIMIT {SAMPLE_TEXTS}"""

        text_sample = nb.sql(conn, SAMPLE_SQL)
        nb.show_sql()

        endpoint = nb.model_client() if USE_AI_THEMES else None
        if not USE_AI_THEMES:
            print("Optional AI themes are off. The SQL analysis, local model and handoff remain available.")
        if endpoint is not None and nb.confirm_send(ds, len(text_sample)):
            client, model_name = endpoint
            themes = []
            with nb.trace(conn, "explore-text-step", dataset=ds, sql=SAMPLE_SQL):
                for text in text_sample["TEXT_"]:
                    answer = client.chat.completions.create(
                        model=model_name,
                        messages=[{"role": "system", "content": "Name the theme of the text in at most five words."},
                                  {"role": "user", "content": text[:4000]}])
                    themes.append(answer.choices[0].message.content.strip())
            text_sample["THEME"] = themes
    text_sample
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Decide what to test next

    Keep one finding worth validating. To rerun on other data, change `DATASET`.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Hand off to the ML Engineer

    Writes a **handoff**: dataset, approved map version, data fingerprint, features, label and split (earliest 80% train, latest 20% test). Next: `ml-engineer/01_train.ipynb`.

    Needs an approved map with date and label roles. Without a date: `nb.write_handoff(conn, ds, split="random")`.
    """)
    return


@app.cell
def _(conn, ds, missing_line, nb):
    handoff_path = None
    if not (ds.has("date") and ds.has("label")):
        print(f"Skipped - a time-based training handoff needs date and label roles ({missing_line}). "
              "For data without a date, explicitly request nb.write_handoff(conn, ds, split='random') after approval.")
    elif ds.status != "approved":
        print("Skipped - approve the descriptor before writing a training handoff: exakit describe " + ds.id + " --approve")
    else:
        handoff_path = nb.write_handoff(conn, ds)
        handoff = nb.read_handoff(handoff_path)
        print(f"Handoff written: {handoff_path}")
        print(f"It holds descriptor {handoff['descriptor']['id']} v{handoff['descriptor']['version']}, the feature view "
              f"{handoff['feature_view']['name']} ({len(handoff['input_schema'])} features), the label "
              f"{handoff['label']['column']} (positive: {handoff['label']['positive']}) and a {handoff['split']['kind']} split; "
              "ml-engineer/01_train starts from it.")
    return


if __name__ == "__main__":
    app.run()
