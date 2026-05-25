import SwiftUI

// MARK: - First Run Disclosure View

struct FirstRunDisclosureView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("About Self-Learning")
                .font(.title2)
                .fontWeight(.semibold)

            Text(
                "FreeFlow learns from your edits. Corrections you make to dictated text get applied to future dictations in the same app. Common words and short typos are never learned. You can disable this anytime in Settings → Learned Corrections."
            )
            .font(.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Turn it off") {
                    appState.isSelfLearningEnabled = false
                    FirstRunDisclosure.markShown()
                    dismiss()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Keep it on") {
                    FirstRunDisclosure.markShown()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

// MARK: - Helper

enum FirstRunDisclosure {
    private static let defaultsKey = "selfLearningDisclosureShown"

    /// Returns true when the disclosure should be shown: self-learning is on
    /// and the user has not yet acknowledged it this device.
    static func shouldShow(appState: AppState) -> Bool {
        !UserDefaults.standard.bool(forKey: defaultsKey) && appState.isSelfLearningEnabled
    }

    /// Persists the acknowledgement so the disclosure is never shown again.
    static func markShown() {
        UserDefaults.standard.set(true, forKey: defaultsKey)
    }
}
