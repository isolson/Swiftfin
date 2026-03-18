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

    struct EpisodeContent: View {

        private var onSelect: () -> Void

        let subHeader: String
        let header: String
        let content: String
        let airDate: String?
        let rating: String?

        var body: some View {
            Button {
                onSelect()
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(subHeader)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(header)
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(content)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3, reservesSpace: true)

                    HStack(spacing: 8) {
                        if let airDate {
                            Text(airDate)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if let rating {
                            Text(rating)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(.secondary, lineWidth: 1)
                                )
                        }
                    }
                    .frame(minHeight: 20)
                }
                .padding()
            }
            .buttonStyle(.card)
        }
    }
}

extension SeriesEpisodeSelector.EpisodeContent {
    init(
        subHeader: String,
        header: String,
        content: String,
        airDate: String? = nil,
        rating: String? = nil
    ) {
        self.subHeader = subHeader
        self.header = header
        self.content = content
        self.airDate = airDate
        self.rating = rating
        self.onSelect = {}
    }

    func onSelect(perform action: @escaping () -> Void) -> Self {
        copy(modifying: \.onSelect, with: action)
    }
}
