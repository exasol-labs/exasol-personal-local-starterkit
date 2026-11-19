package exakit.tls;

import java.io.ByteArrayInputStream;
import java.security.KeyStore;
import java.security.cert.CertificateException;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.util.Base64;
import java.util.Collection;
import java.util.List;
import java.util.Locale;
import javax.net.ssl.TrustManagerFactory;
import javax.net.ssl.X509TrustManager;

/**
 * Trusts exactly the CA certificates passed in its constructor argument and
 * checks the server's host name - what tls=verify means, without a truststore
 * file. Argument: "<host>|<cert>.<cert>..." with each certificate as unpadded
 * base64url DER.
 */
public final class PemTrustManager implements X509TrustManager {
    private final String host;
    private final X509TrustManager chain;

    public PemTrustManager(String arg) throws Exception {
        int bar = arg.indexOf('|');
        if (bar <= 0) {
            throw new IllegalArgumentException("expected <host>|<certificates>");
        }
        host = arg.substring(0, bar).toLowerCase(Locale.ROOT);
        KeyStore anchors = KeyStore.getInstance("PKCS12");
        anchors.load(null, null);
        CertificateFactory factory = CertificateFactory.getInstance("X.509");
        int index = 0;
        for (String encoded : arg.substring(bar + 1).split("\\.")) {
            byte[] der = Base64.getUrlDecoder().decode(encoded);
            anchors.setCertificateEntry("ca" + index++, factory.generateCertificate(new ByteArrayInputStream(der)));
        }
        TrustManagerFactory tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
        tmf.init(anchors);
        chain = (X509TrustManager) tmf.getTrustManagers()[0];
    }

    @Override
    public void checkServerTrusted(X509Certificate[] certificates, String authType) throws CertificateException {
        chain.checkServerTrusted(certificates, authType);
        if (!matches(certificates[0])) {
            throw new CertificateException("the certificate does not name " + host);
        }
    }

    @Override
    public void checkClientTrusted(X509Certificate[] certificates, String authType) throws CertificateException {
        chain.checkClientTrusted(certificates, authType);
    }

    @Override
    public X509Certificate[] getAcceptedIssuers() {
        return chain.getAcceptedIssuers();
    }

    // RFC 6125: DNS subjectAltNames only (no CN fallback when they exist);
    // a wildcard covers exactly one left-most label.
    private boolean matches(X509Certificate certificate) throws CertificateException {
        Collection<List<?>> names = certificate.getSubjectAlternativeNames();
        boolean anyDns = false;
        if (names != null) {
            for (List<?> name : names) {
                if (Integer.valueOf(2).equals(name.get(0))) {
                    anyDns = true;
                    if (nameMatches(String.valueOf(name.get(1)).toLowerCase(Locale.ROOT))) {
                        return true;
                    }
                }
            }
        }
        if (anyDns) {
            return false;
        }
        String subject = certificate.getSubjectX500Principal().getName();
        for (String part : subject.split(",")) {
            if (part.startsWith("CN=")) {
                return nameMatches(part.substring(3).toLowerCase(Locale.ROOT));
            }
        }
        return false;
    }

    private boolean nameMatches(String pattern) {
        if (pattern.startsWith("*.")) {
            int dot = host.indexOf('.');
            return dot > 0 && host.substring(dot).equals(pattern.substring(1));
        }
        return host.equals(pattern);
    }
}
