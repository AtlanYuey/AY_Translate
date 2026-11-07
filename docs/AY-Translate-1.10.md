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
- Apple native OCR, iOS integration, consecutive Share UI and iPad checks: pending CI.
- Unsigned IPA: pending CI/package inspection. No release/tag/merge.
