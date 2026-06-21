import Foundation

@main
struct SelfLearningTests {
    static func main() {
        var passed = 0
        var failed = 0
        func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
            if cond {
                passed += 1
                print("PASS: \(name)")
            } else {
                failed += 1
                print("FAIL: \(name) — \(detail())")
            }
        }

        // 1. CommonWordGuard
        check(
            "guard rejects common words on left",
            !CommonWordGuard.isAllowedAsLearnedCorrection(original: "Hi", corrected: "Hello")
        )
        check(
            "guard rejects common words on right",
            !CommonWordGuard.isAllowedAsLearnedCorrection(original: "Greetz", corrected: "Hello")
        )
        check(
            "guard rejects single-char short edits",
            !CommonWordGuard.isAllowedAsLearnedCorrection(original: "from", corrected: "form")
        )
        check(
            "guard rejects short tokens",
            !CommonWordGuard.isAllowedAsLearnedCorrection(original: "ab", corrected: "ac")
        )
        check(
            "guard accepts a clear vocabulary pair",
            CommonWordGuard.isAllowedAsLearnedCorrection(original: "clawed", corrected: "Claude")
        )
        check(
            "guard accepts proper-noun fix",
            CommonWordGuard.isAllowedAsLearnedCorrection(original: "Aisha", corrected: "Aysha")
        )
        check(
            "guard accepts brand capitalization",
            CommonWordGuard.isAllowedAsLearnedCorrection(original: "openai", corrected: "OpenAI")
        )

        // 2. extractSingleWordSubstitutions
        let pairs1 = PostInsertionMonitor.extractSingleWordSubstitutions(
            original: "ask claud about it",
            edited: "ask Claude about it"
        )
        check(
            "extracts single-word substitution",
            pairs1 == [PostInsertionMonitor.CorrectionPair(original: "claud", corrected: "Claude")],
            "got \(pairs1)"
        )

        let pairs2 = PostInsertionMonitor.extractSingleWordSubstitutions(
            original: "ask claud about it",
            edited: "ask Claude about it please"
        )
        check(
            "extracts substitution alongside trailing insertion",
            pairs2 == [PostInsertionMonitor.CorrectionPair(original: "claud", corrected: "Claude")],
            "got \(pairs2)"
        )

        let pairs3 = PostInsertionMonitor.extractSingleWordSubstitutions(
            original: "hello world",
            edited: "hello world"
        )
        check(
            "no substitutions when identical",
            pairs3.isEmpty,
            "got \(pairs3)"
        )

        // Pure case differences should not register as substitutions —
        // LCS uses caseInsensitiveCompare so "hello" and "Hello" are matches.
        let pairs4 = PostInsertionMonitor.extractSingleWordSubstitutions(
            original: "hello world friend",
            edited: "Hello world friend"
        )
        check(
            "case-only changes are not substitutions",
            pairs4.isEmpty,
            "got \(pairs4)"
        )

        // 3. CorrectionLearningService round-trip + threshold
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("freeflow-smoke-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let storeURL = tmpDir.appendingPathComponent("learned_corrections.json")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let svc = CorrectionLearningService(storeURL: storeURL)
        _ = svc.recordCorrection(appBundle: "com.tinyspeck.slackmacgap", original: "clawed", corrected: "Claude")
        let belowThreshold = svc.relevantCorrections(forAppBundle: "com.tinyspeck.slackmacgap")
        check(
            "single observation stays below confidence threshold",
            belowThreshold.isEmpty,
            "got \(belowThreshold)"
        )

        _ = svc.recordCorrection(appBundle: "com.tinyspeck.slackmacgap", original: "clawed", corrected: "Claude")
        let active = svc.relevantCorrections(forAppBundle: "com.tinyspeck.slackmacgap")
        check(
            "two observations surface the correction",
            active == ["clawed": "Claude"],
            "got \(active)"
        )

        let otherApp = svc.relevantCorrections(forAppBundle: "com.apple.mail")
        check(
            "correction scoped to one app does not leak to another",
            otherApp.isEmpty,
            "got \(otherApp)"
        )

        // 4. Guard rejection persists at service layer too
        let rejected = svc.recordCorrection(appBundle: "x", original: "Hi", corrected: "Hello")
        check(
            "service rejects guard-failed pair (returns nil)",
            rejected == nil,
            "got \(rejected ?? -1)"
        )

        // 5. Persistence round-trip
        let svc2 = CorrectionLearningService(storeURL: storeURL)
        let reloaded = svc2.relevantCorrections(forAppBundle: "com.tinyspeck.slackmacgap")
        check(
            "JSON store reloads from disk on init",
            reloaded == ["clawed": "Claude"],
            "got \(reloaded)"
        )

        // 6. Prompt formatter
        let prompt = PostProcessingService.formatLearnedCorrectionsPrompt(["clawed": "Claude", "aisha": "Aysha"])
        check(
            "prompt formatter sorts alphabetically and includes both rules",
            prompt.contains("- aisha -> Aysha") && prompt.contains("- clawed -> Claude"),
            "got: \(prompt)"
        )
        check(
            "prompt formatter returns empty for empty dict",
            PostProcessingService.formatLearnedCorrectionsPrompt([:]).isEmpty
        )

        // 7. TranscriptionGarbageFilter — provider-agnostic hallucination/garbage guard.
        //    These run without network/metadata: the function is pure and takes an
        //    optional audio duration. False positives (dropping real dictation) are the
        //    cardinal sin, so the negatives below are the real regression guard.

        func garbage(_ text: String, _ dur: Double? = nil) -> Bool {
            TranscriptionGarbageFilter.isLikelyGarbage(text: text, durationSeconds: dur)
        }

        // DESIGN: the filter is CONTENT-anchored. A transcript is only dropped
        // when it carries a CONTENT signal that implies NO real speech — it IS a
        // blank-audio token, it is entirely non-alphabetic, or it is pure ellipsis
        // fragmentation. Duration/WPS and comma-fragmentation are WEAK signals
        // that may only ever *combine with* a content signal; they can never drop
        // a transcript that contains normal real words. When in doubt, don't flag.

        // --- Positives (MUST flag) ---

        // Blank-audio token IS the whole transcript (unambiguous content signal).
        check(
            "flags [BLANK_AUDIO] (whole transcript) at 10s",
            garbage("[BLANK_AUDIO]", 10.0),
            "expected garbage"
        )

        // (silence) standalone bracketed token is the whole transcript.
        check(
            "flags (silence) (whole transcript)",
            garbage("(silence)", 6.0),
            "expected garbage"
        )

        // Pure ellipsis / non-alphabetic transcript — no real words at all.
        check(
            "flags pure ellipsis transcript at 8s",
            garbage("... ... ...", 8.0),
            "expected garbage"
        )

        // Unicode ellipsis only, nothing else.
        check(
            "flags lone unicode ellipsis",
            garbage("\u{2026}", 4.0),
            "expected garbage"
        )

        // --- Negatives (MUST NOT flag — regression guard for real dictation) ---
        // All use a realistic duration where the production path would have one,
        // because parseTranscript ALWAYS has the audio duration.

        check(
            "keeps a normal short phrase",
            !garbage("okay let's ship it", 2.0),
            "false positive"
        )

        check(
            "keeps a single sentence with one comma",
            !garbage("Send the proposal to Sarah, please.", 3.0),
            "false positive"
        )

        check(
            "keeps a normal multi-sentence dictation",
            !garbage("I went to the store this morning. It was raining hard. I bought an umbrella.", 8.0),
            "false positive"
        )

        // The just-shipped list formatting must survive — the big regression:
        // 3 short comma chunks + 0.67 wps on a 6s clip must NOT drop a real list.
        check(
            "keeps a real list dictation (eggs, milk, and bread) @ 6s",
            !garbage("eggs, milk, and bread", 6.0),
            "false positive"
        )

        // Short list, short slow clip — comma-fragmentation + low wps together
        // must not drop it (no content signal present).
        check(
            "keeps a short list (first, second, third) @ 5s",
            !garbage("first, second, third", 5.0),
            "false positive"
        )

        // Extreme-low-wps standalone is UNSAFE: "yes" on a 3s clip = 0.33 wps.
        check(
            "keeps a legit short answer 'yes' @ 3s",
            !garbage("yes", 3.0),
            "false positive"
        )

        check(
            "keeps a legit short answer 'no problem' @ 4s",
            !garbage("no problem", 4.0),
            "false positive"
        )

        // A single, slow word on a long clip (extreme low wps) must still survive
        // — it is a real word, so no content signal, so no drop.
        check(
            "keeps a single real word on a long clip ('Tested.' @ 9s)",
            !garbage("Tested.", 9.0),
            "false positive"
        )

        // One hesitation ellipsis among real words is normal speech.
        check(
            "keeps a single hesitation ellipsis @ 4s",
            !garbage("I think... maybe Friday works.", 4.0),
            "false positive"
        )

        // Heavily disfluent real speech (stutter + many ellipsis pauses) must
        // survive: it contains real words, so it is never a content signal. The
        // filter is content-anchored and deliberately does NOT try to flag
        // ellipsis-with-filler junk, because that class overlaps with real
        // stuttering — recall of real speech beats catching every bit of garbage.
        check(
            "keeps heavily disfluent repeated-word speech @ 5s",
            !garbage("I... I... I... I... I...", 5.0),
            "false positive"
        )
        check(
            "keeps filler-with-ellipsis (conservative tradeoff) @ 2s",
            !garbage("..., ..., um..., ..., ..., uh..., ...", 2.0),
            "false positive"
        )

        // Substring false-trigger guard: "loop"/"scooped" must NOT match the
        // "oop " interjection token.
        check(
            "keeps speech containing 'loop'/'scooped' (no substring trigger)",
            !garbage("I scooped the data into a loop", 4.0),
            "false positive"
        )

        // A blank-token string embedded in REAL dictated speech must survive —
        // the token is not the whole transcript, so it is not a content signal.
        check(
            "keeps real speech that literally contains '(pause)'",
            !garbage("Add a dramatic (pause) right before the punch line.", 5.0),
            "false positive"
        )

        // A real, longer list with commas + duration must survive.
        check(
            "keeps a longer real list dictation @ 8s",
            !garbage("for the trip we need sunscreen and towels, a cooler full of drinks, and the beach chairs", 8.0),
            "false positive"
        )

        // Empty / whitespace is not flagged as garbage here (existing pipeline handles emptiness).
        check(
            "empty string is not flagged",
            !garbage("", 5.0),
            "false positive"
        )

        // CJK normal speech on a sensible clip must NOT trip the char-rate signal.
        check(
            "keeps normal CJK speech @ 5s",
            !garbage("我们今天下午开会讨论这个项目的进度", 5.0),
            "false positive"
        )

        // CJK comma-list: chunks to 1 word each + low cps, but no content signal,
        // so a real CJK list must NOT be dropped.
        check(
            "keeps a real CJK comma list @ 5s",
            !garbage("苹果，牛奶，面包", 5.0),
            "false positive"
        )

        // Spaceless non-CJK script (Thai) on a long clip must NOT trip word-rate.
        check(
            "keeps normal Thai speech on a long clip @ 8s",
            !garbage("สวัสดีครับวันนี้เราจะประชุมกันเรื่องโครงการใหม่ในช่วงบ่าย", 8.0),
            "false positive"
        )

        // Bare real English words that happen to be Whisper marker words must NOT
        // be dropped — only the BRACKETED forms are unambiguous markers.
        check(
            "keeps the real word 'silence' dictated alone @ 3s",
            !garbage("silence", 3.0),
            "false positive"
        )
        check(
            "keeps the real word 'music' dictated alone @ 3s",
            !garbage("music", 3.0),
            "false positive"
        )
        check(
            "keeps the real word 'pause' dictated alone @ 3s",
            !garbage("pause", 3.0),
            "false positive"
        )
        check(
            "keeps a real sentence using the word 'silence'",
            !garbage("We sat in complete silence.", 4.0),
            "false positive"
        )

        // CJK/Thai real speech with ellipsis pauses must NOT collapse to ~1
        // whitespace token and trip the pure-ellipsis content signal — it has
        // plenty of real letters, so it is real speech.
        check(
            "keeps CJK speech with ellipsis pauses @ 6s",
            !garbage("我在想... 也许我们应该... 等到下周再决定...", 6.0),
            "false positive"
        )
        // Adversarial: CJK with NO whitespace and 3+ ellipses collapses to one
        // whitespace token. Must NOT be dropped — it is dense with real letters.
        check(
            "keeps no-whitespace CJK speech with ellipses @ 6s",
            !garbage("我在想...也许我们应该...等到下周再决定...", 6.0),
            "false positive"
        )

        // Dictated numbers have no letters but ARE real content — must survive,
        // both as a plain number and as a number read with ellipsis pauses.
        check(
            "keeps a dictated number (no letters) @ 4s",
            !garbage("555 1234", 4.0),
            "false positive"
        )
        check(
            "keeps a price/time dictation @ 3s",
            !garbage("$20 at 10:30", 3.0),
            "false positive"
        )
        check(
            "keeps a phone number read with ellipsis pauses @ 6s",
            !garbage("555... 123... 4567...", 6.0),
            "false positive"
        )

        // Short, disfluent CJK speech with ellipsis pauses ("um... good... ok...")
        // is real content and must survive — few characters is normal for CJK.
        check(
            "keeps short disfluent CJK speech with ellipses @ 4s",
            !garbage("嗯...好...行...", 4.0),
            "false positive"
        )

        // Brace-wrapped text is never a Whisper marker (Whisper uses [..]/(..));
        // it can be real dictated code/JSON, so it must NOT be dropped.
        check(
            "keeps brace-wrapped '{silence}' (real dictated text)",
            !garbage("{silence}", 3.0),
            "false positive"
        )

        print("\n---\nPassed: \(passed)\nFailed: \(failed)")
        exit(failed == 0 ? 0 : 1)
    }
}
