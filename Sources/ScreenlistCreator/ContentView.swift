import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var model: AppViewModel

    var body: some View {
        HSplitView {
            VideoListPane()
                .frame(minWidth: 330, idealWidth: 380)
            SettingsPane()
                .frame(minWidth: 420, idealWidth: 480)
        }
        .frame(minWidth: 820, minHeight: 620)
        .sheet(isPresented: $model.isPreviewPresented) {
            PreviewSheet()
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

// MARK: - Left pane: video queue

struct VideoListPane: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var model: AppViewModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if model.items.isEmpty {
                emptyState
            } else {
                List(selection: $model.selection) {
                    ForEach(model.items) { item in
                        VideoRow(item: item)
                            .tag(item.id)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack(spacing: 12) {
                Button {
                    model.presentOpenPanel()
                } label: {
                    Label("Add Videos", systemImage: "plus")
                }

                Button {
                    model.removeSelected()
                } label: {
                    Label("Remove", systemImage: "minus")
                }
                .disabled(model.selection.isEmpty || model.isGenerating)

                Spacer()

                Button("Clear All") {
                    model.clearAll()
                }
                .disabled(model.items.isEmpty || model.isGenerating)
            }
            .padding(10)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "film.stack")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text("Drop videos here")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text("or click “Add Videos” below")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Text("MP4, MOV, AVI, MKV, WebM, WMV, FLV, MPEG and more")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var found = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            found = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                }
                if let url {
                    Task { @MainActor in
                        model.addVideos(urls: [url])
                    }
                }
            }
        }
        return found
    }
}

struct VideoRow: View {
    @EnvironmentObject var model: AppViewModel
    let item: VideoItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "film")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            statusView
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var statusView: some View {
        switch item.status {
        case .loadingInfo:
            ProgressView()
                .controlSize(.small)
        case .ready:
            EmptyView()
        case .running(let fraction):
            HStack(spacing: 6) {
                ProgressView(value: fraction)
                    .frame(width: 60)
                Text("\(Int(fraction * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .done(let url):
            Button {
                model.revealInFinder(url: url)
            } label: {
                Label("Show", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .help("Screenlist saved to \(url.path). Click to reveal in Finder.")
        case .failed(let message):
            // Clickable: the common failure is "install FFmpeg", which is too long
            // to read in a tooltip.
            Button {
                model.lastError = message
            } label: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            }
            .buttonStyle(.plain)
            .help(message)
        }
    }
}

// MARK: - Right pane: settings

struct SettingsPane: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var model: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    layoutSection
                    appearanceSection
                    rangeSection
                    outputSection
                    decodingSection
                }
                .padding(14)
            }

            Divider()
            actionBar
        }
        .onAppear { model.refreshFFmpegStatus() }
    }

    private var layoutSection: some View {
        GroupBox("Grid") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Stepper("Rows: \(settings.rows)", value: $settings.rows, in: 1...12)
                    Spacer()
                    Stepper("Columns: \(settings.columns)", value: $settings.columns, in: 1...10)
                }
                Text("\(settings.rows * settings.columns) frames per screenlist")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Sheet width") {
                    HStack(spacing: 8) {
                        Slider(value: sheetWidthBinding, in: 640...6144, step: 64)
                            .frame(maxWidth: 220)
                        Text("\(settings.sheetWidth) px")
                            .font(.callout.monospacedDigit())
                            .frame(width: 64, alignment: .trailing)
                    }
                }

                HStack {
                    Stepper("Spacing: \(settings.spacing) px", value: $settings.spacing, in: 0...64)
                    Spacer()
                    Stepper("Margin: \(settings.margin) px", value: $settings.margin, in: 0...128)
                }
            }
            .padding(6)
        }
    }

    private var sheetWidthBinding: Binding<Double> {
        Binding(
            get: { Double(settings.sheetWidth) },
            set: { settings.sheetWidth = Int($0) }
        )
    }

    private var appearanceSection: some View {
        GroupBox("Appearance") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Theme", selection: $settings.theme) {
                    ForEach(SheetTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Header with file info (name, size, duration, codec)", isOn: $settings.showHeader)
                Toggle("Timestamp on each frame", isOn: $settings.showTimestamps)

                if settings.showTimestamps {
                    Picker("Timestamp position", selection: $settings.timestampCorner) {
                        ForEach(TimestampCorner.allCases) { corner in
                            Text(corner.displayName).tag(corner)
                        }
                    }
                }
            }
            .padding(6)
        }
    }

    private var rangeSection: some View {
        GroupBox("Capture Range") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Skip intro") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.skipStartPercent, in: 0...20, step: 0.5)
                            .frame(maxWidth: 220)
                        Text(String(format: "%.1f %%", settings.skipStartPercent))
                            .font(.callout.monospacedDigit())
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                LabeledContent("Skip outro") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.skipEndPercent, in: 0...20, step: 0.5)
                            .frame(maxWidth: 220)
                        Text(String(format: "%.1f %%", settings.skipEndPercent))
                            .font(.callout.monospacedDigit())
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                Text("Frames are spaced evenly across the remaining part of the video.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }

    private var outputSection: some View {
        GroupBox("Output") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Format", selection: $settings.format) {
                    ForEach(ImageFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .pickerStyle(.segmented)

                if settings.format.supportsQuality {
                    LabeledContent("Quality") {
                        HStack(spacing: 8) {
                            Slider(value: $settings.quality, in: 0.3...1.0)
                                .frame(maxWidth: 220)
                            Text("\(Int(settings.quality * 100)) %")
                                .font(.callout.monospacedDigit())
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                }

                Picker("Save to", selection: $settings.outputMode) {
                    ForEach(OutputMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                if settings.outputMode == .customFolder {
                    HStack(spacing: 8) {
                        Text(settings.customFolderPath.isEmpty ? "No folder selected" : settings.customFolderPath)
                            .font(.callout)
                            .foregroundStyle(settings.customFolderPath.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { chooseFolder() }
                    }
                }

                LabeledContent("File name") {
                    TextField("{name}_screenlist", text: $settings.filenameTemplate)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                }
                Text("Tokens: {name} {date} {time} {rows} {cols}")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("If file exists", selection: $settings.collisionPolicy) {
                    ForEach(CollisionPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
            }
            .padding(6)
        }
    }

    private var decodingSection: some View {
        GroupBox("Decoding") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: model.ffmpegStatus.isInstalled
                          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.ffmpegStatus.isInstalled ? .green : .yellow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("FFmpeg: \(model.ffmpegStatus.summary)")
                            .font(.callout)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Text(model.ffmpegStatus.isInstalled
                             ? "MP4 and MOV decode natively; FFmpeg handles the rest."
                             : "Install it with “brew install ffmpeg”, or choose an existing copy.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                HStack(spacing: 8) {
                    Button("Choose FFmpeg…") { chooseFFmpeg() }
                    if !settings.ffmpegPath.isEmpty {
                        Button("Use Automatic") {
                            settings.ffmpegPath = ""
                            model.refreshFFmpegStatus()
                            model.retryFailedItems()
                        }
                    }
                    Button("Re-check") {
                        model.refreshFFmpegStatus()
                        model.retryFailedItems()
                    }
                    Spacer()
                }

                Text("Adds AVI, MKV, WebM, WMV, ASF, FLV, DivX, OGV, MXF, VOB, "
                     + "RealMedia and more. Full list: --cli --formats")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(6)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button("Restore Defaults") {
                settings.restoreDefaults()
            }
            .disabled(model.isGenerating)

            Spacer()

            if model.isPreviewLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Preview") {
                model.generatePreview(settings: settings.snapshot())
            }
            .disabled(model.items.isEmpty || model.isGenerating || model.isPreviewLoading)

            if model.isGenerating {
                Button("Cancel") {
                    model.cancelGeneration()
                }
                .keyboardShortcut(.cancelAction)
            }

            Button {
                model.generateAll(settings: settings.snapshot())
            } label: {
                Label("Create Screenlists", systemImage: "square.grid.3x3")
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(model.items.isEmpty || model.isGenerating)
        }
        .padding(12)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder where screenlists will be saved"
        if panel.runModal() == .OK, let url = panel.url {
            settings.customFolderPath = url.path
        }
    }

    private func chooseFFmpeg() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Select the ffmpeg binary, or the folder containing ffmpeg and ffprobe"
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url {
            settings.ffmpegPath = url.path
            model.refreshFFmpegStatus()
            model.retryFailedItems()
        }
    }
}

// MARK: - Preview sheet

struct PreviewSheet: View {
    @EnvironmentObject var model: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            if let image = model.previewImage {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(
                            maxWidth: min(image.size.width, 900),
                            maxHeight: min(image.size.height, 700)
                        )
                        .padding()
                }
            } else {
                Text("No preview available")
                    .foregroundStyle(.secondary)
                    .padding(40)
            }
            Divider()
            HStack {
                Text("Preview is rendered at reduced size")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}
