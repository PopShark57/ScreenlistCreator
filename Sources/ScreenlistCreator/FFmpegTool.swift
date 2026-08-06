import Foundation

/// A matched `ffmpeg`/`ffprobe` pair.
struct FFmpegTool: Sendable {
    let ffmpeg: URL
    let ffprobe: URL

    var directoryPath: String { ffmpeg.deletingLastPathComponent().path }
}

enum FFmpegLocator {
    /// Also read by `SettingsStore`, so a path chosen in the UI is picked up here
    /// without threading it through the engine.
    static let overrideDefaultsKey = "ffmpegPath"

    /// A GUI app launched from Finder inherits a bare `PATH` (`/usr/bin:/bin:…`),
    /// so Homebrew and MacPorts installs are invisible unless we look for them.
    private static let searchDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
        "/sw/bin",
        "/usr/bin",
        "/bin",
    ]

    static var overridePath: String {
        get { UserDefaults.standard.string(forKey: overrideDefaultsKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: overrideDefaultsKey) }
    }

    /// Finds ffmpeg and ffprobe, or nil when FFmpeg is not installed.
    static func locate(override: String? = nil) -> FFmpegTool? {
        let configured = (override ?? overridePath).trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty, let tool = toolFromOverride(configured) {
            return tool
        }
        for directory in candidateDirectories() {
            let ffmpeg = URL(fileURLWithPath: directory).appendingPathComponent("ffmpeg")
            guard isExecutable(ffmpeg) else { continue }
            let ffprobe = URL(fileURLWithPath: directory).appendingPathComponent("ffprobe")
            // ffprobe normally sits beside ffmpeg; keep looking if this install lacks it.
            guard isExecutable(ffprobe) else { continue }
            return FFmpegTool(ffmpeg: ffmpeg, ffprobe: ffprobe)
        }
        return nil
    }

    /// Accepts either the ffmpeg binary itself or the directory holding it.
    private static func toolFromOverride(_ path: String) -> FFmpegTool? {
        let expanded = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded.path, isDirectory: &isDirectory) else { return nil }

        let directory = isDirectory.boolValue ? expanded : expanded.deletingLastPathComponent()
        let ffmpeg = isDirectory.boolValue ? directory.appendingPathComponent("ffmpeg") : expanded
        let ffprobe = directory.appendingPathComponent("ffprobe")
        guard isExecutable(ffmpeg), isExecutable(ffprobe) else { return nil }
        return FFmpegTool(ffmpeg: ffmpeg, ffprobe: ffprobe)
    }

    private static func candidateDirectories() -> [String] {
        var directories: [String] = []

        // Binaries copied into the bundle take priority, so a self-contained build
        // never picks up a different FFmpeg from the user's machine.
        let bundle = Bundle.main.bundleURL.appendingPathComponent("Contents")
        directories.append(bundle.appendingPathComponent("Helpers").path)
        directories.append(bundle.appendingPathComponent("MacOS").path)

        directories.append(contentsOf: searchDirectories)

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            directories.append(contentsOf: path.split(separator: ":").map(String.init))
        }

        var seen = Set<String>()
        return directories.filter { seen.insert($0).inserted && !$0.isEmpty }
    }

    private static func isExecutable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// Version string such as `7.1.1`, for display. Empty when it cannot be read.
    static func version(of tool: FFmpegTool) async -> String {
        guard let result = try? await ProcessRunner.run(
            executable: tool.ffmpeg,
            arguments: ["-hide_banner", "-version"],
            timeout: 15
        ), result.succeeded else { return "" }

        let firstLine = String(decoding: result.stdout, as: UTF8.self)
            .split(separator: "\n").first.map(String.init) ?? ""
        // "ffmpeg version 7.1.1 Copyright (c) …" — also handles Homebrew's
        // "n7.1.1" and Debian's "7.1.1-1ubuntu2" style suffixes.
        let fields = firstLine.split(separator: " ").map(String.init)
        guard let index = fields.firstIndex(of: "version"), index + 1 < fields.count else { return "" }
        let raw = fields[index + 1]
        return raw.hasPrefix("n") ? String(raw.dropFirst()) : raw
    }
}
