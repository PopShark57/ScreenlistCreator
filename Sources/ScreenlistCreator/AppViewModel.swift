import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct VideoItem: Identifiable {
    enum Status {
        case loadingInfo
        case ready
        case running(Double)      // 0...1
        case done(URL)
        case failed(String)
    }

    let id = UUID()
    let url: URL
    var metadata: VideoMetadata?
    var status: Status = .loadingInfo

    var displayName: String { url.lastPathComponent }

    var subtitle: String {
        guard let m = metadata else {
            if case .failed = status { return "Could not be read — click the warning for details" }
            return "Reading info…"
        }
        var parts = [m.durationText, m.resolutionText, m.fileSizeText]
        // Worth surfacing: it explains why a file works here but not in QuickTime.
        if m.backend == .ffmpeg { parts.append("FFmpeg") }
        return parts.joined(separator: "  •  ")
    }
}

struct FFmpegStatus: Sendable {
    var isInstalled = false
    var path = ""
    var version = ""

    var summary: String {
        guard isInstalled else { return "Not found" }
        return version.isEmpty ? path : "\(version) — \(path)"
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    static let shared = AppViewModel()

    @Published var items: [VideoItem] = []
    @Published var selection: Set<UUID> = []
    @Published var isGenerating = false
    @Published var previewImage: NSImage?
    @Published var isPreviewPresented = false
    @Published var isPreviewLoading = false
    @Published var lastError: String?
    @Published var ffmpegStatus = FFmpegStatus()

    private var generationTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?

    static var allowedContentTypes: [UTType] { VideoFormats.openPanelContentTypes }

    // MARK: - FFmpeg

    func refreshFFmpegStatus() {
        Task {
            guard let tool = FFmpegLocator.locate() else {
                ffmpegStatus = FFmpegStatus()
                return
            }
            let version = await FFmpegLocator.version(of: tool)
            ffmpegStatus = FFmpegStatus(isInstalled: true, path: tool.ffmpeg.path, version: version)
        }
    }

    /// Re-reads files that failed to load. Called after the FFmpeg path changes so a
    /// freshly installed copy picks up everything already sitting in the queue.
    func retryFailedItems() {
        for item in items {
            guard case .failed = item.status else { continue }
            update(id: item.id) {
                $0.metadata = nil
                $0.status = .loadingInfo
            }
            loadMetadata(for: item.id, url: item.url)
        }
    }

    // MARK: - Queue management

    func addVideos(urls: [URL]) {
        let existing = Set(items.map { $0.url.standardizedFileURL })
        for url in urls {
            let std = url.standardizedFileURL
            guard !existing.contains(std) else { continue }
            guard FileManager.default.fileExists(atPath: std.path) else { continue }
            let item = VideoItem(url: std)
            items.append(item)
            loadMetadata(for: item.id, url: std)
        }
    }

    private func loadMetadata(for id: UUID, url: URL) {
        Task {
            do {
                let metadata = try await VideoMetadataLoader.load(url: url)
                update(id: id) {
                    $0.metadata = metadata
                    $0.status = .ready
                }
            } catch {
                update(id: id) {
                    $0.status = .failed(error.localizedDescription)
                }
            }
        }
    }

    func removeSelected() {
        items.removeAll { selection.contains($0.id) }
        selection.removeAll()
    }

    func clearAll() {
        guard !isGenerating else { return }
        items.removeAll()
        selection.removeAll()
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = Self.allowedContentTypes
        panel.message = "Choose video files to create screenlists for"
        if panel.runModal() == .OK {
            addVideos(urls: panel.urls)
        }
    }

    // MARK: - Generation

    func generateAll(settings: SettingsSnapshot) {
        guard !isGenerating else { return }
        let pending = items.compactMap { item -> (UUID, URL, VideoMetadata)? in
            guard let m = item.metadata else { return nil }
            switch item.status {
            case .ready, .done, .failed: return (item.id, item.url, m)
            default: return nil
            }
        }
        guard !pending.isEmpty else { return }

        isGenerating = true
        lastError = nil
        generationTask = Task {
            for (id, url, metadata) in pending {
                if Task.isCancelled { break }
                update(id: id) { $0.status = .running(0) }
                do {
                    let image = try await ScreenlistEngine.renderSheet(
                        videoURL: url,
                        metadata: metadata,
                        settings: settings,
                        progress: { fraction in
                            Task { @MainActor in
                                self.update(id: id) { $0.status = .running(fraction) }
                            }
                        }
                    )
                    let outputURL = ScreenlistEngine.outputURL(for: url, settings: settings)
                    try ScreenlistEngine.export(
                        image: image,
                        to: outputURL,
                        format: settings.format,
                        quality: settings.quality
                    )
                    update(id: id) { $0.status = .done(outputURL) }
                } catch is CancellationError {
                    update(id: id) { $0.status = .ready }
                    break
                } catch {
                    update(id: id) { $0.status = .failed(error.localizedDescription) }
                }
            }
            isGenerating = false
        }
    }

    func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
        for index in items.indices {
            if case .running = items[index].status {
                items[index].status = .ready
            }
        }
    }

    // MARK: - Preview

    func generatePreview(settings: SettingsSnapshot) {
        guard !isPreviewLoading else { return }
        // Preview the first selected item, else the first ready one.
        let candidate = items.first { selection.contains($0.id) && $0.metadata != nil }
            ?? items.first { $0.metadata != nil }
        guard let item = candidate, let metadata = item.metadata else { return }

        isPreviewLoading = true
        previewTask = Task {
            do {
                let image = try await ScreenlistEngine.renderSheet(
                    videoURL: item.url,
                    metadata: metadata,
                    settings: settings,
                    sheetWidthOverride: min(settings.sheetWidth, 1400),
                    progress: { _ in }
                )
                previewImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                isPreviewPresented = true
            } catch {
                lastError = error.localizedDescription
            }
            isPreviewLoading = false
        }
    }

    // MARK: - Helpers

    func revealInFinder(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func update(id: UUID, _ mutate: (inout VideoItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[index])
    }
}
