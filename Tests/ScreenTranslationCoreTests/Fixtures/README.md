# Japanese OCR stress fixtures

`Yomogi-Regular.ttf` is the unmodified Yomogi handwriting-style Japanese font,
retrieved from https://github.com/google/fonts/tree/main/ofl/yomogi on 2026-11-08.
Its SIL Open Font License and author attribution are included in `OFL.txt`.
The font is a SwiftPM test resource only; it is not included in the app/extension.

`VisionCoreTests.testDifficultJapaneseCoverageAndRepeatabilityBenchmark` renders
neutral Japanese phrases using this font and system Hiragino. Cases include:
32 px handwriting-style horizontal/vertical text, 26 px individual glyph rotations
between −9° and +7° with horizontal jitter, 12 px horizontal print, 14 px vertical
print, and 26 px kanji with 8 px ruby. Coordinates refer to the source bitmap,
not device points. These are synthetic fixtures, not real handwriting photographs.

Each identical image runs three times under normal Share memory policy, followed
by one constrained-memory run. CI artifacts retain the input PNG, every detected
region, expected/actual text, exact-match status, character error rate and elapsed
time for every case/run. On macOS/iOS 26, all six body transcripts are exact-match regressions, including
the sub-16 px cases. The legacy engine retains metrics and a body-region presence
check because it is less accurate. Ruby transcriptions are retained separately in
the report, including their errors; perfect body recognition is not reported as
perfect recognition of the 8 px annotations.
