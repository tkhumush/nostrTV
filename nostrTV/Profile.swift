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
        return displayName ?? name ?? "Unknown"
    }
}
