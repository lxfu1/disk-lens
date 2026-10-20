import AppKit

@main struct GenerateIcon {
    static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            let mark = AppBrand.image
            for size in [16, 32, 128, 256, 512] {
                for scale in [1, 2] {
                    let pixels = size * scale
                    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                    let factor = CGFloat(pixels) / 1024
                    let transform = NSAffineTransform(); transform.scale(by: factor); transform.concat()
                    mark.draw(in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
                    NSGraphicsContext.restoreGraphicsState()
                    let suffix = scale == 2 ? "@2x" : ""
                    let url = folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
                    do { try bitmap.representation(using: .png, properties: [:])!.write(to: url) }
                    catch { fatalError("Could not write icon: \(error)") }
                }
            }
        }
    }
}
