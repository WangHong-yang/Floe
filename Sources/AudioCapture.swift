import AVFoundation
import CoreAudio
import AudioToolbox

final class AudioResampler {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    let source: AVAudioFormat
    init?(source: AVAudioFormat) {
        self.source = source
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

/// Delivers mono 16 kHz Float32 samples. Inference never runs on the audio thread.
/// "System default" uses AVAudioEngine (follows the system input); a specific
/// microphone uses AVCaptureSession, because AVAudioEngine keeps the previous
/// device's client format after a device switch and then fails to start.
final class AudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var active = false
    private var installed = false
    private var resampler: AudioResampler?
    private var session: AVCaptureSession?
    private let sessionQueue = DispatchQueue(label: "Floe.Capture", qos: .userInitiated)
    /// "" = system default, otherwise a Core Audio / AVCaptureDevice UID.
    private var deviceUID = ""
    var onSamples: (([Float]) -> Void)?
    var onError: ((String) -> Void)?
    /// Kept for the configuration-change observer; switching is now internal.
    var lastDeviceSwitch = Date.distantPast
    var isCapturing: Bool { installed || session != nil }

    /// Choose the input for the next start(). Unplugged devices fall back to default.
    @discardableResult
    func selectInput(uid: String) -> Bool {
        guard !isCapturing else { return false }
        let resolved = uid.isEmpty || AVCaptureDevice(uniqueID: uid) == nil ? "" : uid
        guard resolved != deviceUID else { return false }
        deviceUID = resolved
        // A fresh engine re-reads the (default) device format.
        engine = AVAudioEngine()
        return true
    }

    func start() throws {
        lock.lock()
        active = true
        resampler = nil
        lock.unlock()
        if !deviceUID.isEmpty, let device = AVCaptureDevice(uniqueID: deviceUID) {
            try startSession(device)
        } else {
            try startEngine()
        }
    }

    private func startSession(_ device: AVCaptureDevice) throws {
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw Self.unavailable }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        output.setSampleBufferDelegate(self, queue: sessionQueue)
        guard session.canAddOutput(output) else { throw Self.unavailable }
        session.addOutput(output)
        self.session = session
        // Continuity (iPhone) mics can take seconds to start; never block the
        // main thread, or macOS disables the shortcut event tap.
        sessionQueue.async { [weak self] in
            session.startRunning()
            if !session.isRunning { self?.onError?("Microphone unavailable. Check your input device.") }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer, length >= MemoryLayout<Float>.size else { return }
        let count = length / MemoryLayout<Float>.size
        let samples = pointer.withMemoryRebound(to: Float.self, capacity: count) {
            Array(UnsafeBufferPointer(start: $0, count: count))
        }
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        onSamples?(samples)
    }

    private static let unavailable = NSError(domain: "GlobeTalk", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Microphone unavailable. Check your input device."])

    private func startEngine() throws {
        let input = engine.inputNode
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else { throw Self.unavailable }
        // format: nil uses the node's live format; a cached format can raise
        // an Objective-C exception when the device changed.
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.active else { return }
            do {
                if self.resampler?.source != buffer.format {
                    guard let converter = AudioResampler(source: buffer.format) else { throw Self.unavailable }
                    self.resampler = converter
                }
                let samples = try self.resampler!.convert(buffer)
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
            // Bluetooth headsets can switch profile while opening; retry once fresh.
            engine = AVAudioEngine()
            lock.lock(); active = true; lock.unlock()
            Thread.sleep(forTimeInterval: 0.25)
            do { try startEngineOnce() } catch { stop(); throw error }
        }
    }

    private var retried = false
    private func startEngineOnce() throws {
        guard !retried else { throw Self.unavailable }
        retried = true
        defer { retried = false }
        try startEngine()
    }

    func stop(flush: Bool = false) {
        if let session {
            session.stopRunning()
            // Drain samples already queued on the delivery queue.
            sessionQueue.sync {}
            self.session = nil
        }
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

/// Core Audio input devices, identified by their persistent UID.
struct InputDevice: Hashable, Identifiable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func hasInput(_ device: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr && size > 0
    }

    static func all() -> [InputDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.filter(hasInput).compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return InputDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid)
        }
    }

    static func systemDefault() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }
}

