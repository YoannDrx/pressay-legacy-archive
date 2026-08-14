#if APP_STORE
import AppKit
import Foundation

struct TextInjectionTarget {
    let snapshot: TargetSnapshot

    init(
        snapshot: TargetSnapshot,
        focusedElement: Any? = nil,
        selectionRange: CFRange? = nil,
        selectedText: String? = nil
    ) {
        self.snapshot = snapshot
    }
}

@MainActor
final class TextInjector: TextDelivering {
    static let shared = TextInjector()

    private(set) var lastDeliveryStrategy: DeliveryStrategy = .copied
    private(set) var lastDeliveryFailure: DeliveryFailureReason?
    var canUndoLastInsertion: Bool { false }

    private init() {}

    func inject(text: String, target: TextInjectionTarget?) async -> Bool {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else {
            lastDeliveryFailure = .emptyText
            return false
        }
        lastDeliveryFailure = .missingTarget
        return false
    }

    func injectDictation(text: String, target: TextInjectionTarget?) async -> Bool {
        await inject(text: text, target: target)
    }

    func copyToPasteboard(_ text: String) {
        lastDeliveryStrategy = .copied
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func undoLastInsertion() -> Bool { false }
    func prepareRecentInsertionForReplacement() -> Bool { false }

    static func hasAccessibilityPermission() -> Bool { false }
    static func requestAccessibilityPermission() {}
}
#else
import AppKit
import Carbon.HIToolbox
import OSLog

struct TextInjectionTarget {
    let snapshot: TargetSnapshot
    let focusedElement: AXUIElement?
    let selectionRange: CFRange?
    let selectedText: String?

    var processIdentifier: pid_t { snapshot.processIdentifier }

    init(
        snapshot: TargetSnapshot,
        focusedElement: AXUIElement?,
        selectionRange: CFRange? = nil,
        selectedText: String? = nil
    ) {
        self.snapshot = snapshot
        self.focusedElement = focusedElement
        self.selectionRange = selectionRange
        self.selectedText = selectedText
    }
}

@MainActor
final class TextInjector: TextDelivering {
    static let shared = TextInjector()
    private init() {}

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "fr.yodev.pressay",
        category: "TextDelivery"
    )

    private struct UndoToken {
        let target: TextInjectionTarget
        let insertedText: String
        let insertedUTF16Length: Int
        let expiresAt: Date
    }

    private var lastUndoToken: UndoToken?
    private(set) var lastDeliveryStrategy: DeliveryStrategy = .copied
    private(set) var lastDeliveryFailure: DeliveryFailureReason?

    var canUndoLastInsertion: Bool {
        guard let token = lastUndoToken else { return false }
        return token.expiresAt > Date()
    }

    func captureTargetApp() -> TextInjectionTarget? {
        AccessibilityContextService.shared.capture().target
    }

    func inject(text: String, target: TextInjectionTarget?) async -> Bool {
        await deliver(text: text, target: target, isInstantDictation: false)
    }

    func injectDictation(text: String, target: TextInjectionTarget?) async -> Bool {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return fail(.emptyText) }
        guard TextInjector.hasAccessibilityPermission() else {
            return fail(.accessibilityNotGranted)
        }
        guard let target else { return fail(.missingTarget) }
        guard !target.snapshot.isSecure else { return fail(.secureTarget) }
        guard let app = NSRunningApplication(
            processIdentifier: target.processIdentifier
        ), !app.isTerminated else {
            return fail(.targetApplicationUnavailable)
        }

        lastUndoToken = nil
        lastDeliveryStrategy = .copied
        lastDeliveryFailure = nil
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == target.processIdentifier else {
            return fail(.targetApplicationNotFrontmost)
        }

        // Pressay 1.2.7 used the target application's native Edit > Paste
        // command for Electron and browser editors. Unlike a synthetic CGEvent,
        // AXPress reports whether the application accepted the menu action.
        let didUseApplicationMenu = await ClipboardTransactionCoordinator.shared
            .pasteDictationUsingApplicationMenu(
                cleanText,
                processIdentifier: target.processIdentifier
            )
        if didUseApplicationMenu {
            lastDeliveryStrategy = .paste
            logger.notice(
                "Native application-menu paste accepted: pid=\(target.processIdentifier, privacy: .public)"
            )
            return true
        }

        // Some small native applications do not expose a conventional Paste
        // menu item. Keep the historical global shortcut only as a fallback.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(cleanText, forType: .string) else {
            return fail(.clipboardPasteFailed)
        }

        // NSPasteboard writes are handed to the shared pasteboard server. Give
        // it one short scheduling window before asking Electron/WebKit to read
        // the new value, then emit a real key-down/key-up gesture instead of
        // posting both events in the same run-loop instant.
        do {
            try await Task.sleep(for: .milliseconds(35))
        } catch {
            return fail(.clipboardPasteFailed)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == target.processIdentifier else {
            return fail(.targetApplicationNotFrontmost)
        }
        let didPaste = await Self.postPasteShortcut()
        lastDeliveryStrategy = didPaste ? .paste : .copied
        logger.notice(
            "Simple dictation paste posted: success=\(didPaste, privacy: .public), pid=\(target.processIdentifier, privacy: .public)"
        )
        return didPaste ? true : fail(.clipboardPasteFailed)
    }

    private static func postPasteShortcut() async -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_V),
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_V),
                  keyDown: false
              ) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        // Always emit key-up, including if the parent task is cancelled while
        // the gesture is in flight, so Command can never remain logically held.
        try? await Task.sleep(for: .milliseconds(15))
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func deliver(
        text: String,
        target: TextInjectionTarget?,
        isInstantDictation: Bool
    ) async -> Bool {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return fail(.emptyText) }
        guard TextInjector.hasAccessibilityPermission() else {
            return fail(.accessibilityNotGranted)
        }
        guard let target else { return fail(.missingTarget) }
        guard !target.snapshot.isSecure else { return fail(.secureTarget) }
        guard let app = NSRunningApplication(
            processIdentifier: target.processIdentifier
        ),
              !app.isTerminated else {
            return fail(.targetApplicationUnavailable)
        }
        let prefersPaste = prefersPasteDelivery(for: target)
        guard target.snapshot.isEditable || prefersPaste else {
            logger.error(
                """
                Non-editable AX target: role=\(target.snapshot.elementRole ?? "nil", privacy: .public), \
                subrole=\(target.snapshot.elementSubrole ?? "nil", privacy: .public), \
                selectedTextSettable=\(target.snapshot.canWriteSelectedText, privacy: .public), \
                valueSettable=\(target.snapshot.canWriteValue, privacy: .public)
                """
            )
            return fail(.nonEditableTarget)
        }
        lastUndoToken = nil
        lastDeliveryStrategy = .copied
        lastDeliveryFailure = nil

        let targetBundleIdentifier = target.snapshot.bundleIdentifier ?? "unknown"
        let deliveryStartedAt = Date()
        logger.notice(
            "Delivery started: instant=\(isInstantDictation, privacy: .public), target=\(targetBundleIdentifier, privacy: .public), pid=\(target.processIdentifier, privacy: .public), prefersPaste=\(prefersPaste, privacy: .public)"
        )

        guard await restoreTargetApplication(
            app,
            processIdentifier: target.processIdentifier,
            isInstantDictation: isInstantDictation
        ) else {
            return fail(.targetApplicationNotFrontmost)
        }
        guard windowStillMatches(target) else {
            return fail(.targetWindowChanged)
        }
        let usesTargetedPaste = DeliveryPreferencePolicy
            .shouldUseTargetedPaste(
                prefersPaste: prefersPaste,
                isInstantDictation: isInstantDictation
            )
        if MissingAccessibilityTargetPolicy.canUseTargetedPaste(
            bundleIdentifier: target.snapshot.bundleIdentifier,
            isInstantDictation: isInstantDictation,
            prefersPaste: prefersPaste,
            isSecure: target.snapshot.isSecure,
            hasFocusedElement: target.focusedElement != nil
        ) {
            logger.info(
                "Using targeted shortcut delivery for accessibility-limited target"
            )
            let didPaste = await ClipboardTransactionCoordinator.shared
                .pasteDictation(
                    cleanText,
                    processIdentifier: target.processIdentifier
                )
            lastDeliveryStrategy = didPaste ? .paste : .copied
            logger.notice(
                "Targeted-shortcut delivery ended: success=\(didPaste, privacy: .public), duration=\(Date().timeIntervalSince(deliveryStartedAt), format: .fixed(precision: 3), privacy: .public)s"
            )
            return didPaste ? true : fail(.clipboardPasteFailed)
        }
        guard let currentFocusedElement = currentFocusedElement(
            processIdentifier: target.processIdentifier
        ) else {
            if BrowserFocusLossPastePolicy.canUseTargetedPaste(
                bundleIdentifier: target.snapshot.bundleIdentifier,
                isInstantDictation: isInstantDictation,
                prefersPaste: prefersPaste,
                hadOriginalFocusedElement: target.focusedElement != nil,
                isSecure: target.snapshot.isSecure
            ) {
                logger.info(
                    "Using targeted shortcut delivery after browser focus loss"
                )
                let didPaste = await ClipboardTransactionCoordinator.shared
                    .pasteDictation(
                        cleanText,
                        processIdentifier: target.processIdentifier
                    )
                lastDeliveryStrategy = didPaste ? .paste : .copied
                logger.notice(
                    "Browser-focus delivery ended: success=\(didPaste, privacy: .public), duration=\(Date().timeIntervalSince(deliveryStartedAt), format: .fixed(precision: 3), privacy: .public)s"
                )
                return didPaste ? true : fail(.clipboardPasteFailed)
            }
            return fail(.focusedElementUnavailable)
        }
        guard let activeTarget = matchingFocusedTarget(
            target,
            currentElement: currentFocusedElement,
            allowsPasteOnlyTarget: prefersPaste
        ) else {
            return false
        }
        guard await selectionStillMatches(activeTarget) else {
            return fail(.selectionChanged)
        }

        let expectedPastedValue = activeTarget.focusedElement.flatMap {
            expectedValue(afterInserting: cleanText, in: $0)
        }

        if usesTargetedPaste {
            let didPaste = await ClipboardTransactionCoordinator.shared
                .pasteDictation(
                    cleanText,
                    processIdentifier: activeTarget.processIdentifier
                )
            guard didPaste else {
                logger.error("Target application refused the targeted paste shortcut")
                return fail(.clipboardPasteFailed)
            }
            if activeTarget.selectionRange != nil {
                rememberUndo(for: activeTarget, insertedText: cleanText)
            }
            lastDeliveryStrategy = .paste
            logger.notice(
                "Delivery completed with targeted paste in \(Date().timeIntervalSince(deliveryStartedAt), format: .fixed(precision: 3), privacy: .public)s"
            )
            return true
        }

        if DeliveryPreferencePolicy.shouldUseAccessibilityReplacement(
            canWriteSelectedText: activeTarget.snapshot.canWriteSelectedText,
            prefersPaste: prefersPaste,
            isInstantDictation: isInstantDictation
        ),
           await insertSelectedTextUsingAccessibility(
               cleanText,
               in: activeTarget
           ) {
            rememberUndo(for: activeTarget, insertedText: cleanText)
            lastDeliveryStrategy = .accessibilityReplacement
            return true
        }

        let pasteWasPosted = if isInstantDictation {
            await ClipboardTransactionCoordinator.shared.pasteDictation(
                cleanText,
                processIdentifier: activeTarget.processIdentifier
            )
        } else {
            await ClipboardTransactionCoordinator.shared.paste(cleanText)
        }
        let didPaste: Bool
        if isInstantDictation {
            // The keyboard event is posted only after the captured target is
            // frontmost and its focused element has been revalidated. Keeping
            // the clipboard alive briefly is necessary; waiting another half
            // second for often-stale AXValue propagation is not. Native and
            // Chromium editors can publish their old value after accepting the
            // paste, which delayed the terminal HUD state without improving
            // delivery safety.
            didPaste = pasteWasPosted
        } else if let element = activeTarget.focusedElement,
           let expectedPastedValue {
            didPaste = pasteWasPosted
                ? await value(of: element, becomes: expectedPastedValue.value)
                : false
        } else {
            didPaste = pasteWasPosted
        }
        if didPaste,
           activeTarget.focusedElement != nil,
           activeTarget.selectionRange != nil {
            rememberUndo(for: activeTarget, insertedText: cleanText)
        }
        lastDeliveryStrategy = didPaste ? .paste : .copied
        if !didPaste {
            return fail(.clipboardPasteFailed)
        }
        let completedStrategy = String(describing: lastDeliveryStrategy)
        logger.notice(
            "Delivery completed with strategy \(completedStrategy, privacy: .public) in \(Date().timeIntervalSince(deliveryStartedAt), format: .fixed(precision: 3), privacy: .public)s"
        )
        return didPaste
    }

    private func insertSelectedTextUsingAccessibility(
        _ text: String,
        in target: TextInjectionTarget
    ) async -> Bool {
        guard let element = target.focusedElement else {
            return false
        }
        let expectedValue = expectedValue(
            afterInserting: text,
            in: element
        )
        guard AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success else {
            return false
        }

        if let expectedValue,
           !(await value(of: element, becomes: expectedValue.value)) {
            // Chromium can apply AXSelectedText while continuing to publish a
            // stale AXValue. The setter only receives the new dictation, so it
            // cannot reintroduce text from an obsolete editor snapshot. Do not
            // retry with Cmd+V after a successful setter or text may duplicate.
            logger.debug(
                "Accessibility accepted selected-text insertion before AX verification caught up"
            )
        }
        return true
    }

    private func expectedValue(
        afterInserting text: String,
        in element: AXUIElement
    ) -> AccessibilityValueReplacement? {
        guard let currentValue = copiedString(
            attribute: kAXValueAttribute,
            from: element
        ),
              let range = selectedTextRange(from: element) else {
            return nil
        }
        return AccessibilityValueInsertion.replacingSelection(
            in: currentValue,
            location: range.location,
            length: range.length,
            with: text
        )
    }

    private func value(
        of element: AXUIElement,
        becomes expectedValue: String
    ) async -> Bool {
        for _ in 0..<20 {
            if copiedString(
                attribute: kAXValueAttribute,
                from: element
            ) == expectedValue {
                return true
            }
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    private func prefersPasteDelivery(for target: TextInjectionTarget) -> Bool {
        let application = NSRunningApplication(
            processIdentifier: target.processIdentifier
        )
        let isElectron = application?.bundleURL
            .flatMap(Bundle.init(url:))?
            .infoDictionary?["ElectronAsarIntegrity"] != nil
        let prefersPaste = DeliveryPreferencePolicy.prefersPaste(
            bundleIdentifier: target.snapshot.bundleIdentifier,
            isElectron: isElectron
        )
        if prefersPaste {
            logger.debug(
                "Using paste delivery for web/Electron target"
            )
        }
        return prefersPaste
    }

    func copyToPasteboard(_ text: String) {
        lastDeliveryStrategy = .copied
        lastDeliveryFailure = nil
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func undoLastInsertion() -> Bool {
        guard let token = lastUndoToken,
              token.expiresAt > Date(),
              let element = token.target.focusedElement,
              let originalRange = token.target.selectionRange,
              isOriginalTargetStillFocused(token.target),
              let currentRange = selectedTextRange(from: element),
              currentRange.location == originalRange.location + token.insertedUTF16Length,
              currentRange.length == 0 else {
            lastUndoToken = nil
            return false
        }

        var insertedRange = CFRange(
            location: originalRange.location,
            length: token.insertedUTF16Length
        )
        guard let rangeValue = AXValueCreate(.cfRange, &insertedRange),
              AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
              ) == .success,
              AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                (token.target.selectedText ?? "") as CFString
              ) == .success else {
            lastUndoToken = nil
            return false
        }

        var restoredRange = originalRange
        if let restoredRangeValue = AXValueCreate(.cfRange, &restoredRange) {
            _ = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                restoredRangeValue
            )
        }
        lastUndoToken = nil
        return true
    }

    func prepareRecentInsertionForReplacement() -> Bool {
        guard let token = lastUndoToken,
              token.expiresAt.addingTimeInterval(52) > Date(),
              let element = token.target.focusedElement,
              let originalRange = token.target.selectionRange,
              isOriginalTargetStillFocused(token.target),
              let currentRange = selectedTextRange(from: element),
              currentRange.location
                == originalRange.location + token.insertedUTF16Length,
              currentRange.length == 0 else {
            return false
        }

        var insertedRange = CFRange(
            location: originalRange.location,
            length: token.insertedUTF16Length
        )
        guard let rangeValue = AXValueCreate(.cfRange, &insertedRange),
              AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
              ) == .success,
              selectedText(from: element) == token.insertedText else {
            return false
        }
        lastUndoToken = nil
        return true
    }

    private func isOriginalTargetStillFocused(_ target: TextInjectionTarget) -> Bool {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier == target.processIdentifier,
              target.snapshot.bundleIdentifier == nil
                || application.bundleIdentifier == target.snapshot.bundleIdentifier else {
            return false
        }
        guard windowStillMatches(target) else { return false }
        return focusedElementStillMatches(target, recordsFailure: false)
    }

    private func focusedElementStillMatches(
        _ target: TextInjectionTarget,
        recordsFailure: Bool = true
    ) -> Bool {
        matchingFocusedTarget(target, recordsFailure: recordsFailure) != nil
    }

    private func matchingFocusedTarget(
        _ target: TextInjectionTarget,
        recordsFailure: Bool = true,
        allowsPasteOnlyTarget: Bool = false
    ) -> TextInjectionTarget? {
        guard target.focusedElement != nil else {
            if recordsFailure {
                _ = fail(.focusedElementUnavailable)
            }
            return nil
        }
        guard let currentElement = currentFocusedElement(
            processIdentifier: target.processIdentifier
        ) else {
            if recordsFailure {
                _ = fail(.focusedElementUnavailable)
            }
            return nil
        }
        return matchingFocusedTarget(
            target,
            currentElement: currentElement,
            recordsFailure: recordsFailure,
            allowsPasteOnlyTarget: allowsPasteOnlyTarget
        )
    }

    private func matchingFocusedTarget(
        _ target: TextInjectionTarget,
        currentElement: AXUIElement,
        recordsFailure: Bool = true,
        allowsPasteOnlyTarget: Bool = false
    ) -> TextInjectionTarget? {
        guard let originalElement = target.focusedElement else {
            if recordsFailure {
                _ = fail(.focusedElementUnavailable)
            }
            return nil
        }
        if CFEqual(currentElement, originalElement) {
            return target
        }
        let role = copiedString(
            attribute: kAXRoleAttribute,
            from: currentElement
        )
        let subrole = copiedString(
            attribute: kAXSubroleAttribute,
            from: currentElement
        )
        let isProtected = copiedBool(
            attribute: NSAccessibility.Attribute.containsProtectedContent.rawValue,
            from: currentElement
        )
        let isSecure = subrole == kAXSecureTextFieldSubrole as String
            || isProtected
        let canWriteSelectedText = isAttributeSettable(
            kAXSelectedTextAttribute,
            on: currentElement
        )
        let canWriteValue = isAttributeSettable(
            kAXValueAttribute,
            on: currentElement
        )
        let reportsEditable = copiedBool(
            attribute: kAXIsEditableAttribute,
            from: currentElement
        )
        let matches = FocusedElementValidator.matches(
            snapshot: target.snapshot,
            currentIdentifier: copiedString(
                attribute: kAXIdentifierAttribute,
                from: currentElement
            ),
            currentFrameHash: elementFrameHash(for: currentElement),
            currentRole: role,
            currentSubrole: subrole,
            currentIsSecure: isSecure,
            currentIsEditable: AccessibilityEditabilityPolicy.isEditable(
                role: role,
                isSecure: isSecure,
                reportsEditable: reportsEditable,
                canWriteSelectedText: canWriteSelectedText,
                canWriteValue: canWriteValue
            ),
            allowsPasteOnlyTarget: allowsPasteOnlyTarget
        )
        if !matches, recordsFailure {
            _ = fail(.focusedElementChanged)
        }
        guard matches else { return nil }
        return TextInjectionTarget(
            snapshot: target.snapshot,
            focusedElement: currentElement,
            selectionRange: target.selectionRange,
            selectedText: target.selectedText
        )
    }

    private func currentFocusedElement(
        processIdentifier: pid_t
    ) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(processIdentifier)
        var currentValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &currentValue
        ) == .success,
              let currentValue,
              CFGetTypeID(currentValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(currentValue, to: AXUIElement.self)
    }

    private func waitForTargetApplication(
        _ processIdentifier: pid_t,
        timeout: Duration = .seconds(1)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier
                == processIdentifier {
                return true
            }
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    private func restoreTargetApplication(
        _ application: NSRunningApplication,
        processIdentifier: pid_t,
        isInstantDictation: Bool
    ) async -> Bool {
        let frontmostProcessIdentifier = NSWorkspace.shared
            .frontmostApplication?.processIdentifier
        guard TargetActivationPolicy.shouldActivate(
            targetProcessIdentifier: processIdentifier,
            frontmostProcessIdentifier: frontmostProcessIdentifier
        ) else {
            return true
        }

        // macOS 14+ prefers a cooperative hand-off. Menu-bar and Control
        // Center interactions can still leave another process active, so give
        // that request a short opportunity before using the legacy force flag.
        // The fallback is intentionally scoped to the PID captured before the
        // recording; all window, focused-element and selection checks still run
        // before any text is delivered.
        NSApp.yieldActivation(to: application)
        _ = application.activate(
            from: NSRunningApplication.current,
            options: [.activateAllWindows]
        )
        if await waitForTargetApplication(
            processIdentifier,
            timeout: isInstantDictation
                ? .milliseconds(150)
                : .milliseconds(200)
        ) {
            return true
        }

        logger.notice(
            "Cooperative target activation did not complete; retrying captured PID"
        )
        _ = application.activate(
            options: [.activateAllWindows]
        )
        return await waitForTargetApplication(
            processIdentifier,
            timeout: isInstantDictation
                ? .milliseconds(350)
                : .seconds(1)
        )
    }

    private func selectedTextRange(from element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
    }

    private func selectionStillMatches(_ target: TextInjectionTarget) async -> Bool {
        let currentRange = target.focusedElement.flatMap(
            selectedTextRange(from:)
        )
        let currentAXText = target.focusedElement.flatMap(
            selectedText(from:)
        )
        let fallbackText: String?
        if target.snapshot.selectedTextHash != nil,
           !target.snapshot.canReadSelectedText {
            fallbackText = await ClipboardTransactionCoordinator.shared
                .captureSelection()
        } else {
            fallbackText = nil
        }
        return TargetSelectionValidator.matches(
            snapshot: target.snapshot,
            currentRange: currentRange,
            currentAXText: currentAXText,
            fallbackText: fallbackText
        )
    }

    private func selectedText(from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private func copiedString(
        attribute: String,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private func copiedBool(
        attribute: String,
        from element: AXUIElement
    ) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return false
        }
        return (value as? NSNumber)?.boolValue ?? false
    }

    private func isAttributeSettable(
        _ attribute: String,
        on element: AXUIElement
    ) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            element,
            attribute as CFString,
            &settable
        ) == .success && settable.boolValue
    }

    private func elementFrameHash(for element: AXUIElement) -> String? {
        guard let position = copiedPoint(
            attribute: kAXPositionAttribute,
            from: element
        ),
              let size = copiedSize(
                attribute: kAXSizeAttribute,
                from: element
              ) else {
            return nil
        }
        return SelectionFingerprint.hash(
            [
                stableCoordinate(position.x),
                stableCoordinate(position.y),
                stableCoordinate(size.width),
                stableCoordinate(size.height)
            ].joined(separator: "|")
        )
    }

    private func copiedPoint(
        attribute: String,
        from element: AXUIElement
    ) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private func copiedSize(
        attribute: String,
        from element: AXUIElement
    ) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

    private func stableCoordinate(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }

    private func rememberUndo(
        for target: TextInjectionTarget,
        insertedText: String
    ) {
        lastUndoToken = UndoToken(
            target: target,
            insertedText: insertedText,
            insertedUTF16Length: (insertedText as NSString).length,
            expiresAt: Date().addingTimeInterval(8)
        )
    }

    private func fail(_ reason: DeliveryFailureReason) -> Bool {
        lastDeliveryStrategy = .copied
        lastDeliveryFailure = reason
        logger.error("Delivery failed: \(reason.rawValue, privacy: .public)")
        return false
    }

    private func windowStillMatches(_ target: TextInjectionTarget) -> Bool {
        guard let expected = target.snapshot.windowIdentifier else {
            return true
        }
        let appElement = AXUIElementCreateApplication(target.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
              let windowValue,
              CFGetTypeID(windowValue) == AXUIElementGetTypeID() else {
            return false
        }
        let window = unsafeBitCast(windowValue, to: AXUIElement.self)
        var identifierValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            window,
            kAXIdentifierAttribute as CFString,
            &identifierValue
        ) == .success,
           let identifier = identifierValue as? String {
            return identifier == expected
        }
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &titleValue
        ) == .success,
              let title = titleValue as? String else {
            return false
        }
        return SelectionFingerprint.hash(
            "\(target.processIdentifier)|\(title)"
        ) == expected
    }

    nonisolated static func hasAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    nonisolated static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}

enum AccessibilityEditabilityPolicy {
    private static let textRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXSearchField"
    ]

    static func isEditable(
        role: String?,
        isSecure: Bool,
        reportsEditable: Bool,
        canWriteSelectedText: Bool,
        canWriteValue: Bool
    ) -> Bool {
        guard !isSecure else { return false }
        if textRoles.contains(role ?? "") || canWriteSelectedText {
            return true
        }
        return reportsEditable && canWriteValue
    }
}

enum DeliveryPreferencePolicy {
    private static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.brave.Browser",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser",
        "org.mozilla.firefox"
    ]

    static func prefersPaste(
        bundleIdentifier: String?,
        isElectron: Bool
    ) -> Bool {
        isElectron
            || isBrowser(bundleIdentifier: bundleIdentifier)
    }

    static func isBrowser(bundleIdentifier: String?) -> Bool {
        bundleIdentifier.map(browserBundleIdentifiers.contains) == true
    }

    static func shouldUseAccessibilityReplacement(
        canWriteSelectedText: Bool,
        prefersPaste: Bool,
        isInstantDictation: Bool
    ) -> Bool {
        canWriteSelectedText && !prefersPaste
    }

    static func shouldUseTargetedPaste(
        prefersPaste: Bool,
        isInstantDictation: Bool
    ) -> Bool {
        prefersPaste && isInstantDictation
    }

}

enum BrowserFocusLossPastePolicy {
    static func canUseTargetedPaste(
        bundleIdentifier: String?,
        isInstantDictation: Bool,
        prefersPaste: Bool,
        hadOriginalFocusedElement: Bool,
        isSecure: Bool
    ) -> Bool {
        isInstantDictation
            && prefersPaste
            && hadOriginalFocusedElement
            && !isSecure
            && DeliveryPreferencePolicy.isBrowser(
                bundleIdentifier: bundleIdentifier
            )
    }
}

enum TargetActivationPolicy {
    static func shouldActivate(
        targetProcessIdentifier: pid_t,
        frontmostProcessIdentifier: pid_t?
    ) -> Bool {
        targetProcessIdentifier != frontmostProcessIdentifier
    }
}

enum MissingAccessibilityTargetPolicy {
    // Codex and Chromium web editors can keep their native/DOM focus while
    // temporarily publishing no AXFocusedUIElement. The caller has already
    // restored the captured application and verified the captured window;
    // keep the fallback limited to instant paste delivery and known browsers
    // instead of applying it to every Electron application.
    private static let compatibleBundleIdentifiers: Set<String> = ["com.openai.codex"]

    static func canUseTargetedPaste(
        bundleIdentifier: String?,
        isInstantDictation: Bool,
        prefersPaste: Bool,
        isSecure: Bool,
        hasFocusedElement: Bool
    ) -> Bool {
        guard isInstantDictation,
              prefersPaste,
              !isSecure,
              !hasFocusedElement,
              let bundleIdentifier else {
            return false
        }
        return compatibleBundleIdentifiers.contains(bundleIdentifier)
            || DeliveryPreferencePolicy.isBrowser(
                bundleIdentifier: bundleIdentifier
            )
    }
}

#endif

struct AccessibilityValueReplacement: Equatable {
    let value: String
    let cursorLocation: Int
}

enum AccessibilityValueInsertion {
    static func replacingSelection(
        in currentValue: String,
        location: Int,
        length: Int,
        with insertedText: String
    ) -> AccessibilityValueReplacement? {
        let value = currentValue as NSString
        guard location >= 0,
              length >= 0,
              location <= value.length,
              length <= value.length - location else {
            return nil
        }
        return AccessibilityValueReplacement(
            value: value.replacingCharacters(
                in: NSRange(location: location, length: length),
                with: insertedText
            ),
            cursorLocation: location + (insertedText as NSString).length
        )
    }
}

enum FocusedElementValidator {
    static func matches(
        snapshot: TargetSnapshot,
        currentIdentifier: String?,
        currentFrameHash: String?,
        currentRole: String?,
        currentSubrole: String?,
        currentIsSecure: Bool,
        currentIsEditable: Bool,
        allowsPasteOnlyTarget: Bool = false
    ) -> Bool {
        guard !currentIsSecure,
              currentIsEditable || allowsPasteOnlyTarget,
              currentRole == snapshot.elementRole,
              currentSubrole == snapshot.elementSubrole else {
            return false
        }
        if let expectedIdentifier = snapshot.elementIdentifier {
            guard currentIdentifier == expectedIdentifier else {
                return false
            }
            if let expectedFrameHash = snapshot.elementFrameHash {
                return currentFrameHash == expectedFrameHash
            }
            return true
        }
        guard let expectedFrameHash = snapshot.elementFrameHash else {
            return false
        }
        return currentFrameHash == expectedFrameHash
    }
}

enum TargetSelectionValidator {
    static func matches(
        snapshot: TargetSnapshot,
        currentRange: CFRange?,
        currentAXText: String?,
        fallbackText: String?
    ) -> Bool {
        if let expectedLocation = snapshot.selectionLocation,
           let expectedLength = snapshot.selectionLength {
            guard let currentRange,
                  currentRange.location == expectedLocation,
                  currentRange.length == expectedLength else {
                return false
            }
        }

        guard let expectedHash = snapshot.selectedTextHash else {
            return true
        }
        let currentText: String?
        if snapshot.canReadSelectedText {
            currentText = currentAXText
        } else {
            currentText = fallbackText
        }
        guard let currentText else { return false }
        return SelectionFingerprint.hash(currentText) == expectedHash
    }
}
