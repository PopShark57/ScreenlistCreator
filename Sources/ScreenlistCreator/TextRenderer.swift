import Foundation
import CoreGraphics
import CoreText

/// Small CoreText helper for drawing single lines into a CGContext.
/// AppKit-free so it is safe to use from background tasks.
enum TextRenderer {

    struct TextSize {
        var width: CGFloat
        var height: CGFloat
        var ascent: CGFloat
        var descent: CGFloat
    }

    static func measure(text: String, font: CTFont) -> TextSize {
        let line = makeLine(text: text, font: font, color: CGColor(gray: 0, alpha: 1))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        return TextSize(width: width, height: ascent + descent, ascent: ascent, descent: descent)
    }

    /// Draws `text` with its baseline at `point.y` (plus descent handling done by callers),
    /// truncating in the middle if it exceeds `maxWidth`.
    @discardableResult
    static func draw(
        text: String,
        font: CTFont,
        color: CGColor,
        at point: CGPoint,
        maxWidth: CGFloat,
        in ctx: CGContext
    ) -> CGFloat {
        var line = makeLine(text: text, font: font, color: color)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        if width > maxWidth {
            let token = makeLine(text: "…", font: font, color: color)
            if let truncated = CTLineCreateTruncatedLine(line, Double(maxWidth), .middle, token) {
                line = truncated
            }
        }
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = point
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        return min(width, maxWidth)
    }

    private static func makeLine(text: String, font: CTFont, color: CGColor) -> CTLine {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color
        ]
        let attributed = CFAttributedStringCreate(
            kCFAllocatorDefault,
            text as CFString,
            attributes as CFDictionary
        )!
        return CTLineCreateWithAttributedString(attributed)
    }
}
