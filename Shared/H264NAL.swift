import Foundation

/// NAL header bytes as the 368G's EasyConn stack expects them.
///
/// The official ZONTES app's EasyConn SDK finds the SPS by the literal byte 0x67
/// (`net/easyconn/carman/utils/HardCodecUtil.java`), the header MediaCodec writes. VideoToolbox
/// writes the same NAL types with nal_ref_idc 1 instead: 0x27 SPS, 0x28 PPS, 0x25 IDR, 0x21
/// slice. A decoder only cares whether nal_ref_idc is zero, so rewriting it is safe.
enum H264NAL {
    /// The header byte to send, or nil to leave the NAL out (SEI and access unit delimiters,
    /// which the official app never sends).
    static func normalizedHeader(_ header: UInt8) -> UInt8? {
        let type = header & 0x1F
        let referenced = header & 0x60 != 0
        switch type {
        case 7: return 0x67
        case 8: return 0x68
        case 5: return 0x65
        case 1: return referenced ? 0x41 : 0x01
        case 6, 9: return nil
        default: return header
        }
    }

    /// Appends one NAL (header byte first, no start code) as Annex-B with its header normalized.
    static func appendAnnexB(_ nal: Data, to accessUnit: inout Data) {
        guard let first = nal.first, let header = normalizedHeader(first) else { return }
        accessUnit.append(contentsOf: [0, 0, 0, 1])
        accessUnit.append(header)
        accessUnit.append(nal.dropFirst())
    }

    /// The header byte of every NAL in an Annex-B access unit, for the log.
    static func headers(inAnnexB data: Data) -> [UInt8] {
        let bytes = [UInt8](data)
        var headers: [UInt8] = []
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                headers.append(bytes[index + 3])
                index += 4
            } else {
                index += 1
            }
        }
        return headers
    }
}
