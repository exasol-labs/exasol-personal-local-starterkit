# Network and TLS (/security/network-and-tls)



The kit listens on this computer only. Its outbound calls are few and listed below. The one that needs the most care is the database connection, because the database uses a self-signed certificate that no client can check against a certificate authority.

## The database certificate is pinned [#the-database-certificate-is-pinned]

The kit records the database's certificate fingerprint once, then every client it builds checks that the port still serves that certificate.

* **What is recorded.** The SHA-256 of the server's DER certificate, as lowercase hex. `fingerprint()` in `setup/lib/tls_pin.py` computes it. It reads the certificate without validating it, because reading it is the point. The value is stored in the manifest as `runtime.tls_fingerprint`, with the time in `runtime.tls_fingerprint_at`.
* **When it is recorded.** When the kit deploys or starts its own database, `exakit_tls_record()` in `setup/lib/common.sh` records the certificate. This is trust on first use, as the code's comment calls it.
* **Who checks it.** The exapump profile gets `certificate_fingerprint` (`exapump_write_profile()` in `setup/lib/exapump.sh`). A pyexasol connection gets the DSN `host/<fingerprint>:port` (`exakit_tls_pinned_dsn()` in `setup/lib/common.sh`). The notebook's `connect()` pins the same way (`_pinned()` in `notebook/package/exakit_nb/__init__.py`).
* **What a mismatch does.** A client refuses a certificate that does not match. `exakit tls-pin` compares the pinned and live values and changes nothing. `exakit tls-pin --accept` records the live certificate, after a question that defaults to no when a pin is being replaced. Its exit code is `6` when the live certificate is not the pinned one (`setup/help/exakit.json`).

The profiles also carry `validate_certificate = false`. That is deliberate: the certificate is self-signed, so the pin is the check. Without a recorded pin, nothing validates the certificate.

Exasol's own documentation describes the same approach for clients that cannot verify a certificate: a SHA-256 fingerprint, which changes whenever the certificate is replaced. See [Upload TLS certificate](https://docs.exasol.com/db/latest/administration/on-premise/access_management/tls_certificate.htm).

### Installs made before the pin existed [#installs-made-before-the-pin-existed]

`exakit_tls_ensure_pinned()` in `setup/lib/common.sh` records a pin the first time a kit command finds the database running and answering. The pin then trusts whatever answered on the port at that time. The code does not compare it with anything earlier.

### The MCP server connection is not pinned in this code [#the-mcp-server-connection-is-not-pinned-in-this-code]

`_mcp_sidecar_definition()` in `setup/lib/mcp.sh` sets the server's connection like this:

```text
EXA_DSN          = $(EXASOL_DB_HOST):$(EXASOL_DB_PORT)     no fingerprint
EXA_SSL_CERT_VALIDATION = "false"
```

`exakit_tls_rewrite_clients()` in `setup/lib/common.sh` says that "the launcher's sidecar entries hold no DSN". The pin reaches the stdio form of the server's `EXA_DSN`, and the other kit clients. It does not reach the sidecar definition in this repository. Whether the launcher adds a pin elsewhere is outside this repository, so this page does not claim one.

## Addresses the kit listens on [#addresses-the-kit-listens-on]

| Listener                      | Address                                             | Source                                                                                          |
| ----------------------------- | --------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Notebook documentation server | `127.0.0.1` (the page is shown as `localhost`)      | `BIND` in `notebook/package/exakit_nb/docs.py`. Its comment says "no other computer reaches it" |
| Exasol MCP server             | `127.0.0.1:4896`, with `--no-auth`                  | `hostIP` and `args` in `_mcp_sidecar_definition()`, `setup/lib/mcp.sh`                          |
| Database                      | The port recorded in the manifest, on this computer | `runtime.dsn` in the manifest                                                                   |

The MCP server has no token. See [AI clients](/security/ai-clients).

## Every outbound call the kit makes [#every-outbound-call-the-kit-makes]

| Call                         | Destination                                                          | When                                                             | Source                                                                        |
| ---------------------------- | -------------------------------------------------------------------- | ---------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Install and update downloads | GitHub release URLs and the launcher's S3 bucket, over HTTPS         | When you install, update or repair                               | `versions.json`; see [Add-ons and downloads](/security/add-ons-and-downloads) |
| Public IP lookup             | `https://checkip.amazonaws.com`, one request per run, 3-second limit | When a source command runs. Skipped with `EXAKIT_NO_IP_LOOKUP=1` | `setup/virtual-schemas/engine/publicip.py`                                    |
| Your model                   | The address in `EXAKIT_PROVIDER_BASE_URL`                            | Only when you use a model helper                                 | [What is sent to a model](/security/what-goes-to-a-model)                     |
| Langfuse                     | The address in `LANGFUSE_BASE_URL`                                   | Only when tracing is on                                          | [What is sent to a model](/security/what-goes-to-a-model)                     |
| External sources             | The source you connected                                             | When the database reads it                                       | [External sources](#external-sources) below                                   |

The public IP is one address and a newline. The module says it is "advice, never a step". It is for allow-listing this computer at a source that filters by address. If the lookup fails, the address is reported as unknown.

Telemetry is turned off by default. `marketplace/kit_telemetry.py` sets `EXASOL_TELEMETRY_DISABLE`, `DBT_SEND_ANONYMOUS_USAGE_STATS=false` and `MLFLOW_DISABLE_TELEMETRY=true` for every process the kit starts, unless you set those variables yourself.

## External sources [#external-sources]

A source is read where it lives. The database connects to it through a virtual schema, and the connection's TLS setting decides how the certificate is checked.

* **The default is `verify`.** `setup/virtual-schemas/engine/paste.py` says "tls stays at verify (TCPS, the kit's default)". The engine's failure advice in `setup/virtual-schemas/engine/lifecycle.py`, `tls_fix()`, names the fix: "fix the server certificate", or give the CA that signs it with `--set ca=<PEM file or bundle>`.
* **`require` encrypts without checking.** `tls_fix()` says it is used "only knowingly". The engine's own advice in `setup/virtual-schemas/engine/sql.py` calls it "encrypts without checking the certificate".
* **A pasted string can change the setting.** `tls_sqlserver()` in `setup/virtual-schemas/engine/paste.py` maps `encrypt=false` to `disable`, and `TrustServerCertificate=true` to `require`. Those values come from the string you paste, not from the kit's defaults. Before you confirm the connection, the kit shows the reading back with its secrets masked. The shell prints it as `Read: ...` in `_exakit_vs_tui_paste()` in `setup/lib/virtual-schemas.sh`.
* **The kit does not lower the setting by itself.** When the paste does not say otherwise, the engine keeps `verify`. An unknown `encrypt` value is reported, and `tls` stays at its default.

## Limits [#limits]

* The pin is recorded on first use. It trusts whatever answered on the port at that moment.
* The MCP server's connection to the database is not pinned in this repository.
* The database connection uses `validate_certificate = false` alongside the pin.
* A pasted SQL Server string can set `tls=disable` for a source. The kit shows that reading before you confirm, but the choice is yours.
* Telemetry is off only for the processes the kit starts. Tools you run yourself follow their own settings.
