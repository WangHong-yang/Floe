import AppKit
import SwiftUI
import AVFoundation
import Combine

final class AppModel: ObservableObject {
    let loginItem = LoginItem()
    @Published var status = "Loading local model…"
    @Published var text = ""
    @Published var ready = false
    @Published var recording = false
    @Published var busy = false
    @Published var audioLevel = 0.0
    @Published var micAllowed = false
    @Published var requestingMicrophone = false
    @Published var accessibilityAllowed = false
    @Published var inputAllowed = false
    @Published var hotkey = Hotkey.load()
    @Published var recordingHotkey = false
    @Published var recordingStarted: Date?
    @Published var editingPrompt = false
    @Published var promptDraft = ""
    var paraphrasePrompt: String {
        get { UserDefaults.standard.string(forKey: "paraphrasePrompt") ?? Paraphraser.defaultPrompt }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == Paraphraser.defaultPrompt.trimmingCharacters(in: .whitespacesAndNewlines) {
                UserDefaults.standard.removeObject(forKey: "paraphrasePrompt")
            } else {
                UserDefaults.standard.set(newValue, forKey: "paraphrasePrompt")
            }
        }
    }
    var usingCustomPrompt: Bool { UserDefaults.standard.string(forKey: "paraphrasePrompt") != nil }
    @Published var inputDevices: [InputDevice] = []
    @Published var saveHistory = UserDefaults.standard.object(forKey: "saveHistory") as? Bool ?? true
    let history = HistoryStore()
    var showHistory: (() -> Void)?
    @Published var inputDeviceUID = UserDefaults.standard.string(forKey: "inputDeviceUID") ?? ""
    /// Press once to start, press again (or Esc) to stop and transcribe.
    @Published var toggleMode = UserDefaults.standard.object(forKey: "toggleMode") as? Bool ?? true
    @Published var liveStreaming = UserDefaults.standard.object(forKey: "liveStreaming") as? Bool ?? false
    @Published var paraphraseEnabled = UserDefaults.standard.object(forKey: "paraphraseEnabled") as? Bool ?? false
    @Published var paraphraseModel = UserDefaults.standard.string(forKey: "paraphraseModel") ?? Paraphraser.defaultModel
    @Published var paraphraseProfile = UserDefaults.standard.string(forKey: "paraphraseProfile") ?? ""
    @Published var paraphraseRegion = UserDefaults.standard.string(forKey: "paraphraseRegion") ?? ""
    @Published var autoInsert = UserDefaults.standard.object(forKey: "autoInsert") as? Bool ?? true
    @Published var permissionGuide: PermissionGuide?
    @Published var listenerStarted = false
    @Published var needsPermissionRestart = false
    @Published var permissionFeedback = ""
    @Published var lastTrigger = "Waiting for shortcut"
    @Published var hotwordText = UserDefaults.standard.string(forKey: "hotwordText") ?? ""
    @Published var hotwordsEnabled = UserDefaults.standard.object(forKey: "hotwordsEnabled") as? Bool ?? true
    @Published var hotwordScore = UserDefaults.standard.object(forKey: "hotwordScore") as? Double ?? 2.5
    @Published var learnCorrections = UserDefaults.standard.object(forKey: "learnCorrections") as? Bool ?? true
    @Published var pasteInterval = UserDefaults.standard.object(forKey: "pasteInterval") as? Double ?? 0.005
    @Published var hotwordFeedback = ""
    @Published var editingHotwords = false
    @Published var hotwordDraft = ""
    @Published var hotwordDraftEnabled = true
    @Published var hotwordDraftScore = 2.5
    @Published var hotwordDraftError = ""
    @Published var suggestedWord: String?
    @Published var suggestedOriginal = ""
    @Published var suggestionSeconds = 5
    var suggestionChanged: (() -> Void)?
    var changed: (() -> Void)?
    var showSettingsAfterPermission: (() -> Void)?
    var guideChanged: ((PermissionGuide?) -> Void)?
    var restartForPermissions: (() -> Void)?
    private var probeRunning = false
    private var restartScheduled = false
    private let permissionQueue = DispatchQueue(label: "GlobeTalk.Permissions")
    private let capture = AudioCapture()
    private let keys = KeyMonitor()
    private let hotkeyRecorder = HotkeyRecorder()
    private let inference = DispatchQueue(label: "GlobeTalk.ASR", qos: .userInitiated)
    // Recognizer and stream are owned exclusively by the inference queue.
    private var recognizer: OpaquePointer?
    private var liveInsertion: LiveInsertion?
    private var lastOutputTime = Date.distantPast
    private var pendingOutput = ""
    private var outputTimer: Timer?
    private var outputBlocked = false
    private var startSound: NSSound?
    private var session = UUID()
    private var held = false
    private var monitorTimer: Timer?
    private var timeout: Timer?
    private var configurationObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var correctionObserver: CorrectionObserver?
    private var suggestionTimer: Timer?
    private var releaseTimer: Timer?
    private var finishing = false
    private var sampleCount = 0

    func setup() {
        keys.hotkey = hotkey
        keys.toggleTap = toggleMode
        keys.onHold = { [weak self] down in
            // A CGEventTap callback must return promptly. Starting AVAudioEngine
            // synchronously here can cause macOS to disable the tap.
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastTrigger = "\(self.keyName) \(down ? "pressed" : "released")"
                self.held = down
                if self.toggleMode {
                    guard down else { return }
                    if self.recording { self.finish() } else { self.begin() }
                } else if down { self.begin() }
                else if self.recording { self.finish() }
            }
        }
        keys.onCancel = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                // Esc always discards the recording; press the shortcut again to finish.
                self.cancel()
            }
        }
        keys.onUnavailable = { [weak self] in DispatchQueue.main.async { self?.cancel() } }
        keys.onInteraction = { [weak self] in
            guard let self, !self.toggleMode, self.recording || self.busy,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            DispatchQueue.main.async {
                if self.recording || self.busy { self.cancel() }
            }
        }
        capture.onError = { [weak self] message in
            DispatchQueue.main.async {
                self?.cancel()
                self?.status = "Recording failed: \(message)"
                self?.changed?()
            }
        }
        refreshPermissions()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshPermissions()
            self?.probePermissions()
        }
        monitorTimer?.tolerance = 0.5
        probePermissions()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.recording,
                      Date().timeIntervalSince(self.capture.lastDeviceSwitch) > 1.5 else { return }
                self.cancel()
                self.status = "Input device changed. Start recording again."
            }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.held = false
                self?.cancel()
            }
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("Model").path else {
            status = "Model folder is missing. Rebuild the app."
            return
        }
        let score = hotwordsEnabled && !hotwordText.isEmpty ? hotwordScore : 0
        inference.async {
            let r = score > 0 ? GTCreateWithHotwords(directory, Float(score)) : GTCreate(directory)
            self.recognizer = r
            DispatchQueue.main.async {
                self.ready = r != nil
                self.status = r == nil ? "Model could not load. Rebuild the app." : self.idleStatus
                self.changed?()
            }
        }
    }

    var keyName: String { hotkey.name }
    /// Paraphrasing rewrites the whole text, so it always inserts once at the end.
    private var streamsLive: Bool { liveStreaming && !paraphraseEnabled }
    private var listeningStatus: String {
        if toggleMode { return "Listening · Press \(keyName) to finish, Esc to cancel" }
        return streamsLive ? "Listening · Inserting text live. Esc to stop" : "Listening · Release to insert. Esc to stop"
    }
    private var maxRecording: TimeInterval { toggleMode ? 600 : 120 }
    private var idleStatus: String {
        if !micAllowed { return "Allow microphone access" }
        if !inputAllowed { return "Allow Input Monitoring to detect \(keyName)" }
        if autoInsert && !accessibilityAllowed { return "Allow Accessibility to insert text" }
        if needsPermissionRestart { return "Permissions granted · Restarting to apply" }
        if !listenerStarted { return "Permissions granted · Reopen the app to start the shortcut listener" }
        return toggleMode ? "Ready · Press \(keyName) to speak" : "Ready · Hold \(keyName) to speak"
    }

    func refreshPermissions() {
        // Once a fresh probe confirms a grant, a cached false in this process
        // must not erase the success feedback before the automatic restart.
        applyPermissions(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            input: CGPreflightListenEventAccess() || (needsPermissionRestart && inputAllowed),
            accessibility: AXIsProcessTrusted() || (needsPermissionRestart && accessibilityAllowed))
    }

    private func applyPermissions(microphone: Bool, input: Bool, accessibility: Bool) {
        let newlyMic = microphone && !micAllowed
        let newlyInput = input && !inputAllowed
        let newlyAX = accessibility && !accessibilityAllowed
        let previous = inputAllowed
        // @Published emits even for equal values. Stable permission polls must
        // not invalidate every settings, waveform and suggestion view.
        if micAllowed != microphone { micAllowed = microphone }
        if accessibilityAllowed != accessibility { accessibilityAllowed = accessibility }
        if inputAllowed != input { inputAllowed = input }
        if inputAllowed && (!previous || !listenerStarted) { listenerStarted = keys.start() }
        if !inputAllowed && previous {
            keys.stop()
            listenerStarted = false
            cancel()
        }
        if newlyMic { permissionFeedback = "Microphone enabled ✓" }
        if newlyInput { permissionFeedback = "Input Monitoring enabled ✓" }
        if newlyAX { permissionFeedback = "Accessibility enabled ✓" }
        let grantedFeedback = "All permissions granted. Ready to dictate ✓"
        if micAllowed && inputAllowed && accessibilityAllowed && permissionFeedback != grantedFeedback {
            permissionFeedback = grantedFeedback
        }
        if ready && !recording && !busy && status != idleStatus { status = idleStatus }
    }

    private var needsFreshPermissionProbe: Bool {
        !inputAllowed || !accessibilityAllowed || needsPermissionRestart
    }

    private func probePermissions() {
        // A fresh process is only necessary while cached TCC grants may be
        // stale. Revocations are still detected by refreshPermissions().
        guard needsFreshPermissionProbe, !probeRunning,
              let executable = Bundle.main.executableURL else { return }
        probeRunning = true
        permissionQueue.async {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executable
            process.arguments = ["--permission-probe"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            var state: [String: Bool]?
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Bool]
            } catch {}
            let result = state
            DispatchQueue.main.async {
                self.probeRunning = false
                guard let result else { return }
                let input = result["input"] ?? false
                let ax = result["accessibility"] ?? false
                let cached = (input && !CGPreflightListenEventAccess()) || (ax && !AXIsProcessTrusted())
                if self.needsPermissionRestart != cached { self.needsPermissionRestart = cached }
                self.applyPermissions(microphone: result["microphone"] ?? false,
                                      input: input, accessibility: ax)
                if cached && !self.restartScheduled && !self.recording && !self.busy && !self.requestingMicrophone {
                    self.restartScheduled = true
                    self.restartForPermissions?()
                }
            }
        }
    }

    static func testIdleUpdates() -> Bool {
        let model = AppModel()
        model.ready = true
        model.micAllowed = true
        model.inputAllowed = true
        model.accessibilityAllowed = true
        model.listenerStarted = true
        model.permissionFeedback = "All permissions granted. Ready to dictate ✓"
        model.status = model.idleStatus
        var updates = 0
        let subscription = model.objectWillChange.sink { updates += 1 }
        for _ in 0..<30 {
            model.applyPermissions(microphone: true, input: true, accessibility: true)
        }
        guard updates == 0, !model.needsFreshPermissionProbe else { return false }
        model.applyPermissions(microphone: false, input: true, accessibility: true)
        guard !model.micAllowed, model.status == "Allow microphone access", updates > 0 else { return false }
        // Simulate a cached input grant disappearing without starting a listener.
        model.inputAllowed = false
        guard model.needsFreshPermissionProbe else { return false }
        model.inputAllowed = true
        model.needsPermissionRestart = true
        guard model.needsFreshPermissionProbe else { return false }
        withExtendedLifetime(subscription) {}
        return true
    }

    func requestMic() {
        guard !requestingMicrophone else { return }
        requestingMicrophone = true
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            // The system prompt can finish its window-ordering transition
            // after the authorization callback. Restore after that transition.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard let self else { return }
                self.requestingMicrophone = false
                self.refreshPermissions()
                self.showSettingsAfterPermission?()
                self.changed?()
            }
        }
    }

    func deferPermissionRestart() {
        restartScheduled = false
    }

    func requestAccessibility() {
        permissionGuide = .accessibility
        guideChanged?(.accessibility)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSettings("Privacy_Accessibility")
    }

    func requestInput() {
        permissionGuide = .input
        guideChanged?(.input)
        _ = CGRequestListenEventAccess()
        openSettings("Privacy_ListenEvent")
    }

    func dismissPermissionGuide() {
        permissionGuide = nil
        guideChanged?(nil)
    }

    func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    func setHotkey(_ key: Hotkey) {
        held = false
        cancel()
        hotkey = key
        key.save()
        keys.hotkey = key
        if inputAllowed { listenerStarted = keys.start() }
        if ready { status = idleStatus }
    }

    func applyToggleMode() { keys.toggleTap = toggleMode }

    func refreshInputDevices() {
        let devices = InputDevice.all()
        if inputDevices != devices { inputDevices = devices }
    }

    func setInputDevice(_ uid: String) {
        if recording || busy { cancel() }
        inputDeviceUID = uid
        UserDefaults.standard.set(uid, forKey: "inputDeviceUID")
        capture.selectInput(uid: uid)
    }

    func recordHotkey() {
        guard !recordingHotkey else {
            hotkeyRecorder.stop()
            recordingHotkey = false
            keys.suspended = false
            return
        }
        held = false
        cancel()
        recordingHotkey = true
        keys.suspended = true
        hotkeyRecorder.start { [weak self] key in
            guard let self else { return }
            self.recordingHotkey = false
            self.keys.suspended = false
            if let key { self.setHotkey(key) }
        }
    }

    func saveParaphraseSettings() {
        let d = UserDefaults.standard
        d.set(paraphraseEnabled, forKey: "paraphraseEnabled")
        d.set(paraphraseModel.trimmingCharacters(in: .whitespaces), forKey: "paraphraseModel")
        d.set(paraphraseProfile.trimmingCharacters(in: .whitespaces), forKey: "paraphraseProfile")
        d.set(paraphraseRegion.trimmingCharacters(in: .whitespaces), forKey: "paraphraseRegion")
    }

    private var paraphraseConfig: Paraphraser.Config {
        let glossary = hotwordsEnabled
            ? hotwordText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            : []
        return Paraphraser.Config(
            model: paraphraseModel.trimmingCharacters(in: .whitespaces),
            profile: paraphraseProfile.trimmingCharacters(in: .whitespaces),
            region: paraphraseRegion.trimmingCharacters(in: .whitespaces),
            prompt: paraphrasePrompt,
            glossary: glossary)
    }

    func begin() {
        if recording, finishing, releaseTimer != nil, !toggleMode {
            releaseTimer?.invalidate()
            releaseTimer = nil
            finishing = false
            busy = false
            status = listeningStatus
            timeout = Timer.scheduledTimer(withTimeInterval: maxRecording, repeats: false) { [weak self] _ in self?.finish() }
            changed?()
            return
        }
        guard ready, !recording, !busy else { return }
        refreshPermissions()
        guard micAllowed else {
            status = "Allow microphone access, then hold your shortcut."
            changed?()
            return
        }
        capture.selectInput(uid: inputDeviceUID)
        sampleCount = 0
        recordingStarted = Date()
        session = UUID()
        correctionObserver?.stop()
        dismissSuggestion()
        correctionObserver = learnCorrections && autoInsert ? CorrectionObserver() : nil
        correctionObserver?.onCandidate = { [weak self] candidate in self?.suggest(candidate) }
        let id = session
        let words = hotwordsEnabled ? Hotwords.forRecognizer(hotwordText) : ""
        liveInsertion = autoInsert ? LiveInsertion() : nil
        outputBlocked = false
        pendingOutput = ""
        lastOutputTime = .distantPast
        text = ""
        audioLevel = 0
        recording = true
        status = listeningStatus
        changed?()
        inference.async {
            if let r = self.recognizer { _ = GTBeginWithHotwords(r, words) }
        }
        capture.onSamples = { [weak self] samples in
            guard let self else { return }
            self.inference.async {
                guard let r = self.recognizer else { return }
                let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
                let level = min(1, sqrt(energy / Double(max(1, samples.count))) * 12)
                self.sampleCount += samples.count
                samples.withUnsafeBufferPointer { GTAccept(r, $0.baseAddress, Int32(samples.count)) }
                let value = self.readText(r)
                DispatchQueue.main.async {
                    guard self.session == id, self.recording else { return }
                    self.audioLevel = self.audioLevel * 0.4 + level * 0.6
                    if self.text != value {
                        self.text = value
                        self.queueOutput(value)
                    }
                }
            }
        }
        do {
            startSound = NSSound(named: NSSound.Name("Tink"))
            startSound?.volume = 0.25
            startSound?.play()
            try capture.start()
            timeout = Timer.scheduledTimer(withTimeInterval: maxRecording, repeats: false) { [weak self] _ in
                self?.finish()
            }
        } catch {
            cancel()
            status = error.localizedDescription
            changed?()
        }
    }

    func finish() {
        guard recording, !finishing else { return }
        timeout?.invalidate()
        timeout = nil
        finishing = true
        busy = true
        status = "Finishing…"
        changed?()
        let id = session
        // A brief real-audio tail delivers the last syllable and pending tap
        // buffers. Synthetic silence in GTFinish cannot recover cut-off audio.
        releaseTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            guard let self, self.session == id else { return }
            self.releaseTimer = nil
            self.completeFinish(id)
        }
    }

    private func completeFinish(_ id: UUID) {
        capture.stop(flush: true)
        recording = false
        finishing = false
        inference.async {
            guard let r = self.recognizer else { return }
            GTFinish(r)
            let value = self.readText(r)
            GTCancel(r)
            DispatchQueue.main.async {
                guard self.session == id else { return }
                self.outputTimer?.invalidate()
                self.outputTimer = nil
                guard self.paraphraseEnabled, !value.isEmpty else { return self.deliver(value, id, raw: value) }
                self.text = value
                self.status = "Rewriting with Bedrock…"
                self.changed?()
                Paraphraser.run(value, self.paraphraseConfig) { result in
                    guard self.session == id else { return }
                    switch result {
                    case .success(let rewritten): self.deliver(rewritten, id, raw: value)
                    case .failure(let error):
                        self.deliver(value, id, raw: value, note: "Rewrite failed (\(error.localizedDescription)) · Inserted raw text")
                    }
                }
            }
        }
    }

    private func deliver(_ value: String, _ id: UUID, raw: String, note: String? = nil) {
                if saveHistory && !value.isEmpty { history.add(raw: raw, final: value) }
                let delay = max(0, self.pasteInterval - Date().timeIntervalSince(self.lastOutputTime))
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard self.session == id else { return }
                    self.text = value
                    self.applyOutput(value)
                    // Let the last synthetic paste consume its transient
                    // suffix before replacing the clipboard with the full text.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        guard self.session == id else { return }
                        let copied = !value.isEmpty && DictationClipboard.write(value, transient: false)
                        self.busy = false
                        if !self.outputBlocked { self.correctionObserver?.arm(value) }
                        if value.isEmpty { self.status = "No speech detected · Try again" }
                        else if let note { self.status = note }
                        else if copied { self.status = "Finished · Full transcript copied" }
                        else { self.status = "Finished · Copy the transcript from the menu bar" }
                        self.changed?()
                    }
                }
    }

    private func queueOutput(_ value: String) {
        pendingOutput = value
        guard autoInsert, streamsLive, !outputBlocked else { return }
        // Do not overwrite the clipboard before an earlier paste is consumed.
        let delay = pasteInterval - Date().timeIntervalSince(lastOutputTime)
        if delay <= 0 {
            outputTimer?.invalidate()
            outputTimer = nil
            applyOutput(value)
        } else if outputTimer == nil {
            outputTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.outputTimer = nil
                self.applyOutput(self.pendingOutput)
            }
        }
    }

    private func applyOutput(_ value: String) {
        guard autoInsert, !outputBlocked, !value.isEmpty else { return }
        guard let liveInsertion, liveInsertion.update(value) else {
            outputBlocked = true
            status = accessibilityAllowed ? "Focus changed or paste failed · Copy from the menu bar" : "Accessibility access required · Allow it in Settings"
            return
        }
        lastOutputTime = Date()
    }

    func cancel() {
        guard recording || busy else { return }
        session = UUID()
        releaseTimer?.invalidate()
        releaseTimer = nil
        finishing = false
        correctionObserver?.stop()
        dismissSuggestion()
        outputTimer?.invalidate()
        outputTimer = nil
        capture.stop()
        timeout?.invalidate()
        timeout = nil
        recording = false
        busy = false
        text = ""
        status = "Canceled · " + (toggleMode ? "Press" : "Hold") + " \(keyName) to start again"
        inference.async { if let r = self.recognizer { GTCancel(r) } }
        changed?()
    }

    func copy() {
        guard !text.isEmpty else { return }
        if DictationClipboard.write(text, transient: false) { status = "Copied" }
    }

    private func readText(_ r: OpaquePointer) -> String {
        guard let pointer = GTText(r) else { return "" }
        defer { GTFreeText(pointer) }
        return String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func shutdown() {
        releaseTimer?.invalidate()
        suggestionTimer?.invalidate()
        correctionObserver?.stop()
        keys.stop()
        capture.stop()
        monitorTimer?.invalidate()
        timeout?.invalidate()
        outputTimer?.invalidate()
        inference.sync {
            if let r = recognizer { GTDestroy(r) }
            recognizer = nil
        }
    }

    func saveHotwords(_ draft: String, enabled: Bool, score: Double) throws {
        guard !recording, !busy, ready else {
            throw NSError(domain: "GlobeTalk", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Wait for dictation to finish before saving."])
        }
        let normalized = try Hotwords.normalize(draft)
        guard [1.5, 2.5, 4.0].contains(score) else { return }
        hotwordText = normalized
        hotwordsEnabled = enabled
        hotwordScore = score
        UserDefaults.standard.set(normalized, forKey: "hotwordText")
        UserDefaults.standard.set(enabled, forKey: "hotwordsEnabled")
        UserDefaults.standard.set(score, forKey: "hotwordScore")
        hotwordFeedback = "Saved \(normalized.components(separatedBy: .newlines).filter { !$0.isEmpty }.count) hotwords · Applies to your next dictation"
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("Model").path else { return }
        ready = false
        let boost = enabled && !normalized.isEmpty ? score : 0
        inference.async {
            let replacement = boost > 0 ? GTCreateWithHotwords(directory, Float(boost)) : GTCreate(directory)
            if let replacement {
                if let old = self.recognizer { GTDestroy(old) }
                self.recognizer = replacement
            }
            DispatchQueue.main.async {
                self.ready = self.recognizer != nil
                if replacement == nil {
                    self.hotwordsEnabled = false
                    UserDefaults.standard.set(false, forKey: "hotwordsEnabled")
                    self.hotwordFeedback = "Hotwords could not load and were disabled. Your list is preserved."
                }
                self.changed?()
            }
        }
    }

    private func suggest(_ candidate: (String, String)?) {
        dismissSuggestion()
        guard learnCorrections, !recording, !busy, let (old, new) = candidate,
              !hotwordText.components(separatedBy: .newlines).contains(new),
              hotwordText.components(separatedBy: .newlines).filter({ !$0.isEmpty }).count < 100 else { return }
        suggestedOriginal = old
        suggestedWord = new
        suggestionSeconds = 5
        suggestionChanged?()
        suggestionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.suggestionSeconds -= 1
            if self.suggestionSeconds <= 0 { self.acceptSuggestion() }
        }
    }

    func dismissSuggestion() {
        suggestionTimer?.invalidate()
        suggestionTimer = nil
        suggestedWord = nil
        suggestionChanged?()
    }

    func rejectSuggestion() {
        correctionObserver?.stop()
        dismissSuggestion()
    }

    func acceptSuggestion() {
        guard let word = suggestedWord else { return }
        correctionObserver?.stop()
        dismissSuggestion()
        do {
            try saveHotwords(hotwordText + "\n" + word, enabled: true, score: hotwordScore)
            hotwordFeedback = "Added “\(word)” · Edit or remove it in Hotwords"
        } catch { hotwordFeedback = error.localizedDescription }
    }
}

struct ControlView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack(alignment: .topLeading) {
                DraggableAppIcon()
                    .frame(width: 220, height: 220)
                    .offset(x: -52, y: -94)
                HStack {
                    Spacer()
                    Text("On-device").font(.caption.bold()).padding(6)
                        .background(.teal.opacity(0.12), in: Capsule())
                }
            }
            .frame(height: 56, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 5) {
                Text("Floe").font(.title2.bold())
                Text("Local Chinese & English dictation")
                    .foregroundStyle(.secondary)
            }
            if model.status != "Allow microphone access" {
                Text(model.status).font(.callout).textSelection(.enabled)
            }
            if !model.permissionFeedback.isEmpty {
                Text(model.permissionFeedback).font(.caption).foregroundStyle(.teal)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                permission("Microphone", allowed: model.micAllowed, action: model.requestMic)
                permission("Input Monitoring · Detect shortcuts", allowed: model.inputAllowed, action: model.requestInput)
                permission("Accessibility · Insert text", allowed: model.accessibilityAllowed, action: model.requestAccessibility)
            }
            HStack(alignment: .top, spacing: 10) {
                Text("Drag the app icon into the list in System Settings, then enable it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }.controlSize(.small)
            }
            HStack {
                Text("Shortcut").font(.callout)
                Text(model.recordingHotkey ? "Press a key… (Esc to cancel)" : model.hotkey.name)
                    .font(.callout.monospaced()).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.teal.opacity(model.recordingHotkey ? 0.25 : 0.12), in: RoundedRectangle(cornerRadius: 6))
                Spacer()
                Button(model.recordingHotkey ? "Cancel" : "Change…") { model.recordHotkey() }
                Menu("Presets") {
                    Button("🌐 / Fn") { model.setHotkey(.fn) }
                    Button("Right ⌥ Option") { model.setHotkey(.rightOption) }
                }.fixedSize()
            }
            HStack {
                Text("Microphone").font(.callout)
                Picker("Microphone", selection: Binding(get: { model.inputDeviceUID },
                                                         set: { model.setInputDevice($0) })) {
                    Text("System default").tag("")
                    ForEach(model.inputDevices) { Text($0.name).tag($0.uid) }
                    if !model.inputDeviceUID.isEmpty && !model.inputDevices.contains(where: { $0.uid == model.inputDeviceUID }) {
                        Text("Unavailable device (using default)").tag(model.inputDeviceUID)
                    }
                }.labelsHidden()
                Button {
                    model.refreshInputDevices()
                } label: { Image(systemName: "arrow.clockwise") }.help("Refresh device list")
            }
            .onAppear { model.refreshInputDevices() }
            Toggle("Press once to start, again to finish (Esc cancels)", isOn: $model.toggleMode)
                .onChange(of: model.toggleMode) {
                    UserDefaults.standard.set(model.toggleMode, forKey: "toggleMode")
                    model.applyToggleMode()
                    model.cancel()
                }
            LoginItemView(loginItem: model.loginItem)
            Toggle("Save transcripts locally (History)", isOn: $model.saveHistory)
                .onChange(of: model.saveHistory) { UserDefaults.standard.set(model.saveHistory, forKey: "saveHistory") }
            Toggle("Insert text into the focused field", isOn: $model.autoInsert)
                .onChange(of: model.autoInsert) { UserDefaults.standard.set(model.autoInsert, forKey: "autoInsert") }
            Toggle("Stream text live while speaking", isOn: $model.liveStreaming)
                .onChange(of: model.liveStreaming) { UserDefaults.standard.set(model.liveStreaming, forKey: "liveStreaming") }
                .disabled(!model.autoInsert || model.paraphraseEnabled)
            Toggle("Paraphrase with Bedrock before inserting (sends text to AWS)", isOn: $model.paraphraseEnabled)
                .onChange(of: model.paraphraseEnabled) { model.saveParaphraseSettings() }
            if model.paraphraseEnabled {
                Grid(alignment: .leading, verticalSpacing: 6) {
                    GridRow {
                        Text("Model").font(.caption)
                        TextField("Model ID", text: $model.paraphraseModel).font(.caption.monospaced())
                    }
                    GridRow {
                        Text("Profile").font(.caption)
                        TextField("AWS profile (blank = default)", text: $model.paraphraseProfile).font(.caption.monospaced())
                    }
                    GridRow {
                        Text("Region").font(.caption)
                        TextField("Region (blank = profile default)", text: $model.paraphraseRegion).font(.caption.monospaced())
                    }
                }
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.saveParaphraseSettings() }
                .onChange(of: model.paraphraseModel) { model.saveParaphraseSettings() }
                .onChange(of: model.paraphraseProfile) { model.saveParaphraseSettings() }
                .onChange(of: model.paraphraseRegion) { model.saveParaphraseSettings() }
                HStack {
                    Text(model.usingCustomPrompt ? "Using your custom prompt" : "Using the default prompt")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Prompt…") {
                        model.promptDraft = model.paraphrasePrompt
                        model.editingPrompt = true
                    }
                }
            }
            HStack {
                Text("Text update interval").font(.callout)
                Picker("Text update interval", selection: $model.pasteInterval) {
                    Text("5ms").tag(0.005)
                    Text("15ms").tag(0.015)
                    Text("25ms").tag(0.025)
                    Text("50ms").tag(0.05)
                    Text("100ms").tag(0.1)
                    Text("150ms").tag(0.15)
                    Text("250ms").tag(0.25)
                }.labelsHidden().onChange(of: model.pasteInterval) {
                    UserDefaults.standard.set(model.pasteInterval, forKey: "pasteInterval")
                }.disabled(model.recording || model.busy)
                Spacer()
                Button("History…") { model.showHistory?() }
                Button("Hotwords…") {
                    model.rejectSuggestion()
                    model.editingHotwords = true
                }
            }
            if !model.hotwordFeedback.isEmpty {
                Text(model.hotwordFeedback).font(.caption).foregroundStyle(.teal)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Shortcuts: a single modifier (Fn, Right ⌥…) or any key/combo (F5, ⌃Space…). Non-modifier keys are swallowed while Floe runs. For 🌐: System Settings → Keyboard → Press 🌐 key to → Do Nothing. If the shortcut stops responding after authorization, quit and reopen Floe.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(model.listenerStarted ? "Shortcut listener active" : "Shortcut listener inactive")
                .font(.caption).foregroundStyle(model.listenerStarted ? Color.teal : Color.secondary)
            Text(model.lastTrigger).font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button(model.recording ? "Stop microphone test" : "Test microphone") {
                    if model.recording { model.finish() } else { model.begin() }
                }.disabled(!model.ready || model.busy)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            Text("Zipformer INT8 · Apple Silicon · Audio is never saved or uploaded")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 410)
        .sheet(isPresented: $model.editingHotwords) { HotwordEditor(model: model) }
        .sheet(isPresented: $model.editingPrompt) { PromptEditor(model: model) }
    }

    private func permission(_ title: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        let highlighted = model.permissionGuide.map { title.hasPrefix($0.rawValue) } ?? false
        return HStack {
            Image(systemName: allowed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(allowed ? Color.teal : Color.secondary)
            Text(title).font(.callout)
            Spacer()
            if !allowed {
                Button(title == "Microphone" && model.requestingMicrophone ? "Waiting for permission…" : "Allow", action: action)
                    .controlSize(.small)
                    .disabled(title == "Microphone" && model.requestingMicrophone)
            }
            else { Text("Enabled").font(.caption).foregroundStyle(.teal) }
        }.padding(6)
            .background(highlighted ? Color.teal.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(highlighted ? Color.teal : Color.clear, lineWidth: 1))
    }
}

struct HotwordEditor: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Personal hotwords").font(.title2.bold())
            Toggle("Prioritize these words", isOn: $model.hotwordDraftEnabled)
            Text("One word or phrase per line. Edit directly; delete a line to remove a word. Up to 100 entries.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $model.hotwordDraft).font(.system(.body, design: .monospaced))
                .frame(height: 220).padding(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.4)))
            Text("Examples: FSDP2, Ulysses, Floe, or names you use often. One per line.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Recognition priority", selection: $model.hotwordDraftScore) {
                Text("Low").tag(1.5)
                Text("Standard").tag(2.5)
                Text("High").tag(4.0)
            }.pickerStyle(.segmented)
            Text("Higher priority may misrecognize common words. An empty or disabled list uses the faster default decoder.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Suggest hotwords when I correct dictated text", isOn: $model.learnCorrections)
                .onChange(of: model.learnCorrections) {
                    UserDefaults.standard.set(model.learnCorrections, forKey: "learnCorrections")
                    if !model.learnCorrections { model.rejectSuggestion() }
                }
            Text("Watches the dictated field for 45 seconds. Suggestions are added after 5 seconds unless canceled. Unsupported fields are skipped.")
                .font(.caption).foregroundStyle(.secondary)
            if !model.hotwordDraftError.isEmpty { Text(model.hotwordDraftError).font(.caption).foregroundStyle(.red) }
            HStack {
                Text("\(model.hotwordDraft.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count) hotwords")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try model.saveHotwords(model.hotwordDraft, enabled: model.hotwordDraftEnabled, score: model.hotwordDraftScore)
                        dismiss()
                    } catch { model.hotwordDraftError = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
                    .disabled(!model.ready || model.recording || model.busy)
            }
        }.padding(24).frame(width: 470)
            .onAppear { model.hotwordDraft = model.hotwordText; model.hotwordDraftEnabled = model.hotwordsEnabled; model.hotwordDraftScore = model.hotwordScore; model.hotwordDraftError = "" }
    }
}

struct HotwordSuggestionView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add your correction to hotwords?").font(.headline)
            Text("\(model.suggestedOriginal) → \(model.suggestedWord ?? "")")
                .lineLimit(2).font(.callout)
            HStack {
                Text("\(model.suggestionSeconds) seconds until added").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.rejectSuggestion() }
                Button("Add") { model.acceptSuggestion() }
            }
        }.padding(16).frame(width: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var bar: QuietPanel!
    private var guidePanel: QuietPanel!
    private var suggestionPanel: QuietPanel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Updates and permission restarts must not leave a second listener/bar.
        if let identifier = Bundle.main.bundleIdentifier {
            let identifiers = identifier == PreferencesMigration.identifier
                ? [identifier, PreferencesMigration.legacyIdentifier] : [identifier]
            for oldIdentifier in identifiers {
                for other in NSRunningApplication.runningApplications(withBundleIdentifier: oldIdentifier)
                    where other.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    other.terminate()
                }
            }
        }
        // A regular app shows in the Dock and ⌘Tab; the menu bar item stays too.
        NSApp.setActivationPolicy(.regular)
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "History…", action: #selector(openHistory), keyEquivalent: "y").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Floe", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Floe", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        // Edit menu so ⌘C/⌘V/⌘A work in the settings text fields.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = GlassArtwork.menuIcon()
        let menu = NSMenu()
        menu.addItem(withTitle: "Floe Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        let paraphraseItem = NSMenuItem(title: "Paraphrase（Bedrock 改写）", action: #selector(toggleParaphrase), keyEquivalent: "")
        paraphraseItem.target = self
        menu.addItem(paraphraseItem)
        self.paraphraseItem = paraphraseItem
        menu.addItem(withTitle: "History…", action: #selector(openHistory), keyEquivalent: "y").target = self
        menu.addItem(withTitle: "Copy Last Transcript", action: #selector(copyTranscript), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        menu.delegate = self
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 458, height: 540),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Floe"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.canHide = false
        let settingsView = NSHostingView(rootView: ControlView(model: model))
        window.contentView = settingsView
        window.setContentSize(settingsView.fittingSize)
        window.center()
        bar = QuietPanel(contentRect: NSRect(x: 0, y: 0, width: RecordingBar.width, height: RecordingBar.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        bar.isOpaque = false
        bar.backgroundColor = .clear
        bar.hasShadow = false
        bar.ignoresMouseEvents = true
        bar.level = .statusBar
        bar.hidesOnDeactivate = false
        bar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        bar.contentView = NSHostingView(rootView: RecordingBar(model: model))
        suggestionPanel = QuietPanel(contentRect: NSRect(x: 0, y: 0, width: 372, height: 130),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        suggestionPanel.isOpaque = false
        suggestionPanel.backgroundColor = .clear
        suggestionPanel.level = .floating
        suggestionPanel.hidesOnDeactivate = false
        suggestionPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        suggestionPanel.contentView = NSHostingView(rootView: HotwordSuggestionView(model: model))
        model.suggestionChanged = { [weak self] in
            guard let self else { return }
            if self.model.suggestedWord == nil { self.suggestionPanel.orderOut(nil); return }
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            let frame = screen?.visibleFrame ?? self.window.frame
            self.suggestionPanel.setFrameOrigin(NSPoint(x: frame.maxX - 392, y: frame.minY + 20))
            self.suggestionPanel.orderFrontRegardless()
        }
        guidePanel = QuietPanel(contentRect: NSRect(x: 0, y: 0, width: 410, height: 230),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        guidePanel.titleVisibility = .hidden
        guidePanel.titlebarAppearsTransparent = true
        guidePanel.level = .floating
        guidePanel.hidesOnDeactivate = false
        guidePanel.isMovableByWindowBackground = true
        guidePanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        model.showSettingsAfterPermission = { [weak self] in self?.showSettings() }
        model.showHistory = { [weak self] in self?.openHistory() }
        model.restartForPermissions = { [weak self] in
            guard let self else { return }
            // Avoid a restart loop if the OS still reports stale access.
            guard !CommandLine.arguments.contains("--permission-restarted") else {
                self.model.status = "Permissions granted · Quit and reopen Floe"
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard !self.model.requestingMicrophone, !self.model.recording, !self.model.busy else {
                    self.model.deferPermissionRestart()
                    return
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.createsNewApplicationInstance = true
                configuration.arguments = PermissionRestart.arguments(
                    settingsVisible: self.window.isVisible, guide: self.model.permissionGuide)
                NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
                    DispatchQueue.main.async {
                        if error == nil { NSApp.terminate(nil) }
                        else { self.model.status = "Permissions granted · Quit and reopen Floe" }
                    }
                }
            }
        }
        model.guideChanged = { [weak self] guide in
            guard let self else { return }
            guard let guide else { self.guidePanel.orderOut(nil); return }
            let view = NSHostingView(rootView: PermissionGuideView(model: self.model, guide: guide))
            self.guidePanel.contentView = view
            self.guidePanel.setContentSize(view.fittingSize)
            let frame = NSScreen.main?.visibleFrame ?? self.window.frame
            self.guidePanel.setFrameOrigin(NSPoint(
                x: frame.maxX - self.guidePanel.frame.width - 24,
                y: frame.midY - self.guidePanel.frame.height / 2))
            self.guidePanel.orderFrontRegardless()
        }
        model.changed = { [weak self] in
            guard let self else { return }
            self.statusItem.button?.image = self.model.recording || self.model.busy
                ? NSImage(systemSymbolName: self.model.busy ? "ellipsis" : "mic.fill",
                          accessibilityDescription: self.model.status)
                : GlassArtwork.menuIcon()
            self.statusItem.button?.toolTip = self.model.status
            if self.model.recording || self.model.busy {
                if !self.bar.isVisible {
                    let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
                    if let frame = screen?.visibleFrame {
                        self.bar.setFrameOrigin(NSPoint(x: frame.midX - RecordingBar.width / 2, y: frame.minY + 24))
                    }
                    self.bar.orderFrontRegardless()
                }
            } else { self.bar.orderOut(nil) }
        }
        model.setup()
        if CommandLine.arguments.contains("--show-settings") ||
            !model.micAllowed || !model.inputAllowed || !model.accessibilityAllowed {
            showSettings()
        }
        if let guide = PermissionRestart.guide(in: CommandLine.arguments) {
            model.permissionGuide = guide
            model.guideChanged?(guide)
        }
        model.loginItem.configureDefault()
        if !model.loginItem.errorMessage.isEmpty {
            showSettings()
        }
    }

    @objc func showSettings() {
        model.refreshInputDevices()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    /// Floe lives in the menu bar; opening it again from Finder/Spotlight shows settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }
    private var paraphraseItem: NSMenuItem?
    @objc func toggleParaphrase() {
        model.paraphraseEnabled.toggle()
        model.saveParaphraseSettings()
    }
    func menuWillOpen(_ menu: NSMenu) {
        paraphraseItem?.state = model.paraphraseEnabled ? .on : .off
    }
    private var historyWindow: NSWindow?
    @objc func openHistory() {
        if historyWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Floe History"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: HistoryView(store: model.history))
            w.center()
            historyWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func copyTranscript() { model.copy() }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }
}

struct PromptEditor: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paraphrase prompt").font(.headline)
            Text("Sent to Bedrock as the system prompt. The transcript arrives wrapped in <transcript>…</transcript>; your hotwords are appended as a glossary.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $model.promptDraft)
                .font(.system(size: 12))
                .frame(minHeight: 280)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
            HStack {
                Button("Reset to Default") { model.promptDraft = Paraphraser.defaultPrompt }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.paraphrasePrompt = model.promptDraft
                    model.objectWillChange.send()
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18).frame(width: 520)
    }
}
