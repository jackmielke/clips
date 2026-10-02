import AppKit
import SwiftUI
import AVFoundation
import Carbon.HIToolbox
import Combine

/// A floating, non-activating panel: it never steals focus from what you're recording.
final class FloatingPanel: NSPanel {
    init(size: NSSize, movable: Bool) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = movable
        hidesOnDeactivate = false
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Live preview of the camera, at exactly the size and spot it will have in the finished video.
final class BubbleView: NSView {
    let preview: AVCaptureVideoPreviewLayer
    private let hideButton = NSButton()
    var onHide: (() -> Void)?
    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        hideButton.image = NSImage(systemSymbolName: "eye.slash.fill", accessibilityDescription: "Hide camera")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        hideButton.isBordered = false
        hideButton.contentTintColor = .white
        hideButton.wantsLayer = true
        hideButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        hideButton.layer?.cornerRadius = 14
        hideButton.toolTip = "Turn camera off"
        hideButton.target = self
        hideButton.action = #selector(hideTapped)
        hideButton.alphaValue = 0
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        layer?.backgroundColor = NSColor.black.cgColor
        preview.videoGravity = .resizeAspectFill
        layer?.addSublayer(preview)
        addSubview(hideButton)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func hideTapped() { onHide?() }
    override var mouseDownCanMoveWindow: Bool { true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { NSAnimationContext.runAnimationGroup { $0.duration = 0.15; hideButton.animator().alphaValue = 1 } }
    override func mouseExited(with e: NSEvent) { NSAnimationContext.runAnimationGroup { $0.duration = 0.2; hideButton.animator().alphaValue = 0 } }
    override func layout() {
        super.layout()
        hideButton.frame = NSRect(x: bounds.maxX - 40, y: bounds.maxY - 40, width: 28, height: 28)
        preview.frame = bounds
        layer?.cornerRadius = bounds.width * 70 / 600
        if let c = preview.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MainActor.assumeIsolated { AppModel() }
    var bar: FloatingPanel!
    var bubble: FloatingPanel!
    var countdown: FloatingPanel!
    var status: NSStatusItem!
    var hotKey: EventHotKeyRef?
    var subs = Set<AnyCancellable>()
    var userMovedBar = false

    /// clips://toggle, clips://start, clips://stop, clips://show — for Raycast, Shortcuts, voice, and Claude.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls {
                switch url.host {
                case "toggle": model.toggle()
                case "start": if case .recording = model.phase {} else { model.startCountdown() }
                case "stop": if case .recording = model.phase { model.stop() }
                default: break
                }
                showBar()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { showBar() }
        return false
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        MainActor.assumeIsolated { setUp() }
    }

    @MainActor private func setUp() {
        // Bar
        let host = NSHostingView(rootView: ControlBar(m: model, hide: { [weak self] in self?.hideBar() }))
        host.sizingOptions = [.intrinsicContentSize]
        bar = FloatingPanel(size: host.fittingSize, movable: true)
        bar.contentView = host
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: bar, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepBarCentered() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: bar, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.placing == false { self?.userMovedBar = true } }
        }

        // Camera bubble
        bubble = FloatingPanel(size: NSSize(width: 300, height: 300), movable: true)
        let bv = BubbleView(session: model.camera.session)
        bv.onHide = { [weak self] in self?.model.cameraOn = false }
        bubble.contentView = bv
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: bubble, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.bubbleMoved() }
        }

        // Countdown
        countdown = FloatingPanel(size: NSSize(width: 400, height: 400), movable: false)
        countdown.ignoresMouseEvents = true
        countdown.contentView = NSHostingView(rootView: CountdownView(m: model))

        // Menu bar
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Clips")
        status.button?.target = self
        status.button?.action = #selector(statusClicked)
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        model.onLayoutChange = { [weak self] in self?.layout() }
        model.$phase.sink { [weak self] phase in
            DispatchQueue.main.async { self?.phaseChanged(phase) }
        }.store(in: &subs)

        let menu = NSMenu(), appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Show Recording Bar", action: #selector(showBarAction), keyEquivalent: "n").target = self
        appMenu.addItem(withTitle: "Library", action: #selector(openSite), keyEquivalent: "l").target = self
        appMenu.addItem(withTitle: "Recordings Folder", action: #selector(openLibrary), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Clips", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = menu

        registerHotKey()
        model.applyCamera()
        layout()
        bar.orderFrontRegardless()
    }

    private var placing = false
    private var placingBubble = false
    @MainActor private var isRecording: Bool { if case .recording = model.phase { return true }; return false }

    /// Top-left-origin fractions of the screen, which is what render.py and the saved spot use.
    @MainActor private func normalized(_ r: NSRect, in f: NSRect) -> CGRect {
        CGRect(x: (r.minX - f.minX) / f.width, y: (f.maxY - r.maxY) / f.height, width: r.width / f.width, height: r.height / f.height)
    }

    @MainActor private func bubbleMoved() {
        guard !placingBubble, let f = model.display?.frame else { return }
        let n = normalized(bubble.frame, in: f)
        model.cameraRect = n
        model.cameraSpot = CGPoint(x: n.minX, y: n.minY)
    }

    @MainActor func layout() {
        guard let screen = model.display else { return }
        let f = screen.frame
        // Same geometry render.py uses: 600px square, 60px margin, on a 3024px-wide screen.
        let side = (f.width * 600 / 3024).rounded(), margin = (f.width * 60 / 3024).rounded()
        var origin = NSPoint(x: f.maxX - side - margin, y: f.minY + margin)
        if let saved = model.cameraSpot {   // where the user last dragged it, as fractions of the screen
            origin = NSPoint(x: f.minX + saved.x * f.width, y: f.maxY - saved.y * f.height - side)
        }
        origin.x = min(max(origin.x, f.minX), f.maxX - side)
        origin.y = min(max(origin.y, f.minY), f.maxY - side)
        placingBubble = true
        bubble.setFrame(NSRect(origin: origin, size: NSSize(width: side, height: side)), display: true)
        placingBubble = false
        model.cameraRect = normalized(bubble.frame, in: f)
        if model.cameraOn && (bar.isVisible || isRecording) { bubble.orderFrontRegardless() } else { bubble.orderOut(nil) }
        countdown.setFrame(NSRect(x: f.midX - 200, y: f.midY - 200, width: 400, height: 400), display: true)
        userMovedBar = false
        keepBarCentered()
    }

    @MainActor func keepBarCentered() {
        guard let screen = model.display else { return }
        placing = true
        let v = screen.visibleFrame
        let size = bar.frame.size
        if userMovedBar {
            // Keep the centre where the user dragged it while the bar changes width.
            let mid = bar.frame.midX
            bar.setFrameOrigin(NSPoint(x: mid - size.width / 2, y: bar.frame.minY))
        } else {
            bar.setFrameOrigin(NSPoint(x: v.midX - size.width / 2, y: v.minY + 56))
        }
        placing = false
    }

    @MainActor private func phaseChanged(_ p: Phase) {
        bar.setContentSize(bar.contentView!.fittingSize)
        keepBarCentered()
        if case .countdown = p { countdown.orderFrontRegardless() } else { countdown.orderOut(nil) }
        let recording: Bool = { if case .recording = p { return true }; return false }()
        status.button?.image = NSImage(systemSymbolName: recording ? "record.circle.fill" : "record.circle",
                                       accessibilityDescription: "Clips")
        status.button?.contentTintColor = recording ? .systemRed : nil
        if case .done = p { bar.orderFrontRegardless() }
    }

    @MainActor func hideBar() {
        bar.orderOut(nil)
        // Hidden means hidden: the bubble goes and the camera light goes off too.
        if !isRecording { bubble.orderOut(nil); model.camera.setCamera(nil) }
    }

    @MainActor func showBar() {
        bar.orderFrontRegardless()
        model.applyCamera()
        layout()
    }

    @objc func statusClicked() {
        MainActor.assumeIsolated {
            if NSApp.currentEvent?.type == .rightMouseUp {
                let menu = NSMenu()
                menu.addItem(withTitle: "Show Recordings Folder", action: #selector(openLibrary), keyEquivalent: "").target = self
                menu.addItem(withTitle: "Open Library", action: #selector(openSite), keyEquivalent: "").target = self
                menu.addItem(.separator())
                menu.addItem(withTitle: "Quit Clips", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
                status.menu = menu
                status.button?.performClick(nil)
                status.menu = nil
                return
            }
            if case .recording = model.phase { model.stop(); return }
            if bar.isVisible { hideBar() } else { showBar() }
        }
    }

    @objc func openLibrary() {
        try? FileManager.default.createDirectory(at: AppModel.library, withIntermediateDirectories: true)
        NSWorkspace.shared.open(AppModel.library)
    }
    @objc func openSite() { NSWorkspace.shared.open(URL(string: "https://jack-clips.vercel.app/library")!) }
    @objc func showBarAction() { MainActor.assumeIsolated { showBar() } }

    // ⌥⇧R starts and stops a recording from anywhere. Carbon hot keys need no Accessibility grant.
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            let me = Unmanaged<AppDelegate>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if !me.bar.isVisible { me.showBar() }
                    me.model.toggle()
                }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(optionKey | shiftKey), EventHotKeyID(signature: 0x434C5053, id: 1),
                            GetApplicationEventTarget(), 0, &hotKey)
    }
}

