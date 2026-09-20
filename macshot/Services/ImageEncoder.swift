import Cocoa
import UniformTypeIdentifiers
import ImageIO
import WebP

/// Shared image encoding with user-configurable format, quality, and resolution.
enum ImageEncoder {

    enum Format: String, CaseIterable, Sendable {
        case png = "png"
        case jpeg = "jpeg"
        case heic = "heic"
        case webp = "webp"
        case avif = "avif"

        nonisolated var fileExtension: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            case .heic: return "heic"
            case .webp: return "webp"
            case .avif: return "avif"
            }
        }

        nonisolated var utType: UTType {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            case .heic: return .heic
            case .webp: return .webP
            case .avif: return UTType("public.avif") ?? .image
            }
        }

        nonisolated var hasQuality: Bool {
            switch self {
            case .png: return false
            case .jpeg, .heic, .webp, .avif: return true
            }
        }

        nonisolated var displayName: String {
            switch self {
            case .png: return "PNG"
            case .jpeg: return "JPEG"
            case .heic: return "HEIC"
            case .webp: return "WebP"
            case .avif: return "AVIF"
            }
        }
    }

    static var format: Format {
        if let raw = UserDefaults.standard.string(forKey: "imageFormat"),
           let fmt = Format(rawValue: raw),
           isFormatAvailable(fmt) {
            return fmt
        }
        return .png
    }

    /// Lossy quality 0.0–1.0 (used for JPEG, HEIC, WebP, and AVIF)
    static var quality: CGFloat {
        if let q = UserDefaults.standard.object(forKey: "imageQuality") as? Double {
            return q.isFinite ? CGFloat(max(0.1, min(1.0, q))) : 0.85
        }
        return 0.85
    }

    /// Whether to downscale Retina (2x) screenshots to standard (1x) resolution.
    static var downscaleRetina: Bool {
        UserDefaults.standard.bool(forKey: "downscaleRetina")
    }

    static var fileExtension: String { format.fileExtension }
    static var utType: UTType { format.utType }

    nonisolated static var availableFormats: [Format] {
        Format.allCases.filter { isFormatAvailable($0) }
    }

    nonisolated static func isFormatAvailable(_ format: Format) -> Bool {
        switch format {
        case .png, .jpeg, .heic, .webp:
            return true
        case .avif:
            // Native ImageIO AVIF encode support is OS-provided. Keep the UI and
            // saved default gated so older supported macOS versions never expose
            // a format that cannot be written.
            guard #available(macOS 13.0, *) else { return false }
            let identifiers = CGImageDestinationCopyTypeIdentifiers() as NSArray
            return identifiers.contains("public.avif")
        }
    }

    /// Owns immutable pixels and settings from the instant the user requests
    /// output. AppKit stays on the main actor; encoding can run on a worker.
    struct PreparedImage: Sendable {
        let image: HistoryImageSnapshot.Image
        let format: Format
        let quality: CGFloat
        let downscaleRetina: Bool

        @MainActor init(_ source: NSImage) throws {
            image = try HistoryImageSnapshot.Image(source)
            format = ImageEncoder.format
            quality = ImageEncoder.quality
            downscaleRetina = ImageEncoder.downscaleRetina
        }

        nonisolated func pixelsForEncoding() throws -> CGImage {
            let pixels = image.pixels
            guard downscaleRetina, Double(pixels.width) > image.pointSize.width,
                  Double(pixels.height) > image.pointSize.height else { return pixels }
            // Clamp before converting to Int; malformed point sizes must not
            // trap, overflow a row stride or allocate an enormous bitmap.
            let width = max(1, Int(min(Double(pixels.width), image.pointSize.width)))
            let height = max(1, Int(min(Double(pixels.height), image.pointSize.height)))
            return try HistoryImageSnapshot.Image.render(pixels, width: width, height: height)
        }

        nonisolated func encode() -> Data? {
            guard let pixels = try? pixelsForEncoding() else { return nil }
            switch format {
            case .png: return ImageEncoder.encodeWithCGImageDestination(cgImage: pixels, type: "public.png", lossyQuality: nil)
            case .jpeg: return ImageEncoder.encodeWithCGImageDestination(cgImage: pixels, type: "public.jpeg", lossyQuality: quality)
            case .heic: return ImageEncoder.encodeWithCGImageDestination(cgImage: pixels, type: "public.heic", lossyQuality: quality)
            case .avif: return ImageEncoder.encodeWithCGImageDestination(cgImage: pixels, type: "public.avif", lossyQuality: quality)
            case .webp: return ImageEncoder.encodeWebP(cgImage: pixels, quality: quality)
            }
        }
    }

    static func encode(_ image: NSImage) -> Data? {
        (try? PreparedImage(image))?.encode()
    }

    /// Encode WebP via Swift-WebP (libwebp).
    /// Uses the CGImage RGBA path directly — the library's NSImage path has a bug
    /// (assumes RGB stride and logical size instead of pixel size).
    nonisolated private static func encodeWebP(cgImage srcImage: CGImage, quality: CGFloat) -> Data? {
        let w = srcImage.width
        let h = srcImage.height
        // Re-render into a known premultipliedLast RGBA context (preserving source color space)
        let cs = srcImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(srcImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let rgbaImage = ctx.makeImage() else { return nil }

        let encoder = WebPEncoder()
        let config = WebPEncoderConfig.preset(.picture, quality: Float(quality * 100))
        return try? encoder.encode(RGBA: rgbaImage, config: config)
    }

    /// Generic CGImageDestination encoder — embeds the source color profile.
    /// The CGImage already carries its display's ICC profile (e.g. Display P3).
    /// CGImageDestination embeds it automatically — no pixel conversion needed.
    nonisolated static func encodeWithCGImageDestination(cgImage: CGImage, type: String, lossyQuality: CGFloat?) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, 1, nil) else { return nil }

        var properties: [String: Any] = [:]
        if let q = lossyQuality {
            properties[kCGImageDestinationLossyCompressionQuality as String] = q
        }

        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    // MARK: - Clipboard

    private static let clipboardGenerationLock = NSLock()
    private static var clipboardGeneration = 0

    /// No file URL: it points into our sandbox, which Teams/RDP/web apps prefer but can't read (#309, #393).
    static func copyToClipboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        let generation = beginClipboardCopy()
        let changeCount = pasteboard.changeCount
        guard let prepared = try? PreparedImage(image) else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            guard let pixels = try? prepared.pixelsForEncoding(),
                  let pngData = encodeWithCGImageDestination(cgImage: pixels, type: "public.png", lossyQuality: nil) else {
                return
            }

            let tiffData = encodeWithCGImageDestination(cgImage: pixels, type: "public.tiff", lossyQuality: nil)

            DispatchQueue.main.async {
                guard isCurrentClipboardCopy(generation), pasteboard.changeCount == changeCount else { return }
                writeImagePasteboard(
                    pasteboard,
                    pngData: pngData,
                    tiffData: tiffData
                )
            }
        }
    }

    private static func beginClipboardCopy() -> Int {
        clipboardGenerationLock.lock()
        defer { clipboardGenerationLock.unlock() }
        clipboardGeneration += 1
        return clipboardGeneration
    }

    private static func isCurrentClipboardCopy(_ generation: Int) -> Bool {
        clipboardGenerationLock.lock()
        defer { clipboardGenerationLock.unlock() }
        return generation == clipboardGeneration
    }

    private static func writeImagePasteboard(
        _ pasteboard: NSPasteboard,
        pngData: Data,
        tiffData: Data?
    ) {
        pasteboard.clearContents()

        var types: [NSPasteboard.PasteboardType] = [.png]
        if tiffData != nil {
            types.append(.tiff)
        }
        pasteboard.declareTypes(types, owner: nil)
        pasteboard.setData(pngData, forType: .png)
        if let tiffData {
            pasteboard.setData(tiffData, forType: .tiff)
        }
    }
}
