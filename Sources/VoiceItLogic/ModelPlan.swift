import Foundation

/// When the cleanup model is used, loaded and freed. Pure decisions, so they can be tested without the model.
public enum ModelPlan {
    /// How long a dictation waits for a model that is not loaded yet. After this the text is pasted with the rules only.
    public static let loadWait: TimeInterval = 5

    public struct ModelState: Equatable, Sendable {
        public var installed: Bool
        public var loaded: Bool
        public var loading: Bool
        public init(installed: Bool, loaded: Bool, loading: Bool = false) { self.installed = installed; self.loaded = loaded; self.loading = loading }
    }

    public enum SkipReason: Equatable, Sendable {
        case exactStyle, notInstalled, cleanText
        public var label: String {
            switch self { case .exactStyle: return "exact style"; case .notInstalled: return "model not installed"; case .cleanText: return "short clean text" }
        }
    }

    public enum UseReason: Equatable, Sendable {
        case polished
        case natural(NaturalPolicy.Reason)
        public var label: String {
            switch self { case .polished: return "polished style"; case .natural(let r): return r.label }
        }
    }

    public enum Decision: Equatable, Sendable {
        case skip(SkipReason)
        /// The model is loaded: use it now.
        case use(UseReason)
        /// The model is not loaded (or still loading): wait up to `loadWait` for it, then use it, else paste the rules-only text.
        case loadThenUse(UseReason)

        /// For the log: what happened and why, never the words.
        public var label: String {
            switch self {
            case .skip(let r): return "model skipped (\(r.label))"
            case .use(let r), .loadThenUse(let r): return "model used (\(r.label))"
            }
        }
        public var usesModel: Bool { if case .skip = self { return false }; return true }
    }

    /// What to do with one dictation. `text` is the text after the rules have run.
    public static func decide(style: Style, text: String, longTextWords: Int, model: ModelState) -> Decision {
        guard style.canUseModel else { return .skip(.exactStyle) }
        guard model.installed else { return .skip(.notInstalled) }
        let reason: UseReason
        switch style {
        case .exact: return .skip(.exactStyle)
        case .polished: reason = .polished
        case .natural:
            guard let r = NaturalPolicy.reason(for: text, longTextWords: longTextWords) else { return .skip(.cleanText) }
            reason = .natural(r)
        }
        return model.loaded ? .use(reason) : .loadThenUse(reason)
    }

    /// At key-down: start loading now so the model is ready by the time the key is released?
    /// Only for Polished with Free memory when idle; in Natural the need is not known until the text is.
    public static func loadAtKeyDown(style: Style, memory: ModelMemory, model: ModelState) -> Bool {
        memory == .freeWhenIdle && style == .polished && model.installed && !model.loaded && !model.loading
    }

    public enum SettingsAction: Equatable, Sendable { case load, unload, none }

    /// What the running app should do after the settings (or the installed model) changed.
    /// Exact frees the model whichever memory setting is chosen; Keep ready loads it; Free memory when idle waits for the first need.
    public static func settingsAction(choice: StyleChoice, memory: ModelMemory, model: ModelState) -> SettingsAction {
        guard model.installed else { return .none }
        if choice == .exact { return (model.loaded || model.loading) ? .unload : .none }
        if memory == .keepReady { return (model.loaded || model.loading) ? .none : .load }
        return .none
    }

    /// Free memory when idle: has the model been unused for long enough to free it? Times are in seconds on one clock.
    public static func shouldFreeForIdle(memory: ModelMemory, idleMinutes: Int, lastUsed: TimeInterval?, now: TimeInterval, loaded: Bool) -> Bool {
        guard memory == .freeWhenIdle, loaded, let lastUsed else { return false }
        return now - lastUsed >= Double(idleMinutes) * 60
    }
}
