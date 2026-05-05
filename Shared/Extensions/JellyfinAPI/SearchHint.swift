//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

extension SearchHint {

    /// Build a stub `BaseItemDto` suitable for routing to `ItemView`.
    /// The destination view will fetch the full item by id.
    var asBaseItemDto: BaseItemDto {
        BaseItemDto(
            id: id,
            imageTags: primaryImageTag.map { ["Primary": $0] },
            indexNumber: indexNumber,
            name: name,
            parentIndexNumber: parentIndexNumber,
            primaryImageAspectRatio: primaryImageAspectRatio,
            productionYear: productionYear,
            seriesName: series,
            type: type
        )
    }
}
