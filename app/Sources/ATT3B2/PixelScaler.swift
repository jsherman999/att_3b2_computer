import AppKit

/// Scales a terminal's 1-bit bitmap to the window without the artifacts of plain
/// nearest-neighbour scaling at a fractional ratio (uneven pixel columns, which turn
/// the 5620's stippled background into stripes and chew up glyphs).
///
/// It uses "sharp bilinear" scaling: blow the bitmap up by the next whole number with
/// nearest-neighbour, then let Core Graphics resample that to the exact size with
/// high-quality filtering. Edges stay crisp, every source pixel gets the same width,
/// and only the fraction of a device pixel at each edge is blended.
final class PixelScaler {
    private var context: CGContext?

    /// Draws `image` into `rect` of `ctx`, where `rect` is in points and `backingScale`
    /// is device pixels per point.
    func draw(_ image: CGImage, in rect: CGRect, ctx: CGContext, backingScale: CGFloat) {
        let ratio = rect.width * backingScale / CGFloat(image.width)
        let whole = ratio.rounded()

        // Exactly an integer ratio (or shrinking): draw directly.
        if abs(ratio - whole) < 0.01 && whole >= 1 {
            ctx.interpolationQuality = .none
            ctx.draw(image, in: rect)
            return
        }
        if ratio < 1 {
            ctx.interpolationQuality = .high
            ctx.draw(image, in: rect)
            return
        }

        let n = Int(ratio.rounded(.up))
        let w = image.width * n, h = image.height * n
        if context?.width != w || context?.height != h {
            context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        }
        guard let big = context else { return }
        big.interpolationQuality = .none
        big.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = big.makeImage() else { return }
        ctx.interpolationQuality = .high
        ctx.draw(scaled, in: rect)
    }

    /// Faint CRT scanlines, one per source row, but only when each row covers enough
    /// device pixels to show a gap without beating against the pixel grid.
    static func scanlines(rows: Int, in rect: CGRect, ctx: CGContext, backingScale: CGFloat) {
        let rowHeight = rect.height / CGFloat(rows)
        guard rowHeight * backingScale >= 3 else { return }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.15).cgColor)
        let line = 1 / backingScale
        for i in 0..<rows {
            ctx.fill(CGRect(x: rect.minX, y: rect.minY + CGFloat(i) * rowHeight, width: rect.width, height: line))
        }
    }
}
