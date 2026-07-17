import Foundation

/// A single subtitle line with the time range (in the video's own seconds,
/// matching `AVPlayer.currentTime()`) it should be shown for.
struct SubtitleCue: Identifiable, Equatable {
    let id = UUID()
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String

    /// Compare by content, not by the random `id` — otherwise two identical
    /// cues (e.g. from regenerating subtitles) never compare equal.
    static func == (lhs: SubtitleCue, rhs: SubtitleCue) -> Bool {
        lhs.startTime == rhs.startTime && lhs.endTime == rhs.endTime && lhs.text == rhs.text
    }
}

/// Formats subtitle cues as a standard SubRip (.srt) file.
enum SubtitleExporter {
    static func srt(from cues: [SubtitleCue]) -> String {
        var lines: [String] = []
        for (index, cue) in cues.enumerated() {
            lines.append("\(index + 1)")
            lines.append("\(timestamp(cue.startTime)) --> \(timestamp(cue.endTime))")
            lines.append(cue.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let totalMilliseconds = Int((max(0, seconds) * 1000).rounded())
        let ms = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let s = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let m = totalMinutes % 60
        let h = totalMinutes / 60
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}
