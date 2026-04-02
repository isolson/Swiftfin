//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

enum SubtitlePreference: Storable {
    /// No subtitles desired
    case none
    /// Prefer a specific language, optionally forced-only
    case language(code: String, forcedOnly: Bool)

    /// Returns the stream index matching this preference, or `nil` if no match found.
    /// For `.none`, returns `-1` (subtitles off).
    func matchingStreamIndex(in streams: [MediaStream]) -> Int? {
        switch self {
        case .none:
            return -1
        case let .language(code, forcedOnly):
            let match = streams.first { stream in
                guard stream.language?.caseInsensitiveCompare(code) == .orderedSame else { return false }
                if forcedOnly {
                    return stream.isForced == true
                }
                return true
            }
            return match?.index
        }
    }
}
