// Bakes `rustc --version` into the library as RUSTC_VERSION, so the smoke UDF
// reports the toolchain it was compiled with and the kit can hold it against
// the matrix row (versions.json containers[].runtime.rustc). Read from the
// same RUSTC cargo hands every build script, as exasol-udf-sdk's own build.rs
// does for the ABI fingerprint.
use std::env;
use std::process::Command;

fn main() {
    let rustc = env::var("RUSTC").unwrap_or_else(|_| "rustc".to_string());
    let output = Command::new(rustc)
        .arg("--version")
        .output()
        .expect("rustc not found");
    let version = String::from_utf8_lossy(&output.stdout).trim().to_string();
    println!("cargo:rustc-env=RUSTC_VERSION={}", version);
    println!("cargo:rerun-if-changed=build.rs");
}
