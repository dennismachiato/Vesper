//
//  PromptInputView.swift
//  Vesper

import SwiftUI

struct PromptInputView: View {
    @Binding var promptText: String
    let onContinue: () -> Void
    @FocusState private var isFocused: Bool
    @State private var recentPrompts: [String] = []

    // CLIP text embeddings get saturated well below 77 tokens; this also prevents
    // the user from pasting an essay that silently gets truncated mid-word.
    private let maxPromptChars = 140
    private let minPromptChars = 3

    /// True when the current prompt is long enough to yield a meaningful CLIP embedding.
    private var isPromptValid: Bool {
        promptText.trimmingCharacters(in: .whitespacesAndNewlines).count >= minPromptChars
    }

    private let examples = [
        "eyes open",
        "natural smile",
        "looking at camera",
        "golden hour lighting",
        "soft lighting",
        "sharp focus",
        "clean background",
        "bokeh background",
        "moody and dramatic",
        "high contrast",
        "candid moment",
        "facing camera",
        "great scenery",
        "no people",
        "black and white",
        "vibrant colors",
        "minimalist",
        "cinematic",
        "silhouette",
        "rule of thirds",
        "wide angle",
        "close up",
        "motion blur",
        "night shot",
        "street photography"
    ]

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Text("Describe what you want")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("Tell the AI exactly what to look for")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.top, 100)

            VStack(alignment: .leading, spacing: 6) {
                TextField("e.g. best food photos, soft lighting...", text: $promptText, axis: .vertical)
                    .lineLimit(3...5)
                    .font(.body)
                    .foregroundStyle(.white)
                    .tint(Color.vesperAccent)
                    .padding()
                    .background(Color.vesperCard)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(isFocused ? Color.vesperAccent.opacity(0.5) : Color.vesperBorder, lineWidth: 1)
                    )
                    .focused($isFocused)
                    .onChange(of: promptText) { _, new in
                        // Hard cap protects the CLIP token budget and keeps the
                        // on-screen preview from growing unbounded.
                        if new.count > maxPromptChars {
                            promptText = String(new.prefix(maxPromptChars))
                        }
                    }

                // Length indicator — turns amber near the cap, lets people see
                // they're about to hit the limit before the text silently stops growing.
                HStack {
                    Spacer()
                    Text("\(promptText.count)/\(maxPromptChars)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(promptText.count >= maxPromptChars - 10
                                         ? Color.orange.opacity(0.8)
                                         : Color.white.opacity(0.35))
                }
            }
            .padding(.horizontal, 28)

            // Recent prompts
            if !recentPrompts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.horizontal, 28)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(recentPrompts, id: \.self) { prompt in
                                Button {
                                    promptText = prompt
                                    isFocused = false
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "clock")
                                            .font(.caption2)
                                            .foregroundStyle(Color.vesperAccent.opacity(0.6))
                                        Text(prompt)
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.8))
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .vesperCard(cornerRadius: 20)
                                }
                            }
                        }
                        .padding(.horizontal, 28)
                    }
                }
            }

            // Example prompts
            VStack(alignment: .leading, spacing: 8) {
                Text("Examples")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 28)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(examples, id: \.self) { example in
                            Button {
                                let trimmed = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
                                promptText = trimmed.isEmpty ? example : "\(trimmed), \(example)"
                                isFocused = false
                            } label: {
                                Text(example)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.8))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .vesperCard(cornerRadius: 20)
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                }
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    isFocused = false
                    savePromptToHistory(promptText)
                    onContinue()
                } label: {
                    Text("Find My Best Shots")
                        .vesperPrimaryButton()
                        .opacity(isPromptValid ? 1.0 : 0.45)
                }
                .disabled(!isPromptValid)
                .accessibilityHint(isPromptValid
                                   ? "Runs the photo ranker with your prompt"
                                   : "Type at least \(minPromptChars) characters first")

                Button {
                    promptText = ""
                    isFocused = false
                    onContinue()
                } label: {
                    Text("Skip")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .vesperBackground()
        .onTapGesture { isFocused = false }
        .onAppear { recentPrompts = PromptHistory.load() }
    }

    private func savePromptToHistory(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        PromptHistory.save(trimmed)
        recentPrompts = PromptHistory.load()
    }
}

// MARK: - Prompt history persistence

enum PromptHistory {
    private static let key = "vesper_promptHistory"
    private static let maxCount = 8

    static func load() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let prompts = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return prompts
    }

    static func save(_ prompt: String) {
        var history = load()
        history.removeAll { $0 == prompt }   // deduplicate
        history.insert(prompt, at: 0)
        history = Array(history.prefix(maxCount))
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

#Preview {
    PromptInputView(promptText: .constant("")) {}
}
