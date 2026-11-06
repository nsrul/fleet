mod signals;

#[cfg(unix)]
mod api;
#[cfg(unix)]
mod config;

use std::{env, process::ExitCode, sync::Arc, time::Duration};

#[cfg(unix)]
use anyhow::anyhow;
use anyhow::{Context, Result};
use fleet_engine::{Engine, EngineState};
use fleet_protocol::{DaemonState, PROTOCOL_VERSION};
use signals::ShutdownSignals;
use tokio::sync::Mutex;
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
    let engine = Arc::new(Mutex::new(Engine::start()));

    #[cfg(unix)]
    {
        let config = config::Config::load()?;
        let workspace_path = config
            .socket_path
            .parent()
            .context("the socket path includes a parent directory")?
            .join("workspace.json");
        let mut api = api::ApiServer::bind(
            &config.socket_path,
            config.private_parent,
            Arc::clone(&engine),
            &workspace_path,
        )
        .await?;
        info!(
            event = "ready",
            version = env!("CARGO_PKG_VERSION"),
            protocol_version = PROTOCOL_VERSION,
            pid = std::process::id(),
            state = daemon_state(engine.lock().await.state()).as_str(),
            socket = %api.socket_path().display(),
        );

        enum Stop {
            Signal(Result<&'static str>),
            Api(anyhow::Error),
        }

        let stop = tokio::select! {
            signal = signals.wait() => Stop::Signal(signal),
            result = api.run() => Stop::Api(
                result.err().unwrap_or_else(|| anyhow!("local API accept loop stopped")),
            ),
        };
        let reason = match &stop {
            Stop::Signal(Ok(reason)) => *reason,
            Stop::Signal(Err(_)) => "signal_error",
            Stop::Api(_) => "api_error",
        };
        info!(event = "shutdown_requested", reason);

        tokio::time::timeout(SHUTDOWN_TIMEOUT, async {
            tokio::join!(api.shutdown(), async {
                engine.lock().await.shutdown().await;
            });
        })
        .await
        .context("daemon shutdown exceeded the five-second deadline")?;

        let state = engine.lock().await.state();
        info!(event = "stopped", state = daemon_state(state).as_str());

        match stop {
            Stop::Signal(result) => {
                result?;
            }
            Stop::Api(error) => return Err(error),
        }
    }

    #[cfg(not(unix))]
    {
        info!(
            event = "ready",
            version = env!("CARGO_PKG_VERSION"),
            protocol_version = PROTOCOL_VERSION,
            pid = std::process::id(),
            state = daemon_state(engine.lock().await.state()).as_str(),
            api = "unavailable",
        );

        let signal = signals.wait().await;
        info!(
            event = "shutdown_requested",
            reason = signal.as_ref().copied().unwrap_or("signal_error"),
        );
        tokio::time::timeout(SHUTDOWN_TIMEOUT, async {
            engine.lock().await.shutdown().await;
        })
        .await
        .context("daemon shutdown exceeded the five-second deadline")?;
        info!(
            event = "stopped",
            state = daemon_state(engine.lock().await.state()).as_str(),
        );
        signal?;
    }

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
