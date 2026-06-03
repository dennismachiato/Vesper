//
//  PhotoAccessDeniedView.swift
//  Vesper
//

import SwiftUI

struct PhotoAccessDeniedView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            LinearGradient.vesperBg.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(Color.vesperAccent.opacity(0.08))
                        .frame(width: 120, height: 120)
                        .blur(radius: 24)
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 52, weight: .thin))
                        .foregroundStyle(Color.vesperAccent.opacity(0.85))
                }

                VStack(spacing: 12) {
                    Text("Photos Access Needed")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text("Vesper needs access to your photo library to find your best shots. Your photos are never uploaded — everything stays on your device.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }

                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        permissionStep(number: "1", text: "Open Settings below")
                        permissionStep(number: "2", text: "Tap Privacy & Security")
                    }
                    HStack(spacing: 10) {
                        permissionStep(number: "3", text: "Tap Photos")
                        permissionStep(number: "4", text: "Select \"All Photos\"")
                    }
                }
                .padding(.horizontal, 4)

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "gear")
                            Text("Open Settings")
                        }
                        .vesperPrimaryButton()
                    }

                    Button { dismiss() } label: {
                        Text("Not now")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .padding(.bottom, 40)
            }
            .padding(.horizontal, 28)
        }
    }

    private func permissionStep(number: String, text: String) -> some View {
        HStack(spacing: 10) {
            Text(number)
                .font(.caption.bold())
                .foregroundStyle(.black)
                .frame(width: 22, height: 22)
                .background(Color.vesperAccent)
                .clipShape(Circle())
            Text(text)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
        }
        .padding(12)
        .vesperCard(cornerRadius: 12)
        .frame(maxWidth: .infinity)
    }
}
