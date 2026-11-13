import AppKit
import AVFoundation
import SwiftUI
import ServiceManagement

// Read the installed app's system registration without starting recognition.
if CommandLine.arguments.contains("--login-item-status") {
    switch SMAppService.mainApp.status {
    case .enabled: print("enabled")
    case .requiresApproval: print("requires-approval")
    case .notRegistered: print("not-registered")
    case .notFound: print("not-found")
    @unknown default: print("unknown")
    }
    exit(0)
}

if CommandLine.arguments.contains("--test-preferences-migration") {
    guard PreferencesMigration.test() else { exit(1) }
    print("Preferences migration passed: hotwords and interval preserved, new settings win, unrelated keys omitted.")
    exit(0)
}

if CommandLine.arguments.contains("--test-idle-updates") {
    guard AppModel.testIdleUpdates() else { exit(1) }
    print("Idle updates passed: stable polls emit no UI updates; fresh probes are disabled after grants and reenabled for stale/missing grants.")
    exit(0)
}

if CommandLine.arguments.contains("--test-permission-restart") {
    for visible in [false, true] {
        for guide: PermissionGuide? in [nil, .input, .accessibility] {
            let arguments = PermissionRestart.arguments(settingsVisible: visible, guide: guide)
            guard arguments.contains("--permission-restarted"),
                  arguments.contains("--show-settings") == visible,
                  PermissionRestart.guide(in: arguments) == guide else { exit(1) }
        }
    }
    guard PermissionRestart.guide(in: ["--permission-guide"]) == nil,
          PermissionRestart.guide(in: ["--permission-guide", "invalid"]) == nil else { exit(1) }
    print("Permission restart passed: settings visibility and both authorization guides survive relaunch.")
    exit(0)
}

// Deterministic visual QA: no windows, microphone, animated preview or preferences.
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--render-appearance" {
    MainActor.assumeIsolated {
    let preview = VStack(spacing: 0) {
        ForEach([false, true], id: \.self) { light in
            HStack(spacing: 36) {
                Image(nsImage: GlassArtwork.logo(size: 180)).resizable().frame(width: 180, height: 180)
                VStack(alignment: .leading, spacing: 18) {
                    Text("Floe").font(.system(size: 24, weight: .semibold))
                    HStack(spacing: 24) {
                        VStack(spacing: 10) {
                            GlassWaveform(level: 0.12, finishing: false, time: 0)
                            Text("Quiet").font(.caption)
                        }
                        VStack(spacing: 10) {
                            GlassWaveform(level: 0.8, finishing: false, time: 0)
                            Text("Speaking").font(.caption)
                        }
                        VStack(spacing: 10) {
                            GlassWaveform(level: 0, finishing: true, time: 0)
                            Text("Finishing").font(.caption)
                        }
                    }
                    HStack(spacing: 16) {
                        Image(nsImage: GlassArtwork.logo(size: 64)).resizable().frame(width: 42, height: 42)
                        Image(nsImage: GlassArtwork.logo(size: 32)).resizable().frame(width: 24, height: 24)
                    }
                }
            }.padding(30).frame(width: 620, height: 230)
                .foregroundStyle(light ? Color.black : Color.white)
                .background(light ? Color(red: 0.87, green: 0.89, blue: 0.92) : Color(red: 0.07, green: 0.10, blue: 0.13))
                .environment(\.colorScheme, light ? .light : .dark)
        }
    }
    let renderer = ImageRenderer(content: preview)
    renderer.scale = 2
    guard let image = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { exit(1) }
    do { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2])); exit(0) }
    catch { fputs("\(error)\n", stderr); exit(1) }
    }
}

if CommandLine.arguments.contains("--test-hotwords") {
    do {
        guard try Hotwords.normalize(" FSDP2 \r\nUlysses\n\nFSDP2\n 中文  术语 ") == "FSDP2\nUlysses\n中文 术语",
              Hotwords.forRecognizer("礼拜二\nFSDP2训练\nUlysses") == "礼 拜 二\nFSDP2 训 练\nUlysses",
              Hotwords.correction(from: "我们用 FSDP 做训练", to: "我们用 FSDP2 做训练")?.1 == "FSDP2",
              Hotwords.correction(from: "Use Globetalk here", to: "Use GlobeTalk here")?.1 == "GlobeTalk",
              Hotwords.correction(from: "识别旧名字", to: "识别新名称")?.1 == "新名称",
              Hotwords.correction(from: "删除它", to: "") == nil,
              Hotwords.correction(from: "hello", to: "hello") == nil else { exit(1) }
        for invalid in ["bad/word", "test :100", String(repeating: "词", count: 81),
                        (0..<101).map { "term\($0)" }.joined(separator: "\n")] {
            guard (try? Hotwords.normalize(invalid)) == nil else { exit(1) }
        }
        print("Hotwords passed: normalization, duplicate removal, reserved syntax, limits and correction extraction.")
        exit(0)
    } catch { fputs("\(error)\n", stderr); exit(1) }
}

if CommandLine.arguments.contains("--test-audio-tail") {
    do {
        for rate in [44100.0, 48000.0] {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
            let resampler = AudioResampler(source: format)!
            var count = 0, offset = 0
            while offset < Int(rate) {
                let n = min(1024, Int(rate) - offset)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
                buffer.frameLength = AVAudioFrameCount(n)
                for channel in 0..<2 {
                    for i in 0..<n {
                        buffer.floatChannelData![channel][i] = Float(sin(Double(offset + i) * 2 * .pi * 440 / rate))
                    }
                }
                count += try resampler.convert(buffer).count
                offset += n
            }
            let drained = try resampler.finish()
            let total = count + drained.count
            guard abs(total - 16000) <= 1, !drained.isEmpty,
                  try resampler.finish().isEmpty else {
                fputs("Resampler dropped its tail: \(rate) -> \(total), drained=\(drained.count)\n", stderr)
                exit(1)
            }
            print("Audio tail \(Int(rate)) Hz: \(count) + \(drained.count) = \(total) samples; EOS drain passed.")
        }
        exit(0)
    } catch { fputs("\(error)\n", stderr); exit(1) }
}

if CommandLine.arguments.contains("--test-dictation-clipboard") {
    let clipboard = NSPasteboard.withUniqueName()
    defer { clipboard.releaseGlobally() }
    let fragments = ["你", "好", " English", " and", " 中文"]
    for fragment in fragments {
        guard DictationClipboard.write(fragment, transient: true, to: clipboard),
              clipboard.string(forType: .string) == fragment,
              clipboard.types?.contains(DictationClipboard.transientType) == true else {
            fputs("Streaming fragment lacks the clipboard-history ignore marker\n", stderr)
            exit(1)
        }
    }
    let fullText = "你好 English and 中文"
    guard DictationClipboard.write(fullText, transient: false, to: clipboard),
          clipboard.string(forType: .string) == fullText,
          clipboard.types?.contains(DictationClipboard.transientType) == false,
          clipboard.pasteboardItems?.count == 1 else {
        fputs("Final clipboard did not contain one normal full-text item\n", stderr)
        exit(1)
    }
    print("Clipboard passed: five transient fragments, one full-text result. System clipboard untouched.")
    exit(0)
}

if CommandLine.arguments.contains("--permission-probe") {
    let state: [String: Bool] = [
        "microphone": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
        "input": CGPreflightListenEventAccess(),
        "accessibility": AXIsProcessTrusted()
    ]
    let data = try! JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    exit(0)
}

if CommandLine.arguments.contains("--test-streaming-patches") {
    let sequences = [
        ["", "你", "你好", "你好 world", "你好 World!", "你好 World"],
        ["", "我们用 FS", "我们用 FSDP", "我们用 FSDP2", "我们用 FSDP2 训练"],
        ["", "👩🏽‍💻", "👩🏽‍💻 hello", "👩🏽‍💻 Hello", "👩🏽‍💻"],
        ["", "第一行\n第二行", "第一行\n第三行", "", "重新开始"],
        ["", "错误", "正确", "正确", "正确。"]
    ]
    var checks = 0
    for sequence in sequences {
        var visible = "原有内容："
        var old = ""
        for new in sequence {
            let patch = TranscriptPatch.between(old, new)
            visible = String(visible.dropLast(patch.removeCount)) + patch.append
            guard visible == "原有内容：" + new else {
                fputs("Streaming revision damaged the existing text\n", stderr)
                exit(1)
            }
            old = new
            checks += 1
        }
    }
    print("Streaming patches: \(checks) transitions passed, including revisions, deletion, mixed languages and emoji.")
    exit(0)
}

// Run the real bundled model against WAV files without opening the microphone.
if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--transcribe" {
    let hotwordIndex = CommandLine.arguments.firstIndex(of: "--hotwords-file")
    var testWords = ""
    if let i = hotwordIndex {
        guard i + 1 < CommandLine.arguments.count,
              let raw = try? String(contentsOfFile: CommandLine.arguments[i + 1], encoding: .utf8),
              let normalized = try? Hotwords.normalize(raw), !normalized.isEmpty else { exit(1) }
        testWords = normalized
    }
    guard let directory = Bundle.main.resourceURL?.appendingPathComponent("Model").path,
          let recognizer = testWords.isEmpty ? GTCreate(directory) : GTCreateWithHotwords(directory, 2.5) else {
        fputs("Model load failed\n", stderr)
        exit(1)
    }
    defer { GTDestroy(recognizer) }
    do {
        let paths = Array(CommandLine.arguments[2..<(hotwordIndex ?? CommandLine.arguments.count)])
        for path in paths {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            guard file.length > 0, file.length < Int64(UInt32.max),
                  let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                              frameCapacity: AVAudioFrameCount(file.length)),
                  let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: 16000, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: file.processingFormat, to: mono),
                  let output = AVAudioPCMBuffer(pcmFormat: mono,
                    frameCapacity: AVAudioFrameCount(ceil(Double(file.length) * 16000 / file.processingFormat.sampleRate) + 64))
            else { throw NSError(domain: "GlobeTalk", code: 2) }
            try file.read(into: input)
            var supplied = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if supplied { status.pointee = .endOfStream; return nil }
                supplied = true
                status.pointee = .haveData
                return input
            }
            if let error { throw error }
            guard let samples = output.floatChannelData,
                  GTBeginWithHotwords(recognizer, Hotwords.forRecognizer(testWords)) == 1 else {
                throw NSError(domain: "GlobeTalk", code: 3)
            }
            let started = Date()
            var firstPartial: Double?
            var offset = 0
            while offset < Int(output.frameLength) {
                let count = min(1280, Int(output.frameLength) - offset)
                GTAccept(recognizer, samples[0].advanced(by: offset), Int32(count))
                if let result = GTText(recognizer) {
                    if firstPartial == nil && result.pointee != 0 {
                        firstPartial = Double(offset + count) / 16000
                    }
                    GTFreeText(result)
                }
                offset += count
            }
            GTFinish(recognizer)
            guard let result = GTText(recognizer) else { exit(1) }
            let text = String(cString: result)
            GTFreeText(result)
            print("\(URL(fileURLWithPath: path).lastPathComponent): \(text)")
            print(String(format: "audio=%.2fs inference=%.2fs first-partial-audio=%.2fs",
                Double(output.frameLength) / 16000, Date().timeIntervalSince(started), firstPartial ?? -1))
            if text.isEmpty { exit(2) }
        }
        exit(0)
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}
PreferencesMigration.run()
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
