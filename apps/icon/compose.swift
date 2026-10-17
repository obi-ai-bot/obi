// Builds Oby's icons from a render of Sangam's character (apps/icon/render.mjs makes it).
// Usage: swift apps/icon/compose.swift <render.png> <icon folder>
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fatalError("usage: compose.swift <render.png> <Icon folder>") }
let icon = URL(filePath: arguments[2])

guard let source = CGImageSourceCreateWithURL(URL(filePath: arguments[1]) as CFURL, nil),
      let render = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("can't read the render") }

/// Where Oby is in the render: the box around every pixel that isn't transparent.
func body(of image: CGImage) -> CGRect {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var minX = width, minY = height, maxX = 0, maxY = 0
    for y in 0..<height {
        for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    // Rows in the buffer run top to bottom, like the image coordinates `cropping(to:)` takes.
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

let oby = render.cropping(to: body(of: render))!
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!

/// A square canvas with Oby `fraction` of its width wide, a little above center (the optical
/// center); no Oby when `fraction` is nil.
func canvas(_ size: Int, fraction: CGFloat?, background: ((CGContext, CGFloat) -> Void)? = nil) -> CGImage {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: p3,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let side = CGFloat(size)
    background?(context, side)
    guard let fraction else { return context.makeImage()! }
    context.interpolationQuality = .high
    let width = side * fraction
    let height = width * CGFloat(oby.height) / CGFloat(oby.width)
    context.draw(oby, in: CGRect(x: (side - width) / 2, y: (side - height) / 2 + side * 0.015, width: width, height: height))
    return context.makeImage()!
}

/// Oby's dark: Oby's black, lifted a little at the top so it reads as a surface.
func night(_ context: CGContext, _ side: CGFloat, corner: CGFloat = 0) {
    if corner > 0 {
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side), cornerWidth: corner, cornerHeight: corner, transform: nil))
        context.clip()
    }
    let colors = [CGColor(colorSpace: p3, components: [0.172, 0.176, 0.192, 1])!, CGColor(colorSpace: p3, components: [0.055, 0.055, 0.063, 1])!]
    let gradient = CGGradient(colorsSpace: p3, colors: colors as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: side), end: CGPoint(x: 0, y: 0), options: [])
}

func write(_ image: CGImage, _ path: String, size: Int? = nil) {
    let url = icon.appending(path: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var out = image
    if let size, size != image.width {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: p3,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        out = context.makeImage()!
    }
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, out, nil)
    CGImageDestinationFinalize(destination)
}

// Apple: one Icon Composer document for iPhone, iPad, Mac and Apple Watch. The system draws the
// shape, Liquid Glass, and the dark, tinted and clear looks from Oby on its own layer.
write(canvas(1024, fraction: 0.6), "AppIcon.icon/Assets/oby.png")

// Everywhere else, from one 1024 master: full-bleed square, rounded square, and Android's layers.
let square = canvas(1024, fraction: 0.6) { night($0, $1) }
let rounded = canvas(1024, fraction: 0.56) { night($0, $1, corner: $1 * 0.225) }
write(square, "exports/oby-1024.png")
write(canvas(1024, fraction: 0.6), "exports/oby-foreground-1024.png")

// Android and Wear OS adaptive icons: 108 dp layers at xxxhdpi (432 px); Oby stays inside the
// 66 dp safe circle that every mask keeps.
write(canvas(432, fraction: 0.46), "exports/android/ic_launcher_foreground.png")
write(canvas(432, fraction: nil) { night($0, $1) }, "exports/android/ic_launcher_background.png")
write(square, "exports/android/play-store-512.png", size: 512)

// Windows and Linux: the rounded square, at the sizes each one asks for.
for size in [16, 24, 32, 48, 64, 128, 256, 512] { write(rounded, "exports/desktop/oby-\(size).png", size: size) }
// .ico: a header, one directory entry per size, then each size as a PNG (Windows reads PNG entries).
func png(_ image: CGImage, size: Int) -> Data {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}
let sizes = [16, 24, 32, 48, 64, 128, 256]
let images = sizes.map { png(rounded, size: $0) }
var ico = Data([0, 0, 1, 0, UInt8(sizes.count), 0])
var offset = 6 + 16 * sizes.count
for (size, image) in zip(sizes, images) {
    let side = UInt8(size == 256 ? 0 : size)  // 0 means 256
    ico += [side, side, 0, 0, 1, 0, 32, 0]
    ico += withUnsafeBytes(of: UInt32(image.count).littleEndian) { Data($0) }
    ico += withUnsafeBytes(of: UInt32(offset).littleEndian) { Data($0) }
    offset += image.count
}
images.forEach { ico += $0 }
try! ico.write(to: icon.appending(path: "exports/desktop/oby.ico"))

// The web: favicons and the home-screen icon (iOS rounds that one itself).
write(rounded, "exports/web/favicon-32.png", size: 32)
write(rounded, "exports/web/icon-192.png", size: 192)
write(rounded, "exports/web/icon-512.png", size: 512)
write(square, "exports/web/apple-touch-icon.png", size: 180)
print("Oby is \(oby.width)×\(oby.height) in the render; icons written to \(icon.path)")
