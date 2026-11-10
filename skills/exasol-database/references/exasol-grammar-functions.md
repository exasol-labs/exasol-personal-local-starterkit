# Exasol SQL Functions & Expression Grammar

> **Source of truth.** The *complete* supported Exasol grammar for built-in
> **functions**, operators, **predicates**, **literals**, and **data types**, in
> EBNF, vendored verbatim from
> [`exasol/sql-statement-builder`](https://github.com/exasol/sql-statement-builder) — the same source
> the syntax-diagram images on docs.exasol.com are generated from (via
> `Ebnf2ps`).
>
> **Companion file:** statement-level grammar (SELECT, DDL, DML, DCL,
> session & admin) lives in
> [`exasol-grammar.md`](exasol-grammar.md).
>
> ⚠ **Read only the section you need.** This reference is large — jump to the
> relevant `##` heading (grep or Read that section) rather than loading the whole
> file into context.
>
> - **DB version:** branch `master` (`master` = major version 8, incl. 2025; `R7.1` = 7.1)
> - **Source snapshot:** vendored function, predicate, literal, and data-type grammar excerpts; verify the current upstream branch before regenerating
> - **Regenerate:** re-vendor the relevant function, predicate, literal, and data-type grammar excerpts from [`exasol/sql-statement-builder`](https://github.com/exasol/sql-statement-builder) at the branch above. Do not hand-edit.

## Sections in this file

- Built-in functions (arithmetic / string / date / analytic / aggregate / JSON / spatial / hash …)
- Predicates & conditions
- Literals
- Data types

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

## Built-in functions

<sub>source: `diagrams/functions.bnf`</sub>

```ebnf
multi
  = number "*" (number | interval);

division
  = (number | interval) "/" number;

add
  = (number "+" number) | (interval "+" interval) | ((datetime) "+" (integer | interval));

sub
  = (number "-" number) | (interval "-" interval) | (date "-" (date | integer | interval) ) ;

concat_sign
  = string1 "||" string2;

prior
  = "PRIOR" expr;

connect_by_root
  = "CONNECT_BY_ROOT" expr;

analytic_function
  = function "(" [ expr [ "," expr] ] ")" [ over_clause ];

over_clause
  = "OVER" ( window_name | "(" [ window_name ] [ partition_clause ] [ order_clause ] [window_frame_clause] ")" );
    
partition_clause
  = "PARTITION" "BY" ( expr / "," );

order_clause
  = "ORDER" "BY" ( ( expr [ "DESC" | "ASC" ] [ "NULLS" ( "FIRST" | "LAST" ) ] ) / "," );

window_frame_clause
  = ( "ROWS" | "RANGE" | "GROUPS" ) ( ( "UNBOUNDED" "PRECEDING" | "CURRENT" "ROW" | expr "PRECEDING" ) | "BETWEEN" ( "UNBOUNDED" "PRECEDING" | "CURRENT" "ROW" | expr "PRECEDING" | expr "FOLLOWING") "AND" ( "CURRENT" "ROW" | expr "PRECEDING" | expr "FOLLOWING" | "UNBOUNDED" "FOLLOWING" ) ) [window_frame_exclusion];

window_frame_exclusion
  = "EXCLUDE" ( "CURRENT" "ROW" | "TIES" | "GROUP" | "NO" "OTHERS" );

named_window_specification
  = "WINDOW" ( ( window_name "AS" "(" [ previously_defined_window_name ] [ partition_clause ] [ order_clause ] [window_frame_clause] ")" ) / "," );
  
abs 
  = "ABS" "(" n ")";

acos
  = "ACOS" "(" n ")";

add_days
  = "ADD_DAYS" "(" (datetime) "," integer ")";

add_hours
  = "ADD_HOURS" "(" datetime "," integer ")";

add_minutes
  = "ADD_MINUTES" "(" datetime "," integer ")";

add_months
  = "ADD_MONTHS" "(" (datetime) "," integer ")";

add_seconds
  = "ADD_SECONDS" "(" datetime "," decimal ")";

add_weeks
  = "ADD_WEEKS" "(" (datetime) "," integer ")";

add_years
  = "ADD_YEARS" "(" (datetime) "," integer ")";

any
  = "ANY" "(" [ ( "DISTINCT" | "ALL" ) ] expr ")" [ over_clause ];

approximate_count_distinct
  = "APPROXIMATE_COUNT_DISTINCT" "(" expr ")";

ascii
  = "ASCII" "(" char ")";

unicode
  = "UNICODE" "(" char ")";

asin
  = "ASIN" "(" n ")";

atan
  = "ATAN" "(" n ")";

atan2
  = "ATAN2" "(" n "," m ")";

avg 
  = "AVG" "(" [ ( "DISTINCT" | "ALL" ) ] expr ")" [ over_clause ];

bit_and
  = "BIT_AND" "(" integer "," integer ")";

bit_check
  = "BIT_CHECK" "(" integer "," pos ")"; 

bit_length
  = "BIT_LENGTH" "(" string ")";

bit_lrotate
  = "BIT_LROTATE" "(" integer "," integer ")";

bit_lshift
  = "BIT_LSHIFT" "(" integer "," integer ")";

bit_not
  = "BIT_NOT" "(" integer ")";

bit_or
  = "BIT_OR" "(" integer "," integer ")";

bit_rrotate
  = "BIT_RROTATE" "(" integer "," integer ")";

bit_rshift
  = "BIT_RSHIFT" "(" integer "," integer ")";

bit_to_num
  = "BIT_TO_NUM" "(" digit / "," ")";

bit_set
  = "BIT_SET" "(" integer "," pos ")"; 

bit_xor
  = "BIT_XOR" "(" integer "," integer ")";

case
  = "CASE" (simple_case_expr | searched_case_expr )  "END";

simple_case_expr
  = expr ("WHEN" comparison_expr "THEN" result)+ ["ELSE" expr];

searched_case_expr
  = ("WHEN" condition "THEN" result)+ ["ELSE" expr];
 
cast
  = "CAST" "(" expr "AS" data_type ")";

ceil
  = ("CEIL" | "CEILING") "(" number ")";

character_length
  = "CHARACTER_LENGTH" "(" string ")";

chr
  = ("CHR" | "CHAR") "(" integer ")";

coalesce
  = "COALESCE" "(" (expr / ",") ")";

cologne_phonetic
  = "COLOGNE_PHONETIC" "(" string ")";

concat
  = "CONCAT" "(" string / "," ")";

connect_by_iscycle
  = "CONNECT_BY_ISCYCLE";

connect_by_isleaf
  = "CONNECT_BY_ISLEAF";

convert
  = "CONVERT" "(" data_type "," expr ")";

convert_tz
  = "CONVERT_TZ" "(" datetime "," from_tz "," to_tz ["," options] ")";

corr
  = "CORR" "(" expr1 "," expr2 ")" [ over_clause ]; 

cos
  = "COS" "(" n ")";

cosh
  = "COSH" "(" n ")";

cot
  = "COT" "(" n ")";

count
  = "COUNT" "(" ( "*" | ( [ ( "DISTINCT" | "ALL" ) ] ( expr | ( "(" ( expr / "," ) ")" ) ) ) ) ")" [ over_clause ];

covar_pop
  = "COVAR_POP" "(" expr1 "," expr2 ")" [ over_clause ]; 

covar_samp
  = "COVAR_SAMP" "(" expr1 "," expr2 ")" [ over_clause ]; 

cume_dist
  = "CUME_DIST" "(" ")" over_clause; 

curdate
  = "CURDATE" "(" ")";

current_cluster
  = "CURRENT_CLUSTER";

current_date
  = "CURRENT_DATE";

current_schema
  = "CURRENT_SCHEMA";

current_session
  = "CURRENT_SESSION";

current_statement
  = "CURRENT_STATEMENT";

current_timestamp
  = "CURRENT_TIMESTAMP" [ "(" [ precision ] ")" ];

current_user
  = "CURRENT_USER";

date_trunc
  = "DATE_TRUNC" "(" format "," (datetime ) ")";

day1
  = "DAY" "(" date ")";

dayofweek
  = "DAYOFWEEK" "(" datetime ")";

days_between
  = "DAYS_BETWEEN" "(" (datetime1) "," (datetime2) ")";

dbtimezone
  = "DBTIMEZONE";

decode
  = "DECODE" "(" expr "," ((search "," result) / ",") ["," default] ")";

dense_rank
  = "DENSE_RANK" "(" ")" over_clause;

every
  = "EVERY" "(" [ ( "DISTINCT" | "ALL" ) ] expr ")" [ over_clause ];

degrees
  = "DEGREES" "(" n ")";

div
  = "DIV" "(" m "," n ")";

dump
  = "DUMP" "(" string ["," format ["," start ["," length ] ] ] ")";

edit_distance
  = "EDIT_DISTANCE" "(" string "," string ")";

exp
  = "EXP" "(" n ")";

extract
  = "EXTRACT" "(" ("YEAR" | "MONTH" | "DAY" | "HOUR" | "MINUTE" | "SECOND") "FROM" (datetime | interval) ")";

first_value
  = "FIRST_VALUE" "(" expr ")" [ ( "RESPECT" | "IGNORE" ) "NULLS" ] [ over_clause ];

floor
  = "FLOOR" "(" n ")";

from_posix_time
  = "FROM_POSIX_TIME" "(" number ")";

greatest
  = "GREATEST" "(" ( expr / "," ) ")";

group_concat
  = "GROUP_CONCAT" "(" [ "DISTINCT" ] expr [ order_clause ] [ "SEPARATOR" separator ] ")" [ over_clause ];

grouping
  = ("GROUPING" | "GROUPING_ID") "(" expr / "," ")";

hash_md5
  = "HASH_MD5" "(" expr / "," ")";

hash_sha1
  = ("HASH_SHA1" | "HASH_SHA") "(" expr / "," ")";

hash_sha256
  = "HASH_SHA256" "(" expr / "," ")";

hash_sha512
  = "HASH_SHA512" "(" expr / "," ")";

hash_tiger
  = "HASH_TIGER" "(" expr / "," ")";

hashtype_md5
  = "HASHTYPE_MD5" "(" expr / "," ")";

hashtype_sha1
  = ("HASHTYPE_SHA1" | "HASHTYPE_SHA") "(" expr / "," ")";

hashtype_sha256
  = "HASHTYPE_SHA256" "(" expr / "," ")";

hashtype_sha512
  = "HASHTYPE_SHA512" "(" expr / "," ")";

hashtype_tiger
  = "HASHTYPE_TIGER" "(" expr / "," ")";

hour1
  = "HOUR" "(" datetime ")";

hours_between
  = "HOURS_BETWEEN" "(" timestamp1 "," timestamp2 ")";

if_then_else
  = "IF" condition "THEN" expr [ "ELSE" expr ] "ENDIF";

ifnull
  = "IFNULL" "(" expr1 "," expr2 ")";

initcap
  = "INITCAP" "(" string ")";

insert
  = "INSERT" "(" string "," position "," length "," new_string ")";

instr
  = "INSTR" "(" string "," search_string ["," position ["," occurence]]")";

iproc
  = "IPROC" "(" ")";

is_datatype
  = (("IS_NUMBER" | "IS_DATE" | "IS_TIMESTAMP") "(" string [ "," format ]")") | (("IS_BOOLEAN" | "IS_DSINTERVAL" | "IS_YMINTERVAL") "(" string ")" ) ;

lag
  = "LAG" "(" expr [ "," offset [ "," default ] ] ")" [ ( "RESPECT" | "IGNORE" ) "NULLS" ] over_clause;

last_value
  = "LAST_VALUE" "(" expr ")" [ ( "RESPECT" | "IGNORE" ) "NULLS" ] [ over_clause ];

last_day
  = "LAST_DAY" "(" datetime ")";

lcase
  = "LCASE" "(" string ")";

lead
  = "LEAD" "(" expr [ "," offset [ "," default ] ] ")" [ ( "RESPECT" | "IGNORE" ) "NULLS" ] over_clause;

least
  = "LEAST" "(" (expr / ",") ")";

left  
  = "LEFT"  "(" string "," length ")" ;

length
  = "LENGTH" "(" string ")";

level
  = "LEVEL";

listagg_1
  = "LISTAGG" "(" [ "DISTINCT" | "ALL" ] expr [ "," delimiter ] [ listagg_overflow ] ")";

listagg_2
  = [ "WITHIN" "GROUP" "(" order_clause ")" ] [ over_clause ];

listagg_overflow
  = "ON" "OVERFLOW" ( "ERROR" | "TRUNCATE" [ truncation_filler ] ( "WITH" | "WITHOUT" ) "COUNT" );

ln
  = "LN" "(" n ")";

localtimestamp
  = "LOCALTIMESTAMP" [ "(" [ precision ] ")" ];

locate
  = "LOCATE" "(" search_string "," string ["," position]")";

log
  = "LOG" "(" base "," n ")";

log10
  = "LOG10" "(" n ")";

log2
  = "LOG2" "(" n ")";

lower
  = "LOWER" "(" string ")";

lpad
  = "LPAD" "(" string "," n [ "," padding ]")";

ltrim
  = "LTRIM" "(" string ["," trim_chars ] ")";

max
  = "MAX" "(" [ ( "DISTINCT" | "ALL" ) ] expr ")" [ over_clause ];

median
  = "MEDIAN" "(" [ "ALL" ] expr ")" [ over_clause ];

mid  
  = "MID"  "(" string ","  position [ "," length]")" ;

min
  = "MIN" "(" [ ( "DISTINCT" | "ALL" ) ] expr ")" [ over_clause ];

minute1
  = "MINUTE" "(" datetime ")";

minutes_between
  = "MINUTES_BETWEEN" "(" timestamp1 "," timestamp2 ")";

min_scale
  = "MIN_SCALE" "(" exact_numeric ")";

mod
  = "MOD" "(" m "," n ")";

month1
  = "MONTH" "(" date ")";

months_between
  = "MONTHS_BETWEEN" "(" (datetime1) "," (datetime2) ")";

mul
  = "MUL" "(" [ ( "DISTINCT" | "ALL" ) ] expr ")" [ over_clause ];

nullif
  = "NULLIF" "(" expr1 "," expr2 ")";

nullifzero
  = "NULLIFZERO" "(" number ")";

numtodsinterval
  = "NUMTODSINTERVAL" "(" n "," "'" interval_unit "'" ")";

numtoyminterval
  = "NUMTOYMINTERVAL" "(" n "," "'" interval_unit "'" ")";

now
  = "NOW" "(" ")";

nproc
  = "NPROC" "(" ")";

nth_value
  = "NTH_VALUE" "(" expr "," n ")" [ "FROM" ( "FIRST" | "LAST" ) ] [ ( "RESPECT" | "IGNORE" ) "NULLS" ] over_clause;

ntile
  = "NTILE" "(" expr ")" over_clause;

nvl
  = "NVL" "(" expr1 "," expr2 ")";

nvl2
  = "NVL2" "(" expr1 "," expr2 "," expr3 ")";

octet_length
  = "OCTET_LENGTH" "(" string ")";

percent_rank
  = "PERCENT_RANK" "(" ")" over_clause;

percentile_cont
  = "PERCENTILE_CONT" "(" expr ")" "WITHIN" "GROUP" "(" "ORDER" "BY" order_expr [ ( "ASC" | "DESC" ) ] ")" [ over_clause ];

percentile_disc
  = "PERCENTILE_DISC" "(" expr ")" "WITHIN" "GROUP" "(" "ORDER" "BY" order_expr [ ( "ASC" | "DESC" ) ] ")" [ over_clause ];

pi
  = "PI" "(" ")";

position
  = "POSITION" "(" search_string "IN" string ")";

posix_time
  = "POSIX_TIME" "(" [datetime] ")";

power
  = "POWER" "(" base "," exponent ")";

radians
  = "RADIANS" "(" n ")";

random
  = ("RANDOM" | "RAND") "(" [min "," max] ")";

rank
  = "RANK" "(" ")" over_clause;

ratio_to_report
  = "RATIO_TO_REPORT" "(" expr ")" over_clause;

regexp_instr
  = "REGEXP_INSTR" "(" string "," pattern;

regexp_instr_2
  = ["," position ["," occurence ["," return_opt]]] ")";

regexp_count
  = "REGEXP_COUNT" "(" string "," pattern ["," start_position ] ")";

regexp_replace
  = "REGEXP_REPLACE" "(" string "," pattern;

regexp_replace_2
  = ["," replace_string [","position ["," occurrence]]] ")";

regexp_substr
  =  "REGEXP_SUBSTR"    "(" string ","  pattern; 

regexp_substr_2
  =  [","position ["," occurrence]] ")"; 

regr_functions
  = ( "REGR_AVGX" | "REGR_AVGY" | "REGR_COUNT" | "REGR_INTERCEPT" | "REGR_R2" | "REGR_SLOPE" | "REGR_SXX" | "REGR_SXY" | "REGR_SYY" ) "(" expr1 "," expr2 ")" [ over_clause ];

repeat
  = "REPEAT" "(" string "," n ")";

replace
  = "REPLACE" "(" string "," search_string ["," replace_string] ")";

reverse
  = "REVERSE" "(" string ")";

right  
  = "RIGHT"  "(" string "," length ")" ;

round_datetime
  = "ROUND" "(" date ["," format] ")";

round_number
  = "ROUND" "(" n [ "," integer ] ")";

row_number
  = "ROW_NUMBER" "(" ")" "OVER" "(" [ partition_clause ] [ order_clause ] ")";

rowid
  = [ [ schema "." ] table "." ] "ROWID";

rpad
  = "RPAD" "(" string "," n [ "," padding ]")";

rtrim
  = "RTRIM" "(" string ["," trim_chars ] ")";

scope_user
  = "SCOPE_USER";

second1
  = "SECOND" "(" datetime [ "," precision ] ")";

seconds_between
  = "SECONDS_BETWEEN" "(" timestamp1 "," timestamp2 ")";

sessiontimezone
  = "SESSIONTIMEZONE";

session_parameter
  = "SESSION_PARAMETER" "(" session_id "," parameter_name ")";

sign
  = "SIGN" "(" n ")";

sin
  = "SIN" "(" n ")";

sinh
  = "SINH" "(" n ")";

some
  = "SOME" "(" [ ( "DISTINCT" | "ALL" ) ] expr ")" [ over_clause ];

soundex
  = "SOUNDEX" "(" string ")";

space
  = "SPACE" "(" integer ")";


spatial_1
  = ("ST_AREA" | "ST_BOUNDARY" | "ST_BUFFER" | "ST_CENTROID" | "ST_CONTAINS" | "ST_CONVEXHULL" | "ST_CROSSES" | "ST_DIFFERENCE" | "ST_DIMENSION" | "ST_DISJOINT" | "ST_DISTANCE" | "ST_ENDPOINT") "(" args ")";

spatial_2
  = ("ST_ENVELOPE" | "ST_EQUALS" | "ST_EXTERIORRING" | "ST_FORCE2D" | "ST_GEOMETRYN" | "ST_GEOMETRYTYPE" | "ST_INTERIORRINGN" | "ST_INTERSECTION" | "ST_INTERSECTS" | "ST_ISCLOSED" | "ST_ISEMPTY" | "ST_ISRING" | "ST_ISSIMPLE") "(" args ")";

spatial_3
  = ("ST_LENGTH" | "ST_NUMGEOMETRIES" | "ST_NUMINTERIORRINGS" | "ST_NUMPOINTS" | "ST_OVERLAPS" | "ST_SETSRID" | "ST_POINTN" | "ST_STARTPOINT" | "ST_SYMDIFFERENCE" | "ST_TOUCHES" | "ST_TRANSFORM" | "ST_UNION" | "ST_WITHIN" | "ST_X" | "ST_Y") "(" args ")";

sqrt
  = "SQRT" "(" n ")";

substr
  =  "SUBSTR"    "(" string ","  position [ "," length ] ")" 
   | "SUBSTRING" "(" string "FROM" position [ "FOR" length ] ")";

stddev
  = "STDDEV" "(" [ ( "DISTINCT" | "ALL" ) ] expr ")" [ over_clause ];

stddev_pop
  = "STDDEV_POP" "(" [ ( "DISTINCT" | "ALL" ) ] expr ")" [ over_clause ];

stddev_samp
  = "STDDEV_SAMP" "(" [ ( "DISTINCT" | "ALL" ) ] expr ")" [ over_clause ];

sum
  = "SUM" "(" [ ( "DISTINCT" | "ALL" ) ] expr ")" [ over_clause ];

sys_guid
  = "SYS_GUID" "(" ")";

sys_connect_by_path
  = "SYS_CONNECT_BY_PATH" "(" expr "," char ")";

sysdate
  = "SYSDATE";

systimestamp
  = "SYSTIMESTAMP" [ "(" [ precision ] ")" ];

tan
  = "TAN" "(" n ")";

tanh
  = "TANH" "(" n ")";

to_char_datetime
  = "TO_CHAR" "(" (( (datetime) ["," format ["," "'" nlsparam "'"] ]) | interval) ")";

to_char_number
  = "TO_CHAR" "(" number ["," format ] ")";

to_date
  = "TO_DATE" "(" string ["," format ] ")";

to_dsinterval_1
  = "TO_DSINTERVAL" "(" string ")";

to_number
  = "TO_NUMBER" "(" string ["," format ] ")";

to_timestamp
  = "TO_TIMESTAMP" "(" string ["," format ] ")";

to_yminterval
  = "TO_YMINTERVAL" "(" string ")";

translate
  = "TRANSLATE" "(" expr "," from_string "," to_string ")";

trim
  = "TRIM" "(" string [ "," trim_string ] ")";

trim_2
  = "TRIM" "("[ "LEADING" | "TRAILING" | "BOTH" ] [ trim_string "FROM" ] string ")";

trunc_datetime
  = ("TRUNC" | "TRUNCATE") "(" date ["," format ] ")";

trunc_number
  = ("TRUNC" | "TRUNCATE") "(" n ["," integer ] ")";

typeof
  = "TYPEOF" "(" expr ")";

ucase
  = "UCASE" "(" string ")";

unicodechr
  = "UNICODECHR" "(" n ")";

upper
  = "UPPER" "(" string ")";

user
  = "USER";

value2proc
 = "VALUE2PROC" "(" expr ")";

variance
  = "VARIANCE" "(" [ ( "DISTINCT" | "ALL" ) ] expr ")" [ over_clause ];

var_pop
  = "VAR_POP" "(" [ ( "DISTINCT" | "ALL" ) ] expr ")" [ over_clause ];

var_samp
  = "VAR_SAMP" "(" [ ( "DISTINCT" | "ALL" ) ] expr ")" [ over_clause ];

week
  = "WEEK" "(" date ")";

year1
  = "YEAR" "(" date ")";

years_between
  = "YEARS_BETWEEN" "(" (datetime1) "," (datetime2) ")";

zeroifnull
  = "ZEROIFNULL" "(" number ")";

json_value_1
  = "JSON_VALUE" "(" json_expr [ json_input_clause ] "," json_path_expr [ "RETURNING" data_type ];

json_value_2
  = [ ("ERROR" | "NULL" | "DEFAULT" expr) "ON" "EMPTY" ] [ ("ERROR" | "NULL" | "DEFAULT" expr) "ON" "ERROR" ] ")";

json_extract_1
  = "JSON_EXTRACT" "(" json_expr [ json_input_clause ] "," json_path_expr / ","  ["," "'$.error()'"] ")";

json_extract_2
  = "EMITS" "(" ( column_name data_type) / "," ")";

width_bucket
  = "WIDTH_BUCKET" "(" operand "," bound1 "," bound2 "," bucket_count ")";
```

---

## Predicates & conditions

<sub>source: `diagrams/predicates.bnf`</sub>

```ebnf
comparison_predicates
  = expr1 ("=" | "!=" | "<>" | "^=" | "<" | "<=" | ">" | ">=" ) expr2;

compound_predicates
  = (condition ("AND" | "OR") condition) | "NOT" condition;

between_predicate
  = expr1 [ "NOT" ] "BETWEEN" [ "ASYMMETRIC" | "SYMMETRIC" ] expr2 "AND" expr3;

exists_predicate
  =  "EXISTS" "(" subquery ")";

isnull_predicate
  = expr "IS" [ "NOT" ] "NULL";

regexp_like_predicate
  = string [ "NOT" ] "REGEXP_LIKE" reg_expr;

like_predicate
  = string [ "NOT" ] "LIKE" pattern [ "ESCAPE" esc_char ];

in_predicate
  = expr ["NOT"] "IN" "(" ((expr / ",") | subquery) ")";

json_predicate_1
  = expr [ json_input_clause ] "IS" [ "NOT" ] "JSON" [ ("VALUE" | "ARRAY" | "OBJECT" | "SCALAR") ] ;

json_predicate_2
  = [ ("WITH" | "WITHOUT") "UNIQUE" [ "KEYS"] ];

json_input_clause
  = "FORMAT" "JSON" [ "ENCODING" "UTF8" ];
```

---

## Literals

<sub>source: `diagrams/literale.bnf`</sub>

```ebnf
integer_literal
      = [ "+" | "-" ] digit+;

decimal_literal
      = [ "+" | "-" ] ((digit+ ["." {digit} ]) | ("." digit+));

double_literal
      = decimal_literal ["E" ["+" | "-"] digit+] ;      

boolean_literal
      =  "TRUE" | "FALSE" | "UNKNOWN";

date_literal
      = "DATE" string;

timestamp_literal
      = "TIMESTAMP" string;

interval_ym_literal_1
      = "INTERVAL" (( "'" int "'" "YEAR" ["(" precision ")"]) | ("'" int "'" "MONTH" ["(" precision ")"] ) | ( "'" int "-" int "'" "YEAR" ["(" precision ")"] "TO" "MONTH"));

interval_ds_literal_1
      = "INTERVAL" "'" ((int) | (int time_expr) | (time_expr)) "'";

interval_ds_literal_2
      = (("DAY" | "HOUR" | "MINUTE") ["(" precision ")"]) | ("SECOND" ["(" precision ["," fractional_precision] ")"] );

interval_ds_literal_3
      = ["TO" ("HOUR" | "MINUTE" | ("SECOND" ["(" fractional_precision ")"]))];

string_literal
      = "'"  {character}  "'";

null_literal
      = "NULL";
```

---

## Data types

<sub>source: `diagrams/datentypen.bnf`</sub>

```ebnf
string_datentyp
  = ("CHAR" | "VARCHAR") "(" int ["CHAR"] ")" [["CHARACTER" "SET"] ("ASCII" | "UTF8")];   

```

> ⚠ **Data types are only partially diagrammed upstream.** The source
> `datentypen.bnf` formally specifies only the parameterized string types
> (`CHAR` / `VARCHAR`). It does **not** cover `DECIMAL` / `DOUBLE` / `BOOLEAN` /
> `DATE` / `TIMESTAMP [WITH LOCAL TIME ZONE]` / `INTERVAL …` / `HASHTYPE` /
> `GEOMETRY` or their precision/scale rules. For the full data-type reference
> (ranges, defaults, precision, Oracle aliases, the missing `TIME` type), see the
> **Data Types** table in [`exasol-sql.md`](exasol-sql.md).
