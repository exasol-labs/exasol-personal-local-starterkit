def build_preprocessor_config(*, allowed_schemas, helper_schema_map, wrapper_group_config, **rest):
    return {"allowed_json_schemas": {name: True for name in allowed_schemas},
            "helper_schema_by_allowed_schema": dict(helper_schema_map),
            "group_config_by_schema_and_table": wrapper_group_config,
            "rewrite_path_identifiers": rest.get("rewrite_path_identifiers")}


def render_lua_string_table(value, indent=0):
    if isinstance(value, dict):
        return "{" + ", ".join("[%r] = %s" % (key, render_lua_string_table(value[key])) for key in sorted(value)) + "}"
    if isinstance(value, list):
        return "{" + ", ".join(render_lua_string_table(item) for item in value) + "}"
    if value is True or value is False:
        return "true" if value else "false"
    return "'%s'" % value
