import Foundation
import FoundationModels

enum SubtitleTranslationError: LocalizedError {
    case appleIntelligenceUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .appleIntelligenceUnavailable(let message):
            return message
        }
    }
}

/// Translates subtitle cues with the on-device Apple Intelligence language
/// model (FoundationModels framework, macOS 26+).
///
/// Why not Apple's Translation framework? Its session machinery
/// (`.translationTask` + model-download consent UI) blocks the main thread
/// in this app on current macOS builds before ever reaching our code. The
/// LLM path requires no UI handshake: if Apple Intelligence is enabled,
/// it just works, fully offline.
enum SubtitleTranslator {

    static func languageName(for identifier: String) -> String {
        switch identifier {
        case "zh-Hant": return "Traditional Chinese"
        case "zh-Hans": return "Simplified Chinese"
        case "en": return "English"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        case "es": return "Spanish"
        case "fr": return "French"
        case "de": return "German"
        default:
            return Locale(identifier: "en").localizedString(forIdentifier: identifier) ?? identifier
        }
    }

    /// Translates `cues` in small batches so progress is visible and the
    /// model's context stays small. `onBatch` is awaited on the main actor
    /// after each batch with (cue index -> translated text) and the total
    /// number of lines completed so far. Returns how many lines could not
    /// be translated (e.g. blocked by the model's content filter) and kept
    /// their original text.
    @discardableResult
    static func translate(
        cues: [SubtitleCue],
        sourceLocale: Locale,
        targetIdentifier: String,
        onBatch: @escaping @MainActor ([Int: String], Int) -> Void
    ) async throws -> Int {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw SubtitleTranslationError.appleIntelligenceUnavailable(message(for: reason))
        }

        let sourceName = Locale(identifier: "en")
            .localizedString(forIdentifier: sourceLocale.identifier) ?? sourceLocale.identifier
        let targetName = languageName(for: targetIdentifier)

        let batchSize = 15
        var completed = 0
        var untranslated = 0

        for batchStart in stride(from: 0, to: cues.count, by: batchSize) {
            try Task.checkCancellation()

            let range = batchStart..<min(batchStart + batchSize, cues.count)
            var updates: [Int: String] = [:]

            do {
                let numberedLines = range
                    .map { "\($0 - batchStart + 1)|\(cues[$0].text)" }
                    .joined(separator: "\n")
                let response = try await makeSession(sourceName: sourceName, targetName: targetName)
                    .respond(to: numberedLines)

                for (number, text) in parse(response.content) {
                    let index = batchStart + number - 1
                    if range.contains(index) {
                        updates[index] = text
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Whole batch rejected (e.g. content filter) — the mop-up
                // below retries every line individually.
                print("SuperResVideoPlayer: batch at cue \(batchStart) failed (\(error.localizedDescription)); falling back to line-by-line")
            }

            // Mop up whatever the batch didn't cover: parse misses (the
            // model merged/renumbered lines) or a rejected batch.
            for index in range where updates[index] == nil {
                try Task.checkCancellation()
                if let text = try await translateSingleLine(cues[index].text,
                                                            sourceName: sourceName,
                                                            targetName: targetName) {
                    updates[index] = text
                }
            }

            untranslated += range.count - updates.count
            completed += range.count
            await onBatch(updates, completed)
        }
        return untranslated
    }

    /// One-line fallback translation. More lenient than the batch path: if
    /// the model drops the "1|" prefix, the first non-empty response line
    /// is accepted as the translation. Returns nil if blocked or empty.
    private static func translateSingleLine(_ text: String, sourceName: String, targetName: String) async throws -> String? {
        let content: String
        do {
            content = try await makeSession(sourceName: sourceName, targetName: targetName)
                .respond(to: "1|\(text)").content
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil // this specific line is blocked — keep the original
        }

        if let parsed = parse(content)[1] {
            return parsed
        }
        return content
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
            .map(stripNumberPrefix)
    }

    /// Removes a leading "N|" / "N:" / "N." (ASCII or full-width) that the
    /// model sometimes emits with the wrong number, which the strict parser
    /// rejects but shouldn't end up inside a subtitle.
    private static func stripNumberPrefix(_ line: String) -> String {
        let separators: Set<Character> = ["|", ":", ".", "｜", "：", "．", "、"]
        var index = line.startIndex
        while index < line.endIndex, line[index].isNumber {
            index = line.index(after: index)
        }
        guard index > line.startIndex, index < line.endIndex, separators.contains(line[index]) else {
            return line
        }
        return String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func makeSession(sourceName: String, targetName: String) -> LanguageModelSession {
        // Translating existing subtitles is a "content transformation" of
        // user-provided media — the exact use case Apple's permissive
        // guardrails mode exists for. The default guardrails false-positive
        // heavily on dramatic/fictional dialogue ("Detected content likely
        // to be unsafe"); this mode transforms such content instead of
        // refusing it.
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        // Fresh session per request: keeps the context window small and
        // makes requests independent (one rejected request can't poison
        // the rest).
        return LanguageModelSession(model: model, instructions: """
        You are a professional subtitle translator. Translate each numbered \
        subtitle line from \(sourceName) into \(targetName). Keep the \
        translations concise and natural, suitable for on-screen subtitles. \
        Reply with EXACTLY one line per input line, in the format \
        N|translation, preserving the input numbers. Output nothing else — \
        no commentary, no blank lines.
        """)
    }

    /// Lenient parser for "N|translation" lines (also tolerates "N:" / "N.").
    /// Lines that don't parse are simply skipped — those cues keep their
    /// original text rather than failing the whole batch.
    private static func parse(_ content: String) -> [Int: String] {
        var result: [Int: String] = [:]
        for rawLine in content.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Accept ASCII and full-width separators — Chinese/Japanese
            // output often comes back as "１：…" or "1｜…".
            let separators: Set<Character> = ["|", ":", ".", "｜", "：", "．", "、"]
            guard let separatorIndex = line.firstIndex(where: { separators.contains($0) }) else {
                continue
            }
            let numberPart = line[..<separatorIndex].trimmingCharacters(in: .whitespaces)
            guard let number = Int(numberPart) else { continue }
            let text = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                result[number] = text
            }
        }
        return result
    }

    private static func message(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "Subtitle translation needs Apple Intelligence, which this Mac doesn't support."
        case .appleIntelligenceNotEnabled:
            return "Subtitle translation needs Apple Intelligence — enable it in System Settings > Apple Intelligence & Siri, then try again."
        case .modelNotReady:
            return "Apple Intelligence is still preparing its model. Try again in a few minutes."
        @unknown default:
            return "Apple Intelligence isn't available right now."
        }
    }
}
