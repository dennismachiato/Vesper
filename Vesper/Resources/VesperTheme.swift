//
//  VesperTheme.swift
//  Vesper
//

import SwiftUI

// MARK: - Background gradient

extension LinearGradient {
    /// Rich dark background used across all screens
    static let vesperBg = LinearGradient(
        colors: [
            Color(red: 0.08, green: 0.07, blue: 0.11),
            Color(red: 0.04, green: 0.03, blue: 0.06)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Warm champagne-gold gradient for primary CTA buttons
    static let vesperGold = LinearGradient(
        colors: [
            Color(red: 1.00, green: 0.93, blue: 0.67),
            Color(red: 0.93, green: 0.74, blue: 0.38)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Accent color

extension Color {
    /// Warm champagne accent — used for selected states and icons
    static let vesperAccent = Color(red: 0.98, green: 0.87, blue: 0.55)
    /// Subtle card surface
    static let vesperCard = Color.white.opacity(0.06)
    /// Card border
    static let vesperBorder = Color.white.opacity(0.10)
}

// MARK: - Reusable view modifiers

extension View {
    /// Applies the app-wide dark gradient background that fills safe area
    func vesperBackground() -> some View {
        self.background(LinearGradient.vesperBg.ignoresSafeArea())
    }

    /// Standard glass card surface with a subtle border
    func vesperCard(cornerRadius: CGFloat = 16) -> some View {
        self
            .background(Color.vesperCard)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color.vesperBorder, lineWidth: 1))
    }

    /// Gold gradient primary button style — call on a label view
    func vesperPrimaryButton() -> some View {
        self
            .font(.headline)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding()
            .background(LinearGradient.vesperGold)
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
