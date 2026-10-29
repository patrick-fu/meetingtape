import CoreGraphics
import Foundation
import ImageIO

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources")
let sourceURL = resources.appendingPathComponent("Artwork/AppIcon-source.png")
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width == image.height,
      image.width >= 1024 else {
    fatalError("Expected a square AppIcon source of at least 1024 pixels")
}

func render(size: Int, legacy: Bool, to url: URL) throws {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: colorSpace,
                            bitmapInfo: (legacy ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
    context.interpolationQuality = .high
    let side = CGFloat(size)
    let inset = legacy ? side * 100 / 1024 : 0
    let rect = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    if legacy {
        let radius = side * 184 / 1024
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
    }
    context.draw(image, in: rect)
    let rendered = context.makeImage()!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, rendered, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(url.path)") }
}

let iconset = root.appendingPathComponent(".build/icon/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try render(size: 1024, legacy: false, to: resources.appendingPathComponent("AppIcon.png"))
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try render(size: size * scale, legacy: true,
                   to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
let generated = iconset.deletingLastPathComponent().appendingPathComponent("AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", "-o", generated.path, iconset.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
try Data(contentsOf: generated).write(to: resources.appendingPathComponent("AppIcon.icns"), options: .atomic)
print("Wrote AppIcon.png and AppIcon.icns")
