import SwiftUI

/// Opens with ⌘, — pick a skin or import a new one from a folder.
struct SkinSettingsView: View {
    @EnvironmentObject private var skins: SkinManager
    @State private var showingImporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Skins").font(.title2.bold())

            List(skins.skins) { skin in
                HStack {
                    VStack(alignment: .leading) {
                        Text(skin.manifest.name).font(.headline)
                        Text("by \(skin.manifest.author) · v\(skin.manifest.version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if skin.id == skins.active.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    if !skin.isBuiltIn {
                        Button(role: .destructive) { skins.delete(skin) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { skins.select(skin) }
            }
            .frame(minHeight: 180)

            if let error = skins.lastError {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            HStack {
                Button("Import Skin Folder…") { showingImporter = true }
                Button("Show Skins Folder") {
                    NSWorkspace.shared.open(SkinManager.skinsDirectory)
                }
                WMPImportSection()
            }
        }
        .padding(20)
        .frame(width: 580, height: 340)
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { skins.importSkin(from: url) }
        }
    }
}
