import Foundation

/// How a dictation's text is treated. Replaces the old cleanup mode and tone (see docs/addendum-changes.md, section 4).
public enum Style: String, CaseIterable, Codable, Sendable {
    /// The rules only (fillers, vocabulary, snippets, spoken formatting). The cleanup model is never used.
    case exact
    /// The rules, then the cleanup model, but only when the text is likely to need it (see `NaturalPolicy`).
    case natural
    /// The rules, then the cleanup model every time, with formal wording.
    case polished

    public var displayName: String {
        switch self { case .exact: return "Exact"; case .natural: return "Natural"; case .polished: return "Polished" }
    }

    /// One line under the menu item.
    public var summary: String {
        switch self {
        case .exact: return "Never uses the model"
        case .natural: return "Uses the model only when needed"
        case .polished: return "Always uses the model, formal wording"
        }
    }

    /// Whether this style can ever send text to the cleanup model.
    public var canUseModel: Bool { self != .exact }

    /// Accepts the exact names in any case.
    public init?(lenient text: String) {
        switch text.lowercased().filter({ $0.isLetter }) {
        case "exact": self = .exact
        case "natural": self = .natural
        case "polished": self = .polished
        default: return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let style = Style(lenient: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "unknown style \"\(raw)\". Choices: \(Style.allCases.map(\.rawValue).joined(separator: ", "))"))
        }
        self = style
    }
}

/// The Style setting: one of the three styles, or a style per app.
public enum StyleChoice: String, CaseIterable, Codable, Sendable {
    case exact, natural, polished
    /// Each app uses the style listed for it in `appStyles`; apps not listed use Natural. (Beta.)
    case automatic

    public var displayName: String {
        switch self {
        case .automatic: return "Automatic by app (beta)"
        default: return fixed?.displayName ?? ""
        }
    }

    /// The style when the choice is a single fixed style, or nil for Automatic.
    public var fixed: Style? {
        switch self { case .exact: return .exact; case .natural: return .natural; case .polished: return .polished; case .automatic: return nil }
    }

    public init?(lenient text: String) {
        let key = text.lowercased().filter { $0.isLetter }
        if ["automatic", "auto", "automaticbyapp"].contains(key) { self = .automatic }
        else if let s = Style(lenient: key) { self = StyleChoice(rawValue: s.rawValue)! }
        else { return nil }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let choice = StyleChoice(lenient: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "unknown style \"\(raw)\". Choices: \(StyleChoice.allCases.map(\.rawValue).joined(separator: ", "))"))
        }
        self = choice
    }
}

/// The Cleanup model setting: whether the model stays in memory.
public enum ModelMemory: String, CaseIterable, Codable, Sendable {
    /// Loaded at launch and kept (about 2.7 GB). No waiting. The default.
    case keepReady
    /// Loaded when first needed and freed after `idleMinutes` without use.
    case freeWhenIdle

    public var displayName: String {
        switch self { case .keepReady: return "Keep ready"; case .freeWhenIdle: return "Free memory when idle" }
    }

    public init?(lenient text: String) {
        switch text.lowercased().filter({ $0.isLetter }) {
        case "keepready", "keep": self = .keepReady
        case "freewhenidle", "free", "idle": self = .freeWhenIdle
        default: return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let memory = ModelMemory(lenient: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "unknown cleanup model setting \"\(raw)\". Choices: \(ModelMemory.allCases.map(\.rawValue).joined(separator: ", "))"))
        }
        self = memory
    }
}
