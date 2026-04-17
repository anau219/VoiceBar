import AVFoundation
import Foundation

enum AudioTrimmer {
    /// Trims leading and trailing silence from an audio file.
    /// Returns a new trimmed file URL, or nil if trimming isn't needed/possible.
    static func trimSilence(from url: URL, threshold: Float = 0.01) -> URL? {
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            AppState.log("AudioTrimmer: failed to open file")
            return nil
        }

        let format = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)

        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }

        do {
            try audioFile.read(into: buffer)
        } catch {
            AppState.log("AudioTrimmer: failed to read audio: \(error)")
            return nil
        }

        guard let channelData = buffer.floatChannelData?[0] else { return nil }
        let sampleCount = Int(buffer.frameLength)
        let sampleRate = format.sampleRate

        // Find first sample above threshold
        var startSample = 0
        for i in 0..<sampleCount {
            if abs(channelData[i]) > threshold {
                // Back up slightly to avoid clipping the start of speech
                startSample = max(0, i - Int(sampleRate * 0.05)) // 50ms margin
                break
            }
        }

        // Find last sample above threshold
        var endSample = sampleCount
        for i in stride(from: sampleCount - 1, through: 0, by: -1) {
            if abs(channelData[i]) > threshold {
                // Add margin after speech ends
                endSample = min(sampleCount, i + Int(sampleRate * 0.1)) // 100ms margin
                break
            }
        }

        let trimmedSamples = endSample - startSample
        let originalDuration = Double(sampleCount) / sampleRate
        let trimmedDuration = Double(trimmedSamples) / sampleRate

        // Only trim if we'd remove at least 0.5s
        guard originalDuration - trimmedDuration > 0.5 else {
            AppState.log("AudioTrimmer: minimal silence, skipping trim")
            return nil
        }

        AppState.log("AudioTrimmer: trimming \(String(format: "%.1f", originalDuration))s → \(String(format: "%.1f", trimmedDuration))s")

        // Write trimmed audio to new file
        let trimmedURL = url.deletingLastPathComponent()
            .appendingPathComponent("voicebar_trimmed_\(UUID().uuidString).wav")

        guard let trimmedBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(trimmedSamples)
        ) else { return nil }

        // Copy trimmed samples
        let src = channelData.advanced(by: startSample)
        trimmedBuffer.floatChannelData?[0].initialize(from: src, count: trimmedSamples)
        trimmedBuffer.frameLength = AVAudioFrameCount(trimmedSamples)

        do {
            let outputFile = try AVAudioFile(
                forWriting: trimmedURL,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            try outputFile.write(from: trimmedBuffer)
            return trimmedURL
        } catch {
            AppState.log("AudioTrimmer: failed to write trimmed file: \(error)")
            return nil
        }
    }
}
