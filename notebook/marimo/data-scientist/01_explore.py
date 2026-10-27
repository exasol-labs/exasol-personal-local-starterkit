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
    # Explore a dataset

    - **Dataset:** the Pharma sample (`pharma_trials`, ClinicalTrials.gov studies) as it ships; the Banking sample
      (`banking_complaints`, CFPB consumer complaints) or your own file by changing the one assignment below.
    - **What must be loaded:** that dataset. `00_quickstart.ipynb` loads either sample (or `exakit data-load
      pharma_trials` in a terminal); your own file is loaded by the next cell.
    - **How long:** about two minutes; the text step adds a few seconds per row with your own model.

    The notebook runs on any dataset that has a **descriptor**: a short YAML file naming which column plays each role -
    the *entity* a row is about, the *category* to compare, the *date*, the *label* to predict (0 or 1) and the *text*.
    Every query is built from those roles and printed before its result, so you always see the SQL behind a number.
    """)
    return


@app.cell
def _():
    DATASET = "pharma_trials"   # or "banking_complaints", or your own file ("~/my-data/transactions.csv", roles beside it)
    return (DATASET,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Connect and read the descriptor

    **Change one line to change the data**: the assignment above, and no SQL. A kit dataset is named by its id. Your own
    CSV, Parquet or JSON file is named by its path; its roles are in `<name>.descriptor.yaml` beside it (the quickstart's
    own-file cell writes that file), and the file is loaded into its table the first time. A descriptor file of a table
    already in the database works too. The descriptor is checked by the kit's own rules and against the database: a role
    that names a missing table or column stops here, naming it.

    A file with **no descriptor beside it** does not stop here: the next cell loads it into `MY_DATA.<FILE NAME>`,
    proposes its roles with the evidence and saves that proposal beside the file as a draft, which this notebook explores
    as it is (exploring does not need an approval; training and asking do). To approve the roles, use the picker it
    shows, or the quickstart's `OWN_FILE` cell with this file, or `exakit describe <id> --approve`; a headless run
    approves them only with `EXAKIT_NB_AUTO_APPROVE=force`.

    Paste the quickstart's workflow id into `WORKFLOW_ID` below to continue its log
    in this notebook's separate kernel. Otherwise this notebook starts its own log.
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

    ENTITY, CATEGORY, DATE, LABEL = ds.col("entity"), ds.col("category"), ds.col("date"), ds.col("label")
    TEXT = ds.text_sql()
    return CATEGORY, DATE, ENTITY, LABEL, TEXT, conn, ds, nb


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## The landscape

    The domain's landscape question: the entities with the most rows, by category, and how often the label is 1 for
    each - sponsors by trial phase for the Pharma sample, companies by product for the Banking one.
    """)
    return


@app.cell
def _(CATEGORY, ENTITY, LABEL, conn, ds, nb):
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
    landscape.pivot_table(index="ENTITY", columns="CATEGORY", values="N", fill_value=0, aggfunc="sum")
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    Over time: rows and label rate per period. The period follows the span of the data - days for a few weeks,
    months for a few years, years beyond that.
    """)
    return


@app.cell
def _(DATE, LABEL, conn, ds, nb):
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
    ## A small model, on this computer

    Can the text and the category predict the label? A logistic regression over word counts, trained on this machine
    with scikit-learn - no model service needed. The rows come from the database with the SQL printed below.
    """)
    return


@app.cell
def _(CATEGORY, DATE, ENTITY, LABEL, TEXT, conn, ds, nb):
    SAMPLE = 20000

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
    The words that push a prediction towards 1 and towards 0:
    """)
    return


@app.cell
def _(model):
    import numpy as np

    names = model.named_steps["features"].get_feature_names_out()
    weights = model.named_steps["classifier"].coef_[0]
    order = np.argsort(weights)
    print("towards 1:", ", ".join(n.split("__", 1)[1] for n in names[order[-12:]][::-1]))
    print("towards 0:", ", ".join(n.split("__", 1)[1] for n in names[order[:12]]))
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## The text step, with your own model

    A sample of the text column goes to **your** model endpoint, which names each row's theme in a few words. Set these
    before `exakit notebook` to turn it on (nothing is sent otherwise):

    - `EXAKIT_NB_MODEL` - the model name, e.g. `gpt-4o-mini`, or `llama3.1` on a local Ollama
    - `OPENAI_BASE_URL` and `OPENAI_API_KEY` - the endpoint and its key, as the OpenAI client reads them

    With `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` and `LANGFUSE_BASE_URL` set too (`LANGFUSE_HOST`, the SDK 3 name,
    is accepted as an alias), the calls are one trace in your Langfuse project - every call's input, output, token usage
    and latency - tagged `exasol.dataset`, `exasol.descriptor` (the descriptor's digest), `exasol.descriptor_version`,
    `exasol.workflow_id` (when a workflow is active), `exasol.session_id` and the sample SQL. Without them the step runs
    untraced and says so in one line. When the table is a live source (a virtual schema), the step names the source and
    asks before any row is sent.
    """)
    return


@app.cell
def _(DATE, ENTITY, LABEL, TEXT, conn, ds, nb):
    SAMPLE_TEXTS = 5
    SAMPLE_SQL = f"""
    SELECT {ENTITY} AS ENTITY, {LABEL} AS LABEL_, {TEXT} AS TEXT_
    FROM {ds.fact_table}
    WHERE LENGTH(TRIM({TEXT})) > 0
    ORDER BY {LABEL} DESC, {DATE} DESC, {ENTITY}
    LIMIT {SAMPLE_TEXTS}"""

    text_sample = nb.sql(conn, SAMPLE_SQL)
    nb.show_sql()

    endpoint = nb.model_client()
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
    ## Next

    - Change `DATASET` at the top and run everything again: the same cells work on any described dataset, your own
      file included.
    - Train inside the database and track the run in MLflow: the ML Engineer's notebooks (`ml-engineer/` beside this
      folder), with the `udf-devkit` add-on (`exakit marketplace udf-devkit`).
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Hand off to the ML Engineer

    The last cell writes the **handoff**: one JSON file under `~/.exasol-starter-kit/handoffs/` that the ML Engineer's
    `01_train` starts from without opening the descriptor - which descriptor version and digest this was, a digest of the
    data, the feature view built from the roles (SQL only - category one-hot, date parts, text lengths, entity
    frequency - so a Rust scorer can reproduce it over the same view), the label and its positive class, the training SQL
    with a time split by the date role and the input and output schemas. Without a date role there is no time split and
    the cell refuses, naming the two ways on: ask for a reproducible hash split, `nb.write_handoff(conn, ds,
    split="random")`, or add a date role to the descriptor and approve it.
    Training refuses a handoff whose descriptor has changed since, so run this cell again after a new approval.
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
