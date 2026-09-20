import AVFoundation

enum VideoCompositionBuilder {
    struct Result {
        let composition: AVMutableComposition
        let videoTrack: AVMutableCompositionTrack
        let audioTracks: [AVMutableCompositionTrack]
        let timeMap: [EffectsCompositionInstruction.TimeMapEntry]
        let frameDuration: CMTime
        var duration: Double { composition.duration.seconds }
    }

    enum BuildError: LocalizedError {
        case invalidTimeline, missingVideo, unsupportedFreeze
        var errorDescription: String? {
            switch self {
            case .invalidTimeline: return "The edited recording contains an invalid time range."
            case .missingVideo: return "The source recording has no usable video track."
            case .unsupportedFreeze: return "The selected freeze frame could not be located in the source recording."
            }
        }
    }

    /// Constructs a privately owned composition. Every insert either succeeds
    /// or throws; a partial timeline must never be presented as a valid export.
    static func build(asset: AVAsset, pieces: [VideoSpeeds.Piece], includeAudio: Bool,
                      sourceFrameDuration: CMTime? = nil) throws -> Result {
        guard let sourceVideo = asset.tracks(withMediaType: .video).first else { throw BuildError.missingVideo }
        guard !pieces.isEmpty else { throw BuildError.invalidTimeline }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid) else { throw BuildError.missingVideo }
        // Avoid rounding each edit to a coarse track clock.
        video.naturalTimeScale = 1_000_000_000
        video.preferredTransform = sourceVideo.preferredTransform
        let sourceAudio = includeAudio ? asset.tracks(withMediaType: .audio) : []
        let audio = try sourceAudio.map { _ -> AVMutableCompositionTrack in
            guard let track = composition.addMutableTrack(withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid) else { throw BuildError.invalidTimeline }
            track.naturalTimeScale = 1_000_000_000
            return track
        }
        let frameDuration = sourceFrameDuration ?? VideoFrameCadence.declaredDuration(in: asset.metadata)
            ?? VideoFrameCadence.Inspection(track: sourceVideo).duration()
        var cursor = CMTime.zero
        var map: [EffectsCompositionInstruction.TimeMapEntry] = []
        for piece in pieces {
            guard piece.srcStart.isFinite, piece.srcEnd.isFinite, piece.compositionDuration.isFinite,
                  piece.srcStart >= 0, piece.srcEnd >= piece.srcStart, piece.compositionDuration > 0,
                  piece.srcEnd <= asset.duration.seconds + 0.000000001,
                  piece.compositionDuration < 9_000_000_000 else {
                throw BuildError.invalidTimeline
            }
            var duration = CMTime(seconds: piece.compositionDuration, preferredTimescale: 1_000_000_000)
            guard duration.isNumeric, duration.value > 0 else { throw BuildError.invalidTimeline }
            let start = CMTime(seconds: piece.srcStart, preferredTimescale: 1_000_000_000)
            let sourceRange: CMTimeRange
            if piece.kind == .freeze {
                guard piece.srcStart == piece.srcEnd else { throw BuildError.invalidTimeline }
                sourceRange = try frameRange(at: start, in: sourceVideo, fallbackDuration: frameDuration)
            } else {
                let end = CMTime(seconds: piece.srcEnd, preferredTimescale: 1_000_000_000)
                // A seconds-to-ticks conversion may round a rational endpoint
                // outward by a fraction of a nanosecond. Preserve exact track
                // boundaries rather than rejecting a valid full-length trim.
                let exactStart = abs(start.seconds - sourceVideo.timeRange.start.seconds) <= 0.000000001
                    ? sourceVideo.timeRange.start : start
                let exactEnd = abs(end.seconds - sourceVideo.timeRange.end.seconds) <= 0.000000001
                    ? sourceVideo.timeRange.end : end
                sourceRange = CMTimeRange(start: exactStart, end: exactEnd)
                if piece.kind == .normal {
                    guard abs(piece.compositionDuration - piece.sourceDuration) <= 0.000000001 else {
                        throw BuildError.invalidTimeline
                    }
                    duration = sourceRange.duration
                }
            }
            guard sourceRange.duration.isNumeric, sourceRange.duration.value > 0,
                  CMTimeRangeContainsTimeRange(sourceVideo.timeRange, otherRange: sourceRange) else {
                throw BuildError.invalidTimeline
            }
            try video.insertTimeRange(sourceRange, of: sourceVideo, at: cursor)
            if CMTimeCompare(sourceRange.duration, duration) != 0 {
                // Insertion rounds a rational source interval to the track's
                // clock. Scale the interval actually inserted: using the
                // original 1/30 duration here can leave a nanosecond gap at
                // the next segment, which a compositor may request.
                let insertedRange = CMTimeRange(start: cursor, end: video.timeRange.end)
                video.scaleTimeRange(insertedRange, toDuration: duration)
            }
            for (source, destination) in zip(sourceAudio, audio) {
                if piece.kind == .freeze {
                    destination.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: duration))
                } else {
                    try appendAudio(source: source, destination: destination, range: sourceRange,
                                    at: cursor, scaledDuration: duration)
                }
            }
            let end = CMTimeAdd(cursor, duration)
            guard end.isNumeric else { throw BuildError.invalidTimeline }
            map.append(.init(compStart: cursor.seconds, compEnd: end.seconds,
                             sourceStart: piece.srcStart,
                             factor: piece.kind == .freeze ? 0 : sourceRange.duration.seconds / duration.seconds))
            cursor = end
        }
        return Result(composition: composition, videoTrack: video, audioTracks: audio,
                      timeMap: map, frameDuration: frameDuration)
    }

    private static func appendAudio(source: AVAssetTrack, destination: AVMutableCompositionTrack,
                                    range: CMTimeRange, at cursor: CMTime, scaledDuration: CMTime) throws {
        let overlap = CMTimeRangeGetIntersection(range, otherRange: source.timeRange)
        if overlap.isValid, overlap.duration.isNumeric, overlap.duration.value > 0 {
            let before = CMTimeSubtract(overlap.start, range.start)
            if before.value > 0 { destination.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: before)) }
            try destination.insertTimeRange(overlap, of: source, at: CMTimeAdd(cursor, before))
            let after = CMTimeSubtract(range.end, overlap.end)
            if after.value > 0 {
                destination.insertEmptyTimeRange(CMTimeRange(start: CMTimeAdd(cursor,
                    CMTimeSubtract(overlap.end, range.start)), duration: after))
            }
        } else {
            destination.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: range.duration))
        }
        if CMTimeCompare(range.duration, scaledDuration) != 0 {
            destination.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: scaledDuration)
        }
    }

    /// Locate the whole presentation interval of one actual frame, including
    /// VFR and non-keyframes. Stretching a guessed 1/600-second slice could
    /// straddle the next frame or fail to contain a sample at all.
    private static func frameRange(at time: CMTime, in track: AVAssetTrack,
                                    fallbackDuration: CMTime) throws -> CMTimeRange {
        // Source seconds originate in UI/model Doubles. Snap a sub-nanosecond
        // conversion error at an exact frame boundary to that frame.
        let query = CMTimeAdd(time, CMTime(value: 1, timescale: 1_000_000_000))
        guard let cursor = track.makeSampleCursor(presentationTimeStamp: query) else { throw BuildError.unsupportedFreeze }
        while CMTimeCompare(cursor.presentationTimeStamp, query) > 0 {
            guard cursor.stepInPresentationOrder(byCount: -1) != 0 else { break }
        }
        var end: CMTime
        while true {
            guard let next = cursor.copy() as? AVSampleCursor else { throw BuildError.unsupportedFreeze }
            if next.stepInPresentationOrder(byCount: 1) == 0 {
                let duration = cursor.currentSampleDuration
                end = CMTimeAdd(cursor.presentationTimeStamp,
                    duration.isNumeric && duration.value > 0 ? duration : fallbackDuration)
                break
            }
            end = next.presentationTimeStamp
            if CMTimeCompare(end, query) > 0 { break }
            guard cursor.stepInPresentationOrder(byCount: 1) != 0 else { break }
        }
        return CMTimeRangeGetIntersection(track.timeRange,
            otherRange: CMTimeRange(start: cursor.presentationTimeStamp, end: end))
    }
}
