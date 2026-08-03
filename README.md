# Screenlist Creator

A native macOS app that creates **screenlists** (thumbnail contact sheets) from video
files — a grid of evenly spaced frames with an optional info header and per-frame
timestamps, exported as a single image.

![Sample screenlist](docs/sample_screenlist.png)

*Sample output (4×3 grid, dark theme, header and timestamps on) generated from a synthetic test video.*

## Features

- **Drag & drop** one or more videos into the queue (or ⌘O / "Add Videos", or drop
  them on the Dock icon). Batch processing with per-video progress.
- **Grid**: 1–12 rows × 1–10 columns, sheet width 640–6144 px, adjustable cell
  spacing and outer margin.
- **Appearance**: dark or light sheet theme; optional header with file name, size,
  duration, resolution, codec and frame rate; optional timestamp badge on each
  frame in any corner.
- **Capture range**: skip a percentage of the intro/outro (default 2 %) so credits
  and black lead-ins don't waste cells; frames are sampled evenly across the rest.
- **Output**: JPEG / PNG / HEIC / TIFF, quality slider for lossy formats, save next
  to the video or into a chosen folder, file-name template with `{name}`, `{date}`,
  `{time}`, `{rows}`, `{cols}` tokens, and a keep-both/overwrite collision policy.
- **Preview** button renders a reduced-size sheet without writing any file.
- Settings persist between launches.

## Building

Requires macOS 14+ and the Xcode Command Line Tools (full Xcode works too).

```bash
./scripts/build-app.sh
```

This compiles with `swiftc`, renders the app icon, assembles and ad-hoc signs
`dist/Screenlist Creator.app`. Copy it to `/Applications` if you like.

> The script deliberately avoids SwiftPM/xcodebuild: it compiles the sources
> directly, and if the newest installed SDK requires Xcode-only SwiftUI macro
> plugins it automatically falls back to the newest usable SDK
> (override with `SDK=/path/to/MacOSX.sdk ./scripts/build-app.sh`).

## Headless CLI

The binary inside the bundle also works headlessly, which is handy for scripting
and testing:

```bash
"dist/Screenlist Creator.app/Contents/MacOS/ScreenlistCreator" --cli video.mp4 \
    [--out folder] [--rows N] [--cols N] [--format jpeg|png|heic|tiff] [--width px]
```

## Project layout

| Path | Purpose |
| --- | --- |
| `Sources/ScreenlistCreator/ScreenlistEngine.swift` | Frame extraction (AVFoundation) + sheet composition (CoreGraphics) + export (ImageIO) |
| `Sources/ScreenlistCreator/VideoMetadata.swift` | Duration/resolution/codec/fps/size loading |
| `Sources/ScreenlistCreator/TextRenderer.swift` | CoreText line drawing (AppKit-free, background-safe) |
| `Sources/ScreenlistCreator/Settings.swift` | Settings model, persisted to `UserDefaults` |
| `Sources/ScreenlistCreator/AppViewModel.swift` | Video queue, generation orchestration |
| `Sources/ScreenlistCreator/ContentView.swift` | SwiftUI interface |
| `Sources/ScreenlistCreator/Main.swift` | App entry, Dock-drop delegate |
| `Sources/ScreenlistCreator/CLIRunner.swift` | Headless `--cli` mode |
| `scripts/build-app.sh` | Build + bundle + sign |
| `scripts/make_icon.swift` | Renders the app icon programmatically |
