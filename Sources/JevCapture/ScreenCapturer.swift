import Foundation
import AppKit
import ScreenCaptureKit

public actor ScreenCapturer {
    public nonisolated static let shared = ScreenCapturer()

    /// Captures a single window by its CGWindowID as JPEG data.
    /// - Parameters:
    ///   - windowID: The CGWindowID of the window to capture.
    ///   - maxDimension: Maximum width or height; image is downscaled preserving aspect ratio.
    ///   - quality: JPEG quality from 0.0 (lowest) to 1.0 (highest). Default 0.75.
    /// - Returns: JPEG data, or nil if capture fails.
    public func captureWindow(
        windowID: CGWindowID,
        maxDimension: Int = 1024,
        quality: CGFloat = 0.75
    ) async -> Data? {
        if #available(macOS 14.0, *) {
            if let image = await captureWindowSCK(windowID: windowID) {
                return jpegData(from: image, maxDimension: maxDimension, quality: quality)
            }
        }
        // Fallback to CGWindowListCreateImage for older paths or if SCK fails.
        if let image = captureWindowCG(windowID: windowID) {
            return jpegData(from: image, maxDimension: maxDimension, quality: quality)
        }
        return nil
    }

    /// Captures the full display as JPEG data.
    /// - Parameters:
    ///   - maxDimension: Maximum width or height; image is downscaled preserving aspect ratio.
    ///   - quality: JPEG quality from 0.0 (lowest) to 1.0 (highest). Default 0.75.
    /// - Returns: JPEG data, or nil if capture fails.
    public func captureDisplay(
        maxDimension: Int = 1024,
        quality: CGFloat = 0.75
    ) async -> Data? {
        if #available(macOS 14.0, *) {
            if let image = await captureDisplaySCK() {
                return jpegData(from: image, maxDimension: maxDimension, quality: quality)
            }
        }
        // Fallback to CGDisplayCreateImage for older paths or if SCK fails.
        if let image = captureDisplayCG() {
            return jpegData(from: image, maxDimension: maxDimension, quality: quality)
        }
        return nil
    }

    // MARK: - ScreenCaptureKit Implementations (macOS 14.0+)

    @available(macOS 14.0, *)
    private func captureWindowSCK(windowID: CGWindowID) async -> NSImage? {
        do {
            let availableContent = try await SCShareableContent.current
            guard let window = availableContent.windows.first(where: { $0.windowID == windowID }) else {
                return nil
            }
            let contentFilter = SCContentFilter(desktopIndependentWindow: window)
            let stream = try await SCScreenshotManager.captureImage(
                contentFilter: contentFilter,
                configuration: SCStreamConfiguration()
            )
            return NSImage(cgImage: stream, size: NSZeroSize)
        } catch {
            return nil
        }
    }

    @available(macOS 14.0, *)
    private func captureDisplaySCK() async -> NSImage? {
        do {
            let availableContent = try await SCShareableContent.current
            // The same display the pointer and every tap coordinate are
            // measured against. `.first` is whatever order ScreenCaptureKit
            // happens to return, so with two displays the phone could be shown
            // one screen while its taps landed on the other.
            let mainID = CGMainDisplayID()
            guard let display = availableContent.displays.first(where: { $0.displayID == mainID })
                ?? availableContent.displays.first else {
                return nil
            }
            let contentFilter = SCContentFilter(display: display, excludingWindows: [])
            // A default SCStreamConfiguration is 1920x1080. On any display that
            // is not 16:9 that letterboxes the capture — the black bar down the
            // side — and, worse, it means the image is a different shape from
            // the screen, so any overlay drawn from screen coordinates lands in
            // the wrong place. Match the display exactly.
            let configuration = SCStreamConfiguration()
            configuration.width = display.width
            configuration.height = display.height
            configuration.showsCursor = true
            let stream = try await SCScreenshotManager.captureImage(
                contentFilter: contentFilter,
                configuration: configuration
            )
            return NSImage(cgImage: stream, size: NSZeroSize)
        } catch {
            return nil
        }
    }

    // MARK: - Core Graphics Fallbacks

    private func captureWindowCG(windowID: CGWindowID) -> NSImage? {
        guard let cgImage = CGWindowListCreateImage(
            CGRect.null,
            .optionIncludingWindow,
            windowID,
            [.bestResolution]
        ) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSZeroSize)
    }

    private func captureDisplayCG() -> NSImage? {
        guard let cgImage = CGDisplayCreateImage(CGMainDisplayID()) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSZeroSize)
    }

    // MARK: - JPEG Encoding and Downscaling

    private func jpegData(from nsImage: NSImage, maxDimension: Int, quality: CGFloat) -> Data? {
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        let originalWidth = bitmapImage.pixelsWide
        let originalHeight = bitmapImage.pixelsHigh
        let scale = calculateDownscaleRatio(
            width: originalWidth,
            height: originalHeight,
            maxDimension: maxDimension
        )

        if scale >= 1.0 {
            // No downscaling needed, encode directly
            let jpegData = bitmapImage.representation(using: NSBitmapImageRep.FileType.jpeg, properties: [NSBitmapImageRep.PropertyKey.compressionFactor: quality])
            return jpegData
        }

        let scaledWidth = Int(CGFloat(originalWidth) * scale)
        let scaledHeight = Int(CGFloat(originalHeight) * scale)

        guard let context = CGContext(
            data: nil,
            width: scaledWidth,
            height: scaledHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }

        guard let cgImage = NSImage(data: tiffData)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let rect = CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight)
        context.draw(cgImage, in: rect)

        guard let scaledImage = context.makeImage() else {
            return nil
        }

        let scaledNSImage = NSImage(cgImage: scaledImage, size: NSZeroSize)
        guard let scaledTiffData = scaledNSImage.tiffRepresentation,
              let scaledBitmapImage = NSBitmapImageRep(data: scaledTiffData) else {
            return nil
        }

        let jpegData = scaledBitmapImage.representation(using: NSBitmapImageRep.FileType.jpeg, properties: [NSBitmapImageRep.PropertyKey.compressionFactor: quality])
        return jpegData
    }

    private func calculateDownscaleRatio(width: Int, height: Int, maxDimension: Int) -> CGFloat {
        let maxOriginal = max(width, height)
        if maxOriginal <= maxDimension {
            return 1.0
        }
        return CGFloat(maxDimension) / CGFloat(maxOriginal)
    }
}
