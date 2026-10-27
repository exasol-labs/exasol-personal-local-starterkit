# Rust smoke libraries

These Linux ELF libraries are compiled from `udf/rust-smoke` for Exasol's Rust
language container. They let `exakit udf-setup --language rust` validate the
container without waiting for a separate GitHub release. `versions.json` pins
their byte size and SHA-256. The installer verifies both before it installs or
reuses the container, then runs the smoke UDF against the database.

Build each architecture inside `docker.io/library/rust:1.98.1-trixie` with
`cargo-exasol-udf =0.33.0` and the checked-in `Cargo.lock`:

```bash
cargo exasol-udf build .
cargo exasol-udf validate target/release/libexakit_smoke.so --deny-unknown-deps
```

The CI `rust-smoke` job rebuilds both architectures, checks these bundled
libraries with the same validator, and verifies their size, digest and ELF
architecture. Replace the binaries and their `versions.json` pins together
when the SDK, rustc or smoke source changes.
