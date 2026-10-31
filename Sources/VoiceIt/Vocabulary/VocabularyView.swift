import SwiftUI
import VoiceItCore

/// The Vocabulary window's content: add, search, edit and delete corrections and plain terms.
struct VocabularyView: View {
    @ObservedObject var model: VocabularyModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingBulk = false
    @State private var bulkText = ""
    @FocusState private var focus: Field?
    private enum Field { case heard, correct }

    private let amber = Color(red: 0.98, green: 0.75, blue: 0.14)
    private let red = Color(red: 0.97, green: 0.44, blue: 0.44)

    var body: some View {
        VStack(spacing: 0) {
            if let problem = model.problem { errorBanner(problem) }
            header
            Divider().overlay(.white.opacity(0.1))
            toolbar
            list
            footer
        }
        .foregroundStyle(.white)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 520, idealHeight: 620)
        .sheet(isPresented: $showingBulk) { bulkSheet }
        .onAppear { focus = .heard }
    }

    // MARK: Pieces

    private func errorBanner(_ problem: ConfigProblem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(red)
            VStack(alignment: .leading, spacing: 2) {
                Text("The settings file has an error").font(.system(size: 13, weight: .semibold))
                Text(problem.summary).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                Text("Edits are paused so nothing is overwritten. Your last good settings are still in use.").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 8)
            Button("Open settings file") { model.openSettingsFile() }.controlSize(.small)
        }
        .padding(12)
        .background(red.opacity(0.18))
        .overlay(alignment: .bottom) { Rectangle().fill(red.opacity(0.5)).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 10) {
                field("Heard as (optional)", prompt: "e.g. fluid audio", text: $model.heardInput, focusValue: .heard)
                Image(systemName: "arrow.right").foregroundStyle(.white.opacity(0.4)).padding(.bottom, 7).accessibilityHidden(true)
                field("Correct spelling", prompt: "e.g. FluidAudio", text: $model.correctInput, focusValue: .correct)
                Button("Add") { model.add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isPaused || model.correctInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityHint("Adds the entry to the vocabulary")
                Button("Add many…") { bulkText = ""; model.bulkResult = nil; showingBulk = true }
                    .disabled(model.isPaused)
            }
            if let message = model.message {
                Label(message, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(red).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Leave Heard as empty to add a plain term: a word to spell correctly.").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(14)
        .disabled(model.isPaused)
        .opacity(model.isPaused ? 0.5 : 1)
    }

    private func field(_ title: String, prompt: String, text: Binding<String>, focusValue: Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.65))
            TextField(title, text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: focusValue)
                .onSubmit { model.add() }
                .onChange(of: text.wrappedValue) { _, _ in model.message = nil }
                .accessibilityLabel(title)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
                TextField("Search", text: $model.search).textFieldStyle(.plain).accessibilityLabel("Search the vocabulary")
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.5)).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08)))
            Picker("Show", selection: $model.filter) {
                ForEach(VocabularyModel.Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 230).accessibilityLabel("Filter the list")
            Button { model.copyList() } label: { Label("Copy list", systemImage: "doc.on.doc") }
                .disabled(model.entries.isEmpty)
                .accessibilityHint("Copies every entry as text, one per line")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var list: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.rows) { row in
                        if model.editingID == row.id { editRow(row) } else { displayRow(row) }
                        Divider().overlay(.white.opacity(0.06))
                    }
                    if model.rows.isEmpty { emptyState.padding(.top, 40) }
                }
                .padding(.horizontal, 14)
            }
            if let undo = model.undo {
                HStack {
                    Text("Deleted \u{201C}\(undo.row.term)\u{201D}.").font(.system(size: 12.5))
                    Button("Undo") { model.undoDelete() }.buttonStyle(.link)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(.black.opacity(0.55)).overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1)))
                .padding(.bottom, 10)
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.undo?.id)
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        Text(model.entries.isEmpty ? "No entries yet. Add a word above." : "Nothing matches.")
            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
    }

    private func displayRow(_ row: VocabularyRow) -> some View {
        HStack(spacing: 10) {
            if let heard = row.heard {
                Text(heard).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                Text(row.term).fontWeight(.medium).lineLimit(1)
            } else {
                Text(row.term).fontWeight(.medium).lineLimit(1)
                Text("Plain term").italic().font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 8)
            Button { model.beginEdit(row) } label: { Image(systemName: "pencil") }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.65))
                .accessibilityLabel("Edit \(describe(row))")
            Button { model.remove(row) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.65))
                .accessibilityLabel("Delete \(describe(row))")
        }
        .font(.system(size: 13.5))
        .padding(.vertical, 9)
        .disabled(model.isPaused)
        .accessibilityElement(children: .contain)
    }

    private func describe(_ row: VocabularyRow) -> String {
        row.heard.map { "\($0), corrected to \(row.term)" } ?? "\(row.term), plain term"
    }

    private func editRow(_ row: VocabularyRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Heard as (optional)", text: $model.editHeard).textFieldStyle(.roundedBorder).accessibilityLabel("Heard as")
                Image(systemName: "arrow.right").foregroundStyle(.white.opacity(0.4))
                TextField("Correct spelling", text: $model.editCorrect).textFieldStyle(.roundedBorder).accessibilityLabel("Correct spelling")
                Button { model.commitEdit(row) } label: { Image(systemName: "checkmark") }.buttonStyle(.plain).accessibilityLabel("Save the change")
                Button { model.cancelEdit() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Cancel the change")
            }
            .onSubmit { model.commitEdit(row) }                     // Enter saves
            .onExitCommand { model.cancelEdit() }                   // Escape cancels
            if let editMessage = model.editMessage {
                Text(editMessage).font(.system(size: 12)).foregroundStyle(red)
            }
        }
        .padding(.vertical, 8)
    }

    private var footer: some View {
        let count = model.count
        let warn = count >= Vocabulary.warnAt
        return VStack(spacing: 6) {
            HStack {
                Text("\(count) of \(Vocabulary.limit) entries").font(.system(size: 12)).foregroundStyle(warn ? amber : .white.opacity(0.7))
                Spacer()
                if model.savedFlash {
                    Label("Saved", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(Color(red: 0.2, green: 0.83, blue: 0.6))
                        .transition(.opacity)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(warn ? amber : .white.opacity(0.55))
                        .frame(width: geo.size.width * min(1, CGFloat(count) / CGFloat(Vocabulary.limit)))
                }
            }
            .frame(height: 4)
            .accessibilityElement().accessibilityLabel("\(count) of \(Vocabulary.limit) entries used")
            if warn {
                Text("A long list slows the cleanup down for a few seconds after each change.").font(.system(size: 11.5)).foregroundStyle(amber.opacity(0.9))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .top) { Divider().overlay(.white.opacity(0.1)) }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.savedFlash)
    }

    private var bulkSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add many").font(.system(size: 15, weight: .semibold))
            Text("One entry per line. Use = or an arrow for a correction (heard as = correct spelling); a line with no arrow is a plain term.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $bulkText)
                .font(.system(size: 13, design: .monospaced))
                .frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.2)))
                .accessibilityLabel("Entries to add, one per line")
            if let result = model.bulkResult {
                Text(result).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Close") { showingBulk = false }.keyboardShortcut(.cancelAction)
                Button("Add") { model.addMany(bulkText) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(bulkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
        .preferredColorScheme(.dark)
    }
}
