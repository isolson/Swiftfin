//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import JellyfinAPI
import SwiftUI

extension SeriesEpisodeSelector {

    struct EpisodeRowCard: View {

        @Router
        private var router

        let episode: BaseItemDto

        @FocusState
        private var isFocused: Bool

        @ViewBuilder
        private var thumbnailOverlay: some View {
            ZStack {
                if let progressLabel = episode.progressLabel {
                    LandscapePosterProgressBar(
                        title: progressLabel,
                        progress: (episode.userData?.playedPercentage ?? 0) / 100
                    )
                } else if episode.userData?.isPlayed ?? false {
                    ZStack(alignment: .bottomTrailing) {
                        Color.clear

                        Image(systemName: "checkmark.circle.fill")
                            .resizable()
                            .frame(width: 30, height: 30, alignment: .bottomTrailing)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black)
                            .padding()
                    }
                }

                if isFocused {
                    Image(systemName: "play.fill")
                        .resizable()
                        .frame(width: 40, height: 40)
                        .foregroundStyle(.secondary)
                }
            }
        }

        private var episodeContent: String {
            if episode.isUnaired {
                episode.airDateLabel ?? L10n.noOverviewAvailable
            } else {
                episode.overview ?? L10n.noOverviewAvailable
            }
        }

        var body: some View {
            HStack(alignment: .top, spacing: EdgeInsets.edgePadding) {
                Button {
                    router.route(
                        to: .videoPlayer(
                            item: episode,
                            queue: EpisodeMediaPlayerQueue(episode: episode)
                        )
                    )
                } label: {
                    ZStack {
                        Color.clear

                        ImageView(episode.imageSource(.primary, maxWidth: 500))
                            .failure {
                                SystemImageContentView(systemName: episode.systemImage)
                            }

                        thumbnailOverlay
                    }
                    .posterStyle(.landscape)
                }
                .buttonStyle(.card)
                .posterShadow()
                .frame(width: 300)
                .focused($isFocused)

                SeriesEpisodeSelector.EpisodeContent(
                    subHeader: episode.episodeLocator ?? .emptyDash,
                    header: episode.displayTitle,
                    content: episodeContent
                )
                .onSelect {
                    router.route(to: .item(item: episode))
                }
            }
        }
    }
}
