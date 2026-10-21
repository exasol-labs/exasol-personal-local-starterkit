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
    # Classify text

    Teach a model to read: from a row's free text, predict its **category** - which kind of product a recall is about,
    which banking product a complaint concerns - and then the **label** (a serious recall, a complaint that paid). It is
    the task Spark NLP's news-category classifier demonstrates, done here on Exasol with scikit-learn: the rows come from
    the database with the SQL printed before each result, the model trains on this computer, and nothing leaves it.

    It runs on any dataset with a **descriptor** (the roles: entity, category, date, label, text). `fda_recalls` ships
    with the kit (`exakit data-load fda_recalls`); `banking_complaints` and `pharma_trials` work too, and so does your own
    CSV or Parquet file ("Your own file" below).
    """)
    return


@app.cell
def _():
    DATASET = "fda_recalls"   # or "banking_complaints", "pharma_trials", "~/my-data/descriptor.json", or "own-file"
    return (DATASET,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Your own file

    Say which column plays each role and set `DATASET = "own-file"` above. `exakit_nb.load_own_file` loads the file into
    the table over the kit's connection (a second run loads nothing unless the file changed) and checks the roles.
    """)
    return


@app.cell
def _():
    OWN_FILE = {
        "path": "~/my-data/tickets.csv",
        "table": "MY_DATA.TICKETS",
        "descriptor": {"entity": "CUSTOMER_ID", "category": "QUEUE", "date": "OPENED_ON", "label": "ESCALATED",
                       "text": ["SUBJECT", "BODY"]},
    }
    return (OWN_FILE,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Connect and read the descriptor

    There is no host, user or password in this notebook: the connection comes from the kit.
    """)
    return


@app.cell
def _(DATASET, OWN_FILE):
    import exakit_nb

    conn = exakit_nb.connect()
    ds = exakit_nb.load_own_file(**OWN_FILE, conn=conn) if DATASET == "own-file" else exakit_nb.dataset(conn, DATASET)
    for role, column in ds.roles():
        print(f"  {role:<9} {column}")

    CATEGORY, LABEL, DATE = ds.col("category"), ds.col("label"), ds.col("date")
    TEXT = ds.text_sql()
    return CATEGORY, DATE, LABEL, TEXT, conn, ds, exakit_nb


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## The classes

    How many rows each category has. A class with very few rows is hard to learn; the split below keeps every class's
    share the same in training and test.
    """)
    return


@app.cell
def _(CATEGORY, conn, ds, exakit_nb):
    classes = exakit_nb.sql(conn, f"""
    SELECT CAST({CATEGORY} AS VARCHAR(2000)) AS CATEGORY, COUNT(*) AS N
    FROM {ds.fact_table}
    GROUP BY {CATEGORY}
    ORDER BY N DESC""")
    exakit_nb.show_sql()
    classes
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## The training rows

    The text and the category of every row (up to `SAMPLE`), newest first. Classes with fewer than `MIN_ROWS` rows are
    left out: a model cannot learn a class from a handful of examples.
    """)
    return


@app.cell
def _(CATEGORY, DATE, LABEL, TEXT, conn, ds, exakit_nb):
    SAMPLE, MIN_ROWS = 20000, 20

    rows = exakit_nb.sql(conn, f"""
    SELECT {TEXT} AS TEXT_,
           CAST({CATEGORY} AS VARCHAR(2000)) AS CATEGORY_,
           {LABEL} AS LABEL_
    FROM {ds.fact_table}
    WHERE {CATEGORY} IS NOT NULL
    ORDER BY {DATE} DESC
    LIMIT {SAMPLE}""")
    exakit_nb.show_sql()

    counts = rows["CATEGORY_"].value_counts()
    rows = rows[rows["CATEGORY_"].isin(counts[counts >= MIN_ROWS].index)].reset_index(drop=True)
    rows["TEXT_"] = rows["TEXT_"].fillna("")
    print(f"{len(rows)} rows, {rows['CATEGORY_'].nunique()} classes")
    return (rows,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Train the category classifier

    Words and word pairs, weighted by how telling they are (TF-IDF), into a logistic regression - one model for all the
    classes. Three rows in four train it; the fourth row is kept back to test it on text it has never seen.
    """)
    return


@app.cell
def _(rows):
    from sklearn.feature_extraction.text import TfidfVectorizer
    from sklearn.linear_model import LogisticRegression
    from sklearn.metrics import classification_report, confusion_matrix
    from sklearn.model_selection import train_test_split
    from sklearn.pipeline import Pipeline
    _X_train, _X_test, _y_train, y_test = train_test_split(rows['TEXT_'], rows['CATEGORY_'], test_size=0.25, random_state=0, stratify=rows['CATEGORY_'])
    classifier = Pipeline([('tfidf', TfidfVectorizer(ngram_range=(1, 2), min_df=2, sublinear_tf=True, stop_words='english')), ('model', LogisticRegression(max_iter=2000, class_weight='balanced'))])
    classifier.fit(_X_train, _y_train)
    predicted = classifier.predict(_X_test)
    print(classification_report(y_test, predicted, digits=3))
    return (
        LogisticRegression,
        Pipeline,
        TfidfVectorizer,
        classification_report,
        classifier,
        confusion_matrix,
        predicted,
        train_test_split,
        y_test,
    )


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    Where it goes wrong: each row is the true class, each column what the model said. On `fda_recalls` the product
    type is nearly always plain from the words ("tablets", "catheter", "cookies"), so this is the easy task; the label
    below is the hard one.
    """)
    return


@app.cell
def _(classifier, confusion_matrix, predicted, y_test):
    import pandas as pd

    labels = list(classifier.classes_)
    pd.DataFrame(confusion_matrix(y_test, predicted, labels=labels), index=labels, columns=labels)
    return labels, pd


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    The words that point to each class most strongly.
    """)
    return


@app.cell
def _(classifier, labels, pd):
    words = classifier.named_steps["tfidf"].get_feature_names_out()
    weights = classifier.named_steps["model"].coef_
    top = {label: [words[i] for i in weights[n].argsort()[::-1][:8]] for n, label in enumerate(labels)} if len(labels) > 2 else \
          {labels[1]: [words[i] for i in weights[0].argsort()[::-1][:8]], labels[0]: [words[i] for i in weights[0].argsort()[:8]]}
    pd.DataFrame({label: pd.Series(ws) for label, ws in top.items()})
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Try it on new text

    Write your own sentences: the model says which class each belongs to, and how sure it is.
    """)
    return


@app.cell
def _(classifier, pd):
    NEW_TEXT = [
        "Undeclared peanuts in chocolate chip cookies",
        "Lack of sterility assurance for single-use syringes",
        "Tablets failed dissolution specifications at the 12 month stability time point",
    ]

    probabilities = classifier.predict_proba(NEW_TEXT)
    pd.DataFrame({"text": NEW_TEXT, "predicted": classifier.predict(NEW_TEXT),
                  "confidence": probabilities.max(axis=1).round(3)})
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## The label from the same text

    Can the words also tell the outcome - a serious (Class I) recall, a complaint that ended in money? The same pipeline,
    with the label as the class. The label is often rare, so look at its recall (how many of the 1s it finds) and its
    precision (how many of its 1s are right), not only the accuracy.
    """)
    return


@app.cell
def _(
    LogisticRegression,
    Pipeline,
    TfidfVectorizer,
    classification_report,
    rows,
    train_test_split,
):
    labelled = rows[rows['LABEL_'].notna()]
    _X_train, _X_test, _y_train, y_test_1 = train_test_split(labelled['TEXT_'], labelled['LABEL_'].astype(int), test_size=0.25, random_state=0, stratify=labelled['LABEL_'].astype(int))
    label_model = Pipeline([('tfidf', TfidfVectorizer(ngram_range=(1, 2), min_df=2, sublinear_tf=True, stop_words='english')), ('model', LogisticRegression(max_iter=2000, class_weight='balanced'))]).fit(_X_train, _y_train)
    print(classification_report(y_test_1, label_model.predict(_X_test), digits=3))
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Next

    - Change `DATASET` at the top and run everything again: the same cells classify any described dataset's text.
    - Track these models with MLflow, as `ml-engineer/wine_quality_mlflow.ipynb` does, or train inside the database with
      a Python UDF: `ml-engineer/train.ipynb`.
    """)
    return


if __name__ == "__main__":
    app.run()
