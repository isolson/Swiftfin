//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import JellyfinAPI
import SwiftUI

private struct NoHighlightButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

private struct FocusedBackground: View {

    @Environment(\.isFocused)
    private var isFocused

    var body: some View {
        if isFocused {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.15))
        }
    }
}

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

        private var metadataLabel: String? {
            let parts = [episode.runTimeLabel, episode.airDateLabel, episode.officialRating]
                .compactMap(\.self)
            return parts.isEmpty ? nil : parts.joined(separator: " • ")
        }

        var body: some View {
            HStack(alignment: .center, spacing: EdgeInsets.edgePadding) {
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
                }
                .buttonStyle(.card)
                .posterShadow()
                .posterStyle(.landscape, contentMode: .fit)
                .frame(width: 300)
                .focused($isFocused)

                Button {
                    router.route(to: .item(item: episode))
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(
                            [episode.seasonEpisodeLabel, episode.displayTitle]
                                .compactMap(\.self)
                                .joined(separator: " - ")
                        )
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                        Text(episodeContent)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)

                        if let metadataLabel {
                            Text(metadataLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets.edgePadding / 2)
                    .background {
                        FocusedBackground()
                    }
                }
                .buttonStyle(NoHighlightButtonStyle())
                .frame(maxWidth: 800, alignment: .leading)

                Spacer()
            }
        }
    }
}
