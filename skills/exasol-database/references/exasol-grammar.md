# Exasol SQL Statement Grammar (DQL / DML / DDL / DCL / DAL)

> **Source of truth.** The supported Exasol SQL **statement** grammar used by
> the database skill, in EBNF, derived from
> [`exasol/sql-statement-builder`](https://github.com/exasol/sql-statement-builder) — the same source
> the syntax-diagram images on docs.exasol.com are generated from (via
> `Ebnf2ps`). Prefer these rules over inferring syntax from examples: they
> define legal clauses, their ordering, and their repetition.
>
> Native `IMPORT` and `EXPORT` workflow grammar is intentionally excluded from
> this database-skill reference. Use **exasol-import** and **exasol-export** for
> those workflows.
>
> **Companion file:** built-in **functions**, operators, **predicates**,
> **literals**, and **data types** live in
> [`exasol-grammar-functions.md`](exasol-grammar-functions.md). Load that instead
> when you need a function signature or an expression / predicate / literal form.
>
> ⚠ **Read only the section you need.** This reference is large — jump to the
> relevant `##` heading (grep or Read that section) rather than loading the whole
> file into context.
>
> - **DB version:** branch `master` (`master` = major version 8, incl. 2025; `R7.1` = 7.1)
> - **Source snapshot:** vendored statement-grammar excerpts; verify the current upstream branch before regenerating
> - **Regenerate:** re-vendor the relevant statement-grammar excerpts from [`exasol/sql-statement-builder`](https://github.com/exasol/sql-statement-builder) at the branch above, then keep direct import/export workflow syntax out of this database reference.

## Statements in this file

- Query language (SELECT / DQL)
- Data manipulation (INSERT / UPDATE / DELETE / MERGE / TRUNCATE — DML)
- Data definition (CREATE / ALTER / DROP — DDL)
- Access control (GRANT / REVOKE / roles / privileges — DCL)
- Sessions, transactions & administration (DAL)
- Miscellaneous (COMMIT/ROLLBACK, EXECUTE SCRIPT, KILL, ALTER SESSION/SYSTEM, indexes, zonemaps, consumer groups, RENAME, …)

## How to read this notation

The source uses the `Ebnf2ps` dialect. It is **not** standard EBNF — note the
repetition operators carefully:

| Notation | Meaning |
| --- | --- |
| `a = b ;` | definition of `a` |
| `(a b)` | group (only to scope `\|` or extend `+` / `/`) |
| `a \| b` | alternative (a **or** b) |
| `[a]` | optional (zero or one) |
| `{a}` | zero or more repetitions of a **single element** (⚠ reads right-to-left; never use for a group) |
| `[(a b)+]` | zero or more repetitions of a **group** |
| `a+` | one or more repetitions |
| `a / sep` | **one or more** repetitions of `a` separated by `sep` (e.g. `expr / ","` = comma-separated list) |
| `[a / sep]` | **zero or more** repetitions of `a` separated by `sep` |
| `"string"` | terminal — appears literally in the query (one terminal per token: `"(" ")"`, not `"()"`) |

⚠ The most common misreadings for an agent: `/` is a **separated list**, not
division; `{a}` is repetition of one element only. Keep both in mind.

Rule names in a few files are German (`datentypen` = data types, `literale` =
literals, `sonstige` = miscellaneous) — cosmetic; the terminals are the real SQL.


---

## Query language (SELECT / DQL)

<sub>source: `diagrams/dql.bnf`</sub>

```ebnf
  select_statement_1
        = [ with_clause ] "SELECT" select_list [ "FROM" (from_item / ",") ] ;

  select_statement_2
        = ["WHERE" condition] [connect_by_clause] [preferring_clause] ;

  select_statement_3
        = [group_by_clause] [window_clause] ["QUALIFY" condition] ;

  select_statement_4
        = [order_by_clause] [limit_clause];

  with_clause
        = "WITH" (query_name [ "(" column_alias / "," ")" ] "AS" "(" subquery ")" ) / "," ; 

  select_list
        = ["DISTINCT" | "ALL"] ((expr [["AS"] column_alias] | ((table | view) "." "*") | "*") / ",") ;

  from_item
        = (((["TABLE"] table | view | ( "(" (subquery | values_table | value_range_table) ")" ) ) [["AS"] table_alias ["(" column_alias / "," ")"]]) | (join_clause | "(" join_clause ")")) ;

  connect_by_clause
        = ("CONNECT" "BY" ["NOCYCLE"] (condition / "AND") ["START" "WITH" condition]) | ("START" "WITH" condition "CONNECT" "BY" ["NOCYCLE"] (condition / "AND"));

  preferring_clause
        = "PREFERRING" preference_term ["PARTITION" "BY" (expr / ",") ];

  preference_term
        = "(" preference_term ")" | (("HIGH" | "LOW") expr) | (boolean_expr) | (preference_term ("PLUS" | ("PRIOR" "TO")) preference_term) | "INVERSE" "(" preference_term ")";

  group_by_clause
        = "GROUP" "BY" ((expr | position | cube_rollup_clause | grouping_sets_clause | "(" ")") / ",") ["HAVING" condition] ;

  cube_rollup_clause
        = ("CUBE" | "ROLLUP") "(" grouping_expression_list  ")" ;

  grouping_sets_clause
        = "GROUPING" "SETS" "(" (cube_rollup_clause | (grouping_expression_list)) / "," ")" ;

  grouping_expression_list
        = ((expr) | ("(" expr / "," ")")) / "," ;

  order_by_clause
        = "ORDER" "BY" ((expr | position | column_alias) ["ASC" | "DESC"] [("NULLS" ("FIRST" | "LAST"))]) / "," ;

  limit_clause
        = "LIMIT" (([offset ","] count) | (count ["OFFSET" offset])) ;

  join_clause
        = from_item (inner_outer_clause | ("CROSS" "JOIN" from_item));

  inner_outer_clause
        = ((["INNER"]) | (("LEFT" | "RIGHT") ["OUTER"]) | ("FULL" "OUTER")) "JOIN" from_item (("ON" condition) | ("USING" "(" column / "," ")"));

  values_table
        = "VALUES"  ( "(" expr / "," ")" ) / "," ;

  value_range_table
        = "VALUES" "BETWEEN" min_value "AND" max_value ["WITH" "STEP" step_value] ;

  table_operator_1
	= [with_clause] ( ( subquery | table_operator ) | "(" ( subquery | table_operator ) ")") ("UNION" ["ALL"] | "INTERSECT" | ("EXCEPT" | "MINUS"));

  table_operator_2
	= (subquery | "(" subquery ")") [order_by_clause] [limit_clause] ;

```

---

## Data manipulation (INSERT / UPDATE / DELETE / MERGE / TRUNCATE — DML)

<sub>source: `diagrams/dml.bnf`</sub>

```ebnf
  insert_statement_1
	= "INSERT" "INTO" table [ ["AS"] t_alias ] [ ( "(" column / "," ")" ) ];

  insert_statement_2
        = ( "VALUES"  ( "(" (expr | "DEFAULT") / "," ")") / "," ) | ( "VALUES" "BETWEEN" min_value "AND" max_value ["WITH" "STEP" step_value] ) | "DEFAULT" "VALUES" | subquery;

  update_statement_1
	= "UPDATE" table [ ["AS"] t_alias ];

  update_statement_2
        = "SET" ((col "=" ( expr | "DEFAULT" )) / "," ) ["FROM" from_item / ","];

  update_statement_3
        = ["WHERE" condition] ["PREFERRING" preferring_term] ;

  delete_statement_1
        = "DELETE" [ "*" ] "FROM" table [["AS"] t_alias];

  delete_statement_2
        = ["WHERE" condition] ["PREFERRING" preferring_term] ;

  truncate_statement
        = "TRUNCATE" "TABLE" table;

  merge_statement_1
	= "MERGE" "INTO" table [ ["AS"] t_alias ];

  merge_statement_2
        = "USING" (table | view | subquery) [ ["AS"] t_alias ] "ON" condition;

  merge_statement_3
        = [ "WHEN" "MATCHED" "THEN" (merge_update_clause | merge_delete_clause) ];

  merge_statement_4
        = [ "WHEN" "NOT" "MATCHED" "THEN" merge_insert_clause ];

  merge_update_clause_1
        = "UPDATE" "SET" ((column "=" ( expr | "DEFAULT" ) ) / "," ) [ where_clause ];

  merge_update_clause_2
        = [ "DELETE" [where_clause] ];

  merge_delete_clause
        = "DELETE" [ where_clause ];

  merge_insert_clause_1
        = "INSERT" [ "(" column / "," ")" ]  "VALUES" "(" (expr | "DEFAULT") / "," ")";

  merge_insert_clause_2
        = [ where_clause ];
  
```

---

## Data definition (CREATE / ALTER / DROP — DDL)

<sub>source: `diagrams/ddl.bnf`</sub>

```ebnf
  create_schema_statement
        = "CREATE" "SCHEMA" ["IF" "NOT" "EXISTS"] schema;

  create_virtual_schema_statement_1
        = "CREATE" "VIRTUAL" "SCHEMA" ["IF" "NOT" "EXISTS"] schema;

  create_virtual_schema_statement_2
        = "USING" adapter [ "WITH" ( property "=" string )+ ];

  alter_schema_statement
        = "ALTER" "SCHEMA" schema (("CHANGE" "OWNER" ( user | role )) | ("SET" "RAW_SIZE_LIMIT" "=" limit_in_bytes));

  alter_virtual_schema_statement_1
        = "ALTER" "VIRTUAL" "SCHEMA" schema;

  alter_virtual_schema_statement_2
       = ( "SET" ( property "=" string )+ ) | ( "REFRESH" [ "TABLES" ( table )+ ] ) | ( "CHANGE" "OWNER" ( user | role ) );

  drop_schema_statement_1
        = "DROP" [["FORCE"] "VIRTUAL"] "SCHEMA";

  drop_schema_statement_2
        = ["IF" "EXISTS"] schema [ ( "CASCADE" | "RESTRICT" )];

  create_table_statement_1
        = "CREATE" [ "OR" "REPLACE" ] "TABLE" [ "IF" "NOT" "EXISTS"] table;

  create_table_statement_2
        = ("(" ((column_definition | like_clause | out_of_line_constraint) / ",") ["," (distribute_by | partition_by) / ","] ")") | like_clause | ("AS" subquery [ ("WITH" "DATA") | ("WITH" "NO" "DATA" )] );

  create_table_statement_3
        = ["COMMENT" "IS" string];

  column_definition_1
        = column datatype [ "DEFAULT" expr | "IDENTITY" [ int ] ] { inline_constraint };

  column_definition_2
        = ["COMMENT" "IS" string];

  inline_constraint
        = ["CONSTRAINT" [name]] ( (["NOT"] "NULL") | ("PRIMARY" "KEY") | (references_clause) ) ["ENABLE" | "DISABLE"] ;
  
  out_of_line_constraint_1
        = ["CONSTRAINT" [constraint]];

  out_of_line_constraint_2
        = ( ("PRIMARY" "KEY" "(" column / "," ")" ) | ("FOREIGN" "KEY" "(" column / "," ")" references_clause) ) ["ENABLE" | "DISABLE"];

  references_clause
        = "REFERENCES" table ["(" column / "," ")"];

  like_clause
        = "LIKE" (table | view) ["(" (column [["AS"] alias]) / "," ")"];

  like_clause_2
        = [(("INCLUDING" | "EXCLUDING") "DEFAULTS")] [(("INCLUDING" | "EXCLUDING") "IDENTITY") ] ;

  like_clause_3
        = [(("INCLUDING" | "EXCLUDING") "COMMENTS") ];

  distribute_by
        = "DISTRIBUTE" "BY" (column / ",") ;

  partition_by
        = "PARTITION" "BY" (column / ",") ;

  select_into_statement_1
        = "SELECT" select_list "INTO" "TABLE" table "FROM" from_item / ",";

  drop_table_statement_1
        = "DROP" "TABLE" ["IF" "EXISTS"] table;

  drop_table_statement_2
        = [ ( "CASCADE" | "RESTRICT" )] ["CASCADE" "CONSTRAINTS"];

  alter_column_statement
        = "ALTER" "TABLE" table (add_column | drop_column | modify_column | rename_column | alter_column_default | alter_column_identity);

  add_column_statement_1
	= "ADD" [ "COLUMN" ] ["IF" "NOT" "EXISTS"] column datatype;

  add_column_statement_2
        = [ ("DEFAULT" expr) | ("IDENTITY" [int]) ] [inline_constraint];

  drop_column_statement
        = "DROP" [ "COLUMN" ] ["IF" "EXISTS"] column [ "CASCADE" "CONSTRAINTS" ];

  modify_column_statement_1
        = "MODIFY" [ "COLUMN" ] column [datatype];

  modify_column_statement_2
        = [ ("DEFAULT" expr) | ("IDENTITY" [int]) ] [inline_constraint];

  rename_column_statement
        = "RENAME" "COLUMN" old_name "TO" new_name;

  alter_column_default_statement
	= "ALTER" [ "COLUMN" ] column ( ( "SET" "DEFAULT" expr ) | ( "DROP" "DEFAULT" ) );

  alter_column_identity_statement
	= "ALTER" [ "COLUMN" ] column ( ( "SET" "IDENTITY" [int] ) | ( "DROP" "IDENTITY" ) );

  alter_table_distribute_partition
    = "ALTER" "TABLE" table (( (("DISTRIBUTE" | "PARTITION") "BY" (column / ",")) / ",") | ("DROP" (("DISTRIBUTION" | "PARTITION") / "AND") "KEYS"));

  alter_table_constraint
        = "ALTER" "TABLE" table (("ADD" out_of_line_constraint) | ("MODIFY" (("CONSTRAINT" constraint) | ("PRIMARY" "KEY")) ("ENABLE" | "DISABLE") ) | ("DROP" (("CONSTRAINT" constraint) | ("PRIMARY" "KEY"))) | ("RENAME" "CONSTRAINT" old_name "TO" new_name) );

  create_view_statement
        = "CREATE" [ "OR" "REPLACE" ] [ "FORCE" ] "VIEW" view;

  create_view_statement2
        = [ "(" [column ["COMMENT" "IS" string]] / "," ")"] "AS" subquery;

  create_view_statement3
        = ["COMMENT" "IS" string];

  drop_view_statement
        = "DROP" "VIEW" ["IF" "EXISTS"] view [ ( "CASCADE" | "RESTRICT" )];

  create_function_statement_1
        = ["CREATE" ["OR" "REPLACE"]] "FUNCTION" function;

  create_function_statement_2
        = "(" [(param ["IN"] data_type) / ","] ")" "RETURN" data_type;

  create_function_statement_3
        = ["IS"] (variable data_type ";")+;

  create_function_statement_4
        = "BEGIN" function_statement+ "RETURN" expr ";";

  create_function_statement_5
        = "END" [function] [";"];

  create_function_statement_6
        = "/";

  function_statement
        = assignment | if_branch | for_loop | for_loop_2 | while_loop | ("RETURN" expr ";");

  assignment      
        = identifier ":=" expr ";";
 
  if_branch_1
        = "IF" condition "THEN" function_statement+ ;

  if_branch_2
        = [(("ELSEIF" | "ELSIF") condition "THEN" function_statement+)+];

  if_branch_3
        = ["ELSE" function_statement+] "END" "IF" ";";

  while_loop
        = "WHILE" condition "DO" function_statement+ "END" "WHILE" ";" ;

  for_loop_1
        = "FOR" identifier ":=" int "TO" int;

  for_loop_2
        = "DO" function_statement+ "END" "FOR" ";" ;

  for_loop_11
        = "FOR" identifier "IN" int ".." int;

  for_loop_12
        = "LOOP" function_statement+ "END" "LOOP" ";" ;

  drop_function_statement
        = "DROP" "FUNCTION" ["IF" "EXISTS"] function [ ( "CASCADE" | "RESTRICT" )];


  create_script_content
        = script_content;

  create_script_terminator
        = "/";


  create_script_program_statement_1
        = "CREATE" [ "OR" "REPLACE" ] [ "LUA" ] "SCRIPT" script;

  create_script_program_statement_2
        = [ "(" [ ( [ "ARRAY" ] param_name ) / "," ] ")" ];

  create_script_program_statement_3
        = [ "RETURNS" "TABLE" | "RETURNS" "ROWCOUNT" ] "AS";


  create_script_udf_statement_1
        = "CREATE" [ "OR" "REPLACE" ] ( "JAVA" | "LUA" | "PYTHON3" | "R" | alias );

  create_script_udf_statement_2
        = ( "SCALAR" | "SET" ) "SCRIPT" script;

  create_script_udf_statement_3
        = "(" [ ( param_name data_type ) / "," [ udf_order_by_clause ] | "..." ] ")";

  create_script_udf_statement_4
        = [ "[" "USING" "INPUT" "COLUMN" "NAMES" "]" ];

  create_script_udf_statement_5
        = ( "RETURNS" data_type | "EMITS" "(" ( ( param_name data_type ) / "," | "..." ) ")" ) "AS";

  create_script_udf_order_by
        = "ORDER" "BY" ( param_name [ "ASC" | "DESC" ] ["NULLS" ( "FIRST" | "LAST" ) ] ) / ",";


  create_script_adapter_statement_1
        = "CREATE" [ "OR" "REPLACE" ] ( "JAVA" | "LUA" | "PYTHON3" | alias ) "ADAPTER" "SCRIPT" script "AS";


  create_script_preprocessor_statement_1
        = "CREATE" [ "OR" "REPLACE" ] ( "JAVA" | "LUA" | "PYTHON3" | alias ) "PREPROCESSOR" "SCRIPT" script "AS";


  drop_script_statement
        = "DROP" ["ADAPTER"] "SCRIPT" ["IF" "EXISTS"] script;

  rename_statement
        = "RENAME" [ "SCHEMA" | "TABLE" | "VIEW" | "FUNCTION" | "SCRIPT" | "USER" | "ROLE" | "CONNECTION" | ("CONSUMER" "GROUP")] old_name "TO" new_name;

  comment_table_statement_1
        = "COMMENT" "ON" ["TABLE"] table ["IS" string];

  comment_table_statement_2
        = ["(" ((column "IS" string) / ",") ")"] ;

  comment_object_statement
        = "COMMENT" "ON" (("COLUMN" | "SCHEMA" | "FUNCTION" | "SCRIPT" | "USER" | "ROLE" | "CONNECTION" | ("CONSUMER" "GROUP")) object "IS" string);
```

---

## Access control (GRANT / REVOKE / roles / privileges — DCL)

<sub>source: `diagrams/dcl.bnf`</sub>

```ebnf
  create_user_statement
        = "CREATE" "USER" user "IDENTIFIED" (("BY" password) | ("BY" "KERBEROS" "PRINCIPAL" string) | ("AT" "LDAP" "AS" dn_string ["FORCE"]) | ("BY" "OPENID" "SUBJECT" string));

  alter_user_statement_1
        = "ALTER" "USER" user;

  alter_user_statement_2
        = ("IDENTIFIED" (("BY" password [ "REPLACE" old_password ]) | ("BY" "KERBEROS" "PRINCIPAL" string) | ("AT" "LDAP" "AS" dn_string) | ("BY" "OPENID" "SUBJECT" string))) | ("SET" "PASSWORD_EXPIRY_POLICY" "=" string) | ("PASSWORD" "EXPIRE") | ("RESET" "FAILED" "LOGIN" "ATTEMPTS");

  alter_user_set_consumer_group
        = "ALTER" "USER" user "SET" "CONSUMER_GROUP" "=" ( group | "NULL" );

  drop_user_statement
        = "DROP" "USER" ["IF" "EXISTS"] user ["CASCADE"];

  create_role_statement
        = "CREATE" "ROLE" role;

  alter_role_set_consumer_group
        = "ALTER" "ROLE" role "SET" "CONSUMER_GROUP" "=" ( group | "NULL" );

  drop_role_statement
        = "DROP" "ROLE" ["IF" "EXISTS"] role ["CASCADE"];

  create_connection_statement_1
        = "CREATE" ["OR" "REPLACE"] "CONNECTION" connection "TO" string;

  create_connection_statement_2
        = ["USER" user "IDENTIFIED" "BY" password];

  create_connection_statement_3
        = ["PUBLIC KEY" string] ["SESSION TOKEN" string];

  create_connection_statement_4
        = [ "CLIENT ID" client_id ] [ "TENANT ID" tenant_id ] [ "SAS TOKEN" sas_token ];

  alter_connection_statement_1
        = "ALTER" "CONNECTION" connection "TO" string;

  alter_connection_statement_2
        = ["USER" user "IDENTIFIED" "BY" password];

  alter_connection_statement_3
        = ["PUBLIC KEY" string] ["SESSION TOKEN" string];

  alter_connection_statement_4
        = [ "CLIENT ID" client_id ] [ "TENANT ID" tenant_id ] [ "SAS TOKEN" sas_token ];

  drop_connection_statement
        = "DROP" "CONNECTION" ["IF" "EXISTS"] connection;
  
  grant_sysprivs_statement1
        = "GRANT" ( "ALL" ["PRIVILEGES"] | ( system_privilege / "," ) ) "TO" ((user | role) / ",");

  grant_sysprivs_statement2
        = ["WITH" "ADMIN" "OPTION"];

  grant_role_statement
        = "GRANT" ( role / "," ) "TO" (user | role) / "," ["WITH" "ADMIN" "OPTION"];

  grant_impersonation_statement
        = "GRANT" "IMPERSONATION" "ON" ( (user | role) / "," ) "TO" ( (user | role) / "," );

  grant_connection_statement_1
        = "GRANT" "CONNECTION" ( connection / "," ) "TO" (user | role) / ",";

  grant_connection_statement_2
        = ["WITH" "ADMIN" "OPTION"];

  grant_objprivs_statement_1
        = "GRANT" ( "ALL" ["PRIVILEGES"] | ( ("SELECT" | "INSERT" | "DELETE" | "UPDATE" | "ALTER" | "REFERENCES" | "EXECUTE" | "USAGE") / "," ) ) "ON" ["SCHEMA" | "TABLE" | "VIEW" | "FUNCTION" | "SCRIPT"] object;

  grant_objprivs_statement_2
        = "TO" (user | role) / ",";

  grant_connection_restricted_statement_1
        = "GRANT" "ACCESS" "ON" "CONNECTION" connection_name ;

  grant_connection_restricted_statement_2
        = ["FOR" (udf_script_name | schema_name | "SCRIPT" udf_script_name | "SCHEMA" schema_name)] "TO" (user | role) / ",";

  revoke_sysprivs_statement
        = "REVOKE" ( "ALL" ["PRIVILEGES"] | ( system_privilege / "," ) ) "FROM" ((user | role) / "," );

  revoke_role_statement
        = "REVOKE" (( role / "," ) | ("ALL" "ROLES")) "FROM" ((user | role) / ",");

  revoke_impersonation_statement
        = "REVOKE" "IMPERSONATION" "ON" ( (user | role) / "," ) "FROM" ( (user | role) / "," );

  revoke_connection_statement
        = "REVOKE" "CONNECTION" ( connection / "," ) "FROM" ((user | role) / ",");

  revoke_objprivs_statement_1
        = "REVOKE" ( "ALL" ["PRIVILEGES"] | ( ("SELECT" | "INSERT" | "DELETE" | "IMPORT" | "EXPORT" | "UPDATE" | "ALTER" | "REFERENCES" | "EXECUTE" | "USAGE") / "," ) ) "ON" ((["SCHEMA" | "TABLE" | "VIEW" | "FUNCTION" | "SCRIPT"] object) | ("ALL" ["OBJECTS"]));

  revoke_objprivs_statement_2
        = "FROM" ((user | role) / ",") ["CASCADE" "CONSTRAINTS"];

  revoke_connection_restricted_statement_1
        = "REVOKE" "ACCESS" "ON" "CONNECTION" connection_name ;

  revoke_connection_restricted_statement_2
        = ["FOR" (udf_script_name | schema_name | "SCRIPT" udf_script_name | "SCHEMA" schema_name)] "FROM" (user | role) / ",";

```

---

## Sessions, transactions & administration (DAL)

<sub>source: `diagrams/dal.bnf`</sub>

```ebnf
select_with_invalid_primary_key1
	= "SELECT" ["DISTINCT" | "ALL"] [select_list "WITH"]
        ;

select_with_invalid_primary_key2
	=  "INVALID" "PRIMARY" "KEY" "(" column / "," ")" "FROM" table
        ;

rest_select1
	= [where_clause] [group_by_clause] [window_clause]
        ;

rest_select2
	=  ["QUALIFY" condition] [order_by_clause]
        ;


select_with_invalid_unique1
	= "SELECT" ["DISTINCT" | "ALL"] [select_list "WITH"]
        ;

select_with_invalid_unique2
	= "INVALID" "UNIQUE" "(" column / "," ")" "FROM" table
        ;

select_with_invalid_foreign_key1
	= "SELECT" ["DISTINCT" | "ALL"] [select_list "WITH"]
        ;

select_with_invalid_foreign_key2
	= "INVALID" "FOREIGN" "KEY" "(" column / "," ")" "FROM" table 
        ;

select_with_invalid_foreign_key3
	= "REFERENCING" ref_table ["(" ref_column / "," ")"]
        ;

```

---

## Miscellaneous (expressions, identifiers, comments, hints)

<sub>source: `diagrams/sonstige.bnf`</sub>

```ebnf
  commit_statement
        = "COMMIT" [ "WORK" ];

  rollback_statement
        = "ROLLBACK" [ "WORK" ];

  execute_script_statement
        = "EXECUTE" "SCRIPT" script ["(" [ script_param / "," ] ")" ];
  
  execute_script_statement_2
        = ["WITH" "OUTPUT"];

  script_param
        = expr | ("ARRAY" "(" expr / "," ")");

  open_schema_statement
        = "OPEN" "SCHEMA" schema;

  close_schema_statement
        = "CLOSE" "SCHEMA";

  kill_statement
        = "KILL" (("SESSION" (session_id | "CURRENT_SESSION" )) | ("STATEMENT" [stmt_id] "IN" "SESSION" session_id [message]));

  msg_clause
        = "WITH" "MESSAGE" string;

  alter_session_statement
        = "ALTER" "SESSION" "SET" param "=" value;

  alter_system_statement
        = "ALTER" "SYSTEM" "SET" param "=" value;

  enforce_index_statement
        = "ENFORCE" "INDEX" index "ON" table ( "(" column / "," ")" );

  drop_index_statement
        = "DROP" "INDEX" index "ON" table;

  enforce_zonemap_statement
        = "ENFORCE" "ZONEMAP" "ON" table "(" column ")";

  drop_zonemap_statement
        = "DROP" "ZONEMAP" "ON" table "(" column ")";

  describe_statement
        = ("DESCRIBE" | "DESC") ["FULL"] object_name;

  explain_virtual_statement
        = "EXPLAIN" "VIRTUAL" subquery;

  recompress_statement
        = "RECOMPRESS" ( ("TABLE" table [ "(" column / "," ")" ] ) | "TABLES" table / "," | "SCHEMA" schema | "SCHEMAS" schema / "," | "DATABASE") ["ENFORCE"];
  
  reorganize_statement
        = "REORGANIZE" ("TABLE" table | "TABLES" table / "," | "SCHEMA" schema | "SCHEMAS" schema / "," | "DATABASE") ["ENFORCE"];
 
  truncate_audit_statement
        = "TRUNCATE" "AUDIT" "LOGS" ["KEEP" (("LAST" ("DAY" | "MONTH" | "YEAR")) | ("FROM" datetime))];

  transfer_statement1
        = "TRANSFER" [transfer_options] source "TO" target; 

  transfer_statement2
        = ["WITH" column_type_list | "WITH_FILE" filename];

  transfer_options
        = ((("APPEND" | "REPLACE") | ("SKIP" "(" offset ")") | ("FIELD_SEPARATOR" "(" sep ")") | ("FIELD_DELIMITER" "(" del ")") | ("ROW_SEPARATOR" "(" ("LF" | "CR" | "CRLF" | "NONE") ")") | "CHECK"))+;

  flush_statistics_statement  
        = "FLUSH" "STATISTICS";

  preload_statement
        = "PRELOAD" ( ("TABLE" table [ "(" column / "," ")" ] ) | "TABLES" table / "," | "SCHEMA" schema | "SCHEMAS" schema / "," | "DATABASE"); 

  create_consumer_group_statement
        = "CREATE" "CONSUMER" "GROUP" identifier "WITH" (( "CPU_WEIGHT" | "PRECEDENCE" ) "=" int | ( "GROUP_TEMP_DB_RAM_LIMIT" | "USER_TEMP_DB_RAM_LIMIT" | "SESSION_TEMP_DB_RAM_LIMIT" ) "=" memory_size | "QUERY_TIMEOUT" "=" time_in_seconds | "IDLE_TIMEOUT" "=" time_in_seconds ) / ",";

  drop_consumer_group_statement
        = "DROP" "CONSUMER" "GROUP" identifier;

  alter_consumer_group_statement
        = "ALTER" "CONSUMER" "GROUP" identifier "SET" (( "CPU_WEIGHT" | "PRECEDENCE" ) "=" int | ( "GROUP_TEMP_DB_RAM_LIMIT" | "USER_TEMP_DB_RAM_LIMIT" | "SESSION_TEMP_DB_RAM_LIMIT" ) "=" memory_size | "QUERY_TIMEOUT" "=" time_in_seconds | "IDLE_TIMEOUT" "=" time_in_seconds ) / ",";
  
  memory_size
        = ( int | ( "'" int [ "M" | "G" | "T" ] "'" ) | "'" "OFF" "'");

  impersonate_statement
        = "IMPERSONATE" user;

  control_move_session_statement_1
        = "CONTROL" "MOVE" (("SESSION" session_id / ",") | ("ALL" "SESSIONS" "FROM" (cluster_name|cluster_uid))) "TO" (cluster_name|cluster_uid);

  control_move_session_statement_2
        = ["WAIT" "TIMEOUT" timeout_in_seconds] ["FORCE"];

```
