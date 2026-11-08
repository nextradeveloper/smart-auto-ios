import Accelerate
import CoreGraphics
import Foundation
import MiniH264

/// Turns pictures drawn by this app into H.264 the 368G plays, without the hardware encoder.
///
/// iOS takes VideoToolbox away from an app in the background or behind the lock screen, which is
/// exactly when the dash screen has to keep going. Everything here runs on the CPU: Accelerate
/// converts the drawn XRGB picture to I420, and minih264e (Vendor/minih264) encodes Baseline
/// level 3.1, the format the official ZONTES app sends this dash.
final class SoftwareVideoEncoder {
    let width: Int
    let height: Int

    private let encoder: OpaquePointer
    private var conversion = vImage_ARGBToYpCbCr()
    private var lumaPlane: [UInt8]
    private var cbPlane: [UInt8]
    private var crPlane: [UInt8]

    /// width and height must be multiples of 16.
    init?(width: Int, height: Int, bitRate: Int, frameRate: Int) {
        guard width % 16 == 0, height % 16 == 0,
              let encoder = softh264_create(Int32(width), Int32(height), Int32(bitRate), Int32(frameRate))
        else { return nil }
        self.width = width
        self.height = height
        self.encoder = encoder
        lumaPlane = [UInt8](repeating: 0, count: width * height)
        cbPlane = [UInt8](repeating: 128, count: width * height / 4)
        crPlane = [UInt8](repeating: 128, count: width * height / 4)

        // Video range BT.601: an SPS without colour information means exactly this to a decoder.
        var range = vImage_YpCbCrPixelRange(
            Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
            YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16
        )
        let status = vImageConvert_ARGBToYpCbCr_GenerateConversion(
            kvImage_ARGBToYpCbCrMatrix_ITU_R_601_4, &range, &conversion,
            kvImageARGB8888, kvImage420Yp8_Cb8_Cr8, vImage_Flags(kvImageNoFlags)
        )
        // Every property is set, so deinit frees the encoder.
        if status != kvImageNoError { return nil }
    }

    deinit {
        softh264_destroy(encoder)
    }

    /// The bitmap context to draw a frame in: XRGB, top row first in memory.
    func makeContext() -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )
    }

    /// Encodes what was drawn in `context` (from makeContext). Returns one Annex-B access unit with
    /// the NAL headers the dash expects, or nil on failure.
    func encode(_ context: CGContext, keyFrame: Bool) -> Data? {
        guard let pixels = context.data else { return nil }
        var source = vImage_Buffer(
            data: pixels, height: vImagePixelCount(height), width: vImagePixelCount(width),
            rowBytes: context.bytesPerRow
        )
        let chromaWidth = width / 2
        let chromaHeight = height / 2
        let converted: vImage_Error = lumaPlane.withUnsafeMutableBytes { luma in
            cbPlane.withUnsafeMutableBytes { cb in
                crPlane.withUnsafeMutableBytes { cr in
                    var yBuffer = vImage_Buffer(data: luma.baseAddress, height: vImagePixelCount(height),
                                                width: vImagePixelCount(width), rowBytes: width)
                    var cbBuffer = vImage_Buffer(data: cb.baseAddress, height: vImagePixelCount(chromaHeight),
                                                 width: vImagePixelCount(chromaWidth), rowBytes: chromaWidth)
                    var crBuffer = vImage_Buffer(data: cr.baseAddress, height: vImagePixelCount(chromaHeight),
                                                 width: vImagePixelCount(chromaWidth), rowBytes: chromaWidth)
                    // The context stores X, R, G, B: already the ARGB order the conversion reads.
                    let order: [UInt8] = [0, 1, 2, 3]
                    return vImageConvert_ARGB8888To420Yp8_Cb8_Cr8(
                        &source, &yBuffer, &cbBuffer, &crBuffer, &conversion, order,
                        vImage_Flags(kvImageNoFlags)
                    )
                }
            }
        }
        guard converted == kvImageNoError else { return nil }

        var output: UnsafePointer<UInt8>?
        var size: Int32 = 0
        let status = lumaPlane.withUnsafeBufferPointer { luma in
            cbPlane.withUnsafeBufferPointer { cb in
                crPlane.withUnsafeBufferPointer { cr in
                    softh264_encode(
                        encoder,
                        luma.baseAddress, Int32(width),
                        cb.baseAddress, cr.baseAddress, Int32(chromaWidth),
                        keyFrame ? 1 : 0, &output, &size
                    )
                }
            }
        }
        guard status == 0, let output, size > 0 else { return nil }
        return H264NAL.normalized(annexB: Data(bytes: output, count: Int(size)))
    }
}
