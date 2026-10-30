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
    # Explore patterns, then prepare a reproducible handoff

    **Dataset:** `pharma_trials` by default; change `DATASET` for `banking_complaints` or your own described file. **How long:** about two minutes, plus time for optional model calls.

    You have agreed what the columns mean. Now investigate where outcomes are concentrated, whether they change over time and whether a small model finds useful patterns. Pharma compares sponsors and phases; Banking compares companies and products.

    **By the end:** you will have visible SQL, descriptive results, a local baseline model and a handoff the ML Engineer can reproduce. Start with the supplied code, then adapt the questions to your project.

    **Optional AI:** `USE_AI_THEMES = False` keeps the optional LLM text summaries off. The supplied scikit-learn model runs on your computer without an LLM service. Turn themes on only after configuring your model endpoint; Langfuse tracing is a further opt-in.
    """)
    return


@app.cell
def _():
    DATASET = "pharma_trials"   # or "banking_complaints", or your own file ("~/my-data/transactions.csv", roles beside it)
    USE_AI_THEMES = False  # optional LLM summaries; configure your endpoint before enabling
    return DATASET, USE_AI_THEMES


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Reuse the column map instead of rewriting every query

    Keep `DATASET = "pharma_trials"` for the first run. A sample ID opens its table; a CSV, Parquet or JSON path opens the descriptor saved beside that file. This is how the same analysis can travel between domains.

    **Do now:** review the suggested meanings and check the label still matches the outcome you want to investigate. Exploration can inspect a draft. The final training handoff, Ask and Share need an approved descriptor.

    **Technical note:** the helper validates the mapped columns against the database. An undescribed file can be loaded and profiled here; approve its map in the picker before making a handoff. Date- or label-dependent steps explain why they skip when that role is missing. Keep entity, category and text roles for the main path.

    Set `WORKFLOW_ID` to the quickstart's identifier to keep one investigation log. With no identifier, this notebook starts its own.
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

    ENTITY, CATEGORY, TEXT = ds.col("entity"), ds.col("category"), ds.text_sql()
    DATE = ds.col("date") if ds.has("date") else None      # a role no column fits is None here, never guessed
    LABEL = ds.col("label") if ds.has("label") else None
    skipped = {m["role"]: m["reason"] for m in ds.missing if m["role"] in ("date", "label")}
    missing_line = "; ".join(f"no {role} role: {reason}" for role, reason in skipped.items())
    for role, steps in (("date", "the over-time step and the small model are"),
                        ("label", "the landscape, the over-time step and the small model are")):
        if role in skipped:
            print(f"No {role} role ({skipped[role]}): {steps} skipped below; the text step needs only the text roles.")
    return CATEGORY, DATE, ENTITY, LABEL, TEXT, conn, ds, missing_line, nb


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Find the groups worth investigating

    Start with the busiest entities and their categories. For Pharma, compare trial counts and termination shares across sponsors and phases. For Banking, compare complaint counts and monetary-relief shares across companies and products.

    **Read the result:** `N` is the size of a group; `LABEL_1_PCT` is the percentage with your chosen outcome. A small group with a high percentage deserves different caution from a large group with a stable rate. This is a descriptive comparison, not a causal finding.

    **Technical note:** the query selects the ten entities with the most records, aggregates them by the category role and returns a pandas table. The SQL is printed so you can inspect how the numbers were made.
    """)
    return


@app.cell
def _(CATEGORY, ENTITY, LABEL, conn, ds, missing_line, nb):
    landscape = pivot = None
    if not ds.has("label"):
        print(f"Skipped - the landscape counts how often the label is 1, and no column plays the label role ({missing_line}).")
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
    The first table keeps counts and outcome percentages together. This second view puts each category in a column so you can compare the number of records across entities. It shows counts only; use the first table for outcome rates.
    """)
    return


@app.cell
def _(pivot):
    pivot
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Check whether the pattern changes over time

    A single total can hide changes in the mix of records. The next result follows counts and outcome rates across the approved event date. Consider whether a busy period or a different group mix could affect your earlier comparison.

    **Technical note:** the notebook chooses day, month or year periods from the date span. It needs date and label roles; without them it prints the reason for skipping this step.
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
    ## Try a modest baseline before making a bigger claim

    Can the descriptions and category help distinguish the two outcomes? The next cell fits a small text classifier on your computer. In Pharma the outcome is trial termination; in Banking it is monetary relief.

    **Read the result:** ROC AUC measures how well the model ranks the two outcomes; 0.5 is chance-level ranking. A higher score is evidence from this sample, not proof that the model is ready for a real decision or explains causes.

    **Technical note:** SQL selects up to 20,000 recent labelled rows. scikit-learn combines TF-IDF word features with a one-hot category, then fits logistic regression. A fixed, stratified random split holds out a quarter of this sample. This client demonstration uses a different split from the later time-based in-database training notebook.
    """)
    return


@app.cell
def _(CATEGORY, DATE, ENTITY, LABEL, TEXT, conn, ds, missing_line, nb):
    SAMPLE = 20000

    model = None
    if not (ds.has("date") and ds.has("label")):
        print(f"Skipped - the small model predicts the label from the newest {SAMPLE} rows, which needs the label and date "
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
    ## Inspect the clues the model used

    Read the words associated with predictions toward 1 and toward 0. Use them to form questions about the data: are they plausible domain signals, boilerplate or information that would only be known after the outcome?

    **Technical note:** these are the largest positive and negative coefficients in the fitted linear model. They describe this model's associations. The table remains empty if the model step was skipped.
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
    ## Optional AI: add short themes to a small text sample

    You can complete the investigation without this step. If you want help reading descriptions, configure `EXAKIT_MODEL_ID`, `EXAKIT_PROVIDER_BASE_URL` and `EXAKIT_PROVIDER_API_KEY` before starting the kernel, then set `USE_AI_THEMES = True` near the top.

    These settings work with a text/chat model served through the documented compatibility endpoint of Claude, Ollama, LM Studio, vLLM or Gemini. A local server may need no API key. The [provider guide](../MODEL-PROVIDERS.md) beside these notebooks explains the exact URLs, authentication and limits; model identifiers come from your provider or local server. `nb.model_settings()` checks configuration without printing the key or making a request.

    The code sends up to five selected descriptions to your endpoint and asks for short themes. Read those themes against the original text; they are suggestions to check, not established facts. Use the printed sample SQL to see exactly which records were selected.

    **Optional tracing:** set `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` and `LANGFUSE_BASE_URL` before launching notebooks to group the model calls in your Langfuse project. This records inputs/outputs, usage, timing and workflow/descriptor/session/SQL tags. Keep keys in the environment. Configuring a model can also enable optional column-description notes during profiling; the role assignments still come from fixed rules and require your approval.
    """)
    return


@app.cell
def _(ENTITY, TEXT, USE_AI_THEMES, conn, ds, nb):
    SAMPLE_TEXTS = 5
    LABEL_COL = f"{ds.col('label')} AS LABEL_, " if ds.has("label") else ""
    SAMPLE_ORDER = ", ".join([f"{ds.col(role)} DESC" for role in ("label", "date") if ds.has(role)] + [ENTITY])
    SAMPLE_SQL = f"""
    SELECT {ENTITY} AS ENTITY, {LABEL_COL}{TEXT} AS TEXT_
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
    ## Decide what deserves the next experiment

    Review the group comparisons, time pattern and local model together. Keep a useful question, note a limitation and decide what you would need to validate next. Optional AI themes can help you read the text, while the visible SQL and measured results remain the evidence.

    To repeat this investigation with Banking or your own described file, change `DATASET` and rerun. Keep the same workflow ID when it is the same investigation.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Hand off to the ML Engineer: a recipe someone else can run

    The ML Engineer needs more than a screenshot of your results. The next cell writes a **handoff**: the chosen dataset, approved column-map version, data fingerprint, feature recipe, target and train/test split.

    **Read the result:** keep the printed handoff path and check its descriptor ID/version and label. Open `ml-engineer/01_train.ipynb` to train inside Exasol from this recipe. If you change the approved map or data later, create a fresh handoff.

    **Technical note:** features are reproducible SQL inputs: category flags, date parts, text lengths and entity frequency. The time split uses the earliest 80% for training and later 20% for evaluation. Without a date, explicitly request `nb.write_handoff(conn, ds, split="random")` or approve a date role. A stale or unapproved handoff is refused.
    """)
    return


@app.cell
def _(conn, ds, nb):
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
