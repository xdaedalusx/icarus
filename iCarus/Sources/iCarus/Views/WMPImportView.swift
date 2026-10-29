import SwiftUI

/// The "Import WMP Skin…" button in Settings: opens the file, shows what's inside,
/// and can install it as a skin (look only for now).
enum WMPInstallResult {
    case failure(String)
    case success(WMPBuiltSkin)
}

struct WMPImportSection: View {
    @EnvironmentObject private var skins: SkinManager
    @State private var archiveURL: URL?
    @State private var busy = false
    @State private var report: WMPImportReport?
    @State private var errorText: String?

    var body: some View {
        HStack(spacing: 8) {
            Button("Import WMP Skin…") { choose() }
                .disabled(busy)
            if busy { ProgressView().controlSize(.small) }
        }
        .sheet(item: $report) { report in
            WMPImportReportView(report: report, onInstall: { await install() })
        }
        .alert("Couldn't read that skin", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(errorText ?? "")
        }
    }

    /// A plain macOS open panel. (SwiftUI's .fileImporter silently does nothing when the parent
    /// view already has one, as Settings does for the skin-folder button.)
    @MainActor
    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Windows Media Player skin"
        panel.message = "Pick a .wmz skin file"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in inspect(url) }
        }
    }

    @MainActor
    private func inspect(_ url: URL) {
        busy = true
        Task { @MainActor in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                archiveURL = url
                report = try await WMZImporter.inspect(archive: url)
            } catch {
                errorText = error.localizedDescription
            }
            busy = false
        }
    }

    @MainActor
    private func install() async -> WMPInstallResult {
        guard let url = archiveURL else { return .failure("The skin file is no longer available.") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let result = try await WMZImporter.buildSkin(archive: url)
            defer { try? FileManager.default.removeItem(at: result.folder) }
            skins.importSkin(from: result.folder)   // installs and selects it
            if let problem = skins.lastError { return .failure(problem) }
            return .success(result.built)
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

struct WMPImportReportView: View {
    let report: WMPImportReport
    /// Builds and installs the skin.
    var onInstall: (() async -> WMPInstallResult)? = nil
    @State private var installing = false
    @State private var installError: String?
    @State private var installed: WMPBuiltSkin?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let installed {
            summary(installed)
        } else {
            reportBody
        }
    }

    /// Shown after a successful install: what works and what was left out.
    private func summary(_ built: WMPBuiltSkin) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("\(report.skinName) is installed and selected", systemImage: "checkmark.circle.fill")
                .font(.title3.bold())
                .foregroundStyle(.green)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Working").font(.headline)
                        Text("\(built.controlCount) controls are wired up (buttons, sliders, text, visualizer).")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Skipped").font(.headline)
                        if built.skipped.isEmpty && built.hiddenCount == 0 {
                            Text("Nothing. Everything in the layout was carried over.")
                        }
                        ForEach(built.skipped, id: \.self) { line in
                            Label(line, systemImage: "minus.circle")
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if built.hiddenCount > 0 {
                            Label("\(built.hiddenCount) element(s) the skin only shows by script (sliding panes, pop-ups)",
                                  systemImage: "minus.circle")
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !report.scriptFiles.isEmpty {
                        Text("Scripted behaviour (\(report.scriptFiles.joined(separator: ", "))) doesn't carry over.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("Switch skins any time in Settings (⌘,).")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 360)
    }

    private var reportBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(report.skinName).font(.title2.bold())
                if let line = subtitle { Text(line).font(.callout).foregroundStyle(.secondary) }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Controls found") {
                        ForEach(report.elements) { element in
                            HStack {
                                Text(element.tag).font(.system(.body, design: .monospaced))
                                Text("×\(element.count)").foregroundStyle(.secondary)
                                Spacer()
                                label(for: element.status)
                            }
                        }
                    }

                    section("Files") {
                        Text("\(report.fileCount) files in the archive")
                        Text("\(report.imagesReferenced) images used by the layout"
                             + (report.missingImages.isEmpty ? "" : ", \(report.missingImages.count) missing"))
                        ForEach(report.missingImages, id: \.self) { name in
                            Text("Missing: \(name)").foregroundStyle(.orange)
                        }
                    }

                    section("Artwork converted") {
                        let keyed = report.convertedImages.filter { $0.keyedPixels > 0 }.count
                        Text("\(report.convertedImages.count) images converted to PNG; transparency applied to \(keyed)")
                        DisclosureGroup("Details") {
                            ForEach(report.convertedImages) { image in
                                HStack {
                                    Text(image.source).font(.system(.callout, design: .monospaced))
                                    Spacer()
                                    Text("\(image.width)×\(image.height)"
                                         + (image.keyedPixels > 0 ? " · \(image.keyedPixels) transparent px" : ""))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if !report.buttonGroups.isEmpty {
                        section("Buttons located") {
                            ForEach(report.buttonGroups) { group in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(group.mappingImage).font(.system(.callout, design: .monospaced))
                                    ForEach(group.regions) { region in
                                        HStack {
                                            Text("   " + region.label)
                                            Spacer()
                                            if let r = region.rect {
                                                Text("x \(r.x), y \(r.y), \(r.width)×\(r.height)")
                                                    .foregroundStyle(.secondary)
                                            } else {
                                                Text("colour not found").foregroundStyle(.orange)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if !report.warnings.isEmpty {
                        section("Heads-up") {
                            ForEach(report.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                if let installError {
                    Text(installError).font(.caption).foregroundStyle(.red)
                } else {
                    Text("Installs this as a skin and lists anything that couldn't be carried over.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if installing { ProgressView().controlSize(.small) }
                if let onInstall {
                    Button("Install Skin") {
                        installing = true
                        installError = nil
                        Task { @MainActor in
                            let result = await onInstall()
                            installing = false
                            switch result {
                            case .failure(let message): installError = message
                            case .success(let built): installed = built
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(installing)
                }
                Button("Close") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 520, height: 500)
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let size = report.windowSize { parts.append("Window \(size.width) × \(size.height)") }
        if let author = report.author { parts.append(author) }
        if let copyright = report.copyright { parts.append(copyright) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    @ViewBuilder
    private func label(for status: WMPImportReport.ElementCount.Status) -> some View {
        switch status {
        case .willConvert: Text("will convert").foregroundStyle(.green)
        case .skipped: Text("skipped").foregroundStyle(.orange)
        case .structural: Text("—").foregroundStyle(.secondary)
        }
    }
}
