import Foundation

extension PixelImage {
    /// The image as a PNG file (8-bit RGBA, fixed-Huffman deflate): the same pixels give the same bytes on every
    /// platform. `pixelsPerMeter` adds a pHYs chunk (`PNGOptions.dpi144` for the overview). Precondition: at least
    /// 1×1.
    public func pngData(pixelsPerMeter: Int? = nil) -> [UInt8] {
        PNGEncoder.encode(width: width, height: height, rgba: rgbaBytes,
                          options: PNGOptions(mode: .fixedHuffman, pixelsPerMeter: pixelsPerMeter))
    }
}
