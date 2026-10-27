//! EXAKIT_SMOKE(x BIGINT) RETURNS VARCHAR(2000): the udf-devkit add-on's proof
//! that Rust UDFs run on the RUST container. The kit registers it with
//!
//!     CREATE OR REPLACE RUST SCALAR SCRIPT STARTER_KIT.EXAKIT_SMOKE(x BIGINT)
//!         RETURNS VARCHAR(2000) AS %udf_object /buckets/bfsdefault/default/udf/libexakit_smoke.so;
//!     SELECT STARTER_KIT.EXAKIT_SMOKE(1);
//!
//! and reads one JSON object back: {"container": "RUST", "rustc": "<rustc
//! --version at build time>", "sdk": "0.33.0", "x": <the argument>}. The rustc
//! string is compared with the container row's pin (setup/udf/udf_tool.py
//! smoke-rust); the argument is echoed so a wrong input binding shows here,
//! not in the user's first UDF. No panic path: a NULL argument reads as null.
use exasol_udf_macros::exasol_udf;
use exasol_udf_sdk::context::UdfContext;
use exasol_udf_sdk::error::UdfError;

/// The container alias this library is built to run in (versions.json: the
/// Rust rows' alias).
const CONTAINER: &str = "RUST";
/// The exasol-udf-sdk this library links; the same crate version is the first
/// half of the ABI fingerprint the database checks at load.
const SDK: &str = "0.33.0";
/// `rustc --version` of the compiling toolchain, set by build.rs.
const RUSTC: &str = env!("RUSTC_VERSION");

/// JSON string literal: the few characters a rustc version string could carry
/// that JSON escapes (quotes, backslashes, control characters).
fn json_string(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// The answer as one JSON object; `x` is the argument (null when NULL).
fn report(x: Option<i64>) -> String {
    let x_text = match x {
        Some(value) => value.to_string(),
        None => "null".to_string(),
    };
    format!(
        "{{\"container\": {}, \"rustc\": {}, \"sdk\": {}, \"x\": {}}}",
        json_string(CONTAINER),
        json_string(RUSTC),
        json_string(SDK),
        x_text
    )
}

#[exasol_udf(name = "EXAKIT_SMOKE")]
fn exakit_smoke(ctx: &mut dyn UdfContext) -> Result<Option<String>, UdfError> {
    let x = ctx.get_i64(0)?;
    Ok(Some(report(x)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_report_is_one_json_object_with_the_four_fields() {
        let text = report(Some(1));
        assert!(text.starts_with("{\"container\": \"RUST\", \"rustc\": \"rustc "), "{text}");
        assert!(text.contains("\"sdk\": \"0.33.0\""));
        assert!(text.ends_with("\"x\": 1}"));
        assert!(report(None).ends_with("\"x\": null}"));
    }

    #[test]
    fn json_strings_are_escaped() {
        assert_eq!(json_string("a\"b\\c\n"), "\"a\\\"b\\\\c\\u000a\"");
    }
}
