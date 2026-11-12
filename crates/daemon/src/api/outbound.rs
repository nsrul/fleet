use std::sync::Arc;

use fleet_protocol::api::ServerMessage;
use tokio::{
    io::{AsyncWrite, AsyncWriteExt},
    sync::{Semaphore, mpsc, watch},
};

use super::codec::{self, FrameError};

const OUTBOUND_QUEUE_FRAMES: usize = 64;
const OUTBOUND_BUDGET_BYTES: usize = 8 * 1024 * 1024;

pub struct OutboundFrame {
    bytes: Vec<u8>,
    _permit: tokio::sync::OwnedSemaphorePermit,
}

impl OutboundFrame {
    /// The encoded frame, for tests that inspect what was queued.
    #[cfg(test)]
    pub(super) fn bytes(&self) -> &[u8] {
        &self.bytes
    }
}

#[derive(Debug, thiserror::Error)]
pub enum OutboundError {
    #[error("the client connection is closed")]
    Closed,
    #[error("the client is not reading fast enough")]
    TooSlow,
    #[error(transparent)]
    Frame(#[from] FrameError),
}

/// Per-client bounded frame queue with a byte budget.
#[derive(Clone)]
pub struct Outbound {
    frames: mpsc::Sender<OutboundFrame>,
    budget: Arc<Semaphore>,
    closed: watch::Sender<bool>,
}

impl Outbound {
    pub fn new() -> (Self, mpsc::Receiver<OutboundFrame>, watch::Sender<bool>) {
        let (frames, receiver) = mpsc::channel(OUTBOUND_QUEUE_FRAMES);
        let (closed, _) = watch::channel(false);
        let outbound = Self {
            frames,
            budget: Arc::new(Semaphore::new(OUTBOUND_BUDGET_BYTES)),
            closed: closed.clone(),
        };
        (outbound, receiver, closed)
    }

    pub fn try_send(&self, message: &ServerMessage) -> Result<(), OutboundError> {
        let bytes = codec::encode(message)?;
        let permits = u32::try_from(bytes.len()).map_err(|_| OutboundError::TooSlow)?;
        let permit = self
            .budget
            .clone()
            .try_acquire_many_owned(permits)
            .map_err(|_| OutboundError::TooSlow)?;

        self.frames
            .try_send(OutboundFrame {
                bytes,
                _permit: permit,
            })
            .map_err(|error| match error {
                mpsc::error::TrySendError::Full(_) => OutboundError::TooSlow,
                mpsc::error::TrySendError::Closed(_) => OutboundError::Closed,
            })
    }

    pub fn close(&self) {
        let _ = self.closed.send(true);
    }

    pub fn subscribe_closed(&self) -> watch::Receiver<bool> {
        self.closed.subscribe()
    }
}

pub async fn write_loop<W>(
    mut writer: W,
    mut frames: mpsc::Receiver<OutboundFrame>,
    closed: watch::Sender<bool>,
) where
    W: AsyncWrite + Unpin,
{
    while let Some(frame) = frames.recv().await {
        if writer.write_all(&frame.bytes).await.is_err() {
            break;
        }
        drop(frame);
    }
    let _ = writer.shutdown().await;
    let _ = closed.send(true);
}

#[cfg(test)]
mod tests {
    use fleet_protocol::api::{Base64Bytes, Event, ServerMessage};

    use super::{OUTBOUND_QUEUE_FRAMES, Outbound, OutboundError};

    fn message() -> ServerMessage {
        ServerMessage::Event {
            event: Event::DaemonStopping,
        }
    }

    #[test]
    fn the_byte_budget_is_bounded() {
        let (outbound, _receiver, _closed) = Outbound::new();
        let large = ServerMessage::Event {
            event: Event::Output {
                session_id: "one".into(),
                seq: 0,
                data: Base64Bytes::new(vec![0; 2 * 1024 * 1024]),
            },
        };
        outbound.try_send(&large).unwrap();
        outbound.try_send(&large).unwrap();
        assert!(matches!(
            outbound.try_send(&large),
            Err(OutboundError::TooSlow)
        ));
    }

    #[test]
    fn the_queue_is_bounded_and_detects_disconnects() {
        let (outbound, receiver, _closed) = Outbound::new();
        for _ in 0..OUTBOUND_QUEUE_FRAMES {
            outbound.try_send(&message()).unwrap();
        }
        assert!(matches!(
            outbound.try_send(&message()),
            Err(OutboundError::TooSlow)
        ));

        drop(receiver);
        assert!(matches!(
            outbound.try_send(&message()),
            Err(OutboundError::Closed)
        ));
    }
}
