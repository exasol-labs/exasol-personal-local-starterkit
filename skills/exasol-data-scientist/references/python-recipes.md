# Python recipes for the kit's notebook kernel

The kernel has scikit-learn, SciPy, pandas and NumPy. Connect with the kit's
saved connection, pull a feature table built in SQL, and train on it.

## Pull a feature table

```python
import exakit.nb as nb

conn = nb.connect()                      # the kit's connection: no password in the notebook
features = conn.export_to_pandas(FEATURE_SQL)   # FEATURE_SQL: a query from sql-recipes.md
features.columns = [c.upper() for c in features.columns]
```

## Train and validate a classifier

```python
from sklearn.compose import ColumnTransformer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score, precision_score, recall_score, f1_score
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler

train, test = features[features.FOLD != 0], features[features.FOLD == 0]
numeric = ["LOG_AMOUNT", "CATEGORY_FREQ"]
categorical = ["WEEKDAY", "AMOUNT_BIN"]

model = Pipeline([
    ("prep", ColumnTransformer([
        ("num", StandardScaler(), numeric),
        ("cat", OneHotEncoder(handle_unknown="ignore"), categorical),
    ])),
    ("clf", LogisticRegression(max_iter=1000, class_weight="balanced")),
])
model.fit(train[numeric + categorical], train.TARGET)

scores = model.predict_proba(test[numeric + categorical])[:, 1]
labels = (scores >= 0.5).astype(int)
print({
    "roc_auc": round(roc_auc_score(test.TARGET, scores), 3),
    "precision": round(precision_score(test.TARGET, labels, zero_division=0), 3),
    "recall": round(recall_score(test.TARGET, labels), 3),
    "f1": round(f1_score(test.TARGET, labels), 3),
    # the baseline: always predicting the commoner answer is right this often
    "baseline_accuracy": round(max(test.TARGET.mean(), 1 - test.TARGET.mean()), 3),
})
train_auc = roc_auc_score(train.TARGET, model.predict_proba(train[numeric + categorical])[:, 1])
print("train - test AUC gap:", round(train_auc - roc_auc_score(test.TARGET, scores), 3))
```

ROC AUC 0.5 is a guess and 1.0 is perfect. A gap above about 0.05 between the
training and test scores points at overfitting or leakage.

For more accuracy, swap the classifier for
`sklearn.ensemble.HistGradientBoostingClassifier(class_weight="balanced")`.

## What the model relies on

```python
from sklearn.inspection import permutation_importance

result = permutation_importance(model, test[numeric + categorical], test.TARGET,
                                scoring="roc_auc", n_repeats=5, random_state=0)
for name, value in sorted(zip(numeric + categorical, result.importances_mean), key=lambda x: -x[1]):
    print(f"{name:20s} {value:+.4f}")
```

Permutation importance on the test rows is honest about the model's real use of
a feature. Treat it as a lead, not proof of cause.

## Two proportions

```python
from math import erfc, sqrt

def two_proportions(s_a, n_a, s_b, n_b):
    """Difference in rates B - A, its 95% interval and a two-sided p-value."""
    p_a, p_b = s_a / n_a, s_b / n_b
    pooled = (s_a + s_b) / (n_a + n_b)
    z = (p_b - p_a) / sqrt(pooled * (1 - pooled) * (1 / n_a + 1 / n_b))
    se = sqrt(p_a * (1 - p_a) / n_a + p_b * (1 - p_b) / n_b)
    return {"diff": p_b - p_a, "ci95": (p_b - p_a - 1.96 * se, p_b - p_a + 1.96 * se),
            "p_value": erfc(abs(z) / sqrt(2))}
```

Fill it with the `N` and `SUCCESSES` the per-group SQL returns.

## Two means

```python
from scipy import stats

def two_means(n_a, mean_a, var_a, n_b, mean_b, var_b):
    """Welch's t-test from per-group summaries: no rows leave the database."""
    t, p = stats.ttest_ind_from_stats(mean_b, var_b ** 0.5, n_b, mean_a, var_a ** 0.5, n_a, equal_var=False)
    se = (var_a / n_a + var_b / n_b) ** 0.5
    return {"diff": mean_b - mean_a, "ci95": (mean_b - mean_a - 1.96 * se, mean_b - mean_a + 1.96 * se),
            "t": t, "p_value": p}
```

## Sample size before an experiment

```python
from math import ceil
from scipy.stats import norm

def sample_size_per_group(base_rate, relative_lift, alpha=0.05, power=0.8):
    """Rows per group to detect base_rate * (1 + relative_lift)."""
    p1, p2 = base_rate, base_rate * (1 + relative_lift)
    z = norm.ppf(1 - alpha / 2) + norm.ppf(power)
    return ceil(z ** 2 * (p1 * (1 - p1) + p2 * (1 - p2)) / (p2 - p1) ** 2)
```

## Write scores back

Writing changes the user's database: show the target table and ask first.

```python
scored = test[["ORDER_LINE_ID"]].assign(SCORE=scores)
conn.execute('CREATE SCHEMA IF NOT EXISTS "DS_RESULTS"')
conn.import_from_pandas(scored, ("DS_RESULTS", "CANCEL_SCORES"))   # the table must exist first
```

Create the table with matching columns before `import_from_pandas`. Then a
dashboard or a query can read the scores like any other table.
