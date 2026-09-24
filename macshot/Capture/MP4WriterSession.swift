import Foundation
import AVFoundation
import os

// MARK: - MP4 writer session (queue-confined)

/// Owns ALL AVAssetWriter state and is confined to a single serial queue. The
/// SCStream/mic sample handlers run on that same queue and call into here, so
/// frames/audio and the writer lifecycle (start/pause/finish) never race —
/// previously these were `@MainActor` methods invoked from the background
/// recording queue with no synchronization, which could append after
/// `markAsFinished()` and crash AVAssetWriter. All members are touched only on
/// `queue`; `@unchecked Sendable` is sound because of that confinement.
/// Writer lifecycle mode — Int-backed so its `==` (from RawRepresentable) is
/// nonisolated; it's compared on the recording queue, not the main actor.
enum MP4WriterMode: Int, Sendable { case recording, paused, finishing, finished }

final class MP4WriterSession: @unchecked Sendable {
    let queue: DispatchQueue
    private var mode: MP4WriterMode = .recording
    private var pauseOffset: CMTime = .zero
    private var pausedAt: CMTime?
    private var stopTime: CMTime?
    private let frameDuration: CMTime
    private let onFailure: (Error) -> Void
    private var firstError: Error?
    private var finalResult: Result<Void, Error>?
    private var finishWaiters: [CheckedContinuation<Void, Error>] = []
    private var finishingStarted = false
    private var finishWritingStarted = false
    private var maintenanceTimer: DispatchSourceTimer?
    private var startupDeadline: TimeInterval?
    /// Called once, on the writer queue, with the first frame's time.
    private let onSessionStart: ((CMTime) -> Void)?

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var micAudioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false
    private var startTime: CMTime = .invalid
    private var lastVideoTime: CMTime = .invalid
    private var lastSourceVideoTime: CMTime = .invalid
    private var lastVideoBuffer: CVPixelBuffer?
    private var lastAudioEnd: CMTime = .invalid
    private var lastMicEnd: CMTime = .invalid
    private var systemAudioFormat: CMAudioFormatDescription?
    private var microphoneFormat: CMAudioFormatDescription?
    private(set) var frameCount: Int64 = 0
    private(set) var droppedVideoFrames: Int64 = 0
    private var pendingAudioSamples = RecordingAudioQueue()
    private var pendingMicSamples = RecordingAudioQueue()

    enum WriterError: LocalizedError {
        case noFrames, appendFailed, audioOverload, audioFormatChanged, finalizationTimedOut
        var errorDescription: String? {
            switch self {
            case .noFrames: return "No complete video frames were received. Check Screen Recording permission and the selected display."
            case .appendFailed: return "The recording could not write its media data. Check available disk space."
            case .audioOverload: return "Audio encoding could not keep up with this recording. The recording was stopped to avoid losing audio."
            case .audioFormatChanged: return "The microphone or system audio format changed during recording. The recording was stopped to preserve its timing."
            case .finalizationTimedOut: return "The recording encoder did not finish writing in time. The original recording data has been retained."
            }
        }
    }

    /// Build on `queue` so the writer/inputs are created where they're used.
    static func make(queue: DispatchQueue, url: URL, width: Int, height: Int, fps: Int,
                     recordSystemAudio: Bool, recordMicAudio: Bool,
                     onFailure: @escaping (Error) -> Void = { _ in },
                     onSessionStart: ((CMTime) -> Void)? = nil) throws -> MP4WriterSession {
        var result: Result<MP4WriterSession, Error>!
        queue.sync {
            result = Result {
                try MP4WriterSession(queue: queue, url: url, width: width, height: height,
                                     fps: fps, recordSystemAudio: recordSystemAudio,
                                     recordMicAudio: recordMicAudio, onFailure: onFailure,
                                     onSessionStart: onSessionStart)
            }
        }
        return try result.get()
    }

    private init(queue: DispatchQueue, url: URL, width: Int, height: Int, fps: Int,
                 recordSystemAudio: Bool, recordMicAudio: Bool, onFailure: @escaping (Error) -> Void,
                 onSessionStart: ((CMTime) -> Void)?) throws {
        self.queue = queue
        self.onFailure = onFailure
        self.onSessionStart = onSessionStart
        self.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        dispatchPrecondition(condition: .onQueue(queue))

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.metadata = VideoFrameCadence.metadata(for: frameDuration)
        // Flush self-contained movie fragments during capture. A crash can
        // retain completed fragments, and finalization need not build one
        // ever-growing sample table for a multi-hour recording.
        writer.movieFragmentInterval = CMTime(value: 10, timescale: 1)
        let settings = VideoEncodingSettings.outputSettings(
            width: width, height: height, fps: fps, codec: .h264, quality: .high)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.mediaTimeScale = VideoFrameCadence.captureTimeScale
        input.expectsMediaDataInRealTime = true
        let sourceAttr: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: sourceAttr)
        guard writer.canAdd(input) else { throw WriterError.appendFailed }
        writer.add(input)

        // Mic FIRST so it's the primary audio track (most players decode only the
        // first). Mono downmix avoids one-ear playback on stereo mic devices.
        if recordMicAudio {
            let micLayout = AudioChannelLayout(
                mChannelLayoutTag: kAudioChannelLayoutTag_Mono,
                mChannelBitmap: [], mNumberChannelDescriptions: 0,
                mChannelDescriptions: AudioChannelDescription())
            let micSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128000,
                AVChannelLayoutKey: Data(bytes: [micLayout], count: MemoryLayout<AudioChannelLayout>.size),
            ]
            let micIn = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
            micIn.expectsMediaDataInRealTime = true
            guard writer.canAdd(micIn) else { throw WriterError.appendFailed }
            writer.add(micIn)
            self.micAudioInput = micIn
        }

        if recordSystemAudio {
            let audioLayout = AudioChannelLayout(
                mChannelLayoutTag: kAudioChannelLayoutTag_Stereo,
                mChannelBitmap: [], mNumberChannelDescriptions: 0,
                mChannelDescriptions: AudioChannelDescription())
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256000,
                AVChannelLayoutKey: Data(bytes: [audioLayout], count: MemoryLayout<AudioChannelLayout>.size),
            ]
            let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioIn.expectsMediaDataInRealTime = true
            guard writer.canAdd(audioIn) else { throw WriterError.appendFailed }
            writer.add(audioIn)
            self.audioInput = audioIn
        }

        guard writer.startWriting() else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        self.assetWriter = writer
        self.videoInput = input
        self.adaptor = adaptor
    }

    // MARK: Lifecycle (all mutations are confined to queue)

    func captureDidStart() {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard self.mode != .finished, self.mode != .finishing else { return }
            self.startupDeadline = ProcessInfo.processInfo.systemUptime + 10
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(50))
            timer.setEventHandler { [weak self] in
                guard let self = self else { return }
                if let writer = self.assetWriter, writer.status == .failed {
                    self.fail(writer.error ?? WriterError.appendFailed)
                } else if self.mode == .recording, self.frameCount == 0, let deadline = self.startupDeadline,
                          ProcessInfo.processInfo.systemUptime > deadline {
                    self.fail(WriterError.noFrames)
                }
                if self.sessionStarted {
                    self.handleHeartbeat(atSourceTime: CMClockGetTime(CMClockGetHostTimeClock()))
                    self.drainAudio()
                }
            }
            self.maintenanceTimer = timer
            timer.resume()
        }
    }

    func pause(atSourceTime time: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) {
        queue.async {
            guard self.mode == .recording else { return }
            self.pausedAt = time
            self.mode = .paused
        }
    }

    func resume(addingPausedDuration duration: TimeInterval) {
        queue.async {
            guard self.mode == .paused, duration.isFinite, duration >= 0 else { return }
            self.pauseOffset = CMTimeAdd(self.pauseOffset,
                CMTime(seconds: duration, preferredTimescale: 1_000_000_000))
            if let deadline = self.startupDeadline { self.startupDeadline = deadline + duration }
            self.pausedAt = nil
            self.mode = .recording
        }
    }

    func requestStop(atSourceTime time: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) {
        queue.async {
            guard self.mode != .finished, self.stopTime == nil else { return }
            self.stopTime = self.adjustedTime(self.pausedAt ?? time)
            self.mode = .finishing
        }
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if let result = self.finalResult { continuation.resume(with: result); return }
                self.finishWaiters.append(continuation)
                guard !self.finishingStarted else { return }
                self.finishingStarted = true
                self.mode = .finishing
                self.maintenanceTimer?.cancel()
                self.maintenanceTimer = nil
                guard let writer = self.assetWriter else {
                    self.complete(.failure(self.firstError ?? WriterError.appendFailed)); return
                }
                guard self.sessionStarted, self.frameCount > 0 else {
                    writer.cancelWriting()
                    self.complete(.failure(self.firstError ?? WriterError.noFrames)); return
                }
                guard writer.status == .writing else {
                    self.complete(.failure(self.firstError ?? writer.error ?? WriterError.appendFailed)); return
                }
                let requestedEnd = self.stopTime ?? self.adjustedTime(CMClockGetTime(CMClockGetHostTimeClock()))
                let end = CMTimeMaximum(requestedEnd, CMTimeAdd(self.lastVideoTime, self.frameDuration))
                self.drainForFinish(writer: writer, end: end)
            }
        }
    }

    private func drainForFinish(writer: AVAssetWriter, end: CMTime) {
        // Each input gets one readiness pump, all serialized on the writer's
        // queue. The final callback runs once after every input is marked done.
        var remaining = 1 + (audioInput == nil ? 0 : 1) + (micAudioInput == nil ? 0 : 1)
        let finishedInput = { [weak self] in
            guard let self = self, self.finalResult == nil else { return }
            remaining -= 1
            guard remaining == 0, !self.finishWritingStarted else { return }
            self.finishWritingStarted = true
            writer.endSession(atSourceTime: end)
            writer.finishWriting { [weak self] in
                guard let self = self else { return }
                self.queue.async {
                    if writer.status == .completed, self.firstError == nil {
                        self.complete(.success(()))
                    } else {
                        self.complete(.failure(self.firstError ?? writer.error ?? WriterError.appendFailed))
                    }
                }
            }
        }
        if let input = videoInput {
            var done = false
            input.requestMediaDataWhenReady(on: queue) { [weak self] in
                guard let self = self, !done, self.finalResult == nil else { return }
                guard input.isReadyForMoreMediaData else { return }
                // Extend the final captured/heartbeat image to the exact stop
                // time, without rounding the tail up to the next heartbeat.
                let finalFrameTime = CMTimeSubtract(end, self.frameDuration)
                if CMTimeCompare(finalFrameTime, self.lastVideoTime) > 0,
                   let buffer = self.lastVideoBuffer {
                    if self.adaptor?.append(buffer, withPresentationTime: finalFrameTime) != true {
                        self.fail(writer.error ?? WriterError.appendFailed)
                    }
                }
                done = true
                input.markAsFinished()
                finishedInput()
            }
        }
        for (input, isMic) in [(audioInput, false), (micAudioInput, true)] {
            guard let input = input else { continue }
            var done = false
            input.requestMediaDataWhenReady(on: queue) { [weak self] in
                guard let self = self, !done, self.finalResult == nil else { return }
                self.drainAudio(isMic: isMic)
                let empty = isMic ? self.pendingMicSamples.isEmpty : self.pendingAudioSamples.isEmpty
                guard empty || self.firstError != nil else { return }
                done = true
                input.markAsFinished()
                finishedInput()
            }
        }
        queue.asyncAfter(deadline: .now() + 15) { [weak self, weak writer] in
            guard let self = self, let writer = writer, self.finalResult == nil else { return }
            let error = self.firstError ?? writer.error ?? WriterError.finalizationTimedOut
            writer.cancelWriting()
            self.complete(.failure(error))
        }
    }

    private func fail(_ error: Error) {
        guard firstError == nil, finalResult == nil else { return }
        firstError = error
        onFailure(error)
    }

    private func complete(_ result: Result<Void, Error>) {
        guard finalResult == nil else { return }
        finalResult = result
        Self.log.notice("Recording audio: trimmed=\(self.audioStats.trimmed, privacy: .public) retimed=\(self.audioStats.retimed, privacy: .public) dropped=\(self.audioStats.droppedBeforeBoundary, privacy: .public) invalid=\(self.audioStats.invalid, privacy: .public) ignored=\(self.audioStats.ignored, privacy: .public) received=\(self.audioStats.received, privacy: .public) systemEnd=\(self.lastAudioEnd.seconds - self.startTime.seconds, privacy: .public) micEnd=\(self.lastMicEnd.seconds - self.startTime.seconds, privacy: .public)")
        mode = .finished
        maintenanceTimer?.cancel()
        maintenanceTimer = nil
        pendingAudioSamples.removeAll()
        pendingMicSamples.removeAll()
        lastVideoBuffer = nil
        assetWriter = nil
        videoInput = nil
        audioInput = nil
        micAudioInput = nil
        adaptor = nil
        let waiters = finishWaiters
        finishWaiters.removeAll()
        for waiter in waiters { waiter.resume(with: result) }
    }

    // MARK: Sample handling (SCStream and mic delegates use this same queue)

    /// A static screen may produce only idle markers. A one-frame-per-second
    /// heartbeat keeps audio interleaving and recovery fragments advancing;
    /// retaining one image does not grow memory with the idle duration.
    @discardableResult
    func handleHeartbeat(atSourceTime time: CMTime) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard mode == .recording, time.isNumeric, lastVideoTime.isNumeric,
              let buffer = lastVideoBuffer,
              CMTimeCompare(CMTimeSubtract(adjustedTime(time), lastVideoTime), CMTime(value: 1, timescale: 1)) >= 0 else { return false }
        return appendVideoFrame(pixelBuffer: buffer, at: adjustedTime(time))
    }

    @discardableResult
    func handleFrame(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard presentationTime.isNumeric else { return false }
        let sourceTime = adjustedTime(presentationTime)
        guard !lastSourceVideoTime.isNumeric || CMTimeCompare(sourceTime, lastSourceVideoTime) > 0 else { return false }
        var outputTime = sourceTime
        if lastVideoTime.isNumeric, CMTimeCompare(outputTime, lastVideoTime) <= 0 {
            // A heartbeat uses the delivery clock. A newer captured image can
            // arrive just after that heartbeat with an earlier capture PTS.
            // Preserve the image at the next representable output timestamp;
            // only genuinely out-of-order captured frames are rejected above.
            let scale = VideoFrameCadence.captureTimeScale
            outputTime = CMTimeAdd(CMTimeConvertScale(lastVideoTime, timescale: scale, method: .roundAwayFromZero),
                                   CMTime(value: 1, timescale: scale))
        }
        guard appendVideoFrame(pixelBuffer: pixelBuffer, at: outputTime) else { return false }
        lastSourceVideoTime = sourceTime
        return true
    }

    private func appendVideoFrame(pixelBuffer: CVPixelBuffer, at time: CMTime) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard mode == .recording, firstError == nil, time.isNumeric,
              let writer = assetWriter, let input = videoInput, let adaptor = adaptor else { return false }
        guard writer.status == .writing else {
            fail(writer.error ?? WriterError.appendFailed); return false
        }
        guard !lastVideoTime.isNumeric || CMTimeCompare(time, lastVideoTime) > 0 else { return false }
        guard input.isReadyForMoreMediaData else { droppedVideoFrames += 1; return false }
        if !sessionStarted {
            startTime = time
            writer.startSession(atSourceTime: time)
            sessionStarted = true
            // Pre-roll that ends before the first frame would only be trimmed.
            pendingAudioSamples.removeSamples(endingBefore: time)
            pendingMicSamples.removeSamples(endingBefore: time)
            // Host time of media zero: the adjusted time plus any pause
            // offset accumulated before the first frame.
            onSessionStart?(CMTimeAdd(time, pauseOffset))
        }
        guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
            fail(writer.error ?? WriterError.appendFailed); return false
        }
        frameCount += 1
        lastVideoTime = time
        lastVideoBuffer = pixelBuffer
        drainAudio()
        return true
    }

    func handleSystemAudioSample(_ sample: CMSampleBuffer) { handleAudio(sample, isMic: false) }
    func handleMicSample(_ sample: CMSampleBuffer) { handleAudio(sample, isMic: true) }

    private func handleAudio(_ sample: CMSampleBuffer, isMic: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard mode == .recording, firstError == nil,
              (isMic ? micAudioInput : audioInput) != nil else {
            // Expected during stop and after a reported failure; counted only.
            audioStats.ignored += 1
            return
        }
        audioStats.received += 1
        guard RecordingSampleValidation.isValidAudio(sample),
              let owned = RecordingSampleValidation.ownedCopy(sample),
              let adjusted = SampleBufferTiming.shifted(owned, by: CMTimeMultiply(pauseOffset, multiplier: -1)) else {
            audioStats.invalid += 1
            if !audioStats.loggedInvalid {
                audioStats.loggedInvalid = true
                Self.log.error("Audio sample rejected (\(isMic ? "mic" : "system", privacy: .public)): \(RecordingSampleValidation.describe(sample), privacy: .public)")
            }
            return
        }
        let format = CMSampleBufferGetFormatDescription(sample)
        if let previous = isMic ? microphoneFormat : systemAudioFormat, let format = format,
           !CMFormatDescriptionEqual(previous, otherFormatDescription: format) {
            fail(WriterError.audioFormatChanged)
            return
        }
        if isMic { microphoneFormat = format } else { systemAudioFormat = format }
        // Make room first: a sample must not be refused while earlier audio
        // could still be handed to the encoder.
        if sessionStarted { drainAudio(isMic: isMic) }
        var pending = isMic ? pendingMicSamples : pendingAudioSamples
        if sessionStarted {
            if !pending.append(adjusted) {
                fail(WriterError.audioOverload)
                return
            }
        } else {
            // Pre-roll is useful only near the first complete video frame.
            // Keep the newest short window even if video never arrives.
            while !pending.append(adjusted), pending.removeFirst() != nil {}
            while pending.count > 1, pending.bufferedSeconds > Self.preRollSeconds { pending.removeFirst() }
        }
        if isMic { pendingMicSamples = pending } else { pendingAudioSamples = pending }
        if sessionStarted { drainAudio(isMic: isMic) }
    }

    /// Audio kept before the first video frame. Generous because a first frame
    /// can arrive late with an earlier capture time than audio already queued;
    /// whatever ends before that frame is dropped once it arrives.
    private static let preRollSeconds = 5.0

    private func drainAudio() {
        drainAudio(isMic: false)
        drainAudio(isMic: true)
    }

    private func drainAudio(isMic: Bool) {
        guard sessionStarted, firstError == nil,
              let input = isMic ? micAudioInput : audioInput else { return }
        while input.isReadyForMoreMediaData {
            let sample = isMic ? pendingMicSamples.removeFirst() : pendingAudioSamples.removeFirst()
            guard let sample = sample else { break }
            let lastEnd = isMic ? lastMicEnd : lastAudioEnd
            let boundary = lastEnd.isNumeric ? CMTimeMaximum(startTime, lastEnd) : startTime
            guard let clipped = alignedAudio(sample, startingAt: boundary, isMic: isMic) else { continue }
            guard input.append(clipped) else {
                fail(assetWriter?.error ?? WriterError.appendFailed); return
            }
            let end = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(clipped), CMSampleBufferGetDuration(clipped))
            if isMic { lastMicEnd = end } else { lastAudioEnd = end }
        }
    }

    /// Aligns a queued buffer to the end of the audio already written.
    /// Capture clocks drift against the sample count, so after a second or so
    /// every buffer overlaps its predecessor by a sample or two; trimming keeps
    /// sync. If a buffer can't be trimmed it is moved to the boundary instead:
    /// silently dropping it would lose all audio from that point on.
    private func alignedAudio(_ sample: CMSampleBuffer, startingAt boundary: CMTime, isMic: Bool) -> CMSampleBuffer? {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard CMTimeCompare(pts, boundary) < 0 else { return sample }
        let end = CMTimeAdd(pts, CMSampleBufferGetDuration(sample))
        guard CMTimeCompare(end, boundary) > 0 else {
            audioStats.droppedBeforeBoundary += 1
            return nil
        }
        if let trimmed = RecordingSampleValidation.audio(sample, startingAt: boundary) {
            audioStats.trimmed += 1
            return trimmed
        }
        audioStats.retimed += 1
        if !audioStats.loggedTrimFailure {
            audioStats.loggedTrimFailure = true
            Self.log.error("Audio trim failed (\(isMic ? "mic" : "system", privacy: .public)): \(RecordingSampleValidation.describe(sample), privacy: .public) overlap=\(CMTimeSubtract(boundary, pts).seconds, privacy: .public)")
        }
        return SampleBufferTiming.retimed(sample, to: boundary)
    }

    private struct AudioStats {
        var trimmed = 0, retimed = 0, droppedBeforeBoundary = 0, invalid = 0, ignored = 0, received = 0
        var loggedTrimFailure = false, loggedInvalid = false
    }
    private var audioStats = AudioStats()
    private static let log = Logger(subsystem: "com.sw33tlie.macshot", category: "RecordingWriter")

    private func adjustedTime(_ time: CMTime) -> CMTime { CMTimeSubtract(time, pauseOffset) }
}
