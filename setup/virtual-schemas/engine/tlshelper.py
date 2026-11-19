"""The kit's Java helpers, compiled by the database's own Java.

The TLS helper is a trust manager mssql-jdbc loads by class name. The loader
helper is the JDBC loader's main class for drivers that read trust only from
the JVM's default store (Snowflake): it points the loader's JVM at the
language container's own CA store, then hands every call to the real driver.
Measured on Exasol Personal 2.3.0: the loader runs the container's Java
outside the container, where its cacerts is a dangling absolute symlink, so
it trusts nothing ("the trustAnchors parameter must be non-empty").

TLS helper:

mssql-jdbc reads trust from a file only (treating one it cannot find as
empty), and on Exasol Personal no path reaches both of its readers: the
adapter runs in a sandbox that sees the bucket at /buckets, the loader runs in
/ of the database container and sees it at /exa/bucketfs (measured). Its
documented alternative is a TrustManager class named in the URL
(trustManagerClass, trustManagerConstructorArg). The helper trusts exactly the
CA certificates in that argument and checks the host name itself - with a
custom class the driver checks no host name (mssql-jdbc 13.4 source).

Each class ships as source (setup/virtual-schemas/java/), never as a binary.
It is compiled by the database's own Java through a temporary UDF and packaged
here into a deterministic jar, cached by the source's SHA-256.
"""

import base64
import hashlib
import io
import os
import zipfile

import sql

BUILD = "EXAKIT_TLS_BUILD"
JAR_NAME = "exakit-tls.jar"
CLASS = "exakit.tls.PemTrustManager"
LOADER_JAR = "exakit-loader.jar"
LOADER_MAIN = "exakit.loader.TrustStoreDriver"

# helper -> (source under java/, jar name, the class the jar must hold)
HELPERS = {
    "tls": (("exakit", "tls", "PemTrustManager.java"), JAR_NAME, "exakit/tls/PemTrustManager.class"),
    "loader": (("exakit", "loader", "TrustStoreDriver.java"), LOADER_JAR, "exakit/loader/TrustStoreDriver.class"),
}


class HelperError(Exception):
    pass


def source_path(defs_root, helper="tls"):
    return os.path.join(defs_root, "java", *HELPERS[helper][0])


def build_sql(filename="PemTrustManager.java"):
    return ("CREATE OR REPLACE JAVA SCALAR SCRIPT EXAKIT_VS.%s(src VARCHAR(2000000)) "
            "EMITS (name VARCHAR(200), b64 VARCHAR(2000000)) AS\n"
            "class %s {\n"
            "  static void run(ExaMetadata exa, ExaIterator ctx) throws Exception {\n"
            "    java.nio.file.Path dir = java.nio.file.Files.createTempDirectory(\"exakit-tls\");\n"
            "    java.nio.file.Path file = dir.resolve(\"%s\");\n"
            "    java.nio.file.Files.write(file, ctx.getString(\"src\").getBytes(java.nio.charset.StandardCharsets.UTF_8));\n"
            "    javax.tools.JavaCompiler jc = javax.tools.ToolProvider.getSystemJavaCompiler();\n"
            "    if (jc == null) { ctx.emit(\"ERROR\", \"no Java compiler in the database's Java container\"); return; }\n"
            "    java.io.ByteArrayOutputStream err = new java.io.ByteArrayOutputStream();\n"
            "    java.nio.file.Path out = dir.resolve(\"out\");\n"
            "    if (jc.run(null, null, err, \"--release\", \"11\", \"-d\", out.toString(), file.toString()) != 0) {\n"
            "      ctx.emit(\"ERROR\", err.toString()); return;\n"
            "    }\n"
            "    try (java.util.stream.Stream<java.nio.file.Path> s = java.nio.file.Files.walk(out)) {\n"
            "      for (java.nio.file.Path p : (Iterable<java.nio.file.Path>) s::iterator) {\n"
            "        if (p.toString().endsWith(\".class\")) {\n"
            "          ctx.emit(out.relativize(p).toString().replace('\\\\', '/'),\n"
            "                   java.util.Base64.getEncoder().encodeToString(java.nio.file.Files.readAllBytes(p)));\n"
            "        }\n"
            "      }\n"
            "    }\n"
            "  }\n"
            "}\n/" % (BUILD, BUILD, filename))


def package(classes):
    """A jar with fixed timestamps and order, so the same classes give the same bytes."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as jar:
        for name, data in [("META-INF/MANIFEST.MF", b"Manifest-Version: 1.0\r\nCreated-By: exakit\r\n\r\n")] + \
                sorted(classes.items()):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            jar.writestr(info, data)
    return buf.getvalue()


def jar(db, defs_root, cache_root, helper="tls"):
    """The helper jar's path in the cache, building it in the database first
    when this source has not been built before. EXAKIT_VS must exist."""
    parts, jar_name, class_file = HELPERS[helper]
    with open(source_path(defs_root, helper), encoding="utf-8") as handle:
        source = handle.read()
    key = hashlib.sha256(source.encode("utf-8")).hexdigest()
    dest = os.path.join(cache_root, "tls-helper", key, jar_name)
    if os.path.isfile(dest):
        return dest
    db.execute(build_sql(parts[-1]))
    try:
        rows = db.query("SELECT EXAKIT_VS.%s(%s)" % (BUILD, sql.literal(source)))
    finally:
        try:
            db.execute("DROP SCRIPT EXAKIT_VS.%s" % BUILD)
        except sql.DbError:
            pass
    classes = {}
    for row in rows:
        name, data = row.get("NAME"), row.get("B64")
        if name == "ERROR" or not name:
            raise HelperError("the kit's %s helper could not be built in the database: %s"
                              % ("TLS" if helper == "tls" else "loader", data or "no output"))
        classes[name] = base64.b64decode(data)
    if class_file not in classes:
        raise HelperError("the kit's %s helper was built without its class" % ("TLS" if helper == "tls" else "loader"))
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    partial = dest + ".part"
    with open(partial, "wb") as handle:
        handle.write(package(classes))
    os.replace(partial, dest)
    return dest
