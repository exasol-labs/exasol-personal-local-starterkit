# Semantic fusion (/kit/data/semantic-fusion)



Your data lives in more than one place: a database here, files there, a cloud source somewhere else. The usual answer is to copy everything into one store first (ETL). The kit does not. It reads each source where it is, agrees once on what the data means, and answers from that. Only answers travel back.

<Flow
  caption="Sources stay where they are. One model gives them one meaning."
  steps="[
  { title: &#x22;Sources&#x22;, text: &#x22;A PostgreSQL database, your files, sample data. Nothing is copied&#x22;, tone: &#x22;db&#x22;, href: &#x22;/kit/data/load-data&#x22; },
  { title: &#x22;Connect&#x22;, text: &#x22;An external source becomes a virtual schema, read live&#x22;, code: &#x22;exakit connect postgresql&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;Agree on meaning&#x22;, text: &#x22;You approve what each column is&#x22;, code: &#x22;exakit describe ... --approve&#x22;, tone: &#x22;you&#x22;, href: &#x22;/kit/data/column-maps&#x22; },
  { title: &#x22;Fuse&#x22;, text: &#x22;Links found from the values, one semantic model over all of it&#x22;, code: &#x22;exakit describe --model ... --find-links&#x22;, tone: &#x22;kit&#x22;, href: &#x22;/kit/data/semantic-views&#x22; },
  { title: &#x22;Use&#x22;, text: &#x22;Notebooks, AI clients and dashboards ask the same model&#x22;, tone: &#x22;you&#x22; },
]"
/>

## The four layers [#the-four-layers]

| Layer          | What it does                                                                             | Where the data is         |
| -------------- | ---------------------------------------------------------------------------------------- | ------------------------- |
| Connectors     | A virtual schema (`VS_<NAME>`) per external source. A query is pushed down to the source | Stays in the source       |
| Column maps    | Each column gets a role: key, time, measure, category. You approve it                    | Nothing moves             |
| Semantic model | Tables become entities, links become relationships, measures become metrics              | Definitions only, no rows |
| Answers        | Semantic SQL is compiled into one query over the live sources                            | Only the result returns   |

## An example, measured [#an-example-measured]

Three sources that share no key and no column names: Amazon order lines (sample data, 128,975 rows), a PostgreSQL logistics database read live, and a state population table.

**1. Find how they join.** No foreign key exists. The kit compares values:

```bash
exakit describe --links AMAZON,VS_LOGISTICS,RETAIL_SIGNALS
```

```text
[high] AMAZON.ORDER_LINES.SHIP_STATE -> VS_LOGISTICS.STATE_LOGISTICS.SHIP_STATE:
       128,921 of 128,942 rows match; 21 do not (ORISSA, RAJSHTHAN, ...)
```

The 21 rows are misspelt state names. The link stands, and you get the list to clean. It took 26 small queries.

**2. Put one model over them.**

```bash
exakit describe --model sales_360 --schemas AMAZON,RETAIL_SIGNALS --find-links
```

This published one model over the order lines and the state table, joined on the state name, a link found the same way. Why the link is there is stored with it. (The run was measured under a test model name; `sales_360` stands for it here. The PostgreSQL source was not reachable when the model was published, so its link from step 1 is not in these figures.)

**3. Ask it.** Revenue by region needs both sources. In Semantic SQL you name what you want, not how to join:

```sql
SELECT region, order_lines_count, total_amount
FROM SEM_SALES_360.ORDER_LINES GROUP BY region
```

| Region | Order lines | Revenue       |
| ------ | ----------- | ------------- |
| South  | 52,761      | 31,314,207.29 |
| North  | 30,148      | 19,245,528.38 |
| West   | 27,956      | 16,744,010.73 |

The model compiled that into one scan, one join and one `GROUP BY`. A hand-written join returned the same figures for all 128,975 rows.

## Who uses the model [#who-uses-the-model]

<Flow
  caption="One model, three ways to ask it"
  steps="[
  { title: &#x22;A notebook&#x22;, text: &#x22;Ask in plain language. The AI writes Semantic SQL, you approve the SQL&#x22;, code: &#x22;nb.ask(dataset, question, conn=connection)&#x22;, tone: &#x22;you&#x22;, href: &#x22;/data-scientist/explore/questions&#x22; },
  { title: &#x22;An AI client&#x22;, text: &#x22;Claude Code, Codex, Cursor read the model over a read-only connection&#x22;, tone: &#x22;ai&#x22;, href: &#x22;/kit/tools/ai-clients-and-skills&#x22; },
  { title: &#x22;A dashboard&#x22;, text: &#x22;A checked result becomes a live page on Dash Server&#x22;, code: &#x22;03_share&#x22;, tone: &#x22;kit&#x22;, href: &#x22;/data-scientist/communicate&#x22; },
]"
/>

All three read the same definitions, so *revenue* is the same number everywhere.

## What it costs [#what-it-costs]

| Measured                                        | Result                                        |
| ----------------------------------------------- | --------------------------------------------- |
| Model query on 10,002,745 rows joined to 30,000 | 0.12 to 0.27 s (hand-written: 0.13 to 0.21 s) |
| Finding links across six schemas, 25 tables     | 223 small queries, about 60 s                 |
| Rows copied out of a source                     | 0                                             |

A live source answers at its own speed. Each query to it is a filter or an aggregate the source runs itself.

## The same pattern, larger [#the-same-pattern-larger]

The hospital chain reference build uses this pattern on three systems that share no patient id: a legacy system on PostgreSQL, a health record on MongoDB and an imaging archive on Amazon S3. Exasol reads all three in place, resolves 1,609 patient records to 1,223 people, and answers a question across them in 0.3 to 4 seconds. The images never pass through the database.

## Limits [#limits]

* A link between two plain number columns cannot be proven from the data: numbers in a sequence match by chance. The kit marks it for you to confirm.
* A table needs an approved column map before it joins a model.
* A source that is down cannot be asked. Nothing is cached unless you load a copy yourself.

## Further reading [#further-reading]

* [Semantic views](/kit/data/semantic-views): the commands
* [Links across sources](/data-scientist/explore/semantic-views#links-across-sources): how links are found and what was measured
* [Virtual schemas](https://docs.exasol.com/db/latest/database_concepts/virtual_schemas.htm) in the Exasol documentation
* [Exasol Semantic Views](https://github.com/exasol-labs/exasol-semantic-views) on GitHub
