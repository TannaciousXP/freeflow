import Foundation
import AppKit
import os.log

private let monitorLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "PostInsertionMonitor")

/// Observes the focused text field after FreeFlow inserts a dictated transcript
/// and learns word-level corrections the user makes within a short window.
///
/// Conservative v1 capture: we only learn when the focused field's text right
/// after the paste equals exactly the inserted text (i.e. the user dictated
/// into an empty field, or replaced a selection entirely). This skips the
/// "dictated into the middle of an existing document" case to avoid noisy
/// learning signals. After a single re-read at `finalReadDelay`, we diff
/// post-paste text vs the field's current text and extract single-word
/// substitutions via LCS alignment. CommonWordGuard rejects noise pairs.
final class PostInsertionMonitor {
    static let postPasteSnapshotDelay: TimeInterval = 1.0
    static let finalReadDelay: TimeInterval = 20.0
    static let maxObservedFieldLength = 4_000

    var isEnabled: Bool = true

    private let learningService: CorrectionLearningService
    private let queue = DispatchQueue(label: "com.zachlatta.freeflow.post-insertion-monitor", qos: .utility)
    private var activeWorkItem: DispatchWorkItem?

    init(learningService: CorrectionLearningService) {
        self.learningService = learningService
    }

    /// Begin observing the focused field after a dictation paste. Safe to call
    /// from any thread; scheduling happens off the main queue.
    func track(insertedText: String) {
        guard isEnabled else { return }
        let trimmed = insertedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed.count <= Self.maxObservedFieldLength else { return }

        // Cancel any previous in-flight observation. We only track the most
        // recent dictation — overlapping dictations would confuse the diff.
        queue.async { [weak self] in
            self?.activeWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.snapshotAfterPaste(insertedText: trimmed)
            }
            self?.activeWorkItem = work
            self?.queue.asyncAfter(deadline: .now() + Self.postPasteSnapshotDelay, execute: work)
        }
    }

    // MARK: - Pipeline steps

    private func snapshotAfterPaste(insertedText: String) {
        guard let snap = readFocusedFieldOnMain() else {
            os_log(.debug, log: monitorLog, "Skipping learn: no focused field after paste")
            return
        }
        let normalizedField = Self.normalizeForCompare(snap.text)
        let normalizedInserted = Self.normalizeForCompare(insertedText)

        // Conservative gate: only learn when the field's content matches the
        // dictation we just inserted. Skips "dictated into a partial document"
        // cases where the diff would be too ambiguous.
        guard normalizedField == normalizedInserted else {
            os_log(
                .debug,
                log: monitorLog,
                "Skipping learn: field text does not match inserted text (field=%{public}d chars, inserted=%{public}d chars)",
                normalizedField.count,
                normalizedInserted.count
            )
            return
        }

        let baseline = FocusedFieldSnapshot(text: snap.text, appBundle: snap.appBundle)
        let finalReadWork = DispatchWorkItem { [weak self] in
            self?.finalRead(baseline: baseline)
        }
        activeWorkItem = finalReadWork
        queue.asyncAfter(deadline: .now() + Self.finalReadDelay, execute: finalReadWork)
    }

    private func finalRead(baseline: FocusedFieldSnapshot) {
        guard let final = readFocusedFieldOnMain() else { return }

        // If the user has switched apps, the AX field we'd be reading is in a
        // different context. Abandon — we can't reliably attribute edits.
        guard final.appBundle == baseline.appBundle else {
            os_log(.debug, log: monitorLog, "Skipping learn: app changed since paste")
            return
        }

        guard final.text != baseline.text else { return } // nothing edited
        guard final.text.count <= Self.maxObservedFieldLength else { return }

        let pairs = Self.extractSingleWordSubstitutions(
            original: baseline.text,
            edited: final.text
        )
        guard !pairs.isEmpty else { return }

        for pair in pairs {
            let count = learningService.recordCorrection(
                appBundle: final.appBundle,
                original: pair.original,
                corrected: pair.corrected
            )
            if let count {
                os_log(
                    .info,
                    log: monitorLog,
                    "Learned correction (%{public}d): '%{public}@' -> '%{public}@' (app=%{public}@)",
                    count,
                    pair.original,
                    pair.corrected,
                    final.appBundle ?? "unknown"
                )
            }
        }
    }

    // MARK: - Helpers

    private func readFocusedFieldOnMain() -> FocusedFieldSnapshot? {
        // AX queries are technically safe off the main thread but the rest of
        // the app reads NSWorkspace/AX state on the main thread; keep that
        // contract consistent.
        if Thread.isMainThread {
            return AppContextService.snapshotFocusedField()
        }
        var result: FocusedFieldSnapshot?
        DispatchQueue.main.sync {
            result = AppContextService.snapshotFocusedField()
        }
        return result
    }

    /// Strip trailing whitespace (FreeFlow appends a trailing space after
    /// sentence-ending punctuation) and normalize line endings before
    /// comparing the post-paste field text to the inserted text.
    static func normalizeForCompare(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct CorrectionPair: Equatable {
        let original: String
        let corrected: String
    }

    /// Word-level LCS-based extraction. Returns substitution pairs for both
    /// single-word swaps and multi-word runs (2–3 words each side, ±1 count
    /// tolerance). Single-word behavior is unchanged.
    static func extractSingleWordSubstitutions(
        original: String,
        edited: String
    ) -> [CorrectionPair] {
        let origTokens = tokenizeWords(original)
        let editTokens = tokenizeWords(edited)
        guard !origTokens.isEmpty, !editTokens.isEmpty else { return [] }

        let raw = buildRawAlignment(origTokens, editTokens)
        var pairs: [CorrectionPair] = []
        var residual: [AlignStep] = []

        var i = 0
        while i < raw.count {
            // Multi-word: contiguous N deletes then M inserts, N∈[2,3], |N-M|≤1.
            if case .delete = raw[i] {
                var dels: [String] = []
                var j = i
                while j < raw.count, case .delete(let w) = raw[j] { dels.append(w); j += 1 }
                var ins: [String] = []
                while j < raw.count, case .insert(let w) = raw[j] { ins.append(w); j += 1 }
                let nd = dels.count, ni = ins.count
                if nd >= 2 && nd <= 3 && ni >= 1 && abs(nd - ni) <= 1 {
                    let orig = dels.joined(separator: " ")
                    let corr = ins.joined(separator: " ")
                    if orig.count <= 40 && corr.count <= 40 {
                        pairs.append(CorrectionPair(original: orig, corrected: corr))
                    }
                    i = j; continue
                }
            }

            // Vice-versa: contiguous N inserts then M deletes, N∈[2,3], |N-M|≤1.
            if case .insert = raw[i] {
                var ins: [String] = []
                var j = i
                while j < raw.count, case .insert(let w) = raw[j] { ins.append(w); j += 1 }
                var dels: [String] = []
                while j < raw.count, case .delete(let w) = raw[j] { dels.append(w); j += 1 }
                let nd = dels.count, ni = ins.count
                if ni >= 2 && ni <= 3 && nd >= 1 && abs(ni - nd) <= 1 {
                    let orig = dels.joined(separator: " ")
                    let corr = ins.joined(separator: " ")
                    if orig.count <= 40 && corr.count <= 40 {
                        pairs.append(CorrectionPair(original: orig, corrected: corr))
                    }
                    i = j; continue
                }
            }

            residual.append(raw[i])
            i += 1
        }

        // Single-word substitutions from the non-multi-word residual.
        for step in collapseRaw(residual) {
            if case .substitute(let o, let e) = step {
                pairs.append(CorrectionPair(original: o, corrected: e))
            }
        }
        return pairs
    }

    private static func tokenizeWords(_ text: String) -> [String] {
        // Split on whitespace, drop empty tokens, preserve case for the
        // corrected form. Punctuation is trimmed from the edges only so we
        // don't learn "claud," vs "Claude" as distinct words.
        let separators = CharacterSet.whitespacesAndNewlines
        let edgeStrip = CharacterSet.punctuationCharacters
        return text
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: edgeStrip) }
            .filter { !$0.isEmpty }
    }

    enum AlignStep: Equatable {
        case match(String)
        case substitute(String, String)
        case insert(String)
        case delete(String)
    }

    /// Builds a raw LCS alignment (match/delete/insert only, no substitutes).
    private static func buildRawAlignment(_ a: [String], _ b: [String]) -> [AlignStep] {
        let m = a.count
        let n = b.count
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 1...max(m, 1) {
            guard i <= m else { break }
            for j in 1...max(n, 1) {
                guard j <= n else { break }
                if a[i - 1].caseInsensitiveCompare(b[j - 1]) == .orderedSame {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        var raw: [AlignStep] = []
        var i = m
        var j = n
        while i > 0 && j > 0 {
            if a[i - 1].caseInsensitiveCompare(b[j - 1]) == .orderedSame {
                raw.append(.match(b[j - 1]))
                i -= 1
                j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                raw.append(.delete(a[i - 1]))
                i -= 1
            } else {
                raw.append(.insert(b[j - 1]))
                j -= 1
            }
        }
        while i > 0 { raw.append(.delete(a[i - 1])); i -= 1 }
        while j > 0 { raw.append(.insert(b[j - 1])); j -= 1 }
        raw.reverse()
        return raw
    }

    /// Collapses adjacent delete/insert pairs (in either order) into substitute.
    private static func collapseRaw(_ raw: [AlignStep]) -> [AlignStep] {
        var collapsed: [AlignStep] = []
        var k = 0
        while k < raw.count {
            if k + 1 < raw.count {
                switch (raw[k], raw[k + 1]) {
                case let (.delete(o), .insert(e)):
                    collapsed.append(.substitute(o, e)); k += 2; continue
                case let (.insert(e), .delete(o)):
                    collapsed.append(.substitute(o, e)); k += 2; continue
                default:
                    break
                }
            }
            collapsed.append(raw[k])
            k += 1
        }
        return collapsed
    }

    /// Computes a Myers-style LCS alignment over word tokens, then converts
    /// adjacent insert+delete pairs into a single `substitute` step.
    static func wordLevelLCSAlignment(_ a: [String], _ b: [String]) -> [AlignStep] {
        collapseRaw(buildRawAlignment(a, b))
    }
}
