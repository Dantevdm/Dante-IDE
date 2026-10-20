// Draws the app icon: the Vine D. A stalk is the stem and a vine grows from its tip round into
// the bowl, leaves along it and fireflies inside, on a forest-green tile. The geometry and colours
// are a copy of `Logo` in DanteKit (drawn in the app by `DanteLogo`). Run from the repo root:
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

    // Apple's grid: an 824pt rounded square centred in 1024, with a soft shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: 12), blur: 30, color: color(0x000000, 0.4))
    cg.addPath(shape)
    cg.setFillColor(color(0x0B2016))
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(shape)
    cg.clip()
    cg.drawLinearGradient(gradient([(0, 0x16382A, 1), (0.55, 0x0B2016, 1), (1, 0x040D08, 1)]),
                          start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    radial(cg, [(0, 0xFFE08A, 0.22), (1, 0xFFE08A, 0)], at: CGPoint(x: 612, y: 347), radius: 536)
    cg.restoreGState()
    cg.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
    cg.setStrokeColor(color(0xCFF5A0, 0.12))
    cg.setLineWidth(3)
    cg.strokePath()

    // Sunlight in the bowl.
    radial(cg, [(0, 0xFFE9A8, 0.3), (0.4, 0xFFD66B, 0.09), (1, 0xFFD66B, 0)], at: CGPoint(x: 520, y: 500), radius: 300)

    func stroke(_ curves: [[CGFloat]], width: CGFloat, shade: (CGContext) -> Void) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: curves[0][0], y: curves[0][1]))
        for c in curves { path.addCurve(to: CGPoint(x: c[6], y: c[7]), control1: CGPoint(x: c[2], y: c[3]), control2: CGPoint(x: c[4], y: c[5])) }
        cg.saveGState()
        cg.addPath(path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10))
        cg.clip()
        shade(cg)
        cg.restoreGState()
    }
    // The stalk, the vine and its tendril.
    stroke([[330, 760, 326, 600, 334, 440, 330, 300]], width: 54) {
        $0.drawLinearGradient(gradient([(0, 0xD8F79A, 1), (0.5, 0x7CC456, 1), (1, 0x3A7F3E, 1)]), start: CGPoint(x: 0, y: 250), end: CGPoint(x: 0, y: 810), options: [])
    }
    stroke([[330, 300, 560, 250, 720, 380, 700, 520], [700, 520, 682, 650, 540, 740, 382, 722]], width: 38) {
        $0.drawLinearGradient(gradient([(0, 0xC9F27E, 1), (0.6, 0x5FB24E, 1), (1, 0x2F7A40, 1)]), start: CGPoint(x: 330, y: 279), end: CGPoint(x: 706, y: 725), options: [])
    }
    stroke([[382, 722, 346, 716, 340, 684, 366, 672], [366, 672, 388, 662, 404, 684, 388, 696]], width: 12) {
        $0.setFillColor(color(0x7CC456))
        $0.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    }

    // Leaves: x, y, angle, length, light or dark.
    let leaves: [(CGFloat, CGFloat, CGFloat, CGFloat, Bool)] = [
        (488, 294, -49, 112, true), (609, 339, -25, 108, false), (609, 339, 93, 64, true), (683, 420, 5, 104, true),
        (700, 520, 40, 100, false), (700, 520, -202, 64, true), (665, 609, 67, 96, true), (594, 676, 90, 92, false),
        (594, 676, -152, 64, true), (496, 716, 110, 88, true), (330, 300, -118, 96, true),
    ]
    let leaf = CGMutablePath()
    leaf.move(to: .zero)
    leaf.addCurve(to: CGPoint(x: 120, y: 0), control1: CGPoint(x: 25, y: -30), control2: CGPoint(x: 85, y: -30))
    leaf.addCurve(to: .zero, control1: CGPoint(x: 85, y: 30), control2: CGPoint(x: 25, y: 30))
    for (x, y, angle, length, light) in leaves {
        cg.saveGState()
        cg.translateBy(x: x, y: y)
        cg.rotate(by: angle * .pi / 180)
        cg.scaleBy(x: length / 120, y: length / 120)
        cg.saveGState()
        cg.addPath(leaf)
        cg.clip()
        let stops: [(CGFloat, Int, CGFloat)] = light ? [(0, 0xE4FF9C, 1), (0.45, 0x8FD45A, 1), (1, 0x3C9A4A, 1)] : [(0, 0xB5EE7A, 1), (0.5, 0x5DB653, 1), (1, 0x2A7442, 1)]
        cg.drawLinearGradient(gradient(stops), start: CGPoint(x: 0, y: -22), end: CGPoint(x: 120, y: 22), options: [])
        cg.restoreGState()
        if size >= 64 {
            cg.move(to: CGPoint(x: 8, y: 0))
            cg.addLine(to: CGPoint(x: 110, y: 0))
            cg.setStrokeColor(color(0xE9FFD6, 0.55))
            cg.setLineWidth(5)
            cg.setLineCap(.round)
            cg.strokePath()
        }
        cg.restoreGState()
    }

    // Fireflies (from 64 px up).
    if size >= 64 {
        for (x, y, r) in [(520.0, 470.0, 26.0), (586, 560, 20), (478, 590, 16)] {
            cg.saveGState()
            cg.setAlpha(0.8)
            radial(cg, [(0, 0xFFF6C4, 1), (0.3, 0xFFE27A, 0.8), (1, 0xFFD24A, 0)], at: CGPoint(x: x, y: y), radius: r)
            cg.restoreGState()
        }
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
