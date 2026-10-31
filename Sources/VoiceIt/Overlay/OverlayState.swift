import AppKit
import SwiftUI

/// What the "Open settings" chip on a blocked pill does.
enum PillAction: Hashable { case openMicrophone, openAccessibility, openInputMonitoring, openSettingsFile }

enum OverlayState: Hashable {
    /// Hold to talk shows the spectrum (and the style chip, only under Automatic by app when the style isn't Natural) with no buttons.
    /// Hands-free adds the Done and X buttons, and `warning` ("Stops in 29 s") shortly before the time limit.
    case listening(chip: String?, handsFree: Bool = false, warning: String? = nil)
    case processing
    case loading                      // "Loading model", with a travelling line along the bottom edge
    case done
    case copied                       // green: the copy modifier was held, so the text went to the clipboard on purpose
    case noSpeech
    case notice(String)               // amber: worked with a caveat
    case blocked(String, action: PillAction?)   // red: the user has to do something

    var isListening: Bool { if case .listening = self { return true }; return false }
    /// States with something to click (the X, or the Open settings chip).
    var isClickable: Bool {
        switch self {
        case .listening(_, let handsFree, _): return handsFree      // while holding the key nothing can be clicked
        case .blocked(_, let action): return action != nil
        default: return false
        }
    }
}

enum PillMetrics {
    static let height: CGFloat = 48
    static let font = Font.system(size: 14, weight: .medium)
    static let nsFont = NSFont.systemFont(ofSize: 14, weight: .medium)
    static let spectrumWidth: CGFloat = 109   // 16 bars of 4 pt with 3 pt gaps
    static let spectrumHeight: CGFloat = 28

    static func textWidth(_ s: String) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: nsFont]).width) + 4    // a little slack so the text is never clipped
    }

    /// The round glass buttons (Done, X): 26 pt, 11 pt from the pill's top, bottom and right edges, 8 pt apart.
    static let buttonSize: CGFloat = 26
    static let buttonEdge: CGFloat = 11
    static let buttonGap: CGFloat = 8

    static let chipFont = NSFont.systemFont(ofSize: 12.5)
    /// The "Open settings" chip is 26 pt high like the round buttons, so it sits 11 pt from the pill's top, bottom and right edges.
    static let chipHeight: CGFloat = 26
    static let chipPadding: CGFloat = 13
    static let chipGap: CGFloat = 14            // between the message and the chip
    static let chipEdge: CGFloat = 11
    /// Width of the chip: its text plus its side padding.
    static func chipWidth(_ s: String) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: chipFont]).width) + 2 * chipPadding }
    static let settingsChipLabel = "Open settings"

    /// Width fits the content with even padding; the pill animates between these.
    static func width(for state: OverlayState) -> CGFloat {
        switch state {
        case .listening(let chip, let handsFree, let warning):
            let chipWidth = chip.map { 12 + textWidth($0) + 22 } ?? 0                  // gap, chip text and its padding
            let note = warning.map { 12 + ceil(($0 as NSString).size(withAttributes: [.font: chipFont]).width) + 4 } ?? 0
            if !handsFree { return 20 + spectrumWidth + chipWidth + (chip == nil ? 20 : buttonEdge) }
            return 20 + spectrumWidth + chipWidth + note + 12 + buttonSize + buttonGap + buttonSize + buttonEdge
        case .processing: return 18 + 92 + 18
        case .loading: return 18 + textWidth("Loading model") + 18
        case .done: return 14 + 22 + 12 + textWidth("Pasted") + 18
        case .copied: return 14 + 22 + 12 + textWidth("Copied") + 18
        case .noSpeech: return 18 + textWidth("No speech detected") + 18
        case .notice(let m): return 14 + 22 + 12 + textWidth(m) + 18
        case .blocked(let m, let action):
            // badge, message, then the chip with 10 pt to the edge (or 18 pt if there is no chip)
            return 14 + 22 + 12 + textWidth(m) + (action == nil ? 18 : chipGap + chipWidth(settingsChipLabel) + chipEdge)
        }
    }
}
