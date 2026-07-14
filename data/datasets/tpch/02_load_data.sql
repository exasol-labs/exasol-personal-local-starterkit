-- 02_load_data.sql - post-load transformations.
-- setup/load-data.sh runs this (if non-empty) after every data/*.csv has
-- been bulk-loaded by exapump into its matching TPCH table. The
-- TPC-H sample data is already clean and self-consistent (see
-- data/README.md), so there is nothing to transform, dedupe, or backfill
-- here today. Kept as a real, working statement (not an empty file) so the
-- step exercises the same exapump SQL-file code path as every other kit
-- deliverable, and so a future dataset with real transform needs has a
-- ready-made place to add them.
OPEN SCHEMA TPCH;
SELECT 'TPCH sample data loaded - no post-load transform required.' AS STATUS;
