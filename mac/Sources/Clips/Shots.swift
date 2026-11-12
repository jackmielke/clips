import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

// MARK: - Screenshot list (~/Pictures/Clips/shots.json)

/// One screenshot: the png in ~/Pictures/Clips and its link, jack-clips.vercel.app/s/<slug>.
/// The slug is picked here before uploading, so marking a shot up later re-uploads to the same link.
struct Shot: Codable, Identifiable, Equatable {
    var slug: String
    var file: String
    var date: Date
    var uploaded: Bool
    var edits: Int
    var id: String { slug }
    var url: URL { URL(fileURLWithPath: file) }
    var link: URL { URL(string: "\(ShotStore.origin)/s/\(slug)")! }
    /// The png itself, like the thumbnail macOS shows after a screenshot: drop it into Slack, Messages, Mail, Finder, a browser.
    var dragItem: NSItemProvider {
        let item = NSItemProvider(contentsOf: url) ?? NSItemProvider()
        item.suggestedName = url.deletingPathExtension().lastPathComponent
        return item
    }
}

@MainActor
final class ShotStore: ObservableObject {
    nonisolated static let origin = ProcessInfo.processInfo.environment["CLIPS_ORIGIN"] ?? "https://jack-clips.vercel.app"
    nonisolated static let index = AppModel.shots.appendingPathComponent("shots.json")

    @Published private(set) var shots: [Shot] = []
    @Published private(set) var uploading: Set<String> = []
    @Published private(set) var failed: [String: String] = [:]
    var onUploaded: ((Shot) -> Void)?
    var onFailed: ((Shot, String) -> Void)?

    private var queue: [String] = []
    private var running = false

    init() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.index), let list = try? dec.decode([Shot].self, from: data) {
            shots = list.filter { FileManager.default.fileExists(atPath: $0.file) }
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        try? FileManager.default.createDirectory(at: AppModel.shots, withIntermediateDirectories: true)
        try? enc.encode(shots).write(to: Self.index, options: .atomic)
    }

    func shot(_ slug: String) -> Shot? { shots.first { $0.slug == slug } }

    /// A new capture: remember it and start uploading.
    @discardableResult
    func add(_ file: URL) -> Shot {
        var slug: String
        repeat { slug = String(format: "%08x", UInt32.random(in: .min ... .max)) } while shot(slug) != nil
        let s = Shot(slug: slug, file: file.path, date: Date(), uploaded: false, edits: 0)
        shots.insert(s, at: 0)
        save()
        upload(slug)
        return s
    }

    /// Marked up: overwrite the png and upload it again under the same link.
    func replace(_ slug: String, png: Data) {
        guard let i = shots.firstIndex(where: { $0.slug == slug }) else { return }
        try? png.write(to: shots[i].url, options: .atomic)
        shots[i].edits += 1
        save()
        upload(slug)
    }

    func upload(_ slug: String) {
        if !queue.contains(slug) { queue.append(slug) }
        uploading.insert(slug)
        failed[slug] = nil
        pump()
    }

    /// One upload at a time, so an older version can never land on top of a newer one.
    private func pump() {
        guard !running, !queue.isEmpty else { return }
        let slug = queue.removeFirst()
        guard let s = shot(slug) else { uploading.remove(slug); pump(); return }
        running = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [AppModel.repo.appendingPathComponent("shot.sh").path, s.file, slug]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let err = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        p.terminationHandler = { proc in
            let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let ok = proc.terminationStatus == 0
            Task { @MainActor in self.finished(slug, ok: ok, stderr: stderr) }
        }
        do { try p.run() } catch {
            running = false
            finished(slug, ok: false, stderr: "Couldn't start the upload: \(error.localizedDescription)")
        }
    }

    private func finished(_ slug: String, ok: Bool, stderr: String) {
        running = false
        if !queue.contains(slug) { uploading.remove(slug) }
        if let i = shots.firstIndex(where: { $0.slug == slug }) {
            if ok {
                shots[i].uploaded = true
                save()
                onUploaded?(shots[i])
            } else {
                let why = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "unknown error"
                failed[slug] = why
                onFailed?(shots[i], why)
            }
        }
        pump()
    }

    func copyLink(_ s: Shot) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s.link.absoluteString, forType: .string)
    }

    func status(_ s: Shot) -> String {
        if uploading.contains(s.slug) { return s.uploaded ? "Updating link…" : "Uploading…" }
        if failed[s.slug] != nil { return "Upload failed" }
        return s.uploaded ? "Link ready" : "Not uploaded"
    }
}

// MARK: - Thumbnails

/// A small decoded copy, so a grid of retina screenshots stays light. `version` reloads it after a markup.
struct ShotThumb: View {
    let url: URL
    let version: Int
    var maxPixels: CGFloat = 600
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
            else { Color.white.opacity(0.06) }
        }
        .task(id: "\(url.path)#\(version)") {
            let url = url, max = maxPixels
            image = await Task.detached { Self.load(url, max: max) }.value
        }
    }
    nonisolated static func load(_ url: URL, max: CGFloat) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: max,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

// MARK: - Corner preview right after a capture

struct ShotPreview: View {
    @ObservedObject var store: ShotStore
    let slug: String
    var edit: () -> Void
    var all: () -> Void
    var close: () -> Void
    var hover: (Bool) -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = store.shot(slug) {
                ShotThumb(url: s.url, version: s.edits)
                    .frame(width: 248, height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.12)))
                    .contentShape(Rectangle())
                    .onTapGesture(perform: edit)
                    .onDrag { s.dragItem }
                    .help("Drag it into any app, or click to mark it up")
                HStack(spacing: 6) {
                    Circle().fill(store.failed[slug] != nil ? Color.red : store.uploading.contains(slug) ? Color.yellow : Color.green)
                        .frame(width: 7, height: 7)
                    Text("Copied to clipboard · " + store.status(s))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                }
                HStack(spacing: 6) {
                    PreviewButton(icon: "pencil.tip.crop.circle", text: "Mark up", primary: true, action: edit)
                    PreviewButton(icon: copied ? "checkmark" : "link", text: copied ? "Copied" : "Copy link") {
                        store.copyLink(s)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    }
                    PreviewButton(icon: "square.grid.2x2", text: "All", action: all)
                }
            }
        }
        .padding(12)
        .background(ZStack { VisualEffect(); Color.black.opacity(0.55) }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.10)))
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 20, height: 20).background(Circle().fill(.black.opacity(0.7)))
            }
            .buttonStyle(.plain).offset(x: 6, y: -6)
        }
        .onHover(perform: hover)
        .environment(\.colorScheme, .dark)
        .padding(10)
    }
}

struct PreviewButton: View {
    let icon: String, text: String
    var primary = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(text).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10).frame(height: 28)
            .foregroundStyle(.white)
            .background(Capsule().fill(primary ? Color.accentColor.opacity(hover ? 1 : 0.85) : .white.opacity(hover ? 0.18 : 0.10)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Screenshots window (all of them)

struct ShotsGallery: View {
    @ObservedObject var store: ShotStore
    var edit: (Shot) -> Void
    var take: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Screenshots").font(.system(size: 20, weight: .bold))
                    Text("Files live in Pictures › Clips. Each link is jack-clips.vercel.app/s/… and keeps working after you mark it up.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Folder") { NSWorkspace.shared.open(AppModel.shots) }
                Button("Take Screenshot  ⌥⇧S", action: take).buttonStyle(.borderedProminent)
            }
            if store.shots.isEmpty {
                Spacer()
                Text("No screenshots yet. Press ⌥⇧S, drag over anything, and it shows up here.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], spacing: 18) {
                        ForEach(store.shots) { s in ShotCard(store: store, shot: s, edit: { edit(s) }) }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
    }
}

struct ShotCard: View {
    @ObservedObject var store: ShotStore
    let shot: Shot
    var edit: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ShotThumb(url: shot.url, version: shot.edits)
                .frame(height: 140).frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture(perform: edit)
                .onDrag { shot.dragItem }
                .help("Drag it into any app, or click to mark it up")
            HStack {
                Text(shot.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(store.status(shot)).font(.system(size: 11))
                    .foregroundStyle(store.failed[shot.slug] != nil ? .red : .secondary)
            }
            HStack(spacing: 6) {
                Button("Mark up", action: edit)
                Button(copied ? "Copied" : "Copy link") {
                    store.copyLink(shot)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                }
                Button("Open") { NSWorkspace.shared.open(shot.link) }.disabled(!shot.uploaded)
                if store.failed[shot.slug] != nil { Button("Retry") { store.upload(shot.slug) } }
                Spacer()
                Button { NSWorkspace.shared.activateFileViewerSelecting([shot.url]) } label: { Image(systemName: "folder") }
                    .help("Show in Finder")
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Markup

enum MarkTool: String, CaseIterable {
    case pen, arrow, oval, box, text
    var icon: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .oval: "circle"
        case .box: "rectangle"
        case .pen: "scribble"
        case .text: "textformat"
        }
    }
    var name: String {
        switch self {
        case .arrow: "Arrow"
        case .oval: "Circle"
        case .box: "Box"
        case .pen: "Pen"
        case .text: "Text"
        }
    }
}

/// One mark, in the screenshot's own pixels.
struct Mark {
    var tool: MarkTool
    var color: NSColor
    var points: [CGPoint]
    var text = ""
    var width: CGFloat
}

@MainActor
final class MarkupDoc: ObservableObject {
    let image: NSImage
    let pixel: CGSize
    @Published var tool: MarkTool = .pen
    @Published var color: NSColor = .systemRed
    @Published var marks: [Mark] = []
    /// Line width that reads well at any size: about 0.4% of the long side, never thinner than 4 px.
    var width: CGFloat { max(4, max(pixel.width, pixel.height) / 250) }

    static let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .white, .black]

    init?(file: URL) {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        pixel = CGSize(width: cg.width, height: cg.height)
        image = NSImage(cgImage: cg, size: pixel)
    }

    /// Everything drawn in image pixels, in a flipped (top-left origin) context.
    func draw(extra: Mark? = nil) {
        image.draw(in: CGRect(origin: .zero, size: pixel), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        for m in marks { Self.draw(m) }
        if let extra { Self.draw(extra) }
    }

    /// The marked-up png, at full resolution.
    func render() -> Data? {
        let w = Int(pixel.width), h = Int(pixel.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cg.translateBy(x: 0, y: CGFloat(h))
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        guard let out = cg.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, out, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func draw(_ m: Mark) {
        guard let a = m.points.first else { return }
        let b = m.points.last ?? a
        let w = m.width
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // A soft shadow keeps marks readable on any background.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = w * 1.2
        shadow.shadowOffset = .zero
        shadow.set()
        m.color.setStroke()
        m.color.setFill()
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        switch m.tool {
        case .pen:
            let p = NSBezierPath()
            p.lineWidth = w
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.move(to: a)
            for pt in m.points.dropFirst() { p.line(to: pt) }
            if m.points.count == 1 { p.line(to: a) }
            p.stroke()
        case .box:
            let p = NSBezierPath(roundedRect: rect, xRadius: w, yRadius: w)
            p.lineWidth = w
            p.stroke()
        case .oval:
            let p = NSBezierPath(ovalIn: rect)
            p.lineWidth = w
            p.stroke()
        case .arrow:
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(hypot(dx, dy), 0.001)
            let head = min(w * 5, len * 0.6)
            let angle = atan2(dy, dx)
            let back = CGPoint(x: b.x - cos(angle) * head * 0.8, y: b.y - sin(angle) * head * 0.8)
            let shaft = NSBezierPath()
            shaft.lineWidth = w
            shaft.lineCapStyle = .round
            shaft.move(to: a)
            shaft.line(to: back)
            shaft.stroke()
            let tri = NSBezierPath()
            tri.move(to: b)
            tri.line(to: CGPoint(x: b.x - cos(angle - 0.45) * head, y: b.y - sin(angle - 0.45) * head))
            tri.line(to: CGPoint(x: b.x - cos(angle + 0.45) * head, y: b.y - sin(angle + 0.45) * head))
            tri.close()
            tri.lineJoinStyle = .round
            tri.lineWidth = w * 0.5
            tri.fill()
            tri.stroke()
        case .text:
            let font = NSFont.systemFont(ofSize: textSize(w), weight: .bold)
            let light = m.color == .white || m.color == .systemYellow
            let outline: [NSAttributedString.Key: Any] = [.font: font, .strokeColor: light ? NSColor.black : NSColor.white, .strokeWidth: 14]
            (m.text as NSString).draw(at: a, withAttributes: outline)
            NSShadow().set()
            (m.text as NSString).draw(at: a, withAttributes: [.font: font, .foregroundColor: m.color])
        }
    }

    static func textSize(_ width: CGFloat) -> CGFloat { width * 7 }
}

/// The drawing surface: shows the screenshot fitted to the window and turns drags into marks.
final class MarkupCanvas: NSView, NSTextFieldDelegate {
    let doc: MarkupDoc
    private var current: Mark?
    private var field: NSTextField?
    private var fieldPoint = CGPoint.zero

    init(doc: MarkupDoc) {
        self.doc = doc
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var k: CGFloat { max(0.0001, min(bounds.width / doc.pixel.width, bounds.height / doc.pixel.height)) }
    private var origin: CGPoint {
        CGPoint(x: (bounds.width - doc.pixel.width * k) / 2, y: (bounds.height - doc.pixel.height * k) / 2)
    }
    private func toImage(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: min(max((p.x - origin.x) / k, 0), doc.pixel.width), y: min(max((p.y - origin.y) / k, 0), doc.pixel.height))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: doc.tool == .text ? .iBeam : .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.13, alpha: 1).setFill()
        bounds.fill()
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: origin.x, yBy: origin.y)
        t.scale(by: k)
        t.concat()
        MainActor.assumeIsolated { doc.draw(extra: current) }
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with e: NSEvent) {
        if field != nil { window?.makeFirstResponder(self); return }   // a click away finishes the text
        let p = toImage(e)
        MainActor.assumeIsolated {
            if doc.tool == .text { beginText(at: p); return }
            current = Mark(tool: doc.tool, color: doc.color, points: [p, p], width: doc.width)
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        guard current != nil else { return }
        let p = toImage(e)
        if current!.tool == .pen { current!.points.append(p) } else { current!.points[1] = p }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        guard let m = current else { return }
        current = nil
        let a = m.points.first!, b = m.points.last!
        if m.tool == .pen || hypot(b.x - a.x, b.y - a.y) * k > 4 {
            MainActor.assumeIsolated { doc.marks.append(m) }
        }
        needsDisplay = true
    }

    @MainActor private func beginText(at p: CGPoint) {
        let f = NSTextField()
        f.font = NSFont.systemFont(ofSize: MarkupDoc.textSize(doc.width) * k, weight: .bold)
        f.textColor = doc.color
        f.isBordered = false
        f.drawsBackground = true
        f.backgroundColor = NSColor.black.withAlphaComponent(0.35)
        f.focusRingType = .none
        f.placeholderString = "Type, then Return"
        f.delegate = self
        f.sizeToFit()
        f.frame = NSRect(x: origin.x + p.x * k - 2, y: origin.y + p.y * k, width: max(220, f.frame.width), height: f.frame.height)
        addSubview(f)
        window?.makeFirstResponder(f)
        field = f
        fieldPoint = p
    }

    func controlTextDidChange(_ n: Notification) {
        guard let f = field else { return }
        let w = f.attributedStringValue.size().width + 24
        f.setFrameSize(NSSize(width: max(220, w), height: f.frame.height))
    }

    func controlTextDidEndEditing(_ n: Notification) {
        MainActor.assumeIsolated { commitText() }
    }

    /// Ends any text being typed, keeping it as a mark.
    @MainActor func commitText() {
        guard let f = field else { return }
        field = nil
        let s = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        f.removeFromSuperview()
        if !s.isEmpty { doc.marks.append(Mark(tool: .text, color: doc.color, points: [fieldPoint], text: s, width: doc.width)) }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
}

struct CanvasView: NSViewRepresentable {
    @ObservedObject var doc: MarkupDoc
    let canvas: MarkupCanvas
    func makeNSView(context: Context) -> MarkupCanvas { canvas }
    func updateNSView(_ v: MarkupCanvas, context: Context) {
        v.needsDisplay = true
        v.window?.invalidateCursorRects(for: v)
    }
}

struct MarkupEditor: View {
    @ObservedObject var doc: MarkupDoc
    let canvas: MarkupCanvas
    var save: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 2) {
                    ForEach(MarkTool.allCases, id: \.self) { t in
                        Button { canvas.commitText(); doc.tool = t } label: {
                            Label(t.name, systemImage: t.icon)
                                .labelStyle(.titleAndIcon)
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 9).frame(height: 28)
                                .background(RoundedRectangle(cornerRadius: 6).fill(doc.tool == t ? Color.accentColor.opacity(0.3) : .clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Divider().frame(height: 22)
                HStack(spacing: 7) {
                    ForEach(MarkupDoc.colors, id: \.self) { c in
                        Button { doc.color = c } label: {
                            Circle().fill(Color(nsColor: c)).frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(.gray.opacity(0.5), lineWidth: 1))
                                .padding(3)
                                .overlay(Circle().strokeBorder(doc.color == c ? Color.accentColor : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Divider().frame(height: 22)
                Button { canvas.commitText(); _ = doc.marks.popLast() } label: { Image(systemName: "arrow.uturn.backward") }
                    .keyboardShortcut("z").disabled(doc.marks.isEmpty).help("Undo (⌘Z)")
                Spacer()
                Button("Cancel", action: cancel)
                Button("Save  ⌘↩", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Saves the file, copies the image, and updates the same link")
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            Divider()
            CanvasView(doc: doc, canvas: canvas)
        }
    }
}
