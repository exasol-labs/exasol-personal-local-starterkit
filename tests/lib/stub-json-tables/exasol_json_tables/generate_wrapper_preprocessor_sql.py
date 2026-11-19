def _build_wrapper_rewrite_inputs(*, wrapper_schemas, helper_schemas, manifests, **_defaults):
    return {"wrapper_schemas": list(wrapper_schemas), "helper_schemas": list(helper_schemas),
            "helper_schema_map": dict(zip(wrapper_schemas, helper_schemas)),
            "group_config": {m["publicSchema"]: [r["publicView"] for r in m["roots"]] for m in manifests},
            "visible_column_config": {}, "to_json_config": {}, "helper_function_kinds": {"JSON_AS_VARCHAR": "variant"},
            "blocked_helper_names": [], "regular_to_json_row_object_function": '"%s"."TO_JSON_ROW"' % helper_schemas[0]}
