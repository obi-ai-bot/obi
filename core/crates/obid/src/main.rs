//! `obid serve --config /path/to/config.json` (docs/runner-api.md, "obid only: configuration").

use std::io::IsTerminal;
use std::path::PathBuf;
use std::process::ExitCode;

use obid::config::Config;

const USAGE: &str = "usage: obid serve --config /path/to/config.json\n       obid --version";

enum Command {
    Serve { config: PathBuf },
    Version,
    Help,
}

fn parse(args: &[String]) -> Result<Command, String> {
    match args {
        [flag] if flag == "--version" || flag == "-V" => Ok(Command::Version),
        [flag] if flag == "--help" || flag == "-h" => Ok(Command::Help),
        [serve, flag, path] if serve == "serve" && flag == "--config" => Ok(Command::Serve {
            config: PathBuf::from(path),
        }),
        [serve, flag] if serve == "serve" && flag.starts_with("--config=") => Ok(Command::Serve {
            config: PathBuf::from(&flag["--config=".len()..]),
        }),
        _ => Err(USAGE.into()),
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let command = match parse(&args) {
        Ok(command) => command,
        Err(usage) => {
            eprintln!("{usage}");
            return ExitCode::from(2);
        }
    };
    let config_path = match command {
        Command::Version => {
            println!("obid {}", env!("CARGO_PKG_VERSION"));
            return ExitCode::SUCCESS;
        }
        Command::Help => {
            println!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        Command::Serve { config } => config,
    };

    // The runtime, then SIGTERM and SIGINT caught, before anything else: from here on a stop
    // signal, however early, ends obid with exit 0 (docs/runner-api.md, "obid only").
    let runtime = match tokio::runtime::Runtime::new() {
        Ok(runtime) => runtime,
        Err(e) => {
            eprintln!("obid: can't start the runtime: {e}");
            return ExitCode::FAILURE;
        }
    };
    let stop = {
        let _entered = runtime.enter();
        match obid::StopSignal::install() {
            Ok(stop) => stop,
            Err(e) => {
                eprintln!("obid: can't catch SIGTERM and SIGINT: {e}");
                return ExitCode::FAILURE;
            }
        }
    };

    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_ansi(std::io::stderr().is_terminal())
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_env("OBID_LOG")
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let config = match Config::load(&config_path) {
        Ok(config) => config,
        Err(e) => {
            eprintln!("obid: {e}");
            return ExitCode::from(2);
        }
    };
    if let Err(e) = obid::prepare_home(&config) {
        eprintln!("obid: {e}");
        return ExitCode::FAILURE;
    }
    let from_env = std::env::var_os(obid::token::ENV).map(|v| v.to_string_lossy().into_owned());
    let token = match obid::token::load(&config.home, from_env) {
        Ok(token) => token,
        Err(e) => {
            eprintln!("obid: {e}");
            return ExitCode::FAILURE;
        }
    };

    let result = runtime.block_on(obid::serve(config, token, stop.wait(), |address| {
        // One line on stdout that says where obid answers; never the token.
        println!("obid listening on http://{address}");
        tracing::info!(%address, "obid listening");
    }));
    // Whatever a connection still holds, obid has stopped answering: don't wait on it.
    runtime.shutdown_timeout(std::time::Duration::from_secs(1));
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("obid: {e}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn commands() {
        assert!(
            matches!(parse(&args(&["serve", "--config", "/c.json"])), Ok(Command::Serve { config }) if config.as_path() == Path::new("/c.json"))
        );
        assert!(
            matches!(parse(&args(&["serve", "--config=/c.json"])), Ok(Command::Serve { config }) if config.as_path() == Path::new("/c.json"))
        );
        assert!(matches!(parse(&args(&["--version"])), Ok(Command::Version)));
        for wrong in [
            &[][..],
            &["serve"],
            &["serve", "--config"],
            &["serve", "/c.json"],
            &["run", "--config", "/c.json"],
        ] {
            assert!(parse(&args(wrong)).is_err(), "{wrong:?}");
        }
    }
}
