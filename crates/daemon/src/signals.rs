use anyhow::{Context, Result};

#[cfg(unix)]
use tokio::signal::unix::{Signal as Interrupt, SignalKind, signal};
#[cfg(windows)]
use tokio::signal::windows::{CtrlC as Interrupt, ctrl_c};

pub struct ShutdownSignals {
    interrupt: Interrupt,
    #[cfg(unix)]
    terminate: Interrupt,
}

impl ShutdownSignals {
    pub fn register() -> Result<Self> {
        #[cfg(unix)]
        {
            Ok(Self {
                interrupt: signal(SignalKind::interrupt()).context("register SIGINT handler")?,
                terminate: signal(SignalKind::terminate()).context("register SIGTERM handler")?,
            })
        }
        #[cfg(windows)]
        {
            Ok(Self {
                interrupt: ctrl_c().context("register Ctrl-C handler")?,
            })
        }
    }

    pub async fn wait(&mut self) -> Result<&'static str> {
        #[cfg(unix)]
        {
            tokio::select! {
                signal = self.interrupt.recv() => {
                    signal.context("SIGINT listener closed")?;
                    Ok("SIGINT")
                }
                signal = self.terminate.recv() => {
                    signal.context("SIGTERM listener closed")?;
                    Ok("SIGTERM")
                }
            }
        }
        #[cfg(windows)]
        {
            self.interrupt
                .recv()
                .await
                .context("Ctrl-C listener closed")?;
            Ok("ctrl_c")
        }
    }
}
