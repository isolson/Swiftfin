//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import CoreStore
import Defaults
import Foundation
import Logging

extension SwiftfinStore {

    struct PersistenceBackupServer: Hashable, Storable {
        let currentURL: URL
        let id: String
        let name: String
        let urls: [URL]
        let users: [PersistenceBackupUser]
    }

    struct PersistenceBackupUser: Hashable, Storable {
        let accessPolicy: UserAccessPolicy
        let id: String
        let pinHint: String
        let username: String
    }

    private static let persistenceBackupLogger = Logger.swiftfin()

    /// Returns `true` if the restore succeeded or was not needed,
    /// `false` if the restore failed.
    @discardableResult
    static func restorePersistenceBackupIfNeeded() -> Bool {
        #if os(tvOS)
        do {
            let storedServers = try dataStack.fetchAll(From<ServerModel>())

            guard storedServers.isEmpty else { return true }

            let backups = Defaults[.persistenceBackupServers]

            guard backups.isNotEmpty else { return true }

            try dataStack.perform { transaction in
                for backup in backups {
                    let newServer = transaction.create(Into<ServerModel>())
                    newServer.currentURL = backup.currentURL
                    newServer.id = backup.id
                    newServer.name = backup.name
                    newServer.urls = Set(backup.urls)

                    for userBackup in backup.users {
                        let newUser = transaction.create(Into<UserModel>())
                        newUser.id = userBackup.id
                        newUser.username = userBackup.username
                        newServer.users.insert(newUser)
                    }
                }
            }

            for backup in backups {
                for userBackup in backup.users {
                    let restoredUser = UserState(
                        id: userBackup.id,
                        serverID: backup.id,
                        username: userBackup.username
                    )

                    restoredUser.accessPolicy = userBackup.accessPolicy
                    restoredUser.pinHint = userBackup.pinHint
                }
            }

            persistenceBackupLogger.info(
                "Restored tvOS persistence backup",
                metadata: ["serverCount": .stringConvertible(backups.count)]
            )

            return true
        } catch {
            persistenceBackupLogger.error("Unable to restore tvOS persistence backup: \(error.localizedDescription)")
            return false
        }
        #else
        return true
        #endif
    }

    static func syncPersistenceBackup() {
        #if os(tvOS)
        do {
            let backups = try dataStack
                .fetchAll(From<ServerModel>())
                .map { server in
                    PersistenceBackupServer(
                        currentURL: server.currentURL,
                        id: server.id,
                        name: server.name,
                        urls: server.urls.sorted(by: { $0.absoluteString < $1.absoluteString }),
                        users: server.users
                            .map { user in
                                let userState = user.state

                                return PersistenceBackupUser(
                                    accessPolicy: userState.accessPolicy,
                                    id: user.id,
                                    pinHint: userState.pinHint,
                                    username: user.username
                                )
                            }
                            .sorted(by: { $0.id < $1.id })
                    )
                }
                .sorted(by: { lhs, rhs in
                    if lhs.name == rhs.name {
                        return lhs.id < rhs.id
                    }

                    return lhs.name < rhs.name
                })

            Defaults[.persistenceBackupServers] = backups
        } catch {
            persistenceBackupLogger.error("Unable to sync tvOS persistence backup: \(error.localizedDescription)")
        }
        #endif
    }
}
