//
//  ZapOption.swift
//  nostrTV
//
//  Created by Claude Code
//

import Foundation

/// Represents a preset zap option with emoji, amount, and message
struct ZapOption: Identifiable {
    let id = UUID()
    let emoji: String
    let amount: Int  // Amount in sats
    let message: String

    /// Predefined zap options
    static let presets: [ZapOption] = [
        ZapOption(emoji: "👍", amount: 21, message: "Great Stream! - sent from nostrTV"),
        ZapOption(emoji: "🚀", amount: 420, message: "Let's GO! - sent from nostrTV"),
        ZapOption(emoji: "☕️", amount: 1_000, message: "Coffee on me today! - sent from nostrTV"),
        ZapOption(emoji: "🍺", amount: 5_000, message: "Cheers! - sent from nostrTV"),
        ZapOption(emoji: "🍷", amount: 10_000, message: "Respect! - sent from nostrTV"),
        ZapOption(emoji: "👑", amount: 100_000, message: "G.O.A.T! - sent from nostrTV")
    ]

    /// Format amount with K suffix for thousands
    var displayAmount: String {
        if amount >= 1_000 {
            return "\(amount / 1_000)K"
        }
        return "\(amount)"
    }
}
