import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// Immutable media prepared away from the UI thread. CoreMedia
/// retains its backing storage; callers must not mutate the sample attachments.
public struct PreparedMediaFrame: @unchecked Sendable {
    public let frame: EncodedFrame
    public let sample: CMSampleBuffer
    public let format: CMVideoFormatDescription
    public let isDecoded: Bool
}

/// Thread-safe format cache and compressed-sample construction. This performs
/// no AppKit or layer operations. Session owners still validate generation when
/// the prepared sample arrives at the presentation queue.
public final class MediaFramePreparer: @unchecked Sendable {
    private let lock = NSLock()
    private var format: CMVideoFormatDescription?
    private var sps = Data(), pps = Data()
    private var decoder: VTDecompressionSession?
    private var decoderSPS = Data(), decoderPPS = Data()
    public init() {}
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        invalidateDecoder()
        format = nil; sps = Data(); pps = Data()
    }
    deinit { if let decoder { VTDecompressionSessionInvalidate(decoder) } }
    public func prepare(_ frame: EncodedFrame) throws -> PreparedMediaFrame {
        lock.lock(); defer { lock.unlock() }
        let format = try formatFor(frame)
        return PreparedMediaFrame(frame: frame, sample: try Self.makeSample(frame, format: format), format: format, isDecoded: false)
    }

    /// Decode every compressed reference in arrival order, then let the UI keep
    /// only the newest independent pixel frame. Call from a background queue.
    /// With both asynchronous/temporal flags clear, VideoToolbox guarantees its
    /// output callback completes before DecodeFrame returns; no semaphore or UI
    /// callback is involved. The caller bounds the compressed queue ahead of us.
    public func decode(_ frame: EncodedFrame) throws -> PreparedMediaFrame {
        guard !Thread.isMainThread else { throw MediaError.invalidFrame("video decoding must run off the main thread") }
        lock.lock(); defer { lock.unlock() }
        let compressedFormat = try formatFor(frame)
        if decoder == nil || decoderSPS != frame.sps || decoderPPS != frame.pps {
            invalidateDecoder()
            guard frame.isKeyframe else { throw MediaError.needsKeyframe }
            let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: compressedFormat,
                decoderSpecification: nil, imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                outputCallback: nil, decompressionSessionOut: &decoder)
            guard status == noErr else { invalidateDecoder(); throw MediaError.codec("Creating video decoder", status) }
            decoderSPS = frame.sps; decoderPPS = frame.pps
            if let decoder { _ = VTSessionSetProperty(decoder, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue) }
        }
        guard let decoder else { throw MediaError.needsKeyframe }
        let compressed = try Self.makeSample(frame, format: compressedFormat)
        var decodedImage: CVPixelBuffer?
        var decodedStatus: OSStatus = noErr
        let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: compressed, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            decodedStatus = status; decodedImage = image
        }
        guard status == noErr, decodedStatus == noErr, let image = decodedImage else {
            invalidateDecoder()
            if status != noErr { throw MediaError.codec("Decoding video", status) }
            if decodedStatus != noErr { throw MediaError.codec("Decoding video", decodedStatus) }
            throw MediaError.needsKeyframe
        }
        guard CVPixelBufferGetWidth(image) == Int(frame.width), CVPixelBufferGetHeight(image) == Int(frame.height) else {
            invalidateDecoder(); throw MediaError.invalidFrame("decoded dimensions disagree with frame header")
        }
        var pixelFormat: CMVideoFormatDescription?
        let described = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &pixelFormat)
        guard described == noErr, let pixelFormat else { throw MediaError.codec("Describing decoded video", described) }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        let wrapped = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
            formatDescription: pixelFormat, sampleTiming: &timing, sampleBufferOut: &sample)
        guard wrapped == noErr, let sample else { throw MediaError.codec("Preparing decoded video", wrapped) }
        Self.displayImmediately(sample)
        return PreparedMediaFrame(frame: frame, sample: sample, format: pixelFormat, isDecoded: true)
    }

    private func invalidateDecoder() {
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        decoder = nil; decoderSPS = Data(); decoderPPS = Data()
    }

    private func formatFor(_ frame: EncodedFrame) throws -> CMVideoFormatDescription {
        if format == nil || sps != frame.sps || pps != frame.pps {
            format = try Self.makeFormat(frame); sps = frame.sps; pps = frame.pps
        }
        guard let format else { throw MediaError.invalidFrame("missing decoder configuration") }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard dimensions.width == Int32(frame.width), dimensions.height == Int32(frame.height) else {
            throw MediaError.invalidFrame("H.264 dimensions disagree with frame header")
        }
        return format
    }
    public static func makeFormat(_ frame: EncodedFrame) throws -> CMVideoFormatDescription {
        var result: CMVideoFormatDescription?
        let status = frame.sps.withUnsafeBytes { sps in
            frame.pps.withUnsafeBytes { pps in
                let pointers = [sps.bindMemory(to: UInt8.self).baseAddress!, pps.bindMemory(to: UInt8.self).baseAddress!]
                let lengths = [frame.sps.count, frame.pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: lengths, nalUnitHeaderLength: 4, formatDescriptionOut: &result)
            }
        }
        guard status == noErr, let result else { throw MediaError.codec("Creating decoder format", status) }
        let dimensions = CMVideoFormatDescriptionGetDimensions(result)
        guard dimensions.width == Int32(frame.width), dimensions.height == Int32(frame.height) else { throw MediaError.invalidFrame("H.264 dimensions disagree with frame header") }
        return result
    }
    public static func makeSample(_ frame: EncodedFrame, format: CMVideoFormatDescription) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        let allocated = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: frame.payload.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: frame.payload.count, flags: 0, blockBufferOut: &block)
        guard allocated == noErr, let block else { throw MediaError.codec("Allocating compressed frame", allocated) }
        let copied = frame.payload.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: frame.payload.count) }
        guard copied == noErr else { throw MediaError.codec("Copying compressed frame", copied) }
        var sample: CMSampleBuffer?
        var size = frame.payload.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        let created = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard created == noErr, let sample else { throw MediaError.codec("Creating video sample", created) }
        displayImmediately(sample)
        return sample
    }
    private static func displayImmediately(_ sample: CMSampleBuffer) {
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
    }
}
