# SuperResVideoPlayer

A native macOS video player that plays (almost) anything and enhances it in
real time:

- **Plays every format** — MKV, WebM, AVI, FLAC audio, and everything else
  ffmpeg understands, via an embedded **libmpv** engine (the same engine
  that powers [IINA](https://github.com/iina/iina) and mpv). No conversion,
  no transcoding.
- **AI Image Enhancer** — clean up and reconstruct detail *without changing
  resolution*, applied before Super Resolution. Three engines:
  - **Classic** — one compute pass: edge-aware denoise + contrast-adaptive
    sharpening. Near-free, realtime.
  - **Neural** — MetalFX ML scaler reconstructs at 2x, then Lanczos
    resamples back to native (supersampling). Realtime on Apple Silicon.
  - **Max** — Real-ESRGAN (`realesr-animevideov3`) via Core ML, **export
    only** (too heavy for live playback). One-time install:
    `bash convert-model.sh`.
- **Super Resolution** — real-time upscaling (1.3x / 1.5x / 2.0x) with
  Apple's **MetalFX Spatial Scaler**.
- **AI Frame Interpolation** — 2x/3x motion smoothing: Vision optical flow
  drives Apple's native **MTLFXFrameInterpolator** (2x midpoints) or a
  custom motion-compensated warp kernel (3x, and fallback).
- **AI Subtitles** — on-device transcription with the macOS 26
  **SpeechAnalyzer/SpeechTranscriber** API (long-form audio, per-word
  timestamps), with legacy `SFSpeechRecognizer` as a fallback for extra
  languages. Language models download on demand; installed ones show
  "(downloaded)" in the picker.
- **AI Subtitle Translation** — translate the generated subtitles (e.g.
  Japanese audio → Traditional Chinese subtitles) fully on-device with the
  **Apple Intelligence** foundation model (`FoundationModels` framework),
  batch by batch, with a permissive content-transformation guardrail
  profile suited to translating existing media.
- **Enhanced video export** — re-render the whole file offline with Super
  Resolution and frame interpolation applied, encoded to HEVC `.mp4` with
  audio passed through. Unlike playback (which skips interpolation when
  optical flow can't keep up in real time), export computes flow for every
  frame pair.
- **.srt export** of the generated (or translated) subtitles.
- A live **pipeline stats** readout (input→output resolution, real vs.
  synthesized frames per second, which interpolation engine is active) so
  you can verify the enhancements are actually running.

## Requirements

- Apple Silicon Mac (MetalFX requires an Apple-family GPU).
- **macOS 26 "Tahoe" or later** — hard floor for `MTLFXFrameInterpolator`
  (Metal 4) and the SpeechAnalyzer API.
- Xcode 26+ / a Swift 6.2+ toolchain to build.
- **libmpv**: `brew install mpv`
- Optional: `brew install ffmpeg` — used only to extract audio for subtitle
  generation from containers Apple's Speech framework can't read (MKV,
  WebM, ...), and to repackage such containers for export. Playback itself
  never needs it.
- Subtitle translation requires **Apple Intelligence** to be enabled
  (System Settings > Apple Intelligence & Siri).
- The **Max** image-enhancer engine requires the Real-ESRGAN Core ML model.
  Install it once with `bash convert-model.sh` (needs `python3`; downloads
  the ~2.4 MB weights and converts them into
  `~/Library/Application Support/SuperResVideoPlayer/RealESRGAN.mlpackage`).
  Without it, Classic and Neural still work.

## Build & run

```sh
bash make-app.sh
```

This builds the Swift package, wraps it in a minimal `.app` bundle
(several macOS features — TCC permission prompts, model-download dialogs —
require a real bundle identity), ad-hoc signs it, and launches it with logs
in your terminal.

To produce a **self-contained, shareable app** (libmpv and its dependency
tree bundled into `Contents/Frameworks`, ffmpeg/ffprobe into
`Contents/Helpers` — recipients install nothing):

```sh
bash make-dist.sh   # → dist/SuperResVideoPlayer.app + dist/SuperResVideoPlayer.zip
```

Recipients need Apple Silicon + macOS 26, and must right-click > Open on
first launch (the app is ad-hoc signed, not notarized).

## How it works

```
libmpv (demux + decode + audio + A/V sync)
   └─ software render API → BGRA CVPixelBuffer   (MPVPlayer.swift, dedicated queue)
        └─ zero-copy Metal texture wrap           (Renderer.swift, MTKView draw loop)
             ├─ AI Frame Interpolation            (Vision optical flow → MetalFX / warp kernel)
             ├─ MetalFX Super Resolution          (spatial scaler)
             └─ draw to screen                    (full-screen triangle, Shaders.metal)
```

- `MPVPlayer` embeds libmpv with `vo=libmpv` and the *software* render API:
  mpv renders decoded frames into CPU-visible pixel buffers on a dedicated
  queue (never on the UI/draw path), which the Metal renderer wraps
  zero-copy and enhances. IINA instead lets mpv draw straight into the
  view via OpenGL; this app needs each frame as a texture for MetalFX, at
  the cost of one extra copy.
- `Renderer` keeps the last two real frames plus Vision's optical flow
  field for the pair, and on every display refresh either shows a real
  frame or synthesizes the in-between one (MetalFX for 2x midpoints, warp
  kernel otherwise), then optionally upscales. Synthesized frames are
  cached per (pair, phase) so 120Hz refresh doesn't re-encode identical
  work.
- Subtitles: audio is transcribed on-device (extracted to a temp `.m4a`
  first when the container needs it); word timings are grouped into cues by
  a pause/length heuristic (CJK-aware). Translation rewrites cue text in
  batches of 15 through the on-device language model, with per-line retry
  when a batch is rejected or garbled.
- Export: `AVAssetReader` → the same Metal pipeline (flow computed per
  pair, synchronously) → `AVAssetWriter` (HEVC, writer-driven
  `requestMediaDataWhenReady` with video and audio fed concurrently for
  interleaving).

## Known limitations

- Frame interpolation is repurposed game tech: motion vectors come from
  optical flow (not a game engine) and depth is a flat constant, so expect
  ghosting around fast/complex motion, especially at 3x. During playback,
  interpolation only engages when Vision keeps up in real time — the stats
  line shows the live synth rate; export always interpolates every pair.
- Export ignores rotation metadata and doesn't tag HDR color primaries —
  fine for typical SDR files, wrong for rotated phone footage or HDR.
- The cue-grouping heuristic is pause/length-based, not linguistic; breaks
  won't always land on natural phrase boundaries.
- Subtitle translation quality is "on-device LLM" grade — good for
  following along, not fansub grade. A few lines may be skipped by the
  model's content filter (they keep the original text; the UI reports how
  many).
- The video render path is 8-bit BGRA without color management; HDR
  sources are tone-mapped by mpv to SDR.

## File map

```
Package.swift                 — SPM manifest (Cmpv system library + executable)
Info.plist                    — bundle metadata + TCC usage strings
make-app.sh                   — debug build → minimal .app → run
make-dist.sh                  — release build → self-contained shareable .app/.zip
convert-model.sh              — one-time Real-ESRGAN → Core ML install (Max engine)
convert_model.py              — SRVGGNetCompact → .mlpackage conversion
Sources/Cmpv/                 — libmpv module map (pkg-config: mpv)
Sources/SuperResVideoPlayer/
  SuperResVideoPlayerApp.swift — @main; foreground-app activation
  ContentView.swift            — UI: player, controls, subtitle overlay, status rows
  PlayerViewModel.swift        — app state; wires mpv/subtitles/translation/export
  MPVPlayer.swift              — libmpv embedding (render queue, event thread)
  MetalVideoView.swift         — NSViewRepresentable hosting the MTKView
  Renderer.swift               — frame history, interpolation routing, SR, stats, draw
  FrameInterpolator.swift      — MTLFXFrameInterpolator wrapper (2x midpoints)
  OpticalFlow.swift            — Vision optical flow → Metal motion texture (playback)
  Shaders.metal                — blit shaders + enhance/clear-depth/warp-blend kernels
  EnhancementProcessor.swift   — Image Enhancer: Classic + Neural (MetalFX) engines
  NeuralEnhancer.swift         — Image Enhancer: Max engine (Real-ESRGAN via Core ML)
  SubtitleGenerator.swift      — SpeechAnalyzer (+ legacy fallback) → cues
  SubtitleTranslator.swift     — Apple Intelligence batch translation
  SubtitleCue.swift            — cue model + .srt formatting
  MediaImporter.swift          — ffmpeg helpers: audio extraction / export remux
  VideoExporter.swift          — offline enhance-and-encode pipeline
```

## Licenses

The source in this repository is the author's. Binary distributions built
with `make-dist.sh` bundle [mpv/libmpv](https://mpv.io) and
[FFmpeg](https://ffmpeg.org) (Homebrew builds, GPL-enabled) — if you
redistribute the bundled app, GPL obligations apply to those components.

The **Max** engine uses the [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN)
`realesr-animevideov3` model (BSD-3-Clause, Xintao Wang et al.). The model
is downloaded/converted locally by `convert-model.sh` and is **not**
included in this repository or in `make-dist.sh` bundles.
