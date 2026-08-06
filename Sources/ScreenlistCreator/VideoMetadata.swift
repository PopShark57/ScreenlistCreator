import Foundation
import AVFoundation

struct VideoMetadata: Sendable {
    var duration: Double          // seconds
    var width: Int                // display width after rotation
    var height: Int
    var frameRate: Double
    var codecName: String
    var fileSizeBytes: Int64
    var backend: MediaBackend = .avFoundation

    var resolutionText: String { "\(width)×\(height)" }

    var durationText: String { VideoMetadata.timecode(duration) }

    var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }

    var frameRateText: String {
        frameRate > 0 ? String(format: "%.6g fps", frameRate) : ""
    }

    static func timecode(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

enum VideoMetadataError: LocalizedError {
    case noVideoTrack
    case unreadable(file: String, fileExtension: String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "The file does not contain a video track."
        case .unreadable(let file, let ext):
            let suffix = ext.isEmpty ? "" : " (.\(ext.lowercased()))"
            return """
                \(file)\(suffix) could not be opened by macOS, and FFmpeg was not found. \
                Install it with "brew install ffmpeg", or point Screenlist Creator at an \
                existing copy under Decoding in the settings pane.
                """
        }
    }
}

enum VideoMetadataLoader {

    /// Reads a file's metadata and decides which decoder will be used for it.
    ///
    /// AVFoundation is tried first because it is faster and always available, but it
    /// only demuxes the QuickTime/MPEG family. Anything it cannot open — or opens but
    /// cannot decode, which is common for AVI and Matroska holding codecs macOS has
    /// no decoder for — is handed to FFmpeg.
    static func load(url: URL) async throws -> VideoMetadata {
        do {
            let (metadata, asset) = try await loadWithAVFoundation(url: url)
            if await AVFoundationBackend.canDecodeFrame(asset: asset, metadata: metadata) {
                return metadata
            }
            // Container parsed, video stream did not decode. Prefer FFmpeg if we have
            // it; otherwise keep the AVFoundation metadata so the file at least shows
            // its duration and fails per-frame rather than disappearing.
            if FFmpegLocator.locate() != nil,
               let viaFFmpeg = try? await FFmpegBackend.probe(url: url) {
                return viaFFmpeg
            }
            return metadata
        } catch {
            guard FFmpegLocator.locate() != nil else {
                if error is VideoMetadataError { throw error }
                throw VideoMetadataError.unreadable(
                    file: url.lastPathComponent,
                    fileExtension: url.pathExtension
                )
            }
            return try await FFmpegBackend.probe(url: url)
        }
    }

    /// Returns the asset alongside the metadata so callers can keep using the one
    /// whose tracks are already loaded.
    private static func loadWithAVFoundation(url: URL) async throws -> (VideoMetadata, AVURLAsset) {
        let asset = AVURLAsset(url: url)
        let (duration, tracks) = try await asset.load(.duration, .tracks)
        guard let track = tracks.first(where: { $0.mediaType == .video }) else {
            throw VideoMetadataError.noVideoTrack
        }
        let (naturalSize, transform, frameRate, formatDescriptions) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions
        )

        let displaySize = naturalSize.applying(transform)
        let width = Int(abs(displaySize.width).rounded())
        let height = Int(abs(displaySize.height).rounded())

        var codec = ""
        if let desc = formatDescriptions.first {
            codec = codecDisplayName(CMFormatDescriptionGetMediaSubType(desc))
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { throw VideoMetadataError.noVideoTrack }

        let metadata = VideoMetadata(
            duration: seconds,
            width: width,
            height: height,
            frameRate: Double(frameRate),
            codecName: codec,
            fileSizeBytes: fileSize,
            backend: .avFoundation
        )
        return (metadata, asset)
    }

    private static func codecDisplayName(_ subType: FourCharCode) -> String {
        switch subType {
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha: return "HEVC"
        case kCMVideoCodecType_MPEG4Video: return "MPEG-4"
        case kCMVideoCodecType_MPEG2Video: return "MPEG-2"
        case kCMVideoCodecType_MPEG1Video: return "MPEG-1"
        case kCMVideoCodecType_JPEG: return "MJPEG"
        case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ,
             kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy,
             kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ:
            return "ProRes"
        case kCMVideoCodecType_VP9: return "VP9"
        case kCMVideoCodecType_AV1: return "AV1"
        case kCMVideoCodecType_DVCNTSC, kCMVideoCodecType_DVCPAL,
             kCMVideoCodecType_DVCProPAL, kCMVideoCodecType_DVCPro50NTSC:
            return "DV"
        default:
            // Fall back to the raw four-character code, e.g. "xvid"
            let chars: [Character] = (0..<4).compactMap { i in
                let byte = UInt8((subType >> (8 * (3 - UInt32(i)))) & 0xFF)
                let scalar = Unicode.Scalar(byte)
                return scalar.properties.isAlphabetic || ("0"..."9").contains(Character(scalar)) ? Character(scalar) : nil
            }
            let name = String(chars)
            return name.isEmpty ? "Unknown" : name.uppercased()
        }
    }
}
