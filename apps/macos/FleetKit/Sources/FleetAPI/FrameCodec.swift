import Foundation

/// Length-prefixed JSON framing used by the local API.
public enum FrameCodec {
    /// Encodes a message to JSON without adding a length prefix.
    public static func encodePayload(_ message: some Encodable) throws -> Data {
        let payload = try JSONEncoder().encode(message)
        guard payload.count <= FleetProtocol.maxPayloadBytes else {
            throw FleetError.frameTooLarge(payload.count + 4)
        }
        return payload
    }

    /// Encodes a message as a complete length-prefixed frame.
    public static func encode(_ message: some Encodable) throws -> Data {
        let payload = try encodePayload(message)

        var frame = Data(capacity: payload.count + 4)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    public static func decode<T: Decodable>(_ type: T.Type, from payload: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: payload)
        } catch {
            throw FleetError.invalidFrame(String(describing: error))
        }
    }
}
