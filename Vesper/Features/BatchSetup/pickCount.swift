//
//  pickCount.swift
//  Vesper
//
//  Created by Dennis Mach on 4/2/26.
//

import SwiftUI

struct PickCountView: View {
    @Binding var pickCount: Int
    @Binding var requireUniquePicks: Bool   // when true, scene-diversity dedup is enforced
    let totalPhotos: Int
    let onContinue: () -> Void

    // Remember the last value so next batch starts at the same count
    @AppStorage("lastPickCount") private var lastPickCount: Int = 3

    var body: some View {
        VStack(spacing: 36) {
            VStack(spacing: 6) {
                Text("How many Top Picks?")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("We'll find the best ones from your batch")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.top, 100)

            VStack(spacing: 12) {
                Text("\(pickCount)")
                    .font(.system(size: 80, weight: .bold))
                    .foregroundStyle(LinearGradient.vesperGold)
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.3), value: pickCount)

                Text("of \(totalPhotos) photos")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.45))
            }

            VStack(spacing: 12) {
                Slider(value: Binding(
                    get: { Double(pickCount) },
                    set: {
                        let newVal = Int($0)
                        if newVal != pickCount {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            pickCount = newVal
                        }
                    }
                ), in: 1...Double(min(totalPhotos, 20)), step: 1)
                .tint(Color.vesperAccent)
                .padding(.horizontal, 32)

                HStack {
                    Text("1")
                    Spacer()
                    Text("\(min(totalPhotos, 20))")
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 36)
            }

            // Unique picks toggle
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                requireUniquePicks.toggle()
            } label: {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Pick unique moments")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                        Text(requireUniquePicks
                             ? "AI will avoid choosing near-identical shots"
                             : "AI may pick similar-looking shots from the same moment")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    ZStack {
                        Capsule()
                            .fill(requireUniquePicks ? Color.vesperAccent : Color.vesperCard)
                            .frame(width: 44, height: 26)
                            .overlay(Capsule().stroke(requireUniquePicks ? Color.clear : Color.vesperBorder, lineWidth: 1))
                        Circle()
                            .fill(.white)
                            .frame(width: 20, height: 20)
                            .offset(x: requireUniquePicks ? 9 : -9)
                            .animation(.spring(response: 0.25), value: requireUniquePicks)
                    }
                }
                .padding(16)
                .vesperCard(cornerRadius: 14)
            }
            .padding(.horizontal, 28)

            Spacer()

            Button {
                lastPickCount = pickCount
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onContinue()
            } label: {
                Text("Find My Best Shots")
                    .vesperPrimaryButton()
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .vesperBackground()
        .onAppear {
            let restored = min(lastPickCount, min(totalPhotos, 20))
            if pickCount != restored { pickCount = restored }
        }
    }
}

#Preview {
    PickCountView(pickCount: .constant(3), requireUniquePicks: .constant(true), totalPhotos: 80) {}
}
