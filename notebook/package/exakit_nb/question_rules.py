"""Draft Exasol SQL from a plain-language question, without an AI model: ``nb.draft_question``.

    proposal = nb.draft_question(connection, dataset, "Which category has the highest cancellation rate?")
    proposal.approve(); answer = proposal.run()        # the kit's own path, as for a model's draft (nb.ask)

It matches common question shapes (rate, count, total, average per group; top N; trend over time; filters by year
and by a group's value) to SQL templates over the approved column map, checks the SQL is read-only, and hands it to
nb.ask(proposed_sql=...), so approval, logging and running are the kit's. ``example_questions(dataset)`` suggests
questions this dataset's roles can answer. Nothing leaves the computer: no model is called.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field



class FriendlyError(ValueError):
    pass


def qident(name: str) -> str:
    return '"' + str(name).replace('"', '""') + '"'


def qstr(value: str) -> str:
    return "'" + str(value).replace("'", "''") + "'"


MIN_GROUP_ROWS = 30

_FORBIDDEN = re.compile(
    r"\b(insert|update|delete|merge|create|drop|alter|attach|detach|copy|export|import|install|load|"
    r"pragma|set|reset|call|checkpoint|vacuum|truncate|grant|revoke|use)\b",
    re.IGNORECASE,
)


def ensure_read_only(sql: str) -> str:
    """Return a cleaned single SELECT statement, or raise FriendlyError."""
    text = re.sub(r"--[^\n]*", " ", sql)
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.DOTALL).strip()
    text = text.rstrip(";").strip()
    if not text:
        raise FriendlyError("The query is empty.")
    if ";" in re.sub(r"'(?:[^']|'')*'", "''", text):
        raise FriendlyError("Only one query can run at a time.")
    if not re.match(r"^(select|with)\b", text, re.IGNORECASE):
        raise FriendlyError("Only queries that read data can run here.")
    without_strings = re.sub(r"'(?:[^']|'')*'", "''", text)
    without_idents = re.sub(r'"(?:[^"]|"")*"', '""', without_strings)
    if _FORBIDDEN.search(without_idents):
        raise FriendlyError("This query tries to change something, so it was blocked. Only read-only queries can run.")
    return text


@dataclass
class DraftContext:
    """What a drafter knows about the cleaned table. Built from the column map."""

    table: str
    columns: dict[str, str]  # column -> role key
    types: dict[str, str]  # column -> plain type label
    target: str | None
    target_expr: str | None  # SQL expression giving 1.0 / 0.0 per row
    target_words: str  # e.g. "cancellation"
    row_noun: str  # e.g. "orders"
    default_group: str | None
    values: dict[str, list[str]] = field(default_factory=dict)  # group column -> known values


def _singular(word: str) -> str:
    if word.endswith("ies") and len(word) > 4:
        return word[:-3] + "y"
    if word.endswith("es") and word[:-2].endswith(("ss", "sh", "ch", "x")):
        return word[:-2]
    if word.endswith("s") and not word.endswith("ss") and len(word) > 3:
        return word[:-1]
    return word


_SYNONYMS = {
    "state": ["state", "region", "province"],
    "location": ["location", "city", "place", "where"],
    "category": ["category", "product", "segment"],
    "type": ["type", "kind", "channel", "method"],
    "date": ["date", "day", "time", "when"],
    "amount": ["amount", "value", "revenue", "sales", "spend", "money", "price"],
}

_GENERIC = {"id", "the", "of", "flag", "is", "ts", "txn", "no", "num", "code"}


def _column_tokens(col: str) -> set[str]:
    parts = [p.lower() for p in re.split(r"[^A-Za-z0-9]+", col) if p]
    toks = {p for p in parts if p not in _GENERIC}
    out = set(toks)
    for t in toks:
        for key, syns in _SYNONYMS.items():
            if t == key or t in syns:
                out.update(syns)
    return out


_TIME_TOKENS = {"monthly", "month", "daily", "day", "weekly", "week", "yearly", "year", "annual", "date", "time", "when"}


def _question_words(q: str) -> set[str]:
    words = re.findall(r"[a-z0-9]+", q.lower())
    return set(words) | {_singular(w) for w in words}


def _mentions(question: str, candidates: list[str]) -> list[tuple[int, str]]:
    """(position in the question, column) for each group column the question names, first mention first."""
    words = re.findall(r"[a-z0-9]+", question.lower())
    found = []
    for col in candidates:
        exact = {p.lower() for p in re.split(r"[^A-Za-z0-9]+", col) if p} - _GENERIC
        for i, w in enumerate(words):
            if w in exact or _singular(w) in exact:
                found.append((i, col))
                break
    return sorted(found)


def _find_column(q_words: set[str], candidates: list[str]) -> str | None:
    best, best_score = None, 0
    for col in candidates:
        toks = _column_tokens(col)
        exact = {p.lower() for p in re.split(r"[^A-Za-z0-9]+", col) if p} - _GENERIC
        score = 2 * len(exact & q_words) + len((toks - exact) & q_words)
        if score > best_score:
            best, best_score = col, score
    return best


def _label(word: str) -> str:
    return qident(re.sub(r"[^A-Z0-9]+", "_", str(word).upper()).strip("_") or "VALUE")


def _and(where_sql: str, cond: str) -> str:
    return (where_sql + "\n  AND " + cond) if where_sql else "\nWHERE " + cond


class RuleDrafter:
    """Pattern-matching drafter. Deterministic, offline, explainable."""

    def __init__(self, ctx: DraftContext):
        self.ctx = ctx

    # -- helpers -------------------------------------------------------
    def _cols(self, *roles: str) -> list[str]:
        return [c for c, r in self.ctx.columns.items() if r in roles and c != self.ctx.target]

    def _group_cols(self, question: str = "") -> list[str]:
        """Groups to compare by: group and yes/no columns; a code column only when named in full."""
        cols = self._cols("category", "flag")
        q = question.lower()
        cols += [c for c in self._cols("code") if c.replace("_", " ").lower() in q or c.lower() in q]
        return cols

    def _filters(self, q: str, group_col: str | None) -> tuple[list[str], list[str]]:
        where, notes = [], []
        ql = q.lower()
        date_cols = self._cols("date")
        m = re.search(r"\b(19\d{2}|20\d{2})\b", q)
        if m and date_cols:
            d = date_cols[0]
            where.append(f"EXTRACT(year FROM {qident(d)}) = {m.group(1)}")
            notes.append(f"Only rows from {m.group(1)}, using {d}.")
        taken: list[tuple[int, int]] = []
        matches = []
        for col, vals in self.ctx.values.items():
            if col == group_col:
                continue
            for v in vals:
                vl = str(v).lower()
                if len(vl) < 3 or vl in ("unknown", "yes", "no", "true", "false"):
                    continue
                for mm in re.finditer(r"(?<![a-z0-9])" + re.escape(vl) + r"(?![a-z0-9])", ql):
                    matches.append((mm.start(), mm.end(), col, v))
        for start, end, col, v in sorted(matches, key=lambda x: -(x[1] - x[0])):
            if any(start < e and end > s for s, e in taken):
                continue
            taken.append((start, end))
            where.append(f"{qident(col)} = {qstr(v)}")
            notes.append(f"Only rows where {col} is {v}.")
        return where, notes

    # -- main ----------------------------------------------------------
    def draft(self, question: str) -> dict:
        ctx = self.ctx
        q = question.strip()
        ql = q.lower()
        words = _question_words(q)
        noun = ctx.row_noun
        assumptions: list[str] = []

        target_tokens = _column_tokens(ctx.target) if ctx.target else set()
        tw = ctx.target_words.lower()
        target_stem = tw[:5] if len(tw) >= 5 else tw
        mentions_target = bool(ctx.target) and (
            target_stem in ql or bool(target_tokens & words) or "rate" in words or "percent" in words
            or "%" in q or "share" in words or "likely" in words or "proportion" in words
        )
        measures = self._cols("measure")
        measure = _find_column(words, measures) or (measures[0] if measures else None)
        mentions_measure = measure is not None and (
            bool((_column_tokens(measure) - _TIME_TOKENS) & words)
            or bool(words & {"total", "sum", "revenue", "sales", "spend", "average", "avg", "mean", "typical", "value"})
        )
        wants_avg = bool(words & {"average", "avg", "mean", "typical"})

        # Time words count only outside column names ("monthly fee" is a column, not "by month").
        qt = ql
        for col in ctx.columns:
            qt = re.sub(r"\b" + re.escape(col.replace("_", " ").lower()) + r"\b", " ", qt)
        twords = _question_words(qt)
        trend_grain = None
        if re.search(r"\b(trend|over time|time series|season|seasonal|growth)\b", qt) or twords & {"monthly", "month"}:
            trend_grain = "month"
        if twords & {"weekly", "week"}:
            trend_grain = "week"
        if "daily" in twords or re.search(r"\b(per|by|each) day\b", qt):
            trend_grain = "day"
        if twords & {"yearly", "annual", "annually"} or re.search(r"\b(per|by|each) year\b", qt):
            trend_grain = "year"
        if twords & {"quarter", "quarterly"}:
            trend_grain = "quarter"

        top_m = re.search(r"\b(?:top|best|worst|biggest|largest|highest|lowest)\s+(\d{1,3})\b", ql)
        top_n = int(top_m.group(1)) if top_m else (5 if re.search(r"\btop\b", ql) else None)

        group_col = _find_column(words, self._group_cols(q))
        wants_count = bool(re.search(r"\b(how many|count|number of)\b", ql))
        named = _mentions(q, self._group_cols(q))
        second = None
        if len(named) >= 2 and not trend_grain:
            topword = re.search(r"\b(top|best|biggest|largest|highest|lowest|worst|bottom|most|least)\b", ql)
            if topword:
                after = [c for pos, c in named if pos > len(re.findall(r"[a-z0-9]+", ql[:topword.start()]))]
                inner = after[0] if after else named[-1][1]
                outer = next(c for _, c in named if c != inner)
                group_col, second = outer, ("rank", inner)
            else:
                group_col, second = named[0][1], ("pair", named[1][1])

        # Decide the metric.
        if mentions_target and not (mentions_measure and not re.search(r"\brate|percent|share|likely|%", ql)):
            metric = "rate"
        elif mentions_measure and not wants_count:
            metric = "avg" if wants_avg else "sum"
        else:
            metric = "count"

        has_intent = trend_grain or top_n or metric != "count" or wants_count or group_col
        if not has_intent:
            raise FriendlyError(
                "I couldn't turn that into a query yet. Try asking for a rate, a count, a total, "
                "a trend over time or a top 5, and name a column such as "
                + (", ".join(self._group_cols()[:2]) or "one from your column map")
                + "."
            )

        where, filter_notes = self._filters(q, None if trend_grain else group_col)
        assumptions.append(f"Reads {ctx.table}, the approved data.")

        metric_sql, metric_alias, order_hint = self._metric(metric, measure)
        if metric == "rate":
            assumptions.append(f"The rate is the share of {ctx.row_noun} where {ctx.target} is 1.")
        elif metric in ("sum", "avg"):
            assumptions.append(f"{'Averages' if metric == 'avg' else 'Totals'} come from {measure}.")
        assumptions.extend(filter_notes)

        where_sql = ("\nWHERE " + "\n  AND ".join(where)) if where else ""

        if trend_grain:
            dates = self._cols("date")
            if not dates:
                raise FriendlyError("There is no date column, so I can't show a trend. Mark one as Date in step 1.")
            d = dates[0]
            period = f"DATE_TRUNC('{trend_grain}', {qident(d)})"
            date_where = f"{qident(d)} IS NOT NULL"
            where_sql = "\nWHERE " + "\n  AND ".join([date_where] + where)
            cols = [f"CAST({period} AS DATE) AS {_label(trend_grain + '_start')}", f"COUNT(*) AS {_label(noun)}"]
            if metric != "count":
                cols.append(f"{metric_sql} AS {metric_alias}")
            having = f"\nHAVING COUNT(*) >= {MIN_GROUP_ROWS}" if metric == "rate" else ""
            sql = "SELECT " + ",\n       ".join(cols) + f"\nFROM {ctx.table}{where_sql}\nGROUP BY 1{having}\nORDER BY 1"
            if having:
                assumptions.append(f"Periods with fewer than {MIN_GROUP_ROWS} {ctx.row_noun} are left out, because their rates jump around.")
            assumptions.append(f"Each point is one calendar {trend_grain}, taken from {d}.")
            what = {"rate": f"the {tw} rate", "sum": f"total {measure}", "avg": f"average {measure}", "count": f"the number of {noun}"}[metric]
            summary = f"Show {what} for each {trend_grain}."
            return {"sql": sql, "summary": summary, "assumptions": assumptions, "pattern": "trend"}

        if group_col is None:
            group_col = ctx.default_group if ctx.default_group in self._group_cols() else (self._group_cols() or [None])[0]
            if group_col is None:
                raise FriendlyError("There is no column to group by. Mark one as Group to compare in step 1.")
            assumptions.append(f"You didn't name a group, so I used {group_col}.")

        if second is not None:
            return self._two_columns(group_col, second, metric, metric_sql, metric_alias, measure, top_n, where_sql, assumptions, q)
        label = f"COALESCE(CAST({qident(group_col)} AS VARCHAR(2000)), 'Not recorded')"
        select = [f"{label} AS {_label(group_col)}", f"COUNT(*) AS {_label(noun)}"]
        if metric != "count":
            select.append(f"{metric_sql} AS {metric_alias}")
        having = ""
        if metric == "rate":
            having = f"\nHAVING COUNT(*) >= {MIN_GROUP_ROWS}"
            assumptions.append(f"Groups with fewer than {MIN_GROUP_ROWS} {noun} are left out, because their rates jump around.")
        lowest = bool(re.search(r"\b(lowest|least|fewest|smallest|bottom|safest)\b", ql))
        order_col = metric_alias if metric != "count" else _label(noun)
        order = f"\nORDER BY {order_col} {'ASC' if lowest else 'DESC'}"
        limit = f"\nLIMIT {top_n}" if top_n else ""
        if top_n:  # an unknown value can't be a "top" value: leave those rows out of a ranking
            where_sql = _and(where_sql, f"{qident(group_col)} IS NOT NULL")
            assumptions.append(f"Rows with no {group_col} are left out of the ranking.")
        sql = "SELECT " + ",\n       ".join(select) + f"\nFROM {ctx.table}{where_sql}\nGROUP BY 1{having}{order}{limit}"

        what = {"rate": f"the {tw} rate", "sum": f"total {measure}", "avg": f"average {measure}", "count": f"the number of {noun}"}[metric]
        if top_n:
            summary = f"Find the {'bottom' if lowest else 'top'} {top_n} values of {group_col} by {what}."
        else:
            summary = f"Compare {what} for each {group_col}."
        return {"sql": sql, "summary": summary, "assumptions": assumptions, "pattern": f"{metric}_by_group" + ("_top" if top_n else "")}

    def _two_columns(self, outer, second, metric, metric_sql, metric_alias, measure, top_n, where_sql, assumptions, q):
        ctx = self.ctx
        kind, inner = second
        noun = ctx.row_noun
        a = f"COALESCE(CAST({qident(outer)} AS VARCHAR(2000)), 'Not recorded')"
        b = f"COALESCE(CAST({qident(inner)} AS VARCHAR(2000)), 'Not recorded')"
        cols = [f"{a} AS {_label(outer)}", f"{b} AS {_label(inner)}", f"COUNT(*) AS {_label(noun)}"]
        if metric != "count":
            cols.append(f"{metric_sql} AS {metric_alias}")
        rank_by = metric_alias if metric != "count" else _label(noun)
        what = {"rate": f"the {ctx.target_words} rate", "sum": f"total {measure}", "avg": f"average {measure}", "count": f"the number of {noun}"}[metric]
        if metric == "count":
            money = next((m for m in self._cols("measure") if re.search(r"amount|revenue|sales|value|price", m, re.I)
                          and not re.search(r"list|unit", m, re.I)), measure)
            assumptions.append(f"Ranked by the number of {noun}. Say \"by total {money.lower().replace('_', ' ') if money else 'amount'}\" to rank by money instead.")
        if metric == "rate":
            assumptions.append(f"Combinations with fewer than {MIN_GROUP_ROWS} {noun} are left out, because their rates jump around.")
        having = f"\nHAVING COUNT(*) >= {MIN_GROUP_ROWS}" if metric == "rate" else ""
        if kind == "pair":
            sql = ("SELECT " + ",\n       ".join(cols) + f"\nFROM {ctx.table}{where_sql}\nGROUP BY 1, 2{having}"
                   f"\nORDER BY 1, {rank_by} DESC")
            return {"sql": sql, "summary": f"Show {what} for every {outer} and {inner} combination.",
                    "assumptions": assumptions, "pattern": "two_groups"}
        n = top_n or 3
        # "top hour per type": rows with no hour are not an hour, so they can't win the ranking
        where_sql = _and(where_sql, f"{qident(inner)} IS NOT NULL")
        assumptions.append(f"Rows with no {inner} are left out: an unknown {inner} can't be a top {inner}.")
        if not top_n:
            assumptions.append(f"Shows the top {n} per {outer}. Say \"top 5\" for more.")
        inner_sql = ("SELECT " + ",\n         ".join(cols) + f",\n         ROW_NUMBER() OVER (PARTITION BY {a} ORDER BY "
                     + (metric_sql if metric != "count" else "COUNT(*)") + f" DESC) AS {_label('rank')}"
                     + f"\n  FROM {ctx.table}{where_sql.replace(chr(10), chr(10) + '  ')}\n  GROUP BY 1, 2{having}")
        sql = f"SELECT *\nFROM (\n  {inner_sql}\n)\nWHERE {_label('rank')} <= {n}\nORDER BY {_label(outer)}, {_label('rank')}"
        return {"sql": sql, "summary": f"Find the top {n} values of {inner} in each {outer}, by {what}.",
                "assumptions": assumptions, "pattern": "top_per_group"}

    def _metric(self, metric: str, measure: str | None) -> tuple[str, str, str]:
        ctx = self.ctx
        if metric == "rate":
            return f"ROUND(100 * AVG({ctx.target_expr}), 2)", _label(f"{ctx.target_words}_rate_pct"), "rate"
        if metric == "sum":
            return f"ROUND(SUM({qident(measure)}), 2)", _label(f"total_{measure}"), "sum"
        if metric == "avg":
            return f"ROUND(AVG({qident(measure)}), 2)", _label(f"avg_{measure}"), "avg"
        return "COUNT(*)", _label(ctx.row_noun), "count"


# The column map's roles in the drafter's words (descriptor roles: exakit_nb.describe.COLUMN_ROLES).
ROLE_WORDS = {"key": "id", "time": "date", "measure": "measure", "category": "category", "flag": "flag",
              "text": "text", "identifier": "code", "other": "ignore"}
VALUE_LIMIT = 60                       # a group column with more distinct values is not offered as a filter


def _bare(col: str | None) -> str | None:
    return col.strip('"').split(".")[-1].strip('"') if col else None


def _target_words(ds) -> str:
    target = _bare(ds.col("label")) if ds.has("label") else ""
    return re.sub(r"^(is|has)_", "", target.lower()).replace("_", " ") if target else "yes"


def context_for(conn, ds) -> DraftContext:
    """What the drafter knows: the dataset's roles (sensitive columns left out), its target, and the values of its
    group columns (up to VALUE_LIMIT each, read from the table)."""
    from .readout import noun

    cols = dict(getattr(ds.descriptor, "columns", {}) or {})
    target = _bare(ds.col("label")) if ds.has("label") else None
    roles = {c: ("ignore" if e.get("sensitive") else ROLE_WORDS.get(e.get("role"), "ignore")) for c, e in cols.items()}
    values: dict[str, list[str]] = {}
    for column, role in roles.items():
        if role in ("category", "flag") and column != target:
            rows = conn.execute(f'SELECT DISTINCT CAST({qident(column)} AS VARCHAR(2000)) FROM {ds.fact_table} '
                                f'WHERE {qident(column)} IS NOT NULL LIMIT {VALUE_LIMIT + 1}').fetchall()
            if len(rows) <= VALUE_LIMIT:
                values[column] = [r[0] for r in rows]
    group = _bare(ds.group_by()[1]) if ds.group_by() else None
    return DraftContext(table=ds.fact_table, columns=roles, types={}, target=target,
                        target_expr=f"CAST({qident(target)} AS DOUBLE)" if target else None,
                        target_words=_target_words(ds), row_noun=noun(ds),
                        default_group=group if roles.get(group) in ("category", "flag") else None, values=values)


def draft_question(conn, ds, question: str):
    """A Proposal for ``question`` drafted by rules from the column map (no AI model): read-only SQL, with the
    drafter's assumptions, not approved yet. Approve and run it as any proposal."""
    from .ask import ask

    drafted = RuleDrafter(context_for(conn, ds)).draft(question)
    proposal = ask(ds, question, proposed_sql=ensure_read_only(drafted["sql"]))
    proposal.assumptions = list(drafted.get("assumptions") or [])
    if drafted.get("summary"):
        proposal.doubts = [*proposal.doubts, drafted["summary"]]
    return proposal


def example_questions(ds) -> list[str]:
    """Up to three questions this dataset's approved roles can answer, in its own column names."""
    cols = dict(getattr(ds.descriptor, "columns", {}) or {})
    target = _bare(ds.col("label")) if ds.has("label") else None
    group = _bare(ds.group_by()[1]) if ds.group_by() else None
    measures = [c for c, e in cols.items() if e.get("role") == "measure"]
    others = [c for c, e in cols.items() if e.get("role") == "category" and c not in (group, target) and not e.get("sensitive")]
    words = _target_words(ds)
    nice = lambda c: c.replace("_", " ").lower()

    def plural(c: str) -> str:
        w = nice(c)
        return w[:-1] + "ies" if w.endswith("y") and not w.endswith(("ay", "ey", "oy")) else (w if w.endswith("s") else w + "s")
    out = []
    if target and group:
        out.append(f"Which {nice(group)} has the highest {words} rate?")
    if target and ds.has("date"):
        out.append(f"How has the {words} rate changed by month?")
    if measures and (others or group):
        out.append(f"Top 5 {plural(others[0] if others else group)} by total {nice(measures[0])}")
    if not out and group:
        out.append(f"How many rows are there per {nice(group)}?")
    return out[:3]
