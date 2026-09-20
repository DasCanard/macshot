import AVFoundation
import ScreenCaptureKit
import XCTest

enum RecordingMediaFixture {
    static func mixedMovie(in directory: URL, size: CGSize = CGSize(width: 64, height: 64), frameCount: Int = 60,
                           pixelsForFrame: ((Int) throws -> CVPixelBuffer)? = nil) async throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".mp4")
        let queue = DispatchQueue(label: "macshot.tests.mix-source")
        let writer = try MP4WriterSession.make(queue: queue, url: url, width: Int(size.width), height: Int(size.height), fps: 30,
                                               recordSystemAudio: true, recordMicAudio: true)
        let defaultPixels = try RecordingMediaFixture.pixels(width: Int(size.width), height: Int(size.height))
        for tick in 0..<frameCount { // 30 fps, 48 kHz; distinct tones identify each track
            let pixels = try pixelsForFrame?(tick) ?? defaultPixels
            let time = CMTime(value: Int64(4_800_000 + tick * 1600), timescale: 48_000)
            let mic = try RecordingMediaFixture.audio(samples: 1600, pts: time,
                frequency: 440, phaseSample: tick * 1600, amplitude: 0.3)
            let system = try RecordingMediaFixture.audio(samples: 1600, pts: time,
                frequency: 880, phaseSample: tick * 1600, amplitude: 0.3, rightFrequency: 1320)
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !queue.sync(execute: { writer.handleFrame(pixelBuffer: pixels, presentationTime: time) }) {
                if ProcessInfo.processInfo.systemUptime > deadline { throw CocoaError(.fileWriteUnknown) }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            queue.sync { writer.handleMicSample(mic); writer.handleSystemAudioSample(system) }
        }
        writer.requestStop(atSourceTime: CMTime(value: Int64(3000 + frameCount), timescale: 30))
        try await writer.finish()
        return url
    }

    static func pixels(red: UInt8 = 40, green: UInt8 = 170, width: Int = 64, height: Int = 64) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * stride + 4 * x
                base[i] = 20; base[i + 1] = green; base[i + 2] = red; base[i + 3] = 255
            }
        }
        return buffer
    }

    static func audio(samples: Int = 1024, rate: Int32 = 48_000, pts: CMTime,
                      frequency: Double = 440, phaseSample: Int = 0, amplitude: Double = 0.1,
                      rightFrequency: Double? = nil) throws -> CMSampleBuffer {
        let channels = rightFrequency == nil ? 1 : 2
        let bytesPerFrame = channels * MemoryLayout<Float>.size
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame), mFramesPerPacket: 1, mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format), noErr)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: samples * bytesPerFrame, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: samples * bytesPerFrame,
            flags: 0, blockBufferOut: &block), noErr)
        let data = try XCTUnwrap(block)
        var pcm = [Float](repeating: 0, count: samples * channels)
        for frame in 0..<samples {
            let time = Double(frame + phaseSample) / Double(rate)
            pcm[frame * channels] = Float(sin(2 * .pi * frequency * time) * amplitude)
            if let rightFrequency = rightFrequency {
                pcm[frame * channels + 1] = Float(sin(2 * .pi * rightFrequency * time) * amplitude)
            }
        }
        pcm.withUnsafeBytes { bytes in
            XCTAssertEqual(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: data,
                offsetIntoDestination: 0, dataLength: bytes.count), noErr)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: rate),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = bytesPerFrame
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: data,
            formatDescription: format, sampleCount: samples, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
}

final class RecordingSampleValidationTests: XCTestCase {
    func testOnlyCompleteScreenFramesAreAccepted() throws {
        let buffer = try RecordingMediaFixture.pixels()
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var output: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescription: try XCTUnwrap(format),
            sampleTiming: &timing, sampleBufferOut: &output), noErr)
        let sample = try XCTUnwrap(output)
        XCTAssertFalse(RecordingSampleValidation.isCompleteFrame(sample))
        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)
            as? [NSMutableDictionary])
        for status in [SCFrameStatus.complete, .idle, .blank, .suspended, .started, .stopped] {
            attachments[0][SCStreamFrameInfo.status.rawValue] = status.rawValue
            XCTAssertEqual(RecordingSampleValidation.isCompleteFrame(sample), status == .complete)
        }
        CMSampleBufferInvalidate(sample)
        XCTAssertFalse(RecordingSampleValidation.isCompleteFrame(sample))
    }

    func testAudioBoundaryTrimmingPreservesSampleDurationAndPCM() throws {
        for rate: Int32 in [44_100, 48_000] {
            let sample = try RecordingMediaFixture.audio(samples: 1024, rate: rate,
                                                        pts: CMTime(value: 100 * Int64(rate), timescale: rate))
            let boundary = CMTime(value: 100 * Int64(rate) + 123, timescale: rate)
            let clipped = try XCTUnwrap(RecordingSampleValidation.audio(sample, startingAt: boundary))
            XCTAssertEqual(CMSampleBufferGetNumSamples(clipped), 901)
            XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(clipped), boundary)
            XCTAssertEqual(CMSampleBufferGetDuration(clipped), CMTime(value: 901, timescale: rate))
            var expected = [UInt8](repeating: 0, count: 901 * 4)
            var actual = expected
            CMBlockBufferCopyDataBytes(try XCTUnwrap(sample.dataBuffer), atOffset: 123 * 4,
                                      dataLength: expected.count, destination: &expected)
            CMBlockBufferCopyDataBytes(try XCTUnwrap(clipped.dataBuffer), atOffset: 0,
                                      dataLength: actual.count, destination: &actual)
            XCTAssertEqual(actual, expected)
            XCTAssertNil(RecordingSampleValidation.audio(sample, startingAt:
                CMTimeAdd(sample.presentationTimeStamp, sample.duration)))
        }
    }

    func testAudioBufferBoundsDoNotGrowWithInputDuration() throws {
        let sample = try RecordingMediaFixture.audio(samples: 128, pts: .zero)
        var queue = RecordingAudioQueue(maximumBytes: 4096, maximumBuffers: 8)
        for _ in 0..<100_000 {
            if !queue.append(sample) { queue.removeFirst(); XCTAssertTrue(queue.append(sample)) }
        }
        XCTAssertEqual(queue.samples.count, 8)
        XCTAssertEqual(queue.byteCount, 4096)
        queue.removeAll()
        XCTAssertEqual(queue.byteCount, 0)
    }
}

final class RecordingWriterTests: XCTestCase {
    private var directory: URL!
    private let queue = DispatchQueue(label: "macshot.tests.writer")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func makeWriter(audio: Bool = false) throws -> (MP4WriterSession, URL) {
        let url = directory.appendingPathComponent(UUID().uuidString + ".mp4")
        return (try MP4WriterSession.make(queue: queue, url: url, width: 64, height: 64, fps: 30,
                    recordSystemAudio: audio, recordMicAudio: audio), url)
    }

    private func append(_ writer: MP4WriterSession, time: Double, buffer: CVPixelBuffer) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !queue.sync(execute: { writer.handleFrame(pixelBuffer: buffer,
                              presentationTime: CMTime(seconds: time, preferredTimescale: 48_000)) }) {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Writer did not accept frame"); throw CocoaError(.fileWriteUnknown)
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func decodedTimes(_ url: URL) throws -> [Double] {
        let asset = AVAsset(url: url)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            XCTAssertNotNil(sample.imageBuffer)
            times.append(sample.presentationTimeStamp.seconds)
        }
        XCTAssertEqual(reader.status, .completed, "\(String(describing: reader.error))")
        return times
    }

    func testStaticTailProducesDecodableVideoThroughStopTimeIncludingEightHourTimestamps() async throws {
        for duration in [3.0, 8 * 3600.0] {
            let (writer, url) = try makeWriter()
            let buffer = try RecordingMediaFixture.pixels()
            try await append(writer, time: 100, buffer: buffer)
            try await append(writer, time: 100.1, buffer: buffer)
            writer.requestStop(atSourceTime: CMTime(seconds: 100 + duration, preferredTimescale: 48_000))
            try await writer.finish()
            let asset = AVAsset(url: url)
            XCTAssertEqual(VideoFrameCadence.declaredDuration(in: asset.metadata), CMTime(value: 1, timescale: 30))
            XCTAssertEqual(asset.duration.seconds, duration, accuracy: 1.0 / 30)
            let times = try decodedTimes(url)
            XCTAssertEqual(times.count, 3)
            XCTAssertEqual(try XCTUnwrap(times.first), 0, accuracy: 0.001)
            XCTAssertEqual(try XCTUnwrap(times.last), duration - 1.0 / 30, accuracy: 0.001)
        }
    }

    func testPauseRemovesGapAndStopWhilePausedDoesNotExtendThePause() async throws {
        let (writer, url) = try makeWriter()
        let buffer = try RecordingMediaFixture.pixels()
        try await append(writer, time: 100, buffer: buffer)
        writer.pause(atSourceTime: CMTime(seconds: 100.5, preferredTimescale: 48_000))
        XCTAssertFalse(queue.sync { writer.handleFrame(pixelBuffer: buffer, presentationTime: CMTime(value: 200, timescale: 1)) })
        writer.resume(addingPausedDuration: 3600)
        try await append(writer, time: 3701, buffer: buffer)
        writer.pause(atSourceTime: CMTime(value: 3702, timescale: 1))
        writer.requestStop(atSourceTime: CMTime(value: 7300, timescale: 1))
        try await writer.finish()
        XCTAssertEqual(AVAsset(url: url).duration.seconds, 2, accuracy: 1.0 / 30)
        XCTAssertEqual(try decodedTimes(url)[1], 1, accuracy: 0.001)
    }

    func testFinishingBeforeFirstFrameFailsConsistentlyAndDoesNotHang() async throws {
        let (writer, _) = try makeWriter(audio: true)
        let sample = try RecordingMediaFixture.audio(pts: .zero)
        queue.sync { for _ in 0..<10_000 { writer.handleMicSample(sample) } }
        writer.requestStop(atSourceTime: CMTime(value: 10, timescale: 1))
        for _ in 0..<2 {
            do { try await writer.finish(); XCTFail("Empty recording must not succeed") }
            catch { XCTAssertTrue(error is MP4WriterSession.WriterError) }
        }
    }

    func testConcurrentFinishCompletesOnceAndRetainsTheResult() async throws {
        let (writer, url) = try makeWriter()
        try await append(writer, time: 100, buffer: RecordingMediaFixture.pixels())
        writer.requestStop(atSourceTime: CMTime(value: 101, timescale: 1))
        async let first: Void = writer.finish()
        async let second: Void = writer.finish()
        _ = try await (first, second)
        try await writer.finish()
        XCTAssertEqual(try decodedTimes(url).count, 2)
    }

    func testBothAudioTracksSurviveRealEncodingAndDecoding() async throws {
        let (writer, url) = try makeWriter(audio: true)
        let base = CMTime(value: 100, timescale: 1)
        let beforeStart = try RecordingMediaFixture.audio(samples: 960, pts: CMTimeSubtract(base, CMTime(value: 480, timescale: 48_000)))
        queue.sync { writer.handleMicSample(beforeStart); writer.handleSystemAudioSample(beforeStart) }
        try await append(writer, time: 100, buffer: RecordingMediaFixture.pixels())
        for index in 1..<50 {
            let sample = try RecordingMediaFixture.audio(samples: 960,
                pts: CMTimeAdd(base, CMTime(value: Int64(index * 960 - 480), timescale: 48_000)))
            queue.sync { writer.handleMicSample(sample); writer.handleSystemAudioSample(sample) }
        }
        writer.requestStop(atSourceTime: CMTime(value: 101, timescale: 1))
        try await writer.finish()
        let asset = AVAsset(url: url)
        let tracks = asset.tracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 2)
        for track in tracks {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track,
                outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            var frames = 0
            while let sample = output.copyNextSampleBuffer() { frames += sample.numSamples }
            XCTAssertEqual(reader.status, .completed)
            XCTAssertGreaterThan(frames, 46_000)
            XCTAssertLessThan(frames, 51_000)
        }
    }

    func testCompletedFragmentsCanBeDecodedBeforeTheRecordingIsFinalized() async throws {
        let (writer, url) = try makeWriter()
        let buffer = try RecordingMediaFixture.pixels()
        // Accelerated media time, using the production writer. The copy is
        // taken while writing is still active, before any stop/finish call.
        for frame in 0..<600 {
            try await append(writer, time: 100 + Double(frame) / 30, buffer: buffer)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var recovered: URL?
        repeat {
            let snapshot = directory.appendingPathComponent(UUID().uuidString + ".mp4")
            try FileManager.default.copyItem(at: url, to: snapshot)
            let asset = AVAsset(url: snapshot)
            if let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds >= 8 {
                recovered = snapshot
                break
            }
            try FileManager.default.removeItem(at: snapshot)
            try await Task.sleep(nanoseconds: 20_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        // Always stop the original even if the recovery expectation fails.
        writer.requestStop(atSourceTime: CMTime(value: 120, timescale: 1))
        try await writer.finish()
        let snapshot = try XCTUnwrap(recovered, "No playable fragment was flushed before finishWriting")
        XCTAssertGreaterThanOrEqual(try decodedTimes(snapshot).count, 240)
    }

    func testAnAudioFormatChangeIsReportedOnceAndDoesNotSilentlySucceed() async throws {
        let url = directory.appendingPathComponent("format-change.mp4")
        var failures = 0 // read and written only on the writer queue
        let writer = try MP4WriterSession.make(queue: queue, url: url, width: 64, height: 64, fps: 30,
            recordSystemAudio: false, recordMicAudio: true, onFailure: { _ in failures += 1 })
        let first = try RecordingMediaFixture.audio(rate: 48_000, pts: CMTime(value: 100, timescale: 1))
        let changed = try RecordingMediaFixture.audio(rate: 44_100, pts: CMTime(value: 101, timescale: 1))
        queue.sync {
            writer.handleMicSample(first)
            writer.handleMicSample(changed)
            writer.handleMicSample(changed)
            XCTAssertEqual(failures, 1)
        }
        writer.requestStop(atSourceTime: CMTime(value: 102, timescale: 1))
        do { try await writer.finish(); XCTFail("Changed audio format must be reported") }
        catch { XCTAssertTrue(error is MP4WriterSession.WriterError) }
    }

    func testStaticScreenHeartbeatsKeepAudioAndRecoveryFragmentsAdvancing() async throws {
        let (writer, url) = try makeWriter(audio: true)
        try await append(writer, time: 100, buffer: RecordingMediaFixture.pixels())
        // Twenty seconds of audio, but no new screen image after the first.
        for tick in 0..<1000 {
            let time = CMTime(value: Int64(4_800_000 + tick * 960), timescale: 48_000)
            if tick > 0, tick % 50 == 0 {
                let deadline = ProcessInfo.processInfo.systemUptime + 5
                while !queue.sync(execute: { writer.handleHeartbeat(atSourceTime: time) }) {
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        XCTFail("Static heartbeat stalled"); throw CocoaError(.fileWriteUnknown)
                    }
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
            }
            let sample = try RecordingMediaFixture.audio(samples: 960, pts: time, phaseSample: tick * 960)
            queue.sync { writer.handleMicSample(sample); writer.handleSystemAudioSample(sample) }
        }
        // Wait for async encoders to flush a completed fragment, still without
        // calling finish. A static take must not depend on another screen edit.
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var recovered: URL?
        repeat {
            let snapshot = directory.appendingPathComponent(UUID().uuidString + ".mp4")
            try FileManager.default.copyItem(at: url, to: snapshot)
            let asset = AVAsset(url: snapshot)
            if let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds >= 8 {
                recovered = snapshot
                break
            }
            try FileManager.default.removeItem(at: snapshot)
            try await Task.sleep(nanoseconds: 20_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        writer.requestStop(atSourceTime: CMTime(value: 120, timescale: 1))
        try await writer.finish()
        let snapshot = try XCTUnwrap(recovered, "Static recording did not flush a recoverable fragment")
        XCTAssertGreaterThanOrEqual(try decodedTimes(snapshot).count, 8)
        let asset = AVAsset(url: url)
        XCTAssertEqual(asset.duration.seconds, 20, accuracy: 0.04)
        XCTAssertEqual(asset.tracks(withMediaType: .audio).count, 2)
        for track in asset.tracks(withMediaType: .audio) {
            XCTAssertEqual(track.timeRange.duration.seconds, 20, accuracy: 0.04)
        }
    }

    func testANewScreenImageArrivingJustBehindAHeartbeatIsNotLost() async throws {
        let (writer, url) = try makeWriter()
        let original = try RecordingMediaFixture.pixels(red: 20, green: 200)
        let changed = try RecordingMediaFixture.pixels(red: 230, green: 20)
        try await append(writer, time: 100, buffer: original)
        let heartbeatTime = CMTime(value: 101_050, timescale: 1000)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !queue.sync(execute: { writer.handleHeartbeat(atSourceTime: heartbeatTime) }) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CocoaError(.fileWriteUnknown) }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        // A screen frame was captured before the heartbeat but delivered after
        // it. This may be the only changed image before the screen goes idle.
        try await append(writer, time: 101.030, buffer: changed)
        // An actually older capture must still be rejected.
        XCTAssertFalse(queue.sync { writer.handleFrame(pixelBuffer: original,
            presentationTime: CMTime(value: 100_500, timescale: 1000)) })
        writer.requestStop(atSourceTime: CMTime(value: 102, timescale: 1))
        try await writer.finish()
        let asset = AVAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(asset.tracks(withMediaType: .video).first),
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var lastTime = -1.0, lastRed: UInt8 = 0, lastGreen: UInt8 = 0
        while let frame = output.copyNextSampleBuffer() {
            XCTAssertGreaterThan(frame.presentationTimeStamp.seconds, lastTime)
            lastTime = frame.presentationTimeStamp.seconds
            let buffer = try XCTUnwrap(frame.imageBuffer)
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            lastRed = base[2]; lastGreen = base[1]
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertGreaterThan(lastRed, 200)
        XCTAssertLessThan(lastGreen, 40)
        XCTAssertEqual(asset.duration.seconds, 2, accuracy: 0.001)
    }
}
