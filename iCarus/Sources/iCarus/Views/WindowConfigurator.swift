import SwiftUI
import AppKit

/// Turns the app window into a borderless, transparent "shaped" window for skins
/// that ask for it (so the window's outline is whatever the artwork's alpha is),
/// and puts it back to a normal window otherwise.
///
/// Shaped mode hides the title bar, toolbar and traffic lights, and lets the
/// window be dragged by its background. Closing/minimizing then come from skin
/// buttons (bindings `closeWindow` / `minimizeWindow`) or the ⌘W / ⌘M menu items.
struct WindowConfigurator: NSViewRepresentable {
    let shaped: Bool
    let contentSize: CGSize

    final class Coordinator {
        var lastShaped: Bool?
        var lastSize: CGSize?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        let wantsShaped = shaped
        let size = contentSize

        // Wait a beat: the view only has a window once it's on screen.
        DispatchQueue.main.async {
            guard let window = view.window else { return }

            if coordinator.lastShaped == wantsShaped && coordinator.lastSize == size {
                if wantsShaped { window.invalidateShadow() }
                return
            }
            // Nothing to undo on the very first pass of a normal window.
            if coordinator.lastShaped == nil && !wantsShaped {
                coordinator.lastShaped = false
                coordinator.lastSize = size
                return
            }
            coordinator.lastShaped = wantsShaped
            coordinator.lastSize = size

            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

            if wantsShaped {
                window.styleMask.insert(.fullSizeContentView)
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                buttons.forEach { window.standardWindowButton($0)?.isHidden = true }
                window.toolbar?.isVisible = false
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = true
                window.isMovableByWindowBackground = false   // WindowDragSurface does the dragging
                window.ignoresMouseEvents = false
                window.setContentSize(size)
                // The shadow follows the artwork's outline; recompute it now and once more
                // after the new content has drawn.
                window.invalidateShadow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { window.invalidateShadow() }
            } else {
                window.styleMask.remove(.fullSizeContentView)
                window.titlebarAppearsTransparent = false
                window.titleVisibility = .visible
                buttons.forEach { window.standardWindowButton($0)?.isHidden = false }
                window.toolbar?.isVisible = true
                window.isOpaque = true
                window.backgroundColor = .windowBackgroundColor
                window.isMovableByWindowBackground = false
            }
        }
    }
}

/// An invisible surface that moves the window when you press and drag on it.
/// Controls drawn above it keep their own clicks; the skin's pictures ignore clicks, so a press on
/// the artwork lands here. It follows the mouse itself (no AppKit view in the way).
struct WindowDragSurface: View {
    @State private var startMouse: NSPoint?
    @State private var startOrigin: NSPoint?

    private var window: NSWindow? {
        NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }
    }

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { _ in
                        guard let window else { return }
                        let mouse = NSEvent.mouseLocation
                        if startMouse == nil {
                            startMouse = mouse
                            startOrigin = window.frame.origin
                        }
                        guard let startMouse, let startOrigin else { return }
                        window.setFrameOrigin(NSPoint(x: startOrigin.x + mouse.x - startMouse.x,
                                                      y: startOrigin.y + mouse.y - startMouse.y))
                    }
                    .onEnded { _ in
                        startMouse = nil
                        startOrigin = nil
                    }
            )
    }
}
