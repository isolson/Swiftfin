//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVKit
import Factory
import JellyfinAPI
import Logging
import SwiftUI

struct NativeVideoPlayer: View {

    @Environment(\.presentationCoordinator)
    private var presentationCoordinator

    @InjectedObject(\.mediaPlayerManager)
    private var manager: MediaPlayerManager

    @LazyState
    private var proxy: AVMediaPlayerProxy

    @Router
    private var router

    @State
    private var isBeingDismissedByTransition = false
    @State
    private var shouldShowEpisodeCompletionOverlay = false

    init() {
        self._proxy = .init(wrappedValue: AVMediaPlayerProxy())
    }

    private func playNextEpisode() {
        guard let nextItem = manager.queue?.nextItem else { return }
        shouldShowEpisodeCompletionOverlay = false
        proxy.shouldPresentPostPlayActions = false
        manager.playNewItem(provider: nextItem)
    }

    private func returnToEpisodes() {
        shouldShowEpisodeCompletionOverlay = false
        proxy.shouldPresentPostPlayActions = false
        manager.stop()
    }

    var body: some View {
        ZStack {

            Color.black

            switch manager.state {
            case .playback:
                NativeVideoPlayerView(
                    proxy: proxy,
                    showsPlaybackControls: !shouldShowEpisodeCompletionOverlay
                )
            default:
                ProgressView()
            }

            if shouldShowEpisodeCompletionOverlay {
                EpisodeCompletionOverlay(
                    hasNextEpisode: manager.queue?.nextItem != nil,
                    onPlayNext: playNextEpisode,
                    onBackToEpisodes: returnToEpisodes
                )
            }
        }
        .onAppear {
            manager.proxy = proxy
            manager.start()
        }
        .onReceive(proxy.$shouldPresentPostPlayActions) { newValue in
            shouldShowEpisodeCompletionOverlay = newValue && manager.item.type == .episode
        }
        .preference(key: IsStatusBarHiddenKey.self, value: true)
        .backport
        .onChange(of: presentationCoordinator.isPresented) { _, isPresented in
            guard !isPresented else { return }
            isBeingDismissedByTransition = true
            manager.stop()
        }
        .onReceive(manager.$playbackItem) { _ in
            shouldShowEpisodeCompletionOverlay = false
        }
        .onReceive(manager.$state) { newState in
            if newState == .stopped, !isBeingDismissedByTransition {
                router.dismiss()
            }
        }
        .alert(
            L10n.error,
            isPresented: .constant(manager.error != nil)
        ) {
            Button(L10n.close, role: .cancel) {
                Container.shared.mediaPlayerManager.reset()
                router.dismiss()
            }
        } message: {
            // TODO: localize
            Text("Unable to load this item.")
        }
    }
}

extension NativeVideoPlayer {

    private struct NativeVideoPlayerView: UIViewControllerRepresentable {

        let proxy: AVMediaPlayerProxy
        let showsPlaybackControls: Bool

        func makeUIViewController(context: Context) -> UINativeVideoPlayerViewController {
            let controller = UINativeVideoPlayerViewController(proxy: proxy)
            controller.showsPlaybackControls = showsPlaybackControls
            return controller
        }

        func updateUIViewController(_ uiViewController: UINativeVideoPlayerViewController, context: Context) {
            uiViewController.showsPlaybackControls = showsPlaybackControls
        }
    }

    private struct EpisodeCompletionOverlay: View {

        private enum Action: Hashable {
            case next
            case episodes
        }

        let hasNextEpisode: Bool
        let onPlayNext: () -> Void
        let onBackToEpisodes: () -> Void

        @FocusState
        private var focusedAction: Action?

        var body: some View {
            ZStack {
                Color.black.opacity(0.88)
                    .ignoresSafeArea()

                VStack(spacing: 24) {
                    Text(L10n.ended)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)

                    VStack(spacing: 16) {
                        if hasNextEpisode {
                            Button(L10n.playNextItem, action: onPlayNext)
                                .buttonStyle(.borderedProminent)
                                .focused($focusedAction, equals: .next)
                        }

                        Button(L10n.episodes, action: onBackToEpisodes)
                            .buttonStyle(.bordered)
                            .focused($focusedAction, equals: .episodes)
                    }
                }
                .padding(32)
            }
            .onAppear {
                focusedAction = hasNextEpisode ? .next : .episodes
            }
        }
    }

    private class UINativeVideoPlayerViewController: AVPlayerViewController {

        private let proxy: AVMediaPlayerProxy

        init(proxy: AVMediaPlayerProxy) {
            self.proxy = proxy

            super.init(nibName: nil, bundle: nil)

            player = proxy.player

            player?.allowsExternalPlayback = true
            player?.appliesMediaSelectionCriteriaAutomatically = false
            player?.usesExternalPlaybackWhileExternalScreenIsActive = true
            allowsPictureInPicturePlayback = true

            #if !os(tvOS)
            updatesNowPlayingInfoCenter = false
            #endif
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}
