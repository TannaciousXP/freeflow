import Foundation
import os.log

private let learningLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "CorrectionLearning")

struct LearnedCorrection: Codable, Identifiable, Equatable {
    let id: UUID
    var appBundle: String?
    var original: String
    var corrected: String
    var count: Int
    var firstSeen: Date
    var lastSeen: Date
    var lastApplied: Date?
    var distinctApps: Set<String>

    enum CodingKeys: String, CodingKey {
        case id, appBundle, original, corrected, count, firstSeen, lastSeen, lastApplied, distinctApps
    }

    init(
        id: UUID = UUID(),
        appBundle: String?,
        original: String,
        corrected: String,
        count: Int = 1,
        firstSeen: Date = Date(),
        lastSeen: Date = Date(),
        lastApplied: Date? = nil,
        distinctApps: Set<String> = []
    ) {
        self.id = id
        self.appBundle = appBundle
        self.original = original
        self.corrected = corrected
        self.count = count
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.lastApplied = lastApplied
        self.distinctApps = distinctApps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        appBundle = try c.decodeIfPresent(String.self, forKey: .appBundle)
        original = try c.decode(String.self, forKey: .original)
        corrected = try c.decode(String.self, forKey: .corrected)
        count = try c.decode(Int.self, forKey: .count)
        firstSeen = try c.decode(Date.self, forKey: .firstSeen)
        lastSeen = try c.decode(Date.self, forKey: .lastSeen)
        lastApplied = try c.decodeIfPresent(Date.self, forKey: .lastApplied)
        distinctApps = try c.decodeIfPresent(Set<String>.self, forKey: .distinctApps)
            ?? (appBundle.map { Set([$0]) } ?? Set<String>())
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(appBundle, forKey: .appBundle)
        try c.encode(original, forKey: .original)
        try c.encode(corrected, forKey: .corrected)
        try c.encode(count, forKey: .count)
        try c.encode(firstSeen, forKey: .firstSeen)
        try c.encode(lastSeen, forKey: .lastSeen)
        try c.encodeIfPresent(lastApplied, forKey: .lastApplied)
        try c.encode(Array(distinctApps).sorted(), forKey: .distinctApps)
    }
}

private struct LearnedCorrectionsFile: Codable {
    var version: Int
    var corrections: [LearnedCorrection]
}

/// Persists per-user correction pairs learned from observing edits the user
/// makes to dictated text. Corrections are scoped by app bundle id, with
/// app=nil meaning a global correction.
///
/// Threshold semantics: a correction is "active" once seen `minConfidence`
/// times. Below threshold it's still recorded but not surfaced to the
/// post-processing prompt — this avoids one-off typos becoming sticky rules.
final class CorrectionLearningService {
    static let fileSchemaVersion = 2
    static let defaultMinConfidence = 2
    static let maxOriginalLength = 40
    static let maxCorrectedLength = 60

    private let storeURL: URL
    private let queue = DispatchQueue(label: "com.zachlatta.freeflow.correction-learning", qos: .utility)
    private var corrections: [LearnedCorrection]
    private let isPersistent: Bool

    init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
            self.isPersistent = true
        } else if let resolved = Self.defaultStoreURL() {
            self.storeURL = resolved
            self.isPersistent = true
        } else {
            self.storeURL = URL(fileURLWithPath: "/dev/null")
            self.isPersistent = false
        }
        self.corrections = Self.loadFromDisk(at: self.storeURL, persistent: self.isPersistent)
    }

    // MARK: - Public API

    /// Record an observed correction. If an identical (appBundle, original, corrected)
    /// triple already exists, its count is incremented and lastSeen is updated.
    /// Returns the resulting correction's new count, or nil if rejected.
    @discardableResult
    func recordCorrection(
        appBundle: String?,
        original: String,
        corrected: String
    ) -> Int? {
        let trimmedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCorrected = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOriginal.isEmpty, !trimmedCorrected.isEmpty else { return nil }
        guard trimmedOriginal != trimmedCorrected else { return nil }
        guard trimmedOriginal.count <= Self.maxOriginalLength else { return nil }
        guard trimmedCorrected.count <= Self.maxCorrectedLength else { return nil }
        guard CommonWordGuard.isAllowedAsLearnedCorrection(
            original: trimmedOriginal,
            corrected: trimmedCorrected
        ) else {
            os_log(
                .info,
                log: learningLog,
                "Rejected correction by guard: '%{public}@' -> '%{public}@'",
                trimmedOriginal,
                trimmedCorrected
            )
            return nil
        }

        return queue.sync {
            let now = Date()
            let normalizedBundle = appBundle?.isEmpty == true ? nil : appBundle
            if let idx = corrections.firstIndex(where: {
                $0.appBundle == normalizedBundle
                    && $0.original.caseInsensitiveCompare(trimmedOriginal) == .orderedSame
                    && $0.corrected == trimmedCorrected
            }) {
                corrections[idx].count += 1
                corrections[idx].lastSeen = now
                if let bundle = normalizedBundle {
                    corrections[idx].distinctApps.insert(bundle)
                }
                let resultingCount = corrections[idx].count
                if resultingCount == Self.defaultMinConfidence {
                    NotificationCenter.default.post(
                        name: Notification.Name("freeflow.didLearnCorrection"),
                        object: nil,
                        userInfo: ["original": trimmedOriginal, "corrected": trimmedCorrected]
                    )
                }
                if normalizedBundle != nil {
                    promoteIfNeeded(original: trimmedOriginal, corrected: trimmedCorrected, now: now)
                }
                persist()
                return resultingCount
            } else {
                let appDistinct: Set<String> = normalizedBundle.map { Set([$0]) } ?? Set<String>()
                let entry = LearnedCorrection(
                    appBundle: normalizedBundle,
                    original: trimmedOriginal,
                    corrected: trimmedCorrected,
                    count: 1,
                    firstSeen: now,
                    lastSeen: now,
                    lastApplied: nil,
                    distinctApps: appDistinct
                )
                corrections.append(entry)
                if normalizedBundle != nil {
                    promoteIfNeeded(original: trimmedOriginal, corrected: trimmedCorrected, now: now)
                }
                persist()
                return 1
            }
        }
    }

    /// Returns the set of active corrections relevant to `appBundle`, merging
    /// app-specific entries with global (appBundle == nil) entries. App-specific
    /// entries win on `original` collisions. Only corrections whose effective
    /// confidence (count * time-decay factor) meets `minConfidence` are returned.
    /// Updates `lastApplied` on every returned correction.
    func relevantCorrections(
        forAppBundle appBundle: String?,
        minConfidence: Int = CorrectionLearningService.defaultMinConfidence,
        now: Date = Date()
    ) -> [String: String] {
        queue.sync {
            var result: [String: String] = [:]
            var includedIndices: [Int] = []
            let normalizedBundle = appBundle?.isEmpty == true ? nil : appBundle

            for (i, c) in corrections.enumerated() where c.appBundle == nil {
                let effective = Double(c.count) * decayFactor(now: now, lastSeen: c.lastSeen)
                if effective >= Double(minConfidence) {
                    result[c.original] = c.corrected
                    includedIndices.append(i)
                }
            }
            if let normalizedBundle {
                for (i, c) in corrections.enumerated() where c.appBundle == normalizedBundle {
                    let effective = Double(c.count) * decayFactor(now: now, lastSeen: c.lastSeen)
                    if effective >= Double(minConfidence) {
                        result[c.original] = c.corrected
                        includedIndices.append(i)
                    }
                }
            }
            for i in includedIndices {
                corrections[i].lastApplied = now
            }
            if !includedIndices.isEmpty {
                persist()
            }
            return result
        }
    }

    func allCorrections() -> [LearnedCorrection] {
        queue.sync { corrections }
    }

    func delete(id: UUID) {
        queue.sync {
            corrections.removeAll { $0.id == id }
            persist()
        }
    }

    func clearAll() {
        queue.sync {
            corrections.removeAll()
            persist()
        }
    }

    /// Removes corrections where lastSeen > 90 days old AND lastApplied is nil
    /// or > 60 days old. Persists after pruning. Returns count of removed entries.
    @discardableResult
    func pruneDecayedCorrections(now: Date = Date()) -> Int {
        queue.sync {
            let before = corrections.count
            corrections.removeAll { c in
                let lastSeenAgeDays = now.timeIntervalSince(c.lastSeen) / 86_400
                guard lastSeenAgeDays > 90 else { return false }
                if let applied = c.lastApplied {
                    return now.timeIntervalSince(applied) / 86_400 > 60
                }
                return true
            }
            let removed = before - corrections.count
            if removed > 0 { persist() }
            return removed
        }
    }

    // MARK: - Private helpers

    private func decayFactor(now: Date, lastSeen: Date) -> Double {
        let days = now.timeIntervalSince(lastSeen) / 86_400
        if days <= 30 { return 1.0 }
        if days <= 90 { return 0.5 }
        return 0.25
    }

    private func promoteIfNeeded(original: String, corrected: String, now: Date) {
        let perApp = corrections.filter {
            $0.appBundle != nil
                && $0.original.caseInsensitiveCompare(original) == .orderedSame
                && $0.corrected == corrected
        }
        let allDistinct = perApp.reduce(Set<String>()) { $0.union($1.distinctApps) }
        guard allDistinct.count >= 3 else { return }
        let sumCount = perApp.reduce(0) { $0 + $1.count }
        if let idx = corrections.firstIndex(where: {
            $0.appBundle == nil
                && $0.original.caseInsensitiveCompare(original) == .orderedSame
                && $0.corrected == corrected
        }) {
            corrections[idx].count = sumCount
            corrections[idx].lastSeen = now
        } else {
            corrections.append(LearnedCorrection(
                appBundle: nil,
                original: original,
                corrected: corrected,
                count: sumCount,
                firstSeen: now,
                lastSeen: now,
                lastApplied: nil,
                distinctApps: []
            ))
        }
    }

    // MARK: - Persistence

    private func persist() {
        guard isPersistent else { return }
        let payload = LearnedCorrectionsFile(version: Self.fileSchemaVersion, corrections: corrections)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)

            let tempURL = storeURL.deletingLastPathComponent()
                .appendingPathComponent(".learned_corrections.tmp")
            try data.write(to: tempURL, options: .atomic)
            let fm = FileManager.default
            if fm.fileExists(atPath: storeURL.path) {
                _ = try? fm.replaceItemAt(storeURL, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: storeURL)
            }
        } catch {
            os_log(
                .error,
                log: learningLog,
                "Failed to persist learned corrections: %{public}@",
                error.localizedDescription
            )
        }
    }

    private static func defaultStoreURL() -> URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let base = appSupport.appendingPathComponent(AppName.displayName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            os_log(
                .error,
                log: learningLog,
                "Failed to create app support dir for learned corrections: %{public}@",
                error.localizedDescription
            )
            return nil
        }
        return base.appendingPathComponent("learned_corrections.json")
    }

    private static func loadFromDisk(at url: URL, persistent: Bool) -> [LearnedCorrection] {
        guard persistent else { return [] }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(LearnedCorrectionsFile.self, from: data)
            return file.corrections
        } catch {
            os_log(
                .error,
                log: learningLog,
                "Failed to load learned corrections (will start empty): %{public}@",
                error.localizedDescription
            )
            return []
        }
    }
}
