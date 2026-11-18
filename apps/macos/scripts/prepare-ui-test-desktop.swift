import CoreGraphics
import Darwin
import Foundation

// Hosted runners can start at 1024×768, narrower than Fleet's minimum window.
let minimumWidth = 1440
let minimumHeight = 900
let display = CGMainDisplayID()

func hasRoom() -> Bool {
    let bounds = CGDisplayBounds(display)
    return bounds.width >= CGFloat(minimumWidth) && bounds.height >= CGFloat(minimumHeight)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("UI test desktop: \(message)\n".utf8))
    exit(EXIT_FAILURE)
}

if hasRoom() {
    print("UI test desktop already has enough room: \(CGDisplayBounds(display))")
    exit(EXIT_SUCCESS)
}

let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
guard let modes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] else {
    fail("Could not enumerate display modes. Run in an active macOS desktop session.")
}
let candidates = modes.filter {
    $0.isUsableForDesktopGUI() && $0.width >= minimumWidth && $0.height >= minimumHeight
}.sorted { $0.width * $0.height < $1.width * $1.height }
let supported = Set(modes.map { "\($0.width)×\($0.height)" }).sorted().joined(separator: ", ")
guard !candidates.isEmpty else {
    fail("Need at least \(minimumWidth)×\(minimumHeight). Supported modes: \(supported)")
}

for mode in candidates {
    var configuration: CGDisplayConfigRef?
    let beginResult = CGBeginDisplayConfiguration(&configuration)
    guard beginResult == .success, let configuration else {
        fail("Could not begin display configuration: \(beginResult.rawValue)")
    }
    let configureResult = CGConfigureDisplayWithDisplayMode(configuration, display, mode, nil)
    guard configureResult == .success else {
        CGCancelDisplayConfiguration(configuration)
        print("Could not configure \(mode.width)×\(mode.height): \(configureResult.rawValue)")
        continue
    }
    // Keep the mode after this process exits, without changing permanent preferences.
    let completeResult = CGCompleteDisplayConfiguration(configuration, .forSession)
    guard completeResult == .success else {
        print("Could not apply \(mode.width)×\(mode.height): \(completeResult.rawValue)")
        continue
    }
    for _ in 0..<20 {
        if hasRoom() {
            print("UI test desktop configured: \(CGDisplayBounds(display))")
            exit(EXIT_SUCCESS)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
}
fail("Could not select a usable \(minimumWidth)×\(minimumHeight) desktop. Supported modes: \(supported)")
