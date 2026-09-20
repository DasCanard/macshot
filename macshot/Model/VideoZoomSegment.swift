import Foundation
import CoreGraphics

/// A timeline region where the rendered video zooms into a chosen point.
///
/// - `startTime` / `endTime` are in seconds, relative to the full (untrimmed)
///   source asset. Export code clips these to the active trim range.
/// - `zoomLevel` is a multiplier: 1.0 = no zoom, 2.0 = 2x magnification.
/// - `center` is normalized to the source video's displayed, orientation-applied
///   bounds: (0, 0) = top-left, (1, 1) = bottom-right. The current UI keeps it
///   inside the range where the selected zoom window remains in-frame.
/// - `fadeIn` / `fadeOut` are the transition ramp durations at each edge.
///   Clamped so they never exceed half the segment.
final class VideoZoomSegment: Codable {

    static let minDuration: Double = 0.3
    /// Target fade duration for a generously long segment. For shorter
    /// segments we auto-scale down so the plateau always dominates.
    static let defaultFade: Double = 0.35
    static let minZoom: CGFloat = 1.2
    static let maxZoom: CGFloat = 5.0

    /// Returns the fade duration auto-scaled so the combined in+out fades
    /// never exceed ~40 % of the segment, preserving a visible plateau.
    static func autoFade(for duration: Double) -> Double {
        // One fade (in or out) max length: 20 % of total, capped at defaultFade.
        let capByDuration = max(0.05, duration * 0.20)
        return min(defaultFade, capByDuration)
    }

    var id: UUID
    var startTime: Double
    var endTime: Double
    var zoomLevel: CGFloat
    var center: CGPoint
    var fadeIn: Double
    var fadeOut: Double

    init(id: UUID = UUID(),
         startTime: Double,
         endTime: Double,
         zoomLevel: CGFloat = 2.0,
         center: CGPoint = CGPoint(x: 0.5, y: 0.5),
         fadeIn: Double = defaultFade,
         fadeOut: Double = defaultFade) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.zoomLevel = zoomLevel
        self.center = center
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

    var duration: Double { max(0, endTime - startTime) }

    /// Effective fade duration — honors the user's fadeIn/fadeOut but always
    /// clamps to half the segment so there's at least one plateau frame.
    /// Never exceeds duration/2 (otherwise in+out would overlap).
    var effectiveFadeIn: Double { VideoEffectTiming.effectiveFade(fadeIn, duration: duration) }
    var effectiveFadeOut: Double { VideoEffectTiming.effectiveFade(fadeOut, duration: duration) }

    /// Uses the same value calculation as the background compositor.
    func zoomLevel(at t: Double) -> CGFloat {
        VideoZoomSnapshot(self).zoomLevel(at: t)
    }

    /// Clamp a normalized center so the visible zoom window (1/zoom of each
    /// dimension) stays fully inside the frame. Keeping the center in this
    /// range means `translation`'s edge clamping never has to shift the view,
    /// so the region the user drew and the region actually shown stay
    /// identical (fixes zooming into "the wrong area" near frame edges).
    static func clampedCenter(_ c: CGPoint, zoom: CGFloat) -> CGPoint {
        let half = 1.0 / (2 * max(zoom, 1.0001))
        return CGPoint(x: min(max(c.x, half), 1 - half),
                       y: min(max(c.y, half), 1 - half))
    }

    /// Translation (in video-pixel space) that places `center` at the visible
    /// center when applying `scale(zoom).translate(tx, ty)` to a frame of
    /// `videoSize`. Clamped so the zoom window never shows area outside the
    /// video's bounds (no black bars at edges from over-pan).
    func translation(zoom: CGFloat, videoSize: CGSize) -> CGPoint {
        VideoZoomSnapshot(self).translation(zoom: zoom, videoSize: videoSize)
    }

    /// Whether this segment's time range overlaps another. Touching endpoints
    /// do not count as overlap.
    func overlaps(_ other: VideoZoomSegment) -> Bool {
        return startTime < other.endTime && endTime > other.startTime
    }
}
