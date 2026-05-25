# Engineering Notes

A running log of non-obvious gotchas hit during FreeFlow development. Each
entry answers: what broke, why, how to spot it again, how to fix.

---

## SwiftUI sheet dismissal races with focus-loss commit handlers

**Symptom.** User types into a `SecureField`/`TextField` inside a `.sheet`,
clicks a Done button that calls `dismiss()`, and the typed value never reaches
the underlying model. The field looked accepted in the UI; the binding's local
`@State` got the value; but `appState.someProperty` still holds the old value
when the next step reads it. Common downstream failure: an auth error pointing
at the right host, because the *previous* (wrong) credential got used.

**Root cause.** A common commit pattern looks like:

```swift
.onChange(of: fieldFocused) { isFocused in
    if !isFocused { commit() }
}
```

SwiftUI's `dismiss()` can tear down the sheet view tree before the focus-loss
change publishes. The `.onChange` never fires, the commit never runs, the
value is lost.

**Detection.**
- User pastes a credential, hits Done, then operation fails with an auth error
  pointing at the right endpoint (so routing is correct — only the value is
  wrong).
- Inspect `~/Library/Application Support/<bundle>/.settings`. The field's
  storage key is absent or holds the old value.
- Quick test: tab OUT of the field before clicking Done. If that fixes it,
  this is the bug.

**Fix pattern.** Force-commit on every dismissal path *inside the sheet
itself*. Don't rely on the inner reusable component's focus-loss commit —
that was designed for inline use where focus naturally moves to other UI;
in a sheet, dismissal can preempt it.

```swift
Button("Done") {
    commitSheetInputs()  // explicit
    dismiss()
}
// ...
.onDisappear { commitSheetInputs() }  // belt and suspenders

private func commitSheetInputs() {
    let trimmed = fieldInput.trimmingCharacters(in: .whitespacesAndNewlines)
    fieldInput = trimmed
    if appState.field != trimmed {
        appState.field = trimmed
    }
}
```

**Reference.** `Sources/SetupView.swift` — `SetupProviderSettingsSheet`.

---

## AVCaptureSession cold-start can block `startRunning()` for 10+ seconds

**Symptom.** First hotkey press of a process freezes the UI for ~15 seconds,
then either fails or completes after the user has already released the
trigger — producing "0 audio buffers received" and a generic capture-session
error.

**Root cause.** On systems with multiple HAL plug-ins registered
(ZoomAudioDevice, virtual audio routers, Continuity Camera in the audio
device list), the *first* `AVCaptureSession.startRunning()` in a process
blocks while CoreAudio negotiates device acquisition. Subsequent sessions
in the same process are fast.

**Fix pattern.**
1. **Pre-warm** immediately after mic permission is `.authorized`, off the
   main thread. Create a throwaway session, call `startRunning()`, then
   `stopRunning()`. Cost paid once; user's first real recording is snappy.
2. **Always dispatch `startRecording()` off the main thread** so the UI never
   freezes if pre-warming hasn't happened yet (or the user reinstalled
   between launches, etc.).
3. **Gate pre-warm on `AVCaptureDevice.authorizationStatus(for: .audio) ==
   .authorized`** — never trigger out-of-context permission prompts.
4. **Make the warm-up idempotent.** A static lock guards against re-entry so
   the wired-in callsites (app launch, setup completion) can both call it
   without coordination.

**Reference.**
- `Sources/AudioRecorder.swift` — `warmUpDefaultDevice(deviceUID:)`
- `Sources/AppDelegate.swift` — `warmUpAudioCaptureIfAuthorized()` wired into
  `applicationDidFinishLaunching` (existing setups) and `completeSetup` (new
  setups).

---

## Forced `AVCaptureAudioDataOutput.audioSettings` → `-67440` on macOS 26.5

**Symptom.** Capture session starts, then immediately throws
`AVCaptureSessionRuntimeError` with `NSOSStatusErrorDomain` code `-67440`
(`kAudioFormatNotSupported`). Worked fine on earlier macOS versions.

**Root cause.** Setting an explicit `audioSettings = [...]` dict on the data
output (e.g. requesting 16 kHz mono Int16 PCM) is rejected on macOS 26.5.
Earlier macOS versions tolerated the same dict.

**Fix.** Don't set `audioSettings` at all. Receive sample buffers in
device-native format (typically 48 kHz Float32 stereo) and convert downstream
via `AVAudioConverter` when writing the file. The downstream conversion path
already existed — the forced dict was redundant.

**Reference.** `Sources/AudioRecorder.swift` — see the comment block above
the (removed) `dataOutput.audioSettings = ...` block in `makeSession()`.

---

## Async `startRecording()` stacks if the start handler doesn't guard re-entry

**Symptom.** Holding a dictation hotkey stacks multiple `AVCaptureSession`
instances. Logs show repeated "capture session running..." entries. Resource
leaks. Sometimes manifests only on slow first-session start (when the cold
warm-up is happening) because that's the only window where the start handler
hasn't yet flipped the recorder state.

**Root cause.** The previous synchronous `startRecording` blocked the main
thread, implicitly serializing key-repeat events. Once `startRecording`
dispatches off-thread, repeat ticks fire `.start` again while the first
session is still being built, and each one stacks a fresh recorder.

**Fix pattern.** In *every* handler that now dispatches start asynchronously,
gate on "is there already an in-flight or active recorder?":

```swift
guard testPhase == .idle || testPhase == .done,
      testAudioRecorder == nil else { return }
```

The state-machine check alone isn't enough — `testPhase` doesn't flip until
*after* you allocate the recorder, so concurrent repeat ticks can both
pass that check. The `testAudioRecorder == nil` part is the actual re-entry
guard.

**Reference.** `Sources/SetupView.swift` — test hotkey harness `.start` case.

---

## Two-tier URL resolver: transcription override + primary

**Architecture.** FreeFlow stores **two** API endpoints, not one:

| Storage | Purpose |
|---|---|
| `apiBaseURL` + `apiKey` | Primary provider (post-processing always; transcription fallback) |
| `transcriptionAPIURL` + `transcriptionAPIKey` | Optional transcription override |

The transcription resolver:

```swift
resolvedTranscriptionBaseURL =
    transcriptionAPIURL.trimmed.nonEmpty
        ?? (apiBaseURL == defaultAPIBaseURL  // OpenRouter (no Whisper)
                ? defaultTranscriptionAPIURL  // → OpenAI
                : apiBaseURL)                 // legacy fallback
```

**Why the special case for the default URL.** OpenRouter doesn't expose
`/v1/audio/transcriptions` — only chat/completion. The default provider
configuration is **OpenAI for transcription + OpenRouter for
post-processing**. When the primary is the default OpenRouter URL and the
user hasn't set a transcription override, the resolver hard-routes to OpenAI
or transcription is broken on fresh installs.

**Gotcha.** `resolvedTranscriptionAPIKey` falls back to `apiKey` when the
transcription override key is empty. If the user sets a transcription
**URL** override but forgets the **key**, the primary key gets sent to the
override URL → auth failure. The provider-settings UI must communicate that
both fields are needed for a true hybrid.

**Reference.**
- `Sources/AppState.swift` — `resolvedTranscriptionBaseURL`,
  `resolvedTranscriptionAPIKey`, `makeTranscriptionService()`.
- `Sources/PostProcessingService.swift` — uses the primary `apiBaseURL` +
  `apiKey` directly (no override path on this side).

---

## Model-specific payload params should gate on model name, not constant equality

**Symptom.** Changing `defaultModel` to a different model causes 400 errors
from the provider because a model-specific payload param (e.g.
`reasoning_effort`) is now being sent to a model that doesn't understand it.

**Root cause.** Code wrote `if model == defaultModel { payload["reasoning_effort"] = ... }`.
That gate fires whenever `model` matches whatever `defaultModel` happens to be
right now, not whenever `model` is the specific model that actually accepts
the param.

**Fix pattern.** Gate on the model name's *characteristic*, not on equality
with a default that may shift over time.

```swift
private static func modelAcceptsReasoningEffort(_ model: String) -> Bool {
    model.localizedCaseInsensitiveContains("gpt-oss")
}
```

This survives renaming the default and keeps gpt-oss support working if a
user opts back into it explicitly.

**Reference.** `Sources/PostProcessingService.swift` — `modelAcceptsReasoningEffort`.

---

## `os_log(.info)` is filtered out of `log show` by default

**Gotcha.** `/usr/bin/log show --process "FreeFlow Dev"` by default only
shows Default-level messages. `os_log(.info, ...)` lines are filtered out.
During diagnostics you'll see CoreAudio system traces but none of the app's
own info-level traces — which makes it look like the app isn't logging
anything.

**Fix.**

```sh
/usr/bin/log show --process "FreeFlow Dev" --info --last 5m
/usr/bin/log show --process "FreeFlow Dev" --info --debug --last 5m  # plus .debug
```

For live tailing, the same flags apply to `log stream`. Filter by subsystem
to reduce noise:

```sh
/usr/bin/log stream --process "FreeFlow Dev" \
    --level info \
    --predicate 'subsystem == "com.zachlatta.freeflow"' \
    --style compact
```
