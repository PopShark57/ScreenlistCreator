import Foundation
import UniformTypeIdentifiers

/// Which decoder reads a given file. AVFoundation only demuxes the QuickTime/MPEG
/// family; everything else (AVI, Matroska, WebM, ASF, FLV, RealMedia…) goes through
/// FFmpeg when it is installed.
enum MediaBackend: String, Sendable {
    case avFoundation
    case ffmpeg

    var displayName: String {
        switch self {
        case .avFoundation: return "AVFoundation"
        case .ffmpeg: return "FFmpeg"
        }
    }
}

enum VideoFormats {
    /// Container extensions the app advertises in the open panel and Info.plist.
    /// A handful decode natively; the rest need the FFmpeg backend. The list is
    /// deliberately generous — an extension that FFmpeg cannot demux simply fails
    /// with a per-file message instead of being silently unselectable.
    static let fileExtensions: [String] = [
        "3g2", "3gp", "amv", "asf", "avi", "divx", "dv", "f4v", "flv", "gxf",
        "m1v", "m2t", "m2ts", "m2v", "m4v", "mk3d", "mkv", "mod", "mov", "mp4",
        "mpe", "mpeg", "mpg", "mpv", "mts", "mxf", "nut", "ogm", "ogv", "qt",
        "rm", "rmvb", "tod", "ts", "vob", "vro", "webm", "wmv", "wtv", "y4m",
    ]

    /// Extensions AVFoundation is expected to read on its own. Only used for
    /// messaging — the actual backend is decided by probing each file.
    static let nativeFileExtensions: Set<String> = [
        "3g2", "3gp", "dv", "m1v", "m2t", "m2ts", "m2v", "m4v", "mov", "mp4",
        "mpe", "mpeg", "mpg", "mts", "qt", "ts",
    ]

    /// Formats that exist only because FFmpeg is installed, for display in the UI.
    static var ffmpegOnlyFileExtensions: [String] {
        fileExtensions.filter { !nativeFileExtensions.contains($0) }
    }

    static func isKnownExtension(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }

    /// Content types for `NSOpenPanel`. `public.movie` covers most of the list on
    /// its own, but the concrete types are added too so a file whose type failed to
    /// resolve still shows up.
    static var openPanelContentTypes: [UTType] {
        var types: [UTType] = [.movie, .audiovisualContent, .video]
        for ext in fileExtensions {
            guard let type = UTType(filenameExtension: ext), type.isDeclared else { continue }
            if !types.contains(type) { types.append(type) }
        }
        return types
    }
}
