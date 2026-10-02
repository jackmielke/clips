import AppKit
import AVFoundation
import Combine

enum Phase: Equatable {
    case idle
    case countdown(Int)
    case recording
    case posting(stage: String, progress: Double?)   // nil = indeterminate
    case done(URL)
    case failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var startedAt = Date()
    @Published var displays: [NSScreen] = NSScreen.screens
    @Published var cameras: [AVCaptureDevice] = []
    @Published var mics: [AVCaptureDevice] = []

    @Published var displayID: CGDirectDisplayID { didSet { save(); onLayoutChange?() } }
    @Published var cameraOn: Bool { didSet { save(); applyCamera() } }
    @Published var cameraID: String { didSet { save(); applyCamera() } }
    @Published var micOn: Bool { didSet { save() } }
    @Published var micID: String { didSet { save() } }
    @Published var systemAudioOn: Bool { didSet { save() } }

    let camera = CameraController()
    /// Where the bubble sits on screen right now (top-left fractions); the video puts the camera there too.
    var cameraRect: CGRect?
    var cameraSpot: CGPoint? {
        get { d.object(forKey: "camX") == nil ? nil : CGPoint(x: d.double(forKey: "camX"), y: d.double(forKey: "camY")) }
        set { d.set(newValue?.x, forKey: "camX"); d.set(newValue?.y, forKey: "camY") }
    }
    var onLayoutChange: (() -> Void)?
    private var recorder: Recorder?
    private var countdownTask: Task<Void, Never>?
    private var postProcess: Process?
    private let d = UserDefaults.standard

    nonisolated static let repo = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("dev/clips")
    nonisolated static let library = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies/Clips")

    init() {
        displayID = CGDirectDisplayID(d.integer(forKey: "displayID"))
        cameraOn = d.object(forKey: "cameraOn") as? Bool ?? true
        cameraID = d.string(forKey: "cameraID") ?? ""
        micOn = d.object(forKey: "micOn") as? Bool ?? true
        micID = d.string(forKey: "micID") ?? ""
        systemAudioOn = d.object(forKey: "systemAudioOn") as? Bool ?? true
        refreshDevices()
        if !displays.contains(where: { $0.displayID == displayID }) { displayID = NSScreen.main?.displayID ?? 0 }
        NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.displays = NSScreen.screens; self?.onLayoutChange?() }
        }
    }

    private func save() {
        d.set(Int(displayID), forKey: "displayID")
        d.set(cameraOn, forKey: "cameraOn"); d.set(cameraID, forKey: "cameraID")
        d.set(micOn, forKey: "micOn"); d.set(micID, forKey: "micID")
        d.set(systemAudioOn, forKey: "systemAudioOn")
    }

    func refreshDevices() {
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                   mediaType: .video, position: .unspecified).devices
        mics = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                mediaType: .audio, position: .unspecified).devices
    }

    var display: NSScreen? { displays.first { $0.displayID == displayID } ?? NSScreen.main }
    var selectedCamera: AVCaptureDevice? {
        cameras.first { $0.uniqueID == cameraID } ?? cameras.first { $0.deviceType == .builtInWideAngleCamera } ?? cameras.first
    }
    var selectedMic: AVCaptureDevice? {
        mics.first { $0.uniqueID == micID } ?? AVCaptureDevice.default(for: .audio) ?? mics.first
    }

    func applyCamera() {
        guard cameraOn else { camera.setCamera(nil); onLayoutChange?(); return }
        AVCaptureDevice.requestAccess(for: .video) { ok in
            Task { @MainActor in
                if ok { self.camera.setCamera(self.selectedCamera) } else { self.cameraOn = false }
                self.onLayoutChange?()
            }
        }
    }

    // MARK: Recording

    func toggle() {
        switch phase {
        case .idle, .done, .failed: startCountdown()
        case .countdown: cancelCountdown()
        case .recording: stop()
        case .posting: break
        }
    }

    func startCountdown() {
        if micOn { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
        countdownTask = Task {
            for n in [3, 2, 1] {
                phase = .countdown(n)
                NSSound(named: "Tink")?.play()
                try? await Task.sleep(for: .milliseconds(800))
                if Task.isCancelled { return }
            }
            await begin()
        }
    }

    func cancelCountdown() { countdownTask?.cancel(); phase = .idle }

    private func begin() async {
        let stamp = Self.stamp.string(from: Date())
        let r = Recorder(folder: Self.library.appendingPathComponent(stamp), camera: camera)
        r.onStreamError = { [weak self] msg in self?.fail("Recording stopped: \(msg)") }
        do {
            try await r.begin(.init(displayID: displayID,
                                    camera: cameraOn ? camera.cameraDevice : nil,
                                    mic: micOn ? selectedMic : nil,
                                    systemAudio: systemAudioOn,
                                    cameraRect: cameraOn ? cameraRect : nil))
            recorder = r
            startedAt = Date()
            phase = .recording
        } catch {
            await r.cancel()
            fail(error.localizedDescription)
        }
    }

    func restart() {
        guard let r = recorder else { return }
        recorder = nil
        phase = .idle
        Task { await r.cancel(); startCountdown() }
    }

    func discard() {
        guard let r = recorder else { return }
        recorder = nil
        phase = .idle
        Task { await r.cancel() }
    }

    func stop() {
        guard let r = recorder else { return }
        recorder = nil
        phase = .posting(stage: "Saving", progress: nil)
        NSSound(named: "Pop")?.play()
        Task {
            let folder = await r.finish()
            post(folder)
        }
    }

    func fail(_ msg: String) {
        if let r = recorder { recorder = nil; Task { _ = await r.finish() } }
        phase = .failed(msg)
    }

    // MARK: Posting (render.py + add-clip.sh via post.sh)

    private func post(_ folder: URL) {
        let title = "Recording · " + Self.titleStamp.string(from: Date())
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [Self.repo.appendingPathComponent("post.sh").path, folder.path, title]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        var duration = 0.0
        var link: URL?
        var errTail = ""
        lastFolder = folder
        let logURL = folder.appendingPathComponent("post.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)
        phase = .posting(stage: "Rendering", progress: 0)

        out.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            log?.write(data)
            let s = String(decoding: data, as: UTF8.self)
            for line in s.split(whereSeparator: \.isNewline) {
                if line.hasPrefix("DURATION "), let v = Double(line.dropFirst(9)) { duration = v }
                if line.hasPrefix("STAGE upload") { Task { @MainActor in self.phase = .posting(stage: "Uploading", progress: nil) } }
                if line.hasPrefix("https://"), let u = URL(string: String(line)) { link = u }
            }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            log?.write(data)
            let s = String(decoding: data, as: UTF8.self)
            if !s.contains("frame=") { errTail = String((errTail + s).suffix(1200)) }
            // ffmpeg -stats: "... time=00:01:23.45 ..."
            if let r = s.range(of: "time=", options: .backwards) {
                let parts = s[r.upperBound...].prefix(11).split(separator: ":")
                if parts.count == 3, let hh = Double(parts[0]), let mm = Double(parts[1]), let ss = Double(parts[2]), duration > 0 {
                    let prog = min(1, (hh * 3600 + mm * 60 + ss) / duration)
                    Task { @MainActor in
                        if case .posting("Rendering", _) = self.phase { self.phase = .posting(stage: "Rendering", progress: prog) }
                    }
                }
            }
        }
        p.terminationHandler = { proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                if proc.terminationStatus == 0, let link {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.absoluteString, forType: .string)
                    NSSound(named: "Glass")?.play()
                    self.phase = .done(link)
                } else {
                    let lines = errTail.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                    let why = lines.last { $0.lowercased().contains("error") } ?? lines.last ?? "unknown error"
                    self.phase = .failed("Couldn't post: \(why)")
                }
                try? log?.close()
            }
        }
        do { try p.run(); postProcess = p } catch { phase = .failed("Couldn't start posting: \(error.localizedDescription)") }
    }

    @Published var lastFolder: URL?

    func reset() { phase = .idle }

    func retryPost() { if let f = lastFolder { post(f) } }

    static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"; return f }()
    static let titleStamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"; return f }()
}
