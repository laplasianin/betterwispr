import AppKit
import BetterWisprCore
import SwiftUI

/// A floating panel that takes keyboard input without activating BetterWispr, so the target app stays frontmost for the paste.
private final class ReplyPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }
}

@MainActor
final class ReplyPanelController {
    private let reply: ReplyController
    private let panel: ReplyPanel
    private let hosting: NSHostingView<ReplyView>

    init(reply: ReplyController) {
        self.reply = reply
        hosting = NSHostingView(rootView: ReplyView(reply: reply))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel = ReplyPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 220),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        panel.onKey = { [weak self] event in self?.handle(event) ?? false }
        reply.onChange = { [weak self] in self?.update() }
    }

    func update() {
        if reply.state == .idle {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        hosting.rootView = ReplyView(reply: reply)
        panel.setContentSize(hosting.fittingSize)
        if !panel.isVisible {
            position()
            panel.makeKeyAndOrderFront(nil)
        } else if !panel.isKeyWindow {
            panel.makeKey()
        }
    }

    private func position() {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let size = panel.frame.size
        var origin = NSPoint(x: pointer.x - size.width / 2, y: pointer.y - size.height - 24)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }

    /// Enter pastes, Shift+Enter is a line break, Escape closes, ⌘R regenerates, ⌘E records an edit.
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (event.keyCode, flags) {
        case (36, []), (76, []): reply.paste(); return true          // Return, keypad Enter
        case (53, []): reply.dismiss(); return true                  // Escape
        case (15, .command): reply.regenerate(); return true         // ⌘R
        case (14, .command): reply.editByVoice(); return true        // ⌘E
        default: return false
        }
    }

    func close() {
        reply.onChange = nil
        panel.close()
    }
}
