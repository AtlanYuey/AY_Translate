# AY Translate 1.11 (17)

Candidate improvements for inconsistent OCR coverage:

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

Apple CI and installation-package verification are pending for this candidate.
