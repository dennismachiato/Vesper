//
//  OnboardingView.swift
//  Vesper

import SwiftUI

struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var currentPage = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            icon: "sparkles",
            title: "Meet Vesper",
            description: "You take 50 photos. Vesper picks the best ones — using on-device AI that understands light, sharpness, composition, and your personal style."
        ),
        OnboardingPage(
            icon: "slider.horizontal.3",
            title: "You're in control",
            description: "Pick a category and vibe, or describe exactly what you want. Add reference photos to teach Vesper your taste over time."
        ),
        OnboardingPage(
            icon: "lock.shield",
            title: "100% on-device",
            description: "Your photos never leave your iPhone. Everything runs locally — no servers, no uploads, no subscriptions required to get started."
        )
    ]

    var body: some View {
        ZStack {
            LinearGradient.vesperBg.ignoresSafeArea()

            // Ambient glow that shifts per page
            Circle()
                .fill(Color.vesperAccent.opacity(0.06))
                .frame(width: 300, height: 300)
                .blur(radius: 80)
                .offset(y: -80)
                .animation(.easeInOut(duration: 0.4), value: currentPage)

            VStack(spacing: 0) {
                TabView(selection: $currentPage) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                        pageView(page)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                // Bottom controls
                VStack(spacing: 24) {
                    HStack(spacing: 8) {
                        ForEach(0..<pages.count, id: \.self) { i in
                            Capsule()
                                .fill(i == currentPage ? Color.vesperAccent : Color.vesperAccent.opacity(0.25))
                                .frame(width: i == currentPage ? 20 : 6, height: 6)
                                .animation(.easeInOut(duration: 0.25), value: currentPage)
                        }
                    }

                    if currentPage < pages.count - 1 {
                        Button {
                            withAnimation { currentPage += 1 }
                        } label: {
                            Text("Next")
                                .vesperPrimaryButton()
                        }
                        .padding(.horizontal, 32)
                    } else {
                        // Don't request permission here — Apple guidelines require requesting
                        // permissions at the moment they're needed, not during onboarding.
                        // Permission is requested when the user taps "New Batch" on the home screen.
                        Button {
                            onComplete()
                        } label: {
                            Text("Get Started")
                                .vesperPrimaryButton()
                        }
                        .padding(.horizontal, 32)
                    }
                }
                .padding(.bottom, 52)
            }
        }
    }

    private func pageView(_ page: OnboardingPage) -> some View {
        VStack(spacing: 32) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.vesperAccent.opacity(0.08))
                    .frame(width: 96, height: 96)
                    .blur(radius: 20)
                Image(systemName: page.icon)
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(Color.vesperAccent)
            }

            VStack(spacing: 16) {
                Text(page.title)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(page.description)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.60))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 40)
            }

            Spacer()
            Spacer()
        }
    }

}

struct OnboardingPage {
    let icon: String
    let title: String
    let description: String
}

#Preview {
    OnboardingView {}
}
