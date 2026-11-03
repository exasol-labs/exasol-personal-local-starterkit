-- 01_create_schema.sql - esophageal cancer posts (a de-identified social-listening export).
-- Loads into its own ESOPHAGEAL schema; the dedicated read-only MCP user reads it
-- via database-wide read (USE ANY SCHEMA + SELECT ANY TABLE), no per-schema
-- grant. The table keeps the ESOPHAGEAL_ prefix so fully-qualified names stay clear.
-- What the snapshot holds, where it came from and what was removed: README.md and manifest.json.
--
-- Idempotent: CREATE OR REPLACE TABLE means this can be re-run (e.g. via
-- exakit data-load --force) without manual cleanup.

CREATE SCHEMA IF NOT EXISTS ESOPHAGEAL;
OPEN SCHEMA ESOPHAGEAL;

-- esophageal_posts (one row per post, from data/esophageal_posts.csv). PK: post_id.
CREATE OR REPLACE TABLE ESOPHAGEAL_POSTS (
    POST_ID         DECIMAL(9,0)  NOT NULL,
    CREATED_TIME    TIMESTAMP     NOT NULL,
    SOCIAL_NETWORK  VARCHAR(20)   NOT NULL,   -- WEB / TWITTER / PRINT / TV / ...
    MESSAGE_TYPE    VARCHAR(40)   NOT NULL,   -- Blog Post / Twitter Update / Forums / ...
    IS_REPLY        DECIMAL(1,0)  NOT NULL,   -- 1 when the post answers another post
    LANGUAGE        VARCHAR(40)   NOT NULL,
    COUNTRY         VARCHAR(60)   NOT NULL,
    SOURCE_DOMAIN   VARCHAR(100),             -- kept only where 10 or more posts share it
    MEDIA_TYPES     VARCHAR(300),             -- LINK / PHOTO / VIDEO, comma-separated
    CLIENT_APP      VARCHAR(60),              -- the posting app, kept only where 10 or more posts share it
    RETWEETS        DECIMAL(9,0)  NOT NULL,
    FAVORITES       DECIMAL(9,0)  NOT NULL,
    SENTIMENT       VARCHAR(10)   NOT NULL,   -- NEUTRAL / NEGATIVE / POSITIVE, from the listening tool
    IS_NEGATIVE     DECIMAL(1,0)  NOT NULL,   -- 1 when SENTIMENT is NEGATIVE: the label
    TITLE           VARCHAR(300),
    MESSAGE         VARCHAR(1000),            -- cut at 1,000 characters; handles, links and e-mails replaced
    CONSTRAINT ESOPHAGEAL_POSTS_PK PRIMARY KEY (POST_ID)
);

-- Semantics travel WITH the tables (see the note in tpch/01_create_schema.sql):
-- the MCP describe path reads these comments. COMMENT is idempotent.

COMMENT ON TABLE  ESOPHAGEAL_POSTS IS 'Public posts about esophageal cancer, 2018-2022, from a social-listening export, de-identified: no person, account or location below the country. PK post_id.';
COMMENT ON COLUMN ESOPHAGEAL_POSTS.POST_ID IS 'Post number in time order (PK); not the source''s id';
COMMENT ON COLUMN ESOPHAGEAL_POSTS.CREATED_TIME IS 'When the post was published';
COMMENT ON COLUMN ESOPHAGEAL_POSTS.SOCIAL_NETWORK IS 'Where it was published: WEB, TWITTER, PRINT, TV and others';
COMMENT ON COLUMN ESOPHAGEAL_POSTS.MESSAGE_TYPE IS 'Kind of post: blog post, tweet, reply, forum post, news article and others';
COMMENT ON COLUMN ESOPHAGEAL_POSTS.IS_REPLY IS '1 when the post answers another post in the export';
COMMENT ON COLUMN ESOPHAGEAL_POSTS.LANGUAGE IS 'Language of the post';
COMMENT ON COLUMN ESOPHAGEAL_POSTS.COUNTRY IS 'Country the listening tool assigned to the post';
COMMENT ON COLUMN ESOPHAGEAL_POSTS.SOURCE_DOMAIN IS 'Website it came from, when 10 or more posts share it (null otherwise)';
COMMENT ON COLUMN ESOPHAGEAL_POSTS.MEDIA_TYPES IS 'Media attached: LINK, PHOTO, VIDEO, comma-separated';
COMMENT ON COLUMN ESOPHAGEAL_POSTS.CLIENT_APP IS 'App the post was made with, when 10 or more posts share it (null otherwise)';
COMMENT ON COLUMN ESOPHAGEAL_POSTS.RETWEETS IS 'Times it was shared (retweets)';
COMMENT ON COLUMN ESOPHAGEAL_POSTS.FAVORITES IS 'Times it was liked';
COMMENT ON COLUMN ESOPHAGEAL_POSTS.SENTIMENT IS 'NEUTRAL, NEGATIVE or POSITIVE, as the listening tool scored it';
COMMENT ON COLUMN ESOPHAGEAL_POSTS.IS_NEGATIVE IS '1 when SENTIMENT is NEGATIVE, else 0 (the label to predict from the text)';
COMMENT ON COLUMN ESOPHAGEAL_POSTS.TITLE IS 'Title of a blog post, article or thread, when it has one';
COMMENT ON COLUMN ESOPHAGEAL_POSTS.MESSAGE IS 'Text of the post, cut at 1,000 characters; @handles, links and e-mail addresses replaced';
