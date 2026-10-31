import AppKit
import CoreText

/// Monospaced faces the middle panel can render.
/// `"system"` always resolves through the system monospace font.
enum TerminalFont {
    static let systemID = "system"

    struct Face: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
    }

    @MainActor
    static func resolve(id: String, size: CGFloat) -> NSFont {
        let size = min(max(size, 10), 18)
        let system = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        guard id != systemID, !id.isEmpty else { return system }
        guard let font = NSFont(name: id, size: size), isMonospaced(font) else { return system }
        return font
    }

    @MainActor
    static func installed() -> [Face] {
        if let catalog { return catalog }
        let scanned = scan()
        catalog = scanned
        return scanned
    }

    @MainActor
    private static var catalog: [Face]?

    @MainActor
    private static func scan() -> [Face] {
        let manager = NSFontManager.shared
        var faces = [Face(id: systemID, title: "System")]
        var seen = Set<String>([systemID])
        for family in manager.availableFontFamilies {
            if family.hasPrefix(".") { continue }
            let lowered = family.lowercased()
            if lowered.contains("emoji") || lowered.contains("symbol") || lowered.contains("ornament") {
                continue
            }
            guard let font = manager.font(withFamily: family, traits: [], weight: 5, size: 12)
                ?? manager.font(withFamily: family, traits: [], weight: 0, size: 12),
                isMonospaced(font)
            else { continue }
            let postscript = font.fontName
            if postscript.hasPrefix(".") { continue }
            guard seen.insert(postscript).inserted else { continue }
            faces.append(Face(id: postscript, title: family))
        }
        let system = faces[0]
        let rest = faces.dropFirst().sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        return [system] + rest
    }

    private static func isMonospaced(_ font: NSFont) -> Bool {
        let ctFont = CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
        return CTFontGetSymbolicTraits(ctFont).contains(.traitMonoSpace)
    }
}
