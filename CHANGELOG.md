# Changelog

## 0.1.0-beta.13 — build 23

- Translate Chinese prose that contains inline labels such as AI, Fed, and S&P 500 without replacing Apple Vision or merging independent text in neighboring languages.
- Keep decimal values intact when a number wraps onto the next line within the same column of Chinese prose.

## 0.1.0-beta.12 — build 22

- Keep the existing Apple Vision OCR engine and recognize distinct adjacent runs of supported source and other languages without treating the entire mixed line as a source mismatch.
- Keep right-edge action buttons icon-only while retaining localized tooltips and VoiceOver labels.
- Preserve the translation start request while the overlay moves or resizes, and restart capture for the new region without requiring another toggle.

## 0.1.0-beta.11 — build 21

- Move capture, folder, recording, click-through, reader and settings actions from the top toolbar to a separate vertical rail at the right edge. Keep the captured body, action controls and resize strips disjoint; scroll the rail at very small heights.
- Remove automatic source selection from the overlay, settings and onboarding. Preserve explicit source preferences; migrate first-run/legacy automatic values to an installed OCR-compatible pair or show preparation guidance.
- Retain the latest valid frame during language preparation and start translation when ready without another frame or toggle. Preserve pending start intent through internal preference reconciliation.
- Bound capture startup, first-frame delivery and service waits; reject late canceled work, retry a timed-out first capture once, prepare installed translation sessions before requests, and recreate failed sessions.
- Add delayed/canceled/duplicate-request and right-edge input/layout regressions. Make the Japanese OCR fixture use explicit native fonts at two weights and require the full sentence, retaining all previous assertions.

## 0.1.0-beta.10 — build 20

- Translate short UI labels using the selected source language when their script is compatible and there is no strong contrary language evidence. Include short Han-only Japanese labels without requiring neighboring prose.
- Allow confident short-label language detection and direct nearby context in Auto Detect, without joining independent labels or propagating inferred languages. Ambiguous labels may still require an explicit source.
- Distinguish absent OCR text, uncertain languages, low OCR confidence, mismatched sources and text already in the target language. Retain only counts in diagnostics and show unresolved-language counts alongside completed translations.
- Add synthetic dense-label OCR-to-translation regression coverage and mixed-script, single-character and short-label language-policy checks.

## 0.1.0-beta.9 — build 19

- Rename the app to 바로렌즈 (Barolens) and the repository to `kuil09/barolens` across source, app identity, build metadata and packaging. Existing preferences migrate once to the new identity.
- Use `dev.local.barolens` as the app identifier, rename internal types/files/metadata, and migrate the default export directory without overwriting existing files. macOS Screen Recording access must be checked again for the new identifier.
- Check signature integrity for development packages and reject obsolete product names outside explicit compatibility code.

## 0.1.0-beta.8 — build 18

- Consolidate the repository around the current product, with a clean source baseline and focused refactoring commits. Preserve existing preferences, app identity, signing team, and capture/translation budgets.
- Centralize help, reader, and language-guide window ownership without replacing a reader's content on focus return. Release closed language-guide content and subscriptions.
- Share screenshot/recording eligibility between menus and the toolbar; recording stop remains available while saving a new capture is unavailable.
- Include the unreleased beta.7 correction: ordinary System Settings visits no longer start permission handoff or interrupt translation/recording. Explicit Barolens screen-access actions retain safe hiding and manual restart.
- Retain source-language filtering, manual full-text snapshots, overflow popovers, body-only click-through, rounded resize controls, direct PNG/MP4 saving, recording geometry lock, bounded scroll-aware recording, and refresh responsiveness.

Publication, exact source/checksum, notarization IDs, and candidate verification are recorded in [GitHub Releases](https://github.com/kuil09/barolens/releases). A source entry is not evidence that a new download has been published. Superseded investigation records are summarized in [Historical verification boundaries](docs/validation-history.md).
