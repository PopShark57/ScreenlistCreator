import Foundation
import CoreGraphics
import ImageIO

enum FFmpegError: LocalizedError {
    case notInstalled(fileExtension: String)
    case probeFailed(file: String, reason: String)
    case noVideoStream(file: String)
    case decodeFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let ext):
            let name = ext.isEmpty ? "This format" : ".\(ext.lowercased()) files"
            return """
                \(name) cannot be read by macOS on its own, and FFmpeg was not found. \
                Install it with "brew install ffmpeg", or point Screenlist Creator at an \
                existing copy under Decoding in the settings pane.
                """
        case .probeFailed(let file, let reason):
            return reason.isEmpty
                ? "FFmpeg could not read \(file)."
                : "FFmpeg could not read \(file): \(reason)"
        case .noVideoStream(let file):
            return "\(file) does not contain a video stream."
        case .decodeFailed(let reason):
            return reason.isEmpty ? "FFmpeg could not decode a frame." : "FFmpeg could not decode a frame: \(reason)"
        }
    }
}

/// Reads metadata and extracts frames by driving `ffprobe`/`ffmpeg` as child
/// processes. Used for every container AVFoundation cannot open.
enum FFmpegBackend {

    // MARK: - Metadata

    static func probe(url: URL) async throws -> VideoMetadata {
        guard let tool = FFmpegLocator.locate() else {
            throw FFmpegError.notInstalled(fileExtension: url.pathExtension)
        }
        return try await probe(url: url, tool: tool)
    }

    static func probe(url: URL, tool: FFmpegTool) async throws -> VideoMetadata {
        let result = try await ProcessRunner.run(
            executable: tool.ffprobe,
            arguments: [
                "-hide_banner", "-v", "error",
                "-print_format", "json",
                "-show_format",
                "-show_streams",
                "-select_streams", "v",
                url.path,
            ],
            timeout: 60
        )
        guard result.succeeded else {
            throw FFmpegError.probeFailed(
                file: url.lastPathComponent,
                reason: reasonWithoutPath(result.firstErrorLine, url: url)
            )
        }

        guard let root = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any] else {
            throw FFmpegError.probeFailed(file: url.lastPathComponent, reason: "unreadable ffprobe output")
        }

        let streams = root["streams"] as? [[String: Any]] ?? []
        // Cover art is exposed as a still video stream; never pick it as the movie.
        guard let stream = streams.first(where: { stream in
            let disposition = stream["disposition"] as? [String: Any]
            return intValue(disposition?["attached_pic"]) != 1
        }) ?? streams.first else {
            throw FFmpegError.noVideoStream(file: url.lastPathComponent)
        }
        let format = root["format"] as? [String: Any] ?? [:]

        let codedWidth = intValue(stream["width"]) ?? 0
        let codedHeight = intValue(stream["height"]) ?? 0
        let (width, height) = displaySize(
            width: codedWidth,
            height: codedHeight,
            sampleAspectRatio: stream["sample_aspect_ratio"] as? String,
            rotation: rotationDegrees(stream: stream)
        )

        let duration = doubleValue(format["duration"])
            ?? doubleValue(stream["duration"])
            ?? timecodeSeconds((stream["tags"] as? [String: Any])?["DURATION"] as? String)
            ?? 0

        let frameRate = rationalValue(stream["avg_frame_rate"] as? String)
            ?? rationalValue(stream["r_frame_rate"] as? String)
            ?? 0

        let fileSize = intValue(format["size"]).map(Int64.init)
            ?? ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0)

        return VideoMetadata(
            duration: duration,
            width: width,
            height: height,
            frameRate: frameRate,
            codecName: codecDisplayName(
                codec: stream["codec_name"] as? String ?? "",
                tag: stream["codec_tag_string"] as? String ?? ""
            ),
            fileSizeBytes: fileSize,
            backend: .ffmpeg
        )
    }

    // MARK: - Frame extraction

    /// Decodes a single frame at `seconds`, scaled so its width is at most `maxWidth`.
    ///
    /// Seeking before `-i` lets FFmpeg jump via the container index instead of
    /// decoding from the start, which is what makes long files usable. Containers
    /// with a missing or broken index (some FLV/AVI) can come back empty, so a slow
    /// output-side seek is used as a second attempt.
    static func extractFrame(
        url: URL,
        at seconds: Double,
        maxWidth: Int,
        metadata: VideoMetadata,
        tool: FFmpegTool
    ) async throws -> CGImage {
        let scale = scaleFilter(maxWidth: maxWidth, metadata: metadata)
        let timestamp = String(format: "%.3f", max(0, seconds))

        if let image = try await decodeFrame(
            tool: tool,
            arguments: frameArguments(url: url, seek: timestamp, scale: scale, seekBeforeInput: true)
        ) {
            return image
        }
        if let image = try await decodeFrame(
            tool: tool,
            arguments: frameArguments(url: url, seek: timestamp, scale: scale, seekBeforeInput: false)
        ) {
            return image
        }
        throw FFmpegError.decodeFailed(reason: "no frame at \(VideoMetadata.timecode(seconds))")
    }

    private static func frameArguments(
        url: URL,
        seek: String,
        scale: String,
        seekBeforeInput: Bool
    ) -> [String] {
        var arguments = ["-hide_banner", "-nostdin", "-v", "error"]
        if seekBeforeInput { arguments += ["-ss", seek] }
        arguments += ["-i", url.path]
        if !seekBeforeInput { arguments += ["-ss", seek] }
        arguments += [
            "-map", "0:v:0",
            "-frames:v", "1",
            "-an", "-sn", "-dn",
        ]
        if !scale.isEmpty { arguments += ["-vf", scale] }
        arguments += ["-c:v", "png", "-f", "image2pipe", "-"]
        return arguments
    }

    private static func decodeFrame(tool: FFmpegTool, arguments: [String]) async throws -> CGImage? {
        let result = try await ProcessRunner.run(
            executable: tool.ffmpeg,
            arguments: arguments,
            timeout: 180
        )
        guard result.succeeded, !result.stdout.isEmpty else { return nil }
        guard let source = CGImageSourceCreateWithData(result.stdout as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return image
    }

    /// Explicit target dimensions rather than a `scale=W:-2` expression: the probed
    /// size already accounts for rotation and non-square pixels, so anamorphic files
    /// come out with the right shape.
    private static func scaleFilter(maxWidth: Int, metadata: VideoMetadata) -> String {
        guard metadata.width > 0, metadata.height > 0, maxWidth > 0 else { return "" }
        let width = max(2, min(maxWidth, metadata.width))
        let ratio = Double(metadata.height) / Double(metadata.width)
        let height = max(2, Int((Double(width) * ratio).rounded()))
        return "scale=\(width):\(height):flags=bicubic"
    }

    /// ffmpeg prefixes its diagnostics with the full input path, which the caller
    /// already names. Drop it so the message stays readable in an alert.
    private static func reasonWithoutPath(_ reason: String, url: URL) -> String {
        let prefix = url.path + ": "
        guard reason.hasPrefix(prefix) else { return reason }
        return String(reason.dropFirst(prefix.count))
    }

    // MARK: - ffprobe value helpers
    //
    // ffprobe types are inconsistent — numbers arrive as JSON numbers in some
    // fields and quoted strings in others — so every read goes through these.

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String, let double = Double(string) { return double }
        return nil
    }

    /// Parses `"30000/1001"`. Returns nil for the `"0/0"` ffprobe uses for "unknown".
    private static func rationalValue(_ value: String?) -> Double? {
        guard let value else { return nil }
        let parts = value.split(separator: "/")
        guard parts.count == 2,
              let numerator = Double(parts[0]),
              let denominator = Double(parts[1]),
              denominator != 0, numerator != 0
        else { return nil }
        return numerator / denominator
    }

    /// Matroska stores per-stream duration as a `"00:00:20.023000000"` tag.
    private static func timecodeSeconds(_ value: String?) -> Double? {
        guard let value else { return nil }
        let parts = value.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2])
        else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    private static func rotationDegrees(stream: [String: Any]) -> Int {
        if let sideData = stream["side_data_list"] as? [[String: Any]] {
            for entry in sideData {
                if let rotation = doubleValue(entry["rotation"]) {
                    return Int(rotation.rounded())
                }
            }
        }
        if let tags = stream["tags"] as? [String: Any], let rotation = doubleValue(tags["rotate"]) {
            return Int(rotation.rounded())
        }
        return 0
    }

    /// Applies non-square pixels and rotation so the result matches what a player
    /// shows — the same convention AVFoundation's `preferredTransform` follows.
    private static func displaySize(
        width: Int,
        height: Int,
        sampleAspectRatio: String?,
        rotation: Int
    ) -> (Int, Int) {
        guard width > 0, height > 0 else { return (width, height) }

        var displayWidth = width
        if let ratio = sampleAspectRatio {
            let parts = ratio.split(separator: ":")
            if parts.count == 2,
               let numerator = Double(parts[0]),
               let denominator = Double(parts[1]),
               numerator > 0, denominator > 0, numerator != denominator {
                displayWidth = max(1, Int((Double(width) * numerator / denominator).rounded()))
            }
        }

        let quarterTurns = ((rotation % 180) + 180) % 180
        return quarterTurns == 90 ? (height, displayWidth) : (displayWidth, height)
    }

    private static func codecDisplayName(codec: String, tag: String) -> String {
        let names: [String: String] = [
            "h264": "H.264",
            "hevc": "HEVC",
            "h263": "H.263",
            "vp8": "VP8",
            "vp9": "VP9",
            "av1": "AV1",
            "mpeg1video": "MPEG-1",
            "mpeg2video": "MPEG-2",
            "mpeg4": "MPEG-4",
            "msmpeg4v1": "MS MPEG-4 v1",
            "msmpeg4v2": "MS MPEG-4 v2",
            "msmpeg4v3": "MS MPEG-4 v3",
            "wmv1": "WMV 7",
            "wmv2": "WMV 8",
            "wmv3": "WMV 9",
            "vc1": "VC-1",
            "flv1": "Sorenson Spark",
            "theora": "Theora",
            "mjpeg": "MJPEG",
            "prores": "ProRes",
            "dnxhd": "DNxHD",
            "dvvideo": "DV",
            "ffv1": "FFV1",
            "huffyuv": "HuffYUV",
            "rawvideo": "Raw",
            "cinepak": "Cinepak",
            "svq1": "Sorenson SVQ1",
            "svq3": "Sorenson SVQ3",
            "rv10": "RealVideo 1",
            "rv20": "RealVideo 2",
            "rv30": "RealVideo 3",
            "rv40": "RealVideo 4",
        ]
        let key = codec.lowercased()
        let base = names[key] ?? (codec.isEmpty ? "Unknown" : codec.uppercased())

        // AVI/MP4 hold several incompatible MPEG-4 ASP variants; the FourCC is the
        // part people actually recognise, so keep it.
        let fourCC = tag.trimmingCharacters(in: .whitespaces).uppercased()
        let isMeaningfulTag = fourCC.count == 4 && fourCC.allSatisfy { $0.isLetter || $0.isNumber }
        if key == "mpeg4", isMeaningfulTag, fourCC != "FMP4" {
            return "\(base) (\(fourCC))"
        }
        return base
    }
}
