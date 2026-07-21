import Foundation

/// Pure numeric helpers for the video pipeline, extracted so the "magic
/// number" formulas can be unit-tested independently of Metal/AVFoundation.
public enum VideoMath {

    /// Metal 2D-texture side limit on Apple-family GPUs.
    public static let maxTextureDimension = 16384

    /// A target average bitrate for the HEVC export, scaled by pixel count
    /// and frame rate (~0.07 bits per pixel per second), clamped to a sane
    /// range. Used by `VideoExporter`.
    public static func recommendedBitrate(width: Int, height: Int, fps: Double) -> Int {
        let raw = Double(width * height) * fps * 0.07
        return min(80_000_000, max(2_000_000, Int(raw)))
    }

    /// Clamps a requested upscale factor so the output never exceeds the
    /// GPU's texture-dimension limit. Returns a factor `<= requested` (and
    /// `<= 1` means "already at/over the limit — don't upscale"). Used by
    /// the Super Resolution and Neural-enhancer paths.
    public static func clampedUpscaleFactor(inputWidth: Int, inputHeight: Int,
                                            requestedFactor: Double,
                                            maxDimension: Int = maxTextureDimension) -> Double {
        guard inputWidth > 0, inputHeight > 0 else { return requestedFactor }
        let limit = min(Double(maxDimension) / Double(inputWidth),
                        Double(maxDimension) / Double(inputHeight))
        return min(requestedFactor, limit)
    }
}
