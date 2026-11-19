-- exakit: certificate verification for the Databricks adapter's REST calls.
--
-- Appended by the kit after databricks-virtual-schema's dist file, which is
-- kept byte for byte (its SHA-256 is checked). Upstream 1.0.2 calls the REST
-- API with verify_tls_certificate = false (exasol/databricks-virtual-schema
-- issue 4): measured on Exasol Personal 2.3.0, the database's LuaSec 1.3.2
-- refuses every CA file or directory ("Feature not supported: error loading
-- CA locations"), so verify = "peer" can never succeed there.
--
-- What does work, measured: LuaSec loads certificates from memory
-- (ssl.x509.load), and cert:issued() runs OpenSSL's X509_verify_cert on a
-- chain - signatures, validity periods, CA constraints. So this suffix
-- replaces only the adapter's socket factory: it completes the handshake,
-- then verifies the server's chain against the Mozilla CA bundle the kit
-- pinned (inserted below as text) and the host name against the leaf's
-- subjectAltName entries, and closes the socket unless both pass. No request
-- is written to a server that failed either check.
do
    local EXAKIT_CA_BUNDLE <const> = [==[
--@EXAKIT_CA_BUNDLE@
]==]
    local ssl = require("ssl")
    local x509 = require("ssl.x509")
    local socket = require("socket")
    local http_client = require("exasol.adapter.databricks.http_client")

    local PEM <const> = "%-%-%-%-%-BEGIN CERTIFICATE%-%-%-%-%-.-%-%-%-%-%-END CERTIFICATE%-%-%-%-%-"
    local roots = nil

    local function trusted_roots()
        if not roots then
            roots = {}
            for pem in EXAKIT_CA_BUNDLE:gmatch(PEM) do
                local cert = x509.load(pem)
                if cert then
                    roots[#roots + 1] = cert
                end
            end
        end
        return roots
    end

    -- RFC 6125: an exact DNS name, or a wildcard that is the whole leftmost
    -- label of a name with at least two more labels. Never an IP address.
    local function name_matches(pattern, host)
        pattern, host = pattern:lower(), host:lower()
        if pattern == host then
            return true
        end
        local suffix = pattern:match("^%*(%.[^.*]+%.[^*]+)$")
        if not suffix then
            return false
        end
        local first, rest = host:match("^([^.]+)(%..+)$")
        return first ~= nil and rest == suffix
    end

    local function host_matches(cert, host)
        local extensions = cert:extensions() or {}
        local san = extensions["2.5.29.17"] or {}
        for _, name in ipairs(san.dNSName or {}) do
            if name_matches(name, host) then
                return true
            end
        end
        return false
    end

    -- nil and the reason, or true when the chain ends at a trusted root and
    -- the leaf names the host.
    local function verify(conn, host)
        local leaf = conn:getpeercertificate()
        if not leaf then
            return nil, "the server sent no certificate"
        end
        local chain = conn:getpeerchain() or {}
        local reason = "unable to get local issuer certificate"
        local trusted = false
        for _, root in ipairs(trusted_roots()) do
            local ok, err = root:issued(leaf, table.unpack(chain))
            if ok then
                trusted = true
                break
            end
            if err and err ~= "unable to get local issuer certificate" then
                reason = err
            end
        end
        if not trusted then
            return nil, reason
        end
        if not leaf:validat(os.time()) then
            return nil, "certificate has expired or is not yet valid"
        end
        if not host_matches(leaf, host) then
            return nil, "the certificate does not name " .. host
        end
        return true
    end

    local function verified_socket_factory()
        return function()
            local t = {c = socket.try(socket.tcp())}
            function t:connect(host, port)
                socket.try(self.c:connect(host, port))
                self.c = socket.try(ssl.wrap(self.c, {mode = "client", protocol = "tlsv1_2", verify = "none",
                                                      options = "all"}))
                self.c:sni(host)
                socket.try(self.c:dohandshake())
                local ok, reason = verify(self.c, host)
                if not ok then
                    self.c:close()
                    socket.try(nil, "certificate verify failed: " .. reason .. " (" .. host .. ")")
                end
                return 1
            end
            return setmetatable(t, {
                __index = function(tbl, key)
                    local f = function(proxy, ...)
                        local c = proxy.c
                        return c[key](c, ...)
                    end
                    tbl[key] = f
                    return f
                end
            })
        end
    end

    http_client._create_socket_factory = function(args)
        if args.url:match("^http://") then
            error("E-EXAKIT-TLS-1: refusing an unencrypted request to " .. args.url)
        end
        return verified_socket_factory()
    end
end
