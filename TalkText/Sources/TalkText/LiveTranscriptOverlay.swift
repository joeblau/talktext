import AppKit
import ApplicationServices
import QuartzCore

/// Shows the live transcript near the cursor while recording. Words the
/// recognizer has not settled on are drawn faint and develop to full strength
/// as passes confirm them. The text field itself is only written once, when
/// the final transcript is ready.
@MainActor
protocol LiveTranscriptOverlaying: AnyObject {
    /// `confirmedCharacters` counts characters of `text`, from the start, that
    /// are settled. The first call of a session places the overlay.
    func show(_ text: String, confirmedCharacters: Int, near target: PasteTarget?)
    /// Develops the whole final transcript, then fades the overlay out.
    func complete(with text: String)
    func dismiss()
}

/// Used where no overlay should appear, such as tests.
@MainActor
final class DisabledLiveTranscriptOverlay: LiveTranscriptOverlaying {
    func show(_ text: String, confirmedCharacters: Int, near target: PasteTarget?) {}
    func complete(with text: String) {}
    func dismiss() {}
}

/// Pure opacity curve for the confirmation sweep: full strength behind the
/// boundary and faint ahead of it. While the boundary moves, its edge softens
/// into a gradient up to a few characters wide; at rest the edge is crisp, so
/// confirmed text is fully solid and unconfirmed text uniformly faint.
enum ConfirmationSweep {
    static let unconfirmedOpacity: CGFloat = 0.35
    static let gradientWidth: CGFloat = 2.5

    static func opacity(forCharacterAt index: Int, boundary: CGFloat, softness: CGFloat = 0) -> CGFloat {
        let center = CGFloat(index) + 0.5
        guard softness > 0.01 else { return center < boundary ? 1 : unconfirmedOpacity }
        let progress = (center - (boundary - softness / 2)) / softness
        let clamped = min(1, max(0, progress))
        return 1 - clamped * (1 - unconfirmedOpacity)
    }

    /// Edge width over a sweep: grows from crisp, peaks mid-sweep, and
    /// settles crisp again, so starting or ending a sweep never flickers.
    static func softness(atProgress progress: Double) -> CGFloat {
        gradientWidth * CGFloat(sin(.pi * min(1, max(0, progress))))
    }
}

@MainActor
final class SystemLiveTranscriptOverlay: NSObject, LiveTranscriptOverlaying {
    private static let maximumWidth: CGFloat = 460
    private static let maximumCharacters = 320
    private static let padding = NSSize(width: 12, height: 8)
    private static let caretGap: CGFloat = 6
    private static let sweepDuration: CFTimeInterval = 0.15
    private static let completionHold: TimeInterval = 0.3

    private var panel: NSPanel?
    private let label = NSTextField(wrappingLabelWithString: "")
    private var displayLink: CADisplayLink?
    private var dismissal: DispatchWorkItem?

    private var text = ""
    /// Character index of the confirmation boundary as currently drawn.
    private var drawnBoundary: CGFloat = 0
    private var drawnSoftness: CGFloat = 0
    private var sweep: (from: CGFloat, to: CGFloat, start: CFTimeInterval)?
    /// Where the overlay hangs from, in screen coordinates, and whether it
    /// sits below the caret (growing down) or above it (growing up).
    private var anchor: (point: NSPoint, below: Bool)?

    func show(_ text: String, confirmedCharacters: Int, near target: PasteTarget?) {
        cancelDismissal()
        if anchor == nil {
            anchor = Self.anchor(for: CaretLocator.caretRect(for: target))
        }
        setText(text, confirmedCharacters: confirmedCharacters)
        present()
    }

    func complete(with text: String) {
        guard anchor != nil else { return }
        cancelDismissal()
        setText(text, confirmedCharacters: text.count)
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sweepDuration + Self.completionHold, execute: work)
    }

    func dismiss() {
        cancelDismissal()
        fadeOut()
    }

    private func setText(_ newText: String, confirmedCharacters: Int) {
        text = newText
        let target = CGFloat(min(max(0, confirmedCharacters), newText.count))
        drawnBoundary = min(drawnBoundary, CGFloat(newText.count))
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || target < drawnBoundary {
            // A correction moves the boundary back at once rather than un-developing text.
            drawnBoundary = target
            drawnSoftness = 0
            sweep = nil
        } else if target != drawnBoundary {
            sweep = (drawnBoundary, target, CACurrentMediaTime())
            startDisplayLink()
        }
        render()
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let current = sweep else {
            stopDisplayLink()
            return
        }
        let elapsed = CACurrentMediaTime() - current.start
        let progress = min(1, elapsed / Self.sweepDuration)
        let eased = 1 - pow(1 - progress, 3)
        drawnBoundary = current.from + (current.to - current.from) * CGFloat(eased)
        drawnSoftness = ConfirmationSweep.softness(atProgress: progress)
        if progress >= 1 {
            drawnBoundary = current.to
            drawnSoftness = 0
            sweep = nil
        }
        render()
    }

    private func render() {
        // Show the most recent speech; long dictations keep only their tail.
        var visible = Substring(text)
        var skipped = 0
        if text.count > Self.maximumCharacters {
            skipped = text.count - Self.maximumCharacters
            visible = text.dropFirst(skipped)
            if let space = visible.firstIndex(where: \.isWhitespace) {
                skipped += visible.distance(from: visible.startIndex, to: space) + 1
                visible = visible[visible.index(after: space)...]
            }
        }
        let font = NSFont.systemFont(ofSize: 15)
        let attributed = NSMutableAttributedString()
        if skipped > 0 {
            attributed.append(NSAttributedString(string: "… ", attributes: [
                .font: font, .foregroundColor: NSColor.labelColor,
            ]))
        }
        for (offset, character) in visible.enumerated() {
            let opacity = ConfirmationSweep.opacity(
                forCharacterAt: skipped + offset, boundary: drawnBoundary, softness: drawnSoftness
            )
            attributed.append(NSAttributedString(string: String(character), attributes: [
                .font: font, .foregroundColor: NSColor.labelColor.withAlphaComponent(opacity),
            ]))
        }
        label.attributedStringValue = attributed
        layout()
    }

    private func layout() {
        guard let panel, let anchor else { return }
        label.preferredMaxLayoutWidth = Self.maximumWidth
        let textSize = label.fittingSize
        let size = NSSize(
            width: ceil(min(Self.maximumWidth, textSize.width)) + Self.padding.width * 2,
            height: ceil(textSize.height) + Self.padding.height * 2
        )
        var origin = NSPoint(x: anchor.point.x - Self.padding.width, y: anchor.below ? anchor.point.y - size.height : anchor.point.y)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.point) }) ?? NSScreen.main {
            let bounds = screen.visibleFrame
            origin.x = min(max(bounds.minX, origin.x), bounds.maxX - size.width)
            origin.y = min(max(bounds.minY, origin.y), bounds.maxY - size.height)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        label.frame = NSRect(
            x: Self.padding.width, y: Self.padding.height,
            width: size.width - Self.padding.width * 2, height: size.height - Self.padding.height * 2
        )
    }

    private func present() {
        let panel = panel ?? makePanel()
        self.panel = panel
        layout()
        guard !panel.isVisible || panel.alphaValue < 1 else { return }
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            panel.animator().alphaValue = 1
        }
    }

    private func fadeOut() {
        stopDisplayLink()
        sweep = nil
        anchor = nil
        drawnBoundary = 0
        drawnSoftness = 0
        text = ""
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                // A new session may have shown the overlay during the fade.
                guard let self, self.anchor == nil else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    private func cancelDismissal() {
        dismissal?.cancel()
        dismissal = nil
    }

    private func startDisplayLink() {
        guard displayLink == nil, let view = panel?.contentView ?? makePanel().contentView else { return }
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func makePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.setAccessibilityElement(false)

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.isSelectable = false
        background.addSubview(label)
        panel.contentView = background
        self.panel = panel
        return panel
    }

    /// Hangs the overlay just below the caret line, or above it when the caret
    /// is near the bottom of the screen.
    private static func anchor(for caret: NSRect?) -> (point: NSPoint, below: Bool) {
        let rect = caret ?? NSRect(origin: NSEvent.mouseLocation, size: .zero)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(rect.origin) }) ?? NSScreen.main
        let roomBelow = rect.minY - (screen?.visibleFrame.minY ?? 0)
        if roomBelow > 120 {
            return (NSPoint(x: rect.minX, y: rect.minY - caretGap), true)
        }
        return (NSPoint(x: rect.minX, y: rect.maxY + caretGap), false)
    }
}

/// Finds the text cursor on screen through Accessibility.
enum CaretLocator {
    /// The caret's rectangle in AppKit screen coordinates, or the focused
    /// field's top edge when the app does not report the caret itself.
    @MainActor
    static func caretRect(for target: PasteTarget?) -> NSRect? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        if let target {
            var owner: pid_t = 0
            guard AXUIElementGetPid(element, &owner) == .success,
                  SystemLiveTextElement.accepts(
                      elementProcessIdentifier: owner,
                      target: target,
                      frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
                  ) else { return nil }
        }
        if let caret = insertionPointBounds(of: element) { return appKitRect(fromAccessibility: caret) }
        guard let frame = frame(of: element), frame.height > 0 else { return nil }
        // Without a caret, hang the overlay from the field's first line.
        let firstLine = CGRect(x: frame.minX, y: frame.minY, width: 0, height: min(frame.height, 22))
        return appKitRect(fromAccessibility: firstLine)
    }

    private static func insertionPointBounds(of element: AXUIElement) -> CGRect? {
        var selectionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectionValue) == .success,
              let selectionValue, CFGetTypeID(selectionValue) == AXValueGetTypeID() else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(unsafeDowncast(selectionValue, to: AXValue.self), .cfRange, &selection) else { return nil }
        // Some apps report an empty range as zero-sized; the previous character's
        // trailing edge marks the same spot.
        let caret = CFRange(location: selection.location + selection.length, length: 0)
        if let bounds = bounds(of: element, for: caret), bounds.height > 0 { return bounds }
        if caret.location > 0,
           let previous = bounds(of: element, for: CFRange(location: caret.location - 1, length: 1)),
           previous.height > 0 {
            return CGRect(x: previous.maxX, y: previous.minY, width: 0, height: previous.height)
        }
        return nil
    }

    private static func bounds(of element: AXUIElement, for range: CFRange) -> CGRect? {
        var range = range
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &boundsValue
        ) == .success, let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(unsafeDowncast(boundsValue, to: AXValue.self), .cgRect, &rect),
              rect.origin.x.isFinite, rect.origin.y.isFinite else { return nil }
        return rect
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Accessibility measures from the top-left of the primary display, y down.
    static func appKitRect(fromAccessibility rect: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
