--/
CREATE OR REPLACE LUA SCALAR SCRIPT PREPROC_RT.SEMANTIC_VIEWS_REFUSE_V1(message VARCHAR(2000000)) RETURNS VARCHAR(2000000) AS
-- Raises the Semantic Views refusal it is given (SEMANTIC_QUERY_xxx: ...), so a
-- statement the compiler refuses fails with the compiler's own words. The
-- framework's dispatcher swallows an error a module raises (it skips the rule
-- and runs the statement unchanged), which would show the published view's
-- guard instead of the reason. Same pattern as SEMANTIC_ADMIN.SEMANTIC_GUARD.
function run(ctx)
    error(ctx.message, 0)
end
/

--/
CREATE OR REPLACE LUA SCRIPT PREPROC_RT.SEMANTIC_VIEWS_V1() AS
-- Exasol Semantic Views as a module of the SQL preprocessor framework.
--
-- Semantic Views ships its own preprocessor, SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR,
-- meant to own Exasol's one preprocessor slot (per session, or database-wide).
-- On a starter-kit database the framework's PREPROC_RT.MASTER owns that slot, so
-- this module does the same work as one of MASTER's rules, for every user (rule
-- scope ROLE PUBLIC): the gate and the calls below are upstream's, from
-- lua/semantic_layer/scripts/semantic_preprocessor.lua (v0.6.1), and the
-- rewriting is upstream's own runtimes, SEMANTIC_DEFINITION_RUNTIME and
-- COMPILER_RUNTIME. Upstream stays untouched; only the framing is the kit's.
--
-- Phase EXPAND. A semantic statement is a language extension, not valid Exasol
-- SQL: Semantic DDL, and metric columns read from a published semantic view.
-- The entry returns the compiled statement for one, and nil (the framework's
-- "not my statement") for anything else, so the statement reaches the database
-- unchanged and the next EXPAND rule still sees it.
--
-- Loading the runtimes. Importing both costs about 21 ms, and this module runs
-- for every statement of every user, so they are imported only when the
-- statement could be semantic (upstream's own reasoning). The framework loads a
-- module with import() and import() works only at the top of a script, never
-- inside a function of an imported one (framework ADR, how-it-works.md), so the
-- runtimes are imported here at the top, guided by the statement the database
-- is preprocessing. The entry function still decides on the text it is handed;
-- when that text is not the one the imports were chosen for (an earlier
-- TRANSLATE rule rewrote it), it declines whatever needs a runtime not loaded.
--
-- No pcall: an error here (a runtime the caller has no EXECUTE on) makes the
-- dispatcher skip this rule and run the statement as written, which is the
-- right answer for a principal outside the semantic layer.

local COMMAND_WORDS = {ALTER = true, SHOW = true, DESCRIBE = true, EXPLAIN = true, EXPORT = true}

-- Does the statement name a schema this layer publishes? One small catalog read;
-- every uncertain case answers yes (upstream's references_semantic_schema).
local function references_semantic_schema(head)
    local candidates, seen = {}, {}
    for name in string.gmatch(head, '"?([%a_][%w_]*)"?%s*%.') do
        if not seen[name] then
            seen[name] = true
            candidates[#candidates + 1] = name
        end
    end
    if #candidates == 0 then
        return false
    end
    local ok, rows = pquery([[SELECT UPPER(PUBLISHED_SCHEMA) AS PUBLISHED_SCHEMA
                              FROM SYS_SEMANTIC.MODELS WHERE PUBLISHED_SCHEMA IS NOT NULL]])
    if not ok then
        return true
    end
    for i = 1, #rows do
        if seen[tostring(rows[i][1])] then
            return true
        end
    end
    -- An orphaned publication (its model row gone) still reaches the compiler,
    -- which names it as SEMANTIC_QUERY_005.
    for i = 1, math.min(#candidates, 4) do
        if pquery('SELECT 1 FROM "' .. candidates[i] .. '"."SEMANTIC_DISCOVERY" WHERE 1 = 0') then
            return true
        end
    end
    return false
end

-- What a statement could be: Semantic DDL (definition), a semantic query, both or neither.
local function classify(text)
    local head = string.match(string.upper(text), "^%s*(.-)%s*$") or ""
    local definition = COMMAND_WORDS[string.match(head, "^(%a+)") or ""] ~= nil
        and string.find(head, "SEMANTIC", 1, true) ~= nil
    local query = string.find(head, "SELECT", 1, true) ~= nil
        and string.find(head, "FROM", 1, true) ~= nil
        and references_semantic_schema(head)
    return {definition = definition, query = query}
end

local hint_text = nil
local hint = {definition = true, query = true}
if sqlparsing ~= nil and sqlparsing.getsqltext ~= nil then
    local text = sqlparsing.getsqltext()
    if type(text) == "string" then
        hint_text = text
        hint = classify(text)
    end
end

local definition_runtime = nil
local compiler_runtime = nil
if hint.definition then
    import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")
    definition_runtime = semantic_definition
end
if hint.query then
    import("SEMANTIC_ADMIN.COMPILER_RUNTIME", "compiler")
    compiler_runtime = compiler
end

local function quoted(text)
    local escaped = string.gsub(text, "'", "''")
    return "'" .. escaped .. "'"
end

function semantic_views(sqltext)
    local kind = hint
    if sqltext ~= hint_text then
        kind = classify(sqltext)
    end
    local result = {status = "UNCHANGED"}
    if kind.definition and definition_runtime ~= nil then
        result = definition_runtime.preprocess_sql(sqltext)
    end
    if result.status == "UNCHANGED" and kind.query and compiler_runtime ~= nil then
        result = compiler_runtime.compile_sql_for_preprocessor(sqltext)
    end
    if result.status == "UNCHANGED" then
        return nil
    end
    if result.status == "OK" then
        return tostring(result.generated_sql)
    end
    return "SELECT PREPROC_RT.SEMANTIC_VIEWS_REFUSE_V1("
        .. quoted((result.error_code or "SEMANTIC_QUERY_999") .. ": "
            .. (result.error_message or "Semantic SQL preprocessing failed.")) .. ")"
end
/
