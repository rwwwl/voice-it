import AppKit
import VoiceItCore

/// The state behind the Vocabulary window. All the rules are in `Vocabulary` (tested); this only holds what is on screen and saves
/// through `ConfigStore`, so the settings file stays the single source of truth and an edit applies to the next dictation.
final class VocabularyModel: ObservableObject {
    enum Filter: String, CaseIterable { case all = "All", corrections = "Corrections", terms = "Terms" }
    struct Undo { let row: VocabularyRow; let id = UUID() }

    private let store: ConfigStore

    @Published private(set) var entries: [Config.DictionaryEntry] = []
    /// A problem with the settings file: edits are paused while it is set, so nothing is overwritten.
    @Published private(set) var problem: ConfigProblem?
    @Published var heardInput = ""
    @Published var correctInput = ""
    @Published var message: String?
    @Published var search = ""
    @Published var filter: Filter = .all
    @Published private(set) var editingID: String?
    @Published var editHeard = ""
    @Published var editCorrect = ""
    @Published var editMessage: String?
    @Published private(set) var savedFlash = false
    @Published private(set) var undo: Undo?
    @Published var bulkResult: String?

    private var flashWork: DispatchWorkItem?

    init(store: ConfigStore) { self.store = store; reload() }

    var rows: [VocabularyRow] {
        Vocabulary.rows(entries).filter { row in
            switch filter {
            case .all: return true
            case .corrections: return row.isCorrection
            case .terms: return !row.isCorrection
            }
        }.filter { Vocabulary.matches($0, search: search) }
    }
    var count: Int { Vocabulary.count(entries) }
    var correctionCount: Int { Vocabulary.rows(entries).filter(\.isCorrection).count }
    var termCount: Int { count - correctionCount }
    var isPaused: Bool { problem != nil }

    /// Picks up changes made to the file by hand. Does not disturb a row that is being edited.
    func reload() {
        let config = store.current()
        problem = store.problem
        if config.dictionary != entries { entries = config.dictionary }
    }

    // MARK: Saving

    /// Saves a new list through the settings store. Returns whether it is now in the file.
    @discardableResult
    private func save(_ new: [Config.DictionaryEntry]) -> Bool {
        reload()
        if let problem { message = "Edits are paused: \(problem.summary)"; return false }
        if new == entries { return true }
        _ = store.update { $0.dictionary = new }
        reload()
        guard entries == new else { message = "Couldn't save: the settings file changed. Try again."; return false }
        flashSaved()
        return true
    }

    private func flashSaved() {
        savedFlash = true
        flashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.savedFlash = false }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    // MARK: Adding

    func add() {
        message = nil
        do {
            let new = try Vocabulary.adding(heard: heardInput, correct: correctInput, to: entries)
            if save(new) { heardInput = ""; correctInput = "" }
        } catch let p as VocabularyProblem { message = p.message } catch { message = "\(error)" }
    }

    func addMany(_ text: String) {
        reload()
        if let problem { bulkResult = "Edits are paused: \(problem.summary)"; return }
        let result = Vocabulary.addingMany(text, to: entries)
        guard result.added > 0 else {
            bulkResult = result.skipped.isEmpty ? "Nothing to add." : describe(result)
            return
        }
        if save(result.entries) { bulkResult = describe(result) } else { bulkResult = message }
    }

    private func describe(_ r: Vocabulary.BulkResult) -> String {
        var text = r.summary
        for s in r.skipped.prefix(5) { text += "\nLine \(s.line): \(s.reason)" }
        if r.skipped.count > 5 { text += "\n…and \(r.skipped.count - 5) more." }
        return text
    }

    // MARK: Deleting, with an Undo link for a few seconds

    func remove(_ row: VocabularyRow) {
        guard !isPaused else { message = "Edits are paused: \(problem?.summary ?? "")"; return }
        guard save(Vocabulary.removing(row, from: entries)) else { return }
        let undo = Undo(row: row)
        self.undo = undo
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in if self?.undo?.id == undo.id { self?.undo = nil } }
    }

    func undoDelete() {
        guard let undo else { return }
        self.undo = nil
        do { save(try Vocabulary.adding(heard: undo.row.heard, correct: undo.row.term, to: entries)) }
        catch let p as VocabularyProblem { message = p.message } catch { message = "\(error)" }
    }

    // MARK: Editing in place

    func beginEdit(_ row: VocabularyRow) {
        guard !isPaused else { message = "Edits are paused: \(problem?.summary ?? "")"; return }
        editingID = row.id; editHeard = row.heard ?? ""; editCorrect = row.term; editMessage = nil
    }

    func cancelEdit() { editingID = nil; editMessage = nil }

    func commitEdit(_ row: VocabularyRow) {
        do {
            let new = try Vocabulary.replacing(row, heard: editHeard, correct: editCorrect, in: entries)
            if save(new) { editingID = nil; editMessage = nil } else { editMessage = message }
        } catch let p as VocabularyProblem { editMessage = p.message } catch { editMessage = "\(error)" }
    }

    // MARK: Other

    func copyList() {
        let text = Vocabulary.listText(entries)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func openSettingsFile() { NSWorkspace.shared.open(ConfigStore.url) }
}
