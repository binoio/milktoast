// Programmatic app-icon generator for Milktoast.
//
// macOS 26/27 mask app icons into the system squircle themselves, so the artwork
// must fill the entire square canvas edge to edge — no pre-rounded corners, no
// inset margin, no baked-in shadow. Anything drawn near a corner is clipped by
// the mask, so the character stays inside the safe inner region.
//
// Design: a cheerful slice of toast standing in a pool of milk. The app is
// deliberately mild — it does one small thing and gets out of the way — and the
// icon says so.
//
// Usage: swift Scripts/generate_icon.swift <output-directory>

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [r, g, b, a])!
}

/// 0-255 sugar, so the palette below reads like the hex values it came from.
func hex(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    rgb(CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, a)
}

enum Palette {
    static let skyTop     = hex(0x9C, 0xD4, 0xF5)
    static let skyBottom  = hex(0x5A, 0xA3, 0xD8)
    static let milk       = hex(0xFD, 0xFE, 0xFF)
    static let milkShade  = hex(0xDD, 0xEE, 0xF8)
    static let crust      = hex(0xC8, 0x7C, 0x2E)
    static let crustDark  = hex(0xA9, 0x63, 0x20)
    static let bread      = hex(0xF7, 0xD3, 0x8C)
    static let breadLight = hex(0xFD, 0xE8, 0xB8)
    static let butter     = hex(0xFF, 0xE1, 0x6B)
    static let butterEdge = hex(0xF0, 0xC0, 0x3A)
    static let ink        = hex(0x4A, 0x2C, 0x12)
    static let blush      = hex(0xF3, 0x93, 0x93, 0.55)
}

/// The classic sandwich-slice silhouette: a squared-off body with a two-bump
/// crown, described in a 0...1 box so it can be laid out at any size.
func toastPath(in box: CGRect) -> CGPath {
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: box.minX + x * box.width, y: box.minY + y * box.height)
    }

    let path = CGMutablePath()
    path.move(to: p(0.12, 0.00))
    path.addLine(to: p(0.88, 0.00))
    path.addQuadCurve(to: p(1.00, 0.12), control: p(1.00, 0.00))
    path.addLine(to: p(1.00, 0.50))
    // Right shoulder, dip, left shoulder — the two bumps.
    path.addCurve(to: p(0.70, 0.96), control1: p(1.00, 0.82), control2: p(0.88, 0.96))
    path.addCurve(to: p(0.50, 0.86), control1: p(0.61, 0.96), control2: p(0.58, 0.86))
    path.addCurve(to: p(0.30, 0.96), control1: p(0.42, 0.86), control2: p(0.39, 0.96))
    path.addCurve(to: p(0.00, 0.50), control1: p(0.12, 0.96), control2: p(0.00, 0.82))
    path.addLine(to: p(0.00, 0.12))
    path.addQuadCurve(to: p(0.12, 0.00), control: p(0.00, 0.00))
    path.closeSubpath()
    return path
}

/// A gently wavy top edge for the milk, filled down to the bottom of the canvas.
func milkPath(width s: CGFloat, height: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: 0))
    path.addLine(to: CGPoint(x: 0, y: height))
    path.addCurve(
        to: CGPoint(x: s * 0.5, y: height * 0.94),
        control1: CGPoint(x: s * 0.16, y: height * 1.10),
        control2: CGPoint(x: s * 0.32, y: height * 0.84)
    )
    path.addCurve(
        to: CGPoint(x: s, y: height),
        control1: CGPoint(x: s * 0.70, y: height * 1.06),
        control2: CGPoint(x: s * 0.86, y: height * 0.88)
    )
    path.addLine(to: CGPoint(x: s, y: 0))
    path.closeSubpath()
    return path
}

func renderMaster(size: Int) -> CGImage {
    let s = CGFloat(size)
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: 0, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    // 1. Full-bleed sky. The squircle mask reveals gradient in every corner.
    let sky = CGGradient(
        colorsSpace: sRGB,
        colors: [Palette.skyTop, Palette.skyBottom] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(sky, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

    // 2. Soft bloom behind the character so the middle reads brighter.
    let bloom = CGGradient(
        colorsSpace: sRGB,
        colors: [rgb(1, 1, 1, 0.45), rgb(1, 1, 1, 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(
        bloom,
        startCenter: CGPoint(x: s * 0.5, y: s * 0.56), startRadius: 0,
        endCenter: CGPoint(x: s * 0.5, y: s * 0.56), endRadius: s * 0.44,
        options: []
    )

    // 3. The toast. Sized so it stays clear of the squircle's corners.
    let toastWidth = s * 0.54
    let toastHeight = s * 0.50
    let toastBox = CGRect(
        x: (s - toastWidth) / 2,
        y: s * 0.27,
        width: toastWidth,
        height: toastHeight
    )
    let crustPath = toastPath(in: toastBox)

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -s * 0.014),
        blur: s * 0.045,
        color: rgb(0.05, 0.15, 0.25, 0.35)
    )
    context.addPath(crustPath)
    context.setFillColor(Palette.crust)
    context.fillPath()
    context.restoreGState()

    // Crust rim: the same silhouette, scaled down about its own centre.
    let inset: CGFloat = 0.84
    var shrink = CGAffineTransform(translationX: toastBox.midX, y: toastBox.midY)
        .scaledBy(x: inset, y: inset)
        .translatedBy(x: -toastBox.midX, y: -toastBox.midY)
    let innerPath = crustPath.copy(using: &shrink)!

    context.saveGState()
    context.addPath(innerPath)
    context.clip()
    let crumb = CGGradient(
        colorsSpace: sRGB,
        colors: [Palette.breadLight, Palette.bread] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        crumb,
        start: CGPoint(x: 0, y: toastBox.maxY),
        end: CGPoint(x: 0, y: toastBox.minY),
        options: []
    )
    context.restoreGState()

    // A thin darker line just inside the crust reads as the baked edge.
    context.addPath(crustPath)
    context.setStrokeColor(Palette.crustDark)
    context.setLineWidth(s * 0.008)
    context.strokePath()

    // 4. Pat of butter, slightly tilted, melting on top.
    let butterSize = toastBox.width * 0.20
    let butterRect = CGRect(
        x: toastBox.midX - butterSize / 2,
        y: toastBox.minY + toastBox.height * 0.66,
        width: butterSize,
        height: butterSize * 0.72
    )
    context.saveGState()
    context.translateBy(x: butterRect.midX, y: butterRect.midY)
    context.rotate(by: -0.18)
    context.translateBy(x: -butterRect.midX, y: -butterRect.midY)
    let butterPath = CGPath(
        roundedRect: butterRect,
        cornerWidth: butterSize * 0.18,
        cornerHeight: butterSize * 0.18,
        transform: nil
    )
    context.addPath(butterPath)
    context.setFillColor(Palette.butter)
    context.fillPath()
    context.addPath(butterPath)
    context.setStrokeColor(Palette.butterEdge)
    context.setLineWidth(s * 0.006)
    context.strokePath()
    context.restoreGState()

    // 5. Face. Dots and a simple arc read at 16pt; anything finer does not.
    let eyeRadius = s * 0.021
    let eyeY = toastBox.minY + toastBox.height * 0.44
    let eyeOffset = toastBox.width * 0.20
    context.setFillColor(Palette.ink)
    for dx in [-eyeOffset, eyeOffset] {
        context.fillEllipse(in: CGRect(
            x: toastBox.midX + dx - eyeRadius,
            y: eyeY - eyeRadius * 1.15,
            width: eyeRadius * 2,
            height: eyeRadius * 2.3
        ))
    }

    context.setFillColor(Palette.blush)
    let blushRadius = s * 0.030
    for dx in [-eyeOffset * 1.62, eyeOffset * 1.62] {
        context.fillEllipse(in: CGRect(
            x: toastBox.midX + dx - blushRadius,
            y: eyeY - blushRadius * 1.55,
            width: blushRadius * 2,
            height: blushRadius * 1.5
        ))
    }

    let smile = CGMutablePath()
    let smileWidth = toastBox.width * 0.26
    let smileY = eyeY - toastBox.height * 0.14
    smile.move(to: CGPoint(x: toastBox.midX - smileWidth / 2, y: smileY))
    smile.addQuadCurve(
        to: CGPoint(x: toastBox.midX + smileWidth / 2, y: smileY),
        control: CGPoint(x: toastBox.midX, y: smileY - toastBox.height * 0.14)
    )
    context.addPath(smile)
    context.setStrokeColor(Palette.ink)
    context.setLineWidth(s * 0.016)
    context.setLineCap(.round)
    context.strokePath()

    // 6. Milk, drawn last so the toast sits in it rather than on it.
    let milkHeight = s * 0.24
    context.saveGState()
    context.addPath(milkPath(width: s, height: milkHeight))
    context.clip()
    let milkFill = CGGradient(
        colorsSpace: sRGB,
        colors: [Palette.milkShade, Palette.milk] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        milkFill,
        start: CGPoint(x: 0, y: 0),
        end: CGPoint(x: 0, y: milkHeight),
        options: []
    )
    context.restoreGState()

    return context.makeImage()!
}

func scale(_ image: CGImage, to size: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: 0, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return context.makeImage()!
}

func write(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw NSError(domain: "MilktoastIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot write \(url.path)"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "MilktoastIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot finalize \(url.path)"])
    }
}

let outputRoot = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Support/Icons")
let iconset = outputRoot.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let master = renderMaster(size: 1024)
try write(master, to: outputRoot.appendingPathComponent("icon-1024.png"))
// The product page uses a smaller copy; 512 is plenty for a 56pt card mark.
try write(scale(master, to: 512), to: outputRoot.appendingPathComponent("icon-512.png"))

// The filenames iconutil expects for a classic .icns.
let variants: [(point: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]
for variant in variants {
    let pixels = variant.point * variant.scale
    let suffix = variant.scale == 1 ? "" : "@2x"
    try write(
        scale(master, to: pixels),
        to: iconset.appendingPathComponent("icon_\(variant.point)x\(variant.point)\(suffix).png")
    )
}

print("Wrote \(iconset.path)")
