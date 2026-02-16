#if DEBUG
import Foundation
import os

// MARK: - LLM Cleanup Test Harness

/// Tests the LLM post-processing pipeline with known inputs to verify
/// the model cleans text rather than answering/interpreting it.
struct LLMCleanupTestHarness {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "LLMCleanupTest")

    // MARK: - Test Case Definition

    enum Category: String, CaseIterable {
        case question = "question"
        case medical = "medical"
        case grammar = "grammar"
        case technical = "technical"
        case mixed = "mixed"
    }

    struct TestCase {
        let category: Category
        let input: String
        let expected: String
    }

    struct TestResult {
        let testCase: TestCase
        let output: String
        let latency: TimeInterval
        let passed: Bool
        let failures: [String]
    }

    // MARK: - Test Cases

    static let testCases: [TestCase] = [
        // Questions — must return cleaned question, NOT an answer
        TestCase(
            category: .question,
            input: "can you send me the report by friday",
            expected: "Can you send me the report by Friday?"
        ),
        TestCase(
            category: .question,
            input: "what time is the meeting tomorrow",
            expected: "What time is the meeting tomorrow?"
        ),
        TestCase(
            category: .question,
            input: "did you finish the presentation yet",
            expected: "Did you finish the presentation yet?"
        ),
        TestCase(
            category: .question,
            input: "where should we go for dinner tonight",
            expected: "Where should we go for dinner tonight?"
        ),

        // Medical — must preserve terminology
        TestCase(
            category: .medical,
            input: "patient presents with acute cholecystitis needs stat cbc",
            expected: "Patient presents with acute cholecystitis, needs stat CBC."
        ),
        TestCase(
            category: .medical,
            input: "start metformin 500 milligrams twice daily for diabetes mellitus",
            expected: "Start metformin 500 milligrams twice daily for diabetes mellitus."
        ),
        TestCase(
            category: .medical,
            input: "blood pressure 140 over 90 heart rate 78 oxygen saturation 97 percent",
            expected: "Blood pressure 140/90, heart rate 78, oxygen saturation 97%."
        ),

        // Grammar cleanup
        TestCase(
            category: .grammar,
            input: "i went to the store and buyed some milk yesterday",
            expected: "I went to the store and bought some milk yesterday."
        ),
        TestCase(
            category: .grammar,
            input: "the weather is gonna be real nice tomorrow i think",
            expected: "The weather is going to be really nice tomorrow, I think."
        ),
        TestCase(
            category: .grammar,
            input: "me and him was talking about the project deadline",
            expected: "He and I were talking about the project deadline."
        ),

        // Technical — preserve jargon
        TestCase(
            category: .technical,
            input: "deploy the kubernetes cluster to the staging namespace",
            expected: "Deploy the Kubernetes cluster to the staging namespace."
        ),
        TestCase(
            category: .technical,
            input: "the api endpoint returns a 403 when the jwt token expires",
            expected: "The API endpoint returns a 403 when the JWT token expires."
        ),

        // Mixed/long — realistic dictation
        TestCase(
            category: .mixed,
            input: "so basically what happened was the server went down around 2 am and the on call engineer had to restart the database manually because the automated failover didnt trigger properly",
            expected: "So basically, what happened was the server went down around 2 AM, and the on-call engineer had to restart the database manually because the automated failover didn't trigger properly."
        ),
        TestCase(
            category: .mixed,
            input: "i need to send an email to sarah about the quarterly review and also remind mike that the deadline for the proposal is next wednesday",
            expected: "I need to send an email to Sarah about the quarterly review and also remind Mike that the deadline for the proposal is next Wednesday."
        ),
    ]

    // MARK: - Commentary Detection (mirrors LLMPostProcessor logic)

    private static let commentaryIndicators = [
        "it appears", "it seems", "i notice", "i'm sorry", "i cannot",
        "could you please", "please provide", "there is a", "there are",
        "does not align", "doesn't align", "discrepancy", "transcription error",
        "non-medical", "not a valid", "not clear", "i'd be happy",
        "here is the", "here's the", "sure,", "certainly",
    ]

    static func looksLikeCommentary(_ output: String, rawText: String) -> Bool {
        let lower = output.lowercased()
        for indicator in commentaryIndicators {
            if lower.hasPrefix(indicator) || lower.contains(". \(indicator)") {
                return true
            }
        }
        if output.count > rawText.count * 2 && rawText.count > 10 {
            return true
        }
        return false
    }

    // MARK: - WER Calculation

    /// Word Error Rate between two strings (0.0 = identical, 1.0 = completely different)
    static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let ref = reference.lowercased().split(separator: " ").map(String.init)
        let hyp = hypothesis.lowercased().split(separator: " ").map(String.init)

        guard !ref.isEmpty else { return hyp.isEmpty ? 0.0 : 1.0 }

        // Levenshtein distance on word arrays
        let m = ref.count, n = hyp.count
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }
        for i in 1...m {
            for j in 1...n {
                if ref[i - 1] == hyp[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]
                } else {
                    dp[i][j] = 1 + min(dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1])
                }
            }
        }
        return Double(dp[m][n]) / Double(m)
    }

    // MARK: - Evaluate Single Result

    static func evaluate(testCase: TestCase, output: String, latency: TimeInterval) -> TestResult {
        var failures: [String] = []

        // 1. Commentary check
        if looksLikeCommentary(output, rawText: testCase.input) {
            failures.append("COMMENTARY: output looks like commentary/meta-response")
        }

        // 2. Semantic similarity (WER < 50% vs expected — loose because cleanup changes words)
        let wer = wordErrorRate(reference: testCase.expected, hypothesis: output)
        if wer > 0.50 {
            failures.append("WER: \(String(format: "%.0f%%", wer * 100)) vs expected (threshold 50%)")
        }

        // 3. Reasonable length (0.4x–2.5x of input)
        let ratio = Double(output.count) / Double(max(testCase.input.count, 1))
        if ratio < 0.4 {
            failures.append("TOO_SHORT: output is \(String(format: "%.1fx", ratio)) of input length")
        } else if ratio > 2.5 {
            failures.append("TOO_LONG: output is \(String(format: "%.1fx", ratio)) of input length (likely hallucination)")
        }

        // 4. Timeout
        if latency > 15.0 {
            failures.append("TIMEOUT: \(String(format: "%.1fs", latency)) > 15s limit")
        }

        return TestResult(
            testCase: testCase,
            output: output,
            latency: latency,
            passed: failures.isEmpty,
            failures: failures
        )
    }

    // MARK: - Run All Tests

    @MainActor
    func run(llmConfig: LLMConfig) async -> [TestResult] {
        func log(_ msg: String) {
            FileHandle.standardError.write(Data("[LLMTest] \(msg)\n".utf8))
        }

        log("Starting LLM cleanup test harness (\(Self.testCases.count) cases)")
        log("Provider: \(llmConfig.provider.rawValue), Model: \(llmConfig.provider == .local ? llmConfig.localModelId : llmConfig.modelName)")
        log("System prompt length: \(llmConfig.systemPrompt.count) chars")
        log(String(repeating: "=", count: 80))

        var results: [TestResult] = []

        for (i, testCase) in Self.testCases.enumerated() {
            log("")
            log("[\(i + 1)/\(Self.testCases.count)] Category: \(testCase.category.rawValue)")
            log("  Input:    \"\(testCase.input)\"")
            log("  Expected: \"\(testCase.expected)\"")

            // Reset session before each test so context doesn't bleed
            if llmConfig.provider == .local {
                let manager = await LocalLLMManager.shared
                // Build full system prompt with preamble (same as LLMPostProcessor.init)
                await manager.resetSession(systemPrompt: llmConfig.systemPrompt)
            }

            let postProcessor = LLMPostProcessor(config: llmConfig)
            let start = CFAbsoluteTimeGetCurrent()
            let output = await postProcessor.process(rawText: testCase.input)
            let latency = CFAbsoluteTimeGetCurrent() - start

            let result = Self.evaluate(testCase: testCase, output: output, latency: latency)
            results.append(result)

            let wer = Self.wordErrorRate(reference: testCase.expected, hypothesis: output)
            let status = result.passed ? "PASS" : "FAIL"
            log("  Output:   \"\(output)\"")
            log("  Latency:  \(String(format: "%.2fs", latency))")
            log("  WER:      \(String(format: "%.0f%%", wer * 100))")
            log("  Result:   \(status)")
            if !result.failures.isEmpty {
                for f in result.failures {
                    log("  Failure:  \(f)")
                }
            }
        }

        // Summary
        log("")
        log(String(repeating: "=", count: 80))
        log("SUMMARY")
        log(String(repeating: "=", count: 80))

        let passed = results.filter(\.passed).count
        let total = results.count
        let passRate = Double(passed) / Double(total) * 100
        let meanLatency = results.map(\.latency).reduce(0, +) / Double(total)
        let commentaryCount = results.filter { Self.looksLikeCommentary($0.output, rawText: $0.testCase.input) }.count

        log("Pass rate:            \(passed)/\(total) (\(String(format: "%.0f%%", passRate)))")
        log("Mean latency:         \(String(format: "%.2fs", meanLatency))")
        log("Commentary detected:  \(commentaryCount)/\(total)")

        // Per-category breakdown
        for category in Category.allCases {
            let catResults = results.filter { $0.testCase.category == category }
            guard !catResults.isEmpty else { continue }
            let catPassed = catResults.filter(\.passed).count
            log("  \(category.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)) \(catPassed)/\(catResults.count) passed")
        }

        // List failures
        let failures = results.filter { !$0.passed }
        if !failures.isEmpty {
            log("")
            log("FAILURES:")
            for f in failures {
                log("  [\(f.testCase.category.rawValue)] \"\(f.testCase.input)\"")
                for reason in f.failures {
                    log("    - \(reason)")
                }
            }
        }

        log("")
        return results
    }
}
#endif
