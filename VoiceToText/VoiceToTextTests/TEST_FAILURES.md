# Test Failure Analysis

**Date:** 2026-02-12
**Model:** ggml-base.en-q5_1.bin
**Hardware:** MacBook Air (arm64), macOS 26.2
**Results:** 150 tests, 137 passed, 13 failed, 0 skipped

---

## 1. TranscriptStabilizer: exact matching vs normalized matching

**Tests:**
- `TranscriptStabilizerTests/testFullAgreementCommitsAll`
- `TranscriptStabilizerTests/testPunctuationDoesNotBreakAgreement`
- `TranscriptStabilizerTests/testCaseDoesNotBreakAgreement`

**What happened:**

The stabilizer's LA-2 (Local Agreement) algorithm compares decoded words using exact string equality. The tests assume case-insensitive and punctuation-insensitive comparison.

| Test | Decode 1 | Decode 2 | Expected agreement | Actual agreement |
|------|----------|----------|--------------------|------------------|
| `testFullAgreementCommitsAll` | `"Hello world"` | `"Hello world"` | `"Hello world"` committed | `"Hello"` committed (last word withheld as margin) |
| `testPunctuationDoesNotBreakAgreement` | `"Hello world"` | `"Hello world."` | `"Hello world"` committed | `"Hello"` committed (`"world"` != `"world."`) |
| `testCaseDoesNotBreakAgreement` | `"The Quick Brown Fox"` | `"The quick brown Fox jumps"` | 4-word agreement | 1-word agreement (`"Quick"` != `"quick"`) |

**Root cause:** The stabilizer does not normalize words before comparison. This is a design choice — the tests were written assuming normalization that doesn't exist.

**Fix options:**
- A) Add case/punctuation normalization to the stabilizer's agreement logic
- B) Update tests to match the stabilizer's actual exact-match behavior

---

## 2. Decode latency p95 thresholds too aggressive

**Tests:**
- `StreamingQualityTests/testDecodeLatencyP95Short` — **533ms** actual, 300ms threshold
- `StreamingQualityTests/testDecodeLatencyP95Long` — **1241ms** actual, 800ms threshold

**What happened:**

The p95 latency measures the 95th-percentile decode time across all ticks. The base.en quantized model on this hardware produces decode times in the 200-500ms range normally, but p95 catches the worst ticks (typically when the audio window is longest and the model produces more tokens).

**Root cause:** Thresholds were set aspirationally. The base.en-q5_1 model on Apple Silicon can't consistently hit these at the p95 level.

**Fix:** Raise thresholds to match observed hardware performance:
- Short p95: 300ms → 600ms
- Long p95: 800ms → 1400ms

---

## 3. Time-to-first-word boundary condition

**Tests:**
- `StreamingQualityTests/testTimeToFirstWordShort` — **1500ms** actual, `< 1500` threshold
- `StreamingQualityTests/testTimeToFirstWordLong` — **1500ms** actual, `< 1500` threshold

**What happened:**

TTFW is calculated as the `audioPositionMs` of the first tick with non-empty committed text. With a 250ms tick interval, the first committed word appears at tick 6 (1500ms audio position). The test uses strict `<` comparison, so `1500 < 1500` fails.

**Root cause:** Off-by-one boundary — `XCTAssertLessThan` should be `XCTAssertLessThanOrEqual`.

**Fix:** Change line 121 and 132 in `StreamingQualityTests.swift`:
```swift
// Before:
XCTAssertLessThan(ttfw, 1500, ...)
// After:
XCTAssertLessThanOrEqual(ttfw, 1500, ...)
```

---

## 4. WER exceeds 5% on longer audio

**Tests:**
- `CompetitiveQualityTests/testFinalOutputWERLongUnderFivePercent` — **6.7% WER**, 5% threshold
- `CompetitiveQualityTests/testLongFormDictation` — **8.1% WER**, 5% threshold

**What happened:**

The base.en quantized model achieves ~0% WER on the short phrase (single pangram + tongue twister) but degrades on longer multi-sentence passages. The long phrase includes tongue twisters ("Peter Piper picked a peck of pickled peppers") that are inherently harder. The dictation paragraph includes proper nouns ("Charles Babbage", "Ada Lovelace", "ENIAC") that stress the small model.

**Root cause:** The 5% WER target is achievable with larger Whisper models (small.en, medium.en) but too aggressive for base.en-q5_1 on complex passages.

**Fix options:**
- A) Raise the threshold for base.en to 10%
- B) Gate these tests on model size (skip for base.en, enforce for small.en+)
- C) Simplify the test phrases to avoid tongue twisters and rare proper nouns

---

## 5. Regression baseline assumes perfect WER

**Test:**
- `RegressionGuardTests/testLongTTSRegression` — Full WER **0.067**, baseline **0.0** + tolerance **0.02**

**What happened:**

The baseline file (`Baselines/quality_baselines.json`) records `full_wer: 0.0` for the `long_tts` scenario. With a tolerance of 0.02, the test allows up to 2% WER. The actual result is 6.7%.

**Root cause:** The baseline was likely recorded on a run where the long phrase happened to decode perfectly (non-determinism in Whisper quantized inference). It doesn't reflect typical performance.

**Fix:** Re-record baselines with averaged results from multiple runs, or set `full_wer` to 0.05 for the long_tts baseline.

---

## 6. Technical vocabulary string matching

**Test:**
- `CompetitiveQualityTests/testTechnicalVocabulary` — `"macos"` not found in output

**What happened:**

The test lowercases the transcription output and checks `output.contains("macos")`. Whisper transcribes the spoken word as `"Mac OS"` (two words), which lowercases to `"mac os"`, not `"macos"`.

**Root cause:** String containment check doesn't account for Whisper's tokenization of compound technical terms.

**Fix:** Check for multiple acceptable forms:
```swift
let macOSFound = output.contains("macos") || output.contains("mac os")
XCTAssertTrue(macOSFound, "...")
```

---

## 7. Pipeline integration: stabilizer more conservative than expected

**Tests:**
- `PipelineIntegrationTests/testMultipleTicksAccumulateText` — `XCTAssertTrue failed`
- `PipelineIntegrationTests/testSlidingWindowProgressiveCommit` — `XCTAssertFalse failed - Some tokens should be committed`

**What happened:**

These tests feed synthetic audio through the pipeline and expect committed text to appear after a certain number of ticks. The LA-2 stabilizer requires two consecutive agreeing decodes before committing words, and withholds the last word in each agreement as margin. With short synthetic audio and few ticks, the stabilizer may not have enough agreement to commit anything.

**Root cause:** The tests assume the stabilizer commits aggressively. In practice, LA-2 is deliberately conservative to avoid flicker — it trades latency for stability.

**Fix options:**
- A) Increase the number of ticks in these tests to give the stabilizer enough history
- B) Assert on speculative text instead of committed text for early ticks
- C) Use a lower `commitMarginMs` in the test configuration

---

## Summary by category

| Category | Tests | Severity | Fix effort |
|----------|-------|----------|------------|
| Stabilizer normalization gap | 3 | Medium | Either update stabilizer or tests |
| Latency thresholds too tight | 2 | Low | Raise thresholds |
| Off-by-one boundary | 2 | Low | `<` → `<=` |
| WER thresholds too tight for base.en | 2 | Low | Raise thresholds or gate on model |
| Stale regression baseline | 1 | Low | Re-record baseline |
| String matching too strict | 1 | Low | Accept alternate forms |
| Pipeline integration expectations | 2 | Medium | Adjust tick count or assertions |
