//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVFoundation
import AVKit
import Combine
import Defaults
import Foundation
import JellyfinAPI
import SwiftUI

// TODO: report playback information, see VLCUI.PlaybackInformation (dropped frames, etc.)
// TODO: have set seconds with completion handler

@MainActor
class AVMediaPlayerProxy: VideoMediaPlayerProxy {

    let isBuffering: PublishedBox<Bool> = .init(initialValue: false)
    var isScrubbing: Binding<Bool> = .constant(false)
    var scrubbedSeconds: Binding<Duration> = .constant(.zero)
    var videoSize: PublishedBox<CGSize> = .init(initialValue: .zero)

    let avPlayerLayer: AVPlayerLayer
    let player: AVPlayer

//    private var rateObserver: NSKeyValueObservation!
    private var statusObserver: NSKeyValueObservation!
    private var timeControlStatusObserver: NSKeyValueObservation!
    private var timeObserver: Any!
    private var endOfPlaybackObserver: NSObjectProtocol?
    private var loadingTimeoutTask: Task<Void, Never>?
    private var managerItemObserver: AnyCancellable?
    private var managerStateObserver: AnyCancellable?

    weak var manager: MediaPlayerManager? {
        didSet {
            for var o in observers {
                o.manager = manager
            }

            if let manager {
                managerItemObserver = manager.$playbackItem
                    .sink { playbackItem in
                        if let playbackItem {
                            self.playNew(item: playbackItem)
                        }
                    }

                managerStateObserver = manager.$state
                    .sink { state in
                        switch state {
                        case .stopped:
                            self.playbackStopped()
                        default: break
                        }
                    }
            } else {
                managerItemObserver?.cancel()
                managerStateObserver?.cancel()
            }
        }
    }

    var observers: [any MediaPlayerObserver] = [
        NowPlayableObserver(),
    ]

    init() {
        self.player = AVPlayer()
        self.avPlayerLayer = AVPlayerLayer(player: player)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 1000),
            queue: .main
        ) { newTime in
            let newSeconds = Duration.seconds(newTime.seconds)

            if !self.isScrubbing.wrappedValue {
                self.scrubbedSeconds.wrappedValue = newSeconds
            }

            self.manager?.seconds = newSeconds
        }
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func stop() {
        player.pause()
    }

    func jumpForward(_ seconds: Duration) {
        let currentTime = player.currentTime()
        let newTime = currentTime + CMTime(seconds: seconds.seconds, preferredTimescale: 1)
        player.seek(to: newTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func jumpBackward(_ seconds: Duration) {
        let currentTime = player.currentTime()
        let newTime = max(.zero, currentTime - CMTime(seconds: seconds.seconds, preferredTimescale: 1))
        player.seek(to: newTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setSeconds(_ seconds: Duration) {
        let time = CMTime(seconds: seconds.seconds, preferredTimescale: 1)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setRate(_ rate: Float) {
        player.rate = rate
    }

    func setAudioStream(_ stream: MediaStream) {
        guard let currentItem = player.currentItem else { return }

        Task {
            guard let group = try? await currentItem.asset.loadMediaSelectionGroup(for: .audible) else { return }
            let options = group.options

            if let languageCode = stream.language,
               let match = options
                   .first(where: { $0.extendedLanguageTag == languageCode || $0.locale?.language.languageCode?.identifier == languageCode })
            {
                currentItem.select(match, in: group)
            } else if let index = stream.index, index >= 0, index < options.count {
                currentItem.select(options[index], in: group)
            }
        }
    }

    func setSubtitleStream(_ stream: MediaStream) {
        guard let currentItem = player.currentItem else { return }

        Task {
            guard let group = try? await currentItem.asset.loadMediaSelectionGroup(for: .legible) else { return }

            // nil or -1 index means disable subtitles
            guard let index = stream.index, index >= 0 else {
                currentItem.select(nil, in: group)
                return
            }

            let options = group.options

            if let languageCode = stream.language,
               let match = options
                   .first(where: { $0.extendedLanguageTag == languageCode || $0.locale?.language.languageCode?.identifier == languageCode })
            {
                currentItem.select(match, in: group)
            } else if index < options.count {
                currentItem.select(options[index], in: group)
            }
        }
    }

    func setAspectFill(_ aspectFill: Bool) {
        avPlayerLayer.videoGravity = aspectFill ? .resizeAspectFill : .resizeAspect
    }

    var videoPlayerBody: some View {
        AVPlayerView()
            .environmentObject(self)
    }
}

extension AVMediaPlayerProxy {

    private func playbackStopped() {
        loadingTimeoutTask?.cancel()
        player.pause()

        if let timeObserver {
            DispatchQueue.main.async {
                self.player.removeTimeObserver(timeObserver)
                self.timeObserver = nil
            }
        }

        if let endOfPlaybackObserver {
            NotificationCenter.default.removeObserver(endOfPlaybackObserver)
            self.endOfPlaybackObserver = nil
        }

        if let statusObserver {
            statusObserver.invalidate()
            self.statusObserver = nil
        }

        if let timeControlStatusObserver {
            timeControlStatusObserver.invalidate()
            self.timeControlStatusObserver = nil
        }
    }

    private func playNew(item: MediaPlayerItem) {
        let baseItem = item.baseItem

        if let endOfPlaybackObserver {
            NotificationCenter.default.removeObserver(endOfPlaybackObserver)
        }

        let newAVPlayerItem = AVPlayerItem(url: item.url)
        newAVPlayerItem.externalMetadata = item.baseItem.avMetadata
        newAVPlayerItem.navigationMarkerGroups = Self.navigationMarkerGroups(for: item.baseItem)

        player.replaceCurrentItem(with: newAVPlayerItem)

        endOfPlaybackObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: newAVPlayerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                if let duration = self?.player.currentItem?.duration, duration.isNumeric {
                    self?.manager?.seconds = Duration.seconds(duration.seconds)
                }
                self?.manager?.ended()
            }
        }

        // TODO: protect against paused
//        rateObserver = player.observe(\.rate, options: [.new, .initial]) { _, value in
//            DispatchQueue.main.async {
//                self.manager?.set(rate: value.newValue ?? 1.0)
//            }
//        }

        timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.new]) { player, _ in
            let timeControlStatus = player.timeControlStatus

            DispatchQueue.main.async {
                switch timeControlStatus {
                case .paused:
                    self.manager?.setPlaybackRequestStatus(status: .paused)
                case .waitingToPlayAtSpecifiedRate: ()
                // TODO: buffering
                case .playing:
                    self.manager?.setPlaybackRequestStatus(status: .playing)
                @unknown default: ()
                }
            }
        }

        loadingTimeoutTask?.cancel()
        loadingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.manager?.error(ErrorMessage("Playback timed out while loading"))
        }

        statusObserver = player.observe(\.currentItem?.status, options: [.new]) { _, value in
            guard let newValue = value.newValue else { return }
            switch newValue {
            case .failed:
                self.loadingTimeoutTask?.cancel()
                if let error = self.player.error {
                    DispatchQueue.main.async {
                        self.manager?.error(ErrorMessage("AVPlayer error: \(error.localizedDescription)"))
                    }
                }
            case .readyToPlay:
                self.loadingTimeoutTask?.cancel()
                let resumeSeconds = max(.zero, (baseItem.startSeconds ?? .zero) - Duration.seconds(Defaults[.VideoPlayer.resumeOffset]))
                let runtime = baseItem.runtime ?? .zero
                let startSeconds = runtime > .zero ? min(resumeSeconds, runtime - .seconds(1)) : resumeSeconds

                self.player.seek(
                    to: CMTimeMake(
                        value: startSeconds.components.seconds,
                        timescale: 1
                    ),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero,
                    completionHandler: { _ in
                        self.play()
                    }
                )
            case .none, .unknown:
                break
            @unknown default: ()
            }
        }
    }
}

// MARK: - Chapter Navigation Markers

extension AVMediaPlayerProxy {

    static func navigationMarkerGroups(for item: BaseItemDto) -> [AVNavigationMarkersGroup] {
        guard let chapters = item.fullChapterInfo, chapters.isNotEmpty else { return [] }

        let timedGroups: [AVTimedMetadataGroup] = chapters.map { chapter in
            let chapterInfo = chapter.chapterInfo
            let startTicks = chapterInfo.startPositionTicks ?? 0
            let startTime = CMTime(seconds: Double(startTicks) / 10_000_000, preferredTimescale: 1000)

            let titleItem = AVMutableMetadataItem()
            titleItem.identifier = .commonIdentifierTitle
            titleItem.value = chapterInfo.displayTitle as NSString
            titleItem.extendedLanguageTag = "und"

            return AVTimedMetadataGroup(
                items: [titleItem],
                timeRange: CMTimeRange(start: startTime, duration: .indefinite)
            )
        }

        return [AVNavigationMarkersGroup(title: nil, timedNavigationMarkers: timedGroups)]
    }
}

// MARK: - AVPlayerView

extension AVMediaPlayerProxy {

    struct AVPlayerView: UIViewRepresentable {

        @EnvironmentObject
        private var proxy: AVMediaPlayerProxy
        @EnvironmentObject
        private var scrubbedSeconds: PublishedBox<Duration>

        func makeUIView(context: Context) -> UIView {
//            proxy.isScrubbing = context.environment.isScrubbing
//            proxy.scrubbedSeconds = $scrubbedSeconds.value
            UIAVPlayerView(proxy: proxy)
        }

        func updateUIView(_ uiView: UIView, context: Context) {}
    }

    private class UIAVPlayerView: UIView {

        let proxy: AVMediaPlayerProxy

        init(proxy: AVMediaPlayerProxy) {
            self.proxy = proxy
            super.init(frame: .zero)
            layer.addSublayer(proxy.avPlayerLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            proxy.avPlayerLayer.frame = bounds
        }
    }
}
