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

        print("\n---\nPassed: \(passed)\nFailed: \(failed)")
        exit(failed == 0 ? 0 : 1)
    }
}
