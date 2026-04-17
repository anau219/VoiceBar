import AVFoundation
import Foundation

final class AudioRecorder {
    private var audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var tempURL: URL?

    func startRecording() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("voicebar_\(UUID().uuidString).wav")
        tempURL = url

        let inputNode = audioEngine.inputNode
        let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        audioFile = try AVAudioFile(
            forWriting: url,
            settings: recordingFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        let converter = AVAudioConverter(from: hardwareFormat, to: recordingFormat)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) {
            [weak self] buffer, _ in
            guard let self, let converter, let audioFile = self.audioFile else { return }

            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * 16000.0 / hardwareFormat.sampleRate
            )
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: recordingFormat,
                frameCapacity: frameCount
            ) else { return }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            try? audioFile.write(from: convertedBuffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    func stopRecording() -> URL? {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioFile = nil
        return tempURL
    }

    func cleanup() {
        if let url = tempURL {
            try? FileManager.default.removeItem(at: url)
            tempURL = nil
        }
    }

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
