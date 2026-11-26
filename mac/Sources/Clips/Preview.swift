import AppKit
import AVFoundation
import AVKit

/// Plays a recording straight from its raw tracks, so you can watch it the moment you stop, while
/// render.py is still making clip.mp4. Screen, camera in its spot, mic and computer audio at the saved
/// levels. It skips the cursor polish and the rounded camera corners; the posted clip has those.
nonisolated(unsafe) private var sourcesKey: UInt8 = 0

enum QuickPreview {
    @MainActor static func item(for folder: URL) async -> AVPlayerItem? {
        let rec = folder.appendingPathComponent("recording")
        func file(_ name: String) -> URL? {
            let u = rec.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
        // A composition only points at its sources, so keep each AVURLAsset alive until it's built.
        var keep: [AVURLAsset] = []
        func track(_ u: URL, _ type: AVMediaType) async -> AVAssetTrack? {
            let a = AVURLAsset(url: u)
            keep.append(a)
            return try? await a.loadTracks(withMediaType: type).first
        }
        guard let screenURL = file("channel-2-display-0.mp4"), let screenSrc = await track(screenURL, .video)
        else { return nil }

        let meta = (try? Data(contentsOf: rec.appendingPathComponent("metadata.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let levels = meta["audio"] as? [String: Double] ?? [:]
        let camCfg = (meta["recorders"] as? [[String: Any]])?
            .first { $0["id"] as? String == "channel-4-webcam" }?["configuration"] as? [String: Double]

        let comp = AVMutableComposition()
        // Each track goes in at its own start time, which is how the recorder lines them up.
        func add(_ src: AVAssetTrack, _ type: AVMediaType) async -> AVMutableCompositionTrack? {
            guard let range = try? await src.load(.timeRange),
                  let t = comp.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid),
                  (try? t.insertTimeRange(range, of: src, at: range.start)) != nil else { return nil }
            return t
        }
        guard let screen = await add(screenSrc, .video) else { return nil }
        let W = (try? await screenSrc.load(.naturalSize))?.width ?? 1920
        let H = (try? await screenSrc.load(.naturalSize))?.height ?? 1080

        var layers: [AVMutableVideoCompositionLayerInstruction] = []
        if let camURL = file("channel-4-webcam-0.mp4"), let cfg = camCfg, let size = cfg["size"],
           let camSrc = await track(camURL, .video),
           let cam = await add(camSrc, .video), let n = try? await camSrc.load(.naturalSize) {
            // Same as render.py: a centred square of the camera, size × screen width, at (x, y) from top-left.
            let side = min(n.width, n.height), S = (size * W).rounded()
            let crop = CGRect(x: (n.width - side) / 2, y: (n.height - side) / 2, width: side, height: side)
            let li = AVMutableVideoCompositionLayerInstruction(assetTrack: cam)
            li.setCropRectangle(crop, at: .zero)
            li.setTransform(CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
                .concatenating(CGAffineTransform(scaleX: S / side, y: S / side))
                .concatenating(CGAffineTransform(translationX: ((cfg["x"] ?? 0) * W).rounded(), y: ((cfg["y"] ?? 0) * H).rounded())),
                            at: .zero)
            layers.append(li)
        }
        layers.append(AVMutableVideoCompositionLayerInstruction(assetTrack: screen))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
        instruction.layerInstructions = layers
        let video = AVMutableVideoComposition()
        video.renderSize = CGSize(width: W, height: H)
        video.frameDuration = CMTime(value: 1, timescale: 30)
        video.instructions = [instruction]

        var params: [AVMutableAudioMixInputParameters] = []
        for (name, volume) in [("channel-3-microphone-0.m4a", levels["micVolume"] ?? 1),
                               ("channel-1-system-audio-0.m4a", levels["systemVolume"] ?? 0.5)] {
            guard let u = file(name), let src = await track(u, .audio),
                  let t = await add(src, .audio) else { continue }
            let p = AVMutableAudioMixInputParameters(track: t)
            p.setVolume(Float(volume), at: .zero)
            params.append(p)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = params

        let item = AVPlayerItem(asset: comp)
        item.videoComposition = video
        item.audioMix = mix
        objc_setAssociatedObject(item, &sourcesKey, keep, .OBJC_ASSOCIATION_RETAIN)   // sources live as long as the item
        return item
    }
}

extension AppDelegate {
    /// The bar's play button: the finished clip once it's rendered, the quick preview before that.
    @MainActor func watch(_ u: Upload) {
        if u.localReady { NSWorkspace.shared.open(u.localFile); return }
        Task { @MainActor in
            guard let item = await QuickPreview.item(for: u.folder) else {
                NSSound.beep(); return
            }
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let v = screen.visibleFrame
            let w = min(1280, v.width * 0.7)
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: w * 9 / 16),
                               styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            win.title = "\(u.title) (preview while it renders)"
            win.isReleasedWhenClosed = false
            let view = AVPlayerView()
            view.controlsStyle = .floating
            let player = AVPlayer(playerItem: item)
            view.player = player
            win.contentView = view
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: .main) { [weak self] _ in
                player.pause()
                MainActor.assumeIsolated { self?.previews.removeAll { $0 === win } }
            }
            previews.append(win)
            win.center()
            NSApp.activate()
            win.makeKeyAndOrderFront(nil)
            player.play()
        }
    }
}
