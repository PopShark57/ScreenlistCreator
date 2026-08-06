import Foundation
import SwiftUI

enum ImageFormat: String, CaseIterable, Identifiable {
    case jpeg
    case png
    case heic
    case tiff

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .heic: return "HEIC"
        case .tiff: return "TIFF"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .heic: return "heic"
        case .tiff: return "tiff"
        }
    }

    var utTypeIdentifier: String {
        switch self {
        case .jpeg: return "public.jpeg"
        case .png: return "public.png"
        case .heic: return "public.heic"
        case .tiff: return "public.tiff"
        }
    }

    var supportsQuality: Bool {
        self == .jpeg || self == .heic
    }
}

enum TimestampCorner: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }
}

enum SheetTheme: String, CaseIterable, Identifiable {
    case dark, light

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }
}

enum OutputMode: String, CaseIterable, Identifiable {
    case sameAsVideo
    case customFolder

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sameAsVideo: return "Same folder as video"
        case .customFolder: return "Custom folder"
        }
    }
}

enum CollisionPolicy: String, CaseIterable, Identifiable {
    case autoRename
    case overwrite

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .autoRename: return "Keep both (auto-number)"
        case .overwrite: return "Overwrite"
        }
    }
}

/// Immutable copy of all settings handed to the engine on a background task.
struct SettingsSnapshot: Sendable {
    var rows: Int
    var columns: Int
    var format: ImageFormat
    var quality: Double
    var sheetWidth: Int
    var spacing: Int
    var margin: Int
    var showHeader: Bool
    var showTimestamps: Bool
    var timestampCorner: TimestampCorner
    var theme: SheetTheme
    var skipStartPercent: Double
    var skipEndPercent: Double
    var outputMode: OutputMode
    var customFolderPath: String
    var filenameTemplate: String
    var collisionPolicy: CollisionPolicy

    var frameCount: Int { rows * columns }
}

extension ImageFormat: Sendable {}
extension TimestampCorner: Sendable {}
extension SheetTheme: Sendable {}
extension OutputMode: Sendable {}
extension CollisionPolicy: Sendable {}

@MainActor
final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults

    @Published var rows: Int { didSet { defaults.set(rows, forKey: "rows") } }
    @Published var columns: Int { didSet { defaults.set(columns, forKey: "columns") } }
    @Published var format: ImageFormat { didSet { defaults.set(format.rawValue, forKey: "format") } }
    @Published var quality: Double { didSet { defaults.set(quality, forKey: "quality") } }
    @Published var sheetWidth: Int { didSet { defaults.set(sheetWidth, forKey: "sheetWidth") } }
    @Published var spacing: Int { didSet { defaults.set(spacing, forKey: "spacing") } }
    @Published var margin: Int { didSet { defaults.set(margin, forKey: "margin") } }
    @Published var showHeader: Bool { didSet { defaults.set(showHeader, forKey: "showHeader") } }
    @Published var showTimestamps: Bool { didSet { defaults.set(showTimestamps, forKey: "showTimestamps") } }
    @Published var timestampCorner: TimestampCorner { didSet { defaults.set(timestampCorner.rawValue, forKey: "timestampCorner") } }
    @Published var theme: SheetTheme { didSet { defaults.set(theme.rawValue, forKey: "theme") } }
    @Published var skipStartPercent: Double { didSet { defaults.set(skipStartPercent, forKey: "skipStartPercent") } }
    @Published var skipEndPercent: Double { didSet { defaults.set(skipEndPercent, forKey: "skipEndPercent") } }
    @Published var outputMode: OutputMode { didSet { defaults.set(outputMode.rawValue, forKey: "outputMode") } }
    @Published var customFolderPath: String { didSet { defaults.set(customFolderPath, forKey: "customFolderPath") } }
    @Published var filenameTemplate: String { didSet { defaults.set(filenameTemplate, forKey: "filenameTemplate") } }
    @Published var collisionPolicy: CollisionPolicy { didSet { defaults.set(collisionPolicy.rawValue, forKey: "collisionPolicy") } }

    /// Empty means "search the usual install locations". Read straight from
    /// `UserDefaults` by `FFmpegLocator`, so the key has to stay in sync.
    @Published var ffmpegPath: String { didSet { defaults.set(ffmpegPath, forKey: FFmpegLocator.overrideDefaultsKey) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rows = defaults.object(forKey: "rows") as? Int ?? 4
        columns = defaults.object(forKey: "columns") as? Int ?? 3
        format = ImageFormat(rawValue: defaults.string(forKey: "format") ?? "") ?? .jpeg
        quality = defaults.object(forKey: "quality") as? Double ?? 0.85
        sheetWidth = defaults.object(forKey: "sheetWidth") as? Int ?? 2048
        spacing = defaults.object(forKey: "spacing") as? Int ?? 8
        margin = defaults.object(forKey: "margin") as? Int ?? 16
        showHeader = defaults.object(forKey: "showHeader") as? Bool ?? true
        showTimestamps = defaults.object(forKey: "showTimestamps") as? Bool ?? true
        timestampCorner = TimestampCorner(rawValue: defaults.string(forKey: "timestampCorner") ?? "") ?? .bottomRight
        theme = SheetTheme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .dark
        skipStartPercent = defaults.object(forKey: "skipStartPercent") as? Double ?? 2
        skipEndPercent = defaults.object(forKey: "skipEndPercent") as? Double ?? 2
        outputMode = OutputMode(rawValue: defaults.string(forKey: "outputMode") ?? "") ?? .sameAsVideo
        customFolderPath = defaults.string(forKey: "customFolderPath") ?? ""
        filenameTemplate = defaults.string(forKey: "filenameTemplate") ?? "{name}_screenlist"
        collisionPolicy = CollisionPolicy(rawValue: defaults.string(forKey: "collisionPolicy") ?? "") ?? .autoRename
        ffmpegPath = defaults.string(forKey: FFmpegLocator.overrideDefaultsKey) ?? ""
    }

    func snapshot() -> SettingsSnapshot {
        SettingsSnapshot(
            rows: rows,
            columns: columns,
            format: format,
            quality: quality,
            sheetWidth: sheetWidth,
            spacing: spacing,
            margin: margin,
            showHeader: showHeader,
            showTimestamps: showTimestamps,
            timestampCorner: timestampCorner,
            theme: theme,
            skipStartPercent: skipStartPercent,
            skipEndPercent: skipEndPercent,
            outputMode: outputMode,
            customFolderPath: customFolderPath,
            filenameTemplate: filenameTemplate,
            collisionPolicy: collisionPolicy
        )
    }

    func restoreDefaults() {
        rows = 4
        columns = 3
        format = .jpeg
        quality = 0.85
        sheetWidth = 2048
        spacing = 8
        margin = 16
        showHeader = true
        showTimestamps = true
        timestampCorner = .bottomRight
        theme = .dark
        skipStartPercent = 2
        skipEndPercent = 2
        outputMode = .sameAsVideo
        customFolderPath = ""
        filenameTemplate = "{name}_screenlist"
        collisionPolicy = .autoRename
        ffmpegPath = ""
    }
}
