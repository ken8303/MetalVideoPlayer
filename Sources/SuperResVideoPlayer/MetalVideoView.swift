import SwiftUI
import MetalKit

/// Bridges an MTKView (driven by `Renderer`) into SwiftUI.
struct MetalVideoView: NSViewRepresentable {
    @ObservedObject var playerViewModel: PlayerViewModel

    func makeCoordinator() -> Renderer {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("SuperResVideoPlayer: no Metal-capable GPU found on this Mac.")
        }
        return Renderer(device: device, playerViewModel: playerViewModel)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.device
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        // Frame interpolation needs the view to redraw faster than the
        // source video's own frame rate so the synthesized in-between
        // frames actually get displayed. 120fps gives headroom for both the
        // 2x and 3x modes on ProMotion displays; on 60Hz displays this just
        // clamps to 60.
        nsView.preferredFramesPerSecond = playerViewModel.frameInterpolationMultiplier > 1 ? 120 : 60

        // Push a thread-safe snapshot of the view model's state to the
        // renderer. Renderer.draw(in:) runs on MTKView's render thread and
        // must not read @Published properties directly (data race with
        // main-thread writes) — this is its only supported handoff point.
        context.coordinator.sync(with: playerViewModel)
    }
}
