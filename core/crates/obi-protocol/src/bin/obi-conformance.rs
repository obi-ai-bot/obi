//! The Obi-to-Obi protocol's conformance cases, judged by `obi-protocol`: what obi-sphere's
//! `node spec/conformance/run.mjs --impl "<this binary>"` runs (spec/conformance/README.md,
//! "Implementation mode"). It reads one case, `{case, context, input}`, on stdin, prints one JSON
//! line with its verdict, and exits 0 to accept, 1 to reject, 2 when stdin isn't a case at all.

use std::io::Read;
use std::process::ExitCode;

fn main() -> ExitCode {
    let mut text = String::new();
    if let Err(e) = std::io::stdin().read_to_string(&mut text) {
        println!(
            "{}",
            serde_json::json!({"verdict": "error", "message": format!("can't read stdin: {e}")})
        );
        return ExitCode::from(2);
    }
    let case: serde_json::Value = match serde_json::from_str(&text) {
        Ok(case) => case,
        Err(e) => {
            println!(
                "{}",
                serde_json::json!({"verdict": "error", "message": format!("stdin is not JSON: {e}")})
            );
            return ExitCode::from(2);
        }
    };
    match obi_protocol::judge(&case) {
        Ok(()) => {
            println!("{}", serde_json::json!({"verdict": "accept"}));
            ExitCode::SUCCESS
        }
        Err(rejection) => {
            println!(
                "{}",
                serde_json::json!({"verdict": "reject", "code": rejection.code, "message": rejection.message})
            );
            ExitCode::from(1)
        }
    }
}
