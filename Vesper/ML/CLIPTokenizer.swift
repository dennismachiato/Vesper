//
//  CLIPTokenizer.swift
//  Vesper
//
//  Minimal CLIP BPE tokenizer for short text prompts.
//  Vocabulary and merges are the standard OpenAI CLIP vocab (49408 tokens).
//

import Foundation

class CLIPTokenizer {
    static let shared = CLIPTokenizer()

    private let vocabURL = Bundle.main.url(forResource: "clip_vocab", withExtension: "json")
    private let mergesURL = Bundle.main.url(forResource: "clip_merges", withExtension: "txt")

    private var encoder: [String: Int] = [:]
    private var decoder: [Int: String] = [:]
    private var bpeRanks: [BPEPair: Int] = [:]
    private var cache: [String: [String]] = [:]

    private let sotToken = 49406
    private let eotToken = 49407
    private let contextLength = 77

    struct BPEPair: Hashable {
        let first: String
        let second: String
    }

    init() {
        loadVocabAndMerges()
    }

    func tokenize(_ text: String) -> [Int] {
        let cleaned = text.lowercased().trimmingCharacters(in: .whitespaces)
        let words = tokenizeToWords(cleaned)

        var tokens = [sotToken]
        for word in words {
            let bpeTokens = bpe(word)
            for t in bpeTokens {
                if let id = encoder[t] {
                    tokens.append(id)
                }
            }
            if tokens.count >= contextLength - 1 { break }
        }
        tokens.append(eotToken)

        // Pad to contextLength with zeros
        while tokens.count < contextLength {
            tokens.append(0)
        }
        return Array(tokens.prefix(contextLength))
    }

    private func tokenizeToWords(_ text: String) -> [String] {
        // Simple whitespace + punctuation split
        var words: [String] = []
        var current = ""
        for char in text {
            if char.isLetter || char.isNumber || char == "'" {
                current.append(char)
            } else {
                if !current.isEmpty {
                    words.append(current + "</w>")
                    current = ""
                }
                if !char.isWhitespace {
                    words.append(String(char) + "</w>")
                }
            }
        }
        if !current.isEmpty {
            words.append(current + "</w>")
        }
        return words
    }

    private func bpe(_ token: String) -> [String] {
        if let cached = cache[token] { return cached }

        if bpeRanks.isEmpty {
            // No merges loaded — return character-level tokens
            return token.map { String($0) }
        }

        var word = token.map { String($0) }
        // Replace last char+</w> with single token
        if word.count > 3 {
            let last = word.removeLast()
            word[word.count - 1] = word[word.count - 1] + last
        }

        while word.count > 1 {
            var bestPair: BPEPair? = nil
            var bestRank = Int.max

            for i in 0..<(word.count - 1) {
                let pair = BPEPair(first: word[i], second: word[i + 1])
                if let rank = bpeRanks[pair], rank < bestRank {
                    bestRank = rank
                    bestPair = pair
                }
            }

            guard let pair = bestPair else { break }

            var newWord: [String] = []
            var i = 0
            while i < word.count {
                if i < word.count - 1 && word[i] == pair.first && word[i + 1] == pair.second {
                    newWord.append(pair.first + pair.second)
                    i += 2
                } else {
                    newWord.append(word[i])
                    i += 1
                }
            }
            word = newWord
        }

        cache[token] = word
        return word
    }

    private func loadVocabAndMerges() {
        // Load vocab
        if let url = vocabURL,
           let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Int] {
            encoder = json
            decoder = Dictionary(uniqueKeysWithValues: json.map { ($1, $0) })
        }

        // Load merges
        if let url = mergesURL,
           let content = try? String(contentsOf: url, encoding: .utf8) {
            let lines = content.components(separatedBy: "\n").dropFirst() // skip header
            for (rank, line) in lines.enumerated() {
                let parts = line.split(separator: " ")
                if parts.count == 2 {
                    bpeRanks[BPEPair(first: String(parts[0]), second: String(parts[1]))] = rank
                }
            }
        }
    }
}
