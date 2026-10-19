import Cocoa
import Combine
import SwiftUI

final class OverlayController {
    private let panel: NSPanel
    private var cancellables = Set<AnyCancellable>()
    private var leaveWork: DispatchWorkItem?
    private weak var state: AppState?
    /// Screen-space drag anchors – avoid SwiftUI translation (jitters when the panel moves).
    private var dragStartOrigin: NSPoint?
    private var dragStartMouse: NSPoint?
    /// Bottom-center while dragging. Outside of a drag, placement comes from the saved relative position.
    private var dragAnchor: NSPoint?
    private var mode: Mode = .collapsed
    private var shrinkWork: DispatchWorkItem?
    /// The pointer left while the bar had to stay open (dictation or translate menu).
    private var pointerLeft = false
    /// Screen that currently hosts the temporary follow placement (nil = home screen).
    private var followDisplayID: CGDirectDisplayID?
    /// Bottom-center while following; frozen once a result/preview card is up so insert does not jump.
    private var followAnchor: NSPoint?
    /// Moves a fixed “current screen” card when the pointer crosses displays.
    private var pointerScreenMonitor: Any?
    private var pointerScreenID: CGDirectDisplayID?

    private enum Mode: Int {
        case collapsed, bar, menu, result

        func size(result: OverlayResultSize) -> NSSize {
            switch self {
            case .collapsed: return NSSize(width: 64, height: 48)
            case .bar: return NSSize(width: 228, height: 72)
            case .menu: return NSSize(width: 236, height: 478)
            case .result: return result.panelSize
            }
        }
    }

    init(state: AppState) {
        self.state = state
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false
        // Always stay above the Dock / other system chrome.
        panel.orderFrontRegardless()

        let root = OverlayView(
            onHoverChange: { [weak self] hovering in
                self?.setHovered(hovering)
            },
            onDragChanged: { [weak self] in
                self?.dragChanged()
            },
            onDragEnded: { [weak self] in
                self?.dragEnded()
            }
        )
        .environmentObject(state)
        let host = NSHostingView(rootView: root)
        // Otherwise the hosting view resizes the panel on its own and fights our placement.
        host.sizingOptions = []
        host.frame = panel.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        Publishers.CombineLatest(
            Publishers.CombineLatest4(
                state.$phase,
                state.$widgetHovered,
                state.$widgetTranslateOpen,
                state.$overlayResult
            ),
            Publishers.CombineLatest(state.$dictationPreview, state.$notePreview)
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard self?.state?.widgetDragging != true else { return }
                self?.syncFollowTarget()
                self?.updateMode()
                self?.syncPanelVisibility()
            }
            .store(in: &cancellables)

        let follow = state.$config.map(\.widgetFollowActiveScreen).removeDuplicates()
        let resultSize = state.$config.map(\.overlayResultSize).removeDuplicates()
        let showWidget = state.$config.map(\.showWidget).removeDuplicates()
        let placement = state.$config
            .map { "\($0.resultPlacementFixed)|\($0.resultPlacementScreen)|\($0.resultPlacementAnchor)" }
            .removeDuplicates()
        Publishers.CombineLatest4(follow, resultSize, showWidget, placement)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard self?.state?.widgetDragging != true else { return }
                self?.syncFollowTarget()
                self?.updateMode()
                self?.syncPanelVisibility()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard self?.state?.widgetDragging != true else { return }
                self?.syncFollowTarget()
                self?.applyFrame()
            }
            .store(in: &cancellables)

        show()
    }

    deinit {
        if let pointerScreenMonitor {
            NSEvent.removeMonitor(pointerScreenMonitor)
        }
    }

    func show() {
        mode = targetMode()
        applyFrame()
        syncPanelVisibility()
    }

    private func shouldShowPanel() -> Bool {
        guard let state else { return true }
        if state.overlayResult != nil { return true }
        if state.dictationPreview != nil { return true }
        if state.notePreview != nil { return true }
        if state.widgetDragging { return true }
        if state.widgetTranslateOpen { return true }
        // Aufnahme/Verarbeitung immer sichtbar – „Widget anzeigen“ gilt nur für den Leerlauf.
        if state.phase != .idle { return true }
        return state.config.showWidget
    }

    private func syncPanelVisibility() {
        if shouldShowPanel() {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    /// The choice buttons must not keep the key window, or ⌘V lands here.
    func releaseKey() {
        guard panel.isKeyWindow else { return }
        panel.resignKey()
    }

    private func setHovered(_ hovering: Bool) {
        guard let state else { return }
        if hovering {
            pointerLeft = false
            leaveWork?.cancel()
            leaveWork = nil
            if !state.widgetHovered { state.widgetHovered = true }
            return
        }
        // Dragging reports a leave as the panel moves. Ignore that.
        // A leave during dictation or while the menu is open must still be remembered,
        // otherwise the bar stays up after the phase returns to idle.
        guard !state.widgetDragging else { return }
        leaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.finishLeave()
        }
        leaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
    }

    private func finishLeave() {
        guard let state, !state.widgetDragging else { return }
        if state.widgetTranslateOpen || state.isBusy || state.overlayResult != nil || state.dictationPreview != nil {
            pointerLeft = true
            return
        }
        pointerLeft = false
        state.widgetHovered = false
    }

    private func dragChanged() {
        guard let state else { return }
        let mouse = NSEvent.mouseLocation
        if dragStartOrigin == nil {
            dragStartOrigin = panel.frame.origin
            dragStartMouse = mouse
            leaveWork?.cancel()
            // Size stays put while dragging – expanding mid-drag causes jumps.
            if !state.widgetDragging {
                state.widgetDragging = true
            }
        }
        guard let start = dragStartOrigin, let mouse0 = dragStartMouse else { return }
        let origin = NSPoint(
            x: start.x + (mouse.x - mouse0.x),
            y: start.y + (mouse.y - mouse0.y)
        )
        var frame = panel.frame
        frame.origin = clamped(origin, size: frame.size)
        // display:false avoids full redraw flicker while tracking
        panel.setFrame(frame, display: false, animate: false)
    }

    private func dragEnded() {
        dragStartOrigin = nil
        dragStartMouse = nil
        let point = NSPoint(x: panel.frame.midX, y: panel.frame.minY)
        dragAnchor = point
        persistHome(at: point)
        // A drag always defines the new home; leave any temporary follow.
        followDisplayID = nil
        followAnchor = nil
        state?.widgetDragging = false
        state?.widgetHovered = true
        updateMode()
        dragAnchor = nil
        applyFrame()
    }

    private func persistHome(at point: NSPoint) {
        guard let state else { return }
        guard let screen = screenContaining(point) ?? screenForPanel() ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        guard vf.width > 1, vf.height > 1 else { return }
        var config = state.config
        config.widgetX = Double((point.x - vf.minX) / vf.width)
        config.widgetY = Double((point.y - vf.minY) / vf.height)
        config.widgetDisplayID = screen.displayID.map(Int.init)
        state.config = config
    }

    /// Follow the pointer only while busy, and only when the setting is on.
    /// Dictation preview never follows — it must stay clear of the caret and pointer.
    /// Other result cards freeze their bottom-center until the session ends.
    private func syncFollowTarget() {
        guard let state else {
            followDisplayID = nil
            followAnchor = nil
            return
        }
        // Preview parks at home (and nudges away from pointer/focus), never on the caret.
        // A fixed result placement also ignores follow.
        if state.dictationPreview != nil || state.notePreview != nil || usesFixedResultPlacement {
            followDisplayID = nil
            followAnchor = nil
            return
        }
        let hasCard = state.overlayResult != nil
        let busy = state.phase != .idle || hasCard
        guard state.config.widgetFollowActiveScreen, busy else {
            followDisplayID = nil
            followAnchor = nil
            return
        }
        if hasCard {
            if followAnchor == nil {
                followAnchor = NSPoint(x: panel.frame.midX, y: panel.frame.minY)
            }
            if let anchor = followAnchor {
                followDisplayID = screenContaining(anchor)?.displayID ?? screenUnderPointer()?.displayID
            } else {
                followDisplayID = screenUnderPointer()?.displayID
            }
        } else {
            followAnchor = nil
            followDisplayID = screenUnderPointer()?.displayID
        }
    }

    private var isFollowingPointer: Bool {
        followDisplayID != nil
    }

    private func targetMode() -> Mode {
        guard let state else { return .collapsed }
        if state.overlayResult != nil || state.dictationPreview != nil || state.notePreview != nil { return .result }
        if state.widgetTranslateOpen { return .menu }
        if state.widgetHovered || state.phase != .idle { return .bar }
        return .collapsed
    }

    /// Grow the panel immediately so SwiftUI can animate inside it;
    /// shrink only after the collapse animation has finished.
    private func updateMode() {
        releaseHoverIfPointerLeft()
        let target = targetMode()
        shrinkWork?.cancel()
        shrinkWork = nil
        if target.rawValue > mode.rawValue {
            mode = target
            applyFrame()
        } else if target.rawValue < mode.rawValue {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.targetMode() == target else { return }
                self.mode = target
                self.applyFrame()
            }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.42, execute: work)
        } else {
            // Same visual mode, but the home/follow screen may have changed.
            applyFrame()
        }
        syncPointerScreenWatch()
    }

    private var usesFixedResultPlacement: Bool {
        guard state?.config.resultPlacementFixed == true else { return false }
        return state?.dictationPreview != nil || state?.overlayResult != nil || state?.notePreview != nil
    }

    private func syncPointerScreenWatch() {
        let wants = usesFixedResultPlacement
            && state?.config.resultPlacementScreen == FlowConfig.resultPlacementPointerScreen
        if wants {
            guard pointerScreenMonitor == nil else { return }
            pointerScreenID = screenUnderPointer()?.displayID
            pointerScreenMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged]
            ) { [weak self] _ in
                self?.pointerScreenMayHaveChanged()
            }
        } else if let pointerScreenMonitor {
            NSEvent.removeMonitor(pointerScreenMonitor)
            self.pointerScreenMonitor = nil
            pointerScreenID = nil
        }
    }

    private func pointerScreenMayHaveChanged() {
        let id = screenUnderPointer()?.displayID
        guard id != pointerScreenID else { return }
        pointerScreenID = id
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state?.widgetDragging != true else { return }
            self.applyFrame()
        }
    }

    /// Hover state can stick after a dictation: the pointer left while the phase
    /// was busy, and that leave used to be ignored. Once idle, trust the pointer.
    private func releaseHoverIfPointerLeft() {
        guard let state else { return }
        guard state.widgetHovered, state.phase == .idle else { return }
        guard !state.widgetTranslateOpen, state.overlayResult == nil, state.dictationPreview == nil, !state.widgetDragging else { return }
        let outside = !panel.frame.contains(NSEvent.mouseLocation)
        guard pointerLeft || outside else { return }
        pointerLeft = false
        state.widgetHovered = false
    }

    /// Bottom-center for the current size. Home by default; at the pointer while following.
    /// Dictation preview always uses home, then nudges clear of pointer and focused field.
    private func resolvedPlacement(size: NSSize) -> (point: NSPoint, screen: NSScreen) {
        if let dragAnchor, state?.widgetDragging == true {
            let screen = screenContaining(dragAnchor) ?? screenForPanel() ?? NSScreen.main
                ?? NSScreen.screens[0]
            return (dragAnchor, screen)
        }
        if usesFixedResultPlacement {
            return fixedResultPlacement(size: size)
        }
        if state?.dictationPreview != nil {
            let home = homePlacement()
            return placementClearOfWorkArea(preferred: home.point, size: size, screen: home.screen)
        }
        if isFollowingPointer {
            // Frozen bottom-center after a card appears; otherwise live under the pointer.
            if let locked = followAnchor {
                let screen = screenContaining(locked) ?? placementScreen()
                return (locked, screen)
            }
            let mouse = NSEvent.mouseLocation
            let screen = screenContaining(mouse) ?? placementScreen()
            let vf = screen.visibleFrame
            let gap: CGFloat = 10
            let limits = verticalLimits(for: size, in: vf)
            // Prefer the panel just under the pointer (result card grows upward toward it).
            var y = mouse.y - size.height - gap
            if y < limits.minY {
                // Not enough room below: place just above the pointer instead.
                y = mouse.y + gap
            }
            y = min(max(y, limits.minY), limits.maxY)
            let half = size.width / 2
            let x = min(max(mouse.x, vf.minX + 8 + half), vf.maxX - 8 - half)
            return (NSPoint(x: x.rounded(), y: y.rounded()), screen)
        }
        return homePlacement()
    }

    private func homePlacement() -> (point: NSPoint, screen: NSScreen) {
        let screen = homeScreen()
        let vf = screen.visibleFrame
        let rx = state?.config.widgetX
        let ry = state?.config.widgetY
        let point: NSPoint
        if let rx, let ry {
            point = NSPoint(
                x: (vf.minX + CGFloat(rx) * vf.width).rounded(),
                y: (vf.minY + CGFloat(ry) * vf.height).rounded()
            )
        } else {
            point = NSPoint(x: vf.midX.rounded(), y: (vf.minY + 12).rounded())
        }
        return (point, screen)
    }

    /// Bottom-center of a result card pinned to a screen edge or corner.
    private func fixedResultPlacement(size: NSSize) -> (point: NSPoint, screen: NSScreen) {
        let screen = resolvedResultScreen()
        let vf = screen.visibleFrame
        let margin: CGFloat = 16
        let half = size.width / 2
        let anchor = state?.config.resolvedResultPlacementAnchor ?? .bottomCenter
        let x: CGFloat
        let y: CGFloat
        switch anchor {
        case .topLeading:
            x = vf.minX + margin + half
            y = vf.maxY - margin - size.height
        case .topCenter:
            x = vf.midX
            y = vf.maxY - margin - size.height
        case .topTrailing:
            x = vf.maxX - margin - half
            y = vf.maxY - margin - size.height
        case .bottomLeading:
            x = vf.minX + margin + half
            y = vf.minY + margin
        case .bottomCenter:
            x = vf.midX
            y = vf.minY + margin
        case .bottomTrailing:
            x = vf.maxX - margin - half
            y = vf.minY + margin
        }
        return (NSPoint(x: x.rounded(), y: y.rounded()), screen)
    }

    private func resolvedResultScreen() -> NSScreen {
        let key = state?.config.resultPlacementScreen ?? FlowConfig.resultPlacementPointerScreen
        if key == FlowConfig.resultPlacementPointerScreen {
            return screenUnderPointer() ?? homeScreen()
        }
        if let raw = UInt32(key), let screen = NSScreen.screen(displayID: raw) {
            return screen
        }
        return homeScreen()
    }

    /// Keep the dictation preview off the mouse (and thus usually off the caret nearby).
    private func placementClearOfWorkArea(
        preferred: NSPoint,
        size: NSSize,
        screen: NSScreen
    ) -> (point: NSPoint, screen: NSScreen) {
        let vf = screen.visibleFrame
        let limits = verticalLimits(for: size, in: vf)
        let half = size.width / 2
        let mouse = NSEvent.mouseLocation
        let pad: CGFloat = 40

        func clamp(_ point: NSPoint) -> NSPoint {
            NSPoint(
                x: min(max(point.x, vf.minX + 8 + half), vf.maxX - 8 - half).rounded(),
                y: min(max(point.y, limits.minY), limits.maxY).rounded()
            )
        }

        func frame(at point: NSPoint) -> NSRect {
            NSRect(x: point.x - half, y: point.y, width: size.width, height: size.height)
        }

        let keepout = NSRect(
            x: mouse.x - pad,
            y: mouse.y - pad,
            width: pad * 2,
            height: pad * 2
        )

        func blocked(_ point: NSPoint) -> Bool {
            frame(at: point).intersects(keepout)
        }

        let home = clamp(preferred)
        if !blocked(home) { return (home, screen) }

        let sideX = mouse.x < vf.midX
            ? vf.maxX - 8 - half
            : vf.minX + 8 + half
        let candidates: [NSPoint] = [
            NSPoint(x: home.x, y: mouse.y - size.height - pad),
            NSPoint(x: home.x, y: mouse.y + pad),
            NSPoint(x: sideX, y: home.y),
            NSPoint(x: sideX, y: mouse.y - size.height - pad),
            NSPoint(x: sideX, y: mouse.y + pad),
            NSPoint(x: vf.midX, y: vf.minY + 12),
            NSPoint(x: vf.midX, y: limits.maxY)
        ]
        for raw in candidates {
            let point = clamp(raw)
            if !blocked(point) { return (point, screen) }
        }
        return (clamp(NSPoint(x: vf.midX, y: vf.minY + 12)), screen)
    }

    private func applyFrame() {
        let resultSize = state?.config.resolvedOverlayResultSize ?? .regular
        let size: NSSize
        if mode == .result, state?.notePreview != nil, state?.overlayResult == nil {
            size = NotePreviewLayout.panelSize
        } else if mode == .result, let preview = state?.dictationPreview {
            size = DictationPreviewLayout.panelSize(text: preview.text, result: resultSize)
        } else {
            size = mode.size(result: resultSize)
        }
        if state?.widgetDragging == true {
            // Keep the bottom-center the user is dragging; only grow/shrink around it.
            let midX = panel.frame.midX
            let minY = panel.frame.minY
            let origin = clamped(
                NSPoint(x: midX - size.width / 2, y: minY),
                size: size,
                in: (screenForPanel() ?? NSScreen.main)?.visibleFrame
            )
            panel.setFrame(
                NSRect(x: origin.x.rounded(), y: origin.y.rounded(), width: size.width, height: size.height),
                display: true,
                animate: false
            )
            panel.orderFrontRegardless()
            return
        }

        let placement = resolvedPlacement(size: size)
        let vf = placement.screen.visibleFrame
        var x = placement.point.x
        var y = placement.point.y
        // Result / follow: keep the full panel on screen. Idle bar/menu: clamp to the bar
        // footprint so the wider menu may overhang instead of shifting the pill sideways.
        let half: CGFloat
        if isFollowingPointer || mode == .result {
            half = size.width / 2
        } else {
            half = Mode.bar.size(result: resultSize).width / 2
        }
        x = min(max(x, vf.minX + 8 + half), vf.maxX - 8 - half)
        let limits = verticalLimits(for: size, in: vf)
        y = min(max(y, limits.minY), limits.maxY)
        let frame = NSRect(
            x: (x - size.width / 2).rounded(),
            y: y.rounded(),
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true, animate: false)
        syncPanelVisibility()
    }

    private func placementScreen() -> NSScreen {
        if let followDisplayID, let screen = NSScreen.screen(displayID: followDisplayID) {
            return screen
        }
        return homeScreen()
    }

    private func homeScreen() -> NSScreen {
        if let raw = state?.config.widgetDisplayID,
           let screen = NSScreen.screen(displayID: CGDirectDisplayID(raw)) {
            return screen
        }
        return screenForPanel() ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func screenForPanel() -> NSScreen? {
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        return screenContaining(center)
    }

    private func screenUnderPointer() -> NSScreen? {
        screenContaining(NSEvent.mouseLocation)
    }

    private func screenContaining(_ point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    /// The panel keeps empty space under the pill. That space may cross into the Dock
    /// so the pill itself can sit on the Dock or on the screen edge.
    private func verticalLimits(for size: NSSize, in visible: NSRect) -> (minY: CGFloat, maxY: CGFloat) {
        let minY = visible.minY - OverlayView.pillBottomInset
        let maxY = visible.maxY - size.height - 8
        return (minY, max(minY, maxY))
    }

    /// Keep the pill inside the visible frame: above the menu bar, and down to the Dock or screen edge.
    private func clamped(_ origin: NSPoint, size: NSSize, in visible: NSRect? = nil) -> NSPoint {
        let vf: NSRect
        if let visible {
            vf = visible
        } else if let screen = screenForPanel() ?? NSScreen.main {
            vf = screen.visibleFrame
        } else {
            return origin
        }
        let padX: CGFloat = 8
        let minX = vf.minX + padX
        let maxX = vf.maxX - size.width - padX
        let limits = verticalLimits(for: size, in: vf)
        let minY = limits.minY
        let maxY = limits.maxY
        return NSPoint(
            x: min(max(origin.x, minX), max(minX, maxX)),
            y: min(max(origin.y, minY), max(minY, maxY))
        )
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    static func screen(displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == displayID }
    }
}

struct OverlayView: View {
    @EnvironmentObject var state: AppState
    var onHoverChange: (Bool) -> Void = { _ in }
    var onDragChanged: () -> Void = {}
    var onDragEnded: () -> Void = {}

    private var expanded: Bool {
        if state.dictationPreview != nil || state.notePreview != nil { return false }
        return state.widgetHovered
            || state.phase != .idle
            || state.widgetTranslateOpen
            || state.overlayResult != nil
    }

    /// Pill during recording/processing; idle chip only when “show widget” is on.
    /// Dictation preview and result cards stand alone, without the pill underneath.
    private var showsPill: Bool {
        if state.dictationPreview != nil || state.overlayResult != nil || state.notePreview != nil { return false }
        if state.phase != .idle { return true }
        if state.widgetTranslateOpen { return true }
        return state.config.showWidget
    }

    static let pillBottomInset: CGFloat = 18

    /// The card is pinned to the bottom of a tall panel. Top anchors only look
    /// top-aligned once the card itself sits on the panel's top edge.
    private var pinsCardToTop: Bool {
        guard state.config.resultPlacementFixed else { return false }
        guard state.overlayResult != nil || state.dictationPreview != nil || state.notePreview != nil else { return false }
        switch state.config.resolvedResultPlacementAnchor {
        case .topLeading, .topCenter, .topTrailing: return true
        case .bottomLeading, .bottomCenter, .bottomTrailing: return false
        }
    }
    private static let morph = Animation.spring(response: 0.38, dampingFraction: 0.84)

    var body: some View {
        // Bottom-pinned overlay: the pill keeps its position even for the frame where the content
        // is already taller than the panel (the panel grows one runloop later).
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: pinsCardToTop ? .top : .bottom) { content }
            .animation(state.widgetDragging ? nil : Self.morph, value: expanded)
            .animation(state.widgetDragging ? nil : Self.morph, value: state.widgetTranslateOpen)
            .animation(state.widgetDragging ? nil : Self.morph, value: state.overlayResult)
            .animation(state.widgetDragging ? nil : Self.morph, value: state.dictationPreview)
            .animation(state.widgetDragging ? nil : Self.morph, value: state.notePreview)
            .animation(state.widgetDragging ? nil : .easeOut(duration: 0.2), value: state.phase)
            .environment(\.colorScheme, .dark)
    }

    private var content: some View {
        VStack(spacing: 8) {
            if let note = state.notePreview {
                NoteSavedCard(
                    text: note.body,
                    place: note.placeTitle,
                    dismissSeconds: SnapshotMode.isActive ? 0 : state.config.resolvedOverlayDismissSeconds,
                    onOpen: { state.openSavedNote() },
                    onClose: { state.notePreview = nil }
                )
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)),
                        removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .bottom))
                    )
                )
            } else if let result = state.overlayResult {
                let size = state.config.resolvedOverlayResultSize
                if let choices = result.choices, !choices.isEmpty {
                    OverlayChoiceCard(
                        spoken: result.command,
                        choices: choices,
                        size: size,
                        onInsert: { choice in
                            state.selectOverlayChoice(choice)
                        },
                        onCopy: { choice in
                            state.copy(choice.text)
                        },
                        onNote: { choice in
                            Task { await state.saveCapturedText(choice.text) }
                        },
                        onClose: { state.overlayResult = nil }
                    )
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)),
                            removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .bottom))
                        )
                    )
                } else {
                    OverlayResultCard(
                        command: result.command,
                        text: result.text,
                        size: size,
                        dismissSeconds: SnapshotMode.isActive ? 0 : state.config.resolvedOverlayDismissSeconds,
                        onCopy: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(result.text, forType: .string)
                        },
                        onClose: { state.overlayResult = nil }
                    )
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)),
                            removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .bottom))
                        )
                    )
                }
            } else if let preview = state.dictationPreview {
                let size = state.config.resolvedOverlayResultSize
                let dismiss: Int = {
                    if SnapshotMode.isActive || preview.status == .working || preview.status == .inserted {
                        return 0
                    }
                    // Copied only — insert closes the preview immediately in AppDelegate.
                    return state.config.resolvedDictationPreviewDismissSeconds
                }()
                DictationPreviewCard(
                    text: preview.text,
                    status: preview.status,
                    size: size,
                    dismissSeconds: dismiss,
                    onClose: { state.dictationPreview = nil }
                )
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)),
                        removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .bottom))
                    )
                )
            } else if state.widgetTranslateOpen {
                TranslateMenuCard(
                    languages: translateTargets,
                    nativeId: state.config.nativeLanguage,
                    onPick: { id in
                        state.widgetTranslateOpen = false
                        state.translateSelection(id)
                    },
                    onClose: { state.widgetTranslateOpen = false }
                )
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)),
                        removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .bottom))
                    )
                )
            }
            if showsPill {
                pill
            }
        }
        // Generous hover/drag target around the visible shapes, without changing layout.
        .padding(10)
        .contentShape(Rectangle())
        .onHover(perform: onHoverChange)
        .simultaneousGesture(widgetDrag)
        .padding(-10)
        .fixedSize()
        .padding(.bottom, Self.pillBottomInset)
    }

    private var widgetDrag: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { _ in onDragChanged() }
            .onEnded { _ in onDragEnded() }
    }

    /// One capsule that morphs between chip and bar, so expand/collapse is a smooth resize.
    private var pill: some View {
        ZStack {
            if expanded {
                HStack(spacing: 8) { phaseContent }
                    .padding(.horizontal, horizontalInset)
                    .frame(width: pillWidth, height: 38)
                    .transition(.opacity.animation(.easeOut(duration: 0.18).delay(0.06)))
            } else {
                chipBars
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
            }
        }
        .frame(width: expanded ? pillWidth : 36, height: expanded ? 38 : 19)
        .background(
            Capsule(style: .continuous)
                .fill(Color(white: expanded ? 0.09 : 0.05).opacity(expanded ? 0.96 : 0.62))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(expanded ? 0.08 : 0.12), lineWidth: 0.5)
        )
        .clipShape(Capsule(style: .continuous))
        .softDropShadow(.bar)
        .contentShape(Capsule())
        .help(expanded ? "" : L10n.s("overlay.drag", state.config.resolvedHotkey.symbol))
    }

    static let recordingPillWidth: CGFloat = 196

    private var isRecording: Bool {
        if case .listening = state.phase { return true }
        return false
    }

    private var pillWidth: CGFloat {
        if isRecording { return Self.recordingPillWidth }
        if state.rewriting { return 220 }
        return 172
    }

    /// Idle: round 26pt controls sit concentric in the capsule ends ((38 - 26) / 2).
    private var horizontalInset: CGFloat {
        switch state.phase {
        case .idle: return 6
        case .listening: return 14
        default: return 12
        }
    }

    private var chipBars: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(state.engineReady ? 0.55 : 0.28))
                    .frame(width: 2, height: CGFloat([5, 9, 6][index]))
            }
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch state.phase {
        case .idle:
            idleToolbar
        case .listening:
            HStack(spacing: 8) {
                PulsingDot()
                MirroredWaveform(levels: state.levels, bars: 15)
                    .frame(width: 72, height: 20)
                Text(Fmt.clock(state.elapsed))
                    .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
                iconChip(system: "stop.fill", tint: .red, action: state.toggleRecording)
            }
        case .transcribing:
            statusRow(icon: nil, title: L10n.s("overlay.recognizing")) {
                ThinkingWave().frame(width: 32, height: 14)
            }
        case .polishing(let raw):
            if state.rewriting {
                statusRow(icon: nil, title: SelectionIntentClassifier.busyCaption(for: raw)) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: [Theme.violet, Theme.pink], startPoint: .top, endPoint: .bottom))
                }
            } else if state.dictationPreview != nil {
                statusRow(icon: nil, title: L10n.s("overlay.preview.recognized")) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: [Theme.violet, Theme.pink], startPoint: .top, endPoint: .bottom))
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: [Theme.violet, Theme.pink], startPoint: .top, endPoint: .bottom))
                    Text(raw)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 0)
                }
            }
        case .translating(let code):
            statusRow(icon: nil, title: "→ \(code.uppercased())") {
                ThinkingWave().frame(width: 32, height: 14)
            }
        case .done(let text, let pasted):
            HStack(spacing: 8) {
                Image(systemName: pasted ? "checkmark.circle.fill" : "doc.on.clipboard.fill")
                    .foregroundStyle(pasted ? .green : .orange)
                Text(pasted ? L10n.s("overlay.inserted") : L10n.s("overlay.copied"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                if state.dictationPreview == nil {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        case .notice(let message):
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill").foregroundStyle(.white.opacity(0.65))
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
    }

    private func statusRow<Leading: View>(icon: String?, title: String, @ViewBuilder leading: () -> Leading) -> some View {
        HStack(spacing: 8) {
            leading()
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
        }
    }

    private var idleToolbar: some View {
        HStack(spacing: 6) {
            Button(action: state.toggleRecording) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.gradient))
            }
            .buttonStyle(.plain)
            .disabled(!state.engineReady)
            .opacity(state.engineReady ? 1 : 0.45)
            .help(L10n.s("overlay.dictate"))

            Text(state.config.resolvedHotkey.symbol)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.32))

            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 1, height: 14)
                .padding(.horizontal, 2)

            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    state.widgetTranslateOpen.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "character.book.closed")
                        .font(.system(size: 10, weight: .semibold))
                    Image(systemName: state.widgetTranslateOpen ? "chevron.down" : "chevron.up")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(.white.opacity(0.78))
                .frame(height: 26)
                .padding(.horizontal, 9)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(state.widgetTranslateOpen ? 0.14 : 0.08))
                )
            }
            .buttonStyle(.plain)
            .help(L10n.s("overlay.translateHelp"))

            Spacer(minLength: 2)

            iconChip(system: "gearshape", tint: .white.opacity(0.7)) {
                state.widgetTranslateOpen = false
                state.openMain(.settings)
            }
            .help(L10n.s("menu.settings"))
        }
    }

    /// Native language first (foreign text → my language), then the foreign targets.
    private var translateTargets: [TranslateLanguage] {
        let native = state.config.nativeLanguage
        let preferred = ["en", "de", "fr", "es", "it", "pt", "nl", "pl", "tr"]
        let order = [native] + preferred.filter { $0 != native }
        return order.compactMap { id in TranslateLanguage.all.first { $0.id == id } }
    }

    private func iconChip(system: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

/// Fitted size for the dictation preview card (grows with text up to the result-size max).
enum DictationPreviewLayout {
    static let minCardWidth: CGFloat = 168
    static let textFontSize: CGFloat = 14
    static let horizontalTextPadding: CGFloat = 28
    static let headerHeight: CGFloat = 38.5
    static let textVerticalPadding: CGFloat = 24
    static let cardBottomPadding: CGFloat = 6

    static func cardWidth(for text: String, maxWidth: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: textFontSize, weight: .medium)
        let oneLine = ceil((text as NSString).size(withAttributes: [.font: font]).width) + horizontalTextPadding
        return min(max(oneLine, minCardWidth), maxWidth)
    }

    static func textBlockHeight(for text: String, cardWidth: CGFloat, maxTextHeight: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: textFontSize, weight: .medium)
        let width = max(1, cardWidth - horizontalTextPadding)
        var rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lineHeight = max(1, font.ascender - font.descender + font.leading)
        let lines = max(1, Int(ceil(rect.height / lineHeight)))
        if lines > 1 {
            rect.size.height += CGFloat(lines - 1) * 3
        }
        let content = ceil(rect.height) + textVerticalPadding
        return min(max(content, textVerticalPadding + ceil(lineHeight)), maxTextHeight)
    }

    static func cardHeight(for text: String, cardWidth: CGFloat, maxTextHeight: CGFloat) -> CGFloat {
        headerHeight
            + textBlockHeight(for: text, cardWidth: cardWidth, maxTextHeight: maxTextHeight)
            + cardBottomPadding
    }

    static func panelSize(text: String, result: OverlayResultSize) -> NSSize {
        let width = cardWidth(for: text, maxWidth: result.cardWidth)
        let height = cardHeight(for: text, cardWidth: width, maxTextHeight: result.cardMaxTextHeight)
        return NSSize(width: width, height: height + OverlayView.pillBottomInset)
    }
}

enum NotePreviewLayout {
    static let cardWidth: CGFloat = 320
    static let cardHeight: CGFloat = 148

    static var panelSize: NSSize {
        NSSize(width: cardWidth, height: cardHeight + OverlayView.pillBottomInset)
    }
}

/// Kurze Notiz-Übersicht. Der Balken läuft ab, ein Klick öffnet den Ablageort.
struct NoteSavedCard: View {
    let text: String
    let place: String
    var dismissSeconds: Int = 0
    let onOpen: () -> Void
    let onClose: () -> Void
    @State private var remaining = 1.0
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "note.text")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.gradient)
                    Text(L10n.s("overlay.note.title"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer(minLength: 4)
                    Color.clear.frame(width: 18, height: 18)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 2)

                Text(place)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)

                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineSpacing(2)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
            .frame(width: NotePreviewLayout.cardWidth, height: NotePreviewLayout.cardHeight, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(white: 0.1).opacity(0.97))
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
            .padding(.trailing, 10)
        }
        .overlay {
            OverlayDismissChrome(remaining: remaining, timed: dismissSeconds > 0)
        }
        .softDropShadow(.menu)
        .onHover { hovering = $0 }
        .task(id: "\(text)\n\(place)\n\(dismissSeconds)") {
            await runDismissTimer()
        }
    }

    private func runDismissTimer() async {
        remaining = 1
        guard dismissSeconds > 0 else { return }
        let total = Double(dismissSeconds)
        var elapsed = 0.0
        let step = 0.05
        while elapsed < total {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
            if hovering { continue }
            elapsed += step
            remaining = max(0, 1 - elapsed / total)
        }
        if !Task.isCancelled { onClose() }
    }
}

/// Erkannter Diktat-Text mit Status (erkannt / eingefügt / kopiert) über dem Widget.
struct DictationPreviewCard: View {
    let text: String
    let status: DictationPreviewStatus
    var size: OverlayResultSize = .regular
    var dismissSeconds: Int = 0
    let onClose: () -> Void
    @State private var remaining = 1.0
    @State private var hovering = false

    private var cardWidth: CGFloat {
        DictationPreviewLayout.cardWidth(for: text, maxWidth: size.cardWidth)
    }

    private var textHeight: CGFloat {
        DictationPreviewLayout.textBlockHeight(
            for: text,
            cardWidth: cardWidth,
            maxTextHeight: size.cardMaxTextHeight
        )
    }

    private var scrolls: Bool {
        textHeight + 0.5 >= size.cardMaxTextHeight
    }

    private var statusTitle: String {
        switch status {
        case .working: return L10n.s("overlay.preview.recognized")
        case .inserted: return L10n.s("overlay.preview.inserted")
        case .copied: return L10n.s("overlay.preview.copied")
        }
    }

    private var statusIcon: String {
        switch status {
        case .working: return "text.badge.checkmark"
        case .inserted: return "checkmark.circle.fill"
        case .copied: return "doc.on.clipboard.fill"
        }
    }

    private var statusColor: Color {
        switch status {
        case .working: return .white.opacity(0.7)
        case .inserted: return .green
        case .copied: return .orange
        }
    }

    private var textBody: some View {
        Text(text)
            .font(.system(size: DictationPreviewLayout.textFontSize, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusColor)
                Text(statusTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if status == .working {
                    ThinkingWave().frame(width: 28, height: 12)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
                .padding(.horizontal, 14)

            Group {
                if scrolls {
                    ScrollView {
                        textBody
                    }
                } else {
                    textBody
                }
            }
            .frame(height: textHeight, alignment: .top)
            .padding(.bottom, 6)
        }
        .frame(width: cardWidth)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(white: 0.1).opacity(0.97))
        )
        .overlay {
            OverlayDismissChrome(remaining: remaining, timed: dismissSeconds > 0)
        }
        .softDropShadow(.menu)
        .onHover { hovering = $0 }
        .task(id: "\(text)\n\(String(describing: status))\n\(dismissSeconds)") {
            await runDismissTimer()
        }
    }

    private func runDismissTimer() async {
        remaining = 1
        guard dismissSeconds > 0 else {
            if status == .inserted { onClose() }
            return
        }
        let total = Double(dismissSeconds)
        var elapsed = 0.0
        let step = 0.05
        while elapsed < total {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
            if hovering { continue }
            elapsed += step
            remaining = max(0, 1 - elapsed / total)
        }
        if !Task.isCancelled { onClose() }
    }
}

/// Ergebnis eines Befehls, wenn kein Textfeld den Fokus hat – gleiche Sprache wie das Widget.
struct OverlayResultCard: View {
    let command: String
    let text: String
    var size: OverlayResultSize = .regular
    var dismissSeconds: Int = 0
    let onCopy: () -> Void
    let onClose: () -> Void
    @State private var remaining = 1.0
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.gradient)
                Text(L10n.s("overlay.result.title"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(L10n.s("overlay.result.copy"))
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if !command.isEmpty {
                Text(command)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
                .padding(.horizontal, 14)

            ScrollView {
                Text(text)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
            .frame(maxHeight: size.cardMaxTextHeight)
            .padding(.bottom, 6)
        }
        .frame(width: size.cardWidth)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(white: 0.1).opacity(0.97))
        )
        .overlay {
            OverlayDismissChrome(remaining: remaining, timed: dismissSeconds > 0)
        }
        .softDropShadow(.menu)
        .onHover { hovering = $0 }
        .task(id: "\(command)\n\(text)\n\(dismissSeconds)") {
            await runDismissTimer()
        }
    }

    private func runDismissTimer() async {
        remaining = 1
        guard dismissSeconds > 0 else { return }
        let total = Double(dismissSeconds)
        var elapsed = 0.0
        let step = 0.05
        while elapsed < total {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
            if hovering { continue }
            elapsed += step
            remaining = max(0, 1 - elapsed / total)
        }
        if !Task.isCancelled { onClose() }
    }
}

/// Verbreiterte Kontur; der farbige Balken läuft von rechts nach links ab.
private struct OverlayDismissChrome: View {
    var remaining: Double
    var timed: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.white.opacity(timed ? 0.16 : 0.1), lineWidth: timed ? 2 : 0.5)
            .overlay(alignment: .bottom) {
                if timed {
                    GeometryReader { geo in
                        Capsule()
                            .fill(Theme.gradient)
                            .frame(width: max(0, geo.size.width * remaining), height: 3)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    }
                    .frame(height: 3)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 2)
                    .allowsHitTesting(false)
                }
            }
            .allowsHitTesting(false)
    }
}

/// Auswahl zwischen Befehl und Umformulierung, wenn beides möglich ist.
struct OverlayChoiceCard: View {
    let spoken: String
    let choices: [OverlayResultChoice]
    var size: OverlayResultSize = .regular
    let onInsert: (OverlayResultChoice) -> Void
    let onCopy: (OverlayResultChoice) -> Void
    let onNote: (OverlayResultChoice) -> Void
    let onClose: () -> Void
    @State private var copiedID: String?
    @State private var notedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.gradient)
                Text(L10n.s("overlay.choice.title"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if !spoken.isEmpty {
                Text(spoken)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            Text(L10n.s("overlay.choice.lead"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            choiceRows
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .frame(width: size.cardWidth)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(white: 0.1).opacity(0.97))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                )
        )
        .softDropShadow(.menu)
    }

    private var choiceRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                if index > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 0.5)
                }
                OverlayChoiceRow(
                    choice: choice,
                    copied: copiedID == choice.id,
                    noted: notedID == choice.id,
                    onInsert: { onInsert(choice) },
                    onCopy: { markCopied(choice) },
                    onNote: { markNoted(choice) }
                )
            }
        }
    }

    private func markCopied(_ choice: OverlayResultChoice) {
        onCopy(choice)
        copiedID = choice.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedID == choice.id { copiedID = nil }
        }
    }

    private func markNoted(_ choice: OverlayResultChoice) {
        onNote(choice)
        notedID = choice.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if notedID == choice.id { notedID = nil }
        }
    }
}

private struct OverlayChoiceRow: View {
    let choice: OverlayResultChoice
    let copied: Bool
    let noted: Bool
    let onInsert: () -> Void
    let onCopy: () -> Void
    let onNote: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(choice.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Text(choice.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(5)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                OverlayChoiceAction(
                    title: L10n.s("overlay.choice.insert"),
                    systemImage: "arrow.down.to.line",
                    primary: true,
                    action: onInsert
                )
                OverlayChoiceAction(
                    title: copied ? L10n.s("overlay.choice.copied") : L10n.s("overlay.choice.copy"),
                    systemImage: copied ? "checkmark" : "doc.on.doc",
                    action: onCopy
                )
                OverlayChoiceAction(
                    title: noted ? L10n.s("overlay.choice.noted") : L10n.s("overlay.choice.note"),
                    systemImage: noted ? "checkmark" : "note.text.badge.plus",
                    action: onNote
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Kleines Modal über der Leiste – Sprachen als Codes, ohne Emoji-Flaggen.
struct TranslateMenuCard: View {
    let languages: [TranslateLanguage]
    var nativeId: String = ""
    let onPick: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.s("overlay.translate"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Text(L10n.s("overlay.replace"))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            VStack(spacing: 2) {
                ForEach(languages) { lang in
                    let isNative = lang.id == nativeId
                    Button {
                        onPick(lang.id)
                    } label: {
                        HStack(spacing: 10) {
                            Text(lang.id.uppercased())
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(isNative ? 1 : 0.9))
                                .frame(width: 28, height: 22)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(isNative ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.white.opacity(0.1)))
                                )
                            VStack(alignment: .leading, spacing: 1) {
                                Text(lang.name)
                                    .font(.system(size: 12.5, weight: isNative ? .semibold : .medium))
                                    .foregroundStyle(.white.opacity(isNative ? 0.95 : 0.88))
                                if isNative {
                                    Text(L10n.s("overlay.mine"))
                                        .font(.system(size: 9.5, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.38))
                                }
                            }
                            .lineLimit(1)
                            Spacer()
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.25))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(TranslateRowStyle())

                    if isNative {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 0.5)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
        .frame(width: 196)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(white: 0.1).opacity(0.97))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                )
        )
        .softDropShadow(.menu)
    }
}

private struct OverlayChoiceAction: View {
    let title: String
    let systemImage: String
    var primary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background {
                if primary {
                    Capsule().fill(Theme.gradient)
                } else {
                    Capsule().fill(Color.white.opacity(0.12))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct TranslateRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0))
            )
    }
}

private enum SoftShadowStyle {
    case bar, menu

    var cornerRadius: CGFloat {
        switch self {
        case .bar: return 999
        case .menu: return 14
        }
    }
}

private extension View {
    func softDropShadow(_ style: SoftShadowStyle) -> some View {
        modifier(SoftDropShadow(style: style))
    }
}

/// Layered blurred copies of the shape: a tight contact edge plus progressively wider, fainter
/// layers. Sums to a smooth gaussian falloff that follows the contour.
/// Needs ~18pt free space below and ~14pt at the sides, or the panel clips it.
private struct SoftDropShadow: ViewModifier {
    let style: SoftShadowStyle

    private static let layers: [(opacity: Double, blur: CGFloat, y: CGFloat)] = [
        (0.26, 0.6, 0.5),
        (0.14, 2.5, 1.5),
        (0.16, 7.0, 4.0)
    ]

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                ForEach(Self.layers.indices, id: \.self) { index in
                    let layer = Self.layers[index]
                    RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                        .fill(Color.black.opacity(layer.opacity))
                        .blur(radius: layer.blur)
                        .offset(y: layer.y)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

struct PulsingDot: View {
    @State private var on = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.red.opacity(0.35))
                .frame(width: 14, height: 14)
                .scaleEffect(on ? 1.2 : 0.55)
                .opacity(on ? 0 : 1)
            Circle().fill(Color.red).frame(width: 7, height: 7)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { on = true }
        }
    }
}

struct MirroredWaveform: View {
    let levels: [CGFloat]
    var bars = 23
    var color: Color = .white

    var body: some View {
        HStack(alignment: .center, spacing: 2.4) {
            ForEach(0..<bars, id: \.self) { index in
                let distance = abs(index - bars / 2)
                let source = max(0, levels.count - 1 - distance)
                let value = levels.isEmpty ? 0 : levels[source]
                let envelope = 1 - CGFloat(distance) / CGFloat(bars) * 1.1
                Capsule()
                    .fill(color.opacity(0.45 + 0.55 * envelope))
                    .frame(width: 2.4, height: max(3, 3 + value * 20 * envelope))
            }
        }
        .animation(.easeOut(duration: 0.1), value: levels)
    }
}

struct ThinkingWave: View {
    var bars = 7
    var color: Color = .white

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<bars, id: \.self) { index in
                    let phase = sin(time * 6.5 - Double(index) * 0.7)
                    Capsule()
                        .fill(color.opacity(0.85))
                        .frame(width: 2.5, height: 3 + 10 * CGFloat(0.5 + 0.5 * phase))
                }
            }
        }
    }
}
