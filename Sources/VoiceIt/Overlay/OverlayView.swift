import AppKit
import SwiftUI

final class OverlayModel: ObservableObject {
    @Published var state: OverlayState = .processing
    @Published var visible = false
    @Published var shake = 0
    let spectrum = SpectrumModel()
    var onCancel: () -> Void = {}
    var onDone: () -> Void = {}
    var onAction: (PillAction) -> Void = { _ in }
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

struct OverlayView: View {
    static let size = CGSize(width: 440, height: 130)
    @ObservedObject var model: OverlayModel

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            pill.padding(.bottom, 40)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private var pill: some View {
        let state = model.state
        let width = PillMetrics.width(for: state)
        let reduce = model.reduceMotion
        return TimelineView(.animation(minimumInterval: nil, paused: !state.isListening)) { tl in
            pillFrame(state: state, width: width, reduce: reduce, now: tl.date.timeIntervalSinceReferenceDate)
        }
        .animation(reduce ? .easeOut(duration: 0.15) : .spring(response: 0.5, dampingFraction: 0.62), value: width)
        .animation(.easeOut(duration: 0.15), value: state)
        .keyframeAnimator(initialValue: CGFloat(0), trigger: model.shake) { view, dx in
            view.offset(x: dx)
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(model.reduceMotion ? 0 : -6, duration: 0.09)
                LinearKeyframe(model.reduceMotion ? 0 : 6, duration: 0.09)
                LinearKeyframe(model.reduceMotion ? 0 : -3, duration: 0.09)
                LinearKeyframe(model.reduceMotion ? 0 : 3, duration: 0.09)
                LinearKeyframe(0, duration: 0.09)
            }
        }
        .opacity(model.visible ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: model.visible)
    }

    private func pillFrame(state: OverlayState, width: CGFloat, reduce: Bool, now: TimeInterval) -> some View {
        model.spectrum.step(now: now, reduceMotion: reduce)
        return ZStack {
            PillGlow(glow: state.isListening ? model.spectrum.glow : 0)
                .frame(width: width, height: PillMetrics.height)
            PillMaterial().frame(width: width, height: PillMetrics.height)
            content(state, reduce: reduce)
                .frame(width: width, height: PillMetrics.height)
                .id(state)
                .transition(.opacity)
            if case .loading = state {
                LoadingBar(reduceMotion: reduce).frame(width: width, height: PillMetrics.height).clipShape(Capsule())
            }
        }
        .frame(width: width, height: PillMetrics.height)
    }

    @ViewBuilder
    private func content(_ state: OverlayState, reduce: Bool) -> some View {
        switch state {
        case .listening(let chip, let handsFree, let warning):
            HStack(spacing: 12) {
                SpectrumCanvas(model: model.spectrum)
                if let chip {
                    Text(chip).font(.system(size: 12.5)).foregroundStyle(.white).lineLimit(1).fixedSize()
                        .padding(.horizontal, 11)
                        .frame(height: PillMetrics.buttonSize)
                        .background(Capsule().fill(.white.opacity(0.16)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 1))
                }
                if let warning {
                    Text(warning).font(.system(size: 12.5)).foregroundStyle(Color(red: 0.98, green: 0.75, blue: 0.14)).lineLimit(1).fixedSize()
                }
                if handsFree {
                    HStack(spacing: PillMetrics.buttonGap) {
                        DoneButton { model.onDone() }
                        CancelButton { model.onCancel() }
                    }
                }
            }
            .padding(.leading, 20).padding(.trailing, handsFree || chip != nil ? PillMetrics.buttonEdge : 20)
        case .processing:
            ProcessingLabel(reduceMotion: reduce)
        case .loading:
            LoadingLabel(reduceMotion: reduce)
        case .done:
            HStack(spacing: 12) {
                Badge(symbol: "checkmark", fill: Color(red: 0.2, green: 0.83, blue: 0.6), ink: Color(red: 0.02, green: 0.18, blue: 0.12))
                Text("Pasted").font(PillMetrics.font).foregroundStyle(.white)
            }
            .padding(.leading, 14).padding(.trailing, 18)
        case .copied:
            HStack(spacing: 12) {
                Badge(symbol: "checkmark", fill: Color(red: 0.2, green: 0.83, blue: 0.6), ink: Color(red: 0.02, green: 0.18, blue: 0.12))
                Text("Copied").font(PillMetrics.font).foregroundStyle(.white).lineLimit(1).fixedSize()
            }
            .padding(.leading, 14).padding(.trailing, 18)
        case .noSpeech:
            Text("No speech detected").font(PillMetrics.font).foregroundStyle(.white).padding(.horizontal, 18)
        case .notice(let message):
            HStack(spacing: 12) {
                Badge(symbol: "exclamationmark", fill: Color(red: 0.98, green: 0.75, blue: 0.14), ink: Color(red: 0.23, green: 0.15, blue: 0))
                Text(message).font(PillMetrics.font).foregroundStyle(.white).lineLimit(1).fixedSize()
            }
            .padding(.leading, 14).padding(.trailing, 18)
        case .blocked(let message, let action):
            HStack(spacing: 12) {
                Badge(symbol: Self.symbol(for: action), fill: Color(red: 0.97, green: 0.44, blue: 0.44), ink: Color(red: 0.23, green: 0.04, blue: 0.04))
                Text(message).font(PillMetrics.font).foregroundStyle(.white).lineLimit(1).fixedSize()
                if let action { SettingsChip { model.onAction(action) }.padding(.leading, PillMetrics.chipGap - 12) }
            }
            .padding(.leading, 14).padding(.trailing, action == nil ? 18 : PillMetrics.chipEdge)
        }
    }

    private static func symbol(for action: PillAction?) -> String {
        switch action {
        case .openMicrophone: return "mic.slash"
        case .openAccessibility: return "hand.raised.slash"
        case .openInputMonitoring: return "keyboard"
        case .openSettingsFile: return "doc.badge.gearshape"
        case nil: return "xmark"
        }
    }
}

/// The glass "Open settings" chip on a blocked pill.
private struct SettingsChip: View {
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(PillMetrics.settingsChipLabel).font(.system(size: 12.5)).foregroundStyle(.white).lineLimit(1).fixedSize()
                .padding(.horizontal, PillMetrics.chipPadding)
                .frame(height: PillMetrics.chipHeight)
                .background(Capsule().fill(.white.opacity(hover ? 0.26 : 0.16)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(PillMetrics.settingsChipLabel)
    }
}

private struct Badge: View {
    let symbol: String, fill: Color, ink: Color
    var body: some View {
        Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(ink)
            .frame(width: 22, height: 22).background(Circle().fill(fill))
    }
}

private struct DoneButton: View {
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(hover ? 0.22 : 0.1)))
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel("Finish dictation")
    }
}

private struct CancelButton: View {
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(hover ? 0.22 : 0.1)))
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel("Cancel dictation")
    }
}
