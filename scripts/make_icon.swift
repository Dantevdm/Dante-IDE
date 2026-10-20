// Draws the app icon: the Obelisk D. An obelisk with its gilded tip is the stem and a gold
// ring is the bowl, 36 decan marks inside it and Orion's belt in the middle, on lapis. The
// geometry matches `DanteLogo` in the app and the design canvas's Logo board. Run from the repo root:
//   swift scripts/make_icon.swift && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

func color(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ stops: [(CGFloat, Int, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map { color($0.1, $0.2) } as CFArray, locations: stops.map(\.0))!
}

func radial(_ cg: CGContext, _ stops: [(CGFloat, Int, CGFloat)], at centre: CGPoint, radius: CGFloat) {
    cg.drawRadialGradient(gradient(stops), startCenter: centre, startRadius: 0, endCenter: centre, endRadius: radius, options: [])
}

func icon(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let s = CGFloat(size) / 1024
    // Work top-down in a 1024 grid, like the SVG on the canvas.
    cg.translateBy(x: 0, y: CGFloat(size))
    cg.scaleBy(x: s, y: -s)

    let ring = CGPoint(x: 523, y: 512)
    let gold = gradient([(0, 0xFFF0C2, 1), (0.32, 0xF5C96A, 1), (0.68, 0xD39A3C, 1), (1, 0x9A6220, 1)])

    // Apple's grid: an 824pt rounded square centred in 1024, with a soft shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: 12), blur: 30, color: color(0x000000, 0.4))
    cg.addPath(shape)
    cg.setFillColor(color(0x0B1738))
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(shape)
    cg.clip()
    cg.drawLinearGradient(gradient([(0, 0x15295F, 1), (0.55, 0x0B1738, 1), (1, 0x050A1A, 1)]),
                          start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    radial(cg, [(0, 0xF2B544, 0.2), (1, 0xF2B544, 0)], at: CGPoint(x: 528, y: 463), radius: 478)
    cg.restoreGState()
    cg.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
    cg.setStrokeColor(color(0xF5C96A, 0.14))
    cg.setLineWidth(3)
    cg.strokePath()

    // The warm light the ring sits in.
    radial(cg, [(0, 0xFFD27A, 0.4), (0.45, 0xE9A23B, 0.14), (1, 0xE9A23B, 0)], at: ring, radius: 320)

    // The decans: 36 marks turning inside the ring (still in the icon, so only from 64 px up).
    if size >= 64 {
        cg.setStrokeColor(color(0xF5C96A, 0.5))
        cg.setLineWidth(5)
        for index in 0..<36 {
            let angle = CGFloat(index) / 36 * 2 * .pi
            cg.move(to: CGPoint(x: ring.x + 178 * cos(angle), y: ring.y + 178 * sin(angle)))
            cg.addLine(to: CGPoint(x: ring.x + 198 * cos(angle), y: ring.y + 198 * sin(angle)))
        }
        cg.strokePath()
    }

    // The ring, gold from its top left to its bottom right.
    let circle = CGPath(ellipseIn: CGRect(x: ring.x - 238, y: ring.y - 238, width: 476, height: 476), transform: nil)
    cg.saveGState()
    cg.addPath(circle.copy(strokingWithWidth: 46, lineCap: .butt, lineJoin: .round, miterLimit: 10))
    cg.clip()
    cg.drawLinearGradient(gold, start: CGPoint(x: ring.x - 261, y: ring.y - 261), end: CGPoint(x: ring.x + 261, y: ring.y + 261), options: [])
    cg.restoreGState()

    // The glint that runs round it while agents work, caught at the lower right.
    let glint = CGMutablePath()
    glint.addArc(center: ring, radius: 238, startAngle: 0.7, endAngle: 0.95, clockwise: false)
    cg.saveGState()
    cg.setShadow(offset: .zero, blur: 24 * s, color: color(0xFFE7A8, 0.9))
    cg.addPath(glint)
    cg.setStrokeColor(color(0xFFF7DE, 0.9))
    cg.setLineWidth(30)
    cg.setLineCap(.round)
    cg.strokePath()
    cg.restoreGState()

    // Orion's belt.
    if size >= 64 {
        cg.setFillColor(color(0xE9FBFF))
        for (x, y, r) in [(483.0, 566.0, 11.0), (521, 524, 9), (563, 484, 11)] {
            cg.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
    }

    // The obelisk: a lit face and a shaded one, its gilded tip glowing.
    radial(cg, [(0, 0xFFD27A, 0.9), (0.45, 0xE9A23B, 0.3), (1, 0xE9A23B, 0)], at: CGPoint(x: 285, y: 262), radius: 80)
    func face(_ points: [CGPoint], _ fill: (CGContext) -> Void) {
        cg.saveGState()
        cg.addLines(between: points)
        cg.closePath()
        cg.clip()
        fill(cg)
        cg.restoreGState()
    }
    let top = CGPoint(x: 285, y: 262), bottom = CGPoint(x: 285, y: 760)
    face([CGPoint(x: 237, y: 760), CGPoint(x: 285, y: 760), CGPoint(x: 285, y: 334), CGPoint(x: 251, y: 334)]) {
        $0.drawLinearGradient(gold, start: top, end: bottom, options: [])
    }
    face([CGPoint(x: 285, y: 760), CGPoint(x: 333, y: 760), CGPoint(x: 319, y: 334), CGPoint(x: 285, y: 334)]) {
        $0.drawLinearGradient(gradient([(0, 0xE2AA4E, 1), (0.5, 0xB27A2C, 1), (1, 0x6E4514, 1)]), start: top, end: bottom, options: [])
    }
    face([CGPoint(x: 251, y: 334), CGPoint(x: 285, y: 334), top]) { $0.setFillColor(color(0xFFF4D6)); $0.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024)) }
    face([CGPoint(x: 285, y: 334), CGPoint(x: 319, y: 334), top]) { $0.setFillColor(color(0xF2C46B)); $0.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024)) }
    if size >= 64 {
        cg.setFillColor(color(0x7A4A15, 0.45))
        for (y, h) in [(392.0, 26.0), (452, 12), (498, 40), (572, 18), (624, 30)] {
            cg.addPath(CGPath(roundedRect: CGRect(x: 262, y: y, width: 12, height: h), cornerWidth: 3, cornerHeight: 3, transform: nil))
        }
        cg.fillPath()
    }
    return rep
}

let folder = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: folder)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try icon(size: base * scale).representation(using: .png, properties: [:])!.write(to: folder.appending(path: name))
    }
}
try icon(size: 1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/AppIcon.png"))
print("Wrote \(folder.path)")
