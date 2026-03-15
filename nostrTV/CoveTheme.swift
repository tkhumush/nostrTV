//
//  CoveTheme.swift
//  nostrTV
//
//  Cove Brand Identity — "The Digital Hearth"
//  Centralized design system for the Cove app.
//

import SwiftUI

// MARK: - Brand Colors

extension Color {
    /// Deep Harbor (#1A1F2C) — Soft desaturated navy for backgrounds
    static let coveBackground = Color(red: 0.102, green: 0.122, blue: 0.173)

    /// Sea Foam (#A3D9C9) — Muted friendly mint for primary actions and selections
    static let coveAccent = Color(red: 0.639, green: 0.851, blue: 0.788)

    /// Sunset Gold (#FFB347) — Warm amber for live indicators and zaps
    static let coveGold = Color(red: 1.0, green: 0.702, blue: 0.278)

    /// Lighter variant of Deep Harbor for cards and elevated surfaces
    static let coveSurface = Color(red: 0.14, green: 0.16, blue: 0.22)

    /// Subtle overlay for chat bubbles and secondary surfaces
    static let coveOverlay = Color(red: 0.18, green: 0.20, blue: 0.27)

    /// Muted text on dark backgrounds
    static let coveSecondary = Color(red: 0.55, green: 0.58, blue: 0.65)
}

// MARK: - Brand Typography
// Uses .rounded design for headings (closest system match to Outfit/Lexend)
// Uses default system for body text (closest match to Inter)

extension Font {
    /// App title — large branding text
    static let coveTitle = Font.system(size: 72, weight: .bold, design: .rounded)

    /// Page headings
    static let coveHeading = Font.system(size: 56, weight: .bold, design: .rounded)

    /// Section headings
    static let coveSection = Font.system(size: 48, weight: .bold, design: .rounded)

    /// Card titles
    static let coveCardTitle = Font.system(size: 36, weight: .semibold, design: .rounded)

    /// Subheadings and important labels
    static let coveSubheading = Font.system(size: 28, weight: .semibold, design: .rounded)

    /// Standard body text (optimized for 10-foot readability)
    static let coveBody = Font.system(size: 24, weight: .regular)

    /// Secondary/supporting text
    static let coveCaption = Font.system(size: 20, weight: .medium)

    /// Small labels, timestamps
    static let coveSmall = Font.system(size: 16, weight: .regular)
}

// MARK: - Brand Copy

struct CoveCopy {
    // Loading states
    static let appLoading = "Preparing your spot by the fire..."
    static let loadingSubtitle = "This will just take a moment"
    static let profileLoading = "Finding your profile..."
    static let generatingQR = "Generating QR code..."

    // Empty states
    static let noStreams = "The tide is low right now. Check back soon!"
    static let noMessages = "It's quiet in here..."
    static let noMessagesSub = "Be the first to say hello!"
    static let noZaps = "No zaps sent yet — be the first!"

    // Actions
    static let followAction = "Pull up a chair"
    static let zapAction = "Send a zap"
    static let loginPrompt = "Sign in to join the conversation"
    static let loginSubtitle = "Connect your Nostr identity to chat and send zaps"

    // Chat
    static let chatPlaceholder = "Say something..."

    // Player
    static let scanToZap = "Scan to zap"

    // Bunker
    static let bunkerTitle = "Sign in with nsec bunker"
    static let bunkerConnecting = "Connecting to bunker relay..."
    static let bunkerScan = "Scan the QR code"
    static let bunkerScanSub = "Use Amber, Amethyst, or compatible app"
    static let bunkerApprove = "Approve the connection on your phone"
    static let bunkerConnected = "Connected!"
    static let bunkerFetching = "Finding your profile..."
}

// MARK: - UI Constants

struct CoveUI {
    /// Corner radius for cards and containers (rounded, sea-stone feel)
    static let cornerRadius: CGFloat = 16
    static let smallCornerRadius: CGFloat = 10
    static let badgeCornerRadius: CGFloat = 8

    /// Standard spacing
    static let spacingLarge: CGFloat = 40
    static let spacingMedium: CGFloat = 20
    static let spacingSmall: CGFloat = 12
}
