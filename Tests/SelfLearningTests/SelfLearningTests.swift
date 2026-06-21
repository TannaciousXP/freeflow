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

        // --- Positives (MUST flag) ---

        // Pure ellipsis fragmentation + interjection (2 ambiguous signals combine).
        check(
            "flags ellipsis + interjection fragmentation",
            garbage("Okay, this is... oop, safety. Sir, hotel to zero, by the path."),
            "expected garbage"
        )

        // Explicit blank-audio token stands alone (unambiguous signal).
        check(
            "flags [BLANK_AUDIO] token alone",
            garbage("[BLANK_AUDIO]"),
            "expected garbage"
        )

        // (silence) marker stands alone.
        check(
            "flags (silence) token alone",
            garbage("(silence)"),
            "expected garbage"
        )

        // Heavy comma-fragmentation (3+ short chunks) + ellipsis = 2 signals.
        check(
            "flags comma-spam fragmentation with ellipsis",
            garbage("uh, no, so, by, the... path"),
            "expected garbage"
        )

        // Near-empty transcript on a long clip = extreme word/duration mismatch
        // (Whisper basically gave up on noisy audio). Flags alone. This is the
        // LocalFlow failure mode: e.g. 9s of audio → "Tested." Direction matters —
        // the ported signal catches TOO FEW words per second, not too many.
        check(
            "flags extreme word-rate mismatch (long clip, near-empty text)",
            garbage("Tested.", 9.0),
            "expected garbage"
        )

        // CJK extreme char-rate mismatch on a long clip flags alone.
        check(
            "flags extreme CJK char-rate mismatch",
            garbage("好", 30.0),
            "expected garbage"
        )

        // --- Negatives (MUST NOT flag — regression guard for real dictation) ---

        check(
            "keeps a normal short phrase",
            !garbage("okay let's ship it"),
            "false positive"
        )

        check(
            "keeps a single sentence with one comma",
            !garbage("Send the proposal to Sarah, please."),
            "false positive"
        )

        check(
            "keeps a normal multi-sentence dictation",
            !garbage("I went to the store this morning. It was raining hard. I bought an umbrella."),
            "false positive"
        )

        // The just-shipped list formatting must survive: a real list dictation.
        check(
            "keeps a real list dictation (eggs, milk, and bread)",
            !garbage("eggs, milk, and bread"),
            "false positive"
        )

        check(
            "keeps a legit short answer 'yes'",
            !garbage("yes"),
            "false positive"
        )

        check(
            "keeps a legit short answer 'no problem'",
            !garbage("no problem"),
            "false positive"
        )

        // One ellipsis only (single ambiguous signal) is NOT enough to flag.
        check(
            "keeps a single hesitation ellipsis",
            !garbage("I think... maybe Friday works."),
            "false positive"
        )

        // A normal-length dictation on a matching-length clip is fine.
        check(
            "keeps normal dictation with sensible duration",
            !garbage("Let's schedule the meeting for next Tuesday afternoon.", 3.0),
            "false positive"
        )

        // A real, longer list with commas + duration must survive (no false fragment flag,
        // chunks longer than 3 words each).
        check(
            "keeps a longer real list dictation",
            !garbage("for the trip we need sunscreen and towels, a cooler full of drinks, and the beach chairs"),
            "false positive"
        )

        // Empty / whitespace is not flagged as garbage here (existing pipeline handles emptiness).
        check(
            "empty string is not flagged",
            !garbage(""),
            "false positive"
        )

        // CJK normal speech on a sensible clip must NOT trip the char-rate signal.
        check(
            "keeps normal CJK speech",
            !garbage("我们今天下午开会讨论这个项目的进度", 5.0),
            "false positive"
        )

        // Spaceless non-CJK scripts (Thai here) have no word spacing, so the
        // word-rate signal would undercount them to ~1 token and falsely flag
        // legit long speech on a long clip. The duration signal is skipped for
        // them — this must NOT be flagged.
        check(
            "keeps normal Thai speech on a long clip (no false word-rate flag)",
            !garbage("สวัสดีครับวันนี้เราจะประชุมกันเรื่องโครงการใหม่ในช่วงบ่าย", 8.0),
            "false positive"
        )

        print("\n---\nPassed: \(passed)\nFailed: \(failed)")
        exit(failed == 0 ? 0 : 1)
    }
}
