// Renders the app icon (a small contact-sheet motif) to AppIcon-1024.png.
// Run: swift scripts/make_icon.swift <output.png>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

let S = CGFloat(size)

// Rounded-square background (macOS icon style), dark slate with subtle gradient.
let bgRect = CGRect(x: S * 0.08, y: S * 0.08, width: S * 0.84, height: S * 0.84)
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: S * 0.19, cornerHeight: S * 0.19, transform: nil)
ctx.addPath(bgPath)
ctx.clip()

let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 0.13, green: 0.15, blue: 0.20, alpha: 1),
        CGColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1)
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])

// 3×3 grid of "frames" in shades of teal/blue.
let cols = 3, rows = 3
let gridInset = S * 0.17
let spacing = S * 0.025
let cellW = (S - 2 * gridInset - CGFloat(cols - 1) * spacing) / CGFloat(cols)
let cellH = cellW * 0.62
let gridH = CGFloat(rows) * cellH + CGFloat(rows - 1) * spacing
let gridBottom = (S - gridH) / 2

let hues: [(CGFloat, CGFloat, CGFloat)] = [
    (0.20, 0.55, 0.85), (0.25, 0.70, 0.80), (0.30, 0.80, 0.65),
    (0.15, 0.45, 0.75), (0.35, 0.75, 0.90), (0.22, 0.60, 0.70),
    (0.40, 0.85, 0.80), (0.18, 0.50, 0.65), (0.28, 0.65, 0.88)
]

for row in 0..<rows {
    for col in 0..<cols {
        let i = row * cols + col
        let x = gridInset + CGFloat(col) * (cellW + spacing)
        let y = gridBottom + CGFloat(rows - 1 - row) * (cellH + spacing)
        let rect = CGRect(x: x, y: y, width: cellW, height: cellH)
        let path = CGPath(roundedRect: rect, cornerWidth: S * 0.012, cornerHeight: S * 0.012, transform: nil)
        ctx.addPath(path)
        let (r, g, b) = hues[i]
        ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
        ctx.fillPath()
    }
}

// Play triangle over the center cell.
let centerX = S / 2
let centerY = gridBottom + gridH / 2
let triR = cellH * 0.52
ctx.move(to: CGPoint(x: centerX - triR * 0.5, y: centerY - triR * 0.7))
ctx.addLine(to: CGPoint(x: centerX - triR * 0.5, y: centerY + triR * 0.7))
ctx.addLine(to: CGPoint(x: centerX + triR * 0.8, y: centerY))
ctx.closePath()
ctx.setFillColor(CGColor(gray: 1, alpha: 0.92))
ctx.setShadow(offset: .zero, blur: S * 0.02, color: CGColor(gray: 0, alpha: 0.55))
ctx.fillPath()

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: out) as CFURL
let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write(Data("Failed to write \(out)\n".utf8))
    exit(1)
}
print("Wrote \(out)")
