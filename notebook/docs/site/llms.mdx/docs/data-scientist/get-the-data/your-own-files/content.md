# Your own file (/data-scientist/get-the-data/your-own-files)



Your own file becomes a table in the database. The file is copied in, so queries run on the copy and not on the file. If the table is already in the database, you can use it without a copy.

## Load a file or a folder [#load-a-file-or-a-folder]

The shared cells of `00_quickstart` take a file or a folder, a schema and an optional table:

```python
MY_DATA = "~/sales-data/orders.csv"   # a file or a folder; "" skips it
MY_SCHEMA = ""                        # empty: the folder's name, so ~/sales-data becomes SALES_DATA
MY_TABLE = ""                         # or a table already in the database, e.g. "MY_DATA.ORDERS"
own_data = (nb.use_table(connection, MY_TABLE) if MY_TABLE
            else nb.load_own_file(MY_DATA, MY_SCHEMA, conn=connection, missing_ok=True))
```

For a file called `orders.csv` in a folder called `sales-data`, with no schema named, the table is `SALES_DATA.ORDERS`. The table takes its name from the file.

To call the helper directly, use `nb.load_own_file(path, schema, conn=connection)`.

## What the load accepts [#what-the-load-accepts]

* **CSV, Parquet and JSON** work. JSON can be an array of records or one record per line. A nested value is kept as JSON text.
* **Excel** works too. The kit makes a CSV or UTF-8 copy next to your file and says so. Your original is not changed.
* **A folder** loads every CSV, Parquet and JSON file at its top level, one table per file, each named after its file. Subfolders are skipped. The schema is asked once.
* **Running it again is safe.** A file already loaded is not loaded twice. A file that changed is loaded again. The table keeps the file's SHA-256 in its comment, so the kit can tell.

## How the columns are prepared [#how-the-columns-are-prepared]

When the kit loads a file, it prepares the columns this way:

* Column names become plain upper-case SQL names. Other characters become `_`. A name that starts with a digit gets a `C_` prefix.
* Columns with the same name after this change stop the load. Rename them in the file.
* Text that looks like dates (9 in 10 values parse as dates) is stored as `DATE`.
* True and false values become `0` and `1`. Whole numbers become `DECIMAL(18,0)`. Other numbers become `DOUBLE`. Text becomes `VARCHAR` as wide as its longest value.
* A file with no rows is refused.

## Use a table that is already there [#use-a-table-that-is-already-there]

`nb.use_table(connection, "MY_DATA.ORDERS")` uses a table that is in the database. `nb.data_map(connection)` lists the tables, and the kit's own schemas are left out unless you pass `include_kit=True`. See [The data map](/data-scientist/get-the-data/the-data-map).

If a table's columns kept names with spaces or small letters, such as `Won` or `Opportunity ID`, the kit's queries cannot read them directly. The kit then creates a view with plain names in `EXAKIT_PREPARED` and uses that view. Your table is not changed. The view is named `EXAKIT_PREPARED."<SCHEMA>__<TABLE>__PLAIN"`.

## Roles written beside a file [#roles-written-beside-a-file]

You can describe your file's roles by hand, instead of reviewing the kit's proposal. Pass a mapping of role to column to `nb.load_own_file(..., descriptor={...})`. The kit writes the roles next to the file as `<name>.descriptor.yaml`, so `DATASET = "<the file>"` in a notebook opens it again.

The roles are a draft until you approve them. The approval is covered in [Explore and understand](/data-scientist/explore).

Back to [Get the data](/data-scientist/get-the-data). Next: [External sources](/data-scientist/get-the-data/external-sources).
