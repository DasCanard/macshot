import AVFoundation

enum VideoCompositionRendering {
    enum RenderError: LocalizedError {
        case invalidGeometry
        var errorDescription: String? { "The source recording has invalid video dimensions or orientation." }
    }

    static func scaleComposition(track: AVAssetTrack, renderSize: CGSize, duration: CMTime,
                                  frameDuration: CMTime? = nil) throws -> AVMutableVideoComposition {
        guard let layout = VideoRenderGeometry.layout(sourceSize: track.naturalSize,
            preferredTransform: track.preferredTransform, renderSize: renderSize), duration.isNumeric,
            duration.value > 0 else { throw RenderError.invalidGeometry }
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(layout.layerTransform, at: .zero)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.instructions = [instruction]
        composition.renderSize = renderSize
        composition.frameDuration = frameDuration ?? VideoFrameCadence.Inspection(track: track).duration()
        return composition
    }
}
