import Foundation

/// Provider-agnostic guard against transcription garbage / hallucinations.
///
/// FreeFlow's existing `isHallucination` filter only fires when the provider
/// returns Whisper `segments`/`no_speech_prob` metadata — which Groq and OpenAI
/// cloud responses routinely omit, so it silently no-ops on the default cloud
/// providers. This filter is **additive** and works on the transcript text (plus
/// an optional audio duration) alone, so it catches garbage regardless of what
/// metadata the provider supplied.
///
/// Idea-ported from LocalFlow's `_is_likely_garbage`. Conservative by design:
/// **false positives (dropping real user dictation) are the cardinal sin**, so
/// ambiguous signals (ellipsis, comma-fragmentation, mild word-rate mismatch)
/// must combine — 2+ are required to flag. Only unambiguous markers (explicit
/// blank-audio tokens) and *extreme* word/char-rate mismatch may flag alone.
enum TranscriptionGarbageFilter {

    // CJK detection threshold: if at least this fraction of the non-whitespace,
    // non-punctuation characters are CJK, switch from word-count to char-count
    // (CJK has no word spacing, so `.split()` massively undercounts and would
    // produce false-positive "too few words" flags on legitimate CJK speech).
    private static let cjkDensityThreshold = 0.3

    // Duration below which the content/duration mismatch check is skipped — a
    // short clip with a short transcript is normal ("yes", "no problem").
    private static let durationMismatchMinSeconds = 3.0

    /// Returns true when `text` looks like transcription garbage and should be
    /// dropped. `durationSeconds` is the recorded audio length, if known; when
    /// nil, the content/duration mismatch signal is simply not evaluated (the
    /// text-only signals still apply).
    static func isLikelyGarbage(text: String, durationSeconds: Double?) -> Bool {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return false }

        var signals = 0
        let rawLower = raw.lowercased()

        // Signal 1: Ellipsis — Whisper's uncertainty/trailing-off marker.
        // Matches both the ASCII "..." and the Unicode ellipsis "…".
        if raw.contains("...") || raw.contains("\u{2026}") {
            signals += 1
        }

        // Signal 2 (UNAMBIGUOUS, flags alone): explicit blank-audio / silence
        // markers and hallucinated interjections leaking through from the model.
        let blankAudioTokens = ["[blank_audio]", "(silence)", "[silence]", "(pause)", "(speaking)"]
        if blankAudioTokens.contains(where: { rawLower.contains($0) }) {
            return true
        }
        let interjectionTokens = ["oop,", "oop ", "uh-oh"]
        if interjectionTokens.contains(where: { rawLower.contains($0) }) {
            signals += 1
        }

        // Signal 3: Heavy comma-fragmentation — 3+ comma-separated chunks where
        // every chunk is short (<= 3 words). Catches "uh, no, so, by, the path"
        // while leaving real lists ("eggs, milk, and bread" → only 3 chunks but
        // the trailing chunk "and bread" is fine; the all-short test is what
        // distinguishes spam from a real list whose chunks carry real content).
        let chunks = raw
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if chunks.count >= 3 && chunks.allSatisfy({ wordCount($0) <= 3 }) {
            signals += 1
        }

        // Signal 4: Content/duration mismatch. Only evaluated when we know the
        // duration AND it exceeds the minimum (short clips are exempt).
        if let duration = durationSeconds, duration > durationMismatchMinSeconds {
            if isCJKText(raw) {
                // CJK char-density. Normal CJK speech is ~5-8 chars/sec.
                let nonSpaceChars = raw.reduce(0) { $1.isWhitespace ? $0 : $0 + 1 }
                let cps = Double(nonSpaceChars) / duration
                if cps < 1.0 {
                    return true // extreme — flag alone
                }
                if cps < 2.0 {
                    signals += 1
                }
            } else {
                // Latin/Cyrillic word rate. Normal speech is ~2-3 words/sec.
                let wps = Double(wordCount(raw)) / duration
                if wps < 0.4 {
                    return true // extreme — Whisper basically gave up; flag alone
                }
                if wps < 0.8 {
                    signals += 1
                }
            }
        }

        // Conservative: require 2+ independent ambiguous signals to flag.
        return signals >= 2
    }

    /// Count of whitespace-delimited tokens in `text`.
    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// True if a significant fraction of `text` is CJK (Chinese / Japanese /
    /// Korean). Used to switch garbage detection from word-count to char-count,
    /// since CJK languages have no word spacing.
    private static func isCJKText(_ text: String) -> Bool {
        var cjkChars = 0
        var totalChars = 0
        for scalar in text.unicodeScalars {
            let ch = Character(scalar)
            if ch.isWhitespace || ch.isPunctuation || ch.isSymbol {
                continue
            }
            totalChars += 1
            let cp = scalar.value
            if (0x3040...0x309F).contains(cp) ||   // Hiragana
               (0x30A0...0x30FF).contains(cp) ||   // Katakana
               (0x4E00...0x9FFF).contains(cp) ||   // CJK Unified Ideographs
               (0xAC00...0xD7AF).contains(cp) {     // Hangul Syllables
                cjkChars += 1
            }
        }
        return totalChars > 0 && (Double(cjkChars) / Double(totalChars)) >= cjkDensityThreshold
    }
}
