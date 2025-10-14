//
//  ZapButtonView.swift
//  nostrTV
//
//  Created by Claude Code
//

import SwiftUI

/// Floating button to initiate zap flow
struct ZapButtonView: View {
    let onTap: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(isFocused ? Color.yellow.opacity(0.9) : Color.yellow)
                    .frame(width: 100, height: 100)
                    .shadow(color: .yellow.opacity(0.5), radius: 10)
                    .scaleEffect(isFocused ? 1.2 : 1.0)
                    .animation(.easeInOut(duration: 0.2), value: isFocused)

                Text("⚡️")
                    .font(.system(size: 60))
            }
        }
        .buttonStyle(.card)
        .focused($isFocused)
    }
}

#Preview {
    ZStack {
        Color.black
        ZapButtonView {
            print("Zap button tapped")
        }
    }
}
