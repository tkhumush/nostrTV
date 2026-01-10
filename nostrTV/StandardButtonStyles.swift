//
//  StandardButtonStyles.swift
//  nostrTV
//
//  Created by Claude Code
//  Standardized button styles for consistent focus behavior across the app
//  Following Apple's tvOS Human Interface Guidelines for focus states
//

import SwiftUI

/// Standard button style for tvOS with Apple-compliant focus behavior
/// - Scale: 1.1x (10% enlargement per Apple HIG)
/// - Shadow: Black with 0.3 alpha, offset 16pt, radius 25pt
/// - Animation: Smooth spring animation for natural feel
struct StandardTVButtonStyle: ButtonStyle {
    @Environment(\.isFocused) var isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(isFocused ? 1.1 : 1.0)
            .shadow(
                color: .black.opacity(isFocused ? 0.3 : 0),
                radius: isFocused ? 25 : 0,
                x: 0,
                y: isFocused ? 16 : 0
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }
}

/// Square/rectangular button style (no rounded corners)
/// Used for chat buttons and similar square UI elements
/// Same focus behavior as StandardTVButtonStyle but with rectangular clipping
struct SquareCardButtonStyle: ButtonStyle {
    @Environment(\.isFocused) var isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(isFocused ? 1.1 : 1.0)
            .shadow(
                color: .black.opacity(isFocused ? 0.3 : 0),
                radius: isFocused ? 25 : 0,
                x: 0,
                y: isFocused ? 16 : 0
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
            .clipShape(Rectangle())
    }
}

/// Extension to easily apply standard TV button style
extension ButtonStyle where Self == StandardTVButtonStyle {
    static var standardTV: StandardTVButtonStyle {
        StandardTVButtonStyle()
    }
}

/// Extension to easily apply square card button style
extension ButtonStyle where Self == SquareCardButtonStyle {
    static var squareCard: SquareCardButtonStyle {
        SquareCardButtonStyle()
    }
}
