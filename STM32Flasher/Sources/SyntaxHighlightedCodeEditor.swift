import SwiftUI
import AppKit

final class BoundedUndoTextView: NSTextView {
    private static let maximumUndoLevels = 30
    private var clearsUndoHistoryWhenAvailable = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureUndoManager()
    }

    func configureUndoManager(clearingHistory: Bool = false) {
        clearsUndoHistoryWhenAvailable = clearsUndoHistoryWhenAvailable || clearingHistory
        guard let undoManager else { return }

        undoManager.levelsOfUndo = Self.maximumUndoLevels
        if clearsUndoHistoryWhenAvailable {
            undoManager.removeAllActions()
            clearsUndoHistoryWhenAvailable = false
        }
    }
}

final class EditorLineNumberRulerView: NSRulerView {
    private weak var editorTextView: NSTextView?
    private var editorFontSize: Double

    init(scrollView: NSScrollView, textView: NSTextView, fontSize: Double) {
        editorTextView = textView
        editorFontSize = fontSize
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 52
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    func updateFontSize(_ size: Double) {
        guard editorFontSize != size else { return }
        editorFontSize = size
        setNeedsDisplay(bounds)
    }

    func invalidateLineNumbers() {
        setNeedsDisplay(bounds)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = editorTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else { return }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()

        EditorTheme.lineNumberBackground.setFill()
        bounds.fill()
        EditorTheme.lineNumberBorder.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        let source = textView.string as NSString
        let visibleTextRect = textView.visibleRect
        let containerOrigin = textView.textContainerOrigin
        let visibleContainerRect = visibleTextRect.offsetBy(
            dx: -containerOrigin.x,
            dy: -containerOrigin.y
        )
        layoutManager.ensureLayout(forBoundingRect: visibleContainerRect, in: textContainer)

        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleContainerRect,
            in: textContainer
        )
        let firstCharacter = glyphRange.location < layoutManager.numberOfGlyphs
            ? layoutManager.characterIndexForGlyph(at: glyphRange.location)
            : source.length
        var lineNumber = Self.lineNumber(at: firstCharacter, in: source)
        let rulerTextOrigin = convert(containerOrigin, from: textView)

        if source.length == 0 {
            drawLineNumber(1, y: rulerTextOrigin.y)
            return
        }

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            [weak self] _, usedRect, _, fragmentGlyphRange, _ in
            guard let self else { return }
            let characterRange = layoutManager.characterRange(
                forGlyphRange: fragmentGlyphRange,
                actualGlyphRange: nil
            )
            var logicalLineStart = 0
            source.getLineStart(
                &logicalLineStart,
                end: nil,
                contentsEnd: nil,
                for: NSRange(location: min(characterRange.location, source.length), length: 0)
            )
            if characterRange.location == logicalLineStart {
                self.drawLineNumber(
                    lineNumber,
                    y: rulerTextOrigin.y + usedRect.minY
                )
                lineNumber += 1
            }
        }
    }

    private func drawLineNumber(_ number: Int, y: CGFloat) {
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: min(max(editorFontSize * 0.78, 9), 13),
            weight: .regular
        )
        let value = "\(number)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: EditorTheme.lineNumberText
        ]
        let size = value.size(withAttributes: attributes)
        value.draw(
            at: NSPoint(
                x: ruleThickness - size.width - 9,
                y: y + max(0, (font.ascender - font.descender - size.height) / 2)
            ),
            withAttributes: attributes
        )
    }

    static func lineNumber(at characterIndex: Int, in source: NSString) -> Int {
        let safeIndex = min(max(characterIndex, 0), source.length)
        guard safeIndex > 0 else { return 1 }
        var lineNumber = 1
        var searchLocation = 0
        while searchLocation < safeIndex {
            let range = source.range(
                of: "\n",
                options: [],
                range: NSRange(
                    location: searchLocation,
                    length: safeIndex - searchLocation
                )
            )
            guard range.location != NSNotFound else { break }
            lineNumber += 1
            searchLocation = NSMaxRange(range)
        }
        return lineNumber
    }
}

struct SyntaxHighlightedCodeEditor: NSViewRepresentable {
    private static let maximumEditableCharacters = 1_000_000
    private static let maximumHighlightedCharacters = 250_000

    @Binding var text: String
    var onTextChange: () -> Void
    var fontSize: Double = 13
    var wrapsLines: Bool = false
    var themeID: String = IDETheme.current.rawValue
    var requestedLine: Int? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = EditorTheme.background
        scrollView.borderType = .noBorder

        let textView = BoundedUndoTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.configureUndoManager()
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = EditorTheme.font(size: fontSize)
        textView.textColor = EditorTheme.plainText
        textView.backgroundColor = EditorTheme.background
        textView.insertionPointColor = EditorTheme.caret
        textView.selectedTextAttributes = [
            .backgroundColor: EditorTheme.selection,
            .foregroundColor: EditorTheme.plainText
        ]
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        scrollView.documentView = textView
        let lineNumberRuler = EditorLineNumberRulerView(
            scrollView: scrollView,
            textView: textView,
            fontSize: fontSize
        )
        scrollView.verticalRulerView = lineNumberRuler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.textView = textView
        context.coordinator.lineNumberRuler = lineNumberRuler
        context.coordinator.observeScrolling(in: scrollView)
        context.coordinator.applyConfiguration(to: textView, in: scrollView)
        context.coordinator.replaceText(in: textView, with: text)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.observeScrolling(in: scrollView)
        guard let textView = scrollView.documentView as? NSTextView else { return }
        (textView as? BoundedUndoTextView)?.configureUndoManager()
        context.coordinator.applyConfiguration(to: textView, in: scrollView)
        if textView.string != text {
            context.coordinator.replaceText(
                in: textView,
                with: text,
                clearingUndoHistory: true
            )
        }
        context.coordinator.handleRequestedLine(in: textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private static let highlightQueue = DispatchQueue(
            label: "STM32Flasher.SyntaxHighlighting",
            qos: .userInitiated
        )

        var parent: SyntaxHighlightedCodeEditor
        weak var textView: NSTextView?
        weak var lineNumberRuler: EditorLineNumberRulerView?
        private var isApplyingStyles = false
        private var pendingHighlight: DispatchWorkItem?
        private var highlightGeneration: UInt64 = 0
        private var appliedThemeID = ""
        private var appliedFontSize = 0.0
        private var appliedWrapsLines = false
        private var lastRequestedLine: Int?
        private weak var observedClipView: NSClipView?

        init(parent: SyntaxHighlightedCodeEditor) {
            self.parent = parent
        }

        deinit {
            if let observedClipView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSView.boundsDidChangeNotification,
                    object: observedClipView
                )
            }
        }

        func observeScrolling(in scrollView: NSScrollView) {
            let clipView = scrollView.contentView
            guard observedClipView !== clipView else { return }

            if let observedClipView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSView.boundsDidChangeNotification,
                    object: observedClipView
                )
            }
            observedClipView = clipView
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipViewBoundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
        }

        @objc private func clipViewBoundsDidChange(_ notification: Notification) {
            guard notification.object as? NSClipView === observedClipView else { return }
            lineNumberRuler?.invalidateLineNumbers()
        }

        func applyConfiguration(to textView: NSTextView, in scrollView: NSScrollView) {
            let appearanceChanged = appliedThemeID != parent.themeID
                || appliedFontSize != parent.fontSize
                || appliedWrapsLines != parent.wrapsLines

            guard appearanceChanged else { return }
            appliedThemeID = parent.themeID
            appliedFontSize = parent.fontSize
            appliedWrapsLines = parent.wrapsLines

            scrollView.drawsBackground = true
            scrollView.backgroundColor = EditorTheme.background
            scrollView.hasHorizontalScroller = !parent.wrapsLines
            textView.backgroundColor = EditorTheme.background
            textView.textColor = EditorTheme.plainText
            textView.font = EditorTheme.font(size: parent.fontSize)
            lineNumberRuler?.updateFontSize(parent.fontSize)
            textView.insertionPointColor = EditorTheme.caret
            textView.selectedTextAttributes = [
                .backgroundColor: EditorTheme.selection,
                .foregroundColor: EditorTheme.plainText
            ]

            textView.isHorizontallyResizable = !parent.wrapsLines
            textView.textContainer?.widthTracksTextView = parent.wrapsLines
            textView.textContainer?.containerSize = NSSize(
                width: parent.wrapsLines
                    ? max(scrollView.contentSize.width, 1)
                    : CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            scheduleHighlighting(for: textView, delay: 0)
        }

        func handleRequestedLine(in textView: NSTextView) {
            guard parent.requestedLine != lastRequestedLine else { return }
            lastRequestedLine = parent.requestedLine
            guard let line = parent.requestedLine, line > 0 else { return }

            let source = textView.string as NSString
            var currentLine = 1
            var location = 0

            while currentLine < line, location < source.length {
                let range = source.lineRange(
                    for: NSRange(location: location, length: 0)
                )
                location = NSMaxRange(range)
                currentLine += 1
            }

            guard currentLine == line else { return }
            let targetRange = source.lineRange(
                for: NSRange(location: min(location, source.length), length: 0)
            )
            textView.setSelectedRange(
                NSRange(location: targetRange.location, length: 0)
            )
            textView.scrollRangeToVisible(targetRange)
            textView.window?.makeFirstResponder(textView)
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingStyles,
                  let textView = notification.object as? NSTextView
            else { return }

            parent.text = textView.string
            parent.onTextChange()
            lineNumberRuler?.invalidateLineNumbers()
            scheduleHighlighting(for: textView)
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            let currentLength = (textView.string as NSString).length
            let replacementLength = ((replacementString ?? "") as NSString).length
            let nextLength = currentLength - affectedCharRange.length + replacementLength
            return nextLength <= SyntaxHighlightedCodeEditor.maximumEditableCharacters
        }

        func replaceText(
            in textView: NSTextView,
            with value: String,
            clearingUndoHistory: Bool = false
        ) {
            pendingHighlight?.cancel()
            highlightGeneration &+= 1
            isApplyingStyles = true
            let previousSelection = textView.selectedRange()
            let boundedValue = String(value.prefix(
                SyntaxHighlightedCodeEditor.maximumEditableCharacters
            ))
            textView.string = boundedValue
            if clearingUndoHistory {
                textView.breakUndoCoalescing()
                (textView as? BoundedUndoTextView)?.configureUndoManager(
                    clearingHistory: true
                )
            }
            let safeLocation = min(previousSelection.location, (boundedValue as NSString).length)
            textView.setSelectedRange(NSRange(location: safeLocation, length: 0))
            isApplyingStyles = false
            lineNumberRuler?.invalidateLineNumbers()
            scheduleHighlighting(for: textView, delay: 0)
        }

        private func scheduleHighlighting(
            for textView: NSTextView,
            delay: TimeInterval = 0.15
        ) {
            pendingHighlight?.cancel()
            highlightGeneration &+= 1
            let generation = highlightGeneration
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.prepareHighlighting(for: textView, generation: generation)
            }
            pendingHighlight = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        private func prepareHighlighting(for textView: NSTextView, generation: UInt64) {
            guard generation == highlightGeneration else { return }
            let source = textView.string
            let sourceLength = (source as NSString).length

            guard sourceLength <= SyntaxHighlightedCodeEditor.maximumHighlightedCharacters else {
                applyHighlighting(
                    to: textView,
                    source: source,
                    spans: [],
                    generation: generation
                )
                return
            }

            Self.highlightQueue.async { [weak self, weak textView] in
                let spans = EditorTheme.highlightSpans(in: source) ?? []
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self, let textView else { return }
                    self.applyHighlighting(
                        to: textView,
                        source: source,
                        spans: spans,
                        generation: generation
                    )
                }
            }
        }

        private func applyHighlighting(
            to textView: NSTextView,
            source expectedSource: String,
            spans: [EditorTheme.HighlightSpan],
            generation: UInt64
        ) {
            guard generation == highlightGeneration,
                  textView.string == expectedSource,
                  let storage = textView.textStorage
            else { return }

            let source = storage.string as NSString
            let fullRange = NSRange(location: 0, length: source.length)
            let selections = textView.selectedRanges
            let visibleRange = textView.enclosingScrollView?.documentVisibleRect ?? .zero
            let undoManager = textView.undoManager
            let shouldRestoreUndo = undoManager?.isUndoRegistrationEnabled == true

            isApplyingStyles = true
            if shouldRestoreUndo {
                undoManager?.disableUndoRegistration()
            }
            storage.beginEditing()
            storage.setAttributes([
                .font: EditorTheme.font(size: parent.fontSize),
                .foregroundColor: EditorTheme.plainText
            ], range: fullRange)

            for span in spans where NSMaxRange(span.range) <= source.length {
                storage.addAttribute(
                    .foregroundColor,
                    value: EditorTheme.color(for: span.kind),
                    range: span.range
                )
            }
            storage.endEditing()
            if shouldRestoreUndo {
                undoManager?.enableUndoRegistration()
            }
            textView.selectedRanges = selections
            if visibleRange != .zero {
                textView.enclosingScrollView?.contentView.scroll(to: visibleRange.origin)
                textView.enclosingScrollView?.reflectScrolledClipView(
                    textView.enclosingScrollView!.contentView
                )
            }
            isApplyingStyles = false
        }
    }
}

private enum EditorTheme {
    private static let maximumHighlightSpans = 100_000

    enum TokenKind: Sendable {
        case keyword
        case type
        case function
        case number
        case string
        case preprocessor
        case comment
    }

    struct HighlightSpan: Sendable {
        let range: NSRange
        let kind: TokenKind
    }

    static func font(size: Double) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static var background: NSColor {
        NSColor(IDETheme.current.palette.editor)
    }

    static var plainText: NSColor {
        NSColor(IDETheme.current.palette.primaryText)
    }

    static var selection: NSColor {
        NSColor(IDETheme.current.palette.accent.opacity(0.24))
    }

    static var caret: NSColor {
        NSColor(IDETheme.current.palette.primaryText)
    }

    static var lineNumberBackground: NSColor {
        NSColor(IDETheme.current.palette.editor)
    }

    static var lineNumberBorder: NSColor {
        NSColor.black.withAlphaComponent(0.07)
    }

    static var lineNumberText: NSColor {
        NSColor(IDETheme.current.palette.faintText)
    }
    static let keyword = NSColor(
        calibratedRed: 0.39,
        green: 0.22,
        blue: 0.67,
        alpha: 1
    )
    static let type = NSColor(
        calibratedRed: 0.02,
        green: 0.45,
        blue: 0.32,
        alpha: 1
    )
    static let function = NSColor(
        calibratedRed: 0.08,
        green: 0.34,
        blue: 0.64,
        alpha: 1
    )
    static let number = NSColor(
        calibratedRed: 0.63,
        green: 0.22,
        blue: 0.47,
        alpha: 1
    )
    static let string = NSColor(
        calibratedRed: 0.72,
        green: 0.30,
        blue: 0.13,
        alpha: 1
    )
    static let preprocessor = NSColor(
        calibratedRed: 0.57,
        green: 0.20,
        blue: 0.51,
        alpha: 1
    )
    static let comment = NSColor(
        calibratedRed: 0.35,
        green: 0.43,
        blue: 0.36,
        alpha: 1
    )

    private static let rules: [(NSRegularExpression, TokenKind)] = [
        (#"\b(?:auto|break|case|const|continue|default|do|else|enum|extern|for|goto|if|inline|register|restrict|return|sizeof|static|struct|switch|typedef|union|volatile|while)\b"#, .keyword),
        (#"\b(?:void|char|short|int|long|float|double|signed|unsigned|_Bool|bool|size_t|u?int(?:8|16|32|64)_t)\b"#, .type),
        (#"\b(?:0[xX][0-9A-Fa-f]+|0[bB][01]+|\d+(?:\.\d+)?)(?:[uUlLfF]+)?\b"#, .number),
        (#"\b[A-Za-z_][A-Za-z0-9_]*(?=\s*\()"#, .function),
        (#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, .string),
        (#"(?m)^\s*#.*$"#, .preprocessor),
        (#"(?s)/\*.*?\*/|//[^\n]*"#, .comment)
    ].compactMap { pattern, kind in
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        return (expression, kind)
    }

    static func highlightSpans(in source: String) -> [HighlightSpan]? {
        let range = NSRange(location: 0, length: (source as NSString).length)
        var spans: [HighlightSpan] = []
        spans.reserveCapacity(min(range.length / 4, maximumHighlightSpans))
        var exceededLimit = false

        for (expression, kind) in rules {
            expression.enumerateMatches(
                in: source,
                options: [],
                range: range
            ) { result, _, stop in
                guard let result else { return }
                guard spans.count < maximumHighlightSpans else {
                    exceededLimit = true
                    stop.pointee = true
                    return
                }
                spans.append(HighlightSpan(range: result.range, kind: kind))
            }
            if exceededLimit { return nil }
        }
        return spans
    }

    static func color(for kind: TokenKind) -> NSColor {
        switch kind {
        case .keyword: return keyword
        case .type: return type
        case .function: return function
        case .number: return number
        case .string: return string
        case .preprocessor: return preprocessor
        case .comment: return comment
        }
    }

}
