//
//  StyleQuizView.swift
//  Vesper
//
//  Cold-start style quiz: shown once after onboarding when the user has zero feedback.
//  Presents 4 pairwise style preference questions to bootstrap the taste profile.
//  Each answer inserts two synthetic PhotoFeedback entries — a "like" for the preferred
//  style and a "dislike" for the rejected one — using CLIP text embeddings as proxies.
//

import SwiftUI
import SwiftData
import OSLog

private let styleQuizLogger = Logger(subsystem: "Vesper", category: "StyleQuiz")

private struct StylePair {
    let question: String
    let optionA: StyleOption
    let optionB: StyleOption
}

private struct StyleOption {
    let emoji: String
    let label: String
    let description: String
    let clipPrompt: String  // used to generate a CLIP text embedding as proxy feedback
}

private let quizPairs: [StylePair] = [
    StylePair(
        question: "Which style speaks to you?",
        optionA: StyleOption(
            emoji: "☀️", label: "Bright & Airy",
            description: "Light, clean, high-key",
            clipPrompt: "bright airy light clean minimal aesthetic photo"
        ),
        optionB: StyleOption(
            emoji: "🌙", label: "Dark & Moody",
            description: "Dramatic, deep shadows",
            clipPrompt: "dark moody cinematic dramatic shadow low light photo"
        )
    ),
    StylePair(
        question: "Portraits — what do you prefer?",
        optionA: StyleOption(
            emoji: "😊", label: "Natural & Candid",
            description: "Genuine moments, unposed",
            clipPrompt: "candid natural unposed genuine smile portrait photo"
        ),
        optionB: StyleOption(
            emoji: "📸", label: "Polished & Posed",
            description: "Composed, deliberate shots",
            clipPrompt: "polished posed deliberate composed professional portrait photo"
        )
    ),
    StylePair(
        question: "What do you shoot most?",
        optionA: StyleOption(
            emoji: "🌿", label: "Nature & Landscapes",
            description: "Outdoors, scenery, travel",
            clipPrompt: "nature landscape outdoor scenery travel scenic photo"
        ),
        optionB: StyleOption(
            emoji: "🧑‍🤝‍🧑", label: "People & Moments",
            description: "Faces, events, memories",
            clipPrompt: "people faces social moments event portrait candid photo"
        )
    ),
    StylePair(
        question: "Color or minimal?",
        optionA: StyleOption(
            emoji: "🎨", label: "Vibrant Colors",
            description: "Bold, saturated, expressive",
            clipPrompt: "vibrant colorful saturated bold expressive colors photo"
        ),
        optionB: StyleOption(
            emoji: "🖤", label: "Muted & Film-Like",
            description: "Faded tones, analog feel",
            clipPrompt: "muted desaturated film analog fade vintage tones photo"
        )
    )
]

struct StyleQuizView: View {
    let onComplete: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var currentPair = 0
    @State private var choiceMade: Bool? = nil   // true = A, false = B
    @State private var isFinishing = false

    var body: some View {
        ZStack {
            LinearGradient.vesperBg.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                VStack(spacing: 8) {
                    Text("Quick Style Check")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text("4 questions · helps Vesper learn your taste from day one")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)

                    // Progress dots
                    HStack(spacing: 6) {
                        ForEach(0..<quizPairs.count, id: \.self) { i in
                            Capsule()
                                .fill(i <= currentPair ? Color.vesperAccent : Color.vesperAccent.opacity(0.2))
                                .frame(width: i == currentPair ? 20 : 6, height: 6)
                                .animation(.easeInOut(duration: 0.25), value: currentPair)
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(.top, 80)
                .padding(.horizontal, 28)

                Spacer()

                // Question
                let pair = quizPairs[currentPair]
                VStack(spacing: 20) {
                    Text(pair.question)
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    HStack(spacing: 12) {
                        optionCard(pair.optionA, isA: true)
                        optionCard(pair.optionB, isA: false)
                    }
                    .padding(.horizontal, 20)
                }

                Spacer()

                // Skip
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    advance(choice: nil)
                } label: {
                    Text("Skip")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.3))
                }
                .padding(.bottom, 40)
            }
        }
    }

    @ViewBuilder
    private func optionCard(_ option: StyleOption, isA: Bool) -> some View {
        let chosen = choiceMade.map { $0 == isA }
        Button {
            guard choiceMade == nil else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            choiceMade = isA
            saveFeedback(preferred: option, rejected: isA ? quizPairs[currentPair].optionB : quizPairs[currentPair].optionA)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                advance(choice: isA)
            }
        } label: {
            VStack(spacing: 10) {
                Text(option.emoji)
                    .font(.system(size: 36))
                Text(option.label)
                    .font(.headline)
                    .foregroundStyle(chosen == true ? Color.vesperAccent : .white)
                Text(option.description)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 130)
            .padding(16)
            .background(chosen == true ? Color.vesperAccent.opacity(0.15) : Color.vesperCard)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(chosen == true ? Color.vesperAccent : Color.vesperBorder,
                            lineWidth: chosen == true ? 1.5 : 1)
            )
            .scaleEffect(chosen == false ? 0.95 : 1.0)
            .animation(.spring(response: 0.3), value: choiceMade)
        }
        .disabled(choiceMade != nil)
    }

    private func saveFeedback(preferred: StyleOption, rejected: StyleOption) {
        let preferredEmb = CLIPTextEmbedder.shared?.embed(prompt: preferred.clipPrompt) ?? []
        let rejectedEmb  = CLIPTextEmbedder.shared?.embed(prompt: rejected.clipPrompt)  ?? []

        if !preferredEmb.isEmpty {
            let like = PhotoFeedback(liked: true, imageEmbedding: preferredEmb, purposeTag: "quiz")
            modelContext.insert(like)
        }
        if !rejectedEmb.isEmpty {
            let dislike = PhotoFeedback(liked: false, imageEmbedding: rejectedEmb, purposeTag: "quiz")
            modelContext.insert(dislike)
        }
        do {
            try modelContext.save()
        } catch {
            styleQuizLogger.error("Save style quiz feedback failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func advance(choice: Bool?) {
        let next = currentPair + 1
        if next >= quizPairs.count {
            onComplete()
        } else {
            withAnimation(.easeInOut(duration: 0.25)) {
                currentPair = next
                choiceMade = nil
            }
        }
    }
}

#Preview {
    StyleQuizView {}
}
