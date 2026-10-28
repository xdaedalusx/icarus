import Foundation
import SwiftUI

/// Finds, imports and selects skins.
/// User skins live in ~/Library/Application Support/iCarus/Skins/<skin-id>/
@MainActor
final class SkinManager: ObservableObject {
    @Published private(set) var skins: [Skin] = Skin.builtIn
    @Published private(set) var active: Skin = .classic
    @Published var lastError: String?

    private let defaultsKey = "activeSkinID"

    static var skinsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("iCarus/Skins", isDirectory: true)
    }

    init() {
        try? FileManager.default.createDirectory(at: Self.skinsDirectory,
                                                 withIntermediateDirectories: true)
        reload()
        if let savedID = UserDefaults.standard.string(forKey: defaultsKey),
           let match = skins.first(where: { $0.id == savedID }) {
            active = match
        }
    }

    func select(_ skin: Skin) {
        active = skin
        UserDefaults.standard.set(skin.id, forKey: defaultsKey)
    }

    func reload() {
        SkinImageCache.clear()
        var found = Skin.builtIn
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: Self.skinsDirectory,
                                                   includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            if let skin = try? Self.loadSkin(from: folder) {
                found.append(skin)
            }
        }
        skins = found
        if !skins.contains(where: { $0.id == active.id }) { active = .classic }
    }

    /// Validates a skin folder and copies it into the app's skins directory.
    func importSkin(from folder: URL) {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        do {
            let skin = try Self.loadSkin(from: folder)
            guard !skin.id.hasPrefix("builtin.") else { throw SkinError.reservedID }

            let safeID = skin.id.replacingOccurrences(of: "/", with: "_")
            let destination = Self.skinsDirectory.appendingPathComponent(safeID, isDirectory: true)
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: folder, to: destination)

            reload()
            if let installed = skins.first(where: { $0.id == skin.id }) { select(installed) }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func delete(_ skin: Skin) {
        guard let directory = skin.directory else { return }
        try? FileManager.default.removeItem(at: directory)
        reload()
    }

    private static func loadSkin(from folder: URL) throws -> Skin {
        let manifestURL = folder.appendingPathComponent("skin.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw SkinError.missingManifest
        }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(SkinManifest.self, from: data)
        return Skin(manifest: manifest, directory: folder)
    }

    enum SkinError: LocalizedError {
        case missingManifest, reservedID

        var errorDescription: String? {
            switch self {
            case .missingManifest: return "That folder doesn't contain a skin.json file."
            case .reservedID: return "Skin IDs starting with \"builtin.\" are reserved."
            }
        }
    }
}
