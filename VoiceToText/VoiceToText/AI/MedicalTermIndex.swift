import Foundation
import os

/// Thread-safe, immutable index of medical terms for streaming ASR correction.
/// Built from the bundled medical-terms-en.txt (98K terms).
final class MedicalTermIndex: Sendable {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "MedicalTermIndex")

    /// All terms, lowercased — O(1) exact match
    let termSet: Set<String>

    /// Multi-word terms keyed by their first word (lowercased).
    /// e.g. "atrial" -> ["atrial fibrillation", "atrial flutter", ...]
    let multiWordByFirst: [String: [String]]

    /// Terms >= 6 chars, sorted alphabetically — for fuzzy prefix-narrowed search
    let sortedLongTerms: [String]

    /// Curated high-value terms for Whisper prompt biasing (~150 terms)
    let promptHintTerms: [String]

    /// Common English stopwords that should never be corrected
    static let stopwords: Set<String> = [
        "the", "be", "to", "of", "and", "a", "in", "that", "have", "i",
        "it", "for", "not", "on", "with", "he", "as", "you", "do", "at",
        "this", "but", "his", "by", "from", "they", "we", "say", "her",
        "she", "or", "an", "will", "my", "one", "all", "would", "there",
        "their", "what", "so", "up", "out", "if", "about", "who", "get",
        "which", "go", "me", "when", "make", "can", "like", "time", "no",
        "just", "him", "know", "take", "people", "into", "year", "your",
        "good", "some", "could", "them", "see", "other", "than", "then",
        "now", "look", "only", "come", "its", "over", "think", "also",
        "back", "after", "use", "two", "how", "our", "work", "first",
        "well", "way", "even", "new", "want", "because", "any", "these",
        "give", "day", "most", "us", "was", "were", "been", "has", "had",
        "did", "does", "are", "is", "am", "being", "having", "doing",
        "should", "could", "would", "might", "must", "shall", "may",
        "very", "still", "already", "before", "between", "each", "every",
        "through", "during", "without", "within", "along", "around",
        "again", "where", "while", "since", "until", "more", "much",
        "many", "such", "same", "another", "different", "under", "above",
        "really", "right", "three", "four", "five", "never", "always",
        "often", "sometimes", "usually", "actually", "probably", "perhaps",
        "however", "though", "although", "whether", "either", "neither",
        "something", "nothing", "everything", "anything", "someone",
        "everyone", "anyone", "morning", "evening", "afternoon", "tonight",
        "today", "yesterday", "tomorrow", "little", "large", "small",
        "going", "getting", "making", "taking", "coming", "saying",
        "looking", "working", "trying", "using", "finding", "giving",
        "telling", "asking", "feeling", "thinking", "knowing", "seeing",
        "believe", "become", "begin", "brought", "called", "change",
        "enough", "found", "great", "house", "important", "keep", "last",
        "left", "life", "long", "might", "number", "place", "point",
        "problem", "program", "question", "quite", "rather", "result",
        "running", "second", "several", "start", "state", "thing",
        "together", "turned", "against", "almost", "available", "certain",
        "continue", "current", "early", "following", "further", "general",
        "having", "include", "likely", "looking", "possible", "present",
        "public", "recent", "report", "review", "simply", "social",
        "special", "wanted", "wasn", "didn", "doesn", "isn", "aren",
        "hasn", "hadn", "won", "wouldn", "shouldn", "couldn",
    ]

    private init(
        termSet: Set<String>,
        multiWordByFirst: [String: [String]],
        sortedLongTerms: [String],
        promptHintTerms: [String]
    ) {
        self.termSet = termSet
        self.multiWordByFirst = multiWordByFirst
        self.sortedLongTerms = sortedLongTerms
        self.promptHintTerms = promptHintTerms
    }

    /// Load and build the index from the bundled resource file + DomainContext vocabulary.
    static func load() -> MedicalTermIndex? {
        let start = CFAbsoluteTimeGetCurrent()

        guard let url = Bundle.main.url(forResource: "medical-terms-en", withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            logger.error("Failed to load medical-terms-en.txt from bundle")
            return nil
        }

        let rawTerms = contents.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Build lowercased term set
        var termSet = Set<String>(minimumCapacity: rawTerms.count)
        for term in rawTerms {
            termSet.insert(term.lowercased())
        }

        // Also add DomainContext.medical.promptVocabulary (these are curated high-value terms)
        for term in DomainContext.medical.promptVocabulary {
            termSet.insert(term.lowercased())
        }

        // Build multi-word index
        var multiWordByFirst: [String: [String]] = [:]
        for term in termSet where term.contains(" ") {
            let words = term.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let first = words.first else { continue }
            let key = String(first)
            multiWordByFirst[key, default: []].append(term)
        }

        // Build sorted long-term list for fuzzy search (only single words >= 6 chars)
        let sortedLongTerms = termSet
            .filter { !$0.contains(" ") && $0.count >= 6 }
            .sorted()

        // Build prompt hint terms: DomainContext vocabulary + top common medications
        let topMedications: [String] = [
            "acetaminophen", "amoxicillin", "atorvastatin", "azithromycin",
            "ciprofloxacin", "clopidogrel", "diazepam", "doxycycline",
            "escitalopram", "furosemide", "gabapentin", "hydrochlorothiazide",
            "ibuprofen", "insulin", "levothyroxine", "lisinopril",
            "lorazepam", "losartan", "metformin", "metoprolol",
            "morphine", "naproxen", "omeprazole", "ondansetron",
            "oxycodone", "pantoprazole", "prednisone", "propranolol",
            "rosuvastatin", "sertraline", "simvastatin", "tramadol",
            "vancomycin", "warfarin", "zolpidem",
            // Common conditions
            "aneurysm", "appendicitis", "arrhythmia", "bronchitis",
            "cardiomyopathy", "cellulitis", "cholecystitis", "colitis",
            "concussion", "conjunctivitis", "cystitis", "dermatitis",
            "diverticulitis", "embolism", "encephalitis", "endocarditis",
            "fibromyalgia", "gastritis", "glaucoma", "hemorrhage",
            "hepatitis", "meningitis", "myocarditis", "nephritis",
            "neuropathy", "osteoporosis", "pancreatitis", "pericarditis",
            "pharyngitis", "pneumonia", "pneumothorax", "sepsis",
            "sinusitis", "thrombosis", "tonsillitis", "vasculitis",
        ]

        var hintSet = Set(DomainContext.medical.promptVocabulary.map { $0.lowercased() })
        for med in topMedications {
            hintSet.insert(med.lowercased())
        }
        let promptHintTerms = Array(hintSet).sorted()

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        logger.notice("MedicalTermIndex built: \(termSet.count) terms, \(multiWordByFirst.count) multi-word keys, \(sortedLongTerms.count) fuzzy candidates, \(promptHintTerms.count) prompt hints in \(String(format: "%.1f", elapsed * 1000))ms")

        return MedicalTermIndex(
            termSet: termSet,
            multiWordByFirst: multiWordByFirst,
            sortedLongTerms: sortedLongTerms,
            promptHintTerms: promptHintTerms
        )
    }

    // MARK: - Fuzzy Matching

    /// Find the best fuzzy match for a word in the index.
    /// Returns nil if no match within edit distance threshold.
    func fuzzyMatch(_ word: String) -> (term: String, editDistance: Int)? {
        let lower = word.lowercased()
        guard lower.count >= 6 else { return nil }
        guard !Self.stopwords.contains(lower) else { return nil }

        // Binary search to find terms sharing same first 2 chars
        let prefix = String(lower.prefix(2))
        let startIdx = sortedLongTerms.partitionIndex { $0 >= prefix }
        let endPrefix = prefix.incrementedLastChar()

        var bestTerm: String?
        var bestDist = Int.max
        let maxDist = min(2, lower.count / 4)

        for i in startIdx..<sortedLongTerms.count {
            let term = sortedLongTerms[i]
            if let endPrefix, term >= endPrefix { break }

            // Quick length filter: edit distance can't be less than length difference
            let lenDiff = abs(term.count - lower.count)
            if lenDiff > maxDist { continue }

            let dist = levenshteinDistance(lower, term)
            if dist <= maxDist && dist < bestDist {
                bestDist = dist
                bestTerm = term
                if dist == 0 { break } // exact match found
            }
        }

        guard let match = bestTerm, bestDist > 0 else { return nil } // dist==0 means already in termSet
        // Confidence check: 1 - editDist/len >= 0.7
        let confidence = 1.0 - Double(bestDist) / Double(lower.count)
        guard confidence >= 0.7 else { return nil }

        return (match, bestDist)
    }

    /// Check if a multi-word medical term starts at the given position in the word array.
    func checkMultiWord(words: [String], startIndex: Int) -> String? {
        guard startIndex < words.count else { return nil }
        let firstWord = words[startIndex].lowercased()
            .trimmingCharacters(in: .punctuationCharacters)
        guard let candidates = multiWordByFirst[firstWord] else { return nil }

        // Check 2-word and 3-word combinations
        for candidate in candidates {
            let candidateWords = candidate.split(separator: " ").map { String($0) }
            let windowEnd = startIndex + candidateWords.count
            guard windowEnd <= words.count else { continue }

            let window = words[startIndex..<windowEnd].map {
                $0.lowercased().trimmingCharacters(in: .punctuationCharacters)
            }
            if window == candidateWords {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Levenshtein Distance

    private func levenshteinDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count

        if m == 0 { return n }
        if n == 0 { return m }

        var dp = Array(0...n)
        for i in 1...m {
            var prev = dp[0]
            dp[0] = i
            for j in 1...n {
                let temp = dp[j]
                if aChars[i - 1] == bChars[j - 1] {
                    dp[j] = prev
                } else {
                    dp[j] = min(prev, dp[j], dp[j - 1]) + 1
                }
                prev = temp
            }
        }
        return dp[n]
    }
}

// MARK: - String Helpers

private extension Array where Element == String {
    /// Binary search: return first index where predicate is true
    func partitionIndex(where predicate: (String) -> Bool) -> Int {
        var lo = 0
        var hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if predicate(self[mid]) {
                hi = mid
            } else {
                lo = mid + 1
            }
        }
        return lo
    }
}

private extension String {
    /// Return the string with its last character incremented (for range-end in sorted search).
    /// Returns nil if it can't be incremented.
    func incrementedLastChar() -> String? {
        guard !isEmpty else { return nil }
        var chars = Array(self)
        guard let last = chars.last, let scalar = last.unicodeScalars.first else { return nil }
        let next = Unicode.Scalar(scalar.value + 1)
        guard let nextScalar = next else { return nil }
        chars[chars.count - 1] = Character(nextScalar)
        return String(chars)
    }
}
