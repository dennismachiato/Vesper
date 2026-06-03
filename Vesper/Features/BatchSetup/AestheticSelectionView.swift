//
//  AestheticSelectionView.swift
//  Vesper
//
//  Created by Dennis Mach on 4/1/26.
//

import SwiftUI

enum AestheticStyle: String, CaseIterable {
    case brightAiry = "Bright & Airy"
    case darkMoody = "Dark & Moody"
    case warmGolden = "Warm & Golden"
    case cleanMinimal = "Clean & Minimal"
    case boldDramatic = "Bold & Dramatic"
    case candidRaw = "Candid & Raw"

    var icon: String {
        switch self {
        case .brightAiry: return "sun.max"
        case .darkMoody: return "moon.stars"
        case .warmGolden: return "sunset"
        case .cleanMinimal: return "square"
        case .boldDramatic: return "theatermask.and.paintbrush"
        case .candidRaw: return "camera"
        }
    }

    var description: String {
        switch self {
        case .brightAiry: return "Light, soft, and open"
        case .darkMoody: return "Shadow, depth, and contrast"
        case .warmGolden: return "Golden hour, cozy tones"
        case .cleanMinimal: return "Sharp, even, no distractions"
        case .boldDramatic: return "Strong, striking, editorial"
        case .candidRaw: return "Natural, unposed, in the moment"
        }
    }
}

struct AestheticSelectionView: View {
    @Binding var selectedAesthetics: [AestheticStyle]
    let onContinue: () -> Void

    private let maxSelections = 3
    let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Text("What's the vibe?")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("Pick up to 3 — we'll find photos that match any of them")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)

                // Selection counter
                if !selectedAesthetics.isEmpty {
                    Text("\(selectedAesthetics.count) of \(maxSelections) selected")
                        .font(.caption.bold())
                        .foregroundStyle(Color.vesperAccent)
                        .padding(.top, 2)
                }
            }
            .padding(.top, 100)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(AestheticStyle.allCases, id: \.self) { aesthetic in
                    let isSelected = selectedAesthetics.contains(aesthetic)
                    let isDisabled = !isSelected && selectedAesthetics.count >= maxSelections
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        if isSelected {
                            selectedAesthetics.removeAll { $0 == aesthetic }
                        } else if selectedAesthetics.count < maxSelections {
                            selectedAesthetics.append(aesthetic)
                        }
                    } label: {
                        VStack(spacing: 10) {
                            Image(systemName: aesthetic.icon)
                                .font(.title)
                                .foregroundStyle(isSelected ? Color.vesperAccent : .white.opacity(isDisabled ? 0.25 : 0.7))
                            Text(aesthetic.rawValue)
                                .font(.subheadline.bold())
                                .foregroundStyle(isDisabled ? .white.opacity(0.3) : .white)
                                .multilineTextAlignment(.center)
                            Text(aesthetic.description)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(isDisabled ? 0.2 : 0.45))
                                .multilineTextAlignment(.center)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(16)
                        .background(isSelected ? Color.vesperAccent.opacity(0.12) : Color.vesperCard)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(isSelected ? Color.vesperAccent.opacity(0.6) : Color.vesperBorder, lineWidth: isSelected ? 1.5 : 1)
                        )
                        .opacity(isDisabled ? 0.5 : 1.0)
                    }
                    .disabled(isDisabled)
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            if !selectedAesthetics.isEmpty {
                Button {
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
    AestheticSelectionView(selectedAesthetics: .constant([.darkMoody])) {}
}
