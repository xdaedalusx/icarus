import SwiftUI

/// A look inside the imported skin that's on screen: every element, whether it's showing, and a
/// switch to show or hide it by hand. (Handy for checking what a skin kept, and for testing.)
struct SkinInspectorView: View {
    @EnvironmentObject private var runtime: SceneRuntime
    @Environment(\.dismiss) private var dismiss
    @Environment(\.skin) private var skin

    private struct Row: Identifiable {
        let node: SceneNode
        let depth: Int
        var id: String { node.id }
    }

    private var rows: [Row] {
        guard skin.manifest.widgets?.scenes?.isEmpty == false,
              let scene = runtime.currentScene else { return [] }
        var result: [Row] = []
        func walk(_ node: SceneNode, _ depth: Int) {
            result.append(Row(node: node, depth: depth))
            node.children.forEach { walk($0, depth + 1) }
        }
        walk(scene.root, 0)
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Skin Inspector").font(.title3.bold())
                Spacer()
                if runtime.scenes.count > 1 {
                    Picker("View", selection: Binding(
                        get: { runtime.currentViewID },
                        set: { runtime.showView($0) })) {
                        ForEach(runtime.scenes) { Text($0.id).tag($0.id) }
                    }
                    .frame(width: 180)
                }
            }
            if !rows.isEmpty, skin.manifest.widgets?.scripts?.isEmpty == false {
                HStack {
                    Toggle("Run this skin's script", isOn: Binding(
                        get: { SceneRuntime.scriptsAllowed(skin.id) },
                        set: { runtime.setScriptsEnabled($0) }))
                    Text(runtime.scriptsRunning ? "running" : "off")
                        .foregroundStyle(runtime.scriptsRunning ? .green : .secondary)
                    Spacer()
                }
                if !runtime.scriptLog.isEmpty {
                    ScrollView {
                        Text(runtime.scriptLog.suffix(40).joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 60)
                }
            }
            if rows.isEmpty {
                Text("The active skin isn't an imported Windows Media Player skin, so there's nothing to inspect.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(rows) { row in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { runtime.isVisible(row.node) },
                            set: { runtime.set(row.node.id, visible: $0) }))
                            .labelsHidden()
                        Text(row.node.id)
                            .font(.system(.body, design: .monospaced))
                            .padding(.leading, CGFloat(row.depth) * 14)
                        Text(row.node.tag).foregroundStyle(.secondary)
                        Spacer()
                        Text("z \(runtime.zIndex(row.node)) · \(Int(runtime.left(row.node))), \(Int(runtime.top(row.node)))")
                            .font(.caption).foregroundStyle(.secondary)
                        if !row.node.specs.isEmpty {
                            Image(systemName: "photo").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack {
                Button("Reset") { runtime.reset() }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }
}
