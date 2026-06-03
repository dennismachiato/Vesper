//
//  ErrorView.swift
//  Vesper
//

import SwiftUI

struct ErrorView: View {
    let error: AppError
    let onRetry: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            LinearGradient.vesperBg.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(.red.opacity(0.08))
                        .frame(width: 80, height: 80)
                        .blur(radius: 18)
                    Image(systemName: error.systemImage)
                        .font(.system(size: 36, weight: .thin))
                        .foregroundStyle(.red.opacity(0.8))
                }

                VStack(spacing: 12) {
                    Text(error.title)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text(error.message)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }

                Spacer()

                VStack(spacing: 12) {
                    if let onRetry {
                        Button {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            onRetry()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.counterclockwise")
                                Text("Try Again")
                            }
                            .vesperPrimaryButton()
                        }
                    }

                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onDismiss()
                    } label: {
                        Text(onRetry == nil ? "Go Back" : "Cancel")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .padding(.bottom, 48)
            }
            .padding(.horizontal, 32)
        }
    }
}
