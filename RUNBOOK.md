# VoiceToText Streaming Pipeline — Runbook

## Architecture Overview

The pipeline uses a **sliding-window re-decode** architecture:

1. **AudioRingBuffer** holds the last N seconds of audio (default 8s)
2. A **tick timer** (250ms) triggers re-decoding the current window
3. **TranscriptStabilizer** uses a commit horizon to separate stable (committed) text from speculative text
4. **Backpressure**: if a decode is still in-flight when the next tick fires, it's queued rather than dropped

## Tunable Parameters (PipelineConfig.swift)

| Parameter | Default | Range | Effect |
|-----------|---------|-------|--------|
| `tickMs` | 250 | 100–500 | How often we re-decode. Lower = more responsive, higher CPU |
| `windowMs` | 8000 | 4000–12000 | Audio window size. Larger = more context, slower decode |
| `commitMarginMs` | 700 | 500–900 | How far from window end tokens must be to commit. Lower = faster commit, risk of errors |
| `maxPromptChars` | 1200 | 500–2000 | Decoder prompt from committed text. More = better continuity, slower |
| `silenceMs` | 900 | 500–2000 | Silence duration before skipping decode |
| `noSpeechThreshold` | 0.75 | 0.5–0.95 | Whisper no-speech probability threshold |
| `maxSessionMinutes` | 30 | 1–60 | Safety limit for recording duration |

### Tuning Tips

- **Lag feels too high**: Reduce `commitMarginMs` to 500, reduce `windowMs` to 6000
- **Words getting cut off**: Increase `commitMarginMs` to 900
- **CPU too high on older Macs**: Increase `tickMs` to 500, reduce `windowMs` to 4000
- **Hallucinations during silence**: Reduce `silenceMs` to 500
- **Text flickering**: Increase `commitMarginMs` (speculative tail updates less)

## Debugging

### Enable verbose logging

All components use `os.Logger`. View logs in Console.app with:
- Category filter: `TranscriptionPipeline`, `WhisperManager`, `AudioRecorder`, `TranscriptStabilizer`
- Subsystem: `com.voicetotext.app`

### Common issues

**"instanceBusy" errors**: The backpressure system should prevent these. If they appear, the tick timer is firing faster than decode can complete. Increase `tickMs`.

**Text regresses (goes backwards)**: The stabilizer has a guard against committed text shrinking. Check logs for "Committed text would shrink" warnings.

**Paste fails**: Check for `ClipboardPaster` logs. The pipeline records the frontmost app at recording start and attempts to restore focus. If the app was closed during recording, text remains on clipboard with a toast notification.

**Empty transcription**: Check `SilenceDetector` — if RMS energy is below threshold for the entire session, no decode occurs. Adjust `energyThreshold` in `SilenceDetector.swift`.

## Backend Swapping

### Using a different Whisper backend

The pipeline communicates with Whisper through `WhisperManager.transcribeWindow()`. To swap backends:

1. Create a new class conforming to the same interface as `WhisperManager`
2. Replace the `whisperManager` property in `TranscriptionPipeline`
3. The new backend must return `DecodeResult` with `TranscriptionSegment`s containing token-level timestamps

### Disabling token-level timestamps

If your backend doesn't support token timestamps, return segments with empty `tokens` arrays. The `TranscriptStabilizer` will fall back to segment-level timing (less granular commit horizon).

## Running Tests

```bash
# SwiftPM
cd VoiceToText && swift test

# Xcode
xcodebuild test -scheme VoiceToText -destination 'platform=macOS'
```

### Test coverage

- `AudioRingBufferTests`: Ring buffer write/read, overflow wrap, timestamp mapping, reset
- `TranscriptStabilizerTests`: Commit horizon, speculative replacement, dedup, regression guard
- `PipelineIntegrationTests`: Multi-tick simulation, finalization, silence detection
