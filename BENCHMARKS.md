# Streaming Transcription Benchmarks

Last run: 2026-02-11
Model: `ggml-base.en-q5_1.bin` (Base English, Q5_1 quantization, ~59 MB, Metal + CoreML encoder)
Hardware: Apple M3, macOS 15

## Glossary

- **WER** (Word Error Rate): Percentage of words wrong vs. reference, computed via Levenshtein distance on word arrays: `(insertions + deletions + substitutions) / reference_word_count`.
- **LA-2** (Local Agreement 2): Stabilizer algorithm that commits a word only once two consecutive decode windows agree on it.
- **Flicker**: A speculative (uncommitted) word shown to the user that disappears or changes on the next decode tick. Measured by comparing each tick's speculative text with the previous tick's.
- **Committed text**: Finalized transcript text that never changes once emitted.
- **Speculative text**: Preview text shown ahead of the commit cursor; may change between ticks.

## Results

### Short Benchmark (~5 s)

Phrase: *"The quick brown fox jumps over the lazy dog. She sells seashells by the seashore."*

| Metric             | Value       |
|--------------------|-------------|
| Audio duration     | 5,024 ms    |
| Total elapsed      | 9,050 ms    |
| Ticks              | 21          |
| Avg decode latency | 124 ms      |
| Max decode latency | 208 ms      |
| Time to first word | 1,500 ms    |
| Flicker events     | 3           |
| Streaming WER      | 6.7%        |
| Full decode WER    | 0.0%        |

Streaming output was truncated at "...seashells by the" (missing "seashore"). Full single-pass decode was perfect.

### Long Benchmark (~28 s)

Phrase: *~100-word paragraph (morning sun, grandmother's letters, summers by the lake).*

| Metric             | Value       |
|--------------------|-------------|
| Audio duration     | 27,739 ms   |
| Total elapsed      | 52,558 ms   |
| Ticks              | 111         |
| Avg decode latency | 343 ms      |
| Max decode latency | 769 ms      |
| Time to first word | 1,500 ms    |
| Flicker events     | 35          |
| Streaming WER      | 23.9%       |
| Full decode WER    | 0.0%        |

Key observations:
- Latency climbs as audio accumulates (early ticks ~120 ms, later ticks 500-770 ms).
- Heavy flickering (35 events) with artifacts: duplicate fragments, hallucinated words ("wildflakes", "chairs"), echo phrases ("began open window").
- Tail truncation: committed text ends with "by the late." instead of "by the lake."
- Full decode remains perfect at 0.0% WER.

## Interpretation

Short utterances work well: low WER, minimal flicker, snappy latency. Long-form streaming degrades significantly due to the sliding window + LA-2 stabilizer losing context as audio accumulates. The model itself handles both lengths perfectly in single-pass mode; the degradation is entirely in the streaming pipeline.

## How to Run

```bash
# Build
cd VoiceToText && xcodebuild -scheme VoiceToText -configuration Debug build

# Short benchmark
./build/Products/Debug/VoiceToText.app/Contents/MacOS/VoiceToText --test-harness 2>&1

# Long benchmark
./build/Products/Debug/VoiceToText.app/Contents/MacOS/VoiceToText --test-harness --long 2>&1
```

The harness uses macOS TTS to synthesize audio from a reference phrase, feeds it tick-by-tick through the streaming pipeline, and compares the result against the reference. Output goes to stderr with the `[TestHarness]` prefix.
