//! A `cargo` stand-in for JSON Tables on Windows.
//!
//! WHY THIS EXISTS AT ALL
//!
//! JSON Tables runs its Rust ingest engine through exactly one call shape, in
//! `python/exasol_json_tables/cli.py`:
//!
//! ```text
//! subprocess.run(["cargo", "run", "--manifest-path", <crate>/Cargo.toml,
//!                 "--", "--input", ...])
//! ```
//!
//! The kit ships that engine prebuilt for every platform, so nobody needs a
//! Rust toolchain. On macOS and Linux a five-line `/bin/sh` script named
//! `cargo` sits in front of the CLI on PATH and answers that one call - see
//! `json_tables_write_shim` in `setup/lib/json-tables.sh`, whose behaviour this
//! program mirrors exactly.
//!
//! That trick cannot work on Windows. `subprocess.run` with an argument list
//! goes to `CreateProcess`, and `CreateProcess` resolves a bare name by
//! appending `.exe` only - it never consults `PATHEXT` - so a `cargo.cmd` or
//! `cargo.bat` on PATH is simply not found. The answer has to be a real
//! executable, which is what this is. It is built once by CI
//! (`.github/workflows/pkg-json-tables.yml`) and published to the
//! `mirror-json-tables` release, so the user still never needs a toolchain -
//! the requirement moves to our build machine, which is the whole point.
//!
//! WHAT IT DOES
//!
//!   * `cargo run … json_tables_ingest … -- <args>` -> exec the prebuilt
//!     engine with `<args>`, and exit with the engine's own exit code.
//!   * anything else -> hand over to a real `cargo` on PATH, if the user has
//!     one, so this can never quietly break an unrelated command that happens
//!     to run inside the kit's launcher.
//!   * no real cargo, and not our call -> exit 127 saying so, like the shell
//!     shim does.
//!
//! FINDING THE ENGINE
//!
//! The shell shim has its engine path baked in at install time by `sed`. A
//! compiled binary cannot be templated per machine, so the path arrives one of
//! two ways, checked in this order:
//!
//!   1. `EXAKIT_JSON_TABLES_ENGINE` - set by the kit's launcher.
//!   2. a sibling of this executable, named `exasol-json-tables-ingest.exe`.
//!
//! The env var is what the launcher actually uses; the sibling lookup keeps
//! the shim usable if it is ever invoked without the launcher's environment.

use std::env;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

const ENGINE_ENV: &str = "EXAKIT_JSON_TABLES_ENGINE";
const ENGINE_SIBLING: &str = "exasol-json-tables-ingest.exe";
const INGEST_MARKER: &str = "json_tables_ingest";

/// Is this the ingest call the kit can answer?
///
/// Deliberately the same two-part test the shell shim makes: the subcommand is
/// `run`, and some argument mentions the ingest crate. Matching on the crate
/// name rather than the full manifest path is what keeps this working when
/// upstream moves the crate inside its tree.
fn is_ingest_call(args: &[OsString]) -> bool {
    match args.first() {
        Some(first) if first == "run" => {}
        _ => return false,
    }
    args.iter()
        .any(|a| a.to_string_lossy().contains(INGEST_MARKER))
}

/// The engine's own argv: everything after the first bare `--`.
///
/// Returns None when there is no separator at all, which would mean a `cargo
/// run` we recognised but cannot forward. That is a broken call, not an empty
/// one, and the caller reports it rather than running the engine with no
/// arguments (which would ingest nothing and report success).
fn engine_args(args: &[OsString]) -> Option<Vec<OsString>> {
    let idx = args.iter().position(|a| a == "--")?;
    Some(args[idx + 1..].to_vec())
}

/// Where the prebuilt engine is: the launcher's env var, else a sibling of
/// this executable.
fn engine_path() -> Option<PathBuf> {
    if let Some(p) = env::var_os(ENGINE_ENV) {
        if !p.is_empty() {
            let p = PathBuf::from(p);
            if p.is_file() {
                return Some(p);
            }
        }
    }
    let exe = env::current_exe().ok()?;
    let sibling = exe.parent()?.join(ENGINE_SIBLING);
    if sibling.is_file() {
        return Some(sibling);
    }
    None
}

/// The first real `cargo` on PATH that is not this shim.
///
/// "Not this shim" is decided by directory, the same way the shell shim skips
/// its own shim dir: comparing the resolved parent of our own executable
/// against each PATH entry. Without that, a shim early on PATH would find
/// itself and recurse until the process table gave out.
fn real_cargo(self_dir: Option<&Path>) -> Option<PathBuf> {
    let path = env::var_os("PATH")?;
    for dir in env::split_paths(&path) {
        if let Some(sd) = self_dir {
            if same_dir(&dir, sd) {
                continue;
            }
        }
        // Windows resolves a bare command name to .exe, but a user's cargo may
        // legitimately be a .bat/.cmd shim (rustup installs one in some
        // setups). We are launching it ourselves here, not relying on
        // CreateProcess name resolution, so all three are fair game.
        for name in ["cargo.exe", "cargo.cmd", "cargo.bat"] {
            let candidate = dir.join(name);
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

/// Compare two directories without requiring either to exist.
///
/// `canonicalize` is tried first so that `C:\a\..\b` and `C:\b` match, but a
/// PATH entry that does not exist must not abort the walk - a stale PATH entry
/// is ordinary, and it is not a reason to fail to find a real cargo further
/// along.
fn same_dir(a: &Path, b: &Path) -> bool {
    match (a.canonicalize(), b.canonicalize()) {
        (Ok(x), Ok(y)) => x == y,
        _ => a == b,
    }
}

fn run(args: Vec<OsString>) -> ExitCode {
    let self_dir = env::current_exe()
        .ok()
        .and_then(|e| e.parent().map(Path::to_path_buf));

    if is_ingest_call(&args) {
        let forwarded = match engine_args(&args) {
            Some(a) => a,
            None => {
                eprintln!(
                    "cargo (Exasol kit shim): this is the JSON Tables ingest call, \
                     but it carries no `--` separator, so there are no engine \
                     arguments to forward."
                );
                return ExitCode::from(2);
            }
        };
        let engine = match engine_path() {
            Some(p) => p,
            None => {
                eprintln!(
                    "cargo (Exasol kit shim): the prebuilt JSON Tables ingest engine \
                     was not found. Set {ENGINE_ENV} to it, or place {ENGINE_SIBLING} \
                     next to this shim. Repair with: exakit update json-tables"
                );
                return ExitCode::from(127);
            }
        };
        return spawn(&engine, &forwarded);
    }

    // Not our call. A real cargo, if the user has one, must see it unchanged.
    match real_cargo(self_dir.as_deref()) {
        Some(cargo) => spawn(&cargo, &args),
        None => {
            eprintln!(
                "cargo: not installed, and this is not the JSON Tables ingest call \
                 the kit can answer."
            );
            ExitCode::from(127)
        }
    }
}

/// Run `program` with `args` and become its exit code.
///
/// Windows has no `exec`, so the shim stays alive as the parent and forwards
/// the status. stdio is inherited, so the engine's own output and any prompt
/// reach the caller untouched.
fn spawn(program: &Path, args: &[OsString]) -> ExitCode {
    match Command::new(program).args(args).status() {
        Ok(status) => match status.code() {
            // A Windows exit code is a full i32; ExitCode carries a u8. Anything
            // that does not fit is still a failure, and must not be truncated
            // into a 0 that reads as success.
            Some(0) => ExitCode::SUCCESS,
            Some(c) if (1..=255).contains(&c) => ExitCode::from(c as u8),
            _ => ExitCode::FAILURE,
        },
        Err(e) => {
            eprintln!(
                "cargo (Exasol kit shim): could not run {}: {e}",
                program.display()
            );
            ExitCode::from(126)
        }
    }
}

fn main() -> ExitCode {
    run(env::args_os().skip(1).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn a(v: &[&str]) -> Vec<OsString> {
        v.iter().map(OsString::from).collect()
    }

    #[test]
    fn recognises_the_real_upstream_call() {
        // Verbatim shape from python/exasol_json_tables/cli.py.
        let args = a(&[
            "run",
            "--manifest-path",
            "/x/crates/json_tables_ingest/Cargo.toml",
            "--",
            "--input",
            "in.json",
            "--output",
            "out.parquet",
        ]);
        assert!(is_ingest_call(&args));
        assert_eq!(
            engine_args(&args).unwrap(),
            a(&["--input", "in.json", "--output", "out.parquet"])
        );
    }

    #[test]
    fn a_release_flavoured_call_still_matches() {
        let args = a(&[
            "run",
            "--release",
            "--manifest-path",
            "crates/json_tables_ingest/Cargo.toml",
            "--",
            "--input",
            "in.json",
        ]);
        assert!(is_ingest_call(&args));
        assert_eq!(engine_args(&args).unwrap(), a(&["--input", "in.json"]));
    }

    #[test]
    fn unrelated_cargo_commands_are_not_ours() {
        assert!(!is_ingest_call(&a(&["build", "--release"])));
        assert!(!is_ingest_call(&a(&["--version"])));
        assert!(!is_ingest_call(&a(&[])));
        // `run`, but for somebody else's crate: must go to a real cargo, or the
        // shim would hijack an unrelated build inside the kit's launcher.
        assert!(!is_ingest_call(&a(&[
            "run",
            "--manifest-path",
            "/x/other_crate/Cargo.toml"
        ])));
    }

    #[test]
    fn a_separator_with_no_arguments_after_it_is_empty_not_missing() {
        let args = a(&["run", "--manifest-path", "json_tables_ingest", "--"]);
        assert_eq!(engine_args(&args).unwrap().len(), 0);
    }

    #[test]
    fn a_call_with_no_separator_is_reported_not_guessed() {
        let args = a(&["run", "--manifest-path", "json_tables_ingest"]);
        assert!(is_ingest_call(&args));
        assert!(engine_args(&args).is_none());
    }

    #[test]
    fn only_the_first_separator_splits() {
        // `--` can legitimately appear again in the engine's own argv; it must
        // be forwarded, not treated as a second split point.
        let args = a(&["run", "json_tables_ingest", "--", "--input", "--", "x"]);
        assert_eq!(engine_args(&args).unwrap(), a(&["--input", "--", "x"]));
    }

    #[test]
    fn directory_comparison_tolerates_paths_that_do_not_exist() {
        assert!(same_dir(
            Path::new("/no/such/dir"),
            Path::new("/no/such/dir")
        ));
        assert!(!same_dir(Path::new("/no/such/a"), Path::new("/no/such/b")));
    }
}
