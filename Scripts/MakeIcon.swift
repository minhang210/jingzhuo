import AppKit

// Explicit sRGB buffers avoid display-dependent rasterization.
// The mark matches the in-app rectangle.compress.vertical symbol.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func icon(_ pixels: Int) throws -> Data {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: pixels * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "Icon", code: 1)
    }
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let shape = NSBezierPath(roundedRect: NSRect(x: 78, y: 78, width: 868, height: 868), xRadius: 230, yRadius: 230)
    NSGradient(starting: NSColor(srgbRed: 0.13, green: 0.38, blue: 0.31, alpha: 1),
               ending: NSColor(srgbRed: 0.35, green: 0.58, blue: 0.53, alpha: 1))!.draw(in: shape, angle: 90)

    guard let symbol = NSImage(systemSymbolName: "rectangle.compress.vertical", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 500, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))) else {
        throw NSError(domain: "Icon", code: 2)
    }
    let bounds = NSRect(x: 252, y: 244, width: 520, height: 536)
    let scale = min(bounds.width / symbol.size.width, bounds.height / symbol.size.height)
    let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
    symbol.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
    guard let image = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw NSError(domain: "Icon", code: 3)
    }
    return png
}

for size in [16, 32, 128, 256, 512] {
    try icon(size).write(to: destination.appendingPathComponent("icon_\(size)x\(size).png"))
    try icon(size * 2).write(to: destination.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

if CommandLine.arguments.count > 2 {
    func bigEndian(_ number: Int) -> Data {
        var value = UInt32(number).bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
    // Standard modern PNG representations, including Retina variants.
    // Do not put PNG data in the older icp4/icp5 slots.
    let representations = [("ic07",128), ("ic08",256), ("ic09",512), ("ic10",1024),
                           ("ic11",32), ("ic12",64), ("ic13",256), ("ic14",512)]
    let entries = try representations.map { (type: $0.0, png: try icon($0.1)) }
    var toc = Data()
    var payload = Data()
    for entry in entries {
        let type = entry.type.data(using: .ascii)!
        let length = bigEndian(entry.png.count + 8)
        toc.append(type); toc.append(length)
        payload.append(type); payload.append(length); payload.append(entry.png)
    }
    var file = "icns".data(using: .ascii)!
    file.append(bigEndian(8 + 8 + toc.count + payload.count))
    file.append("TOC ".data(using: .ascii)!)
    file.append(bigEndian(8 + toc.count)); file.append(toc); file.append(payload)
    try file.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
