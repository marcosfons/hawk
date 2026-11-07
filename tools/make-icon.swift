#!/usr/bin/env swift
// Draws Hawk's app icon as a macOS .iconset (every size iconutil needs).
//
//   swift tools/make-icon.swift Support/AppIcon.iconset     (or: make icon)
//
// Same body as drake's icon (a 1024-unit, y-down canvas on Apple's macOS icon
// grid: an 824pt continuous-corner tile with room for the shadow), so the two
// read as a family. The mark is a hawk's eye: an amber iris under a sharp brow,
// with gauge ticks around it for the monitoring. Sizes of 32px and below drop
// the ticks and thicken the brow so the eye still reads.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xFF) / 255,
        CGFloat((hex >> 8) & 0xFF) / 255,
        CGFloat(hex & 0xFF) / 255,
        alpha,
    ])!
}

func white(_ alpha: CGFloat) -> CGColor { rgb(0xFFFFFF, alpha) }
func black(_ alpha: CGFloat) -> CGColor { rgb(0x000000, alpha) }

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space,
               colors: stops.map(\.0) as CFArray,
               locations: stops.map(\.1))!
}

/// A rounded rectangle whose corners are quarter superellipses, so curvature
/// eases into the straight edges the way Apple's continuous corners do.
/// `radius` is the equivalent circular radius; the corner itself spans
/// about 1.53 times that along each edge.
func squirclePoints(_ r: CGRect, radius: CGFloat, exponent n: CGFloat = 3.3) -> [CGPoint] {
    let a = min(radius * 1.528, min(r.width, r.height) / 2)
    let corners: [(CGPoint, CGFloat)] = [
        (CGPoint(x: r.maxX - a, y: r.minY + a), -.pi / 2), // top right
        (CGPoint(x: r.maxX - a, y: r.maxY - a), 0),        // bottom right
        (CGPoint(x: r.minX + a, y: r.maxY - a), .pi / 2),  // bottom left
        (CGPoint(x: r.minX + a, y: r.minY + a), .pi),      // top left
    ]
    // Start and end mid-way along the top edge, so a dash seam lands on a
    // straight run rather than in a corner.
    var points = [CGPoint(x: r.midX, y: r.minY)]
    let steps = 96
    for (centre, start) in corners {
        for i in 0...steps {
            let t = start + CGFloat(i) / CGFloat(steps) * .pi / 2
            let c = cos(t), s = sin(t)
            points.append(CGPoint(x: centre.x + a * copysign(pow(abs(c), 2 / n), c),
                                  y: centre.y + a * copysign(pow(abs(s), 2 / n), s)))
        }
    }
    points.append(points[0])
    return points
}

func squircle(_ r: CGRect, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: squirclePoints(r, radius: radius))
    path.closeSubpath()
    return path
}

func draw(in ctx: CGContext, pixels: Int) {
    let s = CGFloat(pixels) / 1024
    let small = pixels <= 32
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: s, y: -s)
    // Shadow offsets and blur ignore the CTM, so they are given in pixels.
    func shadow(_ dy: CGFloat, _ blur: CGFloat, _ color: CGColor) {
        ctx.setShadow(offset: CGSize(width: 0, height: -dy * s), blur: blur * s, color: color)
    }

    // Body, as in drake
    let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let body = squircle(bodyRect, radius: 185)
    ctx.saveGState()
    shadow(10, 28, black(0.45))
    ctx.addPath(body)
    ctx.setFillColor(rgb(0x000000))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(rgb(0x1A1D24), 0), (rgb(0x0A0B0E), 0.5), (rgb(0x000000), 1)]),
                           start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
    // Warm glow behind the eye, cool light from below
    ctx.drawRadialGradient(gradient([(rgb(0xFFB547, 0.14), 0), (rgb(0xFF8A3D, 0.04), 0.5), (rgb(0xFF8A3D, 0), 1)]),
                           startCenter: CGPoint(x: 540, y: 560), startRadius: 0,
                           endCenter: CGPoint(x: 540, y: 560), endRadius: 520, options: [])
    ctx.drawRadialGradient(gradient([(rgb(0x5B9CFF, 0.06), 0), (rgb(0x5B9CFF, 0), 1)]),
                           startCenter: CGPoint(x: 300, y: 860), startRadius: 0,
                           endCenter: CGPoint(x: 300, y: 860), endRadius: 420, options: [])
    ctx.drawLinearGradient(gradient([(white(0.05), 0), (white(0), 1)]),
                           start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 520), options: [])
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.setLineWidth(small ? 0 : 4)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([(white(0.22), 0), (white(0.04), 0.5), (white(0.08), 1)]),
                           start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
    ctx.restoreGState()

    let eye = CGPoint(x: 530, y: 575)
    let iris: CGFloat = 205

    // Gauge ticks around the lower half of the eye, one lit like a needle.
    if !small {
        for i in 0...12 {
            let angle = CGFloat.pi * (0.08 + 0.84 * CGFloat(i) / 12)      // y-down: 0..pi is the lower half
            let inner = iris + 40, outer = iris + (i % 3 == 0 ? 92 : 70)
            ctx.move(to: CGPoint(x: eye.x + cos(angle) * inner, y: eye.y + sin(angle) * inner))
            ctx.addLine(to: CGPoint(x: eye.x + cos(angle) * outer, y: eye.y + sin(angle) * outer))
            ctx.setLineWidth(i % 3 == 0 ? 16 : 11)
            ctx.setLineCap(.round)
            ctx.setStrokeColor(i == 3 ? rgb(0xFFB547, 0.95) : white(i % 3 == 0 ? 0.30 : 0.16))
            ctx.strokePath()
        }
    }

    // Iris: amber, darker at the rim
    let irisRect = CGRect(x: eye.x - iris, y: eye.y - iris, width: iris * 2, height: iris * 2)
    ctx.saveGState()
    shadow(0, 70, rgb(0xFF9A3D, 0.45))
    ctx.addEllipse(in: irisRect)
    ctx.setFillColor(rgb(0xF2A33A))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: irisRect)
    ctx.clip()
    ctx.drawRadialGradient(gradient([(rgb(0xFFE08A), 0), (rgb(0xFFB547), 0.45), (rgb(0xE07A22), 0.85), (rgb(0x8A3A10), 1)]),
                           startCenter: CGPoint(x: eye.x + 20, y: eye.y + 10), startRadius: 0,
                           endCenter: eye, endRadius: iris, options: [])
    // Pupil, looking slightly forward
    let pupil: CGFloat = small ? 96 : 88
    ctx.addEllipse(in: CGRect(x: eye.x + 22 - pupil, y: eye.y - pupil, width: pupil * 2, height: pupil * 2))
    ctx.setFillColor(rgb(0x050608))
    ctx.fillPath()
    // Catchlight, in the app's cool accent
    ctx.addEllipse(in: CGRect(x: eye.x + 52, y: eye.y - 70, width: small ? 70 : 54, height: small ? 70 : 54))
    ctx.setFillColor(rgb(0xBFD8FF, 0.92))
    ctx.fillPath()
    ctx.restoreGState()

    // Brow: high at the back, swept down over the front of the eye, casting shade on it.
    let brow = CGMutablePath()
    let drop: CGFloat = small ? 24 : 0
    // Its lower edge cuts across the top of the iris, so the eye reads hooded and intent.
    brow.move(to: CGPoint(x: 196, y: 430))
    brow.addQuadCurve(to: CGPoint(x: 560, y: 330), control: CGPoint(x: 350, y: 340))
    brow.addQuadCurve(to: CGPoint(x: 858, y: 520 + drop), control: CGPoint(x: 770, y: 340))
    brow.addQuadCurve(to: CGPoint(x: 570, y: 455 + drop), control: CGPoint(x: 720, y: 440 + drop))
    brow.addQuadCurve(to: CGPoint(x: 196, y: 430), control: CGPoint(x: 360, y: 470 + drop))
    brow.closeSubpath()
    ctx.saveGState()
    shadow(18, 40, black(0.75))
    ctx.addPath(brow)
    ctx.setFillColor(rgb(0xD8DCE4))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(brow)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(rgb(0xF4F6FA), 0), (rgb(0xAEB4C0), 1)]),
                           start: CGPoint(x: 0, y: 330), end: CGPoint(x: 0, y: 520), options: [])
    ctx.restoreGState()
}

func render(_ pixels: Int, to url: URL) {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    draw(in: ctx, pixels: pixels)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <AppIcon.iconset>\n".data(using: .utf8)!)
    exit(2)
}
let dir = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
var count = 0
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        render(size * scale, to: dir.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
        count += 1
    }
}
print("wrote \(count) images to \(dir.path)")
