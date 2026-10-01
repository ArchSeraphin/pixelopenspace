import CoreGraphics
import Foundation
import PixelCore

extension PixelImage {
    /// The image as an sRGB `CGImage`, straight alpha, one pixel per texel (rows top to bottom); nil when the image is
    /// empty. Draw it without interpolation (`Image(...).interpolation(.none)`) so that the texels stay sharp.
    func cgImage() -> CGImage? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeBufferPointer { source in
            bytes.withUnsafeMutableBufferPointer { out in
                for index in 0..<source.count {
                    let pixel = source[index]
                    out[4 * index] = pixel.r
                    out[4 * index + 1] = pixel.g
                    out[4 * index + 2] = pixel.b
                    out[4 * index + 3] = pixel.a
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
