# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown]
# # Train a decision tree inside Exasol
#
# **Dataset:** Pharma or Banking; **How long:** five minutes. Adapted from the
# Notebook Connector / AI Lab scikit-learn training lesson. Reuse the approved
# handoff's SQL features and time split, but fit a decision tree inside a Python
# SET UDF. This lesson returns evaluation metrics; use 01_train for the full
# model-artifact and MLflow contract. Sources: `notebook/upstream-sources.json`.

# %%
import exakit.nb as nb

DATASET = "pharma_trials"  # or "banking_complaints"
CONTAINER = nb.ml_train.udf_container()
conn = nb.connect()
ds = nb.dataset(conn, DATASET).require_approved("decision-tree UDF")
nb.workflow("decision-tree-udf")
handoff = nb.ml_train.training_handoff(conn, ds)
plan = nb.prepare_training(conn, ds, handoff, container=CONTAINER, seed=42)

# %% [markdown]
# ## Build the alternative training script
#
# The feature view is the same SQL feature view used by 01_train. The UDF reads
# at most 10,000 reference rows from each split for this lesson. It needs no network or keys.

# %%
feature_parameters = ", ".join(f'"F{i}" DOUBLE' for i in range(len(plan.features)))
tree_script = f'''CREATE OR REPLACE {CONTAINER} SET SCRIPT EXAKIT_EXAMPLES.TRAIN_TREE(
{feature_parameters}, LABEL_ DOUBLE, SPLIT_ VARCHAR(10))
EMITS (ROWS_TRAIN DOUBLE, ROWS_TEST DOUBLE, ACCURACY DOUBLE, MACRO_F1 DOUBLE, BASELINE_F1 DOUBLE) AS
from sklearn.tree import DecisionTreeClassifier
from sklearn.dummy import DummyClassifier
from sklearn.metrics import accuracy_score, f1_score
def run(ctx):
    frame = ctx.get_dataframe(20000)
    feature_columns = [c for c in frame.columns if c.startswith('F')]
    train = frame[frame['SPLIT_'] == 'train']
    test = frame[frame['SPLIT_'] == 'test']
    if train.empty or test.empty:
        raise ValueError('The selected rows must contain both train and test splits.')
    model = DecisionTreeClassifier(max_depth=4, min_samples_leaf=20, random_state=42)
    model.fit(train[feature_columns], train['LABEL_'].astype(int))
    predicted = model.predict(test[feature_columns])
    baseline = DummyClassifier(strategy='most_frequent').fit(train[feature_columns], train['LABEL_'].astype(int))
    ctx.emit(len(train), len(test), float(accuracy_score(test['LABEL_'], predicted)),
             float(f1_score(test['LABEL_'], predicted, average='macro', zero_division=0)),
             float(f1_score(test['LABEL_'], baseline.predict(test[feature_columns]), average='macro', zero_division=0)))
'''
conn.execute("CREATE SCHEMA IF NOT EXISTS EXAKIT_EXAMPLES")
print(tree_script)
conn.execute(tree_script)

# %%
feature_arguments = ", ".join(f'CAST(T."{name}" AS DOUBLE)' for name in plan.features)
sample_order = ", ".join(f'H."{name}"' for name in plan.features)
tree_sql = (f'SELECT EXAKIT_EXAMPLES.TRAIN_TREE({feature_arguments}, '
            f'CAST(T."{handoff["label"]["column"]}" AS DOUBLE), T."SPLIT_") '
            f'FROM (SELECT H.*, ROW_NUMBER() OVER (PARTITION BY H."SPLIT_" ORDER BY {sample_order}) AS SAMPLE_ROW '
            f'FROM ({handoff["training_sql"]}) H) T WHERE T.SAMPLE_ROW <= 10000')
print(tree_sql)
evaluation = nb.sql(conn, tree_sql)
print(evaluation.to_string(index=False))
assert int(evaluation.iloc[0]["ROWS_TRAIN"]) > 0 and int(evaluation.iloc[0]["ROWS_TEST"]) > 0
