//
//  MarkdownListHandler.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Makes list editing feel natural by continuing items, handling indentation,
// and applying spacing/alignment that keeps lists easy to read.
import AppKit

struct MarkdownLists {
    static func performEdit(_ textView: NSTextView, replace range: NSRange, with string: String) {
        let ns = textView.string as NSString
        let loc = min(range.location, ns.length)
        let maxLen = ns.length - loc
        let len = min(range.length, max(0, maxLen))
        let safeRange = NSRange(location: loc, length: len)

        if let coord = textView.delegate as? NativeTextViewWrapper.Coordinator { coord.isProgrammaticEdit = true }
        defer {
            if let coord = textView.delegate as? NativeTextViewWrapper.Coordinator { coord.isProgrammaticEdit = false }
        }

        guard textView.shouldChangeText(in: safeRange, replacementString: string) else { return }
        textView.textStorage?.replaceCharacters(in: safeRange, with: string)
        textView.didChangeText()
    }

    static let listRegex = try! NSRegularExpression(
        pattern: #"^\s*((?:(\d+)\.|[-•])(?:\s+\[[ xX]\])?\s+)"#
    )
    static let dashNoSpaceRegex = try! NSRegularExpression(pattern: #"^\s*-(?!\s)"#)
    static let numberRegex = try! NSRegularExpression(pattern: #"^\s*(\d+)\.$"#)
    static let leadingWhitespaceRegex = try! NSRegularExpression(pattern: #"^\s*"#)

    static func indentLevel(from leadingWhitespace: String) -> Int {
        let tabCount = leadingWhitespace.filter { $0 == "\t" }.count
        let spaceCount = leadingWhitespace.filter { $0 == " " }.count
        return tabCount + (spaceCount / 2)
    }

    // MARK: - Paragraph Attributes for List Styling

    static func paragraphAttributes(
        for text: String,
        baseFont: NSFont,
        nsText: NSString,
        fullRange: NSRange,
        listsEnabled: Bool,
        defaultLineHeight: CGFloat,
        defaultParagraphSpacing: CGFloat,
        configuration: MarkdownEditorConfiguration = .default
    ) -> [(range: NSRange, attributes: [NSAttributedString.Key: Any])] {
        var attributesList: [(range: NSRange, attributes: [NSAttributedString.Key: Any])] = []
        guard listsEnabled else { return attributesList }

        let indentPerLevel = configuration.lists.indentPerLevel
        let extraLineHeight = configuration.lists.extraLineHeight
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: baseFont]).width

        func applyListMatches(_ matches: [NSTextCheckingResult]) {
            for match in matches {
                let ps = NSMutableParagraphStyle()
                ps.minimumLineHeight = defaultLineHeight + extraLineHeight
                ps.maximumLineHeight = defaultLineHeight + extraLineHeight
                ps.lineSpacing = 0
                ps.paragraphSpacing = defaultParagraphSpacing
                ps.paragraphSpacingBefore = 0
                let wsRange = match.range(at: 1)
                let markerRange = match.range(at: 2)
                let ws = nsText.substring(with: wsRange)
                let tabCount = ws.filter { $0 == "\t" }.count
                let spaceCount = ws.filter { $0 == " " }.count
                let depthIndent = CGFloat(tabCount) * indentPerLevel + CGFloat(spaceCount) * spaceWidth

                let markerString = nsText.substring(with: markerRange) as NSString
                let markerWidth = markerString.size(withAttributes: [.font: baseFont]).width
                let hasCheckbox = markerString.range(of: "[").location != NSNotFound
                let isChecked = markerString.range(of: "[x]", options: [.caseInsensitive]).location != NSNotFound
                let extraSpacing = (hasCheckbox && !isChecked)
                    ? HeadingHelpers.checkboxExtraSpacing(font: baseFont, configuration: configuration.checkbox)
                    : 0

                ps.tabStops = []
                ps.defaultTabInterval = indentPerLevel
                ps.firstLineHeadIndent = 0
                ps.headIndent = depthIndent + markerWidth + extraSpacing

                attributesList.append((match.range(at: 0), [.paragraphStyle: ps]))
            }
        }

        // Ordered lists
        let orderedListPattern = #"^([ \t]*)(\d+\.(?:[ \t]+\[[ xX]\])?[ \t]+)(.*)$"#
        if let orderedListRegex = try? NSRegularExpression(pattern: orderedListPattern, options: [.anchorsMatchLines]) {
            applyListMatches(orderedListRegex.matches(in: text, options: [], range: fullRange))
        }

        // Bullet lists
        let bulletListPattern = #"^([ \t]*)([-•](?:[ \t]+\[[ xX]\])?[ \t]+)(.*)$"#
        if let bulletListRegex = try? NSRegularExpression(pattern: bulletListPattern, options: [.anchorsMatchLines]) {
            applyListMatches(bulletListRegex.matches(in: text, options: [], range: fullRange))
        }
        return attributesList
    }

    // MARK: - Input Handling

    static func handleInsertion(textView: NSTextView, affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard let replacementString = replacementString else { return true }

        // Fast path: skip the expensive isInsideCodeBlock scan for ordinary typing.
        if replacementString.count == 1,
           let ch = replacementString.first,
           ch != ">" && ch != "[" && ch != "(" && ch != "{" &&
           ch != "\t" && ch != " " && ch != "\n" {
            return true
        }

        let activeConfig = (textView as? NativeTextView)?.configuration ?? .default
        let listsEnabled = activeConfig.lists.helpersEnabled
        let autoClosePairsEnabled = activeConfig.lists.autoClosePairsEnabled

        let isInCodeBlock = textView.string.contains("`")
            ? MarkdownDetection.isInsideCodeBlock(location: affectedCharRange.location, in: textView.string)
            : false

        switch replacementString {
        case ">" where affectedCharRange.length == 0 && !isInCodeBlock:
            return handleArrowConversion(textView: textView, affectedCharRange: affectedCharRange)
        case "[":
            return handleBracketInput(
                textView: textView, affectedCharRange: affectedCharRange,
                autoClosePairsEnabled: autoClosePairsEnabled
            )
        case "(", "{":
            return handleAutoPair(
                textView: textView, affectedCharRange: affectedCharRange,
                replacementString: replacementString, autoClosePairsEnabled: autoClosePairsEnabled
            )
        case "\t" where !isInCodeBlock:
            return handleTabIndent(
                textView: textView, affectedCharRange: affectedCharRange,
                listsEnabled: listsEnabled
            )
        case " " where !isInCodeBlock:
            return handleSpaceConversion(
                textView: textView, affectedCharRange: affectedCharRange,
                listsEnabled: listsEnabled
            )
        case "\n":
            return handleNewline(
                textView: textView, affectedCharRange: affectedCharRange,
                listsEnabled: listsEnabled, isInCodeBlock: isInCodeBlock
            )
        default:
            return true
        }
    }

    // MARK: - Arrow Conversion

    private static func handleArrowConversion(textView: NSTextView, affectedCharRange: NSRange) -> Bool {
        let insertionLocation = affectedCharRange.location
        guard insertionLocation > 0 else { return true }
        let nsText = textView.string as NSString
        let previousCharRange = NSRange(location: insertionLocation - 1, length: 1)
        let previousChar = nsText.substring(with: previousCharRange)
        guard previousChar == "-" else { return true }
        performEdit(textView, replace: previousCharRange, with: "→")
        textView.setSelectedRange(NSRange(location: insertionLocation, length: 0))
        return false
    }

    // MARK: - Bracket Input

    private static func handleBracketInput(
        textView: NSTextView, affectedCharRange: NSRange,
        autoClosePairsEnabled: Bool
    ) -> Bool {
        let nsText = textView.string as NSString
        let insertionLocation = affectedCharRange.location
        if insertionLocation > 0 {
            let prevChar = nsText.substring(with: NSRange(location: insertionLocation - 1, length: 1))
            if prevChar == "[" {
                let hasAutoCloseBracket = insertionLocation < nsText.length
                    && nsText.substring(with: NSRange(location: insertionLocation, length: 1)) == "]"
                if hasAutoCloseBracket {
                    performEdit(
                        textView,
                        replace: NSRange(location: insertionLocation - 1, length: 2),
                        with: "[[]]"
                    )
                } else {
                    performEdit(textView, replace: affectedCharRange, with: "[]]")
                }
                textView.setSelectedRange(NSRange(location: insertionLocation + 1, length: 0))
                return false
            }
        }
        guard autoClosePairsEnabled else { return true }
        return insertAutoPair(textView: textView, affectedCharRange: affectedCharRange, open: "[", close: "]")
    }

    // MARK: - Auto Pair

    private static func handleAutoPair(
        textView: NSTextView, affectedCharRange: NSRange,
        replacementString: String, autoClosePairsEnabled: Bool
    ) -> Bool {
        guard autoClosePairsEnabled else { return true }
        let closeChar = replacementString == "(" ? ")" : "}"
        return insertAutoPair(textView: textView, affectedCharRange: affectedCharRange, open: replacementString, close: closeChar)
    }

    private static func insertAutoPair(textView: NSTextView, affectedCharRange: NSRange, open openChar: String, close closeChar: String) -> Bool {
        let insertionLocation = affectedCharRange.location
        performEdit(textView, replace: affectedCharRange, with: "\(openChar)\(closeChar)")
        textView.setSelectedRange(NSRange(location: insertionLocation + openChar.count, length: 0))
        return false
    }

    // MARK: - Tab Indent

    private static func handleTabIndent(
        textView: NSTextView, affectedCharRange: NSRange,
        listsEnabled: Bool
    ) -> Bool {
        guard listsEnabled else { return true }
        let nsText = textView.string as NSString
        let insertionLocation = affectedCharRange.location
        let safeLoc = min(affectedCharRange.location, nsText.length)
        let currentLineRange = nsText.lineRange(for: NSRange(location: safeLoc, length: 0))
        let currentLine = nsText.substring(with: currentLineRange)

        func indentLineIfList(_ regex: NSRegularExpression) -> Bool {
            guard regex.firstMatch(in: currentLine, range: NSRange(location: 0, length: currentLine.utf16.count)) != nil else {
                return false
            }
            if let wsMatch = leadingWhitespaceRegex.firstMatch(in: currentLine, range: NSRange(location: 0, length: currentLine.utf16.count)) {
                let ws = (currentLine as NSString).substring(with: wsMatch.range)
                if indentLevel(from: ws) >= MarkdownEditorConfiguration.default.lists.maximumNestingLevel {
                    return true // already at max, consume but don't indent
                }
            }
            performEdit(textView, replace: NSRange(location: currentLineRange.location, length: 0), with: "\t")
            textView.setSelectedRange(NSRange(location: insertionLocation + 1, length: 0))
            return true
        }

        if indentLineIfList(listRegex) { return false }
        if indentLineIfList(dashNoSpaceRegex) { return false }
        return true
    }

    // MARK: - Space Conversion

    private static func handleSpaceConversion(
        textView: NSTextView, affectedCharRange: NSRange,
        listsEnabled: Bool
    ) -> Bool {
        guard listsEnabled else { return true }
        let insertionLocation = affectedCharRange.location
        guard insertionLocation > 0 else { return true }

        let nsText = textView.string as NSString
        let prevCharRange = NSRange(location: insertionLocation - 1, length: 1)
        let prevChar = nsText.substring(with: prevCharRange)
        let currentLineRange = nsText.lineRange(for: NSRange(location: insertionLocation - 1, length: 0))
        let currentLine = nsText.substring(with: currentLineRange)

        // "1." + Space → ordered list marker
        if let match = numberRegex.firstMatch(in: currentLine, range: NSRange(location: 0, length: currentLine.utf16.count)) {
            let numberString = (currentLine as NSString).substring(with: match.range(at: 1))
            let markerRange = NSRange(location: currentLineRange.location + match.range.location, length: match.range.length)
            performEdit(textView, replace: markerRange, with: "\t\(numberString). ")
            return false
        }

        // "-" at line start + Space → bullet marker
        if prevChar == "-" {
            let beforePrevIndex = insertionLocation - 2
            let isAtLineStart = beforePrevIndex < 0
                || nsText.substring(with: NSRange(location: beforePrevIndex, length: 1)) == "\n"
            if isAtLineStart {
                performEdit(textView, replace: prevCharRange, with: "\t• ")
                return false
            }
        }

        return true
    }

    // MARK: - Newline (Enter)

    private static func handleNewline(
        textView: NSTextView, affectedCharRange: NSRange,
        listsEnabled: Bool, isInCodeBlock: Bool
    ) -> Bool {
        let nsText = textView.string as NSString
        let safeLoc = min(affectedCharRange.location, nsText.length)
        let currentLineRange = nsText.lineRange(for: NSRange(location: safeLoc, length: 0))
        let currentLine = nsText.substring(with: currentLineRange).trimmingCharacters(in: .whitespacesAndNewlines)

        // Horizontal rule expansion
        if currentLine.range(of: "^-{3,}$", options: .regularExpression) != nil {
            return expandHorizontalRule(textView: textView, currentLineRange: currentLineRange)
        }

        // Code fence auto-close
        if currentLine.range(of: "^```\\w*$", options: .regularExpression) != nil {
            if let result = handleCodeFenceClose(
                textView: textView, affectedCharRange: affectedCharRange,
                nsText: nsText, currentLineRange: currentLineRange
            ) {
                return result
            }
        }

        guard listsEnabled && !isInCodeBlock else { return true }

        // List continuation / empty-item removal
        let listLine = nsText.substring(with: currentLineRange)
        guard let match = listRegex.firstMatch(in: listLine, range: NSRange(location: 0, length: listLine.utf16.count)) else {
            return true
        }

        let contentStart = match.range.location + match.range.length
        let contentLength = listLine.utf16.count - contentStart
        let contentText = (listLine as NSString)
            .substring(with: NSRange(location: contentStart, length: contentLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty list item → remove marker
        if contentText.isEmpty {
            return removeEmptyListItem(
                textView: textView, affectedCharRange: affectedCharRange,
                match: match, currentLineRange: currentLineRange
            )
        }

        // Continue list with same marker style
        let leadingWhitespace = extractLeadingWhitespace(from: listLine)
        let markerRaw = (listLine as NSString).substring(with: match.range(at: 1))
        let marker = markerRaw.trimmingCharacters(in: .whitespaces)
        let hasCheckbox = marker.range(of: #"\[[ xX]\]"#, options: .regularExpression) != nil
        let newListItem = buildContinuationMarker(
            match: match, listLine: listLine, leadingWhitespace: leadingWhitespace,
            marker: marker, hasCheckbox: hasCheckbox
        )
        performEdit(textView, replace: affectedCharRange, with: newListItem)
        return false
    }

    private static func expandHorizontalRule(textView: NSTextView, currentLineRange: NSRange) -> Bool {
        let hrFont = (textView as? NativeTextView)?.baseFont
            ?? textView.font
            ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let hyphenWidth = ("-" as NSString).size(withAttributes: [.font: hrFont]).width
        let visibleWidth = textView.enclosingScrollView?.contentView.bounds.width
                            ?? textView.textContainer?.containerSize.width
                            ?? textView.bounds.width
        let count = Int(visibleWidth / hyphenWidth)
        let fullLine = String(repeating: "-", count: max(count, 3))
        performEdit(textView, replace: currentLineRange, with: fullLine + "\n")
        textView.setSelectedRange(NSRange(location: currentLineRange.location + fullLine.count + 1, length: 0))
        return false
    }

    private static func handleCodeFenceClose(
        textView: NSTextView, affectedCharRange: NSRange,
        nsText: NSString, currentLineRange: NSRange
    ) -> Bool? {
        let textBeforeLine = nsText.substring(to: currentLineRange.location)
        let openingCount = textBeforeLine.components(separatedBy: "```").count - 1
        let afterLineStart = currentLineRange.location + currentLineRange.length
        let hasClosingAfter = afterLineStart < nsText.length
            && nsText.substring(from: afterLineStart).contains("```")
        let lineEnd = currentLineRange.location + max(0, currentLineRange.length - 1)
        let cursorAtLineEnd = affectedCharRange.location >= lineEnd

        guard openingCount.isMultiple(of: 2), cursorAtLineEnd, !hasClosingAfter else { return nil }
        let insertionLocation = affectedCharRange.location
        performEdit(textView, replace: affectedCharRange, with: "\n\n```")
        textView.setSelectedRange(NSRange(location: insertionLocation + 1, length: 0))
        return false
    }

    private static func removeEmptyListItem(
        textView: NSTextView, affectedCharRange: NSRange,
        match: NSTextCheckingResult, currentLineRange: NSRange
    ) -> Bool {
        let removalLengthRaw = match.range.location + match.range.length
        let lineEnd = currentLineRange.location + currentLineRange.length
        let hasNewline = currentLineRange.length > 0
            && (textView.string as NSString).substring(with: NSRange(location: lineEnd - 1, length: 1)) == "\n"
        let maxBodyLen = hasNewline ? currentLineRange.length - 1 : currentLineRange.length
        let removalLength = min(removalLengthRaw, maxBodyLen)
        performEdit(textView, replace: NSRange(location: currentLineRange.location, length: removalLength), with: "")
        textView.setSelectedRange(NSRange(location: currentLineRange.location, length: 0))
        return false
    }

    private static func extractLeadingWhitespace(from line: String) -> String {
        if let wsMatch = leadingWhitespaceRegex.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) {
            return (line as NSString).substring(with: wsMatch.range)
        }
        return ""
    }

    private static func buildContinuationMarker(
        match: NSTextCheckingResult, listLine: String, leadingWhitespace: String,
        marker: String, hasCheckbox: Bool
    ) -> String {
        if match.range(at: 2).location != NSNotFound,
           let number = Int((listLine as NSString).substring(with: match.range(at: 2))) {
            let suffix = hasCheckbox ? " [ ] " : " "
            return "\n" + leadingWhitespace + "\(number + 1)." + suffix
        }
        if hasCheckbox {
            let bulletChar = marker.contains("•") ? "•" : "-"
            return "\n" + leadingWhitespace + "\(bulletChar) [ ] "
        }
        return "\n" + leadingWhitespace + marker + " "
    }
}
