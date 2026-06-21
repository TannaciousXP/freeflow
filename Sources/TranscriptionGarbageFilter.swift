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
/// CONTENT-ANCHORED:
///
/// - A **content signal** implies there was no real speech at all — the
///   transcript IS a blank-audio token, it is entirely non-alphabetic, or it is
///   pure ellipsis fragmentation. Real speech always contains real words, so a
///   content signal is safe to act on alone.
/// - **Weak signals** (audio-duration / words-per-second mismatch, heavy
///   comma-fragmentation) overlap with legitimate short or slow speech and real
///   lists, so they may ONLY ever *combine with* a content signal. They can
///   never, on their own or together, drop a transcript that contains real
///   words.
///
/// Net effect: we flag iff a content signal is present. Because no real-word
/// transcript can carry a content signal, the worst case is "some garbage slips
/// through", never "real dictation dropped". When in doubt, don't flag.
///
/// `durationSeconds` is accepted (the production path always has it) so the
/// signature is ready to combine a duration/word-rate signal with a content
/// signal in future tuning, but it currently never causes a drop on its own —
/// duration- and comma-based signals overlap with real short/slow speech and
/// real lists, which is exactly the false-positive class we refuse to risk.
enum TranscriptionGarbageFilter {

    /// Returns true when `text` looks like transcription garbage and should be
    /// dropped. A content signal (blank-audio token, no alphabetic content, or
    /// pure ellipsis fragmentation) is always required; `durationSeconds` never
    /// causes a drop on its own.
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
        // that is purely punctuation/symbols is garbage.
        if !containsRealContent(raw) {
            return true
        }

        // C3: pure ellipsis fragmentation — the transcript is dominated by
        // ellipsis runs with almost no real words. "I think... maybe Friday
        // works." (one ellipsis, real words) is NOT this; "..., ..., um..., ..."
        // is. Requires a content signal's worth of evidence to stand alone.
        if isPureEllipsisFragmentation(raw) {
            return true
        }

        // ── No content signal → keep the transcript. ──
        //
        // Every transcript that reaches this point contains real words. Weak
        // signals (comma-fragmentation, word/char-rate mismatch) overlap with
        // real short/slow speech and real lists, so they are deliberately NOT
        // consulted here: dropping real dictation is the cardinal sin.
        return false
    }

    // MARK: - Content signals

    /// True when the whole trimmed transcript is a single blank-audio / silence
    /// marker (optionally wrapped in `[...]` or `(...)`). Whole-string match only.
    private static func isBlankAudioToken(_ raw: String) -> Bool {
        let lower = raw.lowercased()

        // Exact whole-transcript markers. ONLY bracketed/parenthesized forms (or
        // the underscored machine token "blank_audio") are listed — bare words
        // like "silence", "music", "pause" are valid dictation and must NOT be
        // dropped, so they are deliberately excluded here.
        let exactMarkers: Set<String> = [
            "[blank_audio]", "(blank_audio)", "blank_audio",
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

    /// True when the transcript is overwhelmingly ellipsis with almost no real
    /// letters — pure trailing-off junk. Conservative: needs multiple ellipsis
    /// runs AND very few alphabetic characters, so genuine hesitation ("I
    /// think... maybe Friday works.") and dense CJK/Thai speech with ellipsis
    /// pauses (which have no whitespace to tokenize) both survive.
    ///
    /// Measured in LETTERS, not whitespace tokens, so spacing differences across
    /// scripts can't turn real speech into "one token" and falsely flag it.
    private static func isPureEllipsisFragmentation(_ raw: String) -> Bool {
        // Require MANY ellipsis runs (>= 5). Short disfluent speech — common in
        // CJK, e.g. "嗯...好...行..." (3 runs) — must never reach this rule, since
        // a few characters is normal real content for those scripts.
        let ellipsisRuns = countEllipsisRuns(raw)
        guard ellipsisRuns >= 5 else { return false }

        // Total real-content characters (letters in any script + digits).
        let contentCount = raw.filter { $0.isLetter || $0.isNumber }.count

        // Pure junk: 5+ ellipsis runs and content no greater than the run count
        // (i.e. on the order of one stray filler char per run — "um"/"uh"). Any
        // genuine utterance, even a hesitant one, carries far more real content
        // than ellipses, so it is kept. When in doubt, don't flag.
        return contentCount <= ellipsisRuns
    }

    /// Count runs of ASCII "..." (3+ dots) plus standalone Unicode ellipses "…".
    private static func countEllipsisRuns(_ raw: String) -> Int {
        var runs = 0
        var dotStreak = 0
        for ch in raw {
            if ch == "." {
                dotStreak += 1
            } else {
                if dotStreak >= 3 { runs += 1 }
                dotStreak = 0
                if ch == "\u{2026}" { runs += 1 }
            }
        }
        if dotStreak >= 3 { runs += 1 }
        return runs
    }

}
