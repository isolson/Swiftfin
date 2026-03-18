//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import CollectionHStack
import JellyfinAPI
import SwiftUI

extension SeriesEpisodeSelector {

    struct EpisodeHStack: View {

        @EnvironmentObject
        private var focusGuide: FocusGuide

        @EnvironmentObject
        private var cinematicProxy: CinematicBackgroundView.Proxy

        @FocusedValue(\.focusedPoster)
        private var focusedPoster

        @FocusState
        private var isSectionFocused

        @ObservedObject
        var viewModel: SeasonItemViewModel

        @State
        private var didScrollToPlayButtonItem = false

        @StateObject
        private var proxy = CollectionHStackProxy()

        let playButtonItem: BaseItemDto?
        let seriesItem: BaseItemDto

        // MARK: - Content View

        private func contentView(viewModel: SeasonItemViewModel) -> some View {
            CollectionHStack(
                uniqueElements: viewModel.elements,
                id: \.unwrappedIDHashOrZero,
                columns: 4
            ) { episode in
                SeriesEpisodeSelector.EpisodeCard(episode: episode)
            }
            .clipsToBounds(false)
            .scrollBehavior(.continuousLeadingEdge)
            .insets(horizontal: EdgeInsets.edgePadding)
            .itemSpacing(EdgeInsets.edgePadding / 2)
            .proxy(proxy)
            .onFirstAppear {
                guard !didScrollToPlayButtonItem else { return }
                didScrollToPlayButtonItem = true

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    guard let playButtonItem else { return }
                    proxy.scrollTo(id: playButtonItem.unwrappedIDHashOrZero, animated: false)
                }
            }
        }

        // MARK: - Body

        var body: some View {
            Group {
                switch viewModel.state {
                case .content:
                    if viewModel.elements.isEmpty {
                        EmptyHStack()
                    } else {
                        contentView(viewModel: viewModel)
                    }
                case let .error(error):
                    ErrorHStack(viewModel: viewModel, error: error)
                case .initial, .refreshing:
                    LoadingHStack()
                }
            }
            .transition(.opacity.animation(.linear(duration: 0.1)))
            .padding(.bottom, 45)
            .focusSection()
            .focused($isSectionFocused)
            .focusGuide(
                focusGuide,
                tag: "episodes",
                top: "belowHeader"
            )
            .onChange(of: focusedPoster) {
                guard let focusedPoster, isSectionFocused else { return }
                cinematicProxy.select(item: focusedPoster)
            }
            .onChange(of: isSectionFocused) { _, focused in
                if !focused {
                    cinematicProxy.select(item: seriesItem)
                }
            }
        }
    }
}

// MARK: - State Sub-Views

extension SeriesEpisodeSelector.EpisodeHStack {

    struct EmptyHStack: View {

        var body: some View {
            CollectionHStack(
                count: 1,
                columns: 4
            ) { _ in
                SeriesEpisodeSelector.EmptyCard()
            }
            .insets(horizontal: EdgeInsets.edgePadding)
            .itemSpacing(EdgeInsets.edgePadding / 2)
            .scrollDisabled(true)
        }
    }

    struct ErrorHStack: View {

        @ObservedObject
        var viewModel: SeasonItemViewModel

        let error: ErrorMessage

        var body: some View {
            CollectionHStack(
                count: 1,
                columns: 4
            ) { _ in
                SeriesEpisodeSelector.ErrorCard(error: error)
                    .onSelect {
                        viewModel.send(.refresh)
                    }
            }
            .insets(horizontal: EdgeInsets.edgePadding)
            .itemSpacing(EdgeInsets.edgePadding / 2)
            .scrollDisabled(true)
        }
    }

    struct LoadingHStack: View {

        @State
        private var placeholderCount = Int.random(in: 2 ..< 5)

        var body: some View {
            CollectionHStack(
                count: placeholderCount,
                columns: 4
            ) { _ in
                SeriesEpisodeSelector.LoadingCard()
            }
            .insets(horizontal: EdgeInsets.edgePadding)
            .itemSpacing(EdgeInsets.edgePadding / 2)
            .scrollDisabled(true)
        }
    }
}
