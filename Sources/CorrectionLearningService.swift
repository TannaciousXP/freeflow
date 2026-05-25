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

    init(
        id: UUID = UUID(),
        appBundle: String?,
        original: String,
        corrected: String,
        count: Int = 1,
        firstSeen: Date = Date(),
        lastSeen: Date = Date()
    ) {
        self.id = id
        self.appBundle = appBundle
        self.original = original
        self.corrected = corrected
        self.count = count
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
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
    static let fileSchemaVersion = 1
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
                let resultingCount = corrections[idx].count
                persist()
                return resultingCount
            } else {
                let entry = LearnedCorrection(
                    appBundle: normalizedBundle,
                    original: trimmedOriginal,
                    corrected: trimmedCorrected,
                    count: 1,
                    firstSeen: now,
                    lastSeen: now
                )
                corrections.append(entry)
                persist()
                return 1
            }
        }
    }

    /// Returns the set of active corrections relevant to `appBundle`, merging
    /// app-specific entries with global (appBundle == nil) entries. App-specific
    /// entries win on `original` collisions. Only corrections at or above
    /// `minConfidence` are returned.
    func relevantCorrections(
        forAppBundle appBundle: String?,
        minConfidence: Int = CorrectionLearningService.defaultMinConfidence
    ) -> [String: String] {
        queue.sync {
            var result: [String: String] = [:]
            let normalizedBundle = appBundle?.isEmpty == true ? nil : appBundle

            // Globals first; app-specific can override.
            for c in corrections where c.appBundle == nil && c.count >= minConfidence {
                result[c.original] = c.corrected
            }
            if let normalizedBundle {
                for c in corrections where c.appBundle == normalizedBundle && c.count >= minConfidence {
                    result[c.original] = c.corrected
                }
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
