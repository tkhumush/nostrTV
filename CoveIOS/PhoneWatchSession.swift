import AVKit
import Combine
import SwiftUI

/// This owner survives layout, sheet, keyboard, and fold transitions.
@MainActor
final class PhoneWatchSession: ObservableObject {
    let id = UUID().uuidString
    let stream: Stream
    let client: NostrSDKClient
    let player = AVPlayer()
    let activity = StreamActivityManager()
    @Published var draft = ""
    @Published private(set) var sending = false
    @Published private(set) var sendError: String?
    @Published private(set) var failed = false
    @Published private(set) var buffering = false
    @Published var pictureInPictureActive = false
    private(set) var startCount = 0
    private var observations = Set<AnyCancellable>()
    private var itemStatus: AnyCancellable?
    private var started = false
    private var previousIdleTimer = false

    init(stream: Stream, client: NostrSDKClient) {
        self.stream = stream
        self.client = client
        activity.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        player.publisher(for: \.timeControlStatus).receive(on: DispatchQueue.main).sink { [weak self] status in
            self?.buffering = status == .waitingToPlayAtSpecifiedRate
        }.store(in: &observations)
    }

    var profile: Profile? { stream.pubkey.flatMap { client.getProfile(for: $0) } ?? stream.profile }

    func start() {
        guard !started else { return }
        started = true
        startCount += 1
        previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        #if DEBUG
        if CoveUITestSupport.enabled { loadPlayer(); return }
        #endif
        activity.startListening(for: stream, using: client)
        loadPlayer()
    }

    func retry() { loadPlayer() }

    private func loadPlayer() {
        failed = false
        let source = stream.isLive ? stream.streaming_url : (stream.recording ?? stream.streaming_url)
        let url: URL?
        #if DEBUG
        if CoveUITestSupport.enabled {
            guard let fixture = CoveUITestSupport.playbackFixtureURL else { return }
            url = fixture
        } else { url = StreamPlayback.nativeURL(source) }
        #else
        url = StreamPlayback.nativeURL(source)
        #endif
        guard let url else { failed = true; return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { failed = true; return }
        let item = StreamPlayback.playerItem(for: url)
        itemStatus = item.publisher(for: \.status).receive(on: DispatchQueue.main).sink { [weak self] state in
            self?.failed = state == .failed
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }

    func stop() {
        guard started else { return }
        activity.stopListening()
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemStatus = nil
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimer
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        started = false
    }

    func send(using auth: NostrAuthManager) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending, auth.isAuthenticated else { return }
        #if DEBUG
        if CoveUITestSupport.enabled { return }
        #endif
        sending = true
        sendError = nil
        defer { sending = false }
        do {
            let publisher = LiveActivityManager(nostrSDKClient: client, authManager: auth)
            try await publisher.sendChatMessage(text, to: stream)
            if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
        } catch { sendError = "Message wasn’t sent. Please try again." }
    }
}

/// AVKit supplies touch controls, AirPlay, full screen, and picture-in-picture.
struct PhoneNativePlayer: UIViewControllerRepresentable {
    @ObservedObject var session: PhoneWatchSession
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = session.player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.videoGravity = .resizeAspect
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== session.player { controller.player = session.player }
    }
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        private weak var session: PhoneWatchSession?
        init(session: PhoneWatchSession) { self.session = session }
        func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            Task { @MainActor [weak session] in session?.pictureInPictureActive = true }
        }
        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            Task { @MainActor [weak session] in session?.pictureInPictureActive = false }
        }
        func playerViewController(_ playerViewController: AVPlayerViewController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            completionHandler(session != nil)
        }
    }
}
