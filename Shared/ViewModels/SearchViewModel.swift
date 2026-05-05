//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Defaults
import Foundation
import JellyfinAPI
import OrderedCollections
import SwiftUI

@MainActor
@Stateful
final class SearchViewModel: ViewModel {

    @CasePathable
    enum Action {
        case getSuggestions
        case search(query: String)
        case actuallySearch(query: String)

        var transition: Transition {
            switch self {
            case .getSuggestions:
                .none
            case let .search(query):
                query.isEmpty ? .to(.initial) : .to(.searching)
            case .actuallySearch:
                .to(.searching, then: .initial)
                    .onRepeat(.cancel)
            }
        }
    }

    enum State {
        case error
        case initial
        case searching
    }

    private static let recentSearchesLimit = 10
    private static let resultLimitPerType = 20
    private static let hintsLimit = 8

    @Published
    private(set) var items: [BaseItemKind: [BaseItemDto]] = [:]
    @Published
    private(set) var suggestions: [BaseItemDto] = []
    @Published
    private(set) var hints: [SearchHint] = []

    private var searchQuery: CurrentValueSubject<String, Never> = .init("")
    private var hintsTask: Task<Void, Never>?

    let filterViewModel: FilterViewModel

    var hasNoResults: Bool {
        items.values.allSatisfy(\.isEmpty)
    }

    var canSearch: Bool {
        normalize(searchQuery.value).isNotEmpty || filterViewModel.currentFilters.hasQueryableFilters
    }

    // MARK: init

    init(filterViewModel: FilterViewModel = .init()) {
        self.filterViewModel = filterViewModel
        super.init()

        searchQuery
            .debounce(for: 0.5, scheduler: RunLoop.main)
            .sink { [weak self] query in
                guard let self else { return }

                actuallySearch(query: query)
            }
            .store(in: &cancellables)

        // Lower-latency pipeline that powers `.searchSuggestions`.
        searchQuery
            .debounce(for: 0.2, scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] query in
                guard let self else { return }

                fetchHints(for: query)
            }
            .store(in: &cancellables)

        filterViewModel.$currentFilters
            .debounce(for: 0.5, scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }

                actuallySearch(query: searchQuery.value)
            }
            .store(in: &cancellables)
    }

    // MARK: query normalization

    private func normalize(_ query: String) -> String {
        query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// Variants of a query to send to the server in parallel and merge.
    /// The space-collapsed variant catches titles that the server tokenizes
    /// as a single word but the user typed with spaces (e.g., "hammer barn"
    /// → "hammerbarn").
    private func variants(for normalizedQuery: String) -> [String] {
        guard normalizedQuery.contains(" ") else { return [normalizedQuery] }
        let collapsed = normalizedQuery.replacingOccurrences(of: " ", with: "")
        return [normalizedQuery, collapsed]
    }

    // MARK: search

    @Function(\Action.Cases.search)
    private func _search(_ query: String) async throws {
        searchQuery.value = query

        if normalize(query).isEmpty {
            hints = []
            hintsTask?.cancel()
        }

        await cancel()
    }

    @Function(\Action.Cases.actuallySearch)
    private func _actuallySearch(_ query: String) async throws {

        let normalizedQuery = normalize(query)
        let queryVariants = variants(for: normalizedQuery)

        guard self.canSearch else {
            items.removeAll()
            return
        }

        let newItems = try await withThrowingTaskGroup(
            of: (BaseItemKind, [BaseItemDto]).self,
            returning: [BaseItemKind: [BaseItemDto]].self
        ) { group in

            // Base items
            let retrievingItemTypes: [BaseItemKind] = [
                .boxSet,
                .episode,
                .movie,
                .musicArtist,
                .musicVideo,
                .liveTvProgram,
                .series,
                .tvChannel,
                .video,
            ]

            for type in retrievingItemTypes {
                group.addTask {
                    let items = try await self._getItems(variants: queryVariants, itemType: type)
                    return (type, items)
                }
            }

            // People
            group.addTask {
                let items = try await self._getPeople(variants: queryVariants)
                return (BaseItemKind.person, items)
            }

            var result: [BaseItemKind: [BaseItemDto]] = [:]

            while let items = try await group.next() {
                if items.1.isNotEmpty {
                    result[items.0] = items.1
                }
            }

            return result
        }

        guard !Task.isCancelled else { return }
        self.items = newItems
    }

    /// Run all variants concurrently and merge — preserving the original
    /// query's relevance ordering by appending novel ids from later variants.
    private func _getItems(variants: [String], itemType: BaseItemKind) async throws -> [BaseItemDto] {

        let perVariant = try await withThrowingTaskGroup(
            of: (Int, [BaseItemDto]).self,
            returning: [[BaseItemDto]].self
        ) { group in
            for (index, variant) in variants.enumerated() {
                group.addTask {
                    let items = try await self._getItems(query: variant, itemType: itemType)
                    return (index, items)
                }
            }

            var indexed: [(Int, [BaseItemDto])] = []
            while let result = try await group.next() {
                indexed.append(result)
            }
            return indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }

        var merged: OrderedSet<BaseItemDto> = []
        for batch in perVariant {
            for item in batch { merged.append(item) }
        }

        return Array(merged.prefix(Self.resultLimitPerType))
    }

    private func _getItems(query: String, itemType: BaseItemKind) async throws -> [BaseItemDto] {

        var parameters = Paths.GetItemsByUserIDParameters()
        parameters.enableUserData = true
        parameters.fields = .MinimumFields
        parameters.includeItemTypes = [itemType]
        parameters.isRecursive = true
        parameters.limit = Self.resultLimitPerType
        parameters.searchTerm = query.isEmpty ? nil : query

        // Filters
        let filters = filterViewModel.currentFilters
        parameters.filters = filters.traits
        parameters.genres = filters.genres.map(\.value)
        parameters.sortBy = filters.sortBy.map(\.rawValue)
        parameters.sortOrder = filters.sortOrder
        parameters.tags = filters.tags.map(\.value)
        parameters.years = filters.years.map(\.intValue)

        if filters.letter.first?.value == "#" {
            parameters.nameLessThan = "A"
        } else {
            parameters.nameStartsWith = filters.letter
                .map(\.value)
                .filter { $0 != "#" }
                .first
        }

        let request = Paths.getItemsByUserID(userID: userSession.user.id, parameters: parameters)
        let response = try await userSession.client.send(request)

        return response.value.items ?? []
    }

    private func _getPeople(variants: [String]) async throws -> [BaseItemDto] {

        let perVariant = try await withThrowingTaskGroup(
            of: (Int, [BaseItemDto]).self,
            returning: [[BaseItemDto]].self
        ) { group in
            for (index, variant) in variants.enumerated() {
                group.addTask {
                    let items = try await self._getPeople(query: variant)
                    return (index, items)
                }
            }

            var indexed: [(Int, [BaseItemDto])] = []
            while let result = try await group.next() {
                indexed.append(result)
            }
            return indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }

        var merged: OrderedSet<BaseItemDto> = []
        for batch in perVariant {
            for item in batch { merged.append(item) }
        }

        return Array(merged.prefix(Self.resultLimitPerType))
    }

    private func _getPeople(query: String) async throws -> [BaseItemDto] {

        guard query.isNotEmpty else { return [] }

        var parameters = Paths.GetPersonsParameters()
        parameters.limit = Self.resultLimitPerType
        parameters.searchTerm = query

        let request = Paths.getPersons(parameters: parameters)
        let response = try await userSession.client.send(request)

        return response.value.items ?? []
    }

    // MARK: hints

    private func fetchHints(for query: String) {
        hintsTask?.cancel()

        let normalizedQuery = normalize(query)
        guard normalizedQuery.isNotEmpty else {
            hints = []
            return
        }

        hintsTask = Task { [weak self] in
            guard let self else { return }

            do {
                let merged = try await self.fetchMergedHints(variants: self.variants(for: normalizedQuery))
                guard !Task.isCancelled else { return }
                self.hints = merged
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.hints = []
            }
        }
    }

    private func fetchMergedHints(variants: [String]) async throws -> [SearchHint] {

        let perVariant = try await withThrowingTaskGroup(
            of: (Int, [SearchHint]).self,
            returning: [[SearchHint]].self
        ) { group in
            for (index, variant) in variants.enumerated() {
                group.addTask {
                    let hints = try await self.fetchHints(query: variant)
                    return (index, hints)
                }
            }

            var indexed: [(Int, [SearchHint])] = []
            while let result = try await group.next() {
                indexed.append(result)
            }
            return indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }

        var merged: OrderedSet<SearchHint> = []
        for batch in perVariant {
            for hint in batch { merged.append(hint) }
        }

        return Array(merged.prefix(Self.hintsLimit))
    }

    private func fetchHints(query: String) async throws -> [SearchHint] {

        var parameters = Paths.GetSearchHintsParameters(searchTerm: query)
        parameters.userID = userSession.user.id
        parameters.limit = Self.hintsLimit
        parameters.isIncludeMedia = true
        parameters.isIncludePeople = true
        parameters.isIncludeArtists = true

        let request = Paths.getSearchHints(parameters: parameters)
        let response = try await userSession.client.send(request)

        return response.value.searchHints ?? []
    }

    // MARK: recent searches

    func recordRecentSearch(_ query: String) {
        let trimmed = normalize(query)
        guard trimmed.isNotEmpty else { return }

        var current = Defaults[.recentSearches]
        current.removeAll { $0.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
        current.insert(trimmed, at: 0)
        if current.count > Self.recentSearchesLimit {
            current = Array(current.prefix(Self.recentSearchesLimit))
        }
        Defaults[.recentSearches] = current
    }

    func clearRecentSearches() {
        Defaults[.recentSearches] = []
    }

    // MARK: suggestions

    @Function(\Action.Cases.getSuggestions)
    private func _getSuggestions() async throws {

        filterViewModel.send(.getQueryFilters)

        var parameters = Paths.GetItemsByUserIDParameters()
        parameters.includeItemTypes = [.movie, .series]
        parameters.isRecursive = true
        parameters.limit = 10
        parameters.sortBy = [ItemSortBy.random.rawValue]

        let request = Paths.getItemsByUserID(userID: userSession.user.id, parameters: parameters)
        let response = try await userSession.client.send(request)

        self.suggestions = response.value.items ?? []
    }
}
