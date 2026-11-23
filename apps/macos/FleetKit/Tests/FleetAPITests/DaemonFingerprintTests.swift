import Darwin
import Foundation
import XCTest

@testable import FleetAPI

final class DaemonFingerprintTests: XCTestCase {
    func testFnv1a64MatchesTheDaemon() {
        XCTAssertEqual(DaemonFingerprint.fnv1a64(Data()), "cbf29ce484222325")
        XCTAssertEqual(DaemonFingerprint.fnv1a64(Data("fleet".utf8)), "f775f8a97470ae4f")
    }

    func testAMissingFingerprintIsReplacedWhenThisBuildCanBeRead() {
        XCTAssertTrue(
            DaemonReplacement.shouldReplace(
                reportedFingerprint: nil,
                launchFingerprint: "f775f8a97470ae4f"
            )
        )
        XCTAssertTrue(
            DaemonReplacement.shouldReplace(
                reportedFingerprint: "",
                launchFingerprint: "f775f8a97470ae4f"
            )
        )
    }

    func testAMatchingFingerprintKeepsTheListeningDaemon() {
        XCTAssertFalse(
            DaemonReplacement.shouldReplace(
                reportedFingerprint: "f775f8a97470ae4f",
                launchFingerprint: "f775f8a97470ae4f"
            )
        )
    }

    func testADifferentBuildIsReplaced() {
        XCTAssertTrue(
            DaemonReplacement.shouldReplace(
                reportedFingerprint: "aaaaaaaaaaaaaaaa",
                launchFingerprint: "f775f8a97470ae4f"
            )
        )
    }

    func testAnUnreadableLaunchBinaryIsLeftRunning() {
        XCTAssertFalse(
            DaemonReplacement.shouldReplace(
                reportedFingerprint: nil,
                launchFingerprint: ""
            )
        )
        XCTAssertEqual(DaemonFingerprint.ofFile(at: "/no/such/fleet-daemon"), "")
    }

    func testPeerProcessIDIsThisProcess() throws {
        let path = "/tmp/fleet-peer-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(path) }

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in
                for (index, byte) in bytes.enumerated() {
                    destination[index] = byte
                }
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(listener, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0, String(cString: strerror(errno)))
        XCTAssertEqual(listen(listener, 1), 0)

        let client = try UnixSocket.connect(path: path)
        defer { client.close() }
        XCTAssertEqual(client.peerProcessID(), getpid())
    }
}
