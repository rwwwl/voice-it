import SwiftUI
import VoiceItCore
import VoiceItDownloader

/// The setup window's content: one step at a time, with a progress strip on top and Back and Continue at the bottom.
struct SetupView: View {
    @ObservedObject var model: SetupModel
    var onDone: () -> Void = {}
    /// False only when the window is drawn to an image (the developer preview), where a scroll view can't be drawn.
    var scrolls = true

    @State private var dropTargeted = false
    private let green = Color(red: 0.2, green: 0.83, blue: 0.6)
    private let amber = Color(red: 0.98, green: 0.75, blue: 0.14)
    private let red = Color(red: 0.97, green: 0.44, blue: 0.44)

    var body: some View {
        VStack(spacing: 0) {
            progressStrip
            Divider().overlay(.white.opacity(0.1))
            body(of: content)
            preparationBar
            Divider().overlay(.white.opacity(0.1))
            footer
        }
        .foregroundStyle(.white)
        .frame(width: 560, height: 580)
    }

    // MARK: Frame

    @ViewBuilder private func body(of content: some View) -> some View {
        let padded = content.padding(.horizontal, 28).padding(.vertical, 22).frame(maxWidth: .infinity, alignment: .leading)
        if scrolls { ScrollView { padded } } else { VStack(spacing: 0) { padded; Spacer(minLength: 0) } }
    }

    private var progressStrip: some View {
        HStack(spacing: 6) {
            ForEach(model.steps, id: \.self) { s in
                let current = s == model.step, past = s.rawValue < model.step.rawValue
                VStack(spacing: 5) {
                    Capsule().fill(current ? .white : (past ? green : .white.opacity(0.18))).frame(height: 3)
                    Text(s.title).font(.system(size: 10.5, weight: current ? .semibold : .regular)).foregroundStyle(.white.opacity(current ? 0.95 : 0.5)).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 28).padding(.top, 14).padding(.bottom, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(model.step.rawValue + 1) of \(model.steps.count): \(model.step.title)")
    }

    private var footer: some View {
        HStack {
            Button("Back") { model.back() }.buttonStyle(SetupButtonStyle()).disabled(model.isFirstStep).opacity(model.isFirstStep ? 0 : 1)
            Spacer()
            if model.isLastStep {
                Button("Done") { model.finish(); onDone() }.buttonStyle(SetupButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            } else {
                if model.step == .moveToApplications {
                    Button("Skip") { model.next() }.buttonStyle(SetupButtonStyle())
                } else {
                    Button("Continue") { model.next() }.buttonStyle(SetupButtonStyle(prominent: true)).keyboardShortcut(.defaultAction).disabled(!model.canContinue)
                }
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome: welcome
        case .moveToApplications: moveStep
        case .requirements: requirementsStep
        case .models: modelsStep
        case .menuBar: menuBarStep
        case .permissions: permissionsStep
        case .tryIt: tryIt
        }
    }

    // MARK: Pieces shared by the steps

    private func title(_ text: String, _ subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.system(size: 22, weight: .semibold))
            if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.bottom, 14)
    }

    private func badge(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(.black.opacity(0.75))
            .frame(width: 22, height: 22).background(Circle().fill(color)).accessibilityHidden(true)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.1), lineWidth: 1))
    }

    private func note(_ text: String, color: Color = .white.opacity(0.6)) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    private func size(_ bytes: Int64) -> String { bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1e9) : String(format: "%.0f MB", Double(bytes) / 1e6) }

    // MARK: 1. Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage()).resizable().frame(width: 64, height: 64)
                title("Welcome to Voice It")
            }
            Text("Hold a key, say what you want to write, let go. Your words appear in whichever app you are using, with the \"ums\" and false starts tidied up.")
                .font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
            card {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Everything runs on this Mac.", systemImage: "lock.fill").font(.system(size: 13, weight: .semibold))
                    note("Voice It turns speech into text with models stored on your Mac. After the one-time download in this setup, nothing you say or write leaves it: no account, no tracking, no connection to the internet.")
                }
            }
            note("Setup takes a few minutes, mostly the download. You can come back to it any time from the menu: Set up again…")
        }
    }

    // MARK: 1b. Applications

    private var moveStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Drag Voice It to Applications", "Voice It is running from \(model.placeName). Drag its icon onto the Applications folder to install it where it belongs.")
            card {
                HStack(spacing: 22) {
                    Spacer()
                    VStack(spacing: 6) {
                        if scrolls { AppIconDragSource(image: NSApp.applicationIconImage ?? NSImage(), appURL: Bundle.main.bundleURL).frame(width: 108, height: 108) }
                        else { Image(nsImage: NSApp.applicationIconImage ?? NSImage()).resizable().frame(width: 96, height: 96).padding(6) }
                        Text("Voice It").font(.system(size: 12.5, weight: .semibold))
                    }
                    Image(systemName: "arrow.right").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white.opacity(dropTargeted ? 0.9 : 0.45)).accessibilityHidden(true)
                    VStack(spacing: 6) {
                        if scrolls { FolderDropTarget(image: NSWorkspace.shared.icon(forFile: "/Applications"), isTargeted: $dropTargeted) { model.moveToApplications() }.frame(width: 108, height: 108) }
                        else { Image(nsImage: NSWorkspace.shared.icon(forFile: "/Applications")).resizable().frame(width: 96, height: 96).padding(6) }
                        Text("Applications").font(.system(size: 12.5, weight: .semibold))
                    }
                    Spacer()
                }
                .padding(.vertical, 10)
            }
            switch model.move {
            case .idle:
                note("It copies Voice It into Applications and opens the copy; the one you downloaded stays where it is, and you can delete it afterwards. macOS ties the permissions you give an app to where it is, so it is best to do this before the next steps.")
            case .copying:
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Copying…").font(.system(size: 13)) }
            case .opening(let url, let fellBack):
                HStack(alignment: .top, spacing: 8) {
                    badge("checkmark", green)
                    note("Copied to \(url.deletingLastPathComponent().path)\(fellBack ? " (your own Applications folder: the main one needs an administrator)" : ""). Opening it now; this window will close and setup carries on there.", color: .white.opacity(0.9))
                }
            case .failed(let message):
                HStack(alignment: .top, spacing: 8) { badge("exclamationmark", red); note(message, color: .white.opacity(0.9)) }
                note("Drag the icon onto the folder to try again.")
            }
        }
    }

    // MARK: 2. This Mac

    private var requirementsStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            title("Does this Mac qualify?", "Voice It needs an Apple silicon Mac with macOS 15 or later, enough memory and room for the models.")
            if let from = model.movedFrom { note("Voice It is now in Applications. The copy you downloaded is still at \(from); you can delete it.", color: green) }
            ForEach(Array(model.requirements.results.enumerated()), id: \.offset) { _, r in
                card {
                    HStack(alignment: .top, spacing: 10) {
                        badge(r.status == .ok ? "checkmark" : (r.status == .warning ? "exclamationmark" : "xmark"), r.status == .ok ? green : (r.status == .warning ? amber : red))
                        Text(r.message).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !model.requirements.canContinue {
                note("Voice It can't run on this Mac as it is. Fix what is marked above, then check again.", color: red)
                Button("Check again") { model.recheck() }.buttonStyle(SetupButtonStyle())
            }
        }
    }

    // MARK: 3. Models

    private var modelsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("Download the models", "Two models do the work. They are downloaded once, checked against fixed checksums, and kept on this Mac.")
            card {
                HStack(alignment: .top, spacing: 10) {
                    badge(model.speechInstalled ? "checkmark" : "arrow.down", model.speechInstalled ? green : .white.opacity(0.5))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text("Speech recognition").font(.system(size: 13.5, weight: .semibold)); Text("required").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)) }
                        note("Parakeet turns your voice into text. \(model.speech.map { size($0.totalBytes) } ?? "") · CC BY 4.0")
                        if model.speechInstalled { note("Already on this Mac.", color: green) }
                    }
                }
            }
            card {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $model.wantsCleanup) {
                        HStack { Text("Text cleanup").font(.system(size: 13.5, weight: .semibold)); Text("optional").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)) }
                    }
                    .toggleStyle(SetupToggleStyle())
                    .disabled(model.cleanupInstalled || model.download == .running)
                    note("Qwen3 fixes self-corrections and tidies wording in the Natural and Polished styles. Without it only the Exact style is available. \(model.cleanup.map { size($0.totalBytes) } ?? "") · Apache 2.0")
                    if model.cleanupInstalled { note("Already on this Mac.", color: green) }
                    else if !model.cleanupRecommended {
                        note("This Mac has \(model.memoryText) of memory. The cleanup model is tested and recommended from 16 GB, so it is off by default here.", color: amber)
                    } else { note("Uses about 2.6 GB of memory while Voice It runs. Recommended for this Mac (\(model.memoryText)).") }
                }
            }
            downloadArea
            note("Prefer to fetch them yourself? Put the files in the models folder (the README says how), then come back.")
            Button("Show models folder") { model.openModelsFolder() }.buttonStyle(SetupButtonStyle(small: true))
        }
    }

    @ViewBuilder private var downloadArea: some View {
        switch model.download {
        case .running:
            VStack(alignment: .leading, spacing: 6) {
                ProgressBar(fraction: model.progress?.fraction ?? 0)
                HStack {
                    Text(model.progress.map { "\(size($0.bytesDone)) of \(size($0.bytesTotal))" } ?? "Starting…").font(.system(size: 12))
                    Spacer()
                    Text(model.progress?.file ?? "").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).truncationMode(.middle)
                }
                note("Closing this window stops the download; what has arrived is kept and the next try carries on from it.")
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) { badge("exclamationmark", red); note(message, color: .white.opacity(0.9)) }
                Button("Retry") { model.startDownload() }.buttonStyle(SetupButtonStyle(prominent: true))
            }
        case .done:
            HStack(spacing: 8) { badge("checkmark", green); Text("Downloaded and checked.").font(.system(size: 13)) }
        case .idle:
            if model.idsToFetch.isEmpty {
                HStack(spacing: 8) { badge("checkmark", green); Text("Everything you chose is already on this Mac.").font(.system(size: 13)) }
            } else {
                HStack {
                    Button("Download \(size(model.bytesToFetch))") { model.startDownload() }.buttonStyle(SetupButtonStyle(prominent: true))
                    note("Needs about \(size(ModelDownloader.spaceNeeded(remaining: model.bytesToFetch, compiledCopy: model.idsToFetch.contains("speech") ? (model.speech?.totalBytes ?? 0) : 0))) of free space.")
                }
            }
        }
    }

    // MARK: 4. The menu bar

    private func menuBarImage(_ look: String) -> Image {
        if let image = NSImage(named: "menubar-\(look)") { image.isTemplate = true; return Image(nsImage: image).renderingMode(.template).resizable() }
        return Image(systemName: "mic").resizable()
    }

    private var menuBarStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("You're set. Look for the menu bar icon", "Voice It has no window and no Dock icon: it lives in the menu bar. Look for this icon at the top right of your screen, and click it for Style, Vocabulary, Set up again and Quit.")
            card {
                VStack(spacing: 6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.06))
                        HStack(spacing: 16) {
                            Spacer()
                            Image(systemName: "wifi").font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
                            Image(systemName: "battery.75percent").font(.system(size: 15)).foregroundStyle(.white.opacity(0.75))
                            menuBarImage("idle").aspectRatio(contentMode: .fit).foregroundStyle(.white).frame(width: 20, height: 20)
                                .padding(5).background(RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.25, green: 0.5, blue: 0.98)))
                                .accessibilityLabel("The Voice It icon")
                            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
                            Text("Fri 9:41").font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                        }
                        .padding(.horizontal, 14)
                    }
                    .frame(height: 34)
                    HStack {
                        Spacer()
                        VStack(spacing: 2) {
                            Image(systemName: "arrowtriangle.up.fill").font(.system(size: 9)).foregroundStyle(Color(red: 0.25, green: 0.5, blue: 0.98))
                            Text("Voice It").font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.trailing, 100)
                    }
                }
            }
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("What the icon tells you").font(.system(size: 13, weight: .semibold))
                    iconMeaning("idle", "Ready. Hold the hotkey and speak.")
                    iconMeaning("recording", "Listening to you.")
                    iconMeaning("blocked", "Something needs attention: click it to see what.")
                }
            }
            note("Can't see it? The menu bar may be full (MacBooks with a notch hide the overflow). Hold ⌘ and drag other icons off, or quit a menu bar app you don't use.")
        }
    }

    private func iconMeaning(_ look: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            menuBarImage(look).aspectRatio(contentMode: .fit).foregroundStyle(.white).frame(width: 18, height: 18)
                .padding(5).background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.06))).accessibilityHidden(true)
            Text(text).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.85))
        }
    }

    /// While the speech model is being prepared in the background (about 30 seconds, once) or if that fails, say so on every later step.
    @ViewBuilder private var preparationBar: some View {
        if model.speechInstalled, model.step.rawValue >= SetupStep.models.rawValue {
            switch model.speechLoad {
            case .notStarted, .loading:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Preparing the speech model for this Mac's Neural Engine. About a minute, once. You can carry on.").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.75))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 28).padding(.vertical, 8).background(.white.opacity(0.05))
            case .failed(let why):
                HStack(spacing: 10) {
                    badge("exclamationmark", red)
                    Text("The speech model couldn't be loaded: \(why)").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.9)).lineLimit(2)
                    Spacer(minLength: 0)
                    Button("Try again") { model.retryLoad() }.buttonStyle(SetupButtonStyle(small: true))
                }
                .padding(.horizontal, 28).padding(.vertical, 8).background(red.opacity(0.14))
            case .ready: EmptyView()
            }
        }
    }

    // MARK: 5. Permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            title("Allow three things", "Click each one in turn: macOS then asks you to allow it. The status below is read from the Mac, so it changes as soon as you do.")
            permissionRow("Microphone", "To hear you while you hold the key. Audio is not stored.", granted: model.state.microphoneGranted,
                          detail: model.microphone == .notDetermined ? "Not asked yet" : (model.state.microphoneGranted ? "Allowed" : "Off"), button: model.state.microphoneGranted ? nil : model.microphoneButton) { model.allowMicrophone() }
            permissionRow("Input Monitoring", "To notice the hotkey in any app. Voice It reads only that one key.", granted: model.state.inputMonitoringGranted,
                          detail: model.state.inputMonitoringGranted ? "Allowed" : "Off", button: model.state.inputMonitoringGranted ? nil : model.inputMonitoringButton) { model.allowInputMonitoring() }
            permissionRow("Accessibility", "To paste the text into the app you are in. Without it Voice It copies the text to the clipboard instead.", granted: model.state.accessibilityGranted,
                          detail: model.state.accessibilityGranted ? "Allowed" : "Off", button: model.state.accessibilityGranted ? nil : model.accessibilityButton, optional: true) { model.allowAccessibility() }
            if !model.state.inputMonitoringGranted { note("After you allow Input Monitoring, macOS may ask you to quit and reopen Voice It. If the hotkey does nothing, quit it from the menu and open it again.", color: amber) }
            note("Each setting is in System Settings → Privacy & Security. You can change your mind there at any time.")
        }
    }

    private func permissionRow(_ name: String, _ why: String, granted: Bool, detail: String, button: String?, optional: Bool = false, action: @escaping () -> Void) -> some View {
        card {
            HStack(alignment: .top, spacing: 10) {
                badge(granted ? "checkmark" : (optional ? "exclamationmark" : "xmark"), granted ? green : (optional ? amber : red))
                VStack(alignment: .leading, spacing: 3) {
                    HStack { Text(name).font(.system(size: 13.5, weight: .semibold)); Text(detail).font(.system(size: 11.5)).foregroundStyle(granted ? green : .white.opacity(0.55)) }
                    note(why)
                }
                Spacer(minLength: 8)
                if let button { Button(button, action: action).buttonStyle(SetupButtonStyle(small: true)) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: 6. Try it

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("Try it", "Click in the box below, hold the key shown in blue, say a sentence, and let go.")
            TextEditor(text: $model.practiceText)
                .font(.system(size: 14)).scrollContentBackground(.hidden).padding(8)
                .frame(height: 84)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.09)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.18), lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if model.practiceText.isEmpty { Text("Your words will appear here.").font(.system(size: 14)).foregroundStyle(.white.opacity(0.35)).padding(14).allowsHitTesting(false) }
                }
            if !model.hotkeyActive { note("The hotkey isn't active yet. It needs Input Monitoring (the previous step).", color: amber) }
            card {
                VStack(alignment: .leading, spacing: 12) {
                    KeyboardRow(hotkey: model.hotkey, copyModifier: model.copyModifier)
                    VStack(alignment: .leading, spacing: 6) {
                        keyTip([(model.hotkey, .hold)], "Hold, speak, release: the text is pasted. A quick tap does nothing.")
                        keyTip([(model.hotkey, .hold), (.rightShift, .add)], "Add Shift while holding, then let go of both: it keeps recording hands-free until you click the check mark.")
                        keyTip([(model.hotkey, .hold), (model.copyModifier, .copy)], "Add \(model.copyModifier.displayName) while holding: the text is copied instead of pasted.")
                    }
                }
            }
        }
    }

    private enum KeyRole { case hold, add, copy }

    private func keyTip(_ keys: [(Hotkey, KeyRole)], _ text: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { i, k in
                    if i > 0 { Text("+").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)) }
                    KeyCap(symbol: k.0.symbol, word: (k.0.isRightSide ? "right " : "left ") + k.0.keyWord, role: k.1 == .hold ? .primary : (k.1 == .copy ? .copy : .secondary))
                }
            }
            .frame(width: 210, alignment: .leading)
            Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One key as it looks on the keyboard: a rounded cap with its symbol and word. The role says why it is drawn (blue: hold this; green: add
/// this; amber: copy).
struct KeyCap: View {
    enum Role { case primary, secondary, copy, plain }
    let symbol: String
    let word: String
    var role = Role.plain
    var width: CGFloat? = nil

    private var color: Color {
        switch role {
        case .primary: return Color(red: 0.25, green: 0.5, blue: 0.98)
        case .secondary: return Color(red: 0.2, green: 0.83, blue: 0.6)
        case .copy: return Color(red: 0.98, green: 0.75, blue: 0.14)
        case .plain: return .white.opacity(0.14)
        }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(symbol).font(.system(size: 12, weight: .medium))
            Text(word).font(.system(size: 8.5))
        }
        .foregroundStyle(role == .plain ? .white.opacity(0.7) : (role == .secondary || role == .copy ? .black.opacity(0.8) : .white))
        .padding(.horizontal, 6).padding(.vertical, 4)
        .frame(width: width, alignment: .trailing)
        .lineLimit(1).minimumScaleFactor(0.8)
        .background(RoundedRectangle(cornerRadius: 5).fill(color))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(role == .plain ? 0.18 : 0.0), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(word)
    }
}

/// The bottom row of a Mac keyboard with the keys Voice It uses marked: where to look, left to right, fn control option command, space,
/// command option. The hotkey is blue and the copy key amber; a hotkey or copy key that is not in this row (Shift, Control on the right)
/// is named next to it instead.
struct KeyboardRow: View {
    let hotkey: Hotkey
    let copyModifier: Hotkey

    private struct Key: Identifiable { let id: String; let symbol: String; let word: String; let width: CGFloat; let match: Hotkey? }
    private let keys: [Key] = [
        Key(id: "fn", symbol: "fn", word: "", width: 36, match: nil),
        Key(id: "lc", symbol: "⌃", word: "control", width: 58, match: .leftControl),
        Key(id: "lo", symbol: "⌥", word: "option", width: 50, match: .leftOption),
        Key(id: "lm", symbol: "⌘", word: "command", width: 66, match: .leftCommand),
        Key(id: "sp", symbol: "", word: "", width: 96, match: nil),
        Key(id: "rm", symbol: "⌘", word: "command", width: 66, match: .rightCommand),
        Key(id: "ro", symbol: "⌥", word: "option", width: 50, match: .rightOption),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(keys) { k in
                    let role: KeyCap.Role = k.match == hotkey ? .primary : (k.match == copyModifier ? .copy : .plain)
                    KeyCap(symbol: k.symbol, word: k.word, role: role, width: k.width)
                        .frame(height: 34)
                }
            }
            HStack(spacing: 14) {
                legend(.primary, "hold: \(hotkey.displayName)")
                legend(.copy, "copy: \(copyModifier.displayName)")
                if !keys.contains(where: { $0.match == hotkey }) || !keys.contains(where: { $0.match == copyModifier }) {
                    Text("(a key not in this row is on the rows above)").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Keyboard: hold \(hotkey.displayName); copy with \(copyModifier.displayName)")
    }

    private func legend(_ role: KeyCap.Role, _ text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(role == .primary ? Color(red: 0.25, green: 0.5, blue: 0.98) : Color(red: 0.98, green: 0.75, blue: 0.14)).frame(width: 10, height: 10)
            Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
        }
    }

}

// MARK: Controls drawn by hand, so the window looks the same everywhere and can be drawn to an image

struct SetupButtonStyle: ButtonStyle {
    var prominent = false
    var small = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: small ? 12 : 13, weight: prominent ? .semibold : .regular))
            .foregroundStyle(.white)
            .padding(.horizontal, small ? 11 : 16).padding(.vertical, small ? 4 : 6)
            .background(Capsule().fill(prominent ? Color(red: 0.25, green: 0.5, blue: 0.98) : .white.opacity(configuration.isPressed ? 0.26 : 0.14)))
            .overlay(Capsule().strokeBorder(.white.opacity(prominent ? 0 : 0.2), lineWidth: 1))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

struct SetupToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 10) {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Color(red: 0.2, green: 0.83, blue: 0.6) : .white.opacity(0.25)).frame(width: 36, height: 20)
                    Circle().fill(.white).frame(width: 16, height: 16).padding(2)
                }
                configuration.label
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.55)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

struct ProgressBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule().fill(Color(red: 0.2, green: 0.83, blue: 0.6)).frame(width: max(6, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Download progress")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}
