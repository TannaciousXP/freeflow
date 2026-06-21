import Foundation

/// Provider-agnostic guard against transcription garbage / hallucinations.
///
/// FreeFlow's existing `isHallucination` filter only fires when the provider
/// returns Whisper `segments`/`no_speech_prob` metadata — which Groq and OpenAI
/// cloud responses routinely omit, so it silently no-ops on the default cloud
/// providers. This filter is **additive** and works on the transcript text (plus
/// the audio duration) alone, so it catches garbage regardless of what metadata
/// the provider supplied.
///
/// Idea-ported from LocalFlow's `_is_likely_garbage`, but tightened around one
/// rule: **dropping real user dictation is unacceptable.** We favor recall of
/// real speech over catching every piece of garbage. The filter is therefore
/// CONTENT-ANCHORED — it drops a transcript only when a content signal implies
/// there was no real speech at all:
///
/// - C1: the whole transcript IS a bracketed/parenthesized blank-audio marker
///   (e.g. `[BLANK_AUDIO]`, `(silence)`). Matched as the whole string, never a
///   substring, and bare words like "silence"/"pause" are excluded.
/// - C2: the transcript has no real alphanumeric content at all — only
///   punctuation, ellipsis and symbols (e.g. "...", "…", ".,.,."). Letters AND
///   digits both count as real content, so numbers/prices/times survive.
///
/// Everything else is kept. Word-rate / duration mismatch, comma-fragmentation,
/// and ellipsis-with-filler ("um...", "I... I...") are deliberately NOT used to
/// drop anything: each overlaps with real short, slow, list, or disfluent
/// speech, which is exactly the false-positive class we refuse to risk. The
/// worst case is "some garbage slips through", never "real dictation dropped".
/// When in doubt, don't flag.
///
/// `durationSeconds` is accepted (the production path always has it) and kept in
/// the signature for possible future content-gated combination, but it currently
/// never causes a drop on its own.
enum TranscriptionGarbageFilter {

    /// Returns true when `text` looks like transcription garbage and should be
    /// dropped. A content signal (blank-audio token, or no real alphanumeric
    /// content) is always required; `durationSeconds` never causes a drop on its
    /// own.
    static func isLikelyGarbage(text: String, durationSeconds: Double?) -> Bool {
        _ = durationSeconds // reserved for future content-gated combination; see doc comment
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return false }

        // ── Content signals (any one implies NO real speech → safe to flag) ──

        // C1: the entire transcript is a blank-audio / silence marker. Matched as
        // the WHOLE transcript (or a lone bracketed/parenthesized token), never as
        // a substring — so real dictation that merely contains the word "pause" or
        // a literal "(pause)" aside is not dropped.
        if isBlankAudioToken(raw) {
            return true
        }

        // C2: the transcript has no real content at all — only punctuation,
        // ellipsis, symbols and whitespace. Letters OR digits both count as
        // content (numbers, times, prices are real dictation), so only a string
        // that is purely punctuation/symbols is garbage. This is what catches
        // pure trailing-off junk like "..." / "…, …, …" (no letters at all).
        if !containsRealContent(raw) {
            return true
        }

        // ── No content signal → keep the transcript. ──
        //
        // Every transcript that reaches this point contains real letters or
        // digits. Weak signals (comma-fragmentation, word/char-rate mismatch,
        // ellipsis-with-filler) all overlap with real short/slow/disfluent
        // speech and real lists, so they are deliberately NOT consulted here.
        // Dropping real dictation is the cardinal sin.
        return false
    }

    // MARK: - Content signals

    /// True when the whole trimmed transcript is a single blank-audio / silence
    /// marker (optionally wrapped in `[...]` or `(...)`). Whole-string match only.
    private static func isBlankAudioToken(_ raw: String) -> Bool {
        let lower = raw.lowercased()

        // Exact whole-transcript markers. ONLY bracketed/parenthesized forms are
        // listed — bare words like "silence", "music", "pause", and even the
        // machine-looking "blank_audio" are all valid dictation (e.g. a spoken
        // variable name) and must NOT be dropped, so they are excluded here.
        let exactMarkers: Set<String> = [
            "[blank_audio]", "(blank_audio)",
            "[silence]", "(silence)",
            "[pause]", "(pause)",
            "[speaking]", "(speaking)",
            "[no speech]", "(no speech)",
            "[inaudible]", "(inaudible)",
            "[music]", "(music)",
        ]
        if exactMarkers.contains(lower) {
            return true
        }

        // A lone bracketed/parenthesized token whose inner text is a known marker
        // word (covers underscore/space variants like "[blank audio]").
        if let inner = bracketedInner(lower) {
            let normalizedInner = inner.replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespaces)
            let markerWords: Set<String> = [
                "blank audio", "silence", "pause", "speaking",
                "no speech", "inaudible", "music",
            ]
            if markerWords.contains(normalizedInner) {
                return true
            }
        }
        return false
    }

    /// If `raw` is a single fully-bracketed/parenthesized token (e.g. "[x]" or
    /// "(x)") with no other content, return the inner text; otherwise nil. Only
    /// `[...]` and `(...)` are recognized — Whisper never emits `{...}` markers,
    /// and brace-wrapped text can be real dictated code/JSON.
    private static func bracketedInner(_ raw: String) -> String? {
        guard let first = raw.first, let last = raw.last else { return nil }
        let pairs: [(Character, Character)] = [("[", "]"), ("(", ")")]
        for (open, close) in pairs where first == open && last == close {
            let inner = String(raw.dropFirst().dropLast())
            // Reject if the inner text itself contains another bracket of the
            // same kind, i.e. this wasn't a single clean wrapper.
            if !inner.contains(open) && !inner.contains(close) {
                return inner
            }
        }
        return nil
    }

    /// True if the transcript contains at least one letter (ANY script: Latin,
    /// CJK, Thai, Cyrillic, …) or digit. If it contains none, it is pure
    /// punctuation/symbols and carries no real speech. Digits count so dictated
    /// numbers ("555 1234", "$20", "10:30") are never dropped.
    private static func containsRealContent(_ raw: String) -> Bool {
        for ch in raw where ch.isLetter || ch.isNumber {
            return true
        }
        return false
    }

}
