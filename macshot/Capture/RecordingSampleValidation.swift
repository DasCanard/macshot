import AVFoundation
import ScreenCaptureKit

enum RecordingSampleValidation {
    nonisolated static func isCompleteFrame(_ sample: CMSampleBuffer) -> Bool {
        guard CMSampleBufferIsValid(sample), CMSampleBufferDataIsReady(sample),
              CMSampleBufferGetPresentationTimeStamp(sample).isNumeric,
              sample.imageBuffer != nil,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int else { return false }
        return status == SCFrameStatus.complete.rawValue
    }

    nonisolated static func isValidAudio(_ sample: CMSampleBuffer) -> Bool {
        guard CMSampleBufferIsValid(sample), CMSampleBufferDataIsReady(sample),
              CMSampleBufferGetPresentationTimeStamp(sample).isNumeric,
              CMSampleBufferGetNumSamples(sample) > 0,
              CMSampleBufferGetDuration(sample).isNumeric,
              CMTimeCompare(CMSampleBufferGetDuration(sample), .zero) > 0,
              let description = CMSampleBufferGetFormatDescription(sample),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return false }
        return format.mFormatID == kAudioFormatLinearPCM && format.mSampleRate.isFinite
            && format.mSampleRate > 0 && format.mChannelsPerFrame > 0
    }

    /// Trim PCM at a video-start/pause boundary without stretching an audio
    /// buffer or retaining samples before the writer's session starts.
    nonisolated static func audio(_ sample: CMSampleBuffer, startingAt start: CMTime) -> CMSampleBuffer? {
        guard isValidAudio(sample), start.isNumeric else { return nil }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard CMTimeCompare(pts, start) < 0 else { return sample }
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr,
              timing.duration.isNumeric, timing.duration.value > 0 else { return nil }
        let delta = CMTimeConvertScale(CMTimeSubtract(start, pts), timescale: timing.duration.timescale,
                                       method: .roundAwayFromZero)
        let count = CMSampleBufferGetNumSamples(sample)
        let skipped = delta.value / timing.duration.value + (delta.value % timing.duration.value == 0 ? 0 : 1)
        guard skipped >= 0, skipped < Int64(count) else { return nil }
        var result: CMSampleBuffer?
        if CMSampleBufferCopySampleBufferForRange(allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleRange: CFRange(location: Int(skipped), length: count - Int(skipped)),
            sampleBufferOut: &result) == noErr {
            return result
        }
        // The range copy rejects non-interleaved PCM (ScreenCaptureKit's
        // system audio), so trim each channel plane explicitly.
        return trimmedPlanarPCM(sample, skipping: Int(skipped), count: count,
            start: CMTimeAdd(pts, CMTimeMultiply(timing.duration, multiplier: Int32(skipped))))
    }

    nonisolated private static func trimmedPlanarPCM(_ sample: CMSampleBuffer, skipping skipped: Int,
                                                     count: Int, start: CMTime) -> CMSampleBuffer? {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mBytesPerFrame > 0 else { return nil }
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        let remaining = count - skipped
        var listSize = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &listSize,
            bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: nil) == noErr, listSize > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let listPointer = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil,
            bufferListOut: listPointer, bufferListSize: listSize, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(listPointer)
        for index in buffers.indices {
            guard let data = buffers[index].mData,
                  Int(buffers[index].mDataByteSize) >= count * bytesPerFrame else { return nil }
            buffers[index].mData = data.advanced(by: skipped * bytesPerFrame)
            buffers[index].mDataByteSize = UInt32(remaining * bytesPerFrame)
        }
        var trimmed: CMSampleBuffer?
        guard CMAudioSampleBufferCreateWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: nil,
            dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleCount: remaining, presentationTimeStamp: start, packetDescriptions: nil,
            sampleBufferOut: &trimmed) == noErr, let trimmed,
              CMSampleBufferSetDataBufferFromAudioBufferList(trimmed, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
                bufferList: UnsafePointer(listPointer)) == noErr else { return nil }
        withExtendedLifetime(block) {}
        return trimmed
    }
}

/// Small queue used only until video starts, or while AAC applies backpressure.
/// Bounded by audio duration and buffer count, both independent of the
/// recording length. Duration, not the byte size a buffer reports, is the
/// bound: ScreenCaptureKit's non-interleaved buffers can report sizes that say
/// nothing about how much audio is actually waiting.
struct RecordingAudioQueue: @unchecked Sendable {
    // CoreMedia has not annotated CMSampleBuffer as Sendable. Ownership of
    // this value stays on MP4WriterSession.queue; retained buffers are read-only.
    nonisolated(unsafe) private var storage: [CMSampleBuffer] = []
    private var head = 0
    private(set) var bufferedSeconds: Double = 0
    let maximumSeconds: Double
    let maximumBuffers: Int

    nonisolated init(maximumSeconds: Double = 10, maximumBuffers: Int = 4096) {
        self.maximumSeconds = maximumSeconds
        self.maximumBuffers = maximumBuffers
    }

    nonisolated var count: Int { storage.count - head }
    nonisolated var isEmpty: Bool { count == 0 }
    nonisolated var first: CMSampleBuffer? { isEmpty ? nil : storage[head] }

    /// Returns false if retaining this sample would exceed the bound. Before
    /// video starts the caller may evict old pre-roll; during recording it must
    /// report overload rather than silently dropping audio.
    nonisolated mutating func append(_ sample: CMSampleBuffer) -> Bool {
        let seconds = Self.seconds(of: sample)
        guard seconds > 0, bufferedSeconds + seconds <= maximumSeconds, count < maximumBuffers else { return false }
        storage.append(sample)
        bufferedSeconds += seconds
        return true
    }

    @discardableResult
    nonisolated mutating func removeFirst() -> CMSampleBuffer? {
        guard !isEmpty else { return nil }
        let sample = storage[head]
        head += 1
        bufferedSeconds = isEmpty ? 0 : max(0, bufferedSeconds - Self.seconds(of: sample))
        // Compact occasionally so removal stays O(1) amortized.
        if head >= 256, head * 2 >= storage.count {
            storage.removeFirst(head)
            head = 0
        }
        return sample
    }

    /// Drops leading samples that end at or before `time`.
    nonisolated mutating func removeSamples(endingBefore time: CMTime) {
        while let sample = first,
              CMTimeCompare(CMTimeAdd(sample.presentationTimeStamp, sample.duration), time) <= 0 {
            removeFirst()
        }
    }

    nonisolated mutating func removeAll() {
        storage.removeAll(keepingCapacity: false)
        head = 0
        bufferedSeconds = 0
    }

    nonisolated private static func seconds(of sample: CMSampleBuffer) -> Double {
        let seconds = CMSampleBufferGetDuration(sample).seconds
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }
}
