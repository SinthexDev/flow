import AppKit
import SwiftUI

/// Detached process: stays up across the quit/replace gap, shows only after Flow
/// has exited, and quits itself when Flow is running again.
enum UpdateProgressHud {
    static let argument = "--update-hud"
    static let parentPidArgument = "--parent-pid"
    private static let bundleIdentifier = "de.sinthex.flow"
    private static let maxLifetime: TimeInterval = 600

    static func runStandalone(version: String, parentPid: pid_t?) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Resolve copy while the bundle is still on disk; replace may delete it next.
        let title = L10n.s("update.progress.title", version)
        let body = L10n.s("update.progress.body")
        let controller = UpdateProgressController()
        let selfPid = ProcessInfo.processInfo.processIdentifier
        let started = Date()
        var shown = false

        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
            if Date().timeIntervalSince(started) > maxLifetime {
                timer.invalidate()
                NSApp.terminate(nil)
                return
            }
            let others = otherFlowProcesses(excluding: selfPid)
            if !shown {
                if let parentPid, kill(parentPid, 0) == 0 { return }
                if !others.isEmpty { return }
                controller.show(title: title, body: body)
                shown = true
                return
            }
            if !others.isEmpty {
                timer.invalidate()
                NSApp.terminate(nil)
            }
        }

        app.run()
    }

    /// Second process in its own session; survives the main app quitting for replace.
    @discardableResult
    static func spawnDetached(version: String) -> pid_t? {
        guard let exe = Bundle.main.executableURL?.path else { return nil }
        let parent = ProcessInfo.processInfo.processIdentifier
        return try? UpdateCheck.spawnDetachedExecutable(
            exe,
            arguments: [argument, version, parentPidArgument, "\(parent)"]
        )
    }

    private static func otherFlowProcesses(excluding selfPid: pid_t) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != selfPid && !$0.isTerminated }
    }
}

final class UpdateProgressController {
    private var panel: NSPanel?

    func show(title: String, body: String) {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 280, height: 132),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            self.panel = panel
        }
        guard let panel else { return }
        let root = UpdateProgressView(title: title, message: body)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 132)
        panel.contentView = host
        panel.setContentSize(host.frame.size)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let origin = NSPoint(
                x: frame.midX - host.frame.width / 2,
                y: frame.midY - host.frame.height / 2
            )
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct UpdateProgressView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            FlowMark(size: 36)
            ProgressView()
                .controlSize(.regular)
                .tint(.white.opacity(0.85))
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.14, green: 0.12, blue: 0.22),
                            Color(red: 0.08, green: 0.07, blue: 0.12),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: Theme.violet.opacity(0.35), radius: 22, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.gradient, lineWidth: 1.2)
        )
        .padding(8)
        .environment(\.colorScheme, .dark)
    }
}
