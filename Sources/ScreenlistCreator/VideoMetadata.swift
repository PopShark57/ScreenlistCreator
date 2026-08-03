import Foundation
import AVFoundation

struct VideoMetadata: Sendable {
    var duration: Double          // seconds
    var width: Int                // display width after rotation
    var height: Int
    var frameRate: Double
    var codecName: String
    var fileSizeBytes: Int64

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

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "The file does not contain a video track."
        }
    }
}

enum VideoMetadataLoader {
    static func load(url: URL) async throws -> VideoMetadata {
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

        return VideoMetadata(
            duration: CMTimeGetSeconds(duration),
            width: width,
            height: height,
            frameRate: Double(frameRate),
            codecName: codec,
            fileSizeBytes: fileSize
        )
    }

    private static func codecDisplayName(_ subType: FourCharCode) -> String {
        switch subType {
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha: return "HEVC"
        case kCMVideoCodecType_MPEG4Video: return "MPEG-4"
        case kCMVideoCodecType_MPEG2Video: return "MPEG-2"
        case kCMVideoCodecType_JPEG: return "MJPEG"
        case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ,
             kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy,
             kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ:
            return "ProRes"
        case kCMVideoCodecType_VP9: return "VP9"
        case kCMVideoCodecType_AV1: return "AV1"
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
