// swift-tools-version:6.4
// (6.4+ is required for PackageDescription to expose `.macOS(.v27)` below;
// ships with the Xcode 27 toolchain.)
import PackageDescription
import Foundation

// Resolve Info.plist relative to this manifest file's own location (not the
// current working directory), so the linker flag below works whether the
// package is built with `swift build` from an arbitrary directory or opened
// directly in Xcode (which uses a different working directory at link time).
let infoPlistPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Info.plist")
    .path

let package = Package(
    name: "SuperResVideoPlayer",
    platforms: [
        // Targets macOS 27, built against the macOS 27 SDK. Requires the
        // Xcode 27 toolchain to be the *active* one — if `.v27` fails to
        // resolve, run `sudo xcode-select -s /Applications/Xcode-beta.app`
        // (the build is still picking up the 26.x SDK otherwise).
        .macOS(.v27)
    ],
    targets: [
        // libmpv (the engine inside mpv/IINA) handles demuxing and decoding
        // of every container/codec ffmpeg supports — MKV, WebM, FLAC, ... —
        // natively, with no conversion step. Install it with:
        //     brew install mpv
        // pkg-config (via mpv.pc) supplies the header/library search paths.
        .systemLibrary(
            name: "Cmpv",
            path: "Sources/Cmpv",
            pkgConfig: "mpv",
            providers: [.brew(["mpv"])]
        ),
        // Dependency-free library holding the pure logic (subtitle grouping,
        // .srt formatting, translation parsing, media classification) so it
        // can be unit-tested without AVFoundation/Speech/Metal.
        .target(
            name: "SuperResCore",
            path: "Sources/SuperResCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SuperResCoreTests",
            dependencies: ["SuperResCore"],
            path: "Tests/SuperResCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SuperResVideoPlayer",
            dependencies: ["Cmpv", "SuperResCore"],
            path: "Sources/SuperResVideoPlayer",
            resources: [
                // Ship the raw shader source in the module's resource
                // bundle. Xcode compiles .metal resources into a
                // default.metallib, but command-line `swift build` does NOT
                // — it just copies the file. Renderer.loadShaderLibrary()
                // handles both: it tries the precompiled metallib first,
                // then compiles this source at runtime. `.copy` (not
                // `.process`) guarantees the raw file is present verbatim.
                .copy("Shaders.metal")
            ],
            swiftSettings: [
                // tools-version 6.x defaults to Swift 6 language mode
                // (strict concurrency), which this codebase isn't audited
                // for — it uses manual locking (NSLock) and main-queue hops
                // instead. Stay in Swift 5 mode until a proper Sendable/
                // actor-isolation pass is done.
                .swiftLanguageMode(.v5),
                // Fallback header search paths for libmpv when pkg-config
                // isn't installed (SwiftPM then can't resolve mpv.pc).
                // Harmless if the directories don't exist.
                .unsafeFlags([
                    "-Xcc", "-I/opt/homebrew/include",   // Homebrew, Apple Silicon
                    "-Xcc", "-I/usr/local/include"       // Homebrew, Intel
                ])
            ],
            linkerSettings: [
                // Fallback library search paths, same reason as above.
                .unsafeFlags([
                    "-L/opt/homebrew/lib",
                    "-L/usr/local/lib"
                ]),
                // Embeds Info.plist (at the package root) into the binary's
                // __TEXT,__info_plist section. Plain SPM executables don't
                // get an Info.plist the way an .app bundle does, but the
                // Speech framework (used by the AI Subtitle Generator)
                // still requires NSSpeechRecognitionUsageDescription to be
                // discoverable there, or macOS kills the process instead of
                // prompting for permission. This is the standard workaround
                // for CLI-style Swift executables that need a TCC privacy
                // permission. If you convert this to a proper Xcode "App"
                // target later, use its native Info.plist instead and you
                // can drop this.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlistPath
                ])
            ]
        )
    ]
)
