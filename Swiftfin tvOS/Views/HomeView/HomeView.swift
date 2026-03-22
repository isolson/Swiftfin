//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import Foundation
import JellyfinAPI
import SwiftUI

struct HomeView: View {

    @Router
    private var router

    @StateObject
    private var viewModel = HomeViewModel()

    @StateObject
    private var cinematicProxy = CinematicBackgroundView.Proxy()

    @Default(.Customization.Home.showRecentlyAdded)
    private var showRecentlyAdded

    private var initialBackgroundItem: (any Poster)? {
        if viewModel.resumeItems.isNotEmpty {
            return viewModel.resumeItems.elements.first
        }
        if showRecentlyAdded, viewModel.recentlyAddedViewModel.elements.isNotEmpty {
            return viewModel.recentlyAddedViewModel.elements.first
        }
        if viewModel.nextUpViewModel.elements.isNotEmpty {
            return viewModel.nextUpViewModel.elements.first
        }
        return nil
    }

    @ViewBuilder
    private var contentView: some View {
        ZStack {
            CinematicBackgroundView(
                viewModel: cinematicProxy,
                initialItem: initialBackgroundItem
            )
            .overlay {
                Color.black
                    .maskLinearGradient {
                        (location: 0.5, opacity: 0)
                        (location: 0.6, opacity: 0.4)
                        (location: 1, opacity: 1)
                    }
            }
            .frame(height: UIScreen.main.bounds.height)
            .maskLinearGradient {
                (location: 0.9, opacity: 1)
                (location: 1, opacity: 0)
            }
            .frame(maxHeight: .infinity, alignment: .top)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    if viewModel.resumeItems.isNotEmpty {
                        CinematicResumeView(viewModel: viewModel)

                        NextUpView(viewModel: viewModel.nextUpViewModel)

                        if showRecentlyAdded {
                            RecentlyAddedView(viewModel: viewModel.recentlyAddedViewModel)
                        }
                    } else {
                        if showRecentlyAdded {
                            CinematicRecentlyAddedView(viewModel: viewModel.recentlyAddedViewModel)
                        }

                        NextUpView(viewModel: viewModel.nextUpViewModel)
                            .safeAreaPadding(.top, 150)
                    }

                    ForEach(viewModel.libraries) { viewModel in
                        LatestInLibraryView(viewModel: viewModel)
                    }
                }
            }
            .environmentObject(cinematicProxy)
        }
    }

    var body: some View {
        ZStack {
            Color.clear

            switch viewModel.state {
            case .content:
                contentView
            case let .error(error):
                ErrorView(error: error)
            case .initial, .refreshing:
                ProgressView()
            }
        }
        .animation(.linear(duration: 0.1), value: viewModel.state)
        .refreshable {
            viewModel.send(.refresh)
        }
        .onFirstAppear {
            viewModel.send(.refresh)
        }
        .ignoresSafeArea()
        .sinceLastDisappear { interval in
            if interval > 60 || viewModel.notificationsReceived.contains(.itemMetadataDidChange) {
                viewModel.send(.backgroundRefresh)
                viewModel.notificationsReceived.remove(.itemMetadataDidChange)
            }
        }
        .onChange(of: viewModel.state) {
            if case .content = viewModel.state, let item = initialBackgroundItem {
                cinematicProxy.select(item: item)
            }
        }
    }
}
