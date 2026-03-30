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

    init() {
        self._proxy = .init(wrappedValue: AVMediaPlayerProxy())
    }

    var body: some View {
        ZStack {

            Color.black

            switch manager.state {
            case .playback:
                NativeVideoPlayerView(proxy: proxy, item: manager.playbackItem?.baseItem)
            default:
                ProgressView()
            }
        }
        .onAppear {
            manager.proxy = proxy
            manager.start()
        }
        .preference(key: IsStatusBarHiddenKey.self, value: true)
        .backport
        .onChange(of: presentationCoordinator.isPresented) { _, isPresented in
            guard !isPresented else { return }
            isBeingDismissedByTransition = true
            manager.stop()
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
        let item: BaseItemDto?

        func makeUIViewController(context: Context) -> UINativeVideoPlayerViewController {
            UINativeVideoPlayerViewController(proxy: proxy)
        }

        func updateUIViewController(_ uiViewController: UINativeVideoPlayerViewController, context: Context) {
            #if os(tvOS)
            uiViewController.updateInfoPanel(for: item)
            #endif
        }
    }

    private class UINativeVideoPlayerViewController: AVPlayerViewController {

        private let proxy: AVMediaPlayerProxy
        private var currentItemID: String?

        init(proxy: AVMediaPlayerProxy) {
            self.proxy = proxy

            super.init(nibName: nil, bundle: nil)

            player = proxy.player

            player?.allowsExternalPlayback = true
            #if os(tvOS)
            player?.appliesMediaSelectionCriteriaAutomatically = true
            #else
            player?.appliesMediaSelectionCriteriaAutomatically = false
            #endif
            player?.usesExternalPlaybackWhileExternalScreenIsActive = true
            allowsPictureInPicturePlayback = true

            #if !os(tvOS)
            updatesNowPlayingInfoCenter = false
            #endif
        }

        #if os(tvOS)
        func updateInfoPanel(for item: BaseItemDto?) {
            guard let item, item.id != currentItemID else { return }
            currentItemID = item.id

            let infoVC = UIHostingController(rootView: NativePlayerInfoView(item: item))
            infoVC.title = L10n.info
            customInfoViewControllers = [infoVC]
        }
        #endif

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            player?.pause()
            player?.replaceCurrentItem(with: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}

// MARK: - Info Panel

#if os(tvOS)
private struct NativePlayerInfoView: View {

    let item: BaseItemDto

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(item.displayTitle)
                .font(.title2)
                .fontWeight(.bold)

            DotHStack {
                if item.type == .episode, let seasonEpisodeLocator = item.seasonEpisodeLabel {
                    Text(seasonEpisodeLocator)
                }

                if let runtime = item.runTimeLabel {
                    Text(runtime)
                }

                if let officialRating = item.officialRating {
                    Text(officialRating)
                }
            }
            .foregroundStyle(.secondary)

            if let overview = item.overview {
                Text(overview)
                    .font(.body)
                    .lineLimit(6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(40)
    }
}
#endif
