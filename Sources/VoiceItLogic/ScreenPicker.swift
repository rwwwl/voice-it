import CoreGraphics

/// Chooses which display the overlay appears on: the one showing the most of the focused window.
public enum ScreenPicker {
    /// Index into `screens` of the display containing the largest part of `window`, or nil if the window overlaps none of them.
    /// All rectangles must be in the same coordinate space.
    public static func index(forWindow window: CGRect, screens: [CGRect]) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (i, frame) in screens.enumerated() {
            let overlap = window.intersection(frame)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > 0, best == nil || area > best!.area { best = (i, area) }
        }
        return best?.index
    }
}
