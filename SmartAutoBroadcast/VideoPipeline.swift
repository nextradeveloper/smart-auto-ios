import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import ReplayKit
import VideoToolbox

/// Screen frames in, H.264 access units for the dash out.
///
/// ReplayKit hands over the screen in its native portrait buffer with an orientation tag; the
/// dash wants a landscape 1280x528 stream (the Zontes 368G area 1280x535, aligned down to 16 -
/// the size the Go library announces back to the dash, so the stream must match it exactly).
///
/// Mirrors the Android encoder settings for the 368G: Baseline 3.1, 30 fps, 2.5 Mbps x quality,
/// a plain IDR every second, no B-frames. ReplayKit only delivers a frame when the screen
/// changes, so the last picture is re-encoded every 100 ms (Android's
/// KEY_REPEAT_PREVIOUS_FRAME_AFTER): the Go live queue resets after 3 s without input and then
/// drops everything until the next IDR.
final class VideoPipeline {
    /// One Annex-B access unit (SPS and PPS in front of every IDR) and whether it is an IDR.
    var onAccessUnit: ((Data, Bool) -> Void)?
    var log: ((String) -> Void)?

    private let queue = DispatchQueue(label: "smartauto.video", qos: .userInteractive)
    private let lock = NSLock()

    // Guarded by `lock`: the newest screen frame, waiting for the next tick.
    private var pendingFrame: CVPixelBuffer?
    private var pendingOrientation: CGImagePropertyOrientation = .up

    // Owned by `queue`.
    private var width = 1280
    private var height = 528
    private var frameRate = 30
    private var bitRate = 2_500_000
    private var flip = false
    private var compression: VTCompressionSession?
    private var transfer: VTPixelTransferSession?
    private var rotation: VTPixelRotationSession?
    private var outputPool: CVPixelBufferPool?
    private var rotatedPool: CVPixelBufferPool?
    private var poolFormat: OSType = 0
    private var lastOutput: CVPixelBuffer?
    private var lastEncodeTime: CFTimeInterval = 0
    private var forceKeyFrame = true
    private var timer: DispatchSourceTimer?
    private var running = false

    // Guarded by `statsLock`: updated on VideoToolbox's output thread, read by the session.
    private let statsLock = NSLock()
    private var encodedFramesValue = 0
    private var fpsWindowStart: CFTimeInterval = CACurrentMediaTime()
    private var fpsWindowFrames = 0
    private var measuredFpsValue = 0

    var encodedFrames: Int {
        statsLock.lock(); defer { statsLock.unlock() }
        return encodedFramesValue
    }

    var measuredFps: Int {
        statsLock.lock(); defer { statsLock.unlock() }
        return measuredFpsValue
    }

    private let keepAliveInterval: CFTimeInterval = 0.1

    // MARK: Control

    func start(width: Int, height: Int, frameRate: Int, bitRate: Int, flip: Bool) {
        queue.async {
            self.width = width
            self.height = height
            self.frameRate = frameRate
            self.bitRate = bitRate
            self.flip = flip
            self.running = true
            self.rebuildEncoder()
            self.startTimer()
        }
    }

    /// The dash announced its area: re-create the encoder if the aligned size changed.
    func resize(width: Int, height: Int) {
        queue.async {
            guard width != self.width || height != self.height else { return }
            self.log?("Video size \(self.width)x\(self.height) -> \(width)x\(height)")
            self.width = width
            self.height = height
            self.outputPool = nil
            self.rotatedPool = nil
            self.lastOutput = nil
            self.rebuildEncoder()
        }
    }

    /// The dash (re)started pulling video: Go drops everything until an IDR arrives.
    func requestKeyFrame() {
        queue.async { self.forceKeyFrame = true }
    }

    func stop() {
        queue.sync {
            running = false
            timer?.cancel()
            timer = nil
            if let compression {
                VTCompressionSessionCompleteFrames(compression, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(compression)
            }
            compression = nil
            if let transfer { VTPixelTransferSessionInvalidate(transfer) }
            transfer = nil
            if let rotation { VTPixelRotationSessionInvalidate(rotation) }
            rotation = nil
            outputPool = nil
            rotatedPool = nil
            lastOutput = nil
        }
        lock.lock()
        pendingFrame = nil
        lock.unlock()
    }

    /// Called on ReplayKit's thread for every screen change. Cheap: keeps only the newest frame.
    func submit(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var orientation = CGImagePropertyOrientation.up
        if let raw = CMGetAttachment(
            sampleBuffer,
            key: RPVideoSampleOrientationKey as CFString,
            attachmentModeOut: nil
        ) as? NSNumber, let value = CGImagePropertyOrientation(rawValue: raw.uint32Value) {
            orientation = value
        }
        lock.lock()
        pendingFrame = pixelBuffer
        pendingOrientation = orientation
        lock.unlock()
    }

    /// Releases what can be rebuilt, when iOS warns about memory.
    func trimMemory() {
        queue.async {
            self.rotatedPool = nil
        }
    }

    // MARK: Tick

    private func startTimer() {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        let interval = 1.0 / Double(max(frameRate, 1))
        source.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    private func tick() {
        guard running else { return }
        lock.lock()
        let frame = pendingFrame
        let orientation = pendingOrientation
        pendingFrame = nil
        lock.unlock()

        let now = CACurrentMediaTime()
        if let frame {
            if let converted = convert(frame, orientation: orientation) {
                lastOutput = converted
                encode(converted, at: now)
            }
        } else if let lastOutput, now - lastEncodeTime >= keepAliveInterval {
            encode(lastOutput, at: now)
        }
    }

    // MARK: Conversion

    /// Clockwise quarter turns that make the buffer upright. ReplayKit tags a landscape screen
    /// as .left/.right; on the 368G (2026-11-08) .right needed a counter-clockwise turn, the
    /// opposite of the first guess, which showed landscape upside down. The setting still flips it.
    private func quarterTurns(for orientation: CGImagePropertyOrientation) -> Int {
        var turns: Int
        switch orientation {
        case .right, .rightMirrored: turns = 3
        case .left, .leftMirrored: turns = 1
        case .down, .downMirrored: turns = 2
        default: turns = 0
        }
        if flip { turns += 2 }
        return turns % 4
    }

    private func rotationKey(quarterTurns: Int) -> CFString {
        switch quarterTurns {
        case 1: return kVTRotation_CW90
        case 2: return kVTRotation_180
        default: return kVTRotation_CCW90
        }
    }

    private func convert(_ source: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> CVPixelBuffer? {
        let format = CVPixelBufferGetPixelFormatType(source)
        if format != poolFormat {
            poolFormat = format
            outputPool = nil
            rotatedPool = nil
        }
        if transfer == nil {
            var session: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
            if let session {
                VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
            }
            transfer = session
        }
        guard let transfer else { return nil }

        let turns = quarterTurns(for: orientation)
        let quarter = turns % 2 == 1

        guard let output = makeBuffer(pool: &outputPool, width: width, height: height, format: format) else {
            return nil
        }
        if turns == 0 {
            fillBlack(output)
            return VTPixelTransferSessionTransferImage(transfer, from: source, to: output) == noErr ? output : nil
        }

        // Scale first (cheaper on the smaller picture), in the rotated frame of reference, then turn.
        let scaledWidth = quarter ? height : width
        let scaledHeight = quarter ? width : height
        guard let scaled = makeBuffer(pool: &rotatedPool, width: scaledWidth, height: scaledHeight, format: format) else {
            return nil
        }
        fillBlack(scaled)
        guard VTPixelTransferSessionTransferImage(transfer, from: source, to: scaled) == noErr else { return nil }

        if rotation == nil {
            var session: VTPixelRotationSession?
            VTPixelRotationSessionCreate(nil, &session)
            rotation = session
        }
        guard let rotation else { return nil }
        VTSessionSetProperty(rotation, key: kVTPixelRotationPropertyKey_Rotation, value: rotationKey(quarterTurns: turns))
        return VTPixelRotationSessionRotateImage(rotation, scaled, output) == noErr ? output : nil
    }

    private func makeBuffer(pool: inout CVPixelBufferPool?, width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        if pool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    /// Letterboxing leaves the bars alone, and a recycled or fresh buffer holds anything
    /// (all-zero YUV is bright green). Paint it black first.
    private func fillBlack(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let videoRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        if CVPixelBufferIsPlanar(buffer) {
            for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
                guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
                let bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)
                memset(base, plane == 0 ? (videoRange ? 16 : 0) : 128, bytes)
            }
        } else if let base = CVPixelBufferGetBaseAddress(buffer) {
            // BGRA: zero is opaque-enough black for an encoder that ignores alpha.
            memset(base, 0, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        }
    }

    // MARK: Encoding

    private func rebuildEncoder() {
        if let compression {
            VTCompressionSessionInvalidate(compression)
        }
        compression = nil
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            log?("VTCompressionSessionCreate failed: \(status)")
            return
        }
        let keyInterval = max(frameRate, 1)
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: kCFBooleanTrue as Any,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Baseline_3_1,
            kVTCompressionPropertyKey_AllowFrameReordering: kCFBooleanFalse as Any,
            kVTCompressionPropertyKey_AverageBitRate: bitRate,
            kVTCompressionPropertyKey_DataRateLimits: [bitRate * 3 / 2 / 8, 1] as CFArray,
            kVTCompressionPropertyKey_ExpectedFrameRate: frameRate,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: keyInterval,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 1.0,
        ]
        for (key, value) in properties {
            let result = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            if result != noErr { log?("Encoder property \(key) refused: \(result)") }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        compression = session
        forceKeyFrame = true
        log?("H.264 encoder ready: \(width)x\(height) \(frameRate) fps \(bitRate / 1000) kbps, IDR every 1 s")
    }

    private func encode(_ buffer: CVPixelBuffer, at time: CFTimeInterval) {
        guard let compression else { return }
        lastEncodeTime = time
        var frameProperties: CFDictionary?
        if forceKeyFrame {
            forceKeyFrame = false
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        }
        let pts = CMTime(seconds: time, preferredTimescale: 1_000_000)
        let status = VTCompressionSessionEncodeFrame(
            compression,
            imageBuffer: buffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            self?.emit(sampleBuffer)
        }
        if status != noErr {
            log?("Encode failed: \(status); rebuilding the encoder")
            rebuildEncoder()
        }
    }

    private func emit(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        var isKeyFrame = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]], let first = attachments.first {
            isKeyFrame = !((first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        }

        var accessUnit = Data()
        if isKeyFrame, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
            )
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )
                guard status == noErr, let pointer else { continue }
                H264NAL.appendAnnexB(Data(bytes: pointer, count: size), to: &accessUnit)
            }
        }

        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        var avcc = Data(count: length)
        let copied = avcc.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard copied == noErr else { return }

        // AVCC (4-byte big-endian lengths) to Annex-B, with the headers the dash looks for and
        // without SEI or AUD NALs, like the official app's MediaCodec output.
        var offset = 0
        while offset + 4 <= avcc.count {
            let nalLength = Int(avcc[offset]) << 24 | Int(avcc[offset + 1]) << 16
                | Int(avcc[offset + 2]) << 8 | Int(avcc[offset + 3])
            offset += 4
            guard nalLength > 0, offset + nalLength <= avcc.count else { break }
            H264NAL.appendAnnexB(avcc.subdata(in: offset..<(offset + nalLength)), to: &accessUnit)
            offset += nalLength
        }
        guard !accessUnit.isEmpty else { return }

        statsLock.lock()
        encodedFramesValue += 1
        fpsWindowFrames += 1
        let now = CACurrentMediaTime()
        if now - fpsWindowStart >= 1 {
            measuredFpsValue = Int((Double(fpsWindowFrames) / (now - fpsWindowStart)).rounded())
            fpsWindowStart = now
            fpsWindowFrames = 0
        }
        statsLock.unlock()
        onAccessUnit?(accessUnit, isKeyFrame)
    }
}
