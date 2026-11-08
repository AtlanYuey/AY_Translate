# AY Translate 1.11 (17)

Improvements for inconsistent OCR coverage:

- Reconcile overlapping tile observations using reading direction, line alignment,
  transcript overlap and geometry. Stitch verified prefix/suffix fragments; do not
  collapse neighboring ruby or repeated text in separate bubbles into one region.
- After document recognition, run a bounded, serial independent Vision text read
  with dictionary correction off. Keep complete document observations and add
  uncovered lines; reject cross-column duplicates using actual glyph evidence.
- Recheck uncovered vertical runs beyond the previous first-32-column cutoff.
  Retry weak/partial packed rows individually without dictionary correction.
  Automatic language mode no longer forces Japanese in this supplemental path.
- Settings → Display → Redraw unchanged recognized text (off by default) redraws
  unchanged positioned OCR text, including text already in the target language.
  It does not repeat OCR/translation or change saved translations. The setting is
  included in shared preferences and optional iCloud settings sync.
- Retain small kana beside kanji as annotations in full-text inspection, avoiding
  a second translated overlay on the same column. Remove identical transcripts
  detected with different bounding-box widths.
- Clamp manual text enlargement to free space between neighboring source regions;
  share the same layout plan between preview and export.

Validation includes a new six-case Japanese stress fixture: handwriting-style
font, individual glyph skew/jitter, tiny 12/14 px print and 8 px ruby alongside
26 px kanji. Same-image repeats and constrained-memory results are retained as
metrics. These are synthetic inputs, not a substitute for real handwriting or
on-device recognition checks. Unreadable pixels and genuinely ambiguous glyphs
cannot be guaranteed to transcribe correctly.

Verification for application source `093ebd46d2f639fe0ecc4185f3107c4dc12924f8`:

- Linux: 101 core tests passed.
- macOS 26: 112 core/native Vision tests passed. All 24 body transcripts in the
  six-case, four-pass stress benchmark matched exactly. This includes 12 px
  horizontal and 14 px vertical text, three identical-input repeats and one
  constrained-memory run.
- macOS 15 legacy Vision: 9 native tests passed, 2 document-API tests skipped.
  Stress metrics were 20/24 exact body transcripts: the 14 px vertical text was
  misread in three runs and one rotated character was misread under pressure.
- The 8 px ruby is not fully transcribed: normal document runs omitted separate
  readings; the constrained run returned `とみん` for `としょかん`. These are kept as
  annotation errors, not counted as perfect OCR. The body remains correct and the
  annotations do not create a second translated overlay.

- iPhone Air simulator: 74 hosted tests and 4 UI tests passed. New coverage includes
  opt-in Chinese original overlays, persisted/shared settings and adjacent vertical
  translations enlarged to 180% without overlapping outlines.
- iPad mini (A17 Pro) simulator: portrait/landscape UI check passed.
- Six consecutive Share invocations in the same process completed with zero memory
  warnings. Sampled peak footprints were 127,769,024–137,763,328 bytes. This is a
  simulator check, not a claim that every real-device memory-pressure failure is
  eliminated. The extra local recognizer adds work and memory; real-device timing
  still needs comparison with 1.10.
- The existing UIActivity sheet-height expectation remains an expected failure
  (834 vs 884.64 points). Shortcuts end-to-end behavior was not verified here.

[Successful Apple CI](https://github.com/AtlanYuey/translate-screen/actions/runs/42479655150)
contains the actual PNGs, expected/recognized text, error metrics and test logs.

[Unsigned IPA](https://github.com/AtlanYuey/translate-screen/actions/runs/42479655150/artifacts/13617640094):
`TranslateScreen-1.11-unsigned.ipa`, version 1.11, build 17, minimum iOS 26.5.
Main app and embedded Share extension versions, arm64 executables, unsigned status,
iPhone/iPad orientations, archive integrity and bundled signed Shortcut were verified.
The test-only font is excluded from the app. SHA-256:
`63c725145d9424a7c3cb0a5c733030f82525de22cd9282d1fb4328bfced599eb`.

No customer API key or screenshot was used. No merge, tag or Release was created.
