import AppKit
import AVFoundation
import Combine

/// A finished recording on its way to a link. Uploads run one at a time in the background
/// (add-clip.sh deploys the whole site, so two at once would race), while you keep recording.
struct Upload: Identifiable, Equatable {
    let id = UUID()
    let folder: URL
    let title: String
    var stage = "Waiting"
    var progress: Double?   // nil = indeterminate
}

enum Phase: Equatable {
    case idle
    case countdown(Int)
    case recording
    case done(URL)
    case failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var startedAt = Date()
    /// Set while a recording is paused. Paused time is left out of the clip and the timer.
    @Published var pausedSince: Date?
    @Published var pausedTotal: TimeInterval = 0
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
            pausedSince = nil
            pausedTotal = 0
            phase = .recording
        } catch {
            await r.cancel()
            fail(error.localizedDescription)
        }
    }

    func togglePause() {
        guard let r = recorder, case .recording = phase else { return }
        if let since = pausedSince {
            r.resume()
            pausedTotal += Date().timeIntervalSince(since)
            pausedSince = nil
            NSSound(named: "Tink")?.play()
        } else {
            r.pause()
            pausedSince = Date()
            NSSound(named: "Pop")?.play()
        }
    }

    /// Seconds of recording that will end up in the clip.
    func recordedSeconds(at now: Date) -> TimeInterval {
        max(0, (pausedSince ?? now).timeIntervalSince(startedAt) - pausedTotal)
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

    /// Finish goes straight back to the Record button; saving and posting carry on in the background.
    func stop() {
        guard let r = recorder else { return }
        recorder = nil
        pausedSince = nil
        phase = .idle
        NSSound(named: "Pop")?.play()
        let title = "Recording · " + Self.titleStamp.string(from: Date())
        Task {
            let folder = await r.finish()
            enqueue(folder, title: title)
        }
    }

    func fail(_ msg: String) {
        if let r = recorder { recorder = nil; Task { _ = await r.finish() } }
        phase = .failed(msg)
    }

    // MARK: Posting (render.py + add-clip.sh via post.sh)

    @Published var uploads: [Upload] = []
    /// Called when an upload finishes: the link, or nil and why it failed.
    var onPosted: ((Upload, URL?, String?) -> Void)?

    private func enqueue(_ folder: URL, title: String) {
        uploads.append(Upload(folder: folder, title: title))
        if uploads.count == 1 { runNext() }
    }

    private func runNext() {
        if let u = uploads.first { post(u) }
    }

    private func update(_ id: UUID, stage: String, progress: Double?) {
        guard let i = uploads.firstIndex(where: { $0.id == id }) else { return }
        uploads[i].stage = stage
        uploads[i].progress = progress
    }

    private func finished(_ u: Upload, link: URL?, error: String?) {
        uploads.removeAll { $0.id == u.id }
        lastFolder = u.folder
        if let link {
            lastLink = link
            clipTitle = u.title
            copyLink()
            NSSound(named: "Glass")?.play()
        }
        // Only take over the bar when it isn't busy with something newer.
        switch phase {
        case .idle, .done, .failed: phase = link.map { .done($0) } ?? .failed(error ?? "Couldn't post")
        default: break
        }
        onPosted?(u, link, error)
        runNext()
    }

    private func post(_ u: Upload) {
        let folder = u.folder, title = u.title
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
        let logURL = folder.appendingPathComponent("post.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)
        update(u.id, stage: "Rendering", progress: 0)

        out.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            log?.write(data)
            let s = String(decoding: data, as: UTF8.self)
            for line in s.split(whereSeparator: \.isNewline) {
                if line.hasPrefix("DURATION "), let v = Double(line.dropFirst(9)) { duration = v }
                if line.hasPrefix("STAGE upload") { Task { @MainActor in self.update(u.id, stage: "Uploading", progress: nil) } }
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
                        if self.uploads.first(where: { $0.id == u.id })?.stage == "Rendering" {
                            self.update(u.id, stage: "Rendering", progress: prog)
                        }
                    }
                }
            }
        }
        p.terminationHandler = { proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                if proc.terminationStatus == 0, let link {
                    self.finished(u, link: link, error: nil)
                } else {
                    let lines = errTail.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                    let why = lines.last { $0.lowercased().contains("error") } ?? lines.last ?? "unknown error"
                    self.finished(u, link: nil, error: "Couldn't post: \(why)")
                }
                try? log?.close()
            }
        }
        do { try p.run(); postProcess = p } catch { finished(u, link: nil, error: "Couldn't start posting: \(error.localizedDescription)") }
    }

    @Published var lastFolder: URL?
    @Published var clipTitle = ""
    /// The newest posted link, kept across launches so the menu bar can copy it again.
    @Published var lastLink: URL? = UserDefaults.standard.url(forKey: "lastLink") {
        didSet { d.set(lastLink, forKey: "lastLink") }
    }

    func copyLink() {
        guard let link = lastLink else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
    }

    /// The same key the web page uses for owner editing, kept next to the repo by setup.
    private var adminKey: String? {
        (try? String(contentsOf: Self.repo.appendingPathComponent(".adminkey"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
    var canRename: Bool { adminKey != nil }

    /// Renames the clip on the site (the page and link preview pick it up right away).
    func rename(_ title: String) async -> Bool {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let key = adminKey, let link = lastLink,
              let api = URL(string: "/api/title", relativeTo: link) else { return false }
        var req = URLRequest(url: api)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["slug": link.lastPathComponent, "title": clean])
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        clipTitle = clean
        return true
    }

    func reset() { phase = .idle }

    func retryPost() {
        guard let f = lastFolder else { return }
        phase = .idle
        enqueue(f, title: "Recording · " + Self.titleStamp.string(from: Date()))
    }

    static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"; return f }()
    static let titleStamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"; return f }()
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
