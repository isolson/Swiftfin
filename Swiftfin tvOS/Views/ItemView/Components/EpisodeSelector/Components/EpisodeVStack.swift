//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI
import SwiftUI

extension SeriesEpisodeSelector {

    struct EpisodeVStack: View {

        @EnvironmentObject
        private var focusGuide: FocusGuide

        @FocusState
        private var focusedEpisodeID: String?

        @ObservedObject
        var viewModel: SeasonItemViewModel

        @State
        private var didScrollToPlayButtonItem = false
        @State
        private var lastFocusedEpisodeID: String?

        let playButtonItem: BaseItemDto?

        // MARK: - Content View

        private func contentView(viewModel: SeasonItemViewModel) -> some View {
            ScrollViewReader { proxy in
                VStack(spacing: EdgeInsets.edgePadding / 2) {
                    ForEach(viewModel.elements, id: \.id) { episode in
                        SeriesEpisodeSelector.EpisodeRowCard(episode: episode)
                            .id(episode.id)
                            .focused($focusedEpisodeID, equals: episode.id)
                    }
                }
                .padding(.horizontal, EdgeInsets.edgePadding)
                .onFirstAppear {
                    guard !didScrollToPlayButtonItem else { return }
                    didScrollToPlayButtonItem = true

                    lastFocusedEpisodeID = playButtonItem?.id

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        guard let playButtonItem else { return }
                        proxy.scrollTo(playButtonItem.id, anchor: .top)
                    }
                }
            }
        }

        // MARK: - Determine Which Episode should be Focused

        private func getContentFocus() {
            switch viewModel.state {
            case .content:
                if viewModel.elements.isEmpty {
                    /// Focus the EmptyCard if the Season has no elements
                    focusedEpisodeID = "emptyCard"
                } else {
                    if let lastFocusedEpisodeID,
                       viewModel.elements.contains(where: { $0.id == lastFocusedEpisodeID })
                    {
                        /// Return focus to the Last Focused Episode if it exists in the current Season
                        focusedEpisodeID = lastFocusedEpisodeID
                    } else {
                        /// Focus the First Episode in the season as a last resort
                        focusedEpisodeID = viewModel.elements.first?.id
                    }
                }
            case .error:
                /// Focus the ErrorCard if the Season failed to load
                focusedEpisodeID = "errorCard"
            case .initial, .refreshing:
                /// Focus the LoadingCard if the Season is currently loading
                focusedEpisodeID = "loadingCard"
            }
        }

        // MARK: - Body

        var body: some View {
            ZStack {
                PlaceholderContent()

                Group {
                    switch viewModel.state {
                    case .content:
                        if viewModel.elements.isEmpty {
                            EmptyContent(focusedEpisodeID: $focusedEpisodeID)
                        } else {
                            contentView(viewModel: viewModel)
                        }
                    case let .error(error):
                        ErrorContent(viewModel: viewModel, error: error, focusedEpisodeID: $focusedEpisodeID)
                    case .initial, .refreshing:
                        LoadingContent(focusedEpisodeID: $focusedEpisodeID)
                    }
                }.transition(.opacity.animation(.linear(duration: 0.1)))
            }
            .padding(.bottom, 45)
            .focusSection()
            .focusGuide(
                focusGuide,
                tag: "episodes",
                onContentFocus: {
                    getContentFocus()
                },
                top: "belowHeader"
            )
            .onChange(of: viewModel.id) {
                lastFocusedEpisodeID = viewModel.elements.first?.id
            }
            .onChange(of: focusedEpisodeID) { _, newValue in
                guard let newValue else { return }
                lastFocusedEpisodeID = newValue
            }
            .onChange(of: viewModel.state) { _, newValue in
                if newValue == .content {
                    lastFocusedEpisodeID = viewModel.elements.first?.id
                }
            }
        }
    }
}

// MARK: - State Sub-Views

extension SeriesEpisodeSelector.EpisodeVStack {

    // MARK: - Empty Content

    struct EmptyContent: View {

        let focusedEpisodeID: FocusState<String?>.Binding

        var body: some View {
            HStack {
                SeriesEpisodeSelector.EmptyCard()
                    .focused(focusedEpisodeID, equals: "emptyCard")
                    .frame(maxWidth: 400)

                Spacer()
            }
            .padding(.horizontal, EdgeInsets.edgePadding)
        }
    }

    // MARK: - Error Content

    struct ErrorContent: View {

        @ObservedObject
        var viewModel: SeasonItemViewModel

        let error: ErrorMessage
        let focusedEpisodeID: FocusState<String?>.Binding

        var body: some View {
            HStack {
                SeriesEpisodeSelector.ErrorCard(error: error)
                    .onSelect {
                        viewModel.send(.refresh)
                    }
                    .focused(focusedEpisodeID, equals: "errorCard")
                    .frame(maxWidth: 400)

                Spacer()
            }
            .padding(.horizontal, EdgeInsets.edgePadding)
        }
    }

    // MARK: - Loading Content

    struct LoadingContent: View {

        let focusedEpisodeID: FocusState<String?>.Binding

        var body: some View {
            HStack {
                SeriesEpisodeSelector.LoadingCard()
                    .focused(focusedEpisodeID, equals: "loadingCard")
                    .frame(maxWidth: 400)

                Spacer()
            }
            .padding(.horizontal, EdgeInsets.edgePadding)
        }
    }

    // MARK: - Placeholder Content

    struct PlaceholderContent: View {

        var body: some View {
            HStack {
                SeriesEpisodeSelector.EmptyCard()
                    .frame(maxWidth: 400)

                Spacer()
            }
            .padding(.horizontal, EdgeInsets.edgePadding)
            .opacity(0)
            .allowsHitTesting(false)
        }
    }
}
