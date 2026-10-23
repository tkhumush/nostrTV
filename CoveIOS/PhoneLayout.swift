import Foundation

/// Use the presentation's viewport for arrangement and content bounds for sizing.
enum PhoneWatchArrangement: String { case stacked, sideBySide }

struct PhoneLayout {
    static func watchArrangement(size: CGSize, accessibilityText: Bool) -> PhoneWatchArrangement {
        guard !accessibilityText, size.width >= 640, size.width > size.height else { return .stacked }
        return .sideBySide
    }
    /// On Duo `size` includes the vertical bar the chat runs beneath, so the share is smaller.
    static func chatWidth(in size: CGSize) -> CGFloat { min(360, max(260, size.width * 0.30)) }
    static func splitVideoHeight(in size: CGSize, accessibilityText: Bool) -> CGFloat {
        // Fit the picture at the top rather than centering it in unused vertical
        // space. Reserve room for the creator row, including with the keyboard.
        min(size.width * 9 / 16, max(72, size.height - (accessibilityText ? 140 : 100)))
    }
    static func videoHeight(in size: CGSize, showingChat: Bool, accessibilityText: Bool) -> CGFloat {
        let ideal = size.width * 9 / 16
        // A raised keyboard reduces the proposed height. Give the composer room first.
        let share = size.height * (showingChat ? (size.height < 420 ? 0.28 : 0.48) : 0.78)
        return max(72, min(ideal, accessibilityText ? min(share, 180) : share))
    }
}
