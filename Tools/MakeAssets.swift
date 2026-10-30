import AppKit

/// Package the approved artwork into the standard macOS icon resolutions.
@main enum MakeAssets {
    static func uint32(_ value: UInt32) -> Data { var v = value.bigEndian; return Data(bytes: &v, count: 4) }
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Usage: MakeAssets <resources-directory>") }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let source = NSImage(contentsOf: directory.appendingPathComponent("AppIcon-source.png")) else { fatalError("Missing app icon artwork") }
        var chunks = Data()
        let entries: [(String, Int)] = [("icp4",16),("icp5",32),("icp6",64),("ic07",128),("ic08",256),("ic09",512),("ic10",1024)]
        for (tag, size) in entries {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            let cg = NSGraphicsContext.current!.cgContext
            let side = CGFloat(size)
            // A deterministic icon mask keeps the perimeter clean at every size.
            let mask = CGPath(roundedRect: CGRect(x: side * 0.065, y: side * 0.065, width: side * 0.87, height: side * 0.87), cornerWidth: side * 0.19, cornerHeight: side * 0.19, transform: nil)
            cg.addPath(mask); cg.clip()
            NSColor(white: 0.94, alpha: 1).setFill()
            CGRect(x: 0, y: 0, width: side, height: side).fill()
            NSGraphicsContext.current!.imageInterpolation = .high
            source.draw(in: CGRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            let data = bitmap.representation(using: .png, properties: [:])!
            chunks.append(tag.data(using: .ascii)!); chunks.append(uint32(UInt32(data.count + 8))); chunks.append(data)
        }
        var icon = Data("icns".utf8); icon.append(uint32(UInt32(chunks.count + 8))); icon.append(chunks)
        try icon.write(to: directory.appendingPathComponent("AppIcon.icns"))
    }
}
