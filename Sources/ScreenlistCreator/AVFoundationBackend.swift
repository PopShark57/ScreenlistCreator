import Foundation
import AVFoundation
import CoreGraphics

/// Frame extraction through AVFoundation — the fast path, used whenever macOS can
/// actually decode the file.
enum AVFoundationBackend {

    /// Returns an asset whose tracks are already loaded.
    ///
    /// This matters more than it looks: asking an `AVAssetImageGenerator` for a frame
    /// from an asset that has never had `.tracks` loaded fails outright on some
    /// containers (MPEG program streams among them), so every generator must be built
    /// from a prepared asset.
    static func preparedAsset(url: URL) async -> AVURLAsset {
        let asset = AVURLAsset(url: url)
        _ = try? await asset.load(.tracks)
        return asset
    }

    static func makeGenerator(asset: AVURLAsset, maxWidth: Int, tolerance: CMTime) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: CGFloat(maxWidth), height: 0)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        return generator
    }

    /// Cheap check that the video stream really decodes, not just that the container
    /// parsed. AVFoundation happily opens some AVI and MPEG files whose codec it has
    /// no decoder for, and only fails once a frame is requested.
    ///
    /// Several positions are tried because individual seeks are unreliable in some
    /// containers — MPEG program streams refuse particular timestamps while decoding
    /// the rest of the file fine. One success is enough to keep the file on the fast
    /// path; the renderer falls back to FFmpeg for any single frame that still fails.
    ///
    /// Runs at thumbnail size with unlimited tolerance so it settles for the nearest
    /// keyframe instead of decoding a whole GOP.
    static func canDecodeFrame(asset: AVURLAsset, metadata: VideoMetadata) async -> Bool {
        let generator = makeGenerator(asset: asset, maxWidth: 160, tolerance: .positiveInfinity)
        let duration = max(0, metadata.duration)
        for fraction in [0.5, 0.0, 0.25, 0.75] {
            let time = CMTime(seconds: duration * fraction, preferredTimescale: 600)
            if (try? await generator.image(at: time)) != nil { return true }
        }
        return false
    }
}
