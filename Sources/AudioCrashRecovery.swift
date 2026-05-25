import AVFoundation
import AppKit
import Foundation

enum AudioCrashRecovery {
    struct InflightMeta: Codable {
        let sampleRate: Double
        let channels: Int
        let bitDepth: Int
    }

    static func scanAndOfferRecovery(appState: AppState) {
        let dir = AudioRecorder.inflightAudioDirectory()
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return }

        let pcmURLs = contents.filter {
            $0.lastPathComponent.hasPrefix("inflight-") && $0.pathExtension == "pcm"
        }
        guard !pcmURLs.isEmpty else { return }

        let pcmURL = pcmURLs[0]
        let sidecarURL = pcmURL.deletingPathExtension().appendingPathExtension("json")

        let alert = NSAlert()
        alert.messageText = "Recovered audio from a previous session"
        alert.addButton(withTitle: "Transcribe")
        alert.addButton(withTitle: "Discard")
        let response = alert.runModal()

        guard !appState.isRecording else {
            pcmURLs.forEach { removeInflight($0) }
            return
        }

        if response == .alertFirstButtonReturn {
            if let wavURL = buildWAV(from: pcmURL, sidecar: sidecarURL) {
                appState.transcribeRecoveredAudio(url: wavURL)
            }
        }

        pcmURLs.forEach { removeInflight($0) }
    }

    private static func removeInflight(_ pcmURL: URL) {
        try? FileManager.default.removeItem(at: pcmURL)
        let sidecar = pcmURL.deletingPathExtension().appendingPathExtension("json")
        try? FileManager.default.removeItem(at: sidecar)
    }

    private static func buildWAV(from pcmURL: URL, sidecar sidecarURL: URL) -> URL? {
        guard
            let metaData = try? Data(contentsOf: sidecarURL),
            let meta = try? JSONDecoder().decode(InflightMeta.self, from: metaData),
            let pcmData = try? Data(contentsOf: pcmURL),
            !pcmData.isEmpty,
            let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: meta.sampleRate,
                channels: AVAudioChannelCount(meta.channels),
                interleaved: true
            )
        else { return nil }

        let frameCount = AVAudioFrameCount(pcmData.count / (meta.bitDepth / 8 * meta.channels))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }
        buffer.frameLength = frameCount

        pcmData.withUnsafeBytes { raw in
            guard let src = raw.baseAddress?.assumingMemoryBound(to: Int16.self),
                  let dst = buffer.int16ChannelData?[0] else { return }
            dst.update(from: src, count: Int(frameCount))
        }

        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        do {
            let file = try AVAudioFile(
                forWriting: wavURL,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            try file.write(from: buffer)
        } catch {
            return nil
        }
        return wavURL
    }
}
