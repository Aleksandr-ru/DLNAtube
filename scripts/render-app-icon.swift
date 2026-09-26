import AppKit
import Foundation

// The icon is drawn as vector paths before being rasterized for the macOS iconset.
let canvasSize = 1024
let designSize: CGFloat = 480
let outputURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/DlnaTube-1024.png")

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: canvasSize,
    pixelsHigh: canvasSize,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Cannot create icon bitmap")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
let context = graphics.cgContext
context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)
context.scaleBy(x: CGFloat(canvasSize) / designSize, y: CGFloat(canvasSize) / designSize)
context.translateBy(x: 0, y: designSize)
context.scaleBy(x: 1, y: -1)

// Finder's tile occupies about 81% of its canvas, with transparent space around it.
let tileScale: CGFloat = 0.81
context.translateBy(x: designSize / 2, y: designSize / 2)
context.scaleBy(x: tileScale, y: tileScale)
context.translateBy(x: -designSize / 2, y: -designSize / 2)

let white = CGColor(gray: 1, alpha: 1)
let red = CGColor(red: 1, green: 0, blue: 0.2, alpha: 1)
let background = CGPath(
    roundedRect: CGRect(x: 0, y: 0, width: designSize, height: designSize),
    cornerWidth: 78,
    cornerHeight: 78,
    transform: nil
)
context.addPath(background)
context.setFillColor(red)
context.fillPath()

// Inset the white mark slightly from the red tile.
context.saveGState()
let contentScale: CGFloat = 0.9
context.translateBy(x: designSize / 2, y: designSize / 2)
context.scaleBy(x: contentScale, y: contentScale)
context.translateBy(x: -designSize / 2, y: -designSize / 2)

context.setStrokeColor(white)
context.setLineWidth(32)
context.setLineJoin(.round)
context.setLineCap(.butt)

// Open TV outline. Its lower-left corner leaves room for the broadcast arcs.
let screen = CGMutablePath()
screen.move(to: CGPoint(x: 77, y: 165))
screen.addLine(to: CGPoint(x: 77, y: 121))
screen.addQuadCurve(to: CGPoint(x: 99, y: 99), control: CGPoint(x: 77, y: 99))
screen.addLine(to: CGPoint(x: 381, y: 99))
screen.addQuadCurve(to: CGPoint(x: 403, y: 121), control: CGPoint(x: 403, y: 99))
screen.addLine(to: CGPoint(x: 403, y: 339))
screen.addQuadCurve(to: CGPoint(x: 381, y: 361), control: CGPoint(x: 403, y: 361))
screen.addLine(to: CGPoint(x: 273, y: 361))
context.addPath(screen)
context.strokePath()

// Quarter-circle broadcast waves, aligned with the source icon's lower-left corner.
let bezierQuarter: CGFloat = 0.5522847498
for radius: CGFloat in [49, 114, 180] {
    let wave = CGMutablePath()
    wave.move(to: CGPoint(x: 61, y: 377 - radius))
    wave.addCurve(
        to: CGPoint(x: 61 + radius, y: 377),
        control1: CGPoint(x: 61 + bezierQuarter * radius, y: 377 - radius),
        control2: CGPoint(x: 61 + radius, y: 377 - bezierQuarter * radius)
    )
    context.addPath(wave)
    context.strokePath()
}

// A softly rounded YouTube-style play symbol replaces the magnifying glass.
let play = CGMutablePath()
play.move(to: CGPoint(x: 238, y: 146))
play.addQuadCurve(to: CGPoint(x: 227, y: 153), control: CGPoint(x: 227, y: 145))
play.addLine(to: CGPoint(x: 227, y: 243))
play.addQuadCurve(to: CGPoint(x: 238, y: 250), control: CGPoint(x: 227, y: 251))
play.addLine(to: CGPoint(x: 334, y: 204))
play.addQuadCurve(to: CGPoint(x: 334, y: 192), control: CGPoint(x: 344, y: 198))
play.closeSubpath()
context.addPath(play)
context.setFillColor(white)
context.fillPath()
context.restoreGState()

graphics.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Cannot encode icon PNG")
}
try png.write(to: outputURL)
