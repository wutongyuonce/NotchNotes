import Foundation

enum MarkdownCommand: CaseIterable, Identifiable {
    case bold
    case italic
    case strikethrough
    case inlineCode
    case link
    case quote
    case unorderedList
    case orderedList
    case todoList

    var id: String {
        switch self {
        case .bold: return "bold"
        case .italic: return "italic"
        case .strikethrough: return "strikethrough"
        case .inlineCode: return "inlineCode"
        case .link: return "link"
        case .quote: return "quote"
        case .unorderedList: return "unorderedList"
        case .orderedList: return "orderedList"
        case .todoList: return "todoList"
        }
    }

    var help: String {
        switch self {
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .strikethrough: return "Strikethrough"
        case .inlineCode: return "Inline code"
        case .link: return "Link"
        case .quote: return "Quote"
        case .unorderedList: return "Bulleted list"
        case .orderedList: return "Numbered list"
        case .todoList: return "Todo list"
        }
    }
}
