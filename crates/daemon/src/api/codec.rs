use serde::{Serialize, de::DeserializeOwned};
use tokio::io::{AsyncRead, AsyncReadExt};

use director_protocol::api::MAX_FRAME_BYTES;

/// A length-prefixed JSON frame could not be read or written.
#[derive(Debug, thiserror::Error)]
pub enum FrameError {
    #[error("empty frames are not valid protocol messages")]
    EmptyFrame,
    #[error("frame is {size} bytes, which exceeds the {MAX_FRAME_BYTES}-byte limit")]
    TooLarge { size: usize },
    #[error("invalid JSON message: {0}")]
    InvalidJson(serde_json::Error),
    #[error("failed to encode message: {0}")]
    Encode(serde_json::Error),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

pub fn encode<T: Serialize>(message: &T) -> Result<Vec<u8>, FrameError> {
    let payload = serde_json::to_vec(message).map_err(FrameError::Encode)?;
    let size = payload.len() + 4;
    if size > MAX_FRAME_BYTES {
        return Err(FrameError::TooLarge { size });
    }
    let mut frame = Vec::with_capacity(size);
    frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    frame.extend_from_slice(&payload);
    Ok(frame)
}

pub async fn read<T, R>(reader: &mut R) -> Result<Option<T>, FrameError>
where
    T: DeserializeOwned,
    R: AsyncRead + Unpin,
{
    let mut header = [0_u8; 4];
    if reader.read(&mut header[..1]).await? == 0 {
        return Ok(None);
    }
    reader.read_exact(&mut header[1..]).await?;

    let length = u32::from_be_bytes(header) as usize;
    if length == 0 {
        return Err(FrameError::EmptyFrame);
    }
    if length > MAX_FRAME_BYTES - 4 {
        return Err(FrameError::TooLarge {
            size: length.saturating_add(4),
        });
    }

    let mut payload = vec![0_u8; length];
    reader.read_exact(&mut payload).await?;
    serde_json::from_slice(&payload)
        .map(Some)
        .map_err(FrameError::InvalidJson)
}

#[cfg(test)]
mod tests {
    use director_protocol::api::ClientMessage;
    use serde_json::json;

    use super::{FrameError, read};

    #[tokio::test]
    async fn messages_round_trip_over_a_byte_stream() {
        let message = ClientMessage::Hello {
            protocol_version: 1,
            client: Some("test".into()),
        };
        let frame = super::encode(&message).unwrap();
        let mut reader = frame.as_slice();
        assert_eq!(
            read::<ClientMessage, _>(&mut reader).await.unwrap(),
            Some(message)
        );
        assert_eq!(read::<ClientMessage, _>(&mut reader).await.unwrap(), None);
    }

    #[tokio::test]
    async fn oversized_frames_are_rejected_before_reading_the_payload() {
        let length = u32::MAX.to_be_bytes();
        let mut reader = length.as_slice();
        assert!(matches!(
            read::<ClientMessage, _>(&mut reader).await,
            Err(FrameError::TooLarge { .. })
        ));
    }

    #[tokio::test]
    async fn invalid_json_is_rejected() {
        let payload = json!({"type": "unknown"}).to_string();
        let mut frame = Vec::new();
        frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        frame.extend_from_slice(payload.as_bytes());
        let mut reader = frame.as_slice();
        assert!(matches!(
            read::<ClientMessage, _>(&mut reader).await,
            Err(FrameError::InvalidJson(_))
        ));
    }

    #[tokio::test]
    async fn encoding_rejects_frames_above_the_limit() {
        let huge = serde_json::Value::String("x".repeat(director_protocol::api::MAX_FRAME_BYTES));
        assert!(matches!(
            super::encode(&huge),
            Err(FrameError::TooLarge { .. })
        ));
    }
}
