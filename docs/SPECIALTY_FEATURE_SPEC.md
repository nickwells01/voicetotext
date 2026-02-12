# Specialty Feature Spec

## Overview

Domain-specific speech recognition profiles ("specialties") that improve Whisper's recognition of technical vocabulary. A specialty bundles three layers that work together:

1. **Whisper initial prompt** — domain terms that bias the decoder toward correct recognition
2. **Vocabulary corrections** — source/target pairs that fix common misrecognitions via text replacement
3. **LLM system prompt suffix** — domain-aware post-processing instructions

Specialties are **independent from AI modes** — they can be combined (e.g., "Medical" specialty + "Email Pro" AI mode for dictating medical emails). Specialties work with or without AI Cleanup enabled since layers 1 and 2 operate at the Whisper/text level.

## Data Model

### `SpecialtyPreset`

New file: `VoiceToText/VoiceToText/Models/SpecialtyPreset.swift`

Mirrors the `AIModePreset` pattern (same persistence, selection, built-in + custom approach):

```swift
struct VocabularyCorrection: Codable, Equatable, Identifiable {
    let id: UUID
    var source: String   // what Whisper misrecognizes (e.g. "my oh cardial")
    var target: String   // correct form (e.g. "myocardial")
}

struct SpecialtyPreset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var icon: String                              // SF Symbol name
    var whisperPrompt: String                     // comma-separated domain terms
    var vocabularyCorrections: [VocabularyCorrection]
    var llmSystemPromptSuffix: String
    var isBuiltIn: Bool
}
```

**Persistence** (via UserDefaults, same pattern as `AIModePreset`):
- `loadCustomPresets()` / `saveCustomPresets()` — user-created specialties
- `activePreset()` / `setActivePreset()` — currently selected specialty
- `allPresets()` — built-in + custom combined

**Correction method:**
- `applyVocabularyCorrections(to:)` — case-insensitive word-boundary regex replacement

## Built-in Specialties

### Medical
- **Icon:** `cross.case`
- **Whisper prompt:** ~35 terms including patient, diagnosis, hypertension, tachycardia, myocardial infarction, atrial fibrillation, COPD, EKG, echocardiogram, common drug names (metformin, lisinopril, atorvastatin), dosage units (mg, mL, BID, TID, PRN)
- **Corrections:** "high pertension" -> "hypertension", "a fib" -> "AFib", "my oh cardial" -> "myocardial", "ek g" -> "EKG", "see o p d" -> "COPD", etc.
- **LLM suffix:** Preserve medical terminology, drug names, dosages, and standard abbreviations exactly

### Legal
- **Icon:** `scalemass`
- **Whisper prompt:** ~30 terms including plaintiff, defendant, deposition, affidavit, subpoena, habeas corpus, voir dire, amicus curiae, prima facie, res judicata, stare decisis, tort, fiduciary, certiorari
- **Corrections:** "habeas corpse" -> "habeas corpus", "prima fascia" -> "prima facie", "certiary eye" -> "certiorari", "sub pena" -> "subpoena", etc.
- **LLM suffix:** Preserve legal terminology, case citations, statute references, and Latin phrases; maintain formal legal tone

### Tech / Programming
- **Icon:** `chevron.left.forwardslash.chevron.right`
- **Whisper prompt:** ~40 terms including API, REST, GraphQL, JSON, YAML, SQL, PostgreSQL, Kubernetes, Docker, AWS, OAuth, JWT, WebSocket, async/await, npm, pip, Swift, Python, TypeScript, React, Node.js
- **Corrections:** "J. Son" -> "JSON", "sequel" -> "SQL", "post gress" -> "Postgres", "cube er net ease" -> "Kubernetes", "oh auth" -> "OAuth", "get hub" -> "GitHub", etc.
- **LLM suffix:** Preserve technical terms, API names, framework names; keep camelCase/PascalCase/snake_case intact; don't expand acronyms

### Finance / Business
- **Icon:** `chart.line.uptrend.xyaxis`
- **Whisper prompt:** ~35 terms including revenue, EBITDA, P/E ratio, ROI, CAGR, amortization, GAAP, IFRS, IPO, M&A, SaaS, ARR, MRR, churn rate, burn rate, Series A, cap table, YoY, QoQ
- **Corrections:** "e bit da" -> "EBITDA", "R. O. I." -> "ROI", "gap" -> "GAAP", "i pro" -> "IPO", "sass" -> "SaaS", "A are are" -> "ARR", etc.
- **LLM suffix:** Preserve financial terminology, metric names, abbreviations; format numbers/percentages/currency precisely

## How It Works

### Layer 1: Whisper Initial Prompt

Whisper's `initial_prompt` parameter conditions the decoder on provided tokens, biasing it toward recognizing those words. The specialty's whisper prompt terms are **prepended** to the existing committed-text prompt in `TranscriptionPipeline.buildPrompt()`.

**Prompt composition order:**
1. Specialty domain terms (strongest bias — first position)
2. Committed text continuity context (existing behavior)

Separated by `. ` so Whisper treats them as distinct segments. Token budget: ~60-80 tokens for specialty terms out of 224 total, leaving 144+ for continuity.

**Integration point:** `TranscriptionPipeline.buildPrompt(from:)` (currently line 413)

### Layer 2: Vocabulary Corrections

Text replacement pass using case-insensitive word-boundary regex. Applied in two places:

1. **Live display** — in `TranscriptionPipeline.updateUIFromStabilizer()` after filler word filter, so corrections appear in real-time
2. **Finalization** — in `TranscriptionPipeline.finalizeRecording()` after filler word filter on the raw text before LLM processing

**Performance:** ~10 corrections per specialty, each a simple regex. Runs every tick (250ms) — negligible overhead. If custom specialties grow large (100+ corrections), consider caching compiled regexes.

### Layer 3: LLM System Prompt

The specialty's `llmSystemPromptSuffix` is inserted into the LLM prompt chain in `PasteCoordinator.finalize()`.

**Prompt assembly order:**
1. AI Mode preset systemPrompt (existing — replaces base prompt)
2. **Specialty LLM suffix** (new)
3. App context modifier (existing)
4. Custom vocabulary promptSuffix (existing)
5. **Specialty term preservation** (new — "preserve these domain terms exactly: ...")

**Integration point:** `PasteCoordinator.finalize()` — add `activeSpecialty: SpecialtyPreset?` parameter

## UI

### Menu Bar Picker

A new `configControl` row in `MenuBarView.configSection`, placed between Language and Activation pickers. Always visible (not gated on AI Cleanup):

```
[briefcase] Specialty    [None v]
```

The icon dynamically reflects the active specialty (e.g., `cross.case` when Medical is selected).

### Settings Tab

New "Specialty" tab in `SettingsView` between "AI Cleanup" and "Advanced". Contains:

- **Active Specialty** section — picker with +/- buttons for custom preset CRUD
- **Whisper Prompt Terms** section — TextEditor (read-only for built-ins, editable for custom)
- **Vocabulary Corrections** section — source/target pair list with add/delete rows
- **LLM Instructions** section — TextEditor for domain-specific instructions

Built-in specialties show their content read-only so users can see what's included. Custom specialties are fully editable.

Settings frame height increases from 580 to 640 to accommodate the new tab.

## Files to Change

| File | Change |
|------|--------|
| **New:** `Models/SpecialtyPreset.swift` | Data model, 4 built-ins, persistence, correction logic |
| `Models/AppSettings.swift` | Add `specialtyPresets` and `activeSpecialtyPresetId` to `StorageKey` |
| `App/AppState.swift` | Add `@AppStorage` for `activeSpecialtyPresetId` |
| `Transcription/TranscriptionPipeline.swift` | `buildPrompt()`: prepend specialty terms; `updateUIFromStabilizer()`: apply corrections to live text; `finalizeRecording()`: apply corrections + pass specialty to finalize |
| `Transcription/PasteCoordinator.swift` | Add `activeSpecialty` parameter, insert specialty suffix and term preservation in LLM prompt chain |
| `UI/MenuBarView.swift` | Add specialty picker in configSection |
| `UI/SettingsView.swift` | Add SpecialtyTab, increase frame height |
| `VoiceToText.xcodeproj/project.pbxproj` | Register `SpecialtyPreset.swift` in PBXFileReference, PBXBuildFile, PBXGroup, PBXSourcesBuildPhase |

## Interaction with Existing Features

- **CustomVocabulary** — Coexists. Global vocabulary is for user-specific terms (company names, personal jargon). Specialty corrections are domain-specific and activate/deactivate with the specialty. No changes to `CustomVocabulary.swift`.
- **AI Modes** — Independent. Specialty handles domain recognition, AI mode handles output formatting. Both contribute to the LLM system prompt when AI Cleanup is enabled.
- **App Context Detection** — Stacks. Specialty domain instructions appear before app context modifier in the prompt chain.
- **Filler Word Filter** — Runs first. Vocabulary corrections apply after filler word removal.

## Verification Checklist

- [ ] Build succeeds with no errors
- [ ] Specialty picker visible in menu bar between Language and Activation
- [ ] Settings > Specialty tab shows 4 built-ins (read-only) with correct content
- [ ] Can create, edit, and delete custom specialties
- [ ] Console log confirms specialty terms prepended to Whisper prompt during recording
- [ ] Vocabulary corrections appear in live streaming display
- [ ] LLM system prompt includes specialty suffix when AI Cleanup is enabled
- [ ] Specialty + AI Mode work independently and simultaneously
