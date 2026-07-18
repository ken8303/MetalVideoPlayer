import SwiftUI

struct ContentView: View {
    @StateObject private var playerViewModel = PlayerViewModel()

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                MetalVideoView(playerViewModel: playerViewModel)
                    .background(Color.black)

                if let text = playerViewModel.subtitleText(at: playerViewModel.currentTime) {
                    Text(text)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                        .padding(.bottom, 24)
                        .padding(.horizontal, 40)
                        .shadow(radius: 2)
                        .allowsHitTesting(false)
                }
            }
            .frame(minWidth: 640, minHeight: 360)

            controls
                .padding()
                .background(.regularMaterial)
        }
        .frame(minWidth: 720, minHeight: 480)
        .navigationTitle(playerViewModel.videoTitle)
        .onChange(of: playerViewModel.translationTargetIdentifier) { _, _ in
            playerViewModel.startSubtitleTranslation()
        }
        .onChange(of: playerViewModel.subtitleLanguage) { _, _ in
            // Start the (one-time) speech model download as soon as a
            // not-yet-installed language is picked.
            playerViewModel.ensureSpeechModelDownloaded()
        }
        .onChange(of: playerViewModel.subtitleCues) { _, _ in
            // Newly generated cues: retranslate if a target is active.
            playerViewModel.startSubtitleTranslation()
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                Text(playerViewModel.videoTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if playerViewModel.isExportingVideo {
                    Button("Cancel Export") {
                        playerViewModel.cancelVideoExport()
                    }
                } else {
                    Button("Test 10s") {
                        playerViewModel.exportEnhancedVideo(durationLimit: 10)
                    }
                    .disabled(playerViewModel.duration == 0)
                    .help("Export just the first 10 seconds — quick way to compare enhancer engines.")

                    Button("Export Video…") {
                        playerViewModel.exportEnhancedVideo()
                    }
                    .disabled(playerViewModel.duration == 0)
                }
                Button("Open Video…") {
                    playerViewModel.presentOpenPanel()
                }
                .disabled(playerViewModel.isExportingVideo)
            }

            if let error = playerViewModel.playbackErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button {
                    playerViewModel.togglePlayPause()
                } label: {
                    Image(systemName: playerViewModel.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 24)
                }
                .disabled(playerViewModel.duration == 0)

                Slider(
                    value: Binding(
                        get: { playerViewModel.currentTime },
                        set: { playerViewModel.seek(toSeconds: $0) }
                    ),
                    in: 0...max(playerViewModel.duration, 0.01),
                    onEditingChanged: { editing in
                        playerViewModel.isScrubbing = editing
                    }
                )
                .disabled(playerViewModel.duration == 0)

                Text(timeString(playerViewModel.currentTime) + " / " + timeString(playerViewModel.duration))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(minWidth: 100, alignment: .trailing)
            }

            Divider()

            HStack {
                Toggle("AI Image Enhancer", isOn: $playerViewModel.imageEnhancementEnabled)

                Spacer()

                Picker("Engine", selection: $playerViewModel.enhancementEngine) {
                    Text("Classic").tag(EnhancerEngine.classic)
                    Text("Neural").tag(EnhancerEngine.neural)
                    Text("Max").tag(EnhancerEngine.max)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
                .disabled(!playerViewModel.imageEnhancementEnabled)

                Slider(value: $playerViewModel.enhancementStrength, in: 0...1)
                    .frame(width: 110)
                    .disabled(!playerViewModel.imageEnhancementEnabled)
                Text("\(Int(playerViewModel.enhancementStrength * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }

            if playerViewModel.imageEnhancementEnabled && playerViewModel.enhancementEngine == .max {
                Text(NeuralEnhancer.isModelAvailable
                     ? "Max (Real-ESRGAN) applies during export — playback previews with the Neural engine."
                     : "Max needs the Real-ESRGAN model: run `bash convert-model.sh` once to install it.")
                    .font(.caption)
                    .foregroundStyle(NeuralEnhancer.isModelAvailable ? Color.secondary : Color.orange)
            }

            HStack {
                Toggle("Super Resolution", isOn: $playerViewModel.superResolutionEnabled)

                Spacer()

                Text("Scale:")
                    .foregroundStyle(.secondary)
                Picker("Scale", selection: $playerViewModel.upscaleFactor) {
                    Text("1.3x").tag(1.3)
                    Text("1.5x").tag(1.5)
                    Text("2.0x").tag(2.0)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .disabled(!playerViewModel.superResolutionEnabled)
            }

            if playerViewModel.superResolutionUnsupported {
                Text("Not supported on this Mac's GPU — the toggle above has no effect.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Text("AI Frame Interpolation")
                Spacer()
                Picker("Smoothing", selection: $playerViewModel.frameInterpolationMultiplier) {
                    Text("Off").tag(1)
                    Text("2x").tag(2)
                    Text("3x").tag(3)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            if playerViewModel.frameInterpolationMultiplier > 1 && playerViewModel.nativeFrameInterpolationUnsupported {
                Text("Native MetalFX interpolation isn't supported here — using the custom warp fallback instead.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let stats = playerViewModel.pipelineStatus {
                Text(stats)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            subtitleControls
        }
    }

    private var subtitleControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Subtitles", isOn: $playerViewModel.subtitlesEnabled)
                    .disabled(playerViewModel.subtitleCues.isEmpty)

                Spacer()

                Picker("Language", selection: $playerViewModel.subtitleLanguage) {
                    ForEach(playerViewModel.availableSubtitleLocales, id: \.identifier) { locale in
                        Text(languageLabel(for: locale))
                            .tag(locale)
                    }
                }
                .frame(width: 200)
                .disabled(playerViewModel.isGeneratingSubtitles)

                if playerViewModel.isGeneratingSubtitles {
                    ProgressView(value: playerViewModel.subtitleGenerationProgress)
                        .frame(width: 90)
                    Button("Cancel") {
                        playerViewModel.cancelSubtitleGeneration()
                    }
                } else {
                    Button("Generate Subtitles") {
                        playerViewModel.generateSubtitles()
                    }
                    .disabled(playerViewModel.duration == 0)

                    Button("Export .srt…") {
                        playerViewModel.exportSRT()
                    }
                    .disabled(playerViewModel.subtitleCues.isEmpty)
                }
            }

            HStack {
                Text("Translate to")
                    .foregroundStyle(.secondary)

                Spacer()

                if playerViewModel.isTranslatingSubtitles {
                    ProgressView()
                        .controlSize(.small)
                }

                Picker("Translate to", selection: $playerViewModel.translationTargetIdentifier) {
                    Text("Off").tag("")
                    Text("Traditional Chinese").tag("zh-Hant")
                    Text("Simplified Chinese").tag("zh-Hans")
                    Text("English").tag("en")
                    Text("Japanese").tag("ja")
                    Text("Korean").tag("ko")
                    Text("Spanish").tag("es")
                    Text("French").tag("fr")
                    Text("German").tag("de")
                }
                .labelsHidden()
                .frame(width: 200)
                .disabled(playerViewModel.subtitleCues.isEmpty || playerViewModel.isGeneratingSubtitles)
            }

            if let status = playerViewModel.statusMessage {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            if let error = playerViewModel.subtitleErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func languageLabel(for locale: Locale) -> String {
        let name = locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        let installed = playerViewModel.installedSpeechLocaleIdentifiers
            .contains(locale.identifier(.bcp47))
        return installed ? "\(name) (downloaded)" : name
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

#Preview {
    ContentView()
}
