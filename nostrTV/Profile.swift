//
//  Profile.swift
//  nostrTV
//
//  Created by Taymur Khumush on 8/16/25.
//

import Foundation

struct Profile: Codable, Equatable {
    let pubkey: String
    let name: String?
    let displayName: String?
    let about: String?
    let picture: String?
    let nip05: String?
    let lud16: String?
    
    var displayNameOrName: String {
        preferredName ?? "Unknown"
    }

    var preferredName: String? {
        [displayName, name].compactMap { value in
            let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }.first
    }

    /// Read useful fields independently: one malformed optional metadata field
    /// must not discard a person's name and picture along with it.
    static func fromMetadata(pubkey: String, content: String) -> Profile? {
        guard let data = content.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func text(_ keys: String...) -> String? {
            keys.compactMap { key -> String? in
                guard let value = fields[key] as? String else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }.first
        }
        return Profile(pubkey: pubkey.lowercased(), name: text("name"),
            displayName: text("display_name", "displayName"), about: text("about"),
            picture: text("picture"), nip05: text("nip05"), lud16: text("lud16", "lud06"))
    }

    static func chatName(profile: Profile?, pubkey: String, fallbackName: String? = nil) -> String {
        if let name = profile?.preferredName { return name }
        if let name = fallbackName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        return "\(pubkey.prefix(8))…"
    }
}
