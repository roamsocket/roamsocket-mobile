import Foundation
import ImageIO
import UIKit

/// Pure helpers for image preparation. Lives outside `ChatViewModel` so the
/// downsample + MIME-detection logic can be unit-tested without spinning up
/// the whole VM/AppState graph.
///
/// All helpers are `nonisolated` and safe to call from any background queue
/// (the VM uses `.userInitiated`). They only touch CoreGraphics / UIImage /
/// Foundation, all of which are safe off-main on iOS 17+.
enum ImageProcessing {

    /// Downsample image data straight to the target pixel size with ImageIO,
    /// then re-encode at the given quality. Decodes once at the target
    /// resolution (never a full-size bitmap) and bakes EXIF orientation in.
    ///
    /// Returns `nil` if the source bytes aren't a supported image, the
    /// thumbnail decode fails, or the re-encode produces empty data. Callers
    /// should treat `nil` as "this photo can't be attached" and surface a
    /// banner rather than silently dropping it.
    ///
    /// - Important: `kCGImageSourceShouldCacheImmediately` is deliberately
    ///   **not** set. That flag forces a full RGBA bitmap decode up front,
    ///   defeating the whole point of the thumbnail path and risking a
    ///   multi-hundred-MB allocation on a 50 MB ProRAW next to a resident
    ///   on-device VLM. The lazy decode path is what keeps peak RAM sane.
    static func downsampledJPEG(
        from data: Data,
        maxDimension: CGFloat,
        quality: CGFloat
    ) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(Int(maxDimension), 1),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        // For images in CMYK or with alpha, UIImage's jpegData can return nil
        // (or an empty Data). Re-encode to JPEG explicitly with .up so we
        // don't ship a sideways image downstream, and validate the output
        // is non-empty before returning success.
        guard let jpeg = UIImage(cgImage: cgImage, scale: 1, orientation: .up)
            .jpegData(compressionQuality: quality),
            !jpeg.isEmpty
        else { return nil }
        return jpeg
    }

    /// Best-effort detection of the source MIME. Returns `nil` if the bytes
    /// don't look like a known image format. Used by the picker so we know
    /// whether to request a JPEG, PNG, or HEIC representation from
    /// `NSItemProvider`.
    static func detectMIME(from data: Data) -> String? {
        // ImageIO is the source of truth — it parses the full header.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?
        else { return nil }
        switch type.lowercased() {
        case "public.jpeg", "jpg", "jpeg": return "image/jpeg"
        case "public.png": return "image/png"
        case "public.heic", "public.heif", "heic", "heif": return "image/heic"
        case "public.tiff": return "image/tiff"
        case "public.gif": return "image/gif"
        case "public.bmp": return "image/bmp"
        case "public.webp": return "image/webp"
        default: return nil
        }
    }
}
