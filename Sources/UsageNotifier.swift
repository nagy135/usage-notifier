import AppKit
import SwiftUI

struct UsageWindow: Decodable {
    let name: String
    let used: Double
    let resetsAt: Double
    var remaining: Double { max(0, min(100, 100 - used)) }
}

struct ServiceUsage: Decodable {
    let name: String
    var plan = ""
    var windows: [UsageWindow]? = nil
    var error = ""
    var updatedAt: Double = 0
    var nextAttempt: Double = 0
}

final class UsageModel: ObservableObject {
    @Published var services = [ServiceUsage(name: "Codex"), ServiceUsage(name: "Claude")]
    @Published var loading = false
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var pending = Set<String>()
    private var timer: Timer?
    private var stopping = false

    func start() {
        guard process == nil else { return }
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("usage-helper") else { return }
        let process = Process()
        let stdin = Pipe(), stdout = Pipe()
        process.executableURL = executable
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        // A read-only usage query should not inherit this project's Codex config.
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        output = stdout.fileHandleForReading
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.stopping else { return }
                self.process = nil
                self.input = nil
                self.loading = false
                for index in self.services.indices {
                    self.services[index].error = "Usage reader stopped. Click refresh to reconnect."
                }
            }
        }
        do {
            try process.run()
            self.process = process
            input = stdin.fileHandleForWriting
            refresh()
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        } catch {
            output?.readabilityHandler = nil
            for index in services.indices { services[index].error = "Could not start usage reader. Rebuild the app." }
        }
    }

    func refresh() {
        guard !loading else { return }
        guard let input else { start(); return }
        pending = ["Codex", "Claude"]
        loading = true
        do { try input.write(contentsOf: Data("refresh\n".utf8)) }
        catch {
            loading = false
            process?.terminate()
        }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]
            if let usage = try? JSONDecoder().decode(ServiceUsage.self, from: line),
               let index = services.firstIndex(where: { $0.name == usage.name }) {
                services[index] = usage
                pending.remove(usage.name)
            }
            buffer.removeSubrange(...end)
        }
        loading = !pending.isEmpty
    }

    func stop() {
        stopping = true
        timer?.invalidate()
        output?.readabilityHandler = nil
        try? input?.close()
        if let process, process.isRunning { process.terminate() }
    }
}

private func countdown(_ seconds: TimeInterval) -> String {
    if seconds <= 0 { return "now" }
    let minutes = max(1, Int(ceil(seconds / 60)))
    if minutes >= 1440 { return "\(minutes / 1440)d \((minutes % 1440) / 60)h" }
    if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
    return "\(minutes)m"
}

private struct LimitRow: View {
    let window: UsageWindow
    let tint: Color
    let now: Date
    var color: Color { window.remaining <= 10 ? .red : window.remaining <= 25 ? .orange : tint }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.name).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 8)
                Text("\(window.remaining, specifier: "%.0f")%")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
                Text("left").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                Capsule().fill(tint.opacity(0.12))
                    .overlay(alignment: .leading) {
                        Capsule().fill(color).frame(width: proxy.size.width * window.remaining / 100)
                    }
            }
            .frame(height: 5)
            if window.resetsAt > 0 {
                let reset = Date(timeIntervalSince1970: window.resetsAt)
                HStack(spacing: 4) {
                    Text(reset <= now ? "Reset due · awaiting refresh" : "Resets in \(countdown(reset.timeIntervalSince(now)))")
                    Spacer(minLength: 0)
                    Text(reset, format: .dateTime.weekday(.abbreviated).hour().minute())
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .help(reset.formatted(date: .complete, time: .shortened))
            } else {
                Text("Reset time unavailable").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ServiceCard: View {
    let usage: ServiceUsage
    let now: Date
    var tint: Color { usage.name == "Codex" ? Color(red: 0.23, green: 0.72, blue: 0.64) : Color(red: 0.86, green: 0.53, blue: 0.37) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ProviderIcon(isCodex: usage.name == "Codex")
                    .fill(tint)
                    .frame(width: 18, height: 18)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                Text(usage.name).font(.system(size: 14, weight: .semibold))
                Spacer()
                if !usage.plan.isEmpty {
                    Text(usage.plan.capitalized).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.primary.opacity(0.05), in: Capsule())
                }
            }
            if let windows = usage.windows, !windows.isEmpty {
                ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                    LimitRow(window: window, tint: tint, now: now)
                }
            } else if usage.error.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading usage…").font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(.vertical, 10)
            }
            if !usage.error.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label(usage.error, systemImage: "exclamationmark.circle")
                    if usage.nextAttempt > now.timeIntervalSince1970 {
                        Text("Retry in \(countdown(usage.nextAttempt - now.timeIntervalSince1970))")
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
            if usage.updatedAt > 0 {
                HStack(spacing: 4) {
                    Circle().fill(usage.error.isEmpty ? tint : .orange).frame(width: 4, height: 4)
                    Text(usage.error.isEmpty ? "Updated" : "Last successful update")
                    Text(Date(timeIntervalSince1970: usage.updatedAt), style: .relative)
                    Text("ago")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct UsageCard: View {
    @ObservedObject var model: UsageModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI Usage").font(.system(size: 17, weight: .semibold))
                    Text("Your remaining capacity").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.refresh() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 26, height: 26)
                }
                .disabled(model.loading).help("Refresh usage (⌘R). Provider cooldowns still apply.")
                .accessibilityLabel("Refresh usage")
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "xmark").frame(width: 26, height: 26)
                }
                .keyboardShortcut("q", modifiers: [])
                .help("Quit Usage Notifier (Q)").accessibilityLabel("Quit Usage Notifier")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(spacing: 10) {
                    ForEach(model.services, id: \.name) { usage in
                        ServiceCard(usage: usage, now: context.date)
                    }
                }
            }
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Codex every minute · Claude every 5 minutes")
            }
            .font(.system(size: 9)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(width: 350)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.08)))
    }
}

private final class UsagePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = UsageModel()
    private var panel: NSPanel?
    private var hosting: NSHostingView<UsageCard>?
    private var resizeTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let item = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Refresh Usage", action: #selector(refresh), keyEquivalent: "r")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Usage Notifier", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu
        menu.addItem(item)
        NSApp.mainMenu = menu
        let panel = UsagePanel(contentRect: NSRect(x: 0, y: 0, width: 350, height: 480),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Usage Notifier"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: UsageCard(model: model))
        panel.contentView = hosting
        self.hosting = hosting
        self.panel = panel
        positionPanel()
        panel.orderFrontRegardless()
        // Preserve the top edge as loading/error/model-specific rows change height.
        resizeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.resizePanel() }
        NotificationCenter.default.addObserver(self, selector: #selector(positionPanel), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        model.start()
    }

    @objc private func refresh() { model.refresh() }
    private func resizePanel() {
        guard let panel, let hosting else { return }
        let height = ceil(hosting.fittingSize.height)
        guard height > 0, abs(panel.frame.height - height) > 1 else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }
    @objc private func positionPanel() {
        guard let panel, let screen = NSScreen.screens.first else { return }
        resizePanel()
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - 16,
                                     y: screen.visibleFrame.maxY - panel.frame.height - 16))
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.orderFrontRegardless()
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        resizeTimer?.invalidate()
        model.stop()
    }
}

@main
struct UsageNotifier {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}
