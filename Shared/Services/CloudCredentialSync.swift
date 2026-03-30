//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import CoreStore
import Defaults
import Factory
import Foundation
import KeychainSwift
import Logging
import UIKit

// MARK: - Cloud Data Models

struct CloudServerInfo: Codable {
    let id: String
    let name: String
    var urls: Set<URL>
    var currentURL: URL
}

struct CloudUserCredential: Codable {
    let id: String
    let username: String
    let serverID: String
    var accessToken: String
}

struct CloudStoredEntry: Codable {
    let domain: String
    let key: String
    let data: Data
}

// MARK: - CloudCredentialSync

final class CloudCredentialSync {

    private let store = NSUbiquitousKeyValueStore.default
    private let keychain: KeychainSwift
    private let logger = Logger.swiftfin()
    private let importQueue = DispatchQueue(label: "org.jellyfin.swiftfin.cloudSync")
    private var isImporting = false

    private static let serversKey = "servers"
    private static let userKeyPrefix = "u:"
    private static let prefsKeyPrefix = "p:"
    private static let storedValuesKeyPrefix = "sv:"

    init() {
        self.keychain = Container.shared.keychainService()
    }

    // MARK: - Lifecycle

    /// Register for iCloud external change notifications.
    /// Must be called before `synchronizeOnLaunch()` per Apple docs.
    func startObserving() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleExternalChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store
        )

        // Push preferences when app enters background to batch changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    @objc
    private func handleDidEnterBackground() {
        guard Defaults[.iCloudSync] else { return }
        guard case let .signedIn(userID) = Defaults[.lastSignedInUserID] else { return }

        pushPreferences(for: userID)
    }

    /// Call once at app launch to pull latest iCloud snapshot.
    func synchronizeOnLaunch() {
        store.synchronize()
    }

    // MARK: - Push

    func pushServers() {
        guard Defaults[.iCloudSync] else { return }

        do {
            let servers = try SwiftfinStore.dataStack.fetchAll(From<ServerModel>())
            let cloudServers = servers.map { server -> CloudServerInfo in
                CloudServerInfo(
                    id: server.id,
                    name: server.name,
                    urls: server.urls,
                    currentURL: server.currentURL
                )
            }

            let data = try JSONEncoder().encode(cloudServers)
            store.set(data, forKey: Self.serversKey)
        } catch {
            logger.error("Failed to push servers to iCloud: \(error.localizedDescription)")
        }
    }

    func pushUser(_ userState: UserState) {
        guard Defaults[.iCloudSync] else { return }

        let credential = CloudUserCredential(
            id: userState.id,
            username: userState.username,
            serverID: userState.serverID,
            accessToken: userState.accessToken
        )

        do {
            let data = try JSONEncoder().encode(credential)
            store.set(data, forKey: Self.userKeyPrefix + userState.id)
        } catch {
            logger.error("Failed to push user credential to iCloud: \(error.localizedDescription)")
        }
    }

    func pushPreferences(for userID: String) {
        guard Defaults[.iCloudSync] else { return }

        // Push UserDefaults preferences, filtered to known Swiftfin keys only
        let userSuite = UserDefaults.userSuite(id: userID)
        let allPrefs = userSuite.dictionaryRepresentation()
        let filteredPrefs = allPrefs.filter { Self.syncableDefaultsKeys.contains($0.key) }

        if !filteredPrefs.isEmpty {
            let plistData = try? PropertyListSerialization.data(
                fromPropertyList: filteredPrefs,
                format: .binary,
                options: 0
            )
            if let plistData {
                store.set(plistData, forKey: Self.prefsKeyPrefix + userID)
            }
        }

        // Push StoredValues from CoreStore
        do {
            let storedData = try SwiftfinStore.dataStack.fetchAll(
                AnyStoredData.fetchClause(ownerID: userID)
            )

            let entries: [CloudStoredEntry] = storedData.compactMap { item in
                guard let data = item.data else { return nil }
                // Skip non-setting domains that shouldn't sync
                guard shouldSyncDomain(item.domain) else { return nil }
                return CloudStoredEntry(
                    domain: item.domain,
                    key: item.key,
                    data: data
                )
            }

            let data = try JSONEncoder().encode(entries)
            store.set(data, forKey: Self.storedValuesKeyPrefix + userID)
        } catch {
            logger.error("Failed to push stored values to iCloud: \(error.localizedDescription)")
        }
    }

    func pushAllLocalData() {
        guard Defaults[.iCloudSync] else { return }

        pushServers()

        do {
            let users = try SwiftfinStore.dataStack.fetchAll(From<UserModel>())
            for user in users {
                let state = user.state
                pushUser(state)
                pushPreferences(for: state.id)
            }
        } catch {
            logger.error("Failed to push all local data to iCloud: \(error.localizedDescription)")
        }
    }

    // MARK: - Pull / Import

    /// Import remote data from iCloud KV store into local storage.
    /// Pass `nil` for changedKeys to import everything.
    /// Serialized via `importQueue` to prevent concurrent CoreStore writes
    /// from overlapping app-launch and notification-driven imports.
    func importRemoteData(changedKeys: [String]?) {
        guard Defaults[.iCloudSync] else { return }

        let alreadyImporting = importQueue.sync { () -> Bool in
            if isImporting {
                logger.info("Skipping overlapping importRemoteData call")
                return true
            }
            isImporting = true
            return false
        }
        guard !alreadyImporting else { return }

        defer {
            importQueue.sync { isImporting = false }
        }

        let shouldImportServers = changedKeys == nil || changedKeys?.contains(Self.serversKey) == true
        if shouldImportServers {
            importServers()
        }

        // Import user credentials and preferences
        let allKeys = changedKeys ?? store.dictionaryRepresentation.keys.map(String.init)
        for key in allKeys {
            if key.hasPrefix(Self.userKeyPrefix) {
                importUserCredential(key: key)
            } else if key.hasPrefix(Self.prefsKeyPrefix) {
                let userID = String(key.dropFirst(Self.prefsKeyPrefix.count))
                importPreferences(for: userID, key: key)
            } else if key.hasPrefix(Self.storedValuesKeyPrefix) {
                let userID = String(key.dropFirst(Self.storedValuesKeyPrefix.count))
                importStoredValues(for: userID, key: key)
            }
        }
    }

    // MARK: - Delete

    func removeUser(_ userID: String) {
        guard Defaults[.iCloudSync] else { return }

        store.removeObject(forKey: Self.userKeyPrefix + userID)
        store.removeObject(forKey: Self.prefsKeyPrefix + userID)
        store.removeObject(forKey: Self.storedValuesKeyPrefix + userID)

        // Also update the servers list to remove user reference
        pushServers()
    }

    /// Remove a server and its users from iCloud.
    /// Accepts userIDs directly to avoid depending on CoreStore state
    /// (the server may be about to be deleted from CoreStore).
    func removeServer(_ serverID: String, userIDs: [String]) {
        guard Defaults[.iCloudSync] else { return }

        for userID in userIDs {
            store.removeObject(forKey: Self.userKeyPrefix + userID)
            store.removeObject(forKey: Self.prefsKeyPrefix + userID)
            store.removeObject(forKey: Self.storedValuesKeyPrefix + userID)
        }

        pushServers()
    }

    // MARK: - Notification Handler

    @objc
    private func handleExternalChange(_ notification: Notification) {
        guard Defaults[.iCloudSync] else { return }

        guard let userInfo = notification.userInfo,
              let reason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
        else { return }

        let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]

        switch reason {
        case NSUbiquitousKeyValueStoreServerChange:
            logger.info("iCloud KV store: server change received")
            importRemoteData(changedKeys: changedKeys)

        case NSUbiquitousKeyValueStoreInitialSyncChange:
            logger.info("iCloud KV store: initial sync change")
            importRemoteData(changedKeys: changedKeys)
            pushAllLocalData()

        case NSUbiquitousKeyValueStoreQuotaViolationChange:
            logger.warning("iCloud KV store: quota exceeded")

        case NSUbiquitousKeyValueStoreAccountChange:
            logger.info("iCloud KV store: account changed")
            importRemoteData(changedKeys: nil)

        default:
            break
        }

        Notifications[.didSyncCloudCredentials].post()
    }

    // MARK: - Private Import Helpers

    private func importServers() {
        guard let data = store.data(forKey: Self.serversKey) else { return }

        do {
            let cloudServers = try JSONDecoder().decode([CloudServerInfo].self, from: data)

            for cloudServer in cloudServers {
                let existingServer = try? SwiftfinStore.dataStack.fetchOne(
                    From<ServerModel>().where(\.$id == cloudServer.id)
                )

                if existingServer == nil {
                    try SwiftfinStore.dataStack.perform { transaction in
                        let newServer = transaction.create(Into<ServerModel>())
                        newServer.id = cloudServer.id
                        newServer.name = cloudServer.name
                        newServer.urls = cloudServer.urls
                        newServer.currentURL = cloudServer.currentURL
                    }

                    // Fetch PublicSystemInfo so isVersionCompatible works correctly
                    let serverState = ServerState(
                        urls: cloudServer.urls,
                        currentURL: cloudServer.currentURL,
                        name: cloudServer.name,
                        id: cloudServer.id,
                        usersIDs: []
                    )
                    Task {
                        do {
                            let publicInfo = try await serverState.getPublicSystemInfo()
                            StoredValues[.Server.publicInfo(id: cloudServer.id)] = publicInfo
                        } catch {
                            self.logger.warning("Could not fetch public info for imported server: \(cloudServer.name)")
                        }
                    }

                    logger.info("Imported server from iCloud: \(cloudServer.name)")
                } else {
                    // Merge URL sets for existing servers
                    try SwiftfinStore.dataStack.perform { transaction in
                        guard let server = try transaction.fetchOne(
                            From<ServerModel>().where(\.$id == cloudServer.id)
                        ) else { return }

                        let merged = server.urls.union(cloudServer.urls)
                        server.urls = merged
                    }
                }
            }
        } catch {
            logger.error("Failed to import servers from iCloud: \(error.localizedDescription)")
        }
    }

    private func importUserCredential(key: String) {
        guard let data = store.data(forKey: key) else { return }

        do {
            let credential = try JSONDecoder().decode(CloudUserCredential.self, from: data)

            let existingUser = try? SwiftfinStore.dataStack.fetchOne(
                From<UserModel>().where(\.$id == credential.id)
            )

            if existingUser == nil {
                // Verify the server exists locally
                guard let server = try? SwiftfinStore.dataStack.fetchOne(
                    From<ServerModel>().where(\.$id == credential.serverID)
                ) else {
                    logger.warning("Skipping user import — server \(credential.serverID) not found locally")
                    return
                }

                try SwiftfinStore.dataStack.perform { transaction in
                    let newUser = transaction.create(Into<UserModel>())
                    newUser.id = credential.id
                    newUser.username = credential.username

                    let editServer = transaction.edit(server)!
                    editServer.users.insert(newUser)
                }

                // Store access token in keychain
                keychain.set(credential.accessToken, forKey: "\(credential.id)-accessToken")

                logger.info("Imported user from iCloud: \(credential.username)")
            } else {
                // Update access token if cloud has a different one
                let localToken = keychain.get("\(credential.id)-accessToken")
                if localToken != credential.accessToken {
                    keychain.set(credential.accessToken, forKey: "\(credential.id)-accessToken")
                    logger.info("Updated access token from iCloud for user: \(credential.username)")
                }
            }
        } catch {
            logger.error("Failed to import user credential from iCloud: \(error.localizedDescription)")
        }
    }

    private func importPreferences(for userID: String, key: String) {
        guard let data = store.data(forKey: key) else { return }

        // Verify user exists locally
        guard let _ = try? SwiftfinStore.dataStack.fetchOne(
            From<UserModel>().where(\.$id == userID)
        ) else { return }

        do {
            guard let prefsDict = try PropertyListSerialization.propertyList(
                from: data,
                format: nil
            ) as? [String: Any] else { return }

            let userSuite = UserDefaults.userSuite(id: userID)
            for (key, value) in prefsDict {
                userSuite.set(value, forKey: key)
            }
        } catch {
            logger.error("Failed to import preferences from iCloud: \(error.localizedDescription)")
        }
    }

    private func importStoredValues(for userID: String, key: String) {
        guard let data = store.data(forKey: key) else { return }

        // Verify user exists locally
        guard let _ = try? SwiftfinStore.dataStack.fetchOne(
            From<UserModel>().where(\.$id == userID)
        ) else { return }

        do {
            let entries = try JSONDecoder().decode([CloudStoredEntry].self, from: data)

            for entry in entries {
                try SwiftfinStore.dataStack.perform { transaction in
                    let existing = try transaction.fetchAll(
                        From<AnyStoredData>()
                            .where(\.$ownerID == userID && \.$domain == entry.domain && \.$key == entry.key)
                    )

                    if let existingObject = existing.first {
                        let edit = transaction.edit(existingObject)
                        edit?.data = entry.data
                    } else {
                        let newData = transaction.create(Into<AnyStoredData>())
                        newData.data = entry.data
                        newData.domain = entry.domain
                        newData.ownerID = userID
                        newData.key = entry.key
                    }
                }
            }
        } catch {
            logger.error("Failed to import stored values from iCloud: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func shouldSyncDomain(_ domain: String) -> Bool {
        // Skip domains that are device-local or sensitive
        let excludedDomains: Set<String> = [
            "accessPolicy",
            "pinHint",
            "userData", // UserDto is fetched from server
        ]
        return !excludedDomains.contains(domain)
    }

    /// Known user preference keys from SwiftfinDefaults.
    /// Only these keys are synced to iCloud to avoid polluting the store
    /// with system-managed UserDefaults entries.
    private static let syncableDefaultsKeys: Set<String> = [
        "userAccentColor", "userAppearance",
        // Customization
        "itemViewType", "showPosterLabels",
        "nextUpPosterType", "recentlyAddedPosterType", "latestInLibraryPosterType",
        "shouldShowMissingSeasons", "shouldShowMissingEpisodes",
        "similarPosterType", "searchPosterType",
        "cinematicItemViewTypeUsePrimaryImage", "useSeriesBackdrop",
        "showFavoritedIndicator", "showProgressIndicator", "showUnplayedIndicator", "showPlayedIndicator",
        "libraryCinematicBackground", "libraryEnabledDrawerFilters",
        "letterPickerEnabled", "letterPickerOrientation",
        "libraryViewType", "libraryPosterType", "listColumnCount",
        "libraryRandomImage", "libraryShowFavorites", "libraryRememberLayout", "libraryRememberSort",
        "showRecentlyAdded", "homeResumeNextUp", "homeMaxNextUp",
        "searchEnabledDrawerFilters",
        // Video Player
        "appMaximumBitrate", "appMaximumBitrateTest", "autoPlayEnabled",
        "barActionButtons", "menuActionButtons",
        "jumpBackwardLength", "jumpForwardLength",
        "resumeOffset", "videoPlayerType",
        "videoPlayerHorizontalPanGesture", "videoPlayerhorizontalSwipeAction",
        "videoPlayerLongPressGesture", "videoPlayerLongPressSpeedMultiplier",
        "videoPlayerMultiTapGesture", "videoPlayerDoubleTouchGesture",
        "videoPlayerSwipeGesture", "videoPlayerverticalPanLeftAction", "videoPlayerverticalPanRightAction",
        "chapterSlider", "trailingTimestamp",
        "compatibilityMode", "customDeviceProfileAction", "videoPlayerPlaybackRates",
        "subtitleColor", "subtitleFontName", "subtitleSize",
        "playInBackground",
        // Experimental
        "experimentalDownloads",
        // tvOS
        "downActionShowsMenu", "confirmClose",
    ]
}

// MARK: - Factory Registration

extension Container {
    var cloudCredentialSync: Factory<CloudCredentialSync> {
        self { CloudCredentialSync() }.singleton
    }
}
