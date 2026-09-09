import AppKit
import CoreGraphics
import Foundation

// Renders the Vocaret icon from vectors: midnight glass, a cyan/violet orbital
// halo and a white microphone, with a simplified silhouette at small sizes.

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

/// Superellipse-ish rounded rect matching Apple's icon silhouette.
func squircle(in rect: CGRect) -> CGPath {
    let radius = rect.width * 0.2237
    return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func micPath(scale: CGFloat) -> CGPath {
    let path = CGMutablePath()
    func s(_ v: CGFloat) -> CGFloat { v * scale }

    // Capsule body.
    let body = CGRect(x: s(412), y: s(455), width: s(200), height: s(380))
    path.addRoundedRect(in: body, cornerWidth: s(100), cornerHeight: s(100))

    // Cradle: bottom half of a ring, drawn as a stroked arc turned into a shape.
    let cradle = CGMutablePath()
    cradle.addArc(
        center: CGPoint(x: s(512), y: s(525)),
        radius: s(190),
        startAngle: .pi,
        endAngle: 2 * .pi,
        clockwise: false
    )
    let stroked = cradle.copy(strokingWithWidth: s(48), lineCap: .round, lineJoin: .round, miterLimit: 10)
    path.addPath(stroked)

    // Stand and base. The stand runs up into the cradle so no seam shows, and
    // is long enough to read as a stem rather than a stub.
    path.addRoundedRect(in: CGRect(x: s(488), y: s(211), width: s(48), height: s(134)),
                        cornerWidth: s(24), cornerHeight: s(24))
    path.addRoundedRect(in: CGRect(x: s(397), y: s(185), width: s(230), height: s(52)),
                        cornerWidth: s(26), cornerHeight: s(26))
    return path
}

func render(size: Int) -> CGImage? {
    let dimension = CGFloat(size)
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    let scale = dimension / 1024.0
    // Apple's icon grid: artwork sits inset inside the canvas.
    let inset = dimension * 0.094
    let iconRect = CGRect(x: inset, y: inset, width: dimension - inset * 2, height: dimension - inset * 2)

    // Background squircle with a diagonal gradient.
    context.saveGState()
    context.addPath(squircle(in: iconRect))
    context.clip()
    let colors = [
        CGColor(srgbRed: 0.08, green: 0.18, blue: 0.28, alpha: 1), // midnight teal
        CGColor(srgbRed: 0.18, green: 0.08, blue: 0.34, alpha: 1), // deep violet
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: iconRect.minX, y: iconRect.maxY),
            end: CGPoint(x: iconRect.maxX, y: iconRect.minY),
            options: []
        )
    }
    // Soft highlight across the top for depth.
    if let glow = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22),
                 CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0)] as CFArray,
        locations: [0, 1]
    ) {
        context.drawRadialGradient(
            glow,
            startCenter: CGPoint(x: iconRect.midX, y: iconRect.maxY),
            startRadius: 0,
            endCenter: CGPoint(x: iconRect.midX, y: iconRect.maxY),
            endRadius: iconRect.width * 0.75,
            options: []
        )
    }
    context.restoreGState()

    // Orbital edge lighting echoes the voice-reactive particle sphere. Keep the
    // smallest variants simple so the microphone remains recognisable in Dock.
    context.saveGState()
    context.addPath(squircle(in: iconRect.insetBy(dx: 2 * scale, dy: 2 * scale)))
    context.setStrokeColor(CGColor(srgbRed: 0.6, green: 0.83, blue: 1, alpha: 0.24))
    context.setLineWidth(max(1, 3 * scale))
    context.strokePath()
    if size >= 64 {
        context.translateBy(x: dimension / 2, y: dimension / 2)
        context.rotate(by: -.pi / 5)
        context.scaleBy(x: 1, y: 0.88)
        for i in 0..<96 {
            let angle = Double(i) * 2 * Double.pi / 96
            let radius = 340 * scale
            let dot = (i % 3 == 0 ? 3.5 : 2.1) * scale
            let tint = CGFloat(i) / 95
            context.setFillColor(CGColor(srgbRed: 0.18 + tint * 0.48,
                                        green: 0.84 - tint * 0.43,
                                        blue: 1, alpha: 0.6 + 0.3 * sin(angle)))
            context.fillEllipse(in: CGRect(x: cos(angle) * radius - dot,
                                            y: sin(angle) * radius - dot, width: dot * 2, height: dot * 2))
        }
    }
    context.restoreGState()

    // Microphone glyph, with a subtle drop shadow so it reads on the gradient.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -dimension * 0.008),
                      blur: dimension * 0.02,
                      color: CGColor(srgbRed: 0.10, green: 0.05, blue: 0.35, alpha: 0.35))
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.addPath(micPath(scale: scale))
    context.fillPath()
    context.restoreGState()

    return context.makeImage()
}

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let destination = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let image = render(size: variant.size) else {
        FileHandle.standardError.write(Data("failed to render \(variant.name)\n".utf8))
        exit(1)
    }
    write(image, to: "\(outputDir)/\(variant.name).png")
}
print("wrote \(variants.count) images to \(outputDir)")
