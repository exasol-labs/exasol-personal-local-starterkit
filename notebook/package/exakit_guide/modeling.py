"""The model lab behind step 2: the Data Scientist chooses the task, the model and the split.

Tasks
  predict_yes_no   classification (supervised): the approved 0/1 target
  predict_number   regression (supervised): a number column the user picks
  find_groups      clustering (unsupervised): no target
  find_unusual     anomaly detection (unsupervised): no target

Models are scikit-learn only (already in the kit). "Compare all" trains every
model of the task on identical rows and picks the best cross-validated score,
preferring the simpler model within 0.01. A single model can also be chosen.

The split is the user's: 50-90% for training, by time (newest held out), random
(stratified for yes/no) or by group (one group never on both sides), with 3, 5
or 10 cross-validation folds on the training side. Held-out rows are scored once.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Callable

import numpy as np
import pandas as pd

SEED = 0
ROW_LIMIT = 50_000
NEGATIVE_WORDS = ["expensive", "price", "slow", "days", "crash", "missing", "wrong", "cancel", "problem",
                  "bad", "broken", "late", "refund", "complaint", "other options"]

TASKS = {
    "predict_yes_no": ("Predict yes or no", "Classification, supervised: learns from the approved 0/1 outcome."),
    "predict_number": ("Predict a number", "Regression, supervised: learns to estimate an amount."),
    "find_groups": ("Find natural groups", "Clustering, unsupervised: no outcome needed."),
    "find_unusual": ("Find unusual rows", "Anomaly detection, unsupervised: no outcome needed."),
}

# key -> (family, label, needs scaling, factory(params) -> estimator)
CLASSIFIERS: dict[str, tuple] = {}
REGRESSORS: dict[str, tuple] = {}
CLUSTERERS: dict[str, tuple] = {}
DETECTORS: dict[str, tuple] = {}


def _catalog() -> None:
    if CLASSIFIERS:
        return
    from sklearn.calibration import CalibratedClassifierCV
    from sklearn.cluster import AgglomerativeClustering, KMeans
    from sklearn.dummy import DummyClassifier, DummyRegressor
    from sklearn.ensemble import (ExtraTreesClassifier, ExtraTreesRegressor, HistGradientBoostingClassifier,
                                  HistGradientBoostingRegressor, IsolationForest, RandomForestClassifier,
                                  RandomForestRegressor)
    from sklearn.linear_model import Lasso, LinearRegression, LogisticRegression, Ridge
    from sklearn.mixture import GaussianMixture
    from sklearn.naive_bayes import GaussianNB
    from sklearn.neighbors import KNeighborsClassifier, KNeighborsRegressor, LocalOutlierFactor
    from sklearn.svm import LinearSVC
    from sklearn.tree import DecisionTreeClassifier, DecisionTreeRegressor

    def trees(p):
        return {"n_estimators": p["trees"], "max_depth": p.get("max_depth"), "min_samples_leaf": 5, "n_jobs": -1, "random_state": SEED}

    CLASSIFIERS.update({
        "baseline": ("Baseline", "Always the common answer", False, lambda p: DummyClassifier(strategy="prior")),
        "logistic": ("Linear", "Logistic regression", True,
                     lambda p: LogisticRegression(C=p["C"], max_iter=3000, class_weight="balanced", random_state=SEED)),
        "logistic_l1": ("Linear", "Logistic regression, L1 (uses fewer inputs)", True,
                        lambda p: LogisticRegression(C=p["C"], l1_ratio=1.0, solver="liblinear", class_weight="balanced", random_state=SEED)),
        "decision_tree": ("Trees", "Decision tree", False,
                          lambda p: DecisionTreeClassifier(max_depth=p.get("max_depth") or 6, min_samples_leaf=10, class_weight="balanced", random_state=SEED)),
        "random_forest": ("Trees", "Random forest", False, lambda p: RandomForestClassifier(class_weight="balanced", **trees(p))),
        "extra_trees": ("Trees", "Extra trees", False, lambda p: ExtraTreesClassifier(class_weight="balanced", **trees(p))),
        "boosting": ("Boosting", "Gradient boosting", False,
                     lambda p: HistGradientBoostingClassifier(learning_rate=p["lr"], max_depth=p.get("max_depth"), max_iter=p["trees"],
                                                              class_weight="balanced", random_state=SEED)),
        "knn": ("Other", "k-nearest neighbours", True, lambda p: KNeighborsClassifier(n_neighbors=p["k"])),
        "naive_bayes": ("Other", "Naive Bayes", False, lambda p: GaussianNB()),
        "svm": ("Other", "Support vector machine (linear)", True,
                lambda p: CalibratedClassifierCV(LinearSVC(C=p["C"], class_weight="balanced", random_state=SEED), cv=3)),
    })
    REGRESSORS.update({
        "baseline": ("Baseline", "Always the average", False, lambda p: DummyRegressor(strategy="mean")),
        "linear": ("Linear", "Linear regression", True, lambda p: LinearRegression()),
        "ridge": ("Linear", "Ridge regression", True, lambda p: Ridge(alpha=1.0 / max(p["C"], 1e-6))),
        "lasso": ("Linear", "Lasso regression (uses fewer inputs)", True, lambda p: Lasso(alpha=1.0 / max(p["C"], 1e-6), max_iter=5000)),
        "decision_tree": ("Trees", "Decision tree", False,
                          lambda p: DecisionTreeRegressor(max_depth=p.get("max_depth") or 6, min_samples_leaf=10, random_state=SEED)),
        "random_forest": ("Trees", "Random forest", False, lambda p: RandomForestRegressor(**trees(p))),
        "extra_trees": ("Trees", "Extra trees", False, lambda p: ExtraTreesRegressor(**trees(p))),
        "boosting": ("Boosting", "Gradient boosting", False,
                     lambda p: HistGradientBoostingRegressor(learning_rate=p["lr"], max_depth=p.get("max_depth"), max_iter=p["trees"], random_state=SEED)),
        "knn": ("Other", "k-nearest neighbours", True, lambda p: KNeighborsRegressor(n_neighbors=p["k"])),
    })
    CLUSTERERS.update({
        "kmeans": ("Clustering", "k-means", True, lambda p: KMeans(n_clusters=p["clusters"], n_init=10, random_state=SEED)),
        "gaussian_mixture": ("Clustering", "Gaussian mixture", True, lambda p: GaussianMixture(n_components=p["clusters"], random_state=SEED)),
        "agglomerative": ("Clustering", "Hierarchical (agglomerative)", True, lambda p: AgglomerativeClustering(n_clusters=p["clusters"])),
    })
    DETECTORS.update({
        "isolation_forest": ("Anomaly", "Isolation forest", False,
                             lambda p: IsolationForest(contamination=p["contamination"], n_estimators=p["trees"], random_state=SEED)),
        "lof": ("Anomaly", "Local outlier factor", True, lambda p: LocalOutlierFactor(n_neighbors=p["k"], contamination=p["contamination"])),
    })


def catalog(task: str) -> dict:
    _catalog()
    return {"predict_yes_no": CLASSIFIERS, "predict_number": REGRESSORS, "find_groups": CLUSTERERS, "find_unusual": DETECTORS}[task]


EFFORT = {"fast": 100, "balanced": 200, "thorough": 400}


def params(settings: dict, rows: int) -> dict:
    def num(key, default, cast=float):
        try:
            v = settings.get(key)
            return cast(v) if v not in (None, "") else default
        except (TypeError, ValueError):
            return default

    p = {"trees": EFFORT.get(settings.get("effort") or "balanced", 200), "C": num("C", 1.0), "k": num("neighbours", 15, int),
         "lr": num("learning_rate", 0.1), "clusters": num("clusters", 0, int), "contamination": num("contamination", 2) / 100}
    depth = num("max_depth", 0, int)
    p["max_depth"] = depth if depth > 0 else None
    if rows > 20_000:
        p["trees"] = min(p["trees"], 150)
    p["contamination"] = min(0.2, max(0.005, p["contamination"]))
    return p


def _bare(col: str | None) -> str | None:
    return col.strip('"').split(".")[-1].strip('"') if col else None


# ----------------------------------------------------------------------------- data
@dataclass
class Data:
    frame: pd.DataFrame
    target_flag: str | None
    date: str | None
    numeric: list[str]
    categorical: list[str]
    groups: list[str]                  # columns that can define "keep groups apart"
    left_out: list[tuple[str, str]]
    sql: str = ""


def load(conn, ds, leaks: list[str]) -> Data:
    """Read the approved data once (newest first, at most ROW_LIMIT rows) with every usable column."""
    import exakit.nb as nb

    target = _bare(ds.col("label")) if ds.has("label") else None
    date = _bare(ds.col("date")) if ds.has("date") else None
    cols = dict(getattr(ds.descriptor, "columns", {}) or {})
    numeric, categorical, groups, left_out = [], [], [], []
    for c, e in cols.items():
        role, sensitive = e.get("role"), e.get("sensitive")
        if c == target:
            continue
        if c in leaks:
            left_out.append((c, "gives the answer away"))
        elif sensitive:
            left_out.append((c, "personal data"))
        elif role == "measure":
            numeric.append(c)
        elif role in ("category", "flag"):
            categorical.append(c)
            groups.append(c)
        elif role == "time":
            continue
        elif role in ("key", "identifier"):
            groups.append(c)
            left_out.append((c, "different for (almost) every row, so there is nothing general to learn"))
        elif role == "text":
            left_out.append((c, "free text: see the feature ideas"))
        else:
            left_out.append((c, "marked Leave out"))
    pick = [f'"{c}"' for c in dict.fromkeys(numeric + categorical + groups + ([target] if target else []) + ([date] if date else []))]
    order = f'"{date}" DESC' if date else "1"
    where = f'\nWHERE "{target}" IS NOT NULL' if target else ""
    sql = f"SELECT {', '.join(pick)}\nFROM {ds.fact_table}{where}\nORDER BY {order}\nLIMIT {ROW_LIMIT}"
    frame = nb.sql(conn, sql)
    if target:
        frame[target] = pd.to_numeric(frame[target], errors="coerce").astype(int)
    for c in numeric:
        frame[c] = pd.to_numeric(frame[c], errors="coerce").astype(float)
    for c in categorical:
        if frame[c].dtype == object and frame[c].dropna().map(lambda v: hasattr(v, "as_integer_ratio") and not isinstance(v, bool)).all():
            frame[c] = pd.to_numeric(frame[c], errors="coerce")
    if date:
        frame[date] = pd.to_datetime(frame[date], errors="coerce")
        frame["__month"] = frame[date].dt.month.astype("Int64").astype(str)
        categorical.append("__month")
    return Data(frame, target, date, numeric, categorical, groups, left_out, sql)


# ----------------------------------------------------------------------------- one task's inputs
@dataclass
class Run:
    task: str
    target: str | None
    X: pd.DataFrame
    y: pd.Series | None
    numeric: list[str]
    categorical: list[str]
    metric: str = ""
    metric_label: str = ""
    rate: float | None = None
    notes: list[str] = field(default_factory=list)
    dropped: list[tuple[str, str]] = field(default_factory=list)


def prepare(d: Data, task: str, target_number: str | None = None, extra: dict[str, pd.Series] | None = None) -> Run:
    """The inputs (X), the answer (y) and the score to judge by, for one task."""
    f = d.frame
    numeric, categorical = list(d.numeric), list(d.categorical)
    notes, dropped = [], []
    y, target, metric, label, rate = None, None, "", "", None
    if task == "predict_yes_no":
        if not d.target_flag:
            raise ValueError("Nothing to predict was chosen in step 1. Pick a yes-or-no column there, "
                             "or choose Predict a number, Find natural groups or Find unusual rows here.")
        target, y = d.target_flag, f[d.target_flag]
        rate = float(y.mean())
        metric, label = ("average_precision", "PR AUC") if min(rate, 1 - rate) < 0.05 else ("roc_auc", "ROC AUC")
        if metric == "average_precision":
            notes.append("The 1s are rare, so the score is PR AUC, which focuses on finding them.")
    elif task == "predict_number":
        if not target_number or target_number not in f.columns:
            raise ValueError("Pick the number you want to predict.")
        target = target_number
        y = pd.to_numeric(f[target_number], errors="coerce")
        keep = y.notna()
        f, y = f[keep], y[keep]
        numeric = [c for c in numeric if c != target]
        metric, label = "r2", "R²"
        for c in list(numeric):   # a number that moves with the target almost exactly gives the answer away
            corr = pd.to_numeric(f[c], errors="coerce").corr(y)
            if corr is not None and not np.isnan(corr) and abs(corr) > 0.98:
                numeric.remove(c)
                dropped.append((c, f"moves almost exactly with {target} (correlation {corr:.2f}), so it gives the answer away"))
        if d.target_flag:
            categorical = [c for c in categorical if c != d.target_flag]
    elif d.target_flag:
        notes.append(f"{d.target_flag} (the outcome) is left out, so this works from the data alone. "
                     "Each result's outcome rate is shown afterwards.")
    X = f[numeric + categorical].copy()
    for name, series in (extra or {}).items():
        X[name] = series.reindex(X.index)
        (categorical if X[name].dtype == object else numeric).append(name)
    for c in categorical:
        X[c] = X[c].astype(str).where(X[c].notna(), None)
    return Run(task, target, X, y, numeric, categorical, metric, label, rate, notes, dropped)


def _pre(numeric, categorical, scale: bool):
    from sklearn.compose import ColumnTransformer
    from sklearn.impute import SimpleImputer
    from sklearn.pipeline import Pipeline
    from sklearn.preprocessing import OneHotEncoder, StandardScaler

    num = Pipeline([("impute", SimpleImputer(strategy="median"))] + ([("scale", StandardScaler())] if scale else []))
    cat = Pipeline([("impute", SimpleImputer(strategy="constant", fill_value="(none)")),
                    ("onehot", OneHotEncoder(handle_unknown="ignore", min_frequency=10, sparse_output=False))])
    return ColumnTransformer([("num", num, numeric), ("cat", cat, categorical)])


# ----------------------------------------------------------------------------- the split
def split(d: Data, run: Run, settings: dict):
    """Training and held-out rows, and a description, from the user's split settings."""
    from sklearn.model_selection import GroupShuffleSplit, train_test_split

    pct = min(90, max(50, int(float(settings.get("train_pct") or 75)))) / 100
    method = settings.get("split_method") or ("time" if d.date else "random")
    idx = run.X.index
    if method == "time" and d.date:
        order = d.frame.loc[idx, d.date].sort_values(kind="stable").index
        cut = int(len(order) * pct)
        tr, te = order[:cut], order[cut:]
        text = f"The oldest {pct:.0%} by {d.date} to learn from, the newest {1 - pct:.0%} to test on. The model never sees the future."
    elif method == "group" and settings.get("split_group") in d.frame.columns:
        g = d.frame.loc[idx, settings["split_group"]].astype(str)
        a, b = next(GroupShuffleSplit(n_splits=1, train_size=pct, random_state=SEED).split(idx, groups=g))
        tr, te = idx[a], idx[b]
        text = f"{pct:.0%} of the {settings['split_group']} values to learn from, the rest to test on. No {settings['split_group']} is on both sides."
    else:
        strat = run.y if run.task == "predict_yes_no" else None
        tr, te = train_test_split(idx, train_size=pct, stratify=strat, random_state=SEED)
        text = f"A random {pct:.0%} to learn from, the rest to test on" + (", with the same share of 1s on both sides." if strat is not None else ".")
        method = "random"
    info = {"method": method, "text": text, "train": len(tr), "test": len(te), "pct": pct}
    if run.task == "predict_yes_no":
        info["train_pos"], info["test_pos"] = int(run.y.loc[tr].sum()), int(run.y.loc[te].sum())
        if info["test_pos"] < 30:
            info["warn"] = f"Only {info['test_pos']} rows with a 1 are held out, so the held-out score is shaky. Hold out more."
    elif len(te) < 100:
        info["warn"] = f"Only {len(te)} rows are held out, so the held-out score is shaky. Hold out more."
    return tr, te, info


def _cv(run: Run, d: Data, settings: dict, method: str, train_idx):
    from sklearn.model_selection import GroupKFold, KFold, StratifiedKFold, TimeSeriesSplit

    folds = int(settings.get("folds") or 5)
    if method == "time":
        return TimeSeriesSplit(n_splits=folds), None
    if method == "group" and settings.get("split_group") in d.frame.columns:
        return GroupKFold(n_splits=folds), d.frame.loc[train_idx, settings["split_group"]].astype(str)
    if run.task == "predict_yes_no":
        return StratifiedKFold(n_splits=folds, shuffle=True, random_state=SEED), None
    return KFold(n_splits=folds, shuffle=True, random_state=SEED), None


SIMPLE_ORDER = ["logistic", "linear", "ridge", "logistic_l1", "lasso", "naive_bayes", "decision_tree", "knn", "svm",
                "random_forest", "extra_trees", "boosting"]


def supervised(d: Data, run: Run, settings: dict, model: str = "all") -> dict:
    """Train the chosen model (or every model of the task) on the same split; leaderboard and pick."""
    from sklearn.base import clone
    from sklearn.metrics import average_precision_score, f1_score, mean_absolute_error, r2_score, roc_auc_score
    from sklearn.model_selection import cross_val_score
    from sklearn.pipeline import Pipeline

    cat = catalog(run.task)
    keys = list(cat) if model == "all" else (["baseline", model] if model != "baseline" else ["baseline"])
    tr, te, info = split(d, run, settings)
    X_tr, X_te, y_tr, y_te = run.X.loc[tr], run.X.loc[te], run.y.loc[tr], run.y.loc[te]
    if run.task == "predict_yes_no" and (y_tr.nunique() < 2 or y_te.nunique() < 2):
        raise ValueError("One side of the split has only one answer, so no score can be computed. Change the split.")
    cv, cv_groups = _cv(run, d, settings, info["method"], tr)
    p = params(settings, len(X_tr))
    board = []
    for key in keys:
        family, label, scale, make = cat[key]
        pipe = Pipeline([("pre", _pre(run.numeric, run.categorical, scale)), ("m", make(p))])
        t = time.time()
        try:
            cvs = cross_val_score(clone(pipe), X_tr, y_tr, cv=cv, groups=cv_groups, scoring=run.metric, n_jobs=1)
            fitted = clone(pipe).fit(X_tr, y_tr)
        except Exception as exc:
            board.append({"key": key, "model": label, "family": family, "error": (str(exc).splitlines() or ["failed"])[0][:160]})
            continue
        row = {"key": key, "model": label, "family": family, "cv": float(np.nanmean(cvs)), "cv_sd": float(np.nanstd(cvs)),
               "seconds": round(time.time() - t, 1), "_fitted": fitted}
        if run.task == "predict_yes_no":
            proba = fitted.predict_proba(X_te)[:, 1]
            row.update({"roc_auc": float(roc_auc_score(y_te, proba)), "pr_auc": float(average_precision_score(y_te, proba)),
                        "f1": float(f1_score(y_te, (proba >= 0.5).astype(int), zero_division=0))})
            row["held"] = row["roc_auc"] if run.metric == "roc_auc" else row["pr_auc"]
        else:
            pred = fitted.predict(X_te)
            row.update({"r2": float(r2_score(y_te, pred)), "mae": float(mean_absolute_error(y_te, pred)),
                        "rmse": float(np.sqrt(np.mean((y_te.values - pred) ** 2)))})
            row["held"] = row["r2"]
        board.append(row)
    ok = [r for r in board if "cv" in r]
    if not ok:
        raise ValueError("No model could be trained on this data: " + "; ".join(r.get("error", "") for r in board))
    if model == "all":
        best = max(ok, key=lambda r: r["cv"])
        pick = best
        for key in SIMPLE_ORDER:
            r = next((x for x in ok if x["key"] == key), None)
            if r and best["cv"] - r["cv"] <= 0.01:
                pick = r
                break
    else:
        pick = next((x for x in ok if x["key"] == model), ok[0])
    return {"board": board, "pick": pick, "best": max(ok, key=lambda r: r["cv"]), "X_te": X_te, "y_te": y_te, "split": info,
            "folds": int(settings.get("folds") or 5), "train_rows": len(X_tr), "test_rows": len(X_te),
            "chosen_by": "you" if model != "all" else "cross-validation"}


def importance(result: dict, metric: str, top: int = 8) -> list[dict]:
    """How much the held-out score drops when one input is scrambled (works for any model)."""
    from sklearn.inspection import permutation_importance

    r = permutation_importance(result["pick"]["_fitted"], result["X_te"], result["y_te"], scoring=metric, n_repeats=5,
                               random_state=SEED, n_jobs=1)
    rows = sorted(({"feature": c, "drop": float(m)} for c, m in zip(result["X_te"].columns, r.importances_mean)), key=lambda x: -x["drop"])
    best = max((x["drop"] for x in rows), default=0) or 1
    return [{"label": x["feature"].replace("__month", "Month"), "value": round(x["drop"], 4), "rows": None,
             "relative": x["drop"] / best, "display": f"−{x['drop']:.3f}"} for x in rows[:top] if x["drop"] > 0]


# ----------------------------------------------------------------------------- unsupervised
def _matrix(run: Run, scale: bool, sample: int | None = None):
    X = run.X if not sample or len(run.X) <= sample else run.X.sample(sample, random_state=SEED)
    return X, _pre(run.numeric, run.categorical, scale).fit_transform(X)


def _traits(X: pd.DataFrame, mask, run: Run, top: int = 3) -> list[str]:
    """What sets some rows apart from all rows, in words."""
    out = []
    for c in run.numeric:
        allv = pd.to_numeric(X[c], errors="coerce")
        sub = allv[mask]
        sd = allv.std() or 1
        z = (sub.mean() - allv.mean()) / sd
        if pd.notna(z) and abs(z) >= 0.5:
            out.append((abs(z), f"{'higher' if z > 0 else 'lower'} {c} (avg {sub.mean():,.0f} vs {allv.mean():,.0f})"))
    for c in run.categorical:
        if c == "__month":
            continue
        share_all = X[c].value_counts(normalize=True)
        for v, s in X.loc[mask, c].value_counts(normalize=True).head(3).items():
            lift = s / share_all.get(v, 1e-9)
            if s >= 0.25 and lift >= 1.4:
                out.append((lift - 1, f"mostly {c} = {v} ({s:.0%}, vs {share_all.get(v, 0):.0%} overall)"))
    return [t for _, t in sorted(out, key=lambda x: -x[0])[:top]]


def find_groups(d: Data, run: Run, settings: dict, model: str = "kmeans") -> dict:
    from sklearn.metrics import silhouette_score

    cat = catalog("find_groups")
    key = model if model in cat else "kmeans"
    _family, label, scale, make = cat[key]
    sample = 5_000 if key == "agglomerative" else None
    X, M = _matrix(run, scale, sample)
    p = params(settings, len(X))
    rng = np.random.default_rng(SEED)
    small = M if len(M) <= 3000 else M[rng.choice(len(M), 3000, replace=False)]
    tried = []
    if not p["clusters"]:
        for k in range(2, 7):
            p["clusters"] = k
            est = make(p)
            lab = est.fit_predict(small)
            tried.append((k, float(silhouette_score(small, lab))))
        p["clusters"] = max(tried, key=lambda x: x[1])[0]
    labels = make(p).fit_predict(M)
    pick = rng.choice(len(M), min(len(M), 5000), replace=False)
    score = float(silhouette_score(M[pick], labels[pick]))
    groups = []
    for g in sorted(set(labels)):
        mask = pd.Series(labels == g, index=X.index)
        item = {"name": f"Group {g + 1}", "rows": int(mask.sum()), "share": float(mask.mean()), "traits": _traits(X, mask, run)}
        if d.target_flag:
            item["rate"] = float(d.frame.loc[X.index[mask.values], d.target_flag].mean())
        groups.append(item)
    groups.sort(key=lambda g: -g["rows"])
    for i, g in enumerate(groups):
        g["name"] = f"Group {i + 1}"
    return {"model": label, "k": p["clusters"], "tried": tried, "score": score, "groups": groups, "rows": len(X),
            "sampled": bool(sample and len(run.X) > sample),
            "overall_rate": float(d.frame.loc[X.index, d.target_flag].mean()) if d.target_flag else None}


def find_unusual(d: Data, run: Run, settings: dict, model: str = "isolation_forest") -> dict:
    cat = catalog("find_unusual")
    key = model if model in cat else "isolation_forest"
    _family, label, scale, make = cat[key]
    X, M = _matrix(run, scale)
    p = params(settings, len(X))
    est = make(p)
    flags = est.fit_predict(M)
    raw = est.negative_outlier_factor_ if hasattr(est, "negative_outlier_factor_") else est.score_samples(M)
    unusual = pd.Series(flags == -1, index=X.index)
    show = run.numeric[:3] + [c for c in run.categorical if c != "__month"][:3]
    z = {}
    for c in run.numeric:
        v = pd.to_numeric(X[c], errors="coerce")
        z[c] = (v - v.mean()) / (v.std() or 1)
    freq = {c: X[c].map(X[c].value_counts(normalize=True)) for c in run.categorical if c != "__month"}
    top = []
    for i in np.argsort(raw)[:10]:
        idx = X.index[i]
        why = [(abs(z[c].loc[idx]), f"{c} very {'high' if z[c].loc[idx] > 0 else 'low'} ({X.loc[idx, c]:,.0f})")
               for c in run.numeric if pd.notna(z[c].loc[idx]) and abs(z[c].loc[idx]) >= 2]
        why += [(3.0, f"rare {c}: {X.loc[idx, c]}") for c in freq if pd.notna(freq[c].loc[idx]) and freq[c].loc[idx] < 0.02]
        why.sort(key=lambda w: -w[0])
        top.append([(X.loc[idx, c] if c in run.categorical else (None if pd.isna(X.loc[idx, c]) else round(float(X.loc[idx, c]), 2)))
                    for c in show] + ["; ".join(w for _, w in why[:2]) or "an unusual mix of values"])
    out = {"model": label, "flagged": int(unusual.sum()), "rows": len(X), "share": p["contamination"],
           "columns": show + ["Why it stands out"], "top": top, "traits": _traits(X, unusual, run)}
    if d.target_flag:
        out["rate_unusual"] = float(d.frame.loc[unusual[unusual].index, d.target_flag].mean()) if unusual.any() else None
        out["rate_rest"] = float(d.frame.loc[unusual[~unusual].index, d.target_flag].mean())
    return out


# ----------------------------------------------------------------------------- feature ideas
@dataclass
class Idea:
    id: str
    title: str
    why: str
    sql: str
    build: Callable[[pd.DataFrame], pd.Series]
    source: str = "rule"


def ideas(d: Data, run: Run) -> list[Idea]:
    f = d.frame
    out: list[Idea] = []
    if d.date:
        dt = d.date
        out.append(Idea(f"days_{dt}", f"How long ago {dt} was", "Newer and older records often behave differently (for example new customers leave more).",
                        f'DAYS_BETWEEN(CURRENT_DATE, "{dt}")', lambda fr, dt=dt: (fr[dt].max() - fr[dt]).dt.days.astype(float)))
    cats = [c for c in run.categorical if c != "__month"]
    for m in run.numeric[:2]:
        for c in cats[:2]:
            out.append(Idea(f"ratio_{m}_{c}", f"{m} compared with its {c}'s usual value",
                            f"A {m} that is high or low for its {c} can matter more than the amount itself.",
                            f'"{m}" / AVG("{m}") OVER (PARTITION BY "{c}")', lambda fr, m=m, c=c: fr[m] / fr.groupby(c)[m].transform("mean")))
    if len(cats) >= 2:
        a, b = cats[0], cats[1]
        out.append(Idea(f"combo_{a}_{b}", f"{a} and {b} together", f"Some combinations (a {a} with a certain {b}) can behave differently from each part alone.",
                        f'"{a}" || \' · \' || "{b}"', lambda fr, a=a, b=b: fr[a].astype(str) + " · " + fr[b].astype(str)))
    for c in cats:
        if pd.api.types.is_numeric_dtype(f[c]) and f[c].nunique() > 2:
            out.append(Idea(f"num_{c}", f"Use {c} as a number", f"{c} holds counts. As a number, the model can learn that more is worse (or better).",
                            f'CAST("{c}" AS DOUBLE)', lambda fr, c=c: pd.to_numeric(fr[c], errors="coerce").astype(float)))
    for m in run.numeric:
        if f[m].isna().mean() > 0.005:
            out.append(Idea(f"missing_{m}", f"Whether {m} is missing", f"{f[m].isna().mean():.1%} of rows have no {m}. Sometimes a blank is a signal.",
                            f'CASE WHEN "{m}" IS NULL THEN 1 ELSE 0 END', lambda fr, m=m: fr[m].isna().astype(float)))
    for c in cats:
        if f[c].dtype == object:
            avg_len = f[c].dropna().astype(str).str.len().mean()
            if avg_len and avg_len > 20:
                words = "|".join(NEGATIVE_WORDS)
                out.append(Idea(f"words_{c}", f"{c} mentions a problem", f"{c} holds sentences. A flag for words like price, slow, crash or wrong can carry more signal.",
                                f"CASE WHEN REGEXP_LIKE(LOWER(\"{c}\"), '.*({words}).*') THEN 1 ELSE 0 END",
                                lambda fr, c=c, words=words: fr[c].astype(str).str.lower().str.contains(words, regex=True).astype(float)))
    return out[:8]


def try_idea(d: Data, task: str, target_number: str | None, settings: dict, model_key: str, base: dict, idea: Idea,
             kept: dict[str, pd.Series]) -> dict:
    """Retrain the picked model with the idea added, on the same split; compare with the same model without it."""
    series = idea.build(d.frame)
    run = prepare(d, task, target_number, {**kept, idea.id: series})
    after = next(r for r in supervised(d, run, settings, model_key)["board"] if r.get("key") == model_key and "cv" in r)
    before = next(r for r in base["board"] if r.get("key") == model_key)
    d_cv, d_held = after["cv"] - before["cv"], after["held"] - before["held"]
    label = run.metric_label
    if (task == "predict_yes_no" and after["held"] > 0.98) or (task == "predict_number" and after["held"] > 0.995):
        verdict, text = "suspicious", "The score jumped almost to perfect. That usually means the idea gives the answer away. Don't keep it."
    elif d_cv >= 0.005 and d_held >= -0.002:
        verdict, text = "helps", f"Helps: {label} {d_cv:+.3f} in cross-validation, {d_held:+.3f} on the held-out rows."
    elif d_cv <= -0.005:
        verdict, text = "hurts", f"Makes it worse: {label} {d_cv:+.3f}. Leave it out."
    else:
        verdict, text = "same", f"No real change ({d_cv:+.3f}). Not worth the extra column."
    return {"verdict": verdict, "text": text, "series": series}
