//
//  CategorySelectionView.swift
//  Vesper
//
//  Created by Dennis Mach on 4/1/26.
//

import SwiftUI

enum PhotoCategory: String, CaseIterable {
    case mugshot = "Mugshot"
    case vacation = "Vacation"
    case concert = "Concert"
    case nature = "Nature"
    case edgy = "Edgy"

    var icon: String {
        switch self {
        case .mugshot: return "person.crop.square"
        case .vacation: return "sun.horizon"
        case .concert: return "music.mic"
        case .nature: return "leaf"
        case .edgy: return "bolt"
        }
    }

    var displayName: String {
        switch self {
        case .mugshot: return "Portrait / Headshot"
        case .vacation: return "Vacation"
        case .concert: return "Concert"
        case .nature: return "Nature"
        case .edgy: return "Edgy"
        }
    }

    var description: String {
        switch self {
        case .mugshot: return "Clean, sharp, straight-on"
        case .vacation: return "Bright, happy, location"
        case .concert: return "Energy, atmosphere, crowd"
        case .nature: return "Outdoors, natural light"
        case .edgy: return "Dramatic, high contrast"
        }
    }
}

struct CategorySelectionView: View {
    @Binding var selectedCategory: PhotoCategory?
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 6) {
                Text("What kind of photos?")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("We'll tailor scoring to the scene")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.top, 100)

            VStack(spacing: 10) {
                ForEach(PhotoCategory.allCases, id: \.self) { category in
                    Button {
                        selectedCategory = category
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: category.icon)
                                .font(.title2)
                                .foregroundStyle(selectedCategory == category ? Color.vesperAccent : .white.opacity(0.6))
                                .frame(width: 36)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(category.displayName)
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                Text(category.description)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.5))
                            }

                            Spacer()

                            if selectedCategory == category {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.vesperAccent)
                            }
                        }
                        .padding(16)
                        .background(selectedCategory == category ? Color.vesperAccent.opacity(0.12) : Color.vesperCard)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(selectedCategory == category ? Color.vesperAccent.opacity(0.4) : Color.vesperBorder, lineWidth: 1)
                        )
                    }
                    .padding(.horizontal, 24)
                }
            }

            Spacer()

            if selectedCategory != nil {
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
    CategorySelectionView(selectedCategory: .constant(.vacation)) {}
}
