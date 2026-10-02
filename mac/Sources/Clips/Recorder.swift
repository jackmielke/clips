import AppKit
import AVFoundation
import ScreenCaptureKit

/// Host-clock milliseconds. Every track and every mouse event is timed against this one clock,
/// so the files line up without any guessing at render time.
func hostNowMs() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds * 1000 }

enum RecorderError: LocalizedError {
    case screenPermission, noDisplay, writer(String)
    var errorDescription: String? {
        switch self {
        case .screenPermission: return "Screen recording is off for Clips"
        case .noDisplay: return "That display is gone"
        case .writer(let w): return w
        }
    }
}

/// One output file with one input. Starts on the first sample at or after `start`, so every
/// file shares the same zero.
final class TrackWriter {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    private var started = false
    private let lock = NSLock()

    init(url: URL, type: AVFileType, input: AVAssetWriterInput) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: type)
        self.input = input
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecorderError.writer("Can't write \(url.lastPathComponent)") }
        writer.add(input)
    }

    func append(_ sb: CMSampleBuffer, start: CMTime) {
        lock.lock(); defer { lock.unlock() }
        guard sb.presentationTimeStamp >= start else { return }
        if !started {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: start)
            started = true
        }
        if writer.status == .writing, input.isReadyForMoreMediaData { input.append(sb) }
    }

    func finish() async {
        lock.lock()
        let wasStarted = started
        lock.unlock()
        guard wasStarted else { return }
        input.markAsFinished()
        await writer.finishWriting()
    }
}

/// Records screen, system audio, camera, mic and the mouse into the same folder layout Screen
/// Studio uses, so `render.py` treats both the same way.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate,
                      AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    struct Options {
        var displayID: CGDirectDisplayID
        var camera: AVCaptureDevice?
        var mic: AVCaptureDevice?
        var systemAudio: Bool
        var cameraRect: CGRect?
    }

    let folder: URL
    private var rec: URL { folder.appendingPathComponent("recording") }
    private let camera: CameraController
    private var stream: SCStream?
    private var screenW: TrackWriter?, sysW: TrackWriter?, camW: TrackWriter?, micW: TrackWriter?
    private var start = CMTime.invalid
    private var startMs: Double = 0
    private var pointWidth: CGFloat = 0
    private var cameraRect: CGRect?
    private let mouse = MouseLogger()
    private let screenQ = DispatchQueue(label: "clips.screen"), audioQ = DispatchQueue(label: "clips.sysaudio")
    var onStreamError: ((String) -> Void)?

    init(folder: URL, camera: CameraController) {
        self.folder = folder
        self.camera = camera
    }

    @MainActor func begin(_ o: Options) async throws {
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)

        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { throw RecorderError.screenPermission }
        guard let display = content.displays.first(where: { $0.displayID == o.displayID }) ?? content.displays.first
        else { throw RecorderError.noDisplay }

        // Our own bar, bubble and countdown never end up in the video.
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        let scale = NSScreen.screens.first { $0.displayID == display.displayID }?.backingScaleFactor ?? 2
        pointWidth = CGFloat(display.width)
        let pw = Int(CGFloat(display.width) * scale) & ~1, ph = Int(CGFloat(display.height) * scale) & ~1

        let cfg = SCStreamConfiguration()
        cfg.width = pw
        cfg.height = ph
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.showsCursor = false               // redrawn from the mouse log, bigger and smoother
        cfg.queueDepth = 6
        cfg.capturesAudio = o.systemAudio
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2

        screenW = try TrackWriter(url: rec.appendingPathComponent("channel-2-display-0.mp4"), type: .mp4,
            input: AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: pw, AVVideoHeightKey: ph,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 24_000_000,
                                                  AVVideoExpectedSourceFrameRateKey: 60,
                                                  AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]]))
        if o.systemAudio {
            sysW = try TrackWriter(url: rec.appendingPathComponent("channel-1-system-audio-0.m4a"), type: .m4a,
                                   input: AVAssetWriterInput(mediaType: .audio, outputSettings: aac(channels: 2)))
        }
        if let cam = o.camera {
            let d = CMVideoFormatDescriptionGetDimensions(cam.activeFormat.formatDescription)
            camW = try TrackWriter(url: rec.appendingPathComponent("channel-4-webcam-0.mp4"), type: .mp4,
                input: AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(d.width), AVVideoHeightKey: Int(d.height),
                    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000]]))
        }
        if o.mic != nil {
            micW = try TrackWriter(url: rec.appendingPathComponent("channel-3-microphone-0.m4a"), type: .m4a,
                                   input: AVAssetWriterInput(mediaType: .audio, outputSettings: aac(channels: 1)))
        }

        cameraRect = o.cameraRect
        start = CMClockGetTime(CMClockGetHostTimeClock())
        startMs = start.seconds * 1000

        camera.recordingSink = self
        try camera.attachMic(o.mic)

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQ)
        if o.systemAudio { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQ) }
        try await s.startCapture()
        stream = s

        mouse.start(display: display.displayID, folder: rec, startMs: startMs)
    }

    /// Stops everything and writes metadata. Returns the project folder.
    @MainActor func finish() async -> URL {
        let endMs = hostNowMs()
        try? await stream?.stopCapture()
        stream = nil
        camera.recordingSink = nil
        camera.attachMicSilently(nil)
        mouse.stop()
        for w in [screenW, sysW, camW, micW] { await w?.finish() }
        writeMetadata(durationMs: endMs - startMs)
        return folder
    }

    @MainActor func cancel() async {
        _ = await finish()
        try? FileManager.default.removeItem(at: folder)
    }

    private func aac(channels: Int) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: channels,
         AVEncoderBitRateKey: channels == 1 ? 128_000 : 192_000]
    }

    private func writeMetadata(durationMs: Double) {
        let session: [String: Any] = ["processTimeStartMs": 0, "durationMs": durationMs]
        let meta: [String: Any] = ["recorder": "Clips 1.0", "recorders": [
            ["id": "channel-2-display", "configuration": ["pointWidth": pointWidth], "sessions": [session]],
            ["id": "channel-0-input", "sessions": [session]],
        ] + (cameraRect.map { r in [["id": "channel-4-webcam", "configuration": ["x": r.minX, "y": r.minY, "size": r.width], "sessions": [session]]] } ?? [])]
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: .prettyPrinted) {
            try? data.write(to: rec.appendingPathComponent("metadata.json"))
        }
    }

    // MARK: ScreenCaptureKit

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        switch type {
        case .screen:
            // Idle frames carry no picture; the previous frame simply stays up longer.
            guard let att = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
                  let raw = att[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            screenW?.append(sb, start: start)
        case .audio:
            sysW?.append(sb, start: start)
        default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onStreamError?(error.localizedDescription) }
    }

    // MARK: Camera + mic (delivered by CameraController)

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        let fixed = camera.toHostClock(sb)
        if output is AVCaptureVideoDataOutput { camW?.append(fixed, start: start) }
        else { micW?.append(fixed, start: start) }
    }
}

/// The camera session lives for as long as the camera is on, so the bubble can preview it before
/// recording starts. The mic joins only while recording, so the orange dot means "recording".
final class CameraController: NSObject {
    let session = AVCaptureSession()
    private let videoOut = AVCaptureVideoDataOutput()
    private let audioOut = AVCaptureAudioDataOutput()
    private var camInput: AVCaptureDeviceInput?
    private var micInput: AVCaptureDeviceInput?
    private let q = DispatchQueue(label: "clips.camera")
    weak var recordingSink: (AVCaptureVideoDataOutputSampleBufferDelegate & AVCaptureAudioDataOutputSampleBufferDelegate)? {
        didSet {
            videoOut.setSampleBufferDelegate(recordingSink, queue: q)
            audioOut.setSampleBufferDelegate(recordingSink, queue: q)
        }
    }

    override init() {
        super.init()
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        videoOut.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOut) { session.addOutput(videoOut) }
        if session.canAddOutput(audioOut) { session.addOutput(audioOut) }
        session.commitConfiguration()
    }

    var cameraDevice: AVCaptureDevice? { camInput?.device }

    func setCamera(_ device: AVCaptureDevice?) {
        session.beginConfiguration()
        if let i = camInput { session.removeInput(i); camInput = nil }
        if let d = device, let i = try? AVCaptureDeviceInput(device: d), session.canAddInput(i) {
            session.addInput(i); camInput = i
        }
        session.commitConfiguration()
        updateRunning()
    }

    func attachMic(_ device: AVCaptureDevice?) throws {
        attachMicSilently(device)
    }

    func attachMicSilently(_ device: AVCaptureDevice?) {
        session.beginConfiguration()
        if let i = micInput { session.removeInput(i); micInput = nil }
        if let d = device, let i = try? AVCaptureDeviceInput(device: d), session.canAddInput(i) {
            session.addInput(i); micInput = i
        }
        session.commitConfiguration()
        updateRunning()
    }

    private func updateRunning() {
        let want = camInput != nil || micInput != nil
        q.async { [session] in
            if want && !session.isRunning { session.startRunning() }
            if !want && session.isRunning { session.stopRunning() }
        }
    }

    /// Capture buffers are stamped on the session clock; move them onto the host clock that
    /// ScreenCaptureKit and the mouse log use. Usually a no-op.
    func toHostClock(_ sb: CMSampleBuffer) -> CMSampleBuffer {
        guard let clock = session.synchronizationClock else { return sb }
        let host = CMClockGetHostTimeClock()
        if CFEqual(clock, host) { return sb }
        let pts = sb.presentationTimeStamp
        let shift = CMTimeSubtract(CMSyncConvertTime(pts, from: clock, to: host), pts)
        if abs(shift.seconds) < 0.001 { return sb }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: .invalid, count: count)
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &timing, entriesNeededOut: nil)
        for i in timing.indices {
            timing[i].presentationTimeStamp = CMTimeAdd(timing[i].presentationTimeStamp, shift)
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = CMTimeAdd(timing[i].decodeTimeStamp, shift) }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out ?? sb
    }
}

/// Logs mouse moves and clicks in display points, plus every cursor shape it sees, in Screen
/// Studio's JSON shapes.
final class MouseLogger {
    private var monitors: [Any] = []
    private var moves: [[String: Any]] = [], clicks: [[String: Any]] = []
    private var cursors: [String: [String: Any]] = [:]
    private var folder: URL?
    private var bounds = CGRect.zero
    private var startMs: Double = 0
    private var lastCursorCheck: Double = 0
    private var cursorId = "arrow"

    func start(display: CGDirectDisplayID, folder: URL, startMs: Double) {
        self.folder = folder
        self.startMs = startMs
        bounds = CGDisplayBounds(display)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("cursors"), withIntermediateDirectories: true)
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                          .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e) }) {
            monitors.append(m)
        }
        sampleCursor(force: true)
        let p = CGEvent(source: nil)?.location ?? .zero
        record(type: "mouseMoved", at: p, button: nil)
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        guard let folder else { return }
        write(moves, to: folder.appendingPathComponent("mousemoves-0.json"))
        write(clicks, to: folder.appendingPathComponent("mouseclicks-0.json"))
        write(Array(cursors.values), to: folder.appendingPathComponent("cursors.json"))
    }

    private func handle(_ e: NSEvent) {
        let p = e.cgEvent?.location ?? CGEvent(source: nil)?.location ?? .zero
        sampleCursor(force: false)
        switch e.type {
        case .leftMouseDown, .rightMouseDown:
            record(type: "mouseDown", at: p, button: e.type == .leftMouseDown ? "left" : "right")
        case .leftMouseUp, .rightMouseUp:
            record(type: "mouseUp", at: p, button: e.type == .leftMouseUp ? "left" : "right")
        default:
            record(type: "mouseMoved", at: p, button: nil)
        }
    }

    private func record(type: String, at p: CGPoint, button: String?) {
        var ev: [String: Any] = ["type": type, "x": p.x - bounds.minX, "y": p.y - bounds.minY,
                                 "cursorId": cursorId, "processTimeMs": hostNowMs() - startMs,
                                 "unixTimeMs": Date().timeIntervalSince1970 * 1000, "activeModifiers": []]
        if let button { ev["button"] = button; clicks.append(ev) } else { moves.append(ev) }
    }

    /// The system cursor's look changes (arrow, hand, I-beam...). Save each new one as a PNG once.
    private func sampleCursor(force: Bool) {
        let now = hostNowMs()
        guard force || now - lastCursorCheck > 60, let c = NSCursor.currentSystem else { return }
        lastCursorCheck = now
        let img = c.image
        guard let tiff = img.tiffRepresentation else { return }
        var h = Hasher(); h.combine(tiff); h.combine(c.hotSpot.x); h.combine(c.hotSpot.y)
        let id = "c" + String(UInt(bitPattern: h.finalize()), radix: 36)
        cursorId = id
        guard cursors[id] == nil, let folder else { return }
        cursors[id] = ["id": id, "hotSpot": ["x": c.hotSpot.x, "y": c.hotSpot.y],
                       "standardSize": ["width": img.size.width, "height": img.size.height], "systemCursor": true]
        let best = img.representations.max { $0.pixelsWide < $1.pixelsWide }
        if let cg = (best as? NSBitmapImageRep)?.cgImage ?? img.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try? png.write(to: folder.appendingPathComponent("cursors/\(id).png"))
        }
    }

    private func write(_ obj: Any, to url: URL) {
        if let d = try? JSONSerialization.data(withJSONObject: obj) { try? d.write(to: url) }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
