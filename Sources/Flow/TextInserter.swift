import ApplicationServices
import Cocoa

struct DictationAnchor {
    let element: AXUIElement
    let location: Int
    let following: String
}

struct InsertResult {
    var pasted: Bool
    /// Text bleibt in der Zwischenablage (kein Textfeld / kein AX) – Nutzer kann ⌘V oder ⌘⇧V.
    var keptOnClipboard: Bool
}

final class TextInserter {
    private var restoreWork: DispatchWorkItem?
    /// Textfeld, das beim Start der Aufnahme den Fokus hatte. Der Klick auf
    /// „Einfügen“ liegt im Overlay und darf nicht als neues Ziel gelten.
    private var rememberedInsert: RememberedInsert?
    /// Plain text of the clipboard captured for this paste session.
    private var pendingClipboardText: String?
    /// Previous clipboard text when a paste did not land in a field. The caller keeps it in history.
    var onDisplacedClipboard: ((String) -> Void)?

    func selectedText() -> String? {
        guard let element = focusedElement() else { return nil }
        return accepted(copyString(element, kAXSelectedTextAttribute as CFString))
    }

    /// Accessibility first. A copy keystroke only when no element could say whether a selection exists.
    /// Editors that copy the current line on ⌘C with an empty caret stay on the accessibility answer.
    func captureSelection() async -> String? {
        if Task.isCancelled { return nil }
        let probe = probeAccessibility()
        if Task.isCancelled { return nil }
        switch probe {
        case .text(let text):
            Timing.mark("selection via accessibility (\(text.count) chars)")
            return text
        case .none:
            Timing.mark("selection confirmed empty")
            return nil
        case .unknown:
            let copied = await copySelectionProbe()
            if let copied {
                Timing.mark("selection via copy (\(copied.count) chars)")
            } else {
                Timing.mark("selection copy found nothing")
            }
            return copied
        }
    }

    func hasEditableFocus() -> Bool {
        guard Permissions.accessibilityGranted(), let element = focusedElement() else { return false }
        return isEditable(element)
    }

    func hasInsertableFocus() -> Bool {
        guard Permissions.accessibilityGranted(), let element = focusedElement() else { return false }
        return isInsertable(element)
    }

    init() {
        // Electron/Chromium apps can stall AX queries for seconds (default timeout 6s).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
    }

    /// Merkt sich Fokus und Markierung, solange noch die Ziel-App aktiv ist.
    func rememberInsertTarget() {
        guard Permissions.accessibilityGranted(), let element = focusedElement() else {
            rememberedInsert = nil
            return
        }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != 0, pid != ProcessInfo.processInfo.processIdentifier else {
            rememberedInsert = nil
            return
        }
        rememberedInsert = RememberedInsert(
            element: element,
            range: selectedRange(of: element),
            pid: pid
        )
    }

    /// Ersetzt die gemerkte Markierung oder fügt am gemerkten Cursor ein.
    func insertAtRememberedCursor(
        _ text: String,
        fallbackBundleID: String?,
        completion: @escaping (InsertResult) -> Void
    ) {
        if replaceRememberedSelection(with: text) {
            Timing.mark("insert: accessibility replace")
            completion(InsertResult(pasted: true, keptOnClipboard: false))
            return
        }
        activateRememberedApp(fallbackBundleID: fallbackBundleID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self else { return }
            self.focusRememberedField()
            if self.replaceRememberedSelection(with: text) {
                Timing.mark("insert: accessibility replace after focus")
                completion(InsertResult(pasted: true, keptOnClipboard: false))
                return
            }
            completion(self.insert(text))
        }
    }

    @discardableResult
    func insert(_ text: String) -> InsertResult {
        Timing.mark("insert: start")
        restoreWork?.cancel()
        let captured = captureClipboard()
        Timing.mark("insert: clipboard saved (\(captured.items.types.count) types)")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let trusted = Permissions.accessibilityGranted()
        if !trusted {
            // Without accessibility ⌘V cannot be posted. Text stays copied for manual paste.
            dropPendingClipboard()
            keepDisplaced(captured.text, replacedBy: text)
            return InsertResult(pasted: false, keptOnClipboard: true)
        }

        post(key: 9, flags: .maskCommand)
        Timing.mark("insert: ⌘V posted")
        pendingClipboardText = captured.text
        scheduleRestore(captured.items, after: text)
        let editable = hasInsertableFocus()
        Timing.mark("insert: focus checked (editable=\(editable))")
        return InsertResult(pasted: true, keptOnClipboard: false)
    }

    /// Replaces the just-inserted raw text with `text`, but only if the characters right before the
    /// caret are verifiably `raw`. Returns false without touching anything otherwise – an unverified
    /// replace (e.g. ⌘Z + ⌘V) inserts the text twice in apps whose undo doesn't cover the paste.
    func replacePreviousInsert(raw: String, with text: String) -> Bool {
        guard Permissions.accessibilityGranted(),
              let element = focusedElement(),
              let range = rangeOfJustInserted(raw, in: element) else { return false }

        var cfRange = range
        guard let axRange = AXValueCreate(.cfRange, &cfRange),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success
        else { return false }

        // Some apps accept the set call but ignore it; never paste over an unexpected selection.
        guard selectedRawText(of: element) == raw else {
            var caret = CFRange(location: range.location + range.length, length: 0)
            if let back = AXValueCreate(.cfRange, &caret) {
                AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, back)
            }
            return false
        }

        restoreWork?.cancel()
        let captured = captureClipboard()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        post(key: 9, flags: .maskCommand)
        pendingClipboardText = captured.text
        scheduleRestore(captured.items, after: text)
        return true
    }

    /// Diagnostics: logs when `raw` actually shows up before the caret of the focused field.
    func logWhenLanded(_ raw: String, attempt: Int = 0) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self, Permissions.accessibilityGranted() else { return }
            if let element = self.focusedElement(), self.rangeOfJustInserted(raw, in: element) != nil {
                Timing.mark("text visible in target field")
                return
            }
            guard attempt < 40 else {
                Timing.mark("text not verifiable in target field after 3s")
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.logWhenLanded(raw, attempt: attempt + 1)
            }
        }
    }

    /// Where `inserted` currently sits, plus a short tail of the text that follows it.
    func locateInsert(_ inserted: String) -> DictationAnchor? {
        guard Permissions.accessibilityGranted(),
              let element = focusedElement(),
              let range = rangeOfJustInserted(inserted, in: element) else { return nil }
        let tail = text(
            in: CFRange(location: range.location + range.length, length: 24),
            of: element
        ) ?? ""
        return DictationAnchor(element: element, location: range.location, following: tail)
    }

    /// The text that now occupies the inserted span. Nil when the field can no longer be read.
    func text(at anchor: DictationAnchor, original: String) -> String? {
        let originalLength = (original as NSString).length
        guard originalLength > 0 else { return nil }
        let followingLength = (anchor.following as NSString).length
        let available = characterCount(anchor.element).map { max(0, $0 - anchor.location) }
        let preferred = originalLength + 80 + followingLength
        let length = min(preferred, available ?? preferred)
        guard length > 0,
              let chunk = text(in: CFRange(location: anchor.location, length: length), of: anchor.element)
        else { return nil }
        if anchor.following.isEmpty {
            return chunk
        }
        guard let tail = chunk.range(of: anchor.following) else { return nil }
        return String(chunk[..<tail.lowerBound])
    }

    private func characterCount(_ element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &value) == .success
        else { return nil }
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private func scheduleRestore(_ saved: ClipboardSnapshot, after text: String) {
        let work = DispatchWorkItem { [weak self] in
            self?.restoreBoard(saved)
            self?.sessionSnapshot = nil
            self?.pendingClipboardText = nil
            Timing.mark("insert: clipboard restored")
        }
        restoreWork = work
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.waitUntilVisible(text, timeout: 1.15)
            Thread.sleep(forTimeInterval: 0.08)
            DispatchQueue.main.async {
                guard self?.restoreWork === work else { return }
                work.perform()
            }
        }
    }

    private func waitUntilVisible(_ raw: String, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Permissions.accessibilityGranted(),
               let element = focusedElement(),
               rangeOfJustInserted(raw, in: element) != nil {
                return
            }
            Thread.sleep(forTimeInterval: 0.04)
        }
    }

    /// Range of `raw` ending exactly at the caret, in UTF-16 units as AX expects.
    private func rangeOfJustInserted(_ raw: String, in element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var caret = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &caret), caret.length == 0 else { return nil }

        let length = (raw as NSString).length
        guard length > 0, caret.location >= length else { return nil }
        let candidate = CFRange(location: caret.location - length, length: length)
        guard text(in: candidate, of: element) == raw else { return nil }
        return candidate
    }

    private func text(in range: CFRange, of element: AXUIElement) -> String? {
        var cfRange = range
        if let axRange = AXValueCreate(.cfRange, &cfRange) {
            var result: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, axRange, &result
            ) == .success, let string = result as? String {
                return string
            }
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let full = value as? NSString,
              range.location + range.length <= full.length else { return nil }
        return full.substring(with: NSRange(location: range.location, length: range.length))
    }

    private func selectedRawText(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    func frontmostAppName() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return app.localizedName
    }

    func copyToClipboard(_ text: String) {
        restoreWork?.cancel()
        let displaced = pendingClipboardText ?? sessionSnapshot?.text
        dropPendingClipboard()
        keepDisplaced(displaced, replacedBy: text)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private enum SelectionProbe {
        case text(String)
        case none
        case unknown
    }

    private func probeAccessibility() -> SelectionProbe {
        guard Permissions.accessibilityGranted(), let root = focusedElement() else { return .unknown }
        let deadline = Date().addingTimeInterval(1.1)
        var elements = [root]
        var ancestor = parent(of: root)
        var hops = 0
        while let current = ancestor, hops < 5, Date() < deadline {
            elements.append(current)
            ancestor = parent(of: current)
            hops += 1
        }
        var queue = [root]
        var seen = 0
        while !queue.isEmpty, elements.count < 14, Date() < deadline {
            let node = queue.removeFirst()
            for child in children(of: node).prefix(6) {
                elements.append(child)
                queue.append(child)
                seen += 1
                if seen >= 12 || elements.count >= 14 { break }
            }
        }

        var sawEmptyCaret = false
        var sawPositiveRange = false
        for element in elements {
            if Date() >= deadline { break }
            AXUIElementSetMessagingTimeout(element, 0.35)
            if let text = accepted(copyString(element, kAXSelectedTextAttribute as CFString)) {
                return .text(text)
            }
            if let text = accepted(webSelectedText(of: element)) {
                return .text(text)
            }
            if let range = selectedRange(of: element) {
                if range.length > 0 {
                    sawPositiveRange = true
                    if let text = accepted(text(in: range, of: element)) {
                        return .text(text)
                    }
                } else if CFEqual(element, root) {
                    sawEmptyCaret = true
                }
            }
        }
        if sawPositiveRange { return .unknown }
        if sawEmptyCaret { return .none }
        return .unknown
    }

    @MainActor
    private func copySelectionProbe() -> String? {
        guard !Task.isCancelled else { return nil }
        restoreWork?.cancel()
        let snap = snapshotBoard()
        let board = NSPasteboard.general
        let beforeCount = board.changeCount
        post(key: 8, flags: .maskCommand)
        let deadline = Date().addingTimeInterval(0.28)
        var copied: String?
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            if board.changeCount != beforeCount {
                copied = board.string(forType: .string)
                break
            }
        }
        restoreBoard(snap)
        return accepted(copied)
    }

    private func accepted(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 20_000 else { return nil }
        return text
    }

    private func copyString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        var result: [AXUIElement] = []
        for item in value as! NSArray {
            let cf = item as CFTypeRef
            guard CFGetTypeID(cf) == AXUIElementGetTypeID() else { continue }
            result.append(item as! AXUIElement)
        }
        return result
    }

    private func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value else { return nil }
        let ax = value as! AXValue
        guard AXValueGetType(ax) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(ax, .cfRange, &range) else { return nil }
        return range
    }

    private func webSelectedText(of element: AXUIElement) -> String? {
        var marker: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &marker) == .success,
              let marker else { return nil }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element, "AXStringForTextMarkerRange" as CFString, marker, &value
        )
        guard error == .success else { return nil }
        return value as? String
    }

    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value)
        guard error == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        // The system element is capped at 0.25s. The focused element keeps the
        // 6s default and would freeze the hotkey until it returns.
        AXUIElementSetMessagingTimeout(element, 0.2)
        return element
    }

    private func isEditable(_ element: AXUIElement) -> Bool {
        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? ""

        var editableValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editableValue) == .success,
           let editable = editableValue as? Bool {
            return editable
        }

        let editableRoles: Set<String> = [
            "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
            "AXWebArea", "AXTextEditor"
        ]
        if editableRoles.contains(role) { return true }

        // Manche Apps (Electron) melden AXGroup mit gesetztem SelectedText.
        var selected: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success {
            return true
        }
        return false
    }

    private func isInsertable(_ element: AXUIElement) -> Bool {
        var editableValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editableValue) == .success,
           let editable = editableValue as? Bool {
            return editable
        }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? ""
        let editableRoles: Set<String> = [
            "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXTextEditor"
        ]
        return editableRoles.contains(role)
    }

    private struct ClipboardSnapshot {
        var types: [NSPasteboard.PasteboardType]
        var data: [NSPasteboard.PasteboardType: Data]
        var text: String?
        var isEmpty: Bool { data.isEmpty }
    }

    private var sessionSnapshot: ClipboardSnapshot?

    private func captureClipboard() -> (items: ClipboardSnapshot, text: String?) {
        if let sessionSnapshot {
            return (sessionSnapshot, pendingClipboardText ?? sessionSnapshot.text)
        }
        let snap = snapshotBoard()
        sessionSnapshot = snap
        return (snap, snap.text)
    }

    private func currentPlainText() -> String? {
        let board = NSPasteboard.general
        if let text = board.string(forType: .string) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return text }
        }
        if let data = board.data(forType: .rtf),
           let rich = NSAttributedString(rtf: data, documentAttributes: nil) {
            let text = rich.string
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return text }
        }
        return nil
    }

    /// Keeps the previous clipboard text when this paste stays on the clipboard instead of a field.
    private func keepDisplaced(_ previous: String?, replacedBy inserted: String) {
        guard let previous else { return }
        let trimmed = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200_000 else { return }
        guard trimmed != inserted.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        onDisplacedClipboard?(previous)
    }

    private func dropPendingClipboard() {
        pendingClipboardText = nil
        sessionSnapshot = nil
    }

    private func snapshotBoard() -> ClipboardSnapshot {
        let board = NSPasteboard.general
        var data: [NSPasteboard.PasteboardType: Data] = [:]
        var types: [NSPasteboard.PasteboardType] = []
        for type in board.types ?? [] {
            guard let payload = board.data(forType: type), !payload.isEmpty else { continue }
            types.append(type)
            data[type] = payload
        }
        return ClipboardSnapshot(types: types, data: data, text: currentPlainText())
    }

    private func restoreBoard(_ snapshot: ClipboardSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        pasteboard.declareTypes(snapshot.types, owner: nil)
        for type in snapshot.types {
            if let payload = snapshot.data[type] {
                pasteboard.setData(payload, forType: type)
            }
        }
    }

    private struct RememberedInsert {
        var element: AXUIElement
        var range: CFRange?
        var pid: pid_t
    }

    private func activateRememberedApp(fallbackBundleID: String?) {
        if let pid = rememberedInsert?.pid,
           let app = NSRunningApplication(processIdentifier: pid),
           app.bundleIdentifier != Bundle.main.bundleIdentifier {
            app.activate(from: .current, options: [])
            return
        }
        guard let fallbackBundleID,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: fallbackBundleID).first
        else { return }
        app.activate(from: .current, options: [])
    }

    private func focusRememberedField() {
        guard let rememberedInsert else { return }
        AXUIElementSetAttributeValue(rememberedInsert.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard var range = rememberedInsert.range, range.location >= 0,
              let axRange = AXValueCreate(.cfRange, &range) else { return }
        AXUIElementSetAttributeValue(rememberedInsert.element, kAXSelectedTextRangeAttribute as CFString, axRange)
    }

    private func replaceRememberedSelection(with text: String) -> Bool {
        guard let rememberedInsert else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            rememberedInsert.element,
            kAXSelectedTextAttribute as CFString,
            &settable
        ) == .success, settable.boolValue else { return false }
        focusRememberedField()
        return AXUIElementSetAttributeValue(
            rememberedInsert.element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success
    }

    private func post(key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
