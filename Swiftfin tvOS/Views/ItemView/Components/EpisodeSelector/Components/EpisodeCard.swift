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

    struct EpisodeCard: View {

        @Router
        private var router

        let episode: BaseItemDto

        @FocusState
        private var isFocused: Bool

        // MARK: - Duration Label

        private var durationLabel: String? {
            if let progressLabel = episode.progressLabel {
                return progressLabel
            }
            return episode.runTimeLabel
        }

        // MARK: - Duration Badge Overlay

        @ViewBuilder
        private var durationBadge: some View {
            if let durationLabel {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.5),
                            .init(color: .black.opacity(0.6), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    HStack(spacing: 4) {
                        if episode.progressLabel != nil {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption2)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.caption2)
                        }

                        Text(durationLabel)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                    .padding(10)
                }
            }
        }

        // MARK: - Thumbnail Overlay

        @ViewBuilder
        private var overlayView: some View {
            ZStack {
                if episode.userData?.isPlayed ?? false {
                    ZStack(alignment: .bottomTrailing) {
                        Color.clear

                        Image(systemName: "checkmark.circle.fill")
                            .resizable()
                            .frame(width: 30, height: 30, alignment: .bottomTrailing)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black)
                            .padding()
                    }
                } else if !isFocused {
                    durationBadge
                }

                if isFocused {
                    Color.black.opacity(0.3)

                    Image(systemName: "play.fill")
                        .resizable()
                        .frame(width: 50, height: 50)
                        .foregroundStyle(.white)
                }
            }
        }

        // MARK: - Episode Content

        private var episodeContent: String {
            if episode.isUnaired {
                episode.airDateLabel ?? L10n.noOverviewAvailable
            } else {
                episode.overview ?? L10n.noOverviewAvailable
            }
        }

        private var episodeLabel: String {
            if let indexNumber = episode.indexNumber {
                return L10n.episodeNumber(indexNumber).uppercased()
            }
            return episode.episodeLocator?.uppercased() ?? .emptyDash
        }

        // MARK: - Body

        var body: some View {
            VStack(alignment: .leading) {
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

                        overlayView
                    }
                    .posterStyle(.landscape)
                }
                .buttonStyle(.card)
                .posterShadow()
                .focused($isFocused)

                SeriesEpisodeSelector.EpisodeContent(
                    subHeader: episodeLabel,
                    header: episode.displayTitle,
                    content: episodeContent,
                    airDate: episode.premiereDateLabel,
                    rating: episode.officialRating
                )
                .onSelect {
                    router.route(to: .item(item: episode))
                }
            }
            .focusedValue(\.focusedPoster, AnyPoster(episode))
        }
    }
}
