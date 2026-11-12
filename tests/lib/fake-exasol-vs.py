"""A simulated Exasol for the virtual schema engine (EXAKIT_VS_FAKE_DB).

State lives in the JSON file named by FAKE_VS_STATE, so a test can arrange a
database and inspect it afterwards:

    rust        false -> no RUST alias in SCRIPT_LANGUAGES, and a RUST script fails
                like java false (the custom container is not installed)
    lua         always true: Lua is built into the database
    java        false -> creating a JAVA script fails like a deployment with no
                container ("No usable script language container ...");
                "builtin" -> it fails like a fresh Exasol Personal 2.4, whose
                SCRIPT_LANGUAGES names JAVA=builtin_java but whose BucketFS
                has no Java client yet ("The required executable ... does not
                exist in BucketFS")
    dns         false -> the DNS probe answers "nodns ..." (no resolver at all);
                a host ending in .invalid answers "dns ..." (no such name)
    unreachable host names whose TCP probe fails
    clock_skew  seconds the database clock is off this computer's (negative: behind)
    script_privs, role_privs, users  who may create scripts (EXA_DBA_SYS_PRIVS grantees),
                the role grants and the users; by default only SYS (through DBA)
    loader_cacerts false -> the JDBC loader trusts nothing (Exasol Personal, measured):
                a Snowflake import fails unless its loader's main class is the kit's
                exakit.loader.TrustStoreDriver with exakit-loader.jar beside it
                (Databricks too)
    A Databricks source (jdbc:databricks:) also takes "no_columns" (Unity
    Catalog answers without columns, as the samples catalog does) and fails
    "tls" in the adapter's REST call in the kit's words
    A lakehouse catalog on AWS Glue is keyed by glue.<region>.amazonaws.com and
    takes "databases" ({name: [tables]}), "readable" (the databases the key may
    list; default all) and "key_id" (the access key it accepts)
    A lakehouse folder with no catalog (CATALOG_KIND DIRECT_STORAGE) is keyed
    by the host part of its s3:// or abfss:// URL and takes "tables" and the
    keys it accepts ("key_id"/"secret_key", or "account_key"/"sas_token").
    A catalog source with its own storage keys takes "key_id"/"secret_key" or
    "account_name" with "account_key"/"sas_token" too, checked at the read;
    an OAuth client is "client_id"/"client_secret".
    An Iceberg REST catalog or a Unity Catalog (the same engine) is keyed by
    the host of its URL and takes "catalog" ("rest" | "unity"), "namespaces"
    ({name: [tables]}), "token" (the token it accepts), "key_id" and
    "secret_key" (the storage keys it accepts), "warehouse" (the one it
    knows), "region" (the bucket's; vended credentials with none given fail
    as S3 with an empty region does) and "fail": "external" (Unity closed to
    outside engines) | "managed" (a catalog-managed table, at the read)
    sources     {host: {"tables": [...], "fail": null|"auth"|"tls"|"tls-validity"|"unreachable"|"denied"|"echo",
                        "secret": "<the credential the source accepts>",
                        "read_error": "<the driver's words for a refused read>"}}
                read_error is raised by the bounded read alone, as Exasol
                reports a pushed-down IMPORT the source refused (a missing
                grant): the metadata was read, the rows may not be.
                "echo" fails with the source's "message" as the driver's
                text (one that quotes credentials the run never knew)
                a document source (S3) is keyed by <bucket>.s3.<region>.amazonaws.com
                and also takes "region" (the bucket's real one) and "empty"
                (tables whose objects match nothing); its tables come from the
                mapping staged under FAKE_VS_EXA, as the adapter reads them.
                An Azure account is keyed by <account>.blob.core.windows.net and
                takes "key" (the account key it accepts), "sas" ({container:
                the SAS signature made for it}) and "containers". A mapping
                with no fields for a .csv/.parquet source is read at CREATE
                (schema inference), and a failure there is wrapped in E-VSD-102
    connections {NAME: {"url", "user", "secret"}}    what the engine created
    schemas, scripts, virtual {VS: {"connection", "tables", "adapter"}}
                adapter is the SCHEMA.SCRIPT its CREATE named (USING); one a
                test placed without it runs on EXAKIT_VS.ADAPTER_<X> for VS_<X>,
                as the kit names a source's own adapter. A
                test may place a virtual schema no kit source records - one a
                lost or another kit home left - and SYS.EXA_ALL_VIRTUAL_SCHEMAS
                lists every one with ADAPTER_SCRIPT_SCHEMA/_NAME. As Exasol
                does, an adapter script a virtual schema runs on cannot be
                dropped, nor a schema holding one (CASCADE or not), nor a
                schema with anything left in it without CASCADE; vs_list_fail
                true -> listing the virtual schemas fails; drop_fail
                scripts (SCHEMA.NAME) whose DROP is refused all the same
                a CREATE ... SCRIPT into a schema not in schemas fails as
                Exasol answers it (SQL state 42000, "schema <X> not found"):
                the engine makes EXAKIT_VS itself, nothing makes it for it
    statements  every statement, secrets included, so a test can prove where
                they went (into CONNECTION DDL) and where they did not
    stage_lag   how many staged-files probes see nothing before the files
                staged under FAKE_VS_EXA are reported as the database sees
                them (the share's delay on Exasol Personal); stage_never
                true -> they never are. files_probes counts the probes.
    refresh_fail virtual schemas whose ALTER ... REFRESH fails (the adapter
                cannot reach its source, or refresh_error's words when set);
                script_fail scripts (SCHEMA.NAME) whose CREATE OR REPLACE fails
    vs_fail     a message: every CREATE VIRTUAL SCHEMA fails with it (an
                adapter that echoes what the CONNECTION holds)
    ALTER CONNECTION ... TO '<address>' without USER/IDENTIFIED BY clears the
                user and the password the connection held - measured on Exasol
                2026.2.0-nano.8 (USER_NAME NULL, the password empty); altered
                lists every ALTERed one
    set_fail    a message: ALTER VIRTUAL SCHEMA ... SET fails with it;
                set_fail_when a text: only a SET whose statement holds it fails
    rename_fail connection names: a RENAME CONNECTION to one of them fails
    create_fail connection names: a CREATE CONNECTION of one of them fails
    connection_fail  a message: CREATE CONNECTION fails as pyexasol reports it,
                its query => field printing the statement back, secret and
                all, across as many lines as the statement has

Errors carry realistic driver text, including the statement for a failed
CREATE CONNECTION, so the engine's redaction is exercised for real.
"""

import json
import os
import re


def _load():
    with open(os.environ["FAKE_VS_STATE"]) as handle:
        doc = json.load(handle)
    for key, default in (("java", True), ("rust", True), ("lua", True), ("dns", True), ("unreachable", []), ("sources", {}),
                         ("connections", {}), ("schemas", []), ("scripts", []), ("virtual", {}),
                         ("statements", [])):
        doc.setdefault(key, default)
    return doc


def _save(doc):
    with open(os.environ["FAKE_VS_STATE"], "w") as handle:
        json.dump(doc, handle, indent=1)


def _query_error(message, sql):
    # pyexasol's ExaQueryError as the engine reads it: the database's message,
    # then the session's fields, the statement last (code is the SQL state).
    return Exception("(\n    message     =>  %s\n    dsn         =>  127.0.0.1:8563\n    user        =>  sys\n"
                     "    code        =>  42000\n    query       =>  %s\n)" % (message, sql))


def _host(url):
    m = re.search(r"//(?:tcps://)?([^:/;?]+)", url.replace("@tcps://", "//").replace("@//", "//"))
    return m.group(1) if m else ""


def _s3_error(text):
    # The shape measured on Exasol Personal: the UDF wrapper, then the SDK's exception.
    return Exception("VM error: F-UDF-CL-LIB-1126: F-UDF-CL-SL-JAVA-1006: F-UDF-CL-SL-JAVA-1026:\n"
                     "com.exasol.ExaUDFException: F-UDF-CL-SL-JAVA-1068: Exception during singleCall adapterCall\n"
                     "software.amazon.awssdk.services.s3.model.%s (SDK Attempt Count: 1)\n"
                     "\tsoftware.amazon.awssdk.services.s3.model.S3Exception$BuilderImpl.build(S3Exception.java:113)" % text)


_AZURE_PREAMBLE = (
    "If you are using a StorageSharedKeyCredential, and the server returned an error message that says 'Signature did "
    "not match', you can compare the string to sign with the one generated by the SDK. To log the string to sign, pass "
    "in the context key value pair 'Azure-Storage-Log-String-To-Sign': true to the appropriate method call.\n"
    "If you are using a SAS token, and the server returned an error message that says 'Signature did not match', you "
    "can compare the string to sign with the one generated by the SDK. To log the string to sign, pass in the context "
    "key value pair 'Azure-Storage-Log-String-To-Sign': true to the appropriate generateSas method call.\n"
    "Please remember to disable 'Azure-Storage-Log-String-To-Sign' before going to production as this string can "
    "potentially contain PII.\n")


def _azure_error(code, message, status):
    # The shape measured on Exasol Personal (adapter 3.1.0): on a 403 the SDK's
    # advice comes first, the store's answer is the XML body under it.
    return Exception("VM error: F-UDF-CL-LIB-1126: F-UDF-CL-SL-JAVA-1006: F-UDF-CL-SL-JAVA-1026:\n"
                     "com.exasol.ExaUDFException: F-UDF-CL-SL-JAVA-1068: Exception during singleCall adapterCall\n"
                     "com.azure.storage.blob.models.BlobStorageException: %sStatus code %d, \"\ufeff<?xml version=\"1.0\" "
                     "encoding=\"utf-8\"?><Error><Code>%s</Code><Message>%s\nRequestId:r1\nTime:2026-10-29T03:51:04Z"
                     "</Message></Error>\"\n\tcom.azure.storage.blob.implementation.util.ModelHelper.mapToBlobStorageException"
                     "(ModelHelper.java:663)" % (_AZURE_PREAMBLE if status == 403 else "", status, code, message))


def _azure_source(doc, cred):
    conn = dict(p.split("=", 1) for p in cred["absStorageAccountConnectionString"].split(";") if p)
    account = conn.get("AccountName") or re.match(r"https://([^.]+)\.", conn["BlobEndpoint"]).group(1)
    container = cred["absContainerName"]
    src = doc["sources"].get("%s.blob.core.windows.net" % account)
    if src is None:
        raise Exception("java.net.UnknownHostException: %s.blob.core.windows.net" % account)
    unauthenticated = ("AuthenticationFailed", "Server failed to authenticate the request. Make sure the value of "
                       "Authorization header is formed correctly including the signature.", 403)
    if "AccountKey" in conn:
        if src.get("key") is not None and conn["AccountKey"] != src["key"]:
            raise _azure_error(*unauthenticated)
    else:
        sas = dict(p.split("=", 1) for p in conn["SharedAccessSignature"].split("&"))
        # A SAS is signed for one container: any other, existing or not, rejects it.
        if src.get("sas", {}).get(container) != sas.get("sig"):
            raise _azure_error(*unauthenticated)
        if "l" not in sas.get("sp", ""):
            src = dict(src, fail="denied")
    if container not in src.get("containers", [container]):
        raise _azure_error("ContainerNotFound", "The specified container does not exist.", 404)
    if src.get("fail") == "denied":
        raise _azure_error("AuthorizationPermissionMismatch", "This request is not authorized to perform this "
                           "operation using this permission.", 403)
    return src


def _document_source(doc, con):
    cred = json.loads(con["secret"])
    if "absStorageAccountConnectionString" in cred:
        return _azure_source(doc, cred)
    host = "%s.s3.%s.amazonaws.com" % (cred["s3Bucket"], cred["awsRegion"])
    src = doc["sources"].get(host)
    if src is None:
        # The bucket answers from its own region: any other region's endpoint redirects.
        for other, candidate in doc["sources"].items():
            if other.startswith(cred["s3Bucket"] + ".s3."):
                raise _s3_error("S3Exception: The bucket you are attempting to access must be addressed using the "
                                "specified endpoint. Please send all future requests to this endpoint. (Service: S3, "
                                "Status Code: 301, Request ID: R1)")
        raise _s3_error("NoSuchBucketException: The specified bucket does not exist (Service: S3, Status Code: 404, "
                        "Request ID: R2)")
    if src.get("fail") == "auth" or (src.get("secret") is not None and cred["awsSecretAccessKey"] != src["secret"]):
        raise _s3_error("S3Exception: The request signature we calculated does not match the signature you provided. "
                        "Check your key and signing method. (Service: S3, Status Code: 403, Request ID: R3)")
    if src.get("fail") == "denied":
        raise _s3_error("AccessDeniedException: User: arn:aws:iam::1:user/reader is not authorized to perform: "
                        "s3:ListBucket on resource: \"arn:aws:s3:::%s\" (Service: S3, Status Code: 403, Request ID: R4)"
                        % cred["s3Bucket"])
    return src


def _mappings(path):
    folder = os.path.join(os.environ["FAKE_VS_EXA"], "bucketfs", *path.strip("/").split("/"))
    return [json.load(open(os.path.join(folder, n))) for n in sorted(os.listdir(folder)) if n.endswith(".json")]


def _mapping_tables(path):
    return sorted(m["destinationTable"].upper() for m in _mappings(path))


def _inferred(error, source):
    # Measured (Azure, a CSV mapping without fields): the adapter's coded line,
    # its mitigations, then the store's exception as the cause.
    cause = "\n".join(l for l in str(error).splitlines() if not l.startswith(("VM error:", "com.exasol.ExaUDFException")))
    return Exception("VM error: F-UDF-CL-LIB-1126: F-UDF-CL-SL-JAVA-1006: F-UDF-CL-SL-JAVA-1026:\n"
                     "com.exasol.ExaUDFException: F-UDF-CL-SL-JAVA-1068: Exception during singleCall adapterCall\n"
                     "E-VSD-102: Schema auto inference for source '%s' failed. Known mitigations:\n"
                     "* Make sure that the input files exist at '%s'\n* See cause error message for details.\n"
                     "* Fix the root cause or specify the 'mapping' element in the JSON EDML definition to skip auto "
                     "inference.\ncom.exasol.ExaWrapper.runSingleCall(ExaWrapper.java:101)\nCaused by: %s"
                     % (source, source, cause))


def _loader_trust(doc, connection):
    # Measured on Exasol Personal 2.3.0 (loader_cacerts false): the loader's
    # Java trusts nothing, unless the kit's main class points it at the
    # container's CA store. Only drivers that read the default store care.
    con = doc["connections"].get(connection)
    prefix = next((p for p in ("jdbc:snowflake:", "jdbc:databricks:") if con and con["url"].startswith(p)), None)
    if doc.get("loader_cacerts") is not False or not prefix:
        return
    folder = os.path.join(os.environ["FAKE_VS_EXA"], "jdbc")
    for name in (os.listdir(folder) if os.path.isdir(folder) else []):
        cfg = os.path.join(folder, name, "settings.cfg")
        text = open(cfg).read() if os.path.isfile(cfg) else ""
        if "PREFIX=" + prefix in text and "DRIVERMAIN=exakit.loader.TrustStoreDriver" in text and \
                os.path.isfile(os.path.join(folder, name, "exakit-loader.jar")):
            return
    raise Exception("ETL-5402: JDBC-Client-Error: Connecting to '%s' as user='%s' failed: JDBC driver encountered "
                    "communication error. Message: Exception encountered for HTTP request: (internal_error) Unexpected "
                    "error: java.security.InvalidAlgorithmParameterException: the trustAnchors parameter must be "
                    "non-empty." % (con["url"], con["user"]))


def _bigquery_source(doc, con):
    # Measured against a real project (Simba 1.7.0.1001, adapter 4.0.1): the
    # key is read from the file the URL names, the e-mail must be in the URL,
    # and a key Google refuses (or a token dated by a clock that is off) fails
    # the token request with 400.
    props = dict(p.split("=", 1) for p in con["url"].split(";")[1:] if "=" in p)
    for need in ("OAuthPvtKeyPath", "OAuthServiceAcctEmail"):
        if need not in props:
            raise Exception("RemoteMetadataReaderException: Unable to create BigQuery remote metadata reader. Caused "
                            "by: [Simba][JDBC](10100) Connection Refused: [Simba][JDBC](11640) Required Connection "
                            "Key(s): %s; [Simba][JDBC](11480) Optional Connection Key(s): AdditionalProjects" % need)
    path = os.path.join(os.environ["FAKE_VS_EXA"], "bucketfs", *props["OAuthPvtKeyPath"][len("/buckets/"):].split("/"))
    refused = ("RemoteMetadataReaderException: Unable to create BigQuery remote metadata reader. Caused by: "
               "[Simba][BigQueryJDBCDriver](100004) HttpTransport IO error : Error getting access token for service "
               "account: 400 Bad Request")
    if not os.path.isfile(path):
        raise Exception(refused.replace("400 Bad Request", "%s (No such file or directory)" % props["OAuthPvtKeyPath"]))
    key = json.load(open(path))
    src = doc["sources"].get("www.googleapis.com")
    if src is None:
        raise Exception("java.net.UnknownHostException: www.googleapis.com")
    if key.get("client_email") != props["OAuthServiceAcctEmail"] or \
            (src.get("key_id") and key.get("private_key_id") != src["key_id"]):
        raise Exception(refused)
    return src


def _databricks_source(doc, con, via):
    # Measured (adapter 1.0.2, driver 3.4.3): the adapter reads metadata over
    # the REST API, the loader reads rows over JDBC; each says a refused token
    # its own way.
    host = _host(con["url"])
    src = doc["sources"].get(host)
    if src is None:
        raise Exception("JDBC-Client-Error: Connection failure: connect timed out")
    if src.get("fail") == "auth" or (src.get("secret") is not None and con["secret"] != src["secret"]):
        if via == "loader":
            raise Exception("JDBC-Client-Error: Connecting to '%s' as user='token' failed: Connection failure while "
                            "using the OSS Databricks JDBC driver.\ncom.databricks.jdbc.exception.DatabricksSQLException: "
                            "Error while receiving response from Thrift server. Request {TOpenSessionReq(configuration:{})}, "
                            "Error {Failed to flush data to server: HTTP request failed by code: 403, status line: "
                            "HTTP/1.1 403 Forbidden. Request ID: r1. Error message: Invalid access token. [ReqId: r1]}"
                            % con["url"])
        raise Exception('Lua Error "E-VSDAB-5: HTTP request for URL \'https://%s:443/api/2.1/unity-catalog/tables?'
                        'catalog_name=c\' failed with status 403 (\'HTTP/1.1 403 Forbidden\') and body '
                        '\'{"error_code":403,"message":"Invalid access token. [ReqId: r2]"}\'" caught in script' % host)
    if via == "adapter" and src.get("fail") == "tls":
        raise Exception('Lua Error "E-VSDAB-6: HTTP request \'GET\' for URL \'https://%s:443/api\' failed with result '
                        '\'certificate verify failed: certificate has expired (%s)\'" caught in script' % (host, host))
    if via == "adapter" and src.get("no_columns"):
        raise Exception('Lua Error "1946:"EXAKIT_VS"."ADAPTER_X"|bad argument #1 for function \'for iterator\' '
                        '(table expected, got nil)" caught in script')
    return src


def _glue_source(doc, con, namespace=None):
    # Measured (lakehouse-engine-rs 0.57.3, CATALOG_KIND GLUE): a key AWS does
    # not know, and a database the key may not list - which, under a scoped
    # policy, is also how a database that does not exist reads.
    host = _host(con["url"])
    src = doc["sources"].get(host)
    if src is None:
        raise Exception("VM error: F-UDF-CL-RUST-9001: UDF error: Glue GetTables failed: dispatch failure: "
                        "error trying to connect: dns error")
    cred = json.loads(con["secret"] or "{}")
    database = namespace or src.get("_last_namespace", "")
    if src.get("key_id") and cred.get("access_key") != src["key_id"]:
        raise Exception("VM error: F-UDF-CL-RUST-9001: UDF error: Glue GetTables failed for database '%s': "
                        "UnrecognizedClientException: The security token included in the request is invalid."
                        % database)
    if database not in src.get("readable", src.get("databases", {})):
        raise Exception("VM error: F-UDF-CL-RUST-9001: UDF error: Glue GetTables failed for database '%s': "
                        "AccessDeniedException: User: arn:aws:iam::123456789012:user/reader is not authorized to "
                        "perform: glue:GetTables on resource: arn:aws:glue:%s:123456789012:database/%s because no "
                        "identity-based policy allows the glue:GetTables action"
                        % (database, host.split(".")[1], database))
    return {"tables": [t.upper() for t in src["databases"].get(database, [])]}


def _catalog_source(doc, con, props, at_read=False):
    # lakehouse-engine-rs over an Iceberg REST catalog or Unity Catalog. Not
    # measured live: the shapes follow the Iceberg REST spec's error types,
    # Databricks' error codes and object_store's own words.
    host = _host(con["url"])
    src = doc["sources"].get(host)
    if src is None:
        raise Exception("VM error: F-UDF-CL-RUST-9001: UDF error: catalog request failed: error sending request for "
                        "url (%s): error trying to connect: dns error" % con["url"])
    cred = json.loads(con["secret"] or "{}")
    unity = props.get("CATALOG_KIND") == "UNITY_CATALOG"
    namespace = props.get("NAMESPACE", "")
    if props.get("CATALOG_KIND") == "DIRECT_STORAGE":
        return _direct_source(src, con, cred, at_read)
    _storage_check(src, cred, at_read)
    if con["url"].startswith("http://") and props.get("ALLOW_HTTP") != "true":
        raise Exception("VM error: F-UDF-CL-RUST-9001: UDF error: the catalog URL %s is plain http, which is refused "
                        "unless ALLOW_HTTP is true" % con["url"])
    if unity != (src.get("catalog") == "unity"):
        raise Exception("VM error: F-UDF-CL-RUST-9001: UDF error: catalog request failed: HTTP 404 Not Found")
    if "client_id" in cred:
        # OAuth client credentials: the catalog's token endpoint takes the pair.
        if cred.get("client_id") != src.get("client_id") or cred.get("client_secret") != src.get("client_secret"):
            raise Exception("VM error: F-UDF-CL-RUST-9001: UDF error: OAuth token request failed: HTTP 401: "
                            '{"error":"invalid_client","error_description":"The client is not authorized"}')
    elif unity:
        if cred.get("token") != src.get("token"):
            raise Exception('VM error: F-UDF-CL-RUST-9001: UDF error: Unity Catalog request failed: HTTP 401: '
                            '{"error_code":"UNAUTHENTICATED","message":"Invalid access token. [ReqId: r1]"}')
    elif "token" in cred:
        if cred["token"] != src.get("token"):
            raise Exception("VM error: F-UDF-CL-RUST-9001: UDF error: Iceberg REST catalog request failed: "
                            "NotAuthorizedException: Not authorized to make this request (HTTP 401)")
    elif cred.get("access_key") != src.get("key_id") or cred.get("secret_key") != src.get("secret_key"):
        # Static keys: the catalog lists, the store refuses the signature.
        if at_read:
            raise Exception("VM error: F-UDF-CL-RUST-9001: UDF error: Object Store error: Error performing GET: "
                            "SignatureDoesNotMatch: The request signature we calculated does not match the "
                            "signature you provided. Check your key and signing method.")
    if not unity and src.get("fail") == "catalog-config":
        # Measured: the catalog URL given as the warehouse, against Databricks.
        raise Exception("VM error: F-UDF-CL-RUST-9001: UDF error: failed to read the catalog config for warehouse "
                        "'%s': catalog request failed with HTTP 400: {\"error_code\":\"INVALID_PARAMETER_VALUE\","
                        "\"message\":\"name \\\"%s\\\" is not a valid name. Valid names cannot contain spaces, periods, "
                        "forward slashes\"}" % (cred.get("warehouse"), cred.get("warehouse")))
    if not unity and src.get("warehouse") and cred.get("warehouse") != src["warehouse"]:
        raise Exception("VM error: F-UDF-CL-RUST-9001: UDF error: Iceberg REST catalog request failed: "
                        "NoSuchWarehouseException: Warehouse %s does not exist (HTTP 404)" % cred.get("warehouse"))
    if src.get("fail") == "external":
        raise Exception('VM error: F-UDF-CL-RUST-9001: UDF error: Unity Catalog request failed: HTTP 403: '
                        '{"error_code":"PERMISSION_DENIED","message":"User does not have EXTERNAL USE SCHEMA on '
                        'Schema \'%s\'."}' % namespace)
    if namespace not in src.get("namespaces", {}):
        if unity:
            raise Exception('VM error: F-UDF-CL-RUST-9001: UDF error: Unity Catalog request failed: HTTP 404: '
                            '{"error_code":"SCHEMA_DOES_NOT_EXIST","message":"Schema \'%s\' does not exist."}'
                            % namespace)
        raise Exception("VM error: F-UDF-CL-RUST-9001: UDF error: Iceberg REST catalog request failed: "
                        "NoSuchNamespaceException: Namespace does not exist: %s (HTTP 404)" % namespace)
    if at_read and src.get("region") and not cred.get("region") and cred.get("use_vended_credentials"):
        # Vended S3 credentials with no region given: object_store builds the
        # endpoint from an empty region (measured live, Databricks on AWS).
        raise Exception("VM error: F-UDF-CL-RUST-9001: UDF error: failed to resolve the current Delta version for "
                        "table root 's3://uc-bucket-1/ext/%s': Error interacting with object store: Generic S3 "
                        "error: Error performing GET https://s3..amazonaws.com/uc-bucket-1/ext/%s/_delta_log/"
                        "_last_checkpoint in 2.5s, after 10 retries, max_retries: 10, retry_timeout: 180s - HTTP "
                        "error: error sending request" % (namespace, namespace))
    if at_read and src.get("region") and cred.get("region") != src["region"]:
        raise Exception("VM error: F-UDF-CL-RUST-9001: UDF error: Object Store error: Received redirect without "
                        "LOCATION, this normally indicates an incorrectly configured region")
    if at_read and src.get("fail") == "managed":
        raise Exception("VM error: F-UDF-CL-RUST-9001: UDF error: table %s.%s is a catalog-managed table: Max "
                        "catalog version is required" % (namespace, src["namespaces"][namespace][0]))
    return {"tables": [t.upper() for t in src["namespaces"][namespace]]}


def _storage_check(src, cred, at_read):
    """The files' own credential beside a catalog login (files s3 or azure):
    the catalog lists, the store refuses a wrong key at the read."""
    if not at_read:
        return
    if "account_name" in cred:
        good = (cred.get("account_name") == src.get("account_name") and
                (("account_key" in cred and cred["account_key"] == src.get("account_key")) or
                 ("sas_token" in cred and cred["sas_token"] == src.get("sas_token"))))
        if not good:
            raise Exception("VM error: F-UDF-CL-RUST-9001: UDF error: Object Store error: Error performing GET: "
                            "AuthenticationFailed: Server failed to authenticate the request.")
    elif "access_key" in cred and "token" in cred or "access_key" in cred and "client_id" in cred:
        if cred.get("access_key") != src.get("key_id") or cred.get("secret_key") != src.get("secret_key"):
            raise Exception("VM error: F-UDF-CL-RUST-9001: UDF error: Object Store error: Error performing GET: "
                            "SignatureDoesNotMatch: The request signature we calculated does not match the "
                            "signature you provided. Check your key and signing method.")


def _direct_source(src, con, cred, at_read):
    """CATALOG_KIND DIRECT_STORAGE: the Parquet files under a folder, keyed by
    the folder URL's host part (s3://<bucket>, abfss://<container>@<account>...);
    takes "tables", "key_id"/"secret_key" or "account_key"/"sas_token"."""
    if con["url"].startswith("abfss://"):
        ok = cred.get("account_key", cred.get("sas_token")) in (src.get("account_key"), src.get("sas_token"))
        if not ok:
            raise Exception("VM error: F-UDF-CL-RUST-9001: UDF error: Object Store error: Error performing LIST: "
                            "AuthenticationFailed: Server failed to authenticate the request.")
    elif cred.get("access_key") != src.get("key_id") or cred.get("secret_key") != src.get("secret_key"):
        raise Exception("VM error: F-UDF-CL-RUST-9001: UDF error: Object Store error: Error performing LIST: "
                        "InvalidAccessKeyId: The AWS Access Key Id you provided does not exist in our records.")
    return {"tables": [t.upper() for t in src.get("tables", [])]}


def _source_for(doc, connection, via="adapter"):
    con = doc["connections"].get(connection)
    if not con:
        raise Exception("connection %s not found" % connection)
    if con["url"].startswith("jdbc:databricks:"):
        return _databricks_source(doc, con, via)
    if con["url"].startswith("https://glue."):
        return _glue_source(doc, con, doc.get("namespaces", {}).get(connection))
    if connection in doc.get("catalogs", {}):
        return _catalog_source(doc, con, doc["catalogs"][connection], at_read=True)
    if con["url"].startswith("jdbc:bigquery:"):
        return _bigquery_source(doc, con)
    if con["url"].startswith("mongodb"):
        src = doc["sources"].get(_host(con["url"]))
        if src is None or src.get("fail") == "auth" or (src.get("secret") is not None and con["secret"] != src["secret"]):
            # Measured: a wrong password and an address Atlas refuses read alike.
            raise Exception("VM error: F-UDF-CL-RUST-9001: UDF error: MongoDB error while reading collection metadata")
        return src
    if con["url"] == "" and con["secret"].startswith("{"):
        return _document_source(doc, con)
    src = doc["sources"].get(_host(con["url"]))
    if src is None:
        raise Exception("JDBC-Client-Error: The connection attempt failed.")
    fail = src.get("fail")
    if fail == "echo":
        raise Exception(src["message"])
    if fail == "auth" or (src.get("secret") is not None and con.get("secret") != src["secret"]):
        raise Exception('FATAL: password authentication failed for user "%s"' % con["user"])
    if fail == "tls":
        raise Exception("PKIX path building failed: unable to find valid certification path")
    if fail == "tls-validity":
        # A certificate outside its dates by the database's clock (measured on RDS).
        raise Exception("SSLHandshakeException: PKIX path validation failed: "
                        "java.security.cert.CertPathValidatorException: validity check failed")
    if fail == "unreachable":
        raise Exception("Connection refused. Check that the hostname and port are correct")
    return src


def _adapter_of(name, vs):
    """SCHEMA.SCRIPT a virtual schema runs on: as its CREATE named it, or for a
    VS_<X> a test placed by hand, the kit's own EXAKIT_VS.ADAPTER_<X>."""
    if vs.get("adapter"):
        return vs["adapter"]
    return "EXAKIT_VS.ADAPTER_" + name[3:] if name.startswith("VS_") else ""


def _adapter_users(doc, script):
    """The virtual schemas on an adapter script SCHEMA.NAME (on any script in
    the schema when it ends with a dot)."""
    return sorted(name for name, vs in doc["virtual"].items()
                  if _adapter_of(name, vs) and (_adapter_of(name, vs) == script or
                                                (script.endswith(".") and _adapter_of(name, vs).startswith(script))))


class Fake(object):
    def query(self, sql):
        doc = _load()
        doc["statements"].append(sql)
        try:
            return self._query(doc, sql)
        finally:
            _save(doc)

    def execute(self, sql):
        doc = _load()
        doc["statements"].append(sql)
        try:
            self._execute(doc, sql)
            m = re.match(r'CREATE VIRTUAL SCHEMA "([^"]+)" USING "?(\w+)"?\."?(\w+)"?', sql)
            if m and m.group(1) in doc["virtual"]:
                doc["virtual"][m.group(1)]["adapter"] = "%s.%s" % (m.group(2), m.group(3))
        finally:
            _save(doc)

    def close(self):
        pass

    def _query(self, doc, sql):
        m = re.search(r"FROM EXA_DBA_CONNECTIONS WHERE CONNECTION_NAME = '([^']+)'", sql)
        if m:
            con = doc["connections"].get(m.group(1))
            if con is None:
                return []
            row = {"CONNECTION_NAME": m.group(1)}
            if sql.startswith("SELECT CONNECTION_STRING, USER_NAME "):
                # What the system table shows of a connection: never its password.
                row.update(CONNECTION_STRING=con["url"].replace("''", "'"), USER_NAME=con["user"] or None)
            return [row]
        m = re.search(r"FROM SYS.EXA_ALL_COLUMNS WHERE COLUMN_SCHEMA = '([^']+)'", sql)
        if m:
            # columns: {table: [[name, type, nullable], ...]} at the top level;
            # a table not listed has two plain columns.
            vs = doc["virtual"].get(m.group(1)) or {"tables": []}
            rows = []
            for table in sorted(vs["tables"]):
                cols = doc.get("columns", {}).get(table) or [["ID", "DECIMAL(18,0)", False],
                                                             ["NAME", "VARCHAR(100) UTF8", True]]
                rows += [{"COLUMN_TABLE": table, "COLUMN_NAME": c[0], "COLUMN_TYPE": c[1],
                          "COLUMN_IS_NULLABLE": c[2]} for c in cols]
            return rows
        if sql == "SELECT * FROM SYS.EXA_ALL_VIRTUAL_SCHEMAS":
            if doc.get("vs_list_fail"):
                raise Exception("insufficient privileges for reading EXA_ALL_VIRTUAL_SCHEMAS (test)")
            rows = []
            for name, vs in sorted(doc["virtual"].items()):
                owner, _, script = _adapter_of(name, vs).partition(".")
                rows.append({"SCHEMA_NAME": name, "SCHEMA_OWNER": "SYS", "ADAPTER_SCRIPT_SCHEMA": owner or None,
                             "ADAPTER_SCRIPT_NAME": script or None})
            return rows
        if sql.startswith("SELECT SCRIPT_NAME, SCRIPT_TYPE FROM EXA_ALL_SCRIPTS WHERE SCRIPT_SCHEMA = 'EXAKIT_VS'"):
            return [{"SCRIPT_NAME": s.split(".", 1)[1],
                     "SCRIPT_TYPE": "ADAPTER" if "ADAPTER" in s.split(".", 1)[1] else "UDF"}
                    for s in sorted(doc["scripts"]) if s.startswith("EXAKIT_VS.")]
        m = re.search(r"FROM EXA_SCHEMAS WHERE SCHEMA_NAME = '([^']+)'", sql)
        if m:
            return [{"SCHEMA_NAME": m.group(1)}] if m.group(1) in doc["schemas"] + list(doc["virtual"]) else []
        m = re.search(r"SCRIPT_SCHEMA = '([^']+)' AND SCRIPT_NAME = '([^']+)'", sql)
        if m:
            return [{"SCRIPT_NAME": m.group(2)}] if "%s.%s" % m.groups() in doc["scripts"] else []
        m = re.search(r"EXAKIT_DNS_PROBE_V2\('([^']*)', (\d+)\)", sql)
        if m:
            if "EXAKIT_VS.EXAKIT_DNS_PROBE_V2" not in doc["scripts"]:
                raise Exception("function EXAKIT_VS.EXAKIT_DNS_PROBE_V2 not found")
            if not doc["dns"]:
                return [{"R": "nodns UnknownHostException"}]
            if m.group(1).endswith(".invalid"):
                return [{"R": "dns UnknownHostException"}]
            if m.group(1) in doc["unreachable"]:
                return [{"R": "tcp 10.0.0.9 SocketTimeoutException"}]
            return [{"R": "ok 10.0.0.9"}]
        # The staged-files probe: which of the /buckets paths given (one per
        # line) the database does not see. Really checked under FAKE_VS_EXA,
        # after "stage_lag" probes that see nothing (the share's delay on
        # Exasol Personal) - or never, with "stage_never". "files_probes"
        # counts the calls.
        m = re.search(r"EXAKIT_FILES_PROBE_V1\('((?:[^']|'')*)'\)", sql, re.S)
        if m:
            if "EXAKIT_VS.EXAKIT_FILES_PROBE_V1" not in doc["scripts"]:
                raise Exception("function EXAKIT_VS.EXAKIT_FILES_PROBE_V1 not found")
            paths = [p for p in m.group(1).replace("''", "'").split("\n") if p]
            doc["files_probes"] = doc.get("files_probes", 0) + 1
            if doc.get("stage_never"):
                missing = paths
            elif doc.get("stage_lag", 0) > 0:
                doc["stage_lag"] -= 1
                missing = paths
            elif os.environ.get("FAKE_VS_EXA"):
                missing = [p for p in paths if not os.path.isfile(
                    os.path.join(os.environ["FAKE_VS_EXA"], "bucketfs", *p[len("/buckets/"):].split("/")))]
            else:
                missing = []        # a harness that models no files: the database sees them all
            return [{"R": "\n".join(missing)}]
        # Who may create scripts (and so read BucketFS): the privilege tables.
        if sql.startswith("SELECT GRANTEE FROM EXA_DBA_SYS_PRIVS WHERE PRIVILEGE IN"):
            return [{"GRANTEE": g} for g in doc.get("script_privs", ["DBA", "PREPROC_ADMIN"])]
        if sql == "SELECT GRANTEE, GRANTED_ROLE FROM EXA_DBA_ROLE_PRIVS":
            return [{"GRANTEE": g, "GRANTED_ROLE": r} for g, r in doc.get("role_privs", [["SYS", "DBA"]])]
        if sql == "SELECT USER_NAME FROM EXA_DBA_USERS":
            return [{"USER_NAME": u} for u in doc.get("users", ["SYS", "MCP_READONLY"])]
        if sql == "SELECT SYSTEM_VALUE FROM EXA_PARAMETERS WHERE PARAMETER_NAME = 'SCRIPT_LANGUAGES'":
            # Measured: a custom container appears as its alias once installed.
            value = "R=builtin_r JAVA=builtin_java PYTHON3=builtin_python3"
            if doc["rust"]:
                value += " RUST=localzmq+protobuf:///__builtin__/slc/custom-rust?lang=rust#/exaudf/exaudfclient"
            return [{"SYSTEM_VALUE": value}]
        if sql == "SELECT POSIX_TIME() AS T":
            # The database clock: this computer's, shifted by clock_skew seconds.
            import time
            return [{"T": "%.3f" % (time.time() + doc.get("clock_skew", 0))}]
        if sql.startswith("SELECT EXAKIT_VS.EXAKIT_TLS_BUILD("):
            # The kit's TLS helper, compiled by the database's Java: a stand-in
            # class, or the compiler's absence (tls_compiler false).
            if "EXAKIT_VS.EXAKIT_TLS_BUILD" not in doc["scripts"]:
                raise Exception("function EXAKIT_VS.EXAKIT_TLS_BUILD not found")
            doc["tls_builds"] = doc.get("tls_builds", 0) + 1
            if doc.get("tls_compiler") is False:
                return [{"NAME": "ERROR", "B64": "no Java compiler in the database's Java container"}]
            import base64
            src = sql.replace("''", "'")
            name = "%s/%s.class" % (re.search(r"package ([\w.]+);", src).group(1).replace(".", "/"),
                                    re.search(r"public (?:final )?class (\w+)", src).group(1))
            return [{"NAME": name, "B64": base64.b64encode(b"\xca\xfe\xba\xbe-stand-in").decode()}]
        m = re.search(r"FROM EXA_DBA_VIRTUAL_TABLES WHERE TABLE_SCHEMA = '([^']+)'", sql)
        if m:
            vs = doc["virtual"].get(m.group(1))
            return [{"TABLE_NAME": t} for t in (vs["tables"] if vs else [])]
        m = re.match(r"SELECT \* FROM \(IMPORT FROM JDBC AT \"([^\"]+)\" STATEMENT '", sql)
        if m:
            _loader_trust(doc, m.group(1))
            src = _source_for(doc, m.group(1), "loader")
            if "''missing''" in sql:
                # The schema check: the source's "schemas" ({name: "ok" |
                # "denied" | "case:<NAME>"}) answers; without it, every name is.
                words = ("ok", "denied", "missing", "case:", "USAGE", "SCHEMA", "SELECT")
                value = next((v for v in re.findall(r"''([^']*)''", sql) if v not in words), "")
                answer = "ok" if "schemas" not in src else src["schemas"].get(value, "missing")
                doc.setdefault("scope_checks", []).append(value)
                return [{"ANSWER": answer}]
            return [{"1": 1}]
        m = re.match(r'SELECT \* FROM "([^"]+)"\."([^"]+)" LIMIT 1', sql)
        if m:
            vs = doc["virtual"].get(m.group(1))
            if vs is None:
                raise Exception("schema %s not found" % m.group(1))
            # A JDBC adapter pushes the read down as IMPORT FROM JDBC: the loader runs it.
            _loader_trust(doc, vs["connection"])
            src = _source_for(doc, vs["connection"], "loader")
            if src.get("read_error"):
                raise Exception(src["read_error"])
            return [] if m.group(2) in src.get("empty", []) else [{"X": 1}]
        raise Exception("fake: unexpected query: %s" % sql[:80])

    def _execute(self, doc, sql):
        if doc.get("vs_fail") and sql.startswith("CREATE VIRTUAL SCHEMA"):
            raise Exception(doc["vs_fail"])
        if sql == "CREATE SCHEMA EXAKIT_VS":
            doc["schemas"].append("EXAKIT_VS")
            return
        m = re.match(r"CREATE OR REPLACE (JAVA|RUST|LUA) (SCALAR|ADAPTER|SET) SCRIPT (?:\"?)([\w]+)(?:\"?)\.(?:\"?)([\w]+)", sql)
        if m:
            if m.group(3) not in doc["schemas"]:
                # Exasol resolves the name first: a script needs its schema to exist.
                column = m.start(3) + (0 if sql[m.start(3) - 1] == '"' else 1)
                raise _query_error("schema %s not found [line 1, column %d]" % (m.group(3), column), sql)
            if not doc[m.group(1).lower()]:
                raise Exception("No usable script language container is installed for the requested language.")
            if m.group(1) == "JAVA" and doc["java"] == "builtin":
                raise Exception("VM error: The required executable '/exaudf/exaudfclient' does not exist in BucketFS")
            name = "%s.%s" % (m.group(3), m.group(4))
            if name in doc.get("script_fail", []):
                raise Exception("VM error: could not create script %s" % name)
            if name not in doc["scripts"]:
                doc["scripts"].append(name)
            return
        m = re.match(r"CREATE (OR REPLACE )?CONNECTION \"([^\"]+)\" TO '((?:[^']|'')*)'(?: USER '((?:[^']|'')*)' IDENTIFIED BY '((?:[^']|'')*)')?$", sql)
        if m:
            if doc.get("connection_fail"):
                raise _query_error(doc["connection_fail"], sql)
            if not m.group(1) and m.group(2) in doc["connections"]:
                raise Exception("connection %s already exists (statement: %s)" % (m.group(2), sql))
            if m.group(2) in doc.get("create_fail", []):
                raise Exception("could not create connection %s (test)" % m.group(2))
            doc["connections"][m.group(2)] = {"url": m.group(3), "user": (m.group(4) or "").replace("''", "'"),
                                              "secret": (m.group(5) or "").replace("''", "'")}
            return
        m = re.match(r"ALTER CONNECTION \"([^\"]+)\" TO '((?:[^']|'')*)'$", sql)
        if m:
            # The address alone: the user and password go with it (measured).
            con = doc["connections"].get(m.group(1))
            if con is None:
                raise Exception("connection %s not found" % m.group(1))
            con["url"] = m.group(2)
            con["user"], con["secret"] = "", ""
            doc.setdefault("altered", []).append(m.group(1))
            return
        m = re.match(r'RENAME CONNECTION "([^"]+)" TO "([^"]+)"$', sql)
        if m:
            if m.group(1) not in doc["connections"]:
                raise Exception("connection %s not found" % m.group(1))
            if m.group(2) in doc.get("rename_fail", []):
                raise Exception("could not rename connection %s (test)" % m.group(1))
            if m.group(2) in doc["connections"]:
                raise Exception("connection %s already exists" % m.group(2))
            doc["connections"][m.group(2)] = doc["connections"].pop(m.group(1))
            return
        m = re.match(r"ALTER VIRTUAL SCHEMA \"([^\"]+)\" SET ((?:\w+ = '(?:[^']|'')*' ?)+)$", sql)
        if m:
            # The adapter reads the source's metadata again with the new
            # properties (set_fail: it fails, as an adapter that cannot).
            vs = doc["virtual"][m.group(1)]
            if doc.get("set_fail") or (doc.get("set_fail_when") and doc["set_fail_when"] in sql):
                raise Exception(doc.get("set_fail") or "adapter refused the properties (test)")
            src = _source_for(doc, vs["connection"])
            vs.setdefault("properties", {}).update(re.findall(r"(\w+) = '((?:[^']|'')*)'", m.group(2)))
            if "tables" in src:
                vs["tables"] = list(src["tables"])
            return
        m = re.match(r'CREATE VIRTUAL SCHEMA "([^"]+)" USING .* CONNECTION_NAME = \'([^\']+)\' MAPPING = \'([^\']+)\'', sql)
        if m:
            # Measured: with explicit fields the adapter reads no object until a
            # query; a CSV or Parquet source without them is read to infer them.
            for mapping in _mappings(m.group(3)):
                if "mapping" not in mapping and mapping["source"].lower().endswith((".csv", ".parquet")):
                    try:
                        _source_for(doc, m.group(2))
                    except Exception as error:
                        raise _inferred(error, mapping["source"])
            doc["virtual"][m.group(1)] = {"connection": m.group(2), "tables": _mapping_tables(m.group(3))}
            return
        m = re.match(r'CREATE VIRTUAL SCHEMA "([^"]+)" USING .* MONGODB_CONNECTION = \'([^\']+)\' '
                     r'DATABASE = \'([^\']+)\' COLLECTION = \'([^\']+)\'', sql)
        if m:
            # Measured (exasol-mongodb-vs 0.1.3): CREATE reads the collection's
            # metadata, so a wrong password fails here; a collection the account
            # may not read is reported as one that does not exist.
            src = _source_for(doc, m.group(2))
            coll = "%s.%s" % (m.group(3), m.group(4))
            if src.get("collections") is not None and coll not in src["collections"]:
                raise Exception("VM error: F-UDF-CL-RUST-9001: UDF error: MongoDB collection '%s' does not exist" % coll)
            doc["virtual"][m.group(1)] = {"connection": m.group(2), "tables": list(src.get("tables", []))}
            return
        m = re.match(r'CREATE VIRTUAL SCHEMA "([^"]+)" USING .* CATALOG_CONNECTION = \'([^\']+)\' '
                     r'CATALOG_KIND = \'GLUE\' NAMESPACE = \'([^\']+)\'', sql)
        if m:
            src = _glue_source(doc, doc["connections"][m.group(2)], m.group(3))
            doc.setdefault("namespaces", {})[m.group(2)] = m.group(3)
            doc["virtual"][m.group(1)] = {"connection": m.group(2), "tables": src["tables"]}
            return
        m = re.match(r'CREATE VIRTUAL SCHEMA "([^"]+)" USING \S+ WITH CATALOG_CONNECTION = \'([^\']+)\'((?: \w+ = \'[^\']*\')*)$', sql)
        if m:
            # An Iceberg REST catalog or Unity Catalog: CREATE lists the namespace's tables.
            props = dict(re.findall(r"(\w+) = '([^']*)'", m.group(3)))
            src = _catalog_source(doc, doc["connections"][m.group(2)], props)
            doc.setdefault("catalogs", {})[m.group(2)] = props
            doc["virtual"][m.group(1)] = {"connection": m.group(2), "tables": src["tables"]}
            return
        m = re.match(r'CREATE VIRTUAL SCHEMA "([^"]+)" USING .* CONNECTION_NAME = \'([^\']+)\'', sql)
        if m:
            src = _source_for(doc, m.group(2))
            doc["virtual"][m.group(1)] = {"connection": m.group(2), "tables": list(src.get("tables", []))}
            return
        m = re.match(r'ALTER VIRTUAL SCHEMA "([^"]+)" REFRESH', sql)
        if m:
            vs = doc["virtual"][m.group(1)]
            if m.group(1) in doc.get("refresh_fail", []):
                raise Exception(doc.get("refresh_error") or "Connection refused. Check that the hostname and port are correct")
            src = _source_for(doc, vs["connection"])
            if "tables" in src:
                vs["tables"] = list(src["tables"])
            return
        m = re.match(r'DROP (FORCE )?VIRTUAL SCHEMA (?:IF EXISTS )?"([^"]+)"', sql)
        if m:
            vs = doc["virtual"].get(m.group(2))
            if vs and not m.group(1) and vs["connection"] not in doc["connections"]:
                raise Exception("adapter call failed: connection %s not found" % vs["connection"])
            doc["virtual"].pop(m.group(2), None)
            return
        m = re.match(r'DROP (?:ADAPTER )?SCRIPT "([^"]+)"\."([^"]+)"', sql)
        if m and "%s.%s" % m.groups() in doc.get("drop_fail", []):
            raise Exception("cannot drop script %s.%s: object is in use (test)" % m.groups())
        m = re.match(r'DROP ADAPTER SCRIPT "([^"]+)"\."([^"]+)"', sql)
        if m:
            users = _adapter_users(doc, "%s.%s" % m.groups())
            if users:
                raise Exception("cannot drop adapter script %s.%s: virtual schema %s depends on it"
                                % (m.group(1), m.group(2), users[0]))
            doc["scripts"] = [s for s in doc["scripts"] if s != "%s.%s" % m.groups()]
            return
        m = re.match(r'DROP SCRIPT "([^"]+)"\."([^"]+)"$', sql)
        if m:
            doc["scripts"] = [s for s in doc["scripts"] if s != "%s.%s" % m.groups()]
            return
        if sql == "DROP SCRIPT EXAKIT_VS.EXAKIT_TLS_BUILD":
            doc["scripts"] = [s for s in doc["scripts"] if s != "EXAKIT_VS.EXAKIT_TLS_BUILD"]
            return
        m = re.match(r'DROP CONNECTION (?:IF EXISTS )?"([^"]+)"', sql)
        if m:
            doc["connections"].pop(m.group(1), None)
            return
        m = re.match(r'DROP SCHEMA "?(\w+)"?( CASCADE)?$', sql)
        if m:
            users = _adapter_users(doc, m.group(1) + ".")
            if users:
                raise Exception("cannot drop schema %s: virtual schema %s depends on an adapter script in it"
                                % (m.group(1), users[0]))
            left = [s for s in doc["scripts"] if s.startswith(m.group(1) + ".")]
            if left and not m.group(2):
                raise Exception("schema %s is not empty - use DROP SCHEMA ... CASCADE" % m.group(1))
            doc["schemas"] = [s for s in doc["schemas"] if s != m.group(1)]
            doc["scripts"] = [s for s in doc["scripts"] if not s.startswith(m.group(1) + ".")]
            return
        raise Exception("fake: unexpected statement: %s" % sql[:80])


def connect(**kwargs):
    return Fake()
