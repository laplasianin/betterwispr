#if DEBUG
import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Documentation screenshots for reply mode, in debug builds only.
///
/// `BETTERWISPR_REPLY_DEMO=preview|generating|settings` shows the popup with made-up content, or the Settings page;
/// `BETTERWISPR_REPLY_DEMO_OUT=<dir>` also writes a PNG of each of the app's windows there after three seconds,
/// scrolled by `BETTERWISPR_REPLY_DEMO_SCROLL` points first. The app's own Screen Recording permission takes the shots.
@MainActor
enum ReplyDemo {
    static func run(model: AppModel) {
        let environment = ProcessInfo.processInfo.environment
        guard let mode = environment["BETTERWISPR_REPLY_DEMO"] else { return }
        if mode == "settings" {
            model.selectedPage = .settings
        } else {
            model.reply.showDemo(generating: mode == "generating")
        }
        guard let out = environment["BETTERWISPR_REPLY_DEMO_OUT"] else { return }
        let scroll = Double(environment["BETTERWISPR_REPLY_DEMO_SCROLL"] ?? "") ?? 0
        Task {
            try? await Task.sleep(for: .seconds(3))
            if scroll > 0 { scrollDashboard(by: scroll) }
            if mode == "settings" { tallDashboard() }
            try? await Task.sleep(for: .seconds(1))
            await capture(into: URL(fileURLWithPath: out), prefix: mode)
        }
    }

    private static func scrollDashboard(by points: Double) {
        guard let window = dashboard,
              let scrollView = scrollViews(in: window.contentView).max(by: { $0.frame.width < $1.frame.width }) else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: points))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// The widest visible window: the popup and the capsule are narrow panels.
    private static var dashboard: NSWindow? {
        NSApplication.shared.windows.filter(\.isVisible).max { $0.frame.width < $1.frame.width }
    }

    /// SwiftUI resets a programmatic scroll, so the window grows to the screen's height instead and the shot is cropped later.
    private static func tallDashboard() {
        guard let window = dashboard, let visible = window.screen?.visibleFrame else { return }
        window.setFrame(NSRect(x: window.frame.minX, y: visible.minY, width: window.frame.width, height: visible.height), display: true)
    }

    /// The sidebar scrolls too, so the caller picks the widest one: the page.
    private static func scrollViews(in view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        return ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private static func capture(into directory: URL, prefix: String) async {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for window in content.windows where window.owningApplication?.processID == pid && window.frame.width > 0 {
            let configuration = SCStreamConfiguration()
            configuration.width = Int(window.frame.width * 2)
            configuration.height = Int(window.frame.height * 2)
            configuration.showsCursor = false
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                                            configuration: configuration) else { continue }
            let url = directory.appending(path: "\(prefix)-\(Int(window.frame.width))x\(Int(window.frame.height)).png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
    }
}
#endif
