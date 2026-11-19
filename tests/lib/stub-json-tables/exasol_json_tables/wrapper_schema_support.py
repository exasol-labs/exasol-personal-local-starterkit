def load_installed_wrapper_manifests(con, wrapper_schemas=None):
    manifests = []
    for (helper_schema,) in con.execute(
            "SELECT TABLE_SCHEMA\n        FROM SYS.EXA_ALL_TABLES\n        WHERE TABLE_NAME = '__JVS_ROOTS'\n"
            "        ORDER BY TABLE_SCHEMA").fetchall():
        rows = con.execute(
            'SELECT ROOT_TABLE, SOURCE_SCHEMA, PUBLIC_SCHEMA, PUBLIC_VIEW, HELPER_SCHEMA\n'
            '        FROM "%s"."__JVS_ROOTS"\n        ORDER BY ROOT_TABLE' % helper_schema).fetchall()
        if not rows:
            raise ValueError("Helper schema %s does not contain any __JVS_ROOTS rows." % helper_schema)
        manifests.append({"sourceSchema": rows[0][1], "publicSchema": rows[0][2], "helperSchema": rows[0][4],
                          "roots": [{"tableName": row[0], "publicView": row[3]} for row in rows], "tables": []})
    return manifests
