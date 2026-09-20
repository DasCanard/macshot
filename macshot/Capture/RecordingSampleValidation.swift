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
        guard CMSampleBufferCopySampleBufferForRange(allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleRange: CFRange(location: Int(skipped), length: count - Int(skipped)),
            sampleBufferOut: &result) == noErr else { return nil }
        return result
    }
}

/// Small queue used only until video starts, or while AAC applies backpressure.
/// Both byte and buffer limits are independent of the recording duration.
struct RecordingAudioQueue: @unchecked Sendable {
    // CoreMedia has not annotated CMSampleBuffer as Sendable. Ownership of
    // this value stays on MP4WriterSession.queue; retained buffers are read-only.
    nonisolated(unsafe) private(set) var samples: [CMSampleBuffer] = []
    private(set) var byteCount = 0
    let maximumBytes: Int
    let maximumBuffers: Int

    nonisolated init(maximumBytes: Int = 2 * 1024 * 1024, maximumBuffers: Int = 256) {
        self.maximumBytes = maximumBytes
        self.maximumBuffers = maximumBuffers
    }

    /// Returns false if retaining this sample would exceed the bound. Before
    /// video starts the caller may evict old pre-roll; during recording it must
    /// report overload rather than silently dropping audio.
    nonisolated mutating func append(_ sample: CMSampleBuffer) -> Bool {
        let size = CMSampleBufferGetTotalSampleSize(sample)
        guard size > 0, size <= maximumBytes - byteCount, samples.count < maximumBuffers else { return false }
        samples.append(sample)
        byteCount += size
        return true
    }

    @discardableResult
    nonisolated mutating func removeFirst() -> CMSampleBuffer? {
        guard !samples.isEmpty else { return nil }
        let sample = samples.removeFirst()
        byteCount -= CMSampleBufferGetTotalSampleSize(sample)
        return sample
    }

    nonisolated mutating func removeAll() {
        samples.removeAll(keepingCapacity: false)
        byteCount = 0
    }
}
