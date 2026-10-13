import AppKit
import ApplicationServices
import Carbon
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// A JPEG of the target app's focused window for reply mode. Nil without Screen Recording permission, during secure input, or without a window.
public enum WindowSnapshot {
    @MainActor
    public static func capture(from app: NSRunningApplication) -> Task<Data?, Never> {
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier, !IsSecureEventInputEnabled(),
              CGPreflightScreenCaptureAccess() else { return Task { nil } }
        let trusted = AXIsProcessTrusted()
        return Task.detached(priority: .userInitiated) {
            let info = trusted ? DictationContext.focusedWindowInfo(pid: pid) : (frame: nil, title: nil)
            guard let window = await SCWindow.focused(pid: pid, frame: info.frame, title: info.title) else { return nil }
            let configuration = SCStreamConfiguration()
            let scale = min(2, 1920 / max(window.frame.width, window.frame.height))
            configuration.width = max(1, Int(window.frame.width * scale))
            configuration.height = max(1, Int(window.frame.height * scale))
            configuration.showsCursor = false
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                                            configuration: configuration) else { return nil }
            return jpeg(image)
        }
    }

    /// Scales the image so its long edge is at most `maxEdge` pixels and encodes it as JPEG.
    public static func jpeg(_ image: CGImage, maxEdge: CGFloat = 1920, quality: CGFloat = 0.8) -> Data? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let scale = min(1, maxEdge / max(width, height))
        var source = image
        if scale < 1 {
            let size = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
            guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(origin: .zero, size: size))
            guard let scaled = context.makeImage() else { return nil }
            source = scaled
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, source, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
