# First workflow — revenue analysis you can trust

This is the kit's core loop, done once, end to end: **ask → inspect the SQL → run → validate → rerun**. It takes about 10 minutes and ends with an answer you didn't just receive — you *checked* it.

## Before you start

1. Kit installed and healthy: `exakit status` says `running`
2. AI assistant connected (see your OS quickstart or [QUICKSTART.md](../QUICKSTART.md) step 4)
3. Sample data loaded (the installer offers this; run it yourself any time with):
   ```bash
   exakit data-load
   ```
   You can also point the workflow at any data you upload yourself (`exapump upload yourfile.csv --table STARTER_KIT.MYDATA -p starter-kit`).

The bundled sample is the standard **TPC-H** dataset (a wholesale supplier model). For every table and column — and the kit's definition of "revenue" — see [`data/data-dictionary.md`](../data/data-dictionary.md); for more ready-made questions with validated SQL, see [`data/example-questions.md`](../data/example-questions.md).

## Step 1 — Discover (let the assistant look around)

Paste into your assistant:

> What schemas and tables are available in my Exasol database? For the tables in the TPCH schema, describe their columns and how they relate to each other.

The assistant uses the MCP server's metadata tools — no SQL runs yet. You should see the eight TPC-H tables — `CUSTOMER`, `ORDERS`, `LINEITEM`, `PART`, `SUPPLIER`, `PARTSUPP`, plus `NATION` and `REGION` — with their columns. This step matters: the assistant grounds itself in the *real* schema instead of guessing.

## Step 2 — Ask, but see the SQL first

> Which product type generated the most revenue? **Show me the SQL you intend to run and explain it before executing.**

That bolded instruction is the habit this kit teaches. In TPC-H the closest thing to a "product category" is a part's **type** (`PART.P_TYPE`, e.g. *PROMO BURNISHED COPPER*), so the assistant should join `LINEITEM` to `PART` and sum revenue per `P_TYPE`. It should reply with a query and an explanation — read it before anything runs. Things worth actually checking:

- Which columns define "revenue"? (the kit convention is `L_EXTENDEDPRICE * (1 - L_DISCOUNT)` — line price net of discount)
- Is tax (`L_TAX`) included? (the convention above excludes it)
- Are returned line items (`L_RETURNFLAG = 'R'`) subtracted, or is this gross revenue?
- Is anything filtered out (date ranges via `O_ORDERDATE`)?

A correct query looks like this — inspect it, don't just run it:

```sql
SELECT p.P_TYPE,
       SUM(l.L_EXTENDEDPRICE * (1 - l.L_DISCOUNT)) AS REVENUE
FROM   TPCH.LINEITEM l
JOIN   TPCH.PART p ON p.P_PARTKEY = l.L_PARTKEY
GROUP  BY p.P_TYPE
ORDER  BY REVENUE DESC
LIMIT  10;
```

If you disagree with a choice, say so — e.g. *"exclude returned line items — add `WHERE l.L_RETURNFLAG <> 'R'` — then show me the revised SQL."* Iterate until the SQL says what *you* mean by revenue.

## Step 3 — Run

Tell the assistant to execute. The MCP server is read-only, so the worst any query can do is read data. You get the result table in the conversation.

## Step 4 — Validate independently (the trust step)

Don't take the assistant's number on faith — reproduce it yourself, outside the assistant, with the SQL you just inspected:

```bash
exapump sql -p starter-kit "<paste the approved SQL here>"
```

Same number? That's the point of the whole kit: the AI's answer is now *your* answer, verified through an independent path. (Also try changing one thing — a filter, a grouping — and see the number move the way you'd expect.)

## Step 5 — Make it rerunnable

Save the outcome so it survives beyond this chat session. Two lightweight options today:

1. **Save the SQL** to a file and rerun any time:
   ```bash
   mkdir -p ~/.exasol-starter-kit/workflows
   # paste the approved SQL into revenue-by-type.sql, then:
   exapump sql -p starter-kit < ~/.exasol-starter-kit/workflows/revenue-by-type.sql
   ```
2. **Record the workflow** — the file next to this guide, [`first-revenue-analysis.workflow.json`](first-revenue-analysis.workflow.json), captures this session (question, approved SQL, validation) in a structured, rerunnable form. Use it as the template for your own.

## Where to go next

- Ask a harder question — *"monthly revenue trend by region, top 3 nations only"* — and hold the same discipline: SQL first, validate after
- Bring your own data: `exapump upload data.csv --table STARTER_KIT.MYTABLE -p starter-kit`, then ask about it
- If something misbehaves: `exakit status`, `exakit logs`, and the troubleshooting table in the [README](../README.md)
