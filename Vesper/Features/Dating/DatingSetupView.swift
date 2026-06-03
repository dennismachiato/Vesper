//
//  DatingSetupView.swift
//  Vesper
//

import SwiftUI

// MARK: - Enums

enum DatingVibe: String, CaseIterable {
    case adventurous  = "Adventurous"
    case funPlayful   = "Fun & Playful"
    case fitActive    = "Fit & Active"
    case creative     = "Creative & Artistic"
    case ambitious    = "Ambitious"
    case intellectual = "Intellectual"
    case coolRelaxed  = "Cool & Relaxed"
    case romantic     = "Romantic & Warm"

    var emoji: String {
        switch self {
        case .adventurous:  return "🌍"
        case .funPlayful:   return "😄"
        case .fitActive:    return "💪"
        case .creative:     return "🎨"
        case .ambitious:    return "🚀"
        case .intellectual: return "🧠"
        case .coolRelaxed:  return "😎"
        case .romantic:     return "❤️"
        }
    }

    var tagline: String {
        switch self {
        case .adventurous:  return "Travel, outdoors, exploring"
        case .funPlayful:   return "Laughing, candid, good energy"
        case .fitActive:    return "Athletic, healthy, active lifestyle"
        case .creative:     return "Unique style, artistic, expressive"
        case .ambitious:    return "Polished, driven, professional"
        case .intellectual: return "Curious, thoughtful, bookish"
        case .coolRelaxed:  return "Effortless, laid-back, natural"
        case .romantic:     return "Warm, soft lighting, genuine smile"
        }
    }

    /// CLIP prompt used to score photos for this vibe
    var clipPrompt: String {
        switch self {
        case .adventurous:
            return "person outdoors adventure travel hiking confident natural expression smiling"
        case .funPlayful:
            return "person laughing smiling genuine joy fun candid playful happy"
        case .fitActive:
            return "athletic active person fitness healthy lifestyle confident energetic"
        case .creative:
            return "creative artistic expressive person unique interesting style personality"
        case .ambitious:
            return "professional confident polished person well-dressed ambitious successful"
        case .intellectual:
            return "thoughtful curious intellectual person interesting conversation smart"
        case .coolRelaxed:
            return "cool casual effortless style laid-back confident natural relaxed"
        case .romantic:
            return "warm approachable romantic person soft lighting genuine smile tender"
        }
    }
}

enum DatingAudience: String, CaseIterable {
    case women   = "Women"
    case men     = "Men"
    case everyone = "Everyone"

    var emoji: String {
        switch self {
        case .women:    return "👩"
        case .men:      return "👨"
        case .everyone: return "🌈"
        }
    }

    var tagline: String {
        switch self {
        case .women:    return "Optimized to attract women"
        case .men:      return "Optimized to attract men"
        case .everyone: return "AI figures out what works for all"
        }
    }
}

// MARK: - Vibe selection screen

struct DatingVibeSelectionView: View {
    @Binding var selectedVibes: [DatingVibe]
    let onContinue: () -> Void

    private let maxVibes = 3
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("What's your vibe?")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("Pick up to 3 — we'll find photos that match the energy")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)

                if !selectedVibes.isEmpty {
                    Text("\(selectedVibes.count) of \(maxVibes) selected")
                        .font(.caption.bold())
                        .foregroundStyle(Color.vesperAccent)
                        .padding(.top, 2)
                }
            }
            .padding(.top, 100)
            .padding(.horizontal, 28)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(DatingVibe.allCases, id: \.self) { vibe in
                        let isSelected = selectedVibes.contains(vibe)
                        let isDisabled = !isSelected && selectedVibes.count >= maxVibes
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            if isSelected {
                                selectedVibes.removeAll { $0 == vibe }
                            } else if selectedVibes.count < maxVibes {
                                selectedVibes.append(vibe)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(vibe.emoji)
                                    .font(.system(size: 28))
                                Text(vibe.rawValue)
                                    .font(.subheadline.bold())
                                    .foregroundStyle(isDisabled ? .white.opacity(0.3) : .white)
                                    .lineLimit(1)
                                Text(vibe.tagline)
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(isDisabled ? 0.2 : 0.5))
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(14)
                            .background(isSelected ? Color.vesperAccent.opacity(0.15) : Color.vesperCard)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(isSelected ? Color.vesperAccent : Color.vesperBorder, lineWidth: isSelected ? 1.5 : 1)
                            )
                            .opacity(isDisabled ? 0.5 : 1.0)
                        }
                        .disabled(isDisabled)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }

            if !selectedVibes.isEmpty {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onContinue()
                } label: {
                    Text("Continue")
                        .vesperPrimaryButton()
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .vesperBackground()
    }
}

// MARK: - Audience selection screen

struct DatingAudienceView: View {
    @Binding var selectedAudience: DatingAudience
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 6) {
                Text("Who are you trying to attract?")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text("Vesper tailors the reasoning and picks accordingly")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 100)
            .padding(.horizontal, 28)

            VStack(spacing: 12) {
                ForEach(DatingAudience.allCases, id: \.self) { audience in
                    let isSelected = selectedAudience == audience
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        selectedAudience = audience
                    } label: {
                        HStack(spacing: 16) {
                            Text(audience.emoji)
                                .font(.system(size: 30))
                                .frame(width: 44)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(audience.rawValue)
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                Text(audience.tagline)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.vesperAccent)
                                    .font(.title3)
                            }
                        }
                        .padding(18)
                        .background(isSelected ? Color.vesperAccent.opacity(0.12) : Color.vesperCard)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(isSelected ? Color.vesperAccent : Color.vesperBorder, lineWidth: isSelected ? 1.5 : 1)
                        )
                    }
                    .padding(.horizontal, 24)
                }
            }

            Spacer()

            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onContinue()
            } label: {
                Text("Continue")
                    .vesperPrimaryButton()
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .vesperBackground()
    }
}

#Preview {
    DatingVibeSelectionView(selectedVibes: .constant([])) {}
}
