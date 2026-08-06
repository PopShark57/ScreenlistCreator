import Foundation
import AVFoundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

enum ScreenlistError: LocalizedError {
    case couldNotCreateContext
    case couldNotCreateImage
    case couldNotCreateDestination(String)
    case couldNotWriteFile(String)
    case emptyVideo

    var errorDescription: String? {
        switch self {
        case .couldNotCreateContext: return "Failed to create a drawing context."
        case .couldNotCreateImage: return "Failed to render the screenlist image."
        case .couldNotCreateDestination(let path): return "Cannot write image to \(path)."
        case .couldNotWriteFile(let path): return "Failed to save the screenlist to \(path)."
        case .emptyVideo: return "The video has no usable duration."
        }
    }
}

struct ScreenlistTheme {
    var background: CGColor
    var headerTitle: CGColor
    var headerInfo: CGColor
    var cellPlaceholder: CGColor

    static func forSheetTheme(_ theme: SheetTheme) -> ScreenlistTheme {
        switch theme {
        case .dark:
            return ScreenlistTheme(
                background: CGColor(gray: 0.10, alpha: 1),
                headerTitle: CGColor(gray: 0.96, alpha: 1),
                headerInfo: CGColor(gray: 0.72, alpha: 1),
                cellPlaceholder: CGColor(gray: 0.18, alpha: 1)
            )
        case .light:
            return ScreenlistTheme(
                background: CGColor(gray: 0.94, alpha: 1),
                headerTitle: CGColor(gray: 0.10, alpha: 1),
                headerInfo: CGColor(gray: 0.35, alpha: 1),
                cellPlaceholder: CGColor(gray: 0.82, alpha: 1)
            )
        }
    }
}

enum ScreenlistEngine {

    // MARK: - Rendering

    /// Extracts frames and composes the contact sheet. Returns the finished image.
    /// `progress` is called with values in 0...1 from a background context.
    static func renderSheet(
        videoURL: URL,
        metadata: VideoMetadata,
        settings: SettingsSnapshot,
        sheetWidthOverride: Int? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CGImage {
        guard metadata.duration > 0 else { throw ScreenlistError.emptyVideo }

        let sheetWidth = sheetWidthOverride ?? settings.sheetWidth
        let layout = SheetLayout(settings: settings, sheetWidth: sheetWidth, metadata: metadata)

        // Sample times, evenly spaced across the kept span, midpoints of each slice.
        let skipStart = min(max(settings.skipStartPercent, 0), 40) / 100
        let skipEnd = min(max(settings.skipEndPercent, 0), 40) / 100
        var start = metadata.duration * skipStart
        var end = metadata.duration * (1 - skipEnd)
        if end - start < 0.5 { start = 0; end = metadata.duration }
        let span = end - start
        let count = settings.frameCount
        let times: [Double] = (0..<count).map { start + (Double($0) + 0.5) * span / Double(count) }

        let frames = try await extractFrames(
            videoURL: videoURL,
            times: times,
            maxWidth: layout.cellWidth * 2,
            tolerance: min(1.0, span / Double(count) / 4),
            metadata: metadata,
            progress: progress
        )

        try Task.checkCancellation()
        let sheet = try compose(frames: frames, times: times, layout: layout,
                                metadata: metadata, settings: settings, videoURL: videoURL)
        progress(1.0)
        return sheet
    }

    // MARK: - Frame extraction

    /// Grabs one frame per timestamp using whichever decoder claimed the file.
    /// A `nil` entry means that frame could not be decoded and gets a placeholder.
    private static func extractFrames(
        videoURL: URL,
        times: [Double],
        maxWidth: Int,
        tolerance: Double,
        metadata: VideoMetadata,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [CGImage?] {
        var frames: [CGImage?] = []
        frames.reserveCapacity(times.count)

        // Resolved once per sheet: the AVFoundation path uses it only to rescue
        // individual frames, so a missing FFmpeg is not fatal there.
        let ffmpeg = FFmpegLocator.locate()
        if metadata.backend == .ffmpeg, ffmpeg == nil {
            throw FFmpegError.notInstalled(fileExtension: videoURL.pathExtension)
        }

        var generator: AVAssetImageGenerator?
        if metadata.backend == .avFoundation {
            generator = AVFoundationBackend.makeGenerator(
                asset: await AVFoundationBackend.preparedAsset(url: videoURL),
                maxWidth: maxWidth,
                tolerance: CMTime(seconds: tolerance, preferredTimescale: 600)
            )
        }

        for (index, seconds) in times.enumerated() {
            try Task.checkCancellation()
            var frame: CGImage?

            if let generator {
                frame = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            }
            // Also covers partially damaged files on the AVFoundation path, where
            // some timestamps decode and others do not.
            try Task.checkCancellation()
            if frame == nil, let ffmpeg {
                frame = try? await FFmpegBackend.extractFrame(
                    url: videoURL,
                    at: seconds,
                    maxWidth: maxWidth,
                    metadata: metadata,
                    tool: ffmpeg
                )
            }

            frames.append(frame)
            progress(0.9 * Double(index + 1) / Double(times.count))
        }

        return frames
    }

    // MARK: - Layout

    struct SheetLayout {
        let sheetWidth: Int
        let sheetHeight: Int
        let margin: Int
        let spacing: Int
        let cellWidth: Int
        let cellHeight: Int
        let headerHeight: Int
        let titleFontSize: CGFloat
        let infoFontSize: CGFloat
        let timestampFontSize: CGFloat

        init(settings: SettingsSnapshot, sheetWidth: Int, metadata: VideoMetadata) {
            self.sheetWidth = max(sheetWidth, 320)
            margin = max(0, settings.margin)
            spacing = max(0, settings.spacing)

            let columns = settings.columns
            let contentWidth = max(64, self.sheetWidth - 2 * margin - (columns - 1) * spacing)
            cellWidth = contentWidth / columns
            let aspect = metadata.width > 0 && metadata.height > 0
                ? Double(metadata.height) / Double(metadata.width)
                : 9.0 / 16.0
            cellHeight = max(8, Int((Double(cellWidth) * aspect).rounded()))

            let w = CGFloat(self.sheetWidth)
            titleFontSize = min(max(w * 0.014, 12), 30)
            infoFontSize = min(max(w * 0.011, 10), 24)
            timestampFontSize = min(max(CGFloat(cellWidth) * 0.055, 9), 22)

            if settings.showHeader {
                headerHeight = Int((titleFontSize * 1.7 + infoFontSize * 1.7 + 10).rounded())
            } else {
                headerHeight = 0
            }

            let rows = settings.rows
            let gridHeight = rows * cellHeight + (rows - 1) * spacing
            sheetHeight = margin + headerHeight + (headerHeight > 0 ? spacing : 0) + gridHeight + margin
        }
    }

    // MARK: - Composition

    private static func compose(
        frames: [CGImage?],
        times: [Double],
        layout: SheetLayout,
        metadata: VideoMetadata,
        settings: SettingsSnapshot,
        videoURL: URL
    ) throws -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: layout.sheetWidth,
            height: layout.sheetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ScreenlistError.couldNotCreateContext
        }

        let theme = ScreenlistTheme.forSheetTheme(settings.theme)
        let W = CGFloat(layout.sheetWidth)
        let H = CGFloat(layout.sheetHeight)

        ctx.setFillColor(theme.background)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

        // Header
        if layout.headerHeight > 0 {
            let titleFont = CTFontCreateUIFontForLanguage(.emphasizedSystem, layout.titleFontSize, nil)
                ?? CTFontCreateWithName("Helvetica-Bold" as CFString, layout.titleFontSize, nil)
            let infoFont = CTFontCreateUIFontForLanguage(.system, layout.infoFontSize, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, layout.infoFontSize, nil)

            let maxTextWidth = W - 2 * CGFloat(layout.margin)
            let titleBaseline = H - CGFloat(layout.margin) - layout.titleFontSize * 1.1
            TextRenderer.draw(
                text: videoURL.lastPathComponent,
                font: titleFont,
                color: theme.headerTitle,
                at: CGPoint(x: CGFloat(layout.margin), y: titleBaseline),
                maxWidth: maxTextWidth,
                in: ctx
            )

            var infoParts: [String] = []
            if metadata.fileSizeBytes > 0 { infoParts.append(metadata.fileSizeText) }
            infoParts.append(metadata.durationText)
            infoParts.append(metadata.resolutionText)
            if !metadata.codecName.isEmpty { infoParts.append(metadata.codecName) }
            if !metadata.frameRateText.isEmpty { infoParts.append(metadata.frameRateText) }
            let infoLine = infoParts.joined(separator: "   •   ")

            let infoBaseline = titleBaseline - layout.infoFontSize * 1.6
            TextRenderer.draw(
                text: infoLine,
                font: infoFont,
                color: theme.headerInfo,
                at: CGPoint(x: CGFloat(layout.margin), y: infoBaseline),
                maxWidth: maxTextWidth,
                in: ctx
            )
        }

        // Grid of frames
        let gridTop = H - CGFloat(layout.margin) - CGFloat(layout.headerHeight)
            - (layout.headerHeight > 0 ? CGFloat(layout.spacing) : 0)
        let timestampFont = CTFontCreateUIFontForLanguage(.emphasizedSystem, layout.timestampFontSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, layout.timestampFontSize, nil)

        for index in 0..<frames.count {
            let row = index / settings.columns
            let col = index % settings.columns
            let x = CGFloat(layout.margin) + CGFloat(col) * CGFloat(layout.cellWidth + layout.spacing)
            let yTop = gridTop - CGFloat(row) * CGFloat(layout.cellHeight + layout.spacing)
            let cellRect = CGRect(
                x: x,
                y: yTop - CGFloat(layout.cellHeight),
                width: CGFloat(layout.cellWidth),
                height: CGFloat(layout.cellHeight)
            )

            if let frame = frames[index] {
                ctx.saveGState()
                ctx.interpolationQuality = .high
                ctx.draw(frame, in: aspectFillRect(for: frame, in: cellRect), byTiling: false)
                ctx.restoreGState()
            } else {
                ctx.setFillColor(ScreenlistTheme.forSheetTheme(settings.theme).cellPlaceholder)
                ctx.fill(cellRect)
            }

            if settings.showTimestamps, index < times.count {
                drawTimestampBadge(
                    text: VideoMetadata.timecode(times[index]),
                    font: timestampFont,
                    corner: settings.timestampCorner,
                    cellRect: cellRect,
                    in: ctx
                )
            }
        }

        guard let image = ctx.makeImage() else { throw ScreenlistError.couldNotCreateImage }
        return image
    }

    /// Scales the frame so it covers the whole cell (clipped), keeping aspect. Frames
    /// normally share the cell's aspect exactly, so cropping only kicks in for oddballs.
    private static func aspectFillRect(for image: CGImage, in cell: CGRect) -> CGRect {
        let iw = CGFloat(image.width)
        let ih = CGFloat(image.height)
        guard iw > 0, ih > 0 else { return cell }
        let scale = max(cell.width / iw, cell.height / ih)
        let w = iw * scale
        let h = ih * scale
        return CGRect(
            x: cell.midX - w / 2,
            y: cell.midY - h / 2,
            width: w,
            height: h
        )
    }

    private static func drawTimestampBadge(
        text: String,
        font: CTFont,
        corner: TimestampCorner,
        cellRect: CGRect,
        in ctx: CGContext
    ) {
        let size = TextRenderer.measure(text: text, font: font)
        let padX: CGFloat = size.height * 0.45
        let padY: CGFloat = size.height * 0.25
        let badgeW = size.width + 2 * padX
        let badgeH = size.height + 2 * padY
        let inset: CGFloat = max(4, cellRect.width * 0.015)

        var origin = CGPoint.zero
        switch corner {
        case .topLeft:
            origin = CGPoint(x: cellRect.minX + inset, y: cellRect.maxY - inset - badgeH)
        case .topRight:
            origin = CGPoint(x: cellRect.maxX - inset - badgeW, y: cellRect.maxY - inset - badgeH)
        case .bottomLeft:
            origin = CGPoint(x: cellRect.minX + inset, y: cellRect.minY + inset)
        case .bottomRight:
            origin = CGPoint(x: cellRect.maxX - inset - badgeW, y: cellRect.minY + inset)
        }

        let badgeRect = CGRect(x: origin.x, y: origin.y, width: badgeW, height: badgeH)
        ctx.saveGState()
        // Keep the badge inside the cell even if the cell is tiny.
        ctx.clip(to: cellRect)
        let path = CGPath(roundedRect: badgeRect, cornerWidth: badgeH * 0.25, cornerHeight: badgeH * 0.25, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.62))
        ctx.fillPath()

        TextRenderer.draw(
            text: text,
            font: font,
            color: CGColor(gray: 1, alpha: 0.96),
            at: CGPoint(x: badgeRect.minX + padX, y: badgeRect.minY + padY + size.descent),
            maxWidth: .greatestFiniteMagnitude,
            in: ctx
        )
        ctx.restoreGState()
    }

    // MARK: - Export

    static func export(image: CGImage, to url: URL, format: ImageFormat, quality: Double) throws {
        guard let type = UTType(format.utTypeIdentifier),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else {
            throw ScreenlistError.couldNotCreateDestination(url.path)
        }

        var properties: [CFString: Any] = [:]
        if format.supportsQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0.1), 1.0)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenlistError.couldNotWriteFile(url.path)
        }
    }

    // MARK: - Output naming

    static func outputURL(for videoURL: URL, settings: SettingsSnapshot) -> URL {
        let folder: URL
        switch settings.outputMode {
        case .sameAsVideo:
            folder = videoURL.deletingLastPathComponent()
        case .customFolder:
            if settings.customFolderPath.isEmpty {
                folder = videoURL.deletingLastPathComponent()
            } else {
                folder = URL(fileURLWithPath: (settings.customFolderPath as NSString).expandingTildeInPath,
                             isDirectory: true)
            }
        }

        let baseName = expandTemplate(settings.filenameTemplate, videoURL: videoURL, settings: settings)
        let ext = settings.format.fileExtension
        var candidate = folder.appendingPathComponent(baseName).appendingPathExtension(ext)

        if settings.collisionPolicy == .autoRename {
            var counter = 2
            while FileManager.default.fileExists(atPath: candidate.path) {
                candidate = folder.appendingPathComponent("\(baseName) \(counter)").appendingPathExtension(ext)
                counter += 1
            }
        }
        return candidate
    }

    static func expandTemplate(_ template: String, videoURL: URL, settings: SettingsSnapshot) -> String {
        let trimmed = template.trimmingCharacters(in: .whitespaces)
        let effective = trimmed.isEmpty ? "{name}_screenlist" : trimmed

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH.mm.ss"
        let now = Date()

        var result = effective
            .replacingOccurrences(of: "{name}", with: videoURL.deletingPathExtension().lastPathComponent)
            .replacingOccurrences(of: "{date}", with: dateFormatter.string(from: now))
            .replacingOccurrences(of: "{time}", with: timeFormatter.string(from: now))
            .replacingOccurrences(of: "{rows}", with: String(settings.rows))
            .replacingOccurrences(of: "{cols}", with: String(settings.columns))

        // Strip characters that are illegal or awkward in file names.
        result = result
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? videoURL.deletingPathExtension().lastPathComponent + "_screenlist" : cleaned
    }
}
