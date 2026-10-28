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
    # Build a decision-tree baseline on this computer

    **Dataset:** Pharma or Banking; **How long:** five minutes. Adapted from the
    Notebook Connector / AI Lab telescope training lesson, with approved roles
    instead of the telescope tables. This fits locally; 01_train fits inside Exasol.
    Upstream attribution and MIT license: `notebook/upstream-sources.json`.
    """)
    return


@app.cell
def _():
    import exakit.nb as nb

    DATASET = "pharma_trials"  # or "banking_complaints"
    conn = nb.connect()
    ds = nb.dataset(conn, DATASET).require_approved("decision-tree baseline")
    nb.workflow("decision-tree-baseline")
    if not ds.has("category") or not ds.has("label"):
        raise ValueError("This lesson needs category and binary label roles; review them in 00_quickstart.")
    return conn, ds, nb


@app.cell
def _(conn, ds, nb):
    sample_sql = (f"SELECT CAST({ds.col('category')} AS VARCHAR(2000)) AS CATEGORY, "
                  f"CAST({ds.col('label')} AS DOUBLE) AS LABEL FROM {ds.fact_table} "
                  f"WHERE {ds.col('label')} IS NOT NULL ORDER BY 1, 2 LIMIT 10000")
    print(sample_sql)
    sample = nb.sql(conn, sample_sql)
    print(f"{len(sample)} rows; category is the feature, label is the outcome.")
    return (sample,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Fit a reproducible baseline and check held-out predictions

    Missing categories become one explicit value; unseen categories are ignored
    by the encoder. The fixed split and tree seed make repeats comparable. These
    are predictive associations, not causal explanations.
    """)
    return


@app.cell
def _(sample):
    from sklearn.compose import ColumnTransformer
    from sklearn.dummy import DummyClassifier
    from sklearn.metrics import accuracy_score, classification_report, f1_score
    from sklearn.model_selection import train_test_split
    from sklearn.pipeline import Pipeline
    from sklearn.preprocessing import OneHotEncoder
    from sklearn.tree import DecisionTreeClassifier

    inputs = sample[["CATEGORY"]].fillna("missing")
    labels = sample["LABEL"].astype(int)
    if labels.nunique() != 2 or labels.value_counts().min() < 2:
        raise ValueError("This lesson needs two outcome classes with at least two rows each.")
    train_x, test_x, train_y, test_y = train_test_split(inputs, labels, test_size=0.2, stratify=labels, random_state=42)
    tree = Pipeline([
        ("features", ColumnTransformer([("category", OneHotEncoder(handle_unknown="ignore"), ["CATEGORY"])])),
        ("tree", DecisionTreeClassifier(max_depth=4, min_samples_leaf=20, random_state=42)),
    ])
    tree.fit(train_x, train_y)
    prediction = tree.predict(test_x)
    majority = DummyClassifier(strategy="most_frequent").fit(train_x, train_y).predict(test_x)
    print(f"Accuracy: {accuracy_score(test_y, prediction):.4f}")
    print(f"Macro-F1: {f1_score(test_y, prediction, average='macro'):.4f}; majority: {f1_score(test_y, majority, average='macro'):.4f}")
    print(classification_report(test_y, prediction, zero_division=0))
    return


if __name__ == "__main__":
    app.run()
