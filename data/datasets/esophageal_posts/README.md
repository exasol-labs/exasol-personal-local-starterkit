# esophageal_posts - public posts about esophageal cancer, de-identified

A snapshot of **40,987 public posts about esophageal cancer** published between
January 2018 and September 2022 on the web (blogs, forums), Twitter, in print
and on TV, from a social-listening export. Every post carries the listening
tool's sentiment, so the question "which posts are negative?" has an answer in
the data: 6,466 of them (15.8%) are.

```bash
exakit data-load esophageal_posts
```

It loads into the `ESOPHAGEAL` schema (28 MB of CSV). An installed kit
downloads the CSV first, as one checksummed archive (see [Download](#download)).

## What was removed

The export is shipped **de-identified**. `tools/datasets/esophageal_posts.py`
drops everything that identifies or profiles a person or an account:

- the sender's user id, screen name, listed name, profile image and profile
  link, follower count, influencer score, age and gender;
- the location below the country: location text, state, city, latitude and
  longitude;
- the message, conversation and parent ids and the permalinks, which embed
  tweet ids and lead back to the account;
- a website or a posting app used by fewer than 10 posts (left empty), so a
  personal blog or one account's own posting tool does not name its author.

Inside the title and the message, `@handles` become `@user`, links become `URL`
and e-mail addresses become `EMAIL`; forum markup that names a member goes too - a
quote's attribution (`[quote=Name;id]`) becomes `[QUOTE]`, member and post numbers
are dropped, the name in a quote's `Name said: ↑ ... Click to expand` header and in
`Posted by Name` becomes `user`, a Reddit `u/name` becomes `u/user` - and phone
numbers become `PHONE` (a helpline's too: a personal number cannot be told apart); the message is cut on a word at 1,000
characters. Columns that were empty or one value throughout (33 of the 67) and
the export's duplicate columns are left out. Posts are numbered in time order;
the number is not the source's id.

The text is still people's own words about an illness, and forum posts can name
first names and family details. Treat it as sensitive, and see the terms below.

## Tables

| Table | Rows | One row is |
|---|---:|---|
| `ESOPHAGEAL.ESOPHAGEAL_POSTS` | 40,987 | a post |

## Data dictionary

`ESOPHAGEAL_POSTS`

| Column | Type | Meaning |
|---|---|---|
| `POST_ID` | DECIMAL(9,0) | post number in time order (primary key); not the source's id |
| `CREATED_TIME` | TIMESTAMP | when the post was published (2018-01-16 to 2022-09-30) |
| `SOCIAL_NETWORK` | VARCHAR(20) | `WEB` (19,652), `TWITTER` (15,487), `PRINT` (3,588), `TV` (2,252), `WORDPRESS`, `RADIO` |
| `MESSAGE_TYPE` | VARCHAR(40) | `Blog Post`, `Twitter Update`, `Forums`, `Twitter Reply`, `Print News`, `Twitter Mention`, `TV News` and six rarer kinds |
| `IS_REPLY` | DECIMAL(1,0) | 1 when the post answers another post in the export (877) |
| `LANGUAGE` | VARCHAR(40) | language of the post (English for 40,391) |
| `COUNTRY` | VARCHAR(60) | country the listening tool assigned (United States, United Kingdom and five more) |
| `SOURCE_DOMAIN` | VARCHAR(100) | website it came from, when 10 or more posts share it; empty otherwise |
| `MEDIA_TYPES` | VARCHAR(300) | media attached: `LINK`, `PHOTO`, `VIDEO`, comma-separated |
| `CLIENT_APP` | VARCHAR(60) | app a tweet was made with, when 10 or more posts share it; empty otherwise |
| `RETWEETS` | DECIMAL(9,0) | times it was shared |
| `FAVORITES` | DECIMAL(9,0) | times it was liked |
| `SENTIMENT` | VARCHAR(10) | `NEUTRAL` (29,941), `NEGATIVE` (6,466) or `POSITIVE` (4,580), as the listening tool scored it |
| `IS_NEGATIVE` | DECIMAL(1,0) | 1 when `SENTIMENT` is `NEGATIVE`, else 0 - **the label** |
| `TITLE` | VARCHAR(300) | title of a blog post, article or thread, when it has one |
| `MESSAGE` | VARCHAR(1000) | text of the post, cut at 1,000 characters, handles, links, e-mail addresses, phone numbers and forum member names replaced |

The label comes from the listening tool's sentiment model, not from a person:
a model trained on it learns that tool's judgement.

## The descriptor

[`descriptor.yaml`](descriptor.yaml) tells the persona notebooks which column
plays each role:

| Role | Column | Why |
|---|---|---|
| entity | `SOURCE_DOMAIN` | the website a post came from |
| category | `MESSAGE_TYPE` | the grouping to compare |
| date | `CREATED_TIME` | when the post was published |
| label | `IS_NEGATIVE` | the outcome a model predicts |
| text | `TITLE`, `MESSAGE` | free text for the model and the text step, joined in this order |

## Example questions

[`examples.sql`](examples.sql) has twelve queries, each runnable as it stands:
posts and negativity by source, the sentiment split, posts per quarter,
negativity by kind of post, the busiest websites, countries and languages,
media and sharing, the most shared tweets, posting apps, treatment words,
message length and replies.

## Source, terms and reproducibility

- **Source:** a social-listening export provided by the kit owner
  (`Esophageal.xlsx`, sheet `Stream-Data-1`); its file name and SHA-256 are in
  [`manifest.json`](manifest.json).
- **Terms:** unknown. The posts are third-party content collected by a
  listening tool; Twitter's terms in particular restrict redistributing tweets.
  **Redistribution in the kit is still to be confirmed by the owner**
  (`terms.confirmed` in the manifest); until then this dataset is a release
  blocker.
- **Rebuild:** `python3 tools/datasets/esophageal_posts.py <path to the .xlsx>`
  (needs `openpyxl`) rewrites the CSV and the manifest from the same export; the
  same file gives the same CSV.
- **Transformations:** as listed under [What was removed](#what-was-removed);
  whitespace folded, titles cut at 300 characters; nothing else is changed.

## Download

The CSV is in this folder in the repository, but not in the kit archive the
installer downloads: `exakit data-load esophageal_posts` fetches it as one
release asset, `esophageal_posts-<snapshot>.tar.gz`, whose SHA-256, size and URL
are in [`manifest.json`](manifest.json) (`asset`). The archive is checked
against that digest and the CSV against its own before anything is loaded, and
the verified file is kept under
`~/.exasol-starter-kit/cache/datasets/esophageal_posts/`. Offline, point
`EXAKIT_DATASETS_MIRROR` at a folder (or an `https://` URL) holding the archive.
`python3 tools/datasets/package.py esophageal_posts` rebuilds the archive and
the manifest's `asset` block.
