import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main struct FrameScreenshot {
    static func main() throws {
        guard CommandLine.arguments.count == 3,
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else {
            throw NSError(domain: "FrameScreenshot", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Usage: frame-screenshot input.png output.png (RGB PNG)"])
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: bounds)
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        // Infer the existing rounded corner; preserve the screenshot's color space.
        let radius = (0..<image.width / 2).first { pixels[$0 * 4 + 3] > 127 } ?? 0
        let dark = pixels[(image.width / 2) * 4] < 128
        let components: [CGFloat] = dark ? [0.29, 0.33, 0.38, 1] : [0.76, 0.79, 0.82, 1]
        context.setStrokeColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: components)!)
        // Source-atop keeps transparent corners and does not expand the image.
        context.setBlendMode(.sourceAtop)
        context.setLineWidth(2)
        context.addPath(CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                               cornerWidth: CGFloat(max(0, radius - 1)), cornerHeight: CGFloat(max(0, radius - 1)), transform: nil))
        context.strokePath()
        guard let framed = context.makeImage(),
              let output = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL,
                                                          UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "FrameScreenshot", code: 2)
        }
        CGImageDestinationAddImage(output, framed, nil)
        guard CGImageDestinationFinalize(output) else { throw NSError(domain: "FrameScreenshot", code: 3) }
    }
}
