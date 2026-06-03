//
//  OutfitSetupView.swift
//  Vesper
//
//  Outfit check setup: user picks an occasion and what they want the AI to focus on.
//  The combination generates a CLIP prompt used to rank outfit photos.
//

import SwiftUI

// MARK: - Enums

enum OutfitOccasion: String, CaseIterable {
    case casual      = "Casual / Everyday"
    case date        = "Date night"
    case work        = "Work / Office"
    case formal      = "Formal / Black tie"
    case outdoor     = "Outdoor / Active"
    case party       = "Party / Night out"

    var emoji: String {
        switch self {
        case .casual:   return "👟"
        case .date:     return "🌹"
        case .work:     return "💼"
        case .formal:   return "🎩"
        case .outdoor:  return "🏔️"
        case .party:    return "🎉"
        }
    }

    var tagline: String {
        switch self {
        case .casual:   return "Weekend vibes, everyday look"
        case .date:     return "Evening out, romantic setting"
        case .work:     return "Professional, polished"
        case .formal:   return "Black tie, gala, wedding"
        case .outdoor:  return "Hiking, sports, adventure"
        case .party:    return "Clubbing, festival, birthday"
        }
    }
}

enum OutfitFocus: String, CaseIterable {
    case overall     = "Overall fit & look"
    case colorMatch  = "Color harmony"
    case confidence  = "How confident I look"
    case styleMatch  = "Does it suit the occasion?"

    var emoji: String {
        switch self {
        case .overall:     return "✨"
        case .colorMatch:  return "🎨"
        case .confidence:  return "💪"
        case .styleMatch:  return "🎯"
        }
    }

    var tagline: String {
        switch self {
        case .overall:     return "Best overall outfit photo"
        case .colorMatch:  return "Colors that complement your look"
        case .confidence:  return "Photos where you look most confident"
        case .styleMatch:  return "How well the outfit fits the vibe"
        }
    }

    /// CLIP prompt combining the focus and occasion signals.
    func clipPrompt(occasion: OutfitOccasion) -> String {
        switch self {
        case .overall:
            return "well-dressed person stylish outfit \(occasion.rawValue.lowercased()) good fit fashion"
        case .colorMatch:
            return "outfit color harmony complementary colors well-coordinated palette \(occasion.rawValue.lowercased())"
        case .confidence:
            return "confident person standing tall good posture great outfit \(occasion.rawValue.lowercased()) self-assured"
        case .styleMatch:
            return "appropriate outfit for \(occasion.rawValue.lowercased()) well-dressed stylish matching vibe"
        }
    }
}

// MARK: - View

struct OutfitSetupView: View {
    @Binding var selectedOccasion: OutfitOccasion
    @Binding var selectedFocus: OutfitFocus
    let onContinue: () -> Void

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 6) {
                    Text("Outfit Check")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text("Tell us the occasion and what matters most")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 100)
                .padding(.horizontal, 28)

                // Occasion
                VStack(alignment: .leading, spacing: 12) {
                    Text("What's the occasion?")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 24)

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(OutfitOccasion.allCases, id: \.self) { occ in
                            let isSelected = selectedOccasion == occ
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                selectedOccasion = occ
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(occ.emoji).font(.system(size: 26))
                                    Text(occ.rawValue)
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Text(occ.tagline)
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.5))
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .padding(14)
                                .background(isSelected ? Color.vesperAccent.opacity(0.15) : Color.vesperCard)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14)
                                    .stroke(isSelected ? Color.vesperAccent : Color.vesperBorder,
                                            lineWidth: isSelected ? 1.5 : 1))
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }

                // Focus
                VStack(alignment: .leading, spacing: 12) {
                    Text("What should I focus on?")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 24)

                    VStack(spacing: 10) {
                        ForEach(OutfitFocus.allCases, id: \.self) { focus in
                            let isSelected = selectedFocus == focus
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                selectedFocus = focus
                            } label: {
                                HStack(spacing: 16) {
                                    Text(focus.emoji).font(.title3).frame(width: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(focus.rawValue).font(.subheadline.bold()).foregroundStyle(.white)
                                        Text(focus.tagline).font(.caption).foregroundStyle(.white.opacity(0.5))
                                    }
                                    Spacer()
                                    if isSelected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.vesperAccent)
                                    }
                                }
                                .padding(16)
                                .background(isSelected ? Color.vesperAccent.opacity(0.12) : Color.vesperCard)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14)
                                    .stroke(isSelected ? Color.vesperAccent : Color.vesperBorder,
                                            lineWidth: isSelected ? 1.5 : 1))
                            }
                            .padding(.horizontal, 24)
                        }
                    }
                }

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

#Preview {
    OutfitSetupView(
        selectedOccasion: .constant(.casual),
        selectedFocus: .constant(.overall)
    ) {}
}
