// Draws the app icon: the launch mark (seven arcs, one per lifecycle phase, around a "D")
// on a dark rounded square. Run from the repo root:
//   swift scripts/make_icon.swift && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit
import CoreText

let fonts = URL(fileURLWithPath: "Sources/DanteEditor/Resources/Fonts")
for name in (try? FileManager.default.contentsOfDirectory(atPath: fonts.path)) ?? [] where name.hasSuffix(".ttf") || name.hasSuffix(".otf") {
    CTFontManagerRegisterFontsForURL(fonts.appending(path: name) as CFURL, .process, nil)
}

func color(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func icon(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let cg = context.cgContext
    let s = CGFloat(size) / 1024
    cg.scaleBy(x: s, y: s)

    // Apple's grid: an 824pt rounded square centred in 1024, with a soft shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.35))
    cg.addPath(shape)
    cg.setFillColor(color(0x0F1216))
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(shape)
    cg.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x1A2030), color(0x0B0D10)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    cg.restoreGState()

    // The ring: a faint track, then seven arcs clockwise from the top, brightening as they go.
    let centre = CGPoint(x: 512, y: 512)
    let radius: CGFloat = 270
    let width: CGFloat = 44
    cg.setLineWidth(width)
    cg.setStrokeColor(color(0x171C22))
    cg.addArc(center: centre, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    cg.strokePath()
    cg.setLineCap(.round)
    let gap = (width + 26) / radius
    for index in 0..<7 {
        let step = CGFloat.pi * 2 / 7
        let start = CGFloat.pi / 2 - CGFloat(index) * step - gap / 2
        let end = CGFloat.pi / 2 - CGFloat(index + 1) * step + gap / 2
        cg.setStrokeColor(color(0x8FA8FF, 0.5 + CGFloat(index) * 0.083))
        cg.addArc(center: centre, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        cg.strokePath()
    }

    // The "D".
    let descriptor = NSFontDescriptor(fontAttributes: [.family: "Geist", .traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold]])
    let font = NSFont(descriptor: descriptor, size: 300) ?? NSFont.systemFont(ofSize: 300, weight: .semibold)
    let text = NSAttributedString(string: "D", attributes: [.font: font, .foregroundColor: NSColor(cgColor: color(0xE8ECF2))!])
    let line = CTLineCreateWithAttributedString(text)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    cg.textPosition = CGPoint(x: centre.x - bounds.midX, y: centre.y - bounds.midY)
    CTLineDraw(line, cg)
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
