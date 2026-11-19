//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVKit
import Defaults
import JellyfinAPI
import SwiftUI

/// Chooses between the native system player and Swiftfin's custom player once per presentation.
struct TVVideoPlayerRoute: View {

    let mediaSession: MediaSession

    @State
    private var usesNativeInterface: Bool

    init(mediaSession: MediaSession) {
        self.mediaSession = mediaSession
        self._usesNativeInterface = State(initialValue: NativeVideoPlayer.canPresent(mediaSession))
    }

    @ContentBuilder
    var body: some View {
        if usesNativeInterface {
            NativeVideoPlayer(mediaSession: mediaSession)
        } else {
            VideoPlayer(mediaSession: mediaSession)
        }
    }
}

/// Plays a `MediaSession` with the system `AVPlayerViewController`, so playback looks and behaves
/// like the built-in Apple TV apps: system transport bar, info panel, scrubbing, chapters,
/// contextual "Skip" buttons, and Audio/Subtitle menus backed by Jellyfin's tracks.
struct NativeVideoPlayer: View {

    @Router
    private var router

    let mediaSession: MediaSession

    /// The native interface needs the AVPlayer engine. Sessions already bound to another engine use `VideoPlayer`.
    @MainActor
    static func canPresent(_ mediaSession: MediaSession) -> Bool {
        guard Defaults[.VideoPlayer.nativeInterface] else { return false }

        if let player = mediaSession.player {
            return player is AVMediaPlayer
        }

        return Defaults[.VideoPlayer.mediaPlayerType] == .avPlayer
    }

    @ContentBuilder
    var body: some View {
        Representable(mediaSession: mediaSession)
            .ignoresSafeArea()
            .onChange(of: mediaSession.state, initial: true) { _, newState in
                if newState == .stopped {
                    router.dismiss()
                }
            }
            .alert(
                L10n.error,
                isPresented: .constant(mediaSession.state == .error)
            ) {
                Button(L10n.retry) { mediaSession.retry() }

                Button(L10n.close, role: .cancel) {
                    mediaSession.stop()
                    router.dismiss()
                }
            } message: {
                Text(L10n.unableToLoadThisItem)
            }
            .colorScheme(.dark)
            .persistentSystemOverlays(.hidden)
            .toolbar(.hidden, for: .navigationBar)
    }

    private struct Representable: UIViewControllerRepresentable {

        let mediaSession: MediaSession

        func makeUIViewController(context: Context) -> NativePlayerContainerController {
            NativePlayerContainerController(mediaSession: mediaSession)
        }

        func updateUIViewController(_ uiViewController: NativePlayerContainerController, context: Context) {}

        static func dismantleUIViewController(_ uiViewController: NativePlayerContainerController, coordinator: ()) {
            uiViewController.invalidate()
        }
    }
}

// MARK: - NativePlayerContainerController

/// Hosts an unmodified `AVPlayerViewController` (Apple does not support subclassing it)
/// and bridges it to the `MediaSession`.
@MainActor
final class NativePlayerContainerController: UIViewController, AVPlayerViewControllerDelegate {

    private let mediaSession: MediaSession
    private var engine: AVMediaPlayer?
    private let playerViewController = AVPlayerViewController()

    private let activityIndicator = UIActivityIndicatorView(style: .large)
    private var refreshTimer: Timer?
    private var speedObservation: NSKeyValueObservation?
    private var isDismissing = false

    private var menuSignature: MenuSignature?
    private var contextualActionIDs: [String] = []
    private weak var markedPlayerItem: AVPlayerItem?
    private var markerTask: Task<Void, Never>?

    init(mediaSession: MediaSession) {
        self.mediaSession = mediaSession
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black

        let engine: AVMediaPlayer

        if let attached = mediaSession.player as? AVMediaPlayer {
            engine = attached
        } else {
            engine = AVMediaPlayer()

            if mediaSession.player == nil, mediaSession.state != .stopped {
                mediaSession.attach(player: engine)
            }
        }

        self.engine = engine
        engine.forwardsPlaybackRequests = true

        let controller = playerViewController
        controller.delegate = self
        controller.player = engine.player

        // The engine applies the display criteria itself so that it can track mode switches.
        controller.appliesPreferredDisplayCriteriaAutomatically = false
        controller.allowsPictureInPicturePlayback = false
        controller.transportBarIncludesTitleView = true
        controller.playbackControlsIncludeInfoViews = true
        controller.playbackControlsIncludeTransportBar = true
        // Jellyfin's subtitle menu replaces the system one so that every server track can be chosen,
        // including tracks that require the server to produce a new stream.
        controller.allowedSubtitleOptionLanguages = []

        configureSpeeds()

        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controller.view)
        controller.didMove(toParent: self)

        if mediaSession.queue != nil, mediaSession.item.type == .episode {
            let episodes = UIHostingController(rootView: NativeEpisodesInfoView(mediaSession: mediaSession))
            episodes.title = L10n.episodes
            episodes.preferredContentSize = CGSize(width: 1920, height: 420)
            episodes.view.backgroundColor = .clear
            controller.customInfoViewControllers = [episodes]
        }

        activityIndicator.color = .white
        activityIndicator.hidesWhenStopped = true
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(activityIndicator)

        NSLayoutConstraint.activate([
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        refresh()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [playerViewController]
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        isDismissing = false

        if let window = view.window {
            engine?.videoSurfaceDidMove(to: window)
        }

        startRefreshing()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        // Only a real dismissal ends playback; being covered by another presentation does not.
        isDismissing = false
        var ancestor: UIViewController? = self

        while let controller = ancestor {
            if controller.isBeingDismissed || controller.isMovingFromParent {
                isDismissing = true
                break
            }

            ancestor = controller.parent
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        refreshTimer?.invalidate()
        refreshTimer = nil

        if isDismissing {
            mediaSession.stop()
        }
    }

    func invalidate() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        markerTask?.cancel()
        markerTask = nil
        speedObservation = nil

        // Another native controller may already be driving this engine.
        if mediaSession.state == .stopped || mediaSession.player !== engine {
            engine?.forwardsPlaybackRequests = false
        }

        playerViewController.player = nil
    }

    private func startRefreshing() {
        guard refreshTimer == nil else { return }

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    // MARK: - Speed

    private func configureSpeeds() {
        var speeds = AVPlaybackSpeed.systemDefaultSpeeds
        let rate = Float(mediaSession.effectiveRate)

        if !speeds.contains(where: { abs($0.rate - rate) < 0.01 }) {
            speeds.append(AVPlaybackSpeed(rate: rate, localizedName: "\(rate.formatted())×"))
            speeds.sort { $0.rate < $1.rate }
        }

        playerViewController.speeds = speeds

        if let speed = speeds.first(where: { abs($0.rate - rate) < 0.01 }) {
            playerViewController.selectSpeed(speed)
        }

        let session = mediaSession

        speedObservation = playerViewController.observe(\.selectedSpeed, options: [.new]) { [weak session] controller, _ in
            MainActor.assumeIsolated {
                guard let session,
                      let rate = controller.selectedSpeed?.rate,
                      abs(Double(rate) - session.rate) > 0.001 else { return }

                session.rate = Double(rate)
            }
        }
    }

    private func syncSelectedSpeed() {
        let rate = Float(mediaSession.effectiveRate)

        guard let selected = playerViewController.selectedSpeed, abs(selected.rate - rate) > 0.01 else { return }

        if let speed = playerViewController.speeds.first(where: { abs($0.rate - rate) < 0.01 }) {
            playerViewController.selectSpeed(speed)
        }
    }

    // MARK: - State

    private func refresh() {
        updateActivityIndicator()
        updateMenus()
        updateContextualActions()
        updateNavigationMarkers()
        syncSelectedSpeed()
    }

    private func updateActivityIndicator() {
        let isLoading: Bool = switch mediaSession.activity {
        case .loading, .switchingDisplay:
            true
        default:
            mediaSession.state != .error && mediaSession.state != .stopped && engine?.player.currentItem == nil
        }

        if isLoading {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
    }

    // MARK: - Transport bar menus

    private struct MenuSignature: Equatable {

        let playSessionID: String?
        let canControl: Bool
        let audio: [Int]
        let selectedAudio: Int?
        let subtitles: [Int]
        let selectedSubtitle: Int
        let bitrate: PlaybackBitrate?
        let resolution: PlaybackResolution?
        let source: String?
    }

    private func currentMenuSignature() -> MenuSignature {
        let item = mediaSession.playbackItem

        return MenuSignature(
            playSessionID: item?.playSessionID,
            canControl: mediaSession.canControlPlayback,
            audio: item?.audioStreams.compactMap(\.index) ?? [],
            selectedAudio: item?.selectedAudioStreamIndex,
            subtitles: item?.subtitleStreams.compactMap(\.index) ?? [],
            selectedSubtitle: item.map(Self.selectedSubtitleIndex) ?? -1,
            bitrate: item?.configuration.requestedBitrate,
            resolution: item?.configuration.maxResolution,
            source: item?.mediaSource.id
        )
    }

    private static func selectedSubtitleIndex(_ item: MediaPlayerItem) -> Int {
        item.subtitlesEnabled ? item.subtitleTrackIndex(secondary: false) : -1
    }

    private func updateMenus() {
        let signature = currentMenuSignature()
        guard signature != menuSignature else { return }

        menuSignature = signature

        guard let item = mediaSession.playbackItem, signature.canControl else {
            playerViewController.transportBarCustomMenuItems = []
            return
        }

        playerViewController.transportBarCustomMenuItems = [
            subtitleMenu(for: item),
            audioMenu(for: item),
            qualityMenu(for: item),
        ]
            .compactMap(\.self)
    }

    private func subtitleMenu(for item: MediaPlayerItem) -> UIMenu? {
        let streams = item.subtitleStreams.filter { ($0.index ?? -1) >= 0 }
        guard streams.isNotEmpty else { return nil }

        let selected = Self.selectedSubtitleIndex(item)

        let off = UIAction(title: L10n.off, state: selected < 0 ? .on : .off) { [weak item] _ in
            item?.setSubtitlesEnabled(false)
        }

        let tracks = streams.map { stream in
            let index = stream.index ?? -1

            return UIAction(
                title: stream.displayTitle ?? L10n.unknown,
                subtitle: Self.subtitleDetail(for: stream),
                state: index == selected ? .on : .off
            ) { [weak item] _ in
                guard let item else { return }

                item.setSubtitleTrack(index: index, secondary: false)

                if !item.subtitlesEnabled {
                    item.setSubtitlesEnabled(true)
                }
            }
        }

        return UIMenu(
            title: L10n.subtitles,
            image: UIImage(systemName: selected >= 0 ? "captions.bubble.fill" : "captions.bubble"),
            options: [.singleSelection],
            children: [off] + tracks
        )
    }

    private static func subtitleDetail(for stream: MediaStream) -> String? {
        var details: [String] = []

        if stream.isForced == true {
            details.append(L10n.forced)
        }

        if stream.isExternal == true {
            details.append(L10n.external)
        }

        if let codec = stream.codec?.uppercased(), codec.isNotEmpty {
            details.append(codec)
        }

        return details.isEmpty ? nil : details.joined(separator: " · ")
    }

    private func audioMenu(for item: MediaPlayerItem) -> UIMenu? {
        let streams = item.audioStreams.filter { ($0.index ?? -1) >= 0 }
        guard streams.count > 1 else { return nil }

        let selected = item.selectedAudioStreamIndex

        let tracks = streams.map { stream in
            let index = stream.index ?? -1

            return UIAction(
                title: stream.displayTitle ?? L10n.unknown,
                state: index == selected ? .on : .off
            ) { [weak item] _ in
                guard let item, item.selectedAudioStreamIndex != index else { return }

                item.selectedAudioStreamIndex = index
            }
        }

        return UIMenu(
            title: L10n.audio,
            image: UIImage(systemName: "waveform"),
            options: [.singleSelection],
            children: tracks
        )
    }

    private func qualityMenu(for item: MediaPlayerItem) -> UIMenu? {
        var sections: [UIMenuElement] = []

        let versions = item.baseItem.mediaSources ?? []

        if versions.count > 1 {
            let actions = versions.map { version in
                UIAction(
                    title: version.displayTitle,
                    state: version.id == item.mediaSource.id ? .on : .off
                ) { [weak self, weak item] _ in
                    guard let self, let item, version.id != item.mediaSource.id else { return }

                    var intent = item.resumingIntent(at: mediaSession.seconds)
                    intent.configuration.selectMediaSource(id: version.id)
                    mediaSession.playNewItem(intent: intent)
                }
            }

            sections.append(UIMenu(title: L10n.version, options: [.singleSelection], children: actions))
        }

        let bitrates = item.mediaSource.supportedBitrates

        if bitrates.isNotEmpty {
            let actions = bitrates.map { bitrate in
                UIAction(
                    title: bitrate.displayTitle,
                    state: bitrate == item.configuration.requestedBitrate ? .on : .off
                ) { [weak self] _ in
                    guard let self, bitrate != mediaSession.playbackItem?.configuration.requestedBitrate else { return }

                    mediaSession.setBitrate(bitrate: bitrate)
                }
            }

            sections.append(UIMenu(title: L10n.playbackQuality, options: [.singleSelection], children: actions))
        }

        if item.baseItem.mediaType == .video {
            let actions = PlaybackResolution.allCases.map { resolution in
                UIAction(
                    title: resolution.displayTitle,
                    state: resolution == item.configuration.maxResolution ? .on : .off
                ) { [weak self] _ in
                    guard let self, resolution != mediaSession.playbackItem?.configuration.maxResolution else { return }

                    mediaSession.setResolution(resolution: resolution)
                }
            }

            sections.append(UIMenu(title: L10n.resolution, options: [.singleSelection], children: actions))
        }

        guard sections.isNotEmpty else { return nil }

        return UIMenu(
            title: L10n.playbackQuality,
            image: UIImage(systemName: "gearshape"),
            children: sections
        )
    }

    // MARK: - Contextual actions

    private static let nextItemLeadTime: Duration = .seconds(30)

    private func updateContextualActions() {
        var actions: [(id: String, action: UIAction)] = []

        if let skip = skipSegmentAction() {
            actions.append(skip)
        }

        if let next = nextItemAction() {
            actions.append(next)
        }

        let ids = actions.map(\.id)
        guard ids != contextualActionIDs else { return }

        contextualActionIDs = ids
        playerViewController.contextualActions = actions.map(\.action)
    }

    private func skipSegmentAction() -> (id: String, action: UIAction)? {
        guard let item = mediaSession.playbackItem,
              let observer = item.segments,
              mediaSession.state == .playback,
              mediaSession.canSeek,
              !mediaSession.isSeeking else { return nil }

        let position = mediaSession.seconds
        let duration = mediaSession.playbackState.duration ?? mediaSession.item.runtime

        guard let segment = observer.segments.first(where: { $0.skipTarget(at: position, duration: duration) != nil }) else { return nil }

        // Credits roll into the next item instead when one is queued.
        if segment.type == .outro, mediaSession.queue?.nextItem != nil {
            return nil
        }

        let title = segment.type == .intro ? L10n.skipIntro : L10n.skipCredits

        let action = UIAction(title: title, image: UIImage(systemName: "forward.end.fill")) { [weak self] _ in
            guard let self,
                  mediaSession.state == .playback,
                  mediaSession.canSeek,
                  let target = segment.skipTarget(
                      at: mediaSession.seconds,
                      duration: mediaSession.playbackState.duration ?? mediaSession.item.runtime
                  ) else { return }

            mediaSession.seek(to: target)
        }

        return ("segment:\(segment.id)", action)
    }

    private func nextItemAction() -> (id: String, action: UIAction)? {
        guard let next = mediaSession.queue?.nextItem,
              mediaSession.state == .playback,
              let duration = mediaSession.playbackState.duration ?? mediaSession.item.runtime,
              duration > .zero else { return nil }

        let position = mediaSession.seconds
        let isInCredits = mediaSession.playbackItem?.segments?.segments.contains {
            $0.type == .outro && position >= $0.start && position < $0.end
        } == true

        guard isInCredits || duration - position <= Self.nextItemLeadTime else { return nil }

        let title = next.item.type == .episode ? L10n.nextEpisode : L10n.nextItem

        let action = UIAction(title: title, image: UIImage(systemName: "forward.fill")) { [weak self] _ in
            guard let self, mediaSession.state != .stopped else { return }

            mediaSession.playNewItem(intent: next)
        }

        return ("next:\(next.item.id ?? "")", action)
    }

    // MARK: - Chapters

    private func updateNavigationMarkers() {
        guard let playerItem = engine?.player.currentItem,
              playerItem !== markedPlayerItem,
              let item = mediaSession.playbackItem,
              item.url == (playerItem.asset as? AVURLAsset)?.url else { return }

        markedPlayerItem = playerItem
        markerTask?.cancel()

        // Drop duplicate start times so every marker has a non-empty range.
        var seen: Set<Duration> = []
        let chapters = item.chapters
            .sorted { $0.startSeconds < $1.startSeconds }
            .filter { seen.insert($0.startSeconds).inserted }

        guard chapters.count > 1 else {
            playerItem.navigationMarkerGroups = []
            return
        }

        let runtime = item.baseItem.runtime

        playerItem.navigationMarkerGroups = [Self.markerGroup(for: chapters, runtime: runtime, artwork: [:])]

        let imageURLs = chapters.enumerated().compactMap { offset, chapter in
            chapter.imageSource?.url.map { (offset, $0) }
        }

        guard imageURLs.isNotEmpty else { return }

        markerTask = Task { [weak self, weak playerItem] in
            var artwork: [Int: Data] = [:]

            await withTaskGroup(of: (Int, Data?).self) { group in
                for (offset, url) in imageURLs {
                    group.addTask {
                        guard let (data, response) = try? await URLSession.shared.data(from: url),
                              (response as? HTTPURLResponse)?.statusCode == 200,
                              UIImage(data: data) != nil else { return (offset, nil) }

                        return (offset, data)
                    }
                }

                for await (offset, data) in group {
                    if let data {
                        artwork[offset] = data
                    }
                }
            }

            guard !Task.isCancelled, artwork.isNotEmpty, let self, let playerItem, playerItem === markedPlayerItem else { return }

            playerItem.navigationMarkerGroups = [Self.markerGroup(for: chapters, runtime: runtime, artwork: artwork)]
        }
    }

    private static func markerGroup(
        for chapters: [ChapterInfo.FullInfo],
        runtime: Duration?,
        artwork: [Int: Data]
    ) -> AVNavigationMarkersGroup {
        let markers = chapters.enumerated().map { offset, chapter in
            let start = chapter.startSeconds
            var end = chapters[safe: offset + 1]?.startSeconds ?? runtime ?? start + .seconds(1)

            if end <= start {
                end = start + .seconds(1)
            }

            var metadata: [AVMetadataItem] = []

            let title = AVMutableMetadataItem()
            title.identifier = .commonIdentifierTitle
            title.value = chapter.displayTitle as NSString
            title.extendedLanguageTag = "und"
            metadata.append(title)

            if let data = artwork[offset], let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.8) {
                let artworkItem = AVMutableMetadataItem()
                artworkItem.identifier = .commonIdentifierArtwork
                artworkItem.value = jpeg as NSData
                artworkItem.dataType = kCMMetadataBaseDataType_JPEG as String
                artworkItem.extendedLanguageTag = "und"
                metadata.append(artworkItem)
            }

            let timeRange = CMTimeRange(
                start: CMTime(seconds: start.seconds, preferredTimescale: 600),
                end: CMTime(seconds: end.seconds, preferredTimescale: 600)
            )

            return AVTimedMetadataGroup(items: metadata, timeRange: timeRange)
        }

        return AVNavigationMarkersGroup(title: nil, timedNavigationMarkers: markers)
    }

    // MARK: - AVPlayerViewControllerDelegate

    nonisolated func playerViewController(
        _ playerViewController: AVPlayerViewController,
        didSelect mediaSelectionOption: AVMediaSelectionOption?,
        in mediaSelectionGroup: AVMediaSelectionGroup
    ) {
        MainActor.assumeIsolated {
            syncSystemSelection(mediaSelectionOption, in: mediaSelectionGroup)
        }
    }

    /// Keeps Jellyfin's track configuration in sync when a system menu changes the selection.
    private func syncSystemSelection(_ option: AVMediaSelectionOption?, in group: AVMediaSelectionGroup) {
        guard let item = mediaSession.playbackItem, item.canSelectTracks else { return }

        let isAudio = group.options.contains { $0.hasMediaCharacteristic(.audible) }
        let streams = isAudio ? item.audioStreams : item.subtitleStreams

        guard let option else {
            if !isAudio, item.subtitlesEnabled {
                item.setSubtitlesEnabled(false)
            }
            return
        }
        guard let playerIndex = group.options.firstIndex(of: option),
              let stream = streams.first(where: { item.indexMap.playerIndex(for: $0.index) == playerIndex }),
              let index = stream.index else { return }

        if isAudio {
            if item.selectedAudioStreamIndex != index {
                item.selectedAudioStreamIndex = index
            }
        } else if Self.selectedSubtitleIndex(item) != index {
            item.setSubtitleTrack(index: index, secondary: false)

            if !item.subtitlesEnabled {
                item.setSubtitlesEnabled(true)
            }
        }
    }

    nonisolated func playerViewController(
        _ playerViewController: AVPlayerViewController,
        willResumePlaybackAfterUserNavigatedFrom oldTime: CMTime,
        to targetTime: CMTime
    ) {
        MainActor.assumeIsolated {
            guard let engine, targetTime.isNumeric else { return }

            // Keep the session timeline current after native scrubbing instead of waiting for the next tick.
            mediaSession.playerDidUpdatePosition(.seconds(targetTime.seconds), from: engine)
        }
    }
}
