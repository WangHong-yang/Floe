import AVFoundation

final class AudioResampler {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    init?(source: AVAudioFormat) {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16000, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: source, to: target) else { return nil }
        self.target = target
        self.converter = converter
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> [Float] {
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / input.format.sampleRate) + 64)
        var supplied = false
        return try output(capacity: capacity) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }.0
    }

    func finish() throws -> [Float] {
        var samples: [Float] = []
        for _ in 0..<16 {
            let (chunk, status) = try output(capacity: 512) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            samples += chunk
            if status == .endOfStream || chunk.isEmpty { break }
        }
        return samples
    }

    private func output(capacity: AVAudioFrameCount,
        input: @escaping AVAudioConverterInputBlock) throws -> ([Float], AVAudioConverterOutputStatus) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw NSError(domain: "GlobeTalk.Audio", code: 1)
        }
        var error: NSError?
        let status = converter.convert(to: buffer, error: &error, withInputFrom: input)
        if status == .error {
            throw error ?? NSError(domain: "GlobeTalk.Audio", code: 2)
        }
        let samples = buffer.floatChannelData.map {
            Array(UnsafeBufferPointer(start: $0[0], count: Int(buffer.frameLength)))
        } ?? []
        return (samples, status)
    }
}

/// The tap converts to mono 16 kHz. Inference never runs on the audio thread.
final class AudioCapture {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var active = false
    private var installed = false
    private var resampler: AudioResampler?
    var onSamples: (([Float]) -> Void)?
    var onError: ((String) -> Void)?

    func start() throws {
        let input = engine.inputNode
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let converter = AudioResampler(source: source) else {
            throw NSError(domain: "GlobeTalk", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Microphone unavailable. Check your input device."])
        }
        lock.lock()
        active = true
        resampler = converter
        lock.unlock()
        input.installTap(onBus: 0, bufferSize: 1024, format: source) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.active else { return }
            do {
                let samples = try converter.convert(buffer)
                if !samples.isEmpty { self.onSamples?(samples) }
            } catch {
                self.active = false
                self.onError?(error.localizedDescription)
            }
        }
        installed = true
        do {
            engine.prepare()
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    func stop(flush: Bool = false) {
        engine.stop()
        if installed {
            engine.inputNode.removeTap(onBus: 0)
            installed = false
        }
        // All submitted samples precede the finish operation on the ASR queue.
        lock.lock()
        if flush, active, let samples = try? resampler?.finish(), !samples.isEmpty {
            onSamples?(samples)
        }
        active = false
        resampler = nil
        lock.unlock()
    }
}
