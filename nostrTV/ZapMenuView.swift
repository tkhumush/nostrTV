//
//  ZapMenuView.swift
//  nostrTV
//
//  Created by Claude Code
//

import SwiftUI

/// Interactive menu for selecting zap amounts
struct ZapMenuView: View {
    let onZapSelected: (ZapOption) -> Void
    let onDismiss: () -> Void

    @State private var selectedOption: ZapOption?

    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    var body: some View {
        ZStack {
            // Semi-transparent background - don't dismiss on tap, only use Cancel button
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(spacing: 30) {
                // Title
                Text("⚡️ Send a Zap")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundColor(.white)

                // Zap options grid
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(ZapOption.presets) { option in
                        ZapOptionButton(option: option) {
                            selectedOption = option
                            onZapSelected(option)
                        }
                    }
                }
                .padding(.horizontal, 40)

                // Cancel button
                Button(action: onDismiss) {
                    Text("Cancel")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 60)
                        .padding(.vertical, 20)
                        .background(Color.gray.opacity(0.5))
                        .cornerRadius(15)
                }
                .buttonStyle(.card)
            }
            .padding(60)
        }
    }
}

/// Individual zap option button
private struct ZapOptionButton: View {
    let option: ZapOption
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 12) {
                // Emoji
                Text(option.emoji)
                    .font(.system(size: 64))

                // Amount
                Text("\(option.displayAmount) sats")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)

                // Message
                Text(option.message)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 280, height: 220)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.white.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.yellow, lineWidth: 3)
            )
        }
        .buttonStyle(.card)
    }
}

/// Inline zap menu options for horizontal display next to zap button
struct ZapMenuOptionsView: View {
    let onZapSelected: (ZapOption) -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ZapOption.presets) { option in
                ZapMenuOptionButton(option: option) {
                    onZapSelected(option)
                }
            }
        }
    }
}

/// Individual inline zap option button with native Liquid Glass style
private struct ZapMenuOptionButton: View {
    let option: ZapOption
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Text(option.emoji)
                    .font(.system(size: 40))
                Text("\(option.displayAmount)")
                    .font(.system(size: 18, weight: .bold))
            }
            .frame(width: 120, height: 120)
        }
        .buttonStyle(.borderedProminent)
        .tint(.gray)
    }
}

#Preview {
    ZapMenuView(
        onZapSelected: { option in
            print("Selected: \(option.message) - \(option.amount) sats")
        },
        onDismiss: {
            print("Dismissed")
        }
    )
}

#Preview {
    ZStack {
        Color.black
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color.yellow)
                .frame(width: 120, height: 120)

            ZapMenuOptionsView(
                onZapSelected: { option in
                    print("Selected: \(option.message) - \(option.amount) sats")
                },
                onDismiss: {
                    print("Dismissed")
                }
            )
        }
    }
}
