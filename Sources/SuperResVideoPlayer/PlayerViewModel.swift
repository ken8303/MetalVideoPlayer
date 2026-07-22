import AppKit
import Combine
import UniformTypeIdentifiers
import Speech
import SuperResCore

/// Which implementation the AI Image Enhancer uses.
enum EnhancerEngine: String, CaseIterable, Identifiable {
    case classic   // adaptive denoise + sharpen kernel (cheapest)
    case neural    // MetalFX ML supersample (2x reconstruct → Lanczos back)
    case max       // Real-ESRGAN via Core ML — export only; playback previews with .neural
    var id: String { rawValue }
}

/// Owns the libmpv playback engine (`MPVPlayer`), exposes playback state to
/// SwiftUI, and vends decoded video frames to the Metal renderer. mpv plays
/// every container/codec its bundled ffmpeg supports (MKV, WebM, FLAC, ...)
/// natively — no conversion step.
final class PlayerViewModel: ObservableObject {

    // MARK: Published UI state

    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var videoTitle: String = "No video loaded"
    @Published var isScrubbing = false

    /// Playback volume, 0...100 (mpv's software volume). Persisted; mute is
    /// deliberately not (a fresh launch shouldn't start silent).
    @Published var volume: Double = 100 {
        didSet {
            mpv.setVolume(volume)
            Defaults.set(volume, .volume)
        }
    }
    @Published var isMuted = false {
        didSet { mpv.setMuted(isMuted) }
    }

    /// Set when a file fails to open/decode, so the UI can say why nothing
    /// is playing instead of silently showing a black view.
    @Published var playbackErrorMessage: String?

    /// One-line description of whatever long-running background work is in
    /// flight (audio extraction, model downloads, transcription,
    /// translation, export), shown in the UI's status row. nil = idle.
    @Published var statusMessage: String?

    /// Live per-second summary from the Metal renderer: input→output
    /// resolution and real vs. synthesized frame counts — ground truth that
    /// Super Resolution / frame interpolation are actually running.
    @Published var pipelineStatus: String?

    // MARK: Video export state

    @Published var isExportingVideo = false
    @Published var exportProgress: Double = 0
    private var videoExporter: VideoExporter?

    /// Export gets its own importer so loading a new video (which cancels
    /// `mediaImporter` for subtitles) can't silently kill an export's
    /// repackaging phase.
    private var exportImporter: MediaImporter?

    /// AI Image Enhancer: same-resolution cleanup applied before Super
    /// Resolution. See `EnhancerEngine` for the three implementations.
    /// These enhancement/quality settings persist across launches (see
    /// `Defaults` and `restoreSettings()`).
    @Published var imageEnhancementEnabled = false {
        didSet { Defaults.set(imageEnhancementEnabled, .imageEnhancementEnabled) }
    }
    @Published var enhancementEngine: EnhancerEngine = .classic {
        didSet { Defaults.set(enhancementEngine.rawValue, .enhancementEngine) }
    }
    @Published var enhancementStrength: Double = 0.5 {
        didSet { Defaults.set(enhancementStrength, .enhancementStrength) }
    }

    /// Toggle for enabling/disabling MetalFX Super Resolution upscaling.
    @Published var superResolutionEnabled = true {
        didSet { Defaults.set(superResolutionEnabled, .superResolutionEnabled) }
    }

    /// Target upscale factor applied by MetalFX when Super Resolution is on.
    @Published var upscaleFactor: Double = 1.5 {
        didSet { Defaults.set(upscaleFactor, .upscaleFactor) }
    }

    /// AI Frame Interpolation smoothing multiplier: 1 = off, 2 = one
    /// synthesized in-between frame per real pair (native MetalFX), 3 = two
    /// synthesized frames per real pair (custom warp fallback).
    @Published var frameInterpolationMultiplier: Int = 1 {
        didSet { Defaults.set(frameInterpolationMultiplier, .frameInterpolationMultiplier) }
    }

    /// Set by `Renderer` if MetalFX spatial scaling is unsupported on this GPU.
    @Published var superResolutionUnsupported = false

    /// Set by `Renderer` if the native MTLFXFrameInterpolator is unavailable
    /// (interpolation still works via the custom warp fallback).
    @Published var nativeFrameInterpolationUnsupported = false

    // MARK: AI Subtitle Generator state

    @Published var subtitleCues: [SubtitleCue] = []
    @Published var subtitlesEnabled = true
    @Published var isGeneratingSubtitles = false
    @Published var subtitleGenerationProgress: Double = 0
    @Published var subtitleErrorMessage: String?

    /// Spoken language to transcribe. Restored from the last session if it's
    /// still supported, else the system's current locale.
    @Published var subtitleLanguage: Locale = .current {
        didSet { Defaults.set(subtitleLanguage.identifier, .subtitleLanguage) }
    }

    /// Locales this Mac's Speech framework can recognize, for the language picker.
    private(set) var availableSubtitleLocales: [Locale] = []

    /// BCP-47 identifiers of languages whose on-device speech model is
    /// already installed — shown as "(downloaded)" in the language picker.
    @Published private(set) var installedSpeechLocaleIdentifiers: Set<String> = []

    // MARK: Subtitle translation state

    /// BCP-47 language identifier to translate subtitles into
    /// ("zh-Hant", "en", ...); empty string = translation off.
    /// Translation runs on-device via Apple Intelligence — see
    /// `SubtitleTranslator` and `startSubtitleTranslation()`.
    @Published var translationTargetIdentifier: String = ""

    /// Translated versions of `subtitleCues` (same timings, translated
    /// text). When non-empty, these are displayed and exported instead.
    @Published var translatedCues: [SubtitleCue] = []

    @Published var isTranslatingSubtitles = false

    /// The cues currently shown/exported: translated if available.
    var displayedSubtitleCues: [SubtitleCue] {
        translatedCues.isEmpty ? subtitleCues : translatedCues
    }

    private let subtitleGenerator = SubtitleGenerator()

    /// Extracts audio from containers the Speech framework can't read
    /// directly (it uses AVFoundation internally, so MKV etc. need their
    /// audio track pulled out first — the video stream is never touched).
    private let mediaImporter = MediaImporter()

    private var currentVideoURL: URL?

    /// Bumped on every generate/cancel/load so a stale completion handler
    /// can't overwrite state for a newer transcription.
    private var subtitleGenerationID = 0

    // MARK: Playback engine

    /// libmpv-backed engine. The Metal renderer reads frames from it
    /// directly (via the settings snapshot pushed in MetalVideoView).
    let mpv = MPVPlayer()

    /// Keys + typed accessors for the settings that persist across launches.
    enum Defaults: String {
        case imageEnhancementEnabled, enhancementEngine, enhancementStrength
        case superResolutionEnabled, upscaleFactor, frameInterpolationMultiplier
        case volume, subtitleLanguage

        static func set(_ value: Any, _ key: Defaults) {
            UserDefaults.standard.set(value, forKey: key.rawValue)
        }
        static func has(_ key: Defaults) -> Bool {
            UserDefaults.standard.object(forKey: key.rawValue) != nil
        }
        static func double(_ key: Defaults) -> Double { UserDefaults.standard.double(forKey: key.rawValue) }
        static func integer(_ key: Defaults) -> Int { UserDefaults.standard.integer(forKey: key.rawValue) }
        static func bool(_ key: Defaults) -> Bool { UserDefaults.standard.bool(forKey: key.rawValue) }
        static func string(_ key: Defaults) -> String? { UserDefaults.standard.string(forKey: key.rawValue) }
    }

    /// Restores persisted quality/enhancement settings. Property observers
    /// don't fire during `init`, so anything that must reach mpv (volume) is
    /// pushed explicitly afterwards.
    private func restoreSettings() {
        if Defaults.has(.imageEnhancementEnabled) {
            imageEnhancementEnabled = Defaults.bool(.imageEnhancementEnabled)
        }
        if let raw = Defaults.string(.enhancementEngine), let engine = EnhancerEngine(rawValue: raw) {
            enhancementEngine = engine
        }
        if Defaults.has(.enhancementStrength) {
            enhancementStrength = Defaults.double(.enhancementStrength)
        }
        if Defaults.has(.superResolutionEnabled) {
            superResolutionEnabled = Defaults.bool(.superResolutionEnabled)
        }
        if Defaults.has(.upscaleFactor) {
            // Guard against a value outside the picker's options.
            let saved = Defaults.double(.upscaleFactor)
            if [1.3, 1.5, 2.0].contains(saved) { upscaleFactor = saved }
        }
        if Defaults.has(.frameInterpolationMultiplier) {
            let saved = Defaults.integer(.frameInterpolationMultiplier)
            if (1...3).contains(saved) { frameInterpolationMultiplier = saved }
        }
        if Defaults.has(.volume) {
            volume = min(100, max(0, Defaults.double(.volume)))
        }
    }

    init() {
        let supported = SubtitleGenerator.supportedLocales
        availableSubtitleLocales = supported
        let current = Locale.current
        // Prefer the language used last time, else the system locale —
        // assigning the matched *supported* Locale instance (not `current`),
        // since Locale equality is stricter than identifier equality and the
        // Picker's tag matching needs an instance from `availableSubtitleLocales`.
        let preferredIdentifier = Defaults.string(.subtitleLanguage) ?? current.identifier
        subtitleLanguage = supported.first(where: { $0.identifier == preferredIdentifier })
            ?? supported.first(where: { $0.identifier == current.identifier })
            ?? supported.first
            ?? current

        restoreSettings()
        // Observers don't fire during init — push the restored volume through.
        mpv.setVolume(volume)

        // mpv event callbacks (all delivered on the main queue).
        mpv.onTimeChanged = { [weak self] seconds in
            guard let self, !self.isScrubbing else { return }
            self.currentTime = seconds
        }
        mpv.onDurationChanged = { [weak self] seconds in
            guard let self else { return }
            self.duration = (seconds.isFinite && seconds > 0) ? seconds : 0
        }
        mpv.onPlaybackEnded = { [weak self] in
            self?.isPlaying = false
        }
        mpv.onPauseChanged = { [weak self] paused in
            // Track mpv's real pause state (it can pause itself, e.g. on a
            // buffering stall) — but only once a video is loaded, since mpv
            // reports pause=false while idle at startup.
            guard let self, self.currentVideoURL != nil else { return }
            self.isPlaying = !paused
        }
        mpv.onError = { [weak self] message in
            guard let self else { return }
            self.playbackErrorMessage = "Couldn't play this video: \(message)"
            self.isPlaying = false
        }

        // Let the subtitle generator surface its internal phases (model
        // download, transcription) in the status row.
        subtitleGenerator.onStatus = { [weak self] status in
            self?.statusMessage = status
        }

        Task { @MainActor in
            await self.refreshInstalledSpeechLocales()
        }
    }

    // MARK: Speech model management

    @MainActor
    func refreshInstalledSpeechLocales() async {
        let installed = await SpeechTranscriber.installedLocales
        installedSpeechLocaleIdentifiers = Set(installed.map { $0.identifier(.bcp47) })
    }

    /// Called when the user picks a transcription language: if its on-device
    /// speech model isn't installed yet, download it right away (instead of
    /// surprising the user with a long stall when they hit Generate).
    func ensureSpeechModelDownloaded() {
        let locale = subtitleLanguage
        let bcp47 = locale.identifier(.bcp47)
        guard !installedSpeechLocaleIdentifiers.contains(bcp47),
              !isGeneratingSubtitles else { return }

        Task { @MainActor in
            let supported = await SpeechTranscriber.supportedLocales
                .contains { $0.identifier(.bcp47) == bcp47 }
            guard supported else { return } // legacy-engine language; nothing to pre-download

            let name = locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
            do {
                let transcriber = SpeechTranscriber(
                    locale: locale,
                    transcriptionOptions: [],
                    reportingOptions: [],
                    attributeOptions: [.audioTimeRange]
                )
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    self.statusMessage = "Downloading speech model for \(name)… (one-time)"
                    print("SuperResVideoPlayer: downloading speech model for \(bcp47)…")
                    try await request.downloadAndInstall()
                    print("SuperResVideoPlayer: speech model for \(bcp47) installed")
                }
                await self.refreshInstalledSpeechLocales()
                self.statusMessage = nil
            } catch {
                self.statusMessage = nil
                self.subtitleErrorMessage = "Couldn't download the speech model for \(name): \(error.localizedDescription)"
            }
        }
    }

    // MARK: File loading

    /// Presents an NSOpenPanel and loads the chosen file into mpv.
    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Video"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        var types: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi, .mpeg2TransportStream]
        // mpv plays these natively (no conversion) even though AVFoundation can't.
        types += ["mkv", "webm", "flv", "wmv", "m2ts", "ts", "ogm", "vob", "rm", "rmvb"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = types

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.load(url: url)
        }
    }

    func load(url: URL) {
        // A terminal-launched, non-bundled executable inherits the
        // terminal's TCC permissions — fail with a useful message if macOS
        // is blocking the folder.
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            playbackErrorMessage = """
            macOS is blocking access to this file's folder. Grant your \
            terminal access in System Settings > Privacy & Security > \
            Files and Folders (or Full Disk Access), or move the video \
            outside Documents/Desktop/Downloads.
            """
            print("SuperResVideoPlayer: file not readable (likely TCC): \(url.path)")
            return
        }

        videoTitle = url.lastPathComponent
        currentTime = 0
        duration = 0
        currentVideoURL = url
        playbackErrorMessage = nil
        statusMessage = nil // clear any status a superseded operation left behind

        // A new video invalidates any subtitles (and in-flight
        // transcription) generated for the previous one.
        subtitleGenerator.cancel()
        mediaImporter.cancel()
        subtitleGenerationID += 1
        subtitleCues = []
        subtitleGenerationProgress = 0
        subtitleErrorMessage = nil
        isGeneratingSubtitles = false
        translationTask?.cancel()
        translationID += 1
        translatedCues = []
        translationTargetIdentifier = ""
        isTranslatingSubtitles = false

        print("SuperResVideoPlayer: loading \(url.path)")
        mpv.load(url: url)
        isPlaying = true
    }

    // MARK: Transport controls

    func togglePlayPause() {
        if isPlaying {
            mpv.setPaused(true)
            isPlaying = false
        } else {
            // Resuming from the very end: rewind first, otherwise unpausing
            // at EOF (keep-open) just sits on the last frame.
            if duration > 0, currentTime >= duration - 0.05 {
                mpv.seek(to: 0)
                currentTime = 0
            }
            mpv.setPaused(false)
            isPlaying = true
        }
    }

    func seek(toSeconds seconds: Double) {
        mpv.seek(to: seconds)
        currentTime = seconds
    }

    /// Relative seek used by the ←/→ keyboard shortcuts.
    func step(by seconds: Double) {
        guard duration > 0 else { return }
        seek(toSeconds: min(max(0, currentTime + seconds), duration))
    }

    func adjustVolume(by delta: Double) {
        volume = min(100, max(0, volume + delta))
        if volume > 0, isMuted { isMuted = false }   // nudging volume unmutes
    }

    func toggleMute() {
        isMuted.toggle()
    }

    // MARK: AI Subtitle Generator

    /// Transcribes the current video's audio in the background and
    /// populates `subtitleCues`. For containers the Speech framework can't
    /// read (MKV, WebM, ...), the audio track is extracted to a temporary
    /// .m4a first via ffmpeg — fast, and the video itself is untouched.
    func generateSubtitles() {
        guard let url = currentVideoURL, !isGeneratingSubtitles else { return }

        isGeneratingSubtitles = true
        subtitleErrorMessage = nil
        subtitleGenerationProgress = 0
        subtitleGenerationID += 1
        let myGeneration = subtitleGenerationID

        let locale = subtitleLanguage
        let totalDuration = duration

        Task { @MainActor in
            // Extraction (when needed) is roughly the first 15% of the
            // progress bar; transcription fills the rest.
            func extractAudio() async throws -> URL {
                let audioURL = try await mediaImporter.extractAudio(from: url) { [weak self] progress in
                    guard let self, self.subtitleGenerationID == myGeneration else { return }
                    self.subtitleGenerationProgress = progress * 0.15
                }
                print("SuperResVideoPlayer: extracted audio to \(audioURL.path)")
                return audioURL
            }

            func transcribe(_ audioURL: URL, progressBase: Double) async throws -> [SubtitleCue] {
                try await subtitleGenerator.generate(
                    for: audioURL,
                    locale: locale,
                    totalDuration: totalDuration
                ) { [weak self] progress in
                    guard let self, self.subtitleGenerationID == myGeneration else { return }
                    self.subtitleGenerationProgress = progressBase + progress * (1 - progressBase)
                }
            }

            do {
                let cues: [SubtitleCue]
                // The speech engines read via AVAudioFile, which can't open
                // video containers (mp4/mov included) — only pure audio
                // files. So extract audio first for anything that isn't
                // already an audio file.
                if !MediaImporter.isPureAudioFile(url) {
                    self.statusMessage = "Extracting audio track…"
                    let audioURL = try await extractAudio()
                    guard self.subtitleGenerationID == myGeneration else { return }
                    self.statusMessage = "Transcribing audio…"
                    cues = try await transcribe(audioURL, progressBase: 0.15)
                } else {
                    do {
                        self.statusMessage = "Transcribing audio…"
                        cues = try await transcribe(url, progressBase: 0)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let underlying where MediaImporter.isFFmpegAvailable {
                        // The file looked Speech-readable but wasn't (e.g. a
                        // mislabeled container) — extract audio and retry once.
                        print("SuperResVideoPlayer: transcription failed on original file (\(underlying.localizedDescription)); retrying with extracted audio")
                        guard self.subtitleGenerationID == myGeneration else { return }
                        self.statusMessage = "Extracting audio track…"
                        let audioURL = try await extractAudio()
                        guard self.subtitleGenerationID == myGeneration else { return }
                        self.statusMessage = "Transcribing audio…"
                        cues = try await transcribe(audioURL, progressBase: 0.15)
                    }
                }
                guard self.subtitleGenerationID == myGeneration else { return }
                self.translatedCues = [] // stale for the new cues; ContentView retranslates if a target is set
                self.subtitleCues = cues
                self.subtitlesEnabled = true
                self.isGeneratingSubtitles = false
                self.statusMessage = nil
                // Generation may have installed a model as a side effect.
                await self.refreshInstalledSpeechLocales()
            } catch {
                guard self.subtitleGenerationID == myGeneration else { return }
                self.statusMessage = nil
                if let importError = error as? MediaImportError, case .cancelled = importError {
                    self.isGeneratingSubtitles = false
                    return
                }
                self.subtitleErrorMessage = error.localizedDescription
                self.isGeneratingSubtitles = false
            }
        }
    }

    /// Stops an in-flight transcription (or the audio extraction preceding it).
    func cancelSubtitleGeneration() {
        subtitleGenerator.cancel()
        mediaImporter.cancel()
        subtitleGenerationID += 1
        isGeneratingSubtitles = false
        subtitleGenerationProgress = 0
        statusMessage = nil
    }

    // MARK: Enhanced video export

    /// Prompts for a destination, then re-renders the whole video offline
    /// with the current Super Resolution / frame interpolation settings.
    /// `durationLimit` (seconds) caps the render — used by the test export
    /// to preview the current engine settings quickly.
    func exportEnhancedVideo(durationLimit: Double? = nil) {
        guard let source = currentVideoURL, !isExportingVideo else { return }

        let panel = NSSavePanel()
        let baseName = (videoTitle as NSString).deletingPathExtension
        let stem = baseName.isEmpty ? "Enhanced" : baseName
        if let durationLimit {
            panel.title = "Export Test Clip (\(Int(durationLimit))s)"
            panel.nameFieldStringValue = "\(stem) (test).mp4"
        } else {
            panel.title = "Export Enhanced Video"
            panel.nameFieldStringValue = "\(stem) (enhanced).mp4"
        }
        panel.allowedContentTypes = [.mpeg4Movie]

        panel.begin { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else { return }
            self.startVideoExport(source: source, destination: destination, durationLimit: durationLimit)
        }
    }

    private func startVideoExport(source: URL, destination: URL, durationLimit: Double? = nil) {
        isExportingVideo = true
        exportProgress = 0
        playbackErrorMessage = nil

        let configuration = VideoExporter.Configuration(
            superResolutionEnabled: superResolutionEnabled,
            upscaleFactor: upscaleFactor,
            frameInterpolationMultiplier: frameInterpolationMultiplier,
            imageEnhancementEnabled: imageEnhancementEnabled,
            enhancementEngine: enhancementEngine,
            enhancementStrength: enhancementStrength,
            durationLimitSeconds: durationLimit
        )
        let exporter = VideoExporter()
        videoExporter = exporter
        let importer = MediaImporter()
        exportImporter = importer

        // Free up decode/GPU bandwidth while exporting.
        if isPlaying { togglePlayPause() }

        Task { @MainActor in
            defer {
                self.isExportingVideo = false
                self.statusMessage = nil
                self.videoExporter = nil
                self.exportImporter = nil
            }
            func runExport(from readableSource: URL, using activeExporter: VideoExporter) async throws {
                self.statusMessage = "Exporting video… 0.00% (interpolation makes this slower than real time)"
                let exportStart = Date()
                try await activeExporter.export(source: readableSource, to: destination,
                                                configuration: configuration) { [weak self] progress in
                    guard let self, self.isExportingVideo else { return }
                    self.exportProgress = progress
                    var text = String(format: "Exporting video… %.2f%%", progress * 100)
                    if progress > 0.001 {
                        let elapsed = Date().timeIntervalSince(exportStart)
                        let remaining = elapsed / progress - elapsed
                        text += String(format: " — about %.0f min left", max(remaining / 60, 1))
                    }
                    self.statusMessage = text
                }
            }

            do {
                var readableSource = source
                // AVAssetReader can't open MKV/WebM/... — repackage first
                // (stream copy where possible, so this is usually fast).
                if MediaImporter.needsAudioExtraction(source) {
                    self.statusMessage = "Repackaging video for export…"
                    readableSource = try await importer.remuxVideoToMP4(from: source) { [weak self] progress in
                        guard let self, self.isExportingVideo else { return }
                        self.statusMessage = "Repackaging video for export… \(Int(progress * 100))%"
                    }
                }

                do {
                    try await runExport(from: readableSource, using: exporter)
                } catch let error as VideoExportError {
                    // AVAssetReader can't decode some streams (e.g. 10-bit
                    // HEVC) even from an .mp4. Our pipeline is 8-bit anyway,
                    // so transcode to a baseline H.264 8-bit intermediate
                    // and retry once.
                    guard case .unreadableSource = error, MediaImporter.isFFmpegAvailable else { throw error }
                    print("SuperResVideoPlayer: export reader failed (\(error.localizedDescription)); transcoding to a compatible format and retrying")
                    self.statusMessage = "Preparing source for export…"
                    let compatible = try await importer.transcodeForExport(from: readableSource) { [weak self] progress in
                        guard let self, self.isExportingVideo else { return }
                        self.statusMessage = "Preparing source for export… \(Int(progress * 100))%"
                    }
                    let retryExporter = VideoExporter()
                    self.videoExporter = retryExporter
                    try await runExport(from: compatible, using: retryExporter)
                }
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                if let exportError = error as? VideoExportError, case .cancelled = exportError { return }
                if let importError = error as? MediaImportError, case .cancelled = importError { return }
                self.playbackErrorMessage = error.localizedDescription
            }
        }
    }

    func cancelVideoExport() {
        videoExporter?.cancel()
        exportImporter?.cancel()
    }

    /// Returns the subtitle line that should be visible at `time`, if any
    /// (the translated line, when translation is active).
    func subtitleText(at time: Double) -> String? {
        guard subtitlesEnabled else { return nil }
        return displayedSubtitleCues.first(where: { time >= $0.startTime && time <= $0.endTime })?.text
    }

    // MARK: Subtitle translation

    private var translationTask: Task<Void, Never>?
    private var translationID = 0

    /// (Re)starts translation of the current cues into
    /// `translationTargetIdentifier` using the on-device Apple Intelligence
    /// model. Called whenever the target language or the cues change.
    /// Timings are preserved; only the text changes. Translations appear
    /// incrementally, batch by batch.
    func startSubtitleTranslation() {
        translationTask?.cancel()
        translationID += 1
        let myID = translationID

        translatedCues = []
        isTranslatingSubtitles = false

        let target = translationTargetIdentifier
        guard !target.isEmpty, !subtitleCues.isEmpty else {
            statusMessage = nil
            return
        }

        let cues = subtitleCues
        let sourceLocale = subtitleLanguage
        isTranslatingSubtitles = true
        statusMessage = "Translating subtitles with Apple Intelligence…"
        print("SuperResVideoPlayer: translating \(cues.count) cues to \(target) via Apple Intelligence")

        subtitleErrorMessage = nil
        translationTask = Task { @MainActor in
            var working = cues
            do {
                let untranslated = try await SubtitleTranslator.translate(
                    cues: cues,
                    sourceLocale: sourceLocale,
                    targetIdentifier: target
                ) { updates, completedCount in
                    guard self.translationID == myID else { return }
                    for (index, text) in updates {
                        working[index] = SubtitleCue(
                            startTime: working[index].startTime,
                            endTime: working[index].endTime,
                            text: text
                        )
                    }
                    // Publish progressively so translated lines show up
                    // while the rest are still being processed.
                    self.translatedCues = working
                    self.statusMessage = "Translating subtitles… \(completedCount)/\(cues.count)"
                }
                guard self.translationID == myID else { return }
                self.isTranslatingSubtitles = false
                self.statusMessage = nil
                print("SuperResVideoPlayer: translation finished (\(untranslated) line(s) skipped)")
                if untranslated > 0 {
                    self.subtitleErrorMessage = "\(untranslated) line(s) kept their original text (blocked by the on-device model's content filter)."
                }
            } catch is CancellationError {
                // Superseded by a newer request or switched off.
            } catch {
                guard self.translationID == myID else { return }
                print("SuperResVideoPlayer: translation failed: \(error)")
                self.isTranslatingSubtitles = false
                self.statusMessage = nil
                self.translatedCues = []
                self.subtitleErrorMessage = error.localizedDescription
            }
        }
    }

    /// Prompts for a save location and writes the current cues as a .srt file.
    func exportSRT() {
        guard !subtitleCues.isEmpty else { return }

        let panel = NSSavePanel()
        panel.title = "Export Subtitles"
        let baseName = (videoTitle as NSString).deletingPathExtension
        panel.nameFieldStringValue = baseName.isEmpty ? "Subtitles.srt" : "\(baseName).srt"
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]

        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let content = SubtitleExporter.srt(from: self.displayedSubtitleCues)
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self.subtitleErrorMessage = "Couldn't save the .srt file: \(error.localizedDescription)"
            }
        }
    }
}
