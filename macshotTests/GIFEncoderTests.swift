import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// GIF export runs on frames streamed from a recording, so the decimation and
/// delay maths decide whether an exported GIF plays at the speed it was
/// recorded at.
final class GIFEncoderTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("macshot-gif-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Helpers

    private func encodeGIF(fps: Int, sourceFPS: Int, frames: Int) throws -> URL {
        let url = scratch.appendingPathComponent("out-\(UUID().uuidString).gif")
        let encoder = GIFEncoder(url: url, fps: fps, sourceFPS: sourceFPS)
        for index in 0..<frames {
            encoder.addFrame(try makePixelBuffer(width: 8, height: 8, seed: index))
        }
        encoder.finish()
        return url
    }

    private func makePixelBuffer(width: Int, height: Int, seed: Int = 0) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true,
             kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &buffer)
        let pixelBuffer = try XCTUnwrap(buffer, "CVPixelBufferCreate failed (\(status))")

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * bytesPerRow + x * 4
                    bytes[offset + 0] = UInt8((seed * 7) % 256)       // B
                    bytes[offset + 1] = UInt8((x * 8) % 256)          // G
                    bytes[offset + 2] = UInt8((y * 8) % 256)          // R
                    bytes[offset + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    private func frameCount(of url: URL) throws -> Int {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "not a readable image file")
        return CGImageSourceGetCount(source)
    }

    private func frameDelays(of url: URL) throws -> [Double] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return (0..<CGImageSourceGetCount(source)).compactMap { index in
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any],
                  let delay = gif[kCGImagePropertyGIFDelayTime] as? Double else { return nil }
            return delay
        }
    }

    // MARK: - Decimation

    func testMatchingRatesKeepEveryFrame() throws {
        let url = try encodeGIF(fps: 30, sourceFPS: 30, frames: 30)
        XCTAssertEqual(try frameCount(of: url), 30)
    }

    func testHalfRateKeepsEveryOtherFrame() throws {
        let url = try encodeGIF(fps: 15, sourceFPS: 30, frames: 30)
        XCTAssertEqual(try frameCount(of: url), 15)
    }

    func testFractionalRatioDecimatesEvenly() throws {
        // 24 -> 15 isn't an integer ratio; the point of fractional decimation
        // is that it still lands on the right total.
        let url = try encodeGIF(fps: 15, sourceFPS: 24, frames: 48)
        XCTAssertEqual(try frameCount(of: url), 30, "48 frames of 24fps is 2s, which is 30 frames at 15fps")
    }

    func testRequestAboveTheCapIsClampedToThirty() throws {
        let url = try encodeGIF(fps: 60, sourceFPS: 60, frames: 60)
        XCTAssertEqual(try frameCount(of: url), 30, "GIF is capped at 30fps for file size")
        for delay in try frameDelays(of: url) {
            XCTAssertEqual(delay, 0.03, accuracy: 0.011, "delays must describe 30fps, not the requested 60")
        }
    }

    func testASourceSlowerThanTheRequestIsNotDecimated() throws {
        // Requesting 60fps from a 15fps source: every source frame is wanted.
        // Decimating against the uncapped request would have thrown half away.
        let url = try encodeGIF(fps: 60, sourceFPS: 15, frames: 20)
        XCTAssertEqual(try frameCount(of: url), 20, "no frame should be dropped when the source is slower than the target")
    }

    // MARK: - Delays

    func testDelaysAverageToTheRequestedRate() throws {
        let frames = 60
        let url = try encodeGIF(fps: 15, sourceFPS: 15, frames: frames)
        let delays = try frameDelays(of: url)
        XCTAssertEqual(delays.count, frames)

        // 1/15s = 0.0666…, which can't be expressed in GIF's hundredths. Rounding
        // each frame to 0.07 on its own would make the GIF 5% slow, so the
        // encoder alternates 0.07/0.06 and the total has to come out right.
        let total = delays.reduce(0, +)
        XCTAssertEqual(total, Double(frames) / 15.0, accuracy: 0.02,
                       "a 4-second clip must still take 4 seconds to play back")
        XCTAssertTrue(delays.contains { abs($0 - 0.06) < 0.001 }, "expected the 0.06/0.07 alternation")
        XCTAssertTrue(delays.contains { abs($0 - 0.07) < 0.001 })
    }

    func testNoFrameGetsAZeroDelay() throws {
        // A zero delay makes players fall back to their own default speed.
        for fps in [1, 5, 15, 24, 30] {
            let url = try encodeGIF(fps: fps, sourceFPS: 30, frames: 40)
            for delay in try frameDelays(of: url) {
                XCTAssertGreaterThan(delay, 0, "fps \(fps) produced a zero frame delay")
            }
        }
    }

    // MARK: - Degenerate input

    func testNonPositiveFrameRatesDoNotCrash() throws {
        // These used to divide by zero and trap on Int(infinity).
        // A non-positive rate is treated as the 1fps floor, so feed at least a
        // second of source frames or there is legitimately nothing to write.
        for (fps, sourceFPS) in [(0, 0), (0, 30), (-5, -5), (-1, 0)] {
            let url = scratch.appendingPathComponent("edge-\(fps)-\(sourceFPS).gif")
            let encoder = GIFEncoder(url: url, fps: fps, sourceFPS: sourceFPS)
            for index in 0..<60 {
                encoder.addFrame(try makePixelBuffer(width: 4, height: 4, seed: index))
            }
            encoder.finish()
            XCTAssertGreaterThan(try frameCount(of: url), 0, "fps \(fps)/\(sourceFPS) produced no frames")
            for delay in try frameDelays(of: url) {
                XCTAssertGreaterThan(delay, 0)
            }
        }
    }

    func testFinishWithoutFramesWritesNoBrokenFile() {
        let url = scratch.appendingPathComponent("empty.gif")
        let encoder = GIFEncoder(url: url, fps: 15, sourceFPS: 30)
        encoder.finish()
        if FileManager.default.fileExists(atPath: url.path) {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            XCTAssertEqual(size, 0, "an aborted export must not leave a truncated GIF behind")
        }
    }

    func testFramesSurviveRowPadding() throws {
        // CVPixelBuffer rows are commonly padded to a 64-byte boundary; a width
        // that isn't a multiple of 16 exercises the stride handling.
        let url = scratch.appendingPathComponent("padded.gif")
        let encoder = GIFEncoder(url: url, fps: 10, sourceFPS: 10)
        for index in 0..<5 {
            encoder.addFrame(try makePixelBuffer(width: 37, height: 11, seed: index))
        }
        encoder.finish()

        XCTAssertEqual(try frameCount(of: url), 5)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 37, "a padded row must not shear the frame")
        XCTAssertEqual(image.height, 11)
    }

    func testEncodingKeepsWorkingWhenTheDestinationDirectoryIsGone() throws {
        let url = scratch.appendingPathComponent("missing-dir/out.gif")
        let encoder = GIFEncoder(url: url, fps: 15, sourceFPS: 30)
        encoder.addFrame(try makePixelBuffer(width: 4, height: 4))
        encoder.finish()  // must not crash; the file simply isn't written
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
