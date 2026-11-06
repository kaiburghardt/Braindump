import AppKit
import SwiftUI

/// NSTextView with
/// - an icon left of every note showing its type (click: to-do ⇄ done, note and radar → small
///   menu; right-click: pick a type) and a line that holds multi-line notes together,
/// - a pop-up above a multi-line selection (merge, split, …),
/// - status pills after Jira/Notion links.
final class NoteTextView: NSTextView, @MainActor NSLayoutManagerDelegate {
    static let gutterWidth: CGFloat = 40

    struct NoteStyle {
        let type: NoteType
        let title: NSRange
        let details: NSRange?
    }

    /// Click on a note's icon. Returns menu items to show right there – or nil when the click
    /// was handled directly (checking off a to-do).
    var onGutterClick: ((Int) -> [GutterMenuItem]?)?
    /// Right-click on a note's icon: all options.
    var gutterMenuItems: ((Int) -> [GutterMenuItem])?
    /// For a paragraph start: the note's type, the range of its last line and its line count –
    /// nil if no note starts there.
    var noteSpanAt: ((Int) -> (type: NoteType, lastLine: NSRange, lineCount: Int)?)?
    var previewFor: ((URL) -> LinkPreview?)?
    var onPreviewClick: ((URL) -> Void)?
    var selectionActions: ((NSRange) -> [SelectionAction])?
    var fontSize: CGFloat = 15

    private var hoverLine: (start: Int, rect: NSRect)?
    private var pillRects: [(rect: NSRect, url: URL)] = []
    private var hoverTracking: NSTrackingArea?
    /// Paragraphs restyled by the last edit – the model puts the type styling back there.
    private var restyledRange: NSRange?

    var debugHover: String {
        guard let hoverLine else { return "no hover" }
        return "start=\(hoverLine.start) icon=\(gutterIconRect(for: hoverLine.rect)) symbol=\(gutterSymbol(for: hoverLine.start)?.name ?? "-")"
    }

    var debugPopup: String {
        guard let popup, !popup.isHidden else { return "no pop-up" }
        return "pop-up: " + popup.titles.joined(separator: " | ")
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 1, event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty {
            if let pill = pillRects.first(where: { $0.rect.contains(point) }) {
                onPreviewClick?(pill.url)
                return
            }
            if let line = gutterHit(point) {
                if let items = onGutterClick?(line.start), !items.isEmpty {
                    // Menu right below the icon
                    let icon = gutterIconRect(for: line.rect)
                    makeMenu(items).popUp(positioning: nil, at: NSPoint(x: icon.minX - 4, y: icon.maxY + 4), in: self)
                }
                hoverLine = lineInfo(atY: point.y)
                scheduleIconRefresh()
                return
            }
        }
        super.mouseDown(with: event)
    }

    /// Right-click / ctrl-click on a note's icon shows all types; elsewhere the normal text menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let line = gutterHit(point), let items = gutterMenuItems?(line.start), !items.isEmpty {
            return makeMenu(items)
        }
        return super.menu(for: event)
    }

    private func makeMenu(_ items: [GutterMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            if item.separatorBefore { menu.addItem(.separator()) }
            let perform = item.perform
            let menuItem = ClosureMenuItem(title: item.title) { MainActor.assumeIsolated { perform() } }
            menuItem.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
            menuItem.state = item.checked ? .on : .off
            menu.addItem(menuItem)
        }
        return menu
    }

    /// The note icon under a point in the left margin.
    private func gutterHit(_ point: NSPoint) -> (start: Int, rect: NSRect)? {
        guard point.x < textContainerOrigin.x, let line = lineInfo(atY: point.y),
              gutterIconRect(for: line.rect).insetBy(dx: -6, dy: -4).contains(point),
              gutterSymbol(for: line.start) != nil else { return nil }
        return line
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let line = lineInfo(atY: point.y)
        if line?.start != hoverLine?.start || line?.rect != hoverLine?.rect {
            hoverLine = line
            scheduleIconRefresh()
        }
        if gutterHit(point) != nil || pillRects.contains(where: { $0.rect.contains(point) }) {
            NSCursor.pointingHand.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverLine = nil
        scheduleIconRefresh()
    }

    // MARK: Note icons and lines in the left margin

    /// Every icon is a small image view in the left margin (custom drawing in the margin gets
    /// clipped by NSTextView). Clicks pass through to `mouseDown`.
    private final class PassThroughImageView: NSImageView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// Vertical line that connects the lines of a multi-line note.
    private final class NoteBar: NSView {
        var color: NSColor = .tertiaryLabelColor { didSet { needsDisplay = true } }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            color.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.width / 2, yRadius: bounds.width / 2).fill()
        }
    }

    private var lineIcons: [NSImageView] = []
    private var noteBars: [NoteBar] = []
    private var iconImages: [String: NSImage] = [:]
    private var iconRefreshScheduled = false
    private var scrollObserver: NSObjectProtocol?

    /// Collects triggers (typing, scrolling, layout, hover) and rebuilds the icons once per run loop.
    func scheduleIconRefresh() {
        guard !iconRefreshScheduled else { return }
        iconRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.iconRefreshScheduled = false
            self?.refreshLineIcons()
        }
    }

    private func refreshLineIcons() {
        var used = 0
        var usedBars = 0
        defer {
            for view in lineIcons.dropFirst(used) { view.isHidden = true }
            for bar in noteBars.dropFirst(usedBars) { bar.isHidden = true }
        }
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage else { return }
        let ns = storage.string as NSString
        let glyphs = lm.glyphRange(forBoundingRect: visibleRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y), in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // Start a little above, so the line of a note whose title scrolled out still shows.
        var location = ns.length == 0 ? 0 : ns.paragraphRange(for: NSRange(location: max(0, min(chars.location, ns.length) - 2000), length: 0)).location
        while location <= ns.length, location <= NSMaxRange(chars) {
            let paragraph = location < ns.length ? ns.paragraphRange(for: NSRange(location: location, length: 0)) : NSRange(location: location, length: 0)
            if let span = noteSpanAt?(paragraph.location), let symbol = gutterSymbol(for: paragraph.location, hovered: hoverLine?.start == paragraph.location) {
                let rect = lineRect(at: paragraph.location, lm: lm)
                let iconRect = gutterIconRect(for: rect)
                if used == lineIcons.count {
                    let view = PassThroughImageView()
                    view.imageScaling = .scaleProportionallyUpOrDown
                    addSubview(view)
                    lineIcons.append(view)
                }
                let view = lineIcons[used]
                used += 1
                view.image = image(for: symbol)
                view.frame = iconRect
                view.toolTip = symbol.help
                view.isHidden = false

                if span.lineCount > 1 {
                    let lastGlyphs = lm.glyphRange(forCharacterRange: NSRange(location: span.lastLine.location, length: max(1, span.lastLine.length)), actualCharacterRange: nil)
                    let lastRect = lm.boundingRect(forGlyphRange: lastGlyphs, in: tc).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
                    if usedBars == noteBars.count {
                        let bar = NoteBar()
                        addSubview(bar, positioned: .below, relativeTo: nil)
                        noteBars.append(bar)
                    }
                    let bar = noteBars[usedBars]
                    usedBars += 1
                    bar.color = Self.barColor(for: span.type)
                    bar.frame = NSRect(x: iconRect.midX - 1, y: iconRect.maxY + 3, width: 2, height: max(4, lastRect.maxY - 4 - (iconRect.maxY + 3)))
                    bar.isHidden = false
                }
            }
            guard paragraph.length > 0 else { break }
            location = NSMaxRange(paragraph)
        }
    }

    /// Rect of the first line fragment at a character location (also for the empty last line).
    private func lineRect(at location: Int, lm: NSLayoutManager) -> NSRect {
        if location >= (textStorage?.length ?? 0), !lm.extraLineFragmentRect.isEmpty {
            return lm.extraLineFragmentUsedRect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        }
        return lm.lineFragmentUsedRect(forGlyphAt: lm.glyphIndexForCharacter(at: location), effectiveRange: nil)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    private static func barColor(for type: NoteType) -> NSColor {
        switch type {
        case .todo: NSColor.controlAccentColor.withAlphaComponent(0.45)
        case .radar: NSColor.systemOrange.withAlphaComponent(0.5)
        default: NSColor.tertiaryLabelColor
        }
    }

    private func image(for symbol: (name: String, colors: [NSColor], help: String)) -> NSImage? {
        let key = symbol.name + symbol.colors.map(\.description).joined()
        if let cached = iconImages[key] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: symbol.colors))
        let image = NSImage(systemSymbolName: symbol.name, accessibilityDescription: symbol.help)?.withSymbolConfiguration(config)
        iconImages[key] = image
        return image
    }

    private func gutterIconRect(for lineRect: NSRect) -> NSRect {
        let size: CGFloat = 16
        return NSRect(x: textContainerOrigin.x - 28, y: lineRect.midY - size / 2, width: size, height: size)
    }

    private func gutterSymbol(for index: Int, hovered: Bool = true) -> (name: String, colors: [NSColor], help: String)? {
        guard let type = noteSpanAt?(index)?.type else { return nil }
        switch type {
        case .note:
            return ("circle.dashed", [hovered ? .labelColor : .secondaryLabelColor],
                    "Note · click: make it a to-do or put it on the radar")
        case .todo:
            return ("circle", [hovered ? .controlAccentColor : .controlAccentColor.withAlphaComponent(0.8)],
                    "To-do · click: done · right-click: more options")
        case .done:
            return ("checkmark.circle.fill", [.white, .controlAccentColor], "Done · click: reopen · right-click: more options")
        case .radar:
            return ("scope", [.systemOrange], "Radar · click: checked today, make it a to-do or take it off the radar")
        }
    }

    override func didChangeText() {
        super.didChangeText()
        hidePopup()
        // The type or position of the line under the mouse may have changed.
        if let hover = hoverLine { hoverLine = lineInfo(atY: hover.rect.midY) }
        scheduleIconRefresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layoutManager?.delegate = self
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleIconRefresh() }
            }
        }
        scheduleIconRefresh()
    }

    func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinishedFlag: Bool) {
        scheduleIconRefresh()
    }

    /// Paragraph start + rect of the paragraph's first line under a y position.
    private func lineInfo(atY y: CGFloat) -> (start: Int, rect: NSRect)? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage else { return nil }
        if storage.length > 0 {
            let glyph = lm.glyphIndex(for: NSPoint(x: 1, y: y - textContainerOrigin.y), in: tc)
            if glyph < lm.numberOfGlyphs {
                let fragment = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
                if y >= fragment.minY, y <= fragment.maxY {
                    let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: lm.characterIndexForGlyph(at: glyph), length: 0))
                    return (paragraph.location, lineRect(at: paragraph.location, lm: lm))
                }
            }
        }
        // The empty last line (e.g. a pending next to-do)
        let extra = lm.extraLineFragmentRect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        if !lm.extraLineFragmentRect.isEmpty, y >= extra.minY, y <= extra.maxY {
            return (storage.length, lineRect(at: storage.length, lm: lm))
        }
        return nil
    }

    // MARK: Styling by note type

    func noteRestyled(_ range: NSRange) {
        restyledRange = restyledRange.map { NSUnionRange($0, range) } ?? range
    }

    func takeRestyledRange() -> NSRange? {
        defer { restyledRange = nil }
        return restyledRange
    }

    /// Puts the type styling (done = struck through, radar = bold title) on notes. With
    /// `restyling`, that range is reset to the base styling first.
    func applyNoteStyles(_ styles: [NoteStyle], restyling range: NSRange?) {
        guard let storage = textStorage, storage.length > 0 else { return }
        storage.beginEditing()
        if let range { Styler.style(storage, around: range, fontSize: fontSize) }
        for style in styles where NSMaxRange(style.title) <= storage.length {
            Styler.applyType(style.type, title: style.title, details: style.details, in: storage, fontSize: fontSize)
        }
        storage.endEditing()
        restyledRange = nil
    }

    // MARK: Pop-up above a multi-line selection

    /// Plain AppKit on purpose: a SwiftUI hosting view nested inside this AppKit view (which itself
    /// sits in SwiftUI) crashed in SwiftUI's hit testing on cursor updates.
    private var popup: SelectionPopupView?
    private var popupWorkItem: DispatchWorkItem?

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        popupWorkItem?.cancel()
        if stillSelecting {
            hidePopup()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.updatePopup() }
        popupWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func updatePopup() {
        let selection = selectedRange()
        guard selection.length > 0, window?.firstResponder === self,
              let actions = selectionActions?(selection), !actions.isEmpty,
              let lm = layoutManager, let tc = textContainer else {
            hidePopup()
            return
        }
        let host: SelectionPopupView
        if let popup {
            host = popup
        } else {
            host = SelectionPopupView()
            addSubview(host)
            popup = host
        }
        host.show(actions) { [weak self] in self?.hidePopup() }
        let size = host.fittingSize
        func rect(at location: Int) -> NSRect {
            let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
            return lm.boundingRect(forGlyphRange: glyphs, in: tc).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        }
        let start = rect(at: selection.location)
        var origin = NSPoint(x: min(max(textContainerOrigin.x - 12, start.minX - 12), bounds.maxX - size.width - 8),
                             y: start.minY - size.height + 2)
        if origin.y < visibleRect.minY + 2 {
            origin.y = rect(at: max(selection.location, NSMaxRange(selection) - 1)).maxY - 2
        }
        host.frame = NSRect(origin: origin, size: size)
        host.isHidden = false
    }

    func hidePopup() {
        popupWorkItem?.cancel()
        popup?.isHidden = true
    }

    // MARK: Drawing (link pills)

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawPreviewPills()
    }

    private func drawPreviewPills() {
        pillRects.removeAll()
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, let previewFor, storage.length > 0 else { return }
        let visibleGlyphs = lm.glyphRange(forBoundingRect: visibleRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y), in: tc)
        let visibleChars = lm.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        let ns = storage.string as NSString
        let rightEdge = textContainerOrigin.x + tc.size.width - tc.lineFragmentPadding

        storage.enumerateAttribute(.link, in: visibleChars) { value, range, _ in
            guard let url = value as? URL, range.length > 0, let preview = previewFor(url) else { return }
            // Only when the link ends the line – otherwise the pill would cover text.
            var contentsEnd = 0
            ns.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: range.location, length: 0))
            let tail = ns.substring(with: NSRange(location: NSMaxRange(range), length: max(0, contentsEnd - NSMaxRange(range))))
            guard tail.trimmingCharacters(in: .whitespaces).isEmpty else { return }

            let lastGlyph = lm.glyphIndexForCharacter(at: NSMaxRange(range) - 1)
            let glyphRect = lm.boundingRect(forGlyphRange: NSRange(location: lastGlyph, length: 1), in: tc)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            let lineRect = lm.lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            let x = glyphRect.maxX + 10
            guard rightEdge - x > 80 else { return }
            let rect = drawPill(preview, x: x, centerY: lineRect.midY, maxWidth: min(rightEdge - x, 460))
            pillRects.append((rect, url))
        }
    }

    private func drawPill(_ preview: LinkPreview, x: CGFloat, centerY: CGFloat, maxWidth: CGFloat) -> NSRect {
        let size = max(10, fontSize * 0.78)
        let color: NSColor = switch preview.state {
        case .done: .systemGreen
        case .progress: .systemBlue
        case .todo: .systemGray
        case .unknown: preview.problem == nil ? .systemGray : .systemOrange
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.8),
        ]
        let text = preview.summary as NSString
        let textSize = text.size(withAttributes: attributes)
        let dot: CGFloat = 6, padding: CGFloat = 8, gap: CGFloat = 5
        let height = ceil(textSize.height) + 4
        let width = min(maxWidth, padding + dot + gap + ceil(textSize.width) + padding)
        let rect = NSRect(x: x, y: round(centerY - height / 2), width: width, height: height)

        color.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX + padding, y: rect.midY - dot / 2, width: dot, height: dot)).fill()
        let textRect = NSRect(x: rect.minX + padding + dot + gap, y: rect.minY + 2,
                              width: max(0, width - 2 * padding - dot - gap), height: height - 4)
        text.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        return rect
    }
}

/// NSMenuItem that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: @Sendable () -> Void

    init(title: String, action handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

/// Styles the text lightly – type-independent parts while typing, type styling via `applyType`.
@MainActor
enum Styler {
    static func paragraphStyle(_ size: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.12
        p.paragraphSpacing = round(size * 0.32)
        return p
    }

    static func baseAttributes(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: size),
         .foregroundColor: NSColor.labelColor,
         .paragraphStyle: paragraphStyle(size)]
    }

    /// Restyles the paragraphs around `range` (plus one line before and after) and returns
    /// the range that was restyled.
    @discardableResult
    static func style(_ storage: NSTextStorage, around range: NSRange, fontSize size: CGFloat) -> NSRange {
        let ns = storage.string as NSString
        let length = ns.length
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        let start = min(range.location, length)
        var paragraphs = ns.paragraphRange(for: NSRange(location: start, length: min(range.length, length - start)))
        // Include one line before and after: whether a line is a title or a detail depends on its neighbours.
        if paragraphs.location > 0 {
            paragraphs = NSUnionRange(paragraphs, ns.paragraphRange(for: NSRange(location: paragraphs.location - 1, length: 0)))
        }
        if NSMaxRange(paragraphs) < length {
            paragraphs = NSUnionRange(paragraphs, ns.paragraphRange(for: NSRange(location: NSMaxRange(paragraphs), length: 0)))
        }

        let base = baseAttributes(size)
        let medium = NSFont.systemFont(ofSize: size, weight: .medium)
        let heading = NSFont.systemFont(ofSize: round(size * 1.3), weight: .bold)

        /// Kind of the line directly before/after (nil at the start/end of the document).
        func neighbor(before location: Int) -> LineKind? {
            guard location > 0 else { return nil }
            let r = ns.paragraphRange(for: NSRange(location: location - 1, length: 0))
            return NoteParser.classify(ns.substring(with: r).trimmingCharacters(in: .newlines)).kind
        }
        func neighbor(after end: Int) -> LineKind? {
            guard end < length else { return nil }
            let r = ns.paragraphRange(for: NSRange(location: end, length: 0))
            return NoteParser.classify(ns.substring(with: r).trimmingCharacters(in: .newlines)).kind
        }

        var location = paragraphs.location
        while location < NSMaxRange(paragraphs) {
            var end = 0
            var contentsEnd = 0
            ns.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            let lineRange = NSRange(location: location, length: end - location)
            let content = NSRange(location: location, length: contentsEnd - location)
            storage.setAttributes(base, range: lineRange)

            let raw = ns.substring(with: content)
            let info = NoteParser.classify(raw)
            let marker = NSRange(location: location + info.markerStart, length: info.markerLength)

            // Detail line of a note (hangs on the line above) → a bit quieter.
            let previousKind = neighbor(before: location)
            let isDetail = info.kind != .blank && !NoteParser.startsOwnNote(info.kind)
                && previousKind != nil && previousKind != .blank
            if isDetail {
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: content)
            } else if info.kind == .plain || info.kind == .bullet || info.kind == .link,
                      let next = neighbor(after: end), next != .blank, !NoteParser.startsOwnNote(next) {
                // Title of a multi-line note
                storage.addAttribute(.font, value: medium, range: content)
            }

            switch info.kind {
            case .heading:
                storage.addAttribute(.font, value: heading, range: content)
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: marker)
            case .bullet:
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: marker)
            case .plain:
                let trimmed = raw.drop { $0 == " " || $0 == "\t" }
                if let arrow = ["->", "→", "=>"].first(where: { trimmed.hasPrefix($0) }) {
                    let r = NSRange(location: location + info.markerStart, length: (arrow as NSString).length)
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: r)
                }
            case .todoMarker, .doneMarker, .radarMarker:
                // A typed shortcut that is about to be converted
                storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: marker)
            case .blank, .link:
                break
            }

            for (range, url) in NoteParser.urlRanges(in: raw) {
                storage.addAttribute(.link, value: url, range: NSRange(location: location + range.location, length: range.length))
            }

            if end <= location { break }
            location = end
        }
        // The system font has no emoji like 🚧 → put the fallback font back.
        storage.fixFontAttribute(in: paragraphs)
        return paragraphs
    }

    /// Type styling on top of the base styling.
    static func applyType(_ type: NoteType, title: NSRange, details: NSRange?, in storage: NSTextStorage, fontSize size: CGFloat) {
        switch type {
        case .done:
            for range in [title, details].compactMap({ $0 }) {
                storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor,
                                       .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                       .strikethroughColor: NSColor.tertiaryLabelColor], range: range)
            }
        case .radar:
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .semibold), range: title)
        case .todo, .note:
            break
        }
    }
}

struct EditorView: NSViewRepresentable {
    let model: NotesModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let tv = NoteTextView(frame: .zero, textContainer: container)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.textContainerInset = NSSize(width: NoteTextView.gutterWidth, height: 20) // room for the note icons on the left
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.linkTextAttributes = [.foregroundColor: NSColor.linkColor,
                                 .underlineStyle: NSUnderlineStyle.single.rawValue,
                                 .cursor: NSCursor.pointingHand]
        let size = CGFloat(model.fontSize)
        tv.font = .systemFont(ofSize: size)
        tv.fontSize = size
        tv.typingAttributes = Styler.baseAttributes(size)
        tv.delegate = context.coordinator
        storage.delegate = context.coordinator
        context.coordinator.textView = tv

        let scroll = NSScrollView()
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = tv

        model.attach(tv)
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let size = CGFloat(model.fontSize)
        guard let tv = scroll.documentView as? NoteTextView, size != tv.fontSize else { return }
        tv.fontSize = size
        tv.typingAttributes = Styler.baseAttributes(size)
        model.fontSizeChanged()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, @MainActor NSTextStorageDelegate {
        let model: NotesModel
        weak var textView: NoteTextView?

        init(model: NotesModel) { self.model = model }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            model.editorDidChange(tv.string, editLocation: tv.selectedRange().location)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            model.selectionDidChange(to: tv.selectedRange().location)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            return model.handleReturn(in: textView) || continueBullets(in: textView)
        }

        /// Deliberately *did*ProcessEditing: attribute changes in willProcessEditing enlarge the
        /// "edited range", and NSTextView then moves the cursor to the end of the line.
        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters), let tv = textView else { return }
            let restyled = Styler.style(textStorage, around: editedRange, fontSize: tv.fontSize)
            tv.noteRestyled(restyled)
        }

        /// ↩ in a bullet line continues the list, ↩ in an empty bullet line ends it.
        private func continueBullets(in tv: NSTextView) -> Bool {
            let selection = tv.selectedRange()
            guard selection.length == 0 else { return false }
            let ns = tv.string as NSString
            var start = 0
            var contentsEnd = 0
            ns.getLineStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: selection.location, length: 0))
            let lineRange = NSRange(location: start, length: contentsEnd - start)
            let raw = ns.substring(with: lineRange)
            let info = NoteParser.classify(raw)
            guard info.kind == .bullet, selection.location >= start + info.bodyStart else { return false }

            let rawNS = raw as NSString
            let body = rawNS.substring(from: info.bodyStart).trimmingCharacters(in: .whitespaces)
            if body.isEmpty {
                tv.insertText("", replacementRange: lineRange)
                return true
            }
            let prefix = rawNS.substring(to: info.bodyStart)
            tv.insertText("\n" + prefix, replacementRange: selection)
            return true
        }
    }
}

/// The small bar above a multi-line selection (AppKit: frosted capsule with buttons).
final class SelectionPopupView: NSView {
    private let background = NSVisualEffectView()
    private let stack = NSStackView()
    private(set) var titles: [String] = []

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.25)
            s.shadowBlurRadius = 8
            s.shadowOffset = NSSize(width: 0, height: -2)
            return s
        }()
        background.material = .popover
        background.blendingMode = .withinWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 15
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
        background.addSubview(stack)
        addSubview(background)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            background.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            background.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            background.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func show(_ actions: [SelectionAction], onDone: @escaping @MainActor () -> Void) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        titles = actions.map(\.title)
        for action in actions {
            let perform = action.perform
            let button = ClosureButton(title: action.title, image: NSImage(systemSymbolName: action.systemImage, accessibilityDescription: nil)) {
                MainActor.assumeIsolated {
                    perform()
                    onDone()
                }
            }
            button.bezelStyle = .accessoryBarAction
            button.imagePosition = .imageLeading
            button.controlSize = .regular
            if action.prominent {
                button.contentTintColor = .controlAccentColor
                button.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            }
            stack.addArrangedSubview(button)
        }
        layoutSubtreeIfNeeded()
    }
}

/// NSButton that runs a closure.
private final class ClosureButton: NSButton {
    private var handler: (@Sendable () -> Void)?

    convenience init(title: String, image: NSImage?, handler: @escaping @Sendable () -> Void) {
        self.init(frame: .zero)
        self.title = title
        self.image = image
        self.handler = handler
        target = self
        action = #selector(run)
    }

    @objc private func run() { handler?() }
}
