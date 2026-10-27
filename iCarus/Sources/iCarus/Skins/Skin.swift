import SwiftUI
import AppKit

// MARK: - Manifest (what lives in a skin's skin.json)
//
// A skin is DATA, not code. It can choose a built-in layout and supply
// colours, fonts, metrics and images. It cannot run logic, so every skin
// behaves identically and untrusted skins stay safe.

enum LayoutKind: String, Codable, CaseIterable {
    case standard   // artwork + full playlist
    case compact    // slim horizontal bar
    case widgets    // free placement of knobs, buttons, etc. (see Widgets.swift)
}

struct SkinManifest: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var author: String
    var version: String
    var layout: LayoutKind
    var colors: Colors
    var typography: Typography
    var metrics: Metrics
    /// Optional image filename inside the skin folder (e.g. "background.png").
    var backgroundImage: String?
    /// Only used when layout == .widgets
    var widgets: WidgetLayout?

    struct Colors: Codable, Equatable {
        var background: String
        var surface: String
        var accent: String
        var text: String
        var secondaryText: String
    }

    struct Typography: Codable, Equatable {
        /// "default", "rounded", "serif" or "monospaced"
        var design: String
        var titleSize: Double
        var bodySize: Double
    }

    struct Metrics: Codable, Equatable {
        var cornerRadius: Double
        var spacing: Double
        var controlSize: Double
        var windowWidth: Double
        var windowHeight: Double
    }
}

// MARK: - Runtime skin (manifest + where its files live)

struct Skin: Identifiable, Equatable {
    let manifest: SkinManifest
    /// nil for skins built into the app.
    let directory: URL?

    var id: String { manifest.id }
    var isBuiltIn: Bool { directory == nil }

    // Resolved tokens
    var background: Color { Color(hex: manifest.colors.background) }
    var surface: Color { Color(hex: manifest.colors.surface) }
    var accent: Color { Color(hex: manifest.colors.accent) }
    var text: Color { Color(hex: manifest.colors.text) }
    var secondaryText: Color { Color(hex: manifest.colors.secondaryText) }

    var cornerRadius: CGFloat { manifest.metrics.cornerRadius }
    var spacing: CGFloat { manifest.metrics.spacing }
    var controlSize: CGFloat { manifest.metrics.controlSize }

    var fontDesign: Font.Design {
        switch manifest.typography.design {
        case "rounded": return .rounded
        case "serif": return .serif
        case "monospaced": return .monospaced
        default: return .default
        }
    }

    var titleFont: Font {
        .system(size: manifest.typography.titleSize, weight: .semibold, design: fontDesign)
    }

    var bodyFont: Font {
        .system(size: manifest.typography.bodySize, weight: .regular, design: fontDesign)
    }

    var backgroundImage: NSImage? {
        guard let directory, let name = manifest.backgroundImage else { return nil }
        // Only allow plain filenames so a skin can't read files outside its folder.
        let safeName = (name as NSString).lastPathComponent
        return NSImage(contentsOf: directory.appendingPathComponent(safeName))
    }
}

// MARK: - Built-in skins

extension Skin {
    static let classic = Skin(
        manifest: SkinManifest(
            id: "builtin.classic",
            name: "Classic",
            author: "iCarus",
            version: "1.0",
            layout: .standard,
            colors: .init(
                background: "#1C1C1E",
                surface: "#2C2C2E",
                accent: "#0A84FF",
                text: "#F5F5F7",
                secondaryText: "#98989D"
            ),
            typography: .init(design: "default", titleSize: 20, bodySize: 13),
            metrics: .init(cornerRadius: 12, spacing: 14, controlSize: 28,
                           windowWidth: 420, windowHeight: 640),
            backgroundImage: nil
        ),
        directory: nil
    )

    static let midnightCompact = Skin(
        manifest: SkinManifest(
            id: "builtin.midnight",
            name: "Midnight Compact",
            author: "iCarus",
            version: "1.0",
            layout: .compact,
            colors: .init(
                background: "#0B0F1A",
                surface: "#151B2B",
                accent: "#4ADE80",
                text: "#E6EDF7",
                secondaryText: "#7C8AA5"
            ),
            typography: .init(design: "monospaced", titleSize: 14, bodySize: 11),
            metrics: .init(cornerRadius: 6, spacing: 10, controlSize: 22,
                           windowWidth: 560, windowHeight: 120),
            backgroundImage: nil
        ),
        directory: nil
    )

    static let builtIn: [Skin] = [.classic, .midnightCompact, .retroRadio]
}

// MARK: - Environment

private struct SkinKey: EnvironmentKey {
    static let defaultValue: Skin = .classic
}

extension EnvironmentValues {
    var skin: Skin {
        get { self[SkinKey.self] }
        set { self[SkinKey.self] = newValue }
    }
}

// MARK: - Hex colour helper

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let r, g, b, a: Double
        if cleaned.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
