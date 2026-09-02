/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Defaults
import Foundation

/// Raycast Focus session mode: block only the listed categories, or allow only them.
enum RaycastFocusBlockMode: String, CaseIterable, Identifiable, Codable, Defaults.Serializable {
    case block
    case allow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .block: return String(localized: "Block")
        case .allow: return String(localized: "Allow")
        }
    }

    var summary: String {
        switch self {
        case .block: return String(localized: "Block the selected categories")
        case .allow: return String(localized: "Allow only the selected categories")
        }
    }
}

/// A Raycast Focus category. `id` is Raycast's `categoryId`, the value its
/// `raycast://focus/start?categories=` deeplink resolves; built-ins use their name in
/// lowercase (read from Raycast 2.1.3's bundled category table).
struct RaycastFocusCategory: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String

    static let builtIn: [RaycastFocusCategory] = [
        RaycastFocusCategory(id: "social", title: String(localized: "Social"), symbol: "person.2"),
        RaycastFocusCategory(id: "messaging", title: String(localized: "Messaging"), symbol: "bubble.left.and.bubble.right"),
        RaycastFocusCategory(id: "streaming", title: String(localized: "Streaming"), symbol: "play.rectangle"),
        RaycastFocusCategory(id: "gaming", title: String(localized: "Gaming"), symbol: "gamecontroller"),
        RaycastFocusCategory(id: "news", title: String(localized: "News"), symbol: "newspaper"),
        RaycastFocusCategory(id: "shopping", title: String(localized: "Shopping"), symbol: "cart"),
        RaycastFocusCategory(id: "travel", title: String(localized: "Travel"), symbol: "airplane"),
    ]

    /// Built-ins followed by the user's custom Raycast categories (entered by id in Settings).
    static func all(includingCustom customIds: [String]) -> [RaycastFocusCategory] {
        var result = builtIn
        for raw in customIds {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !result.contains(where: { $0.id == id }) else { continue }
            result.append(RaycastFocusCategory(id: id, title: id, symbol: "tag"))
        }
        return result
    }

    static func title(for id: String) -> String {
        builtIn.first(where: { $0.id == id })?.title ?? id
    }
}
