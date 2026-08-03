import Foundation

/// Headless mode used for testing the engine without the UI:
///   ScreenlistCreator --cli <video> [--out <folder>] [--rows N] [--cols N]
///                     [--format jpeg|png|heic|tiff] [--width N]
enum CLIRunner {
    static func run(arguments: [String]) -> Int32 {
        var args = arguments.dropFirst() // skip executable
        args = args.drop { $0 != "--cli" }.dropFirst()

        var videoPath: String?
        var outFolder: String?
        var rows = 4
        var cols = 3
        var format = ImageFormat.jpeg
        var width = 2048

        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--out": outFolder = iterator.next()
            case "--rows": rows = Int(iterator.next() ?? "") ?? rows
            case "--cols": cols = Int(iterator.next() ?? "") ?? cols
            case "--format": format = ImageFormat(rawValue: iterator.next() ?? "") ?? format
            case "--width": width = Int(iterator.next() ?? "") ?? width
            default:
                if videoPath == nil { videoPath = arg }
            }
        }

        guard let videoPath else {
            FileHandle.standardError.write(Data("Usage: ScreenlistCreator --cli <video> [--out folder] [--rows N] [--cols N] [--format jpeg|png|heic|tiff] [--width N]\n".utf8))
            return 2
        }

        let videoURL = URL(fileURLWithPath: (videoPath as NSString).expandingTildeInPath)
        var snapshot = SettingsSnapshot(
            rows: rows,
            columns: cols,
            format: format,
            quality: 0.85,
            sheetWidth: width,
            spacing: 8,
            margin: 16,
            showHeader: true,
            showTimestamps: true,
            timestampCorner: .bottomRight,
            theme: .dark,
            skipStartPercent: 2,
            skipEndPercent: 2,
            outputMode: .sameAsVideo,
            customFolderPath: "",
            filenameTemplate: "{name}_screenlist",
            collisionPolicy: .autoRename
        )
        if let outFolder {
            snapshot.outputMode = .customFolder
            snapshot.customFolderPath = outFolder
        }

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var exitCode: Int32 = 0

        Task.detached {
            do {
                let metadata = try await VideoMetadataLoader.load(url: videoURL)
                print("Video: \(videoURL.lastPathComponent) — \(metadata.durationText), \(metadata.resolutionText), \(metadata.codecName), \(metadata.fileSizeText)")
                let image = try await ScreenlistEngine.renderSheet(
                    videoURL: videoURL,
                    metadata: metadata,
                    settings: snapshot,
                    progress: { _ in }
                )
                let outputURL = ScreenlistEngine.outputURL(for: videoURL, settings: snapshot)
                try ScreenlistEngine.export(image: image, to: outputURL, format: snapshot.format, quality: snapshot.quality)
                print("Saved: \(outputURL.path) (\(image.width)×\(image.height))")
            } catch {
                FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
                exitCode = 1
            }
            semaphore.signal()
        }

        semaphore.wait()
        return exitCode
    }
}
