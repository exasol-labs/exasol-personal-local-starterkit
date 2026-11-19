-- The kit's dispatch probe for the SQL preprocessor framework.
--
-- setup/preprocessor/manage.py deploys this module, scopes one rule to the
-- kit's administrator user only, and checks that a statement carrying the
-- marker comes back rewritten: once in a single session pointed at the
-- dispatcher, and again in fresh connections after the database default
-- changes. Both the rule and this script are dropped as soon as the check ends.
--
-- No other user is affected at any point, and the probe rewrites nothing but
-- the one marker statement manage.py sends.
--/
CREATE OR REPLACE LUA SCRIPT PREPROC_RT.EXAKIT_PROBE_V1 AS
function exakit_probe(sqltext)
    if string.find(sqltext, "EXAKIT_PP_PROBE_IN", 1, true) then
        return "SELECT 'EXAKIT_PP_PROBE_OUT' AS R"
    end
    return nil
end
/
