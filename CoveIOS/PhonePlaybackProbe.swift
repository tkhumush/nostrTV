#if DEBUG
import SwiftUI
import AVFoundation

/// Explicit UI-test diagnostics; neither the probe nor its media fixture ships in Release.
struct PhonePlaybackProbe: View {
    let session: PhoneWatchSession
    @State private var seconds = 0.0
    @State private var observer: Any?
    var body: some View {
        Text(session.id).font(.system(size: 1)).frame(height: 1).opacity(0.02)
            .accessibilityHidden(false)
            .accessibilityIdentifier("phone-session-id")
            .accessibilityValue(String(format: "%.2f", seconds))
            .onAppear {
                guard observer == nil else { return }
                observer = session.player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { time in
                    seconds = time.seconds.isFinite ? time.seconds : 0
                }
            }
            .onDisappear {
                if let observer { session.player.removeTimeObserver(observer) }
                observer = nil
            }
    }
}
#endif
