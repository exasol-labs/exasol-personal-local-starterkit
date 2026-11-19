package exakit.loader;

import java.io.File;
import java.sql.Connection;
import java.sql.Driver;
import java.sql.DriverManager;
import java.sql.DriverPropertyInfo;
import java.sql.SQLException;
import java.sql.SQLFeatureNotSupportedException;
import java.util.Properties;
import java.util.ServiceLoader;
import java.util.logging.Logger;

/**
 * The JDBC loader's main class on Exasol Personal: it points the loader's JVM at
 * the language container's own CA store, then hands every call to the real
 * driver. The loader runs that Java outside the container, where its cacerts
 * is a dangling absolute symlink - so it trusts nothing. Trust stays the JVM's
 * standard public set; nothing is disabled.
 */
public final class TrustStoreDriver implements Driver {
    static {
        String home = System.getProperty("java.home", "");
        int at = home.indexOf("/lib/jvm/");
        if (System.getProperty("javax.net.ssl.trustStore") == null && at > 0) {
            File store = new File(home.substring(0, at) + "/etc/ssl/certs/java/cacerts");
            if (store.isFile()) {
                System.setProperty("javax.net.ssl.trustStore", store.getPath());
            }
        }
        try {
            DriverManager.registerDriver(new TrustStoreDriver());
        } catch (SQLException e) {
            throw new ExceptionInInitializerError(e);
        }
    }

    private static Driver target(String url) throws SQLException {
        for (Driver d : ServiceLoader.load(Driver.class, TrustStoreDriver.class.getClassLoader())) {
            if (!(d instanceof TrustStoreDriver) && d.acceptsURL(url)) {
                return d;
            }
        }
        throw new SQLException("no JDBC driver on the loader's classpath accepts " + url);
    }

    public Connection connect(String url, Properties info) throws SQLException {
        return acceptsURL(url) ? target(url).connect(url, info) : null;
    }

    public boolean acceptsURL(String url) throws SQLException {
        for (Driver d : ServiceLoader.load(Driver.class, TrustStoreDriver.class.getClassLoader())) {
            if (!(d instanceof TrustStoreDriver) && d.acceptsURL(url)) {
                return true;
            }
        }
        return false;
    }

    public DriverPropertyInfo[] getPropertyInfo(String url, Properties info) throws SQLException {
        return target(url).getPropertyInfo(url, info);
    }

    public int getMajorVersion() { return 1; }

    public int getMinorVersion() { return 0; }

    public boolean jdbcCompliant() { return false; }

    public Logger getParentLogger() throws SQLFeatureNotSupportedException {
        throw new SQLFeatureNotSupportedException();
    }
}
