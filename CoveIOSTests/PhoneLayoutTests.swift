import Foundation
import Testing
@testable import CoveIOS

struct PhoneLayoutTests {
    @Test(arguments: [CGSize(width: 390, height: 700), CGSize(width: 466, height: 610), CGSize(width: 626, height: 820), CGSize(width: 744, height: 1000)])
    func portraitAlwaysKeepsVideoAboveChat(size: CGSize) {
        #expect(PhoneLayout.watchArrangement(size: size, accessibilityText: false) == .stacked)
        let video = PhoneLayout.videoHeight(in: size, showingChat: true, accessibilityText: false)
        #expect(video <= size.height * 0.48)
        #expect(size.height - video >= size.height * 0.52)
    }
    @Test(arguments: [CGSize(width: 890, height: 540), CGSize(width: 700, height: 320), CGSize(width: 1024, height: 700)])
    func wideWindowsPlaceChatAlongsideVideo(size: CGSize) {
        #expect(PhoneLayout.watchArrangement(size: size, accessibilityText: false) == .sideBySide)
        #expect(size.width - PhoneLayout.chatWidth(in: size) >= 380)
    }
    @Test func narrowSplitViewAndAccessibilityRemainStacked() {
        #expect(PhoneLayout.watchArrangement(size: CGSize(width: 450, height: 320), accessibilityText: false) == .stacked)
        #expect(PhoneLayout.watchArrangement(size: CGSize(width: 890, height: 540), accessibilityText: true) == .stacked)
    }
    @Test(arguments: [CGSize(width: 580, height: 600), CGSize(width: 420, height: 260)])
    func landscapePictureFitsWithoutFillingUnusedHeight(size: CGSize) {
        let height = PhoneLayout.splitVideoHeight(in: size, accessibilityText: false)
        #expect(height <= size.width * 9 / 16)
        #expect(height + 100 <= size.height)
    }
}
