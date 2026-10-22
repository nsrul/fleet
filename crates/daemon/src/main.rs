mod signals;

use std::{env, process::ExitCode, time::Duration};

use anyhow::{Context, Result};
use director_engine::{Engine, EngineState};
use director_protocol::{DaemonState, PROTOCOL_VERSION};
use signals::ShutdownSignals;
use tracing::{error, info, level_filters::LevelFilter};
use tracing_subscriber::EnvFilter;

const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(5);

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    match run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            error!(event = "error", error = %format!("{error:#}"));
            ExitCode::FAILURE
        }
    }
}

async fn run() -> Result<()> {
    init_logging()?;
    info!(event = "startup", version = env!("CARGO_PKG_VERSION"));

    // Register handlers before readiness can be observed by another process.
    let mut signals = ShutdownSignals::register()?;
    let mut engine = Engine::start();
    info!(
        event = "ready",
        version = env!("CARGO_PKG_VERSION"),
        protocol_version = PROTOCOL_VERSION,
        pid = std::process::id(),
        state = daemon_state(engine.state()).as_str(),
    );

    let signal = signals.wait().await;
    info!(
        event = "shutdown_requested",
        reason = signal.as_ref().copied().unwrap_or("signal_error"),
    );
    tokio::time::timeout(SHUTDOWN_TIMEOUT, engine.shutdown())
        .await
        .context("engine shutdown exceeded the five-second deadline")?;
    info!(
        event = "stopped",
        state = daemon_state(engine.state()).as_str(),
    );
    signal?;
    Ok(())
}

fn daemon_state(state: EngineState) -> DaemonState {
    match state {
        EngineState::Running => DaemonState::Running,
        EngineState::Stopped => DaemonState::Stopped,
    }
}

fn init_logging() -> Result<()> {
    let filter = match env::var("RUST_LOG") {
        Ok(value) => EnvFilter::builder()
            .with_default_directive(LevelFilter::INFO.into())
            .with_regex(false)
            .parse(value)
            .context("invalid RUST_LOG"),
        Err(env::VarError::NotPresent) => Ok(EnvFilter::new("info")),
        Err(error) => Err(error).context("read RUST_LOG"),
    };
    // Even configuration failures are reported as JSON, using the INFO fallback.
    let (filter, filter_error) = match filter {
        Ok(filter) => (filter, None),
        Err(error) => (EnvFilter::new("info"), Some(error)),
    };
    tracing_subscriber::fmt()
        .json()
        .flatten_event(true)
        .with_ansi(false)
        .with_writer(std::io::stderr)
        .with_env_filter(filter)
        .try_init()
        .map_err(|error| anyhow::anyhow!("initialize JSON logging: {error}"))?;
    if let Some(error) = filter_error {
        return Err(error);
    }
    Ok(())
}
