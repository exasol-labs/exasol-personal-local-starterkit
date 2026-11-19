"""A stand-in for upstream exasol_json_tables, for the kit's tests: the five calls the kit's module generator
(setup/preprocessor/modules/json-tables/generate.py) makes, with upstream's names and signatures. The catalog read
is upstream's own SQL shape (SYS.EXA_ALL_TABLES, then each helper schema's __JVS_ROOTS), so it exercises the
generator's exapump connection against tests/lib/fake-exapump.py; the library and the configuration are small
markers that say what went in. The real upstream is checked live, not here."""
