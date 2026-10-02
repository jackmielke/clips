import SwiftUI
import AVFoundation

// MARK: - Bar

struct ControlBar: View {
    @ObservedObject var m: AppModel
    var hide: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            switch m.phase {
            case .idle: idle
            case .countdown(let n): countdown(n)
            case .recording: recording
            case .posting(let stage, let progress): posting(stage, progress)
            case .done(let url): done(url)
            case .failed(let msg): failed(msg)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 52)
        .background(ZStack { VisualEffect(); Color.black.opacity(0.62) }.clipShape(Capsule()))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: m.phase)
        .padding(24)   // room for the shadow
    }

    // Idle: pick sources, hit record.
    @ViewBuilder private var idle: some View {
        Menu {
            ForEach(m.displays, id: \.displayID) { s in
                Button { m.displayID = s.displayID } label: {
                    if s.displayID == m.displayID { Label(s.localizedName, systemImage: "checkmark") } else { Text(s.localizedName) }
                }
            }
        } label: {
            Chip(icon: "display", text: shortName(m.display?.localizedName ?? "Display"), on: true)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()

        Sep()

        deviceMenu(icon: m.cameraOn ? "video.fill" : "video.slash.fill", on: m.cameraOn, help: "Camera",
                   devices: m.cameras, selected: m.selectedCamera?.uniqueID,
                   pick: { m.cameraID = $0; m.cameraOn = true }, toggle: { m.cameraOn.toggle() })
        deviceMenu(icon: m.micOn ? "mic.fill" : "mic.slash.fill", on: m.micOn, help: "Microphone",
                   devices: m.mics, selected: m.selectedMic?.uniqueID,
                   pick: { m.micID = $0; m.micOn = true }, toggle: { m.micOn.toggle() })
        IconButton(icon: m.systemAudioOn ? "speaker.wave.2.fill" : "speaker.slash.fill", on: m.systemAudioOn,
                   help: m.systemAudioOn ? "Computer audio on" : "Computer audio off") { m.systemAudioOn.toggle() }

        Sep()

        Button(action: m.toggle) {
            HStack(spacing: 8) {
                Circle().fill(Color(red: 1, green: 0.27, blue: 0.27)).frame(width: 12, height: 12)
                Text("Record").font(.system(size: 13, weight: .semibold))
                Text("⌥⇧R").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 14).frame(height: 36)
            .background(Capsule().fill(.white.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(Press())

        IconButton(icon: "minus", on: true, help: "Hide (menu bar icon brings it back)", dim: true, action: hide)
    }

    private func countdown(_ n: Int) -> some View {
        HStack(spacing: 10) {
            Text("Starting in").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            Text("\(n)").font(.system(size: 18, weight: .bold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
            IconButton(icon: "xmark", on: true, help: "Cancel", dim: true) { m.cancelCountdown() }
        }.padding(.leading, 10)
    }

    private var recording: some View {
        HStack(spacing: 6) {
            HStack(spacing: 9) {
                PulseDot()
                TimelineView(.periodic(from: m.startedAt, by: 1)) { ctx in
                    Text(elapsed(ctx.date)).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                }
            }.padding(.leading, 10).padding(.trailing, 4)
            Sep()
            IconButton(icon: "arrow.counterclockwise", on: true, help: "Start over", dim: true) { m.restart() }
            IconButton(icon: "trash", on: true, help: "Discard", dim: true) { m.discard() }
            Button(action: m.stop) {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 10, height: 10)
                    Text("Finish").font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 14).frame(height: 36)
                .background(Capsule().fill(Color(red: 1, green: 0.27, blue: 0.27)))
                .contentShape(Capsule())
            }.buttonStyle(Press())
        }
    }

    private func posting(_ stage: String, _ progress: Double?) -> some View {
        HStack(spacing: 10) {
            Ring(progress: progress)
            Text(progress.map { "\(stage) \(Int($0 * 100))%" } ?? "\(stage)…")
                .font(.system(size: 13, weight: .medium)).monospacedDigit()
                .contentTransition(.numericText())
        }.padding(.horizontal, 12)
    }

    private func done(_ url: URL) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(Color(red: 0.36, green: 0.86, blue: 0.55))
                .padding(.leading, 8)
            Text("Link copied").font(.system(size: 13, weight: .semibold)).padding(.trailing, 4)
            PillButton(text: "Open") { NSWorkspace.shared.open(url) }
            PillButton(text: "New") { m.reset() }
        }
    }

    private func failed(_ msg: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).padding(.leading, 8)
            Text(msg).font(.system(size: 12, weight: .medium)).lineLimit(1).frame(maxWidth: 320, alignment: .leading)
            if msg.contains("Screen recording") {
                PillButton(text: "Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            } else if let f = m.lastFolder {
                PillButton(text: "Retry") { m.retryPost() }
                PillButton(text: "Log") { NSWorkspace.shared.open(f.appendingPathComponent("post.log")) }
            }
            PillButton(text: "OK") { m.reset() }
        }
    }

    private func deviceMenu(icon: String, on: Bool, help: String, devices: [AVCaptureDevice], selected: String?,
                            pick: @escaping (String) -> Void, toggle: @escaping () -> Void) -> some View {
        Menu {
            Button(on ? "Turn off \(help.lowercased())" : "Turn on \(help.lowercased())", action: toggle)
            Divider()
            ForEach(devices, id: \.uniqueID) { dev in
                Button { pick(dev.uniqueID) } label: {
                    if on && dev.uniqueID == selected { Label(dev.localizedName, systemImage: "checkmark") } else { Text(dev.localizedName) }
                }
            }
        } label: {
            IconFace(icon: icon, on: on)
        } primaryAction: { toggle() }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("\(help): click to toggle, hold for devices")
    }

    private func elapsed(_ now: Date) -> String {
        let t = max(0, Int(now.timeIntervalSince(m.startedAt)))
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    private func shortName(_ s: String) -> String {
        s.replacingOccurrences(of: "Built-in ", with: "").replacingOccurrences(of: " Display", with: "")
    }
}

// MARK: - Pieces

struct Chip: View {
    let icon: String, text: String, on: Bool
    @State private var hover = false
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
            Text(text).font(.system(size: 13, weight: .medium))
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 12).frame(height: 36)
        .background(Capsule().fill(.white.opacity(hover ? 0.10 : 0)))
        .contentShape(Capsule())
        .onHover { hover = $0 }
    }
}

struct IconFace: View {
    let icon: String, on: Bool
    var dim = false
    @State private var hover = false
    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(on ? .white.opacity(dim ? 0.6 : 0.95) : Color(red: 1, green: 0.42, blue: 0.42))
            .frame(width: 36, height: 36)
            .background(Circle().fill(.white.opacity(hover ? 0.10 : 0)))
            .contentShape(Circle())
            .onHover { hover = $0 }
            .contentTransition(.symbolEffect(.replace))
    }
}

struct IconButton: View {
    let icon: String, on: Bool, help: String
    var dim = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { IconFace(icon: icon, on: on, dim: dim) }.buttonStyle(Press()).help(help)
    }
}

struct PillButton: View {
    let text: String, action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(text).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).frame(height: 30)
                .background(Capsule().fill(.white.opacity(hover ? 0.18 : 0.10)))
                .contentShape(Capsule())
        }.buttonStyle(Press()).onHover { hover = $0 }
    }
}

struct Sep: View {
    var body: some View { Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 20).padding(.horizontal, 2) }
}

struct Press: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct PulseDot: View {
    @State private var on = false
    var body: some View {
        ZStack {
            Circle().fill(Color(red: 1, green: 0.27, blue: 0.27).opacity(0.35)).frame(width: 18, height: 18)
                .scaleEffect(on ? 1 : 0.5).opacity(on ? 0 : 1)
            Circle().fill(Color(red: 1, green: 0.27, blue: 0.27)).frame(width: 10, height: 10)
        }
        .onAppear { withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { on = true } }
    }
}

struct Ring: View {
    let progress: Double?
    @State private var spin = false
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: 2.5)
            Circle().trim(from: 0, to: progress.map { max(0.03, $0) } ?? 0.28)
                .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .rotationEffect(.degrees(progress == nil && spin ? 360 : 0))
                .animation(progress == nil ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .easeOut(duration: 0.3), value: spin)
                .animation(.easeOut(duration: 0.3), value: progress)
        }
        .frame(width: 18, height: 18)
        .onAppear { spin = true }
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// MARK: - Countdown overlay

struct CountdownView: View {
    @ObservedObject var m: AppModel
    var body: some View {
        ZStack {
            if case .countdown(let n) = m.phase {
                Text("\(n)")
                    .font(.system(size: 120, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 220, height: 220)
                    .background(ZStack { VisualEffect(); Color.black.opacity(0.55) }.clipShape(RoundedRectangle(cornerRadius: 56, style: .continuous)))
                    .id(n)
                    .transition(.asymmetric(insertion: .scale(scale: 1.25).combined(with: .opacity), removal: .scale(scale: 0.8).combined(with: .opacity)))
            }
        }
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: m.phase)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
