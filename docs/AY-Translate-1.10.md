# AY Translate 1.10 (16)

## Changes

- Normalize Google's `models/` resource names at model discovery and request time, including existing saved configurations. Other providers' model namespaces remain intact. Google's compatible API receives JSON mode for the app's structured response contract.
- Accept numeric OCR anchor IDs as well as strings; keep additional AI text whose generated ID is not a local anchor. Unverified geometry remains available in Full Text rather than painting over unverified image regions.
- Preserve specific AI failure categories (HTTP status, output limit, refusal, empty response, malformed JSON) in the recognition notice and content-free diagnostics. Provider refusals are not retried or bypassed.
- Add a separate **Test Image Recognition** action using a generated multilingual sample image, with no local OCR fallback. This exercises the configured multimodal endpoint independently from the existing translation test.
- Check two-character vertical replies, retaining horizontal-text protections. Shrink remaining OCR windows when pressure rises during a page, and drain per-tile temporary geometry objects.
- Release consumed share input attachments, retire a previously retained share controller on a new invocation, and normalize high-bit-depth images inside the decoder's autorelease pool. The original image remains visible during processing and on recoverable errors.
- Include app/extension version, build and process-session ID in new diagnostic records; retain import checkpoints and coalesce consecutive warning samples without losing the warning count or peak footprint.

## Device evidence and limits

The user's initial report lacked the 1.9 checkpoints and was confirmed to be from an older installed package. After reinstalling 1.9, the latest chronological failure (`CBB5…`) stopped at `document_cpu_1_begin`, with 187,942,992 bytes of footprint and 42,743,728 bytes available. Footprint had already risen from 128,419,920 bytes at import to 187,697,232 at presentation. The earliest request was manually stopped; it is not classified as a crash.

These records identify pressure before OCR as well as repeated-invocation retention risk. They do not prove a Jetsam kill or quantify a 1.10 device improvement. Simulator results cannot establish that physical-device memory termination is eliminated.

Gemini request compatibility is checked against Google's [OpenAI compatibility documentation](https://ai.google.dev/gemini-api/docs/openai) and protocol regression tests. No customer API key or screenshot is used in tests. Live Gemini account access and provider-specific content restrictions require the in-app sample test on the user's own device.

## Validation

- Linux: 93 core tests passed.
- [Apple CI 42423319896](https://github.com/AtlanYuey/translate-screen/actions/runs/42423319896), application source commit `8fa9379697a4c2f606737240c6ceda06b568ab5c`: passed.
- macOS 26: 103 core/native Vision tests passed, including the two-character vertical-reply fixture. macOS 15: eight native Vision cases passed; two document-API cases skipped because they require version 26.
- iOS: 72 integration/native tests and four UI tests passed. iPad portrait/landscape check passed.
- The same Share process completed six consecutive 1170 × 2532 generated screenshots, with zero memory warnings. Recorded peak footprint ranged from 69,343,616 to 75,110,784 bytes. This is simulator evidence using neutral text and an identity translation fixture, not a paid-provider or real-device benchmark.
- The UIActivity host still has a recorded expected full-screen-height assertion failure (sheet presentation). Shortcuts end-to-end behavior was not tested in CI.
- [Unsigned IPA artifact](https://github.com/AtlanYuey/translate-screen/actions/runs/42423319896/artifacts/13594815898): app and extension both 1.10 (16), arm64, iOS 26.5 minimum. Archive integrity, embedded Share extension, app icon, signed shortcut and unsigned executable checks passed.
- IPA SHA-256: `4dd34b56bdc8409636dfefe4c333dbcf627a66dbccf8c87897eb9e1f0c867a81`.
- No release/tag/merge. Subsequent documentation-only validation notes do not change the tested application source or IPA.
