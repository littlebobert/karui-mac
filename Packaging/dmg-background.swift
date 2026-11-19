// Draws the disk image window's background: Karui → Applications, with the labels'
// pills and the install line. The bottom 30 pt stay empty: Finder's status bar
// covers them when the person has it turned on. Run by Scripts/make-dmg.sh; the layout points here must
// match Packaging/dmg-settings.py.
//
//   swift Packaging/dmg-background.swift <output-1x.png> <output-2x.png>

import AppKit
import CoreText

let width: CGFloat = 640
let height: CGFloat = 400
// Icon centres, in Finder's top-left coordinates (as in dmg-settings.py).
let appCentre = CGPoint(x: 170, y: 165)
let applicationsCentre = CGPoint(x: 470, y: 165)
let iconSize: CGFloat = 128
// Finder draws each file name 83 pt below its icon's centre (13 pt labels).
let labelCentreY: CGFloat = 248

let paper = NSColor(srgbRed: 0xF4 / 255, green: 0xF1 / 255, blue: 0xEA / 255, alpha: 1)
let ink = NSColor(srgbRed: 0x1A / 255, green: 0x21 / 255, blue: 0x1E / 255, alpha: 1)
let muted = NSColor(srgbRed: 0x66 / 255, green: 0x6B / 255, blue: 0x62 / 255, alpha: 1)
let moss = NSColor(srgbRed: 0x38 / 255, green: 0x5F / 255, blue: 0x49 / 255, alpha: 1)
let pill = NSColor(srgbRed: 0xDC / 255, green: 0xE5 / 255, blue: 0xDB / 255, alpha: 1)

func render(scale: CGFloat, to path: String) throws {
    let pixelsWide = Int(width * scale), pixelsHigh = Int(height * scale)
    guard let context = CGContext(
        data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw CocoaError(.fileWriteUnknown) }
    // Draw in Finder's coordinates: origin top left, y down.
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: 0, y: height)
    context.scaleBy(x: 1, y: -1)

    context.setFillColor(paper.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // A soft moss glow behind Applications, where the app is headed.
    let glow = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [moss.withAlphaComponent(0.07).cgColor, moss.withAlphaComponent(0).cgColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(
        glow, startCenter: applicationsCentre, startRadius: 0,
        endCenter: applicationsCentre, endRadius: 230, options: []
    )

    // The arrow: a rounded shaft and a solid head, between the two icons.
    let shaftStart = appCentre.x + iconSize / 2 + 26
    let headTip = applicationsCentre.x - iconSize / 2 - 22
    let headLength: CGFloat = 26, headHalfHeight: CGFloat = 20, shaft: CGFloat = 10
    context.setFillColor(moss.cgColor)
    context.addPath(CGPath(
        roundedRect: CGRect(x: shaftStart, y: appCentre.y - shaft / 2,
                            width: headTip - headLength - shaftStart + 4, height: shaft),
        cornerWidth: shaft / 2, cornerHeight: shaft / 2, transform: nil
    ))
    context.fillPath()
    let head = CGMutablePath()
    head.move(to: CGPoint(x: headTip, y: appCentre.y))
    head.addLine(to: CGPoint(x: headTip - headLength, y: appCentre.y - headHalfHeight))
    head.addLine(to: CGPoint(x: headTip - headLength, y: appCentre.y + headHalfHeight))
    head.closeSubpath()
    context.addPath(head)
    context.setLineJoin(.round)
    context.setLineWidth(4)
    context.setStrokeColor(moss.cgColor)
    context.drawPath(using: .fillStroke)

    // Pills behind Finder's labels. Finder hides the .app extension, so it shows "Karui".
    // They're sized for 16 pt, the largest label Finder's View Options offer, so a
    // window someone has set to larger text still keeps its labels inside them.
    for (centre, label) in [(appCentre, "Karui"), (applicationsCentre, "Applications")] {
        let textWidth = measure(label, font: .systemFont(ofSize: 16))
        let rect = CGRect(x: centre.x - textWidth / 2 - 14, y: labelCentreY - 15,
                          width: textWidth + 28, height: 30)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 15, cornerHeight: 15, transform: nil))
        context.setFillColor(pill.cgColor)
        context.fillPath()
    }

    draw("Drag Karui to Applications to install it",
         font: .systemFont(ofSize: 17, weight: .medium), colour: ink, centreY: 316, in: context)
    draw("KaruiをApplicationsにドラッグしてインストール",
         font: .systemFont(ofSize: 13), colour: muted, centreY: 341, in: context)

    guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    let bitmap = NSBitmapImageRep(cgImage: image)
    bitmap.size = NSSize(width: width, height: height)
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func attributed(_ text: String, font: NSFont, colour: NSColor = .black) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: colour])
}

func measure(_ text: String, font: NSFont) -> CGFloat {
    CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed(text, font: font)), nil, nil, nil)
}

func draw(_ text: String, font: NSFont, colour: NSColor, centreY: CGFloat, in context: CGContext) {
    let line = CTLineCreateWithAttributedString(attributed(text, font: font, colour: colour))
    var ascent: CGFloat = 0, descent: CGFloat = 0
    let lineWidth = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
    context.saveGState()
    // Core Text draws upright in y-up space; flip back around the baseline.
    let baseline = centreY + (ascent - descent) / 2
    context.translateBy(x: (width - lineWidth) / 2, y: baseline)
    context.scaleBy(x: 1, y: -1)
    context.textPosition = .zero
    CTLineDraw(line, context)
    context.restoreGState()
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: dmg-background.swift <1x.png> <2x.png>\n".utf8))
    exit(1)
}
try render(scale: 1, to: arguments[1])
try render(scale: 2, to: arguments[2])
