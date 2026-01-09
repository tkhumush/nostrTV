//
//  ZapComment.swift
//  nostrTV
//
//  Created by Claude Code
//

import Foundation

/// Represents a chat comment on a Nostr live stream
/// Parsed from kind 1311 (live chat) events
struct ZapComment: Identifiable, Codable {
    let id: String  // Event ID
    let amount: Int  // Amount in millisats (0 for regular comments)
    let senderPubkey: String  // Pubkey of the sender
    let senderName: String?  // Display name of sender (if available)
    let comment: String  // Message content
    let timestamp: Date  // When the message was sent
    let streamEventId: String?  // Stream identifier
    let bolt11: String?  // Lightning invoice (for zap receipts)

    /// Amount formatted as sats (divide millisats by 1000)
    var amountInSats: Int {
        return amount / 1000
    }

    /// Formatted display string for the chyron
    var displayString: String {
        let name = senderName ?? "Anonymous"

        // If this is a zap (has amount), show it differently
        if amount > 0 {
            let sats = amountInSats
            if comment.isEmpty {
                return "⚡️ \(name) zapped \(sats) sats"
            } else {
                return "⚡️ \(name) (\(sats) sats): \(comment)"
            }
        } else {
            // Regular chat comment
            return "\(name): \(comment)"
        }
    }
}
