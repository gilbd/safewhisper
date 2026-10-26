import AppKit
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

final class SafeWhisperApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var recorder: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var carbonHotKey: EventHotKeyRef?
    private var carbonEscapeHotKey: EventHotKeyRef?
    private var carbonEventHandler: EventHandlerRef?
    private var isRecording = false
    private var currentRecordingURL: URL?
    private var targetApplication: NSRunningApplication?
    private var processingTimer: Timer?
    private var processingFrame = 0
    private var hotkeyModifiers: NSEvent.ModifierFlags = [.control, .option]
    private var hotkeyKeyCode: UInt16 = 49 // Space
    private var hotkeyMenuItem: NSMenuItem!
    private var recordingMenuItem: NSMenuItem!
    private var languageMenuItem: NSMenuItem!
    private var languageModeItems: [String: NSMenuItem] = [:]
    private var transcriptionLanguage = "auto"
    private var isCapturingHotkey = false
    private var cancellationRequested = false
    private var lastHotkeyToggle = Date.distantPast
    private var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".safewhisper/run/helper.sock").path
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        loadHotkey()
        loadLanguageMode()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "WF"
        statusItem.menu = makeMenu()
        installHotkey()
        requestMicrophonePermission()
        requestAccessibilityPermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        unregisterCarbonHotkey()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        hotkeyMenuItem = NSMenuItem(title: "Set hotkey… (\(hotkeyDisplayName()))", action: #selector(beginHotkeyCapture), keyEquivalent: "")
        hotkeyMenuItem.target = self
        menu.addItem(hotkeyMenuItem)
        recordingMenuItem = NSMenuItem(title: "Start recording", action: #selector(toggleRecordingFromMenu), keyEquivalent: "")
        recordingMenuItem.target = self
        menu.addItem(recordingMenuItem)

        languageMenuItem = NSMenuItem(title: "Language: Auto", action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        for (code, title) in [("auto", "Auto-detect"), ("he", "Hebrew"), ("en", "English")] {
            let item = NSMenuItem(title: title, action: #selector(selectLanguageMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            languageModeItems[code] = item
            languageMenu.addItem(item)
        }
        languageMenuItem.submenu = languageMenu
        menu.addItem(languageMenuItem)
        updateLanguageMenu()

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit SafeWhisper", action: #selector(quit), keyEquivalent: "q"))
        return menu
    }

    private func installHotkey() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            if self.isRecording && event.keyCode == 53 {
                self.cancelRecording()
                return
            }
            guard event.keyCode == self.hotkeyKeyCode,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(self.hotkeyModifiers)
            else { return }
            self.requestHotkeyToggle()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.isRecording && event.keyCode == 53 {
                self.cancelRecording()
                return nil
            }
            if self.isCapturingHotkey {
                self.captureHotkey(event)
                return nil
            }
            return event
        }
        registerCarbonHotkey()
    }

    private func registerCarbonHotkey() {
        unregisterCarbonHotkey()
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let handler: EventHandlerUPP = { eventHandlerCallRef, eventRef, userData in
            guard let userData else { return noErr }
            let app = Unmanaged<SafeWhisperApp>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            var actualSize: Int = 0
            let parameterStatus = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(kEventParamDirectObject),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                &actualSize,
                &hotKeyID
            )
            if parameterStatus == noErr && hotKeyID.id == 2 {
                app.cancelRecording()
            } else {
                app.requestHotkeyToggle()
            }
            _ = eventHandlerCallRef
            return noErr
        }
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventSpec,
            userData,
            &carbonEventHandler
        )
        guard installStatus == noErr else {
            NSLog("SafeWhisper: failed to install Carbon hotkey event handler: \(installStatus)")
            return
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x53414645), id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(hotkeyKeyCode),
            carbonModifiers(),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &carbonHotKey
        )
        if registerStatus != noErr {
            NSLog("SafeWhisper: failed to register Carbon hotkey: \(registerStatus)")
        }
    }

    private func registerEscapeHotkey() {
        guard carbonEscapeHotKey == nil else { return }
        let escapeID = EventHotKeyID(signature: OSType(0x53414645), id: 2)
        let status = RegisterEventHotKey(
            53,
            0,
            escapeID,
            GetApplicationEventTarget(),
            0,
            &carbonEscapeHotKey
        )
        if status != noErr {
            NSLog("SafeWhisper: failed to register Carbon Escape hotkey: \(status)")
        }
    }

    private func unregisterEscapeHotkey() {
        if let carbonEscapeHotKey {
            UnregisterEventHotKey(carbonEscapeHotKey)
            self.carbonEscapeHotKey = nil
        }
    }

    private func unregisterCarbonHotkey() {
        unregisterEscapeHotkey()
        if let carbonHotKey {
            UnregisterEventHotKey(carbonHotKey)
            self.carbonHotKey = nil
        }
        if let carbonEventHandler {
            RemoveEventHandler(carbonEventHandler)
            self.carbonEventHandler = nil
        }
    }

    private func carbonModifiers() -> UInt32 {
        var result: UInt32 = 0
        if hotkeyModifiers.contains(.command) { result |= UInt32(cmdKey) }
        if hotkeyModifiers.contains(.option) { result |= UInt32(optionKey) }
        if hotkeyModifiers.contains(.control) { result |= UInt32(controlKey) }
        if hotkeyModifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private func loadHotkey() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "hotkeyKeyCode") != nil {
            hotkeyKeyCode = UInt16(defaults.integer(forKey: "hotkeyKeyCode"))
            hotkeyModifiers = NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: "hotkeyModifiers")))
        }
    }

    private func loadLanguageMode() {
        let saved = UserDefaults.standard.string(forKey: "transcriptionLanguage") ?? "auto"
        transcriptionLanguage = ["auto", "he", "en"].contains(saved) ? saved : "auto"
    }

    @objc private func selectLanguageMode(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String,
              ["auto", "he", "en"].contains(code) else { return }
        transcriptionLanguage = code
        UserDefaults.standard.set(code, forKey: "transcriptionLanguage")
        updateLanguageMenu()
        NSApp.hide(nil)
    }

    private func updateLanguageMenu() {
        let titles = ["auto": "Auto", "he": "Hebrew", "en": "English"]
        languageMenuItem?.title = "Language: \(titles[transcriptionLanguage] ?? "Auto")"
        for (code, item) in languageModeItems {
            item.state = code == transcriptionLanguage ? .on : .off
        }
    }

    @objc private func beginHotkeyCapture() {
        isCapturingHotkey = true
        hotkeyMenuItem.title = "Press a new hotkey…"
        NSApp.activate(ignoringOtherApps: true)
    }

    private func captureHotkey(_ event: NSEvent) {
        guard isCapturingHotkey else { return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !modifiers.isEmpty else {
            hotkeyMenuItem.title = "Use a modifier + key…"
            return
        }
        hotkeyModifiers = modifiers
        hotkeyKeyCode = event.keyCode
        let defaults = UserDefaults.standard
        defaults.set(Int(hotkeyKeyCode), forKey: "hotkeyKeyCode")
        defaults.set(Int(hotkeyModifiers.rawValue), forKey: "hotkeyModifiers")
        isCapturingHotkey = false
        hotkeyMenuItem.title = "Set hotkey… (\(hotkeyDisplayName()))"
        registerCarbonHotkey()
    }

    private func hotkeyDisplayName() -> String {
        var result = ""
        if hotkeyModifiers.contains(.control) { result += "⌃" }
        if hotkeyModifiers.contains(.option) { result += "⌥" }
        if hotkeyModifiers.contains(.command) { result += "⌘" }
        if hotkeyModifiers.contains(.shift) { result += "⇧" }
        let keyNames: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 53: "Esc", 51: "Delete"]
        return result + (keyNames[hotkeyKeyCode] ?? "Key \(hotkeyKeyCode)")
    }

    private func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted { NSLog("SafeWhisper: microphone permission denied") }
        }
    }

    private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard !AXIsProcessTrustedWithOptions(options) else { return }
        NSLog("SafeWhisper: Accessibility permission is required for global hotkey and paste")
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func requestHotkeyToggle() {
        let now = Date()
        guard now.timeIntervalSince(lastHotkeyToggle) > 0.35 else { return }
        lastHotkeyToggle = now
        toggleRecording()
    }

    @objc private func toggleRecordingFromMenu() {
        toggleRecording()
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        guard !isRecording else { return }
        targetApplication = NSWorkspace.shared.frontmostApplication
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("safewhisper-\(UUID().uuidString).caf")
        do {
            audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
            currentRecordingURL = url
            cancellationRequested = false
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                do { try self?.audioFile?.write(from: buffer) }
                catch { NSLog("SafeWhisper audio write failed: \(error)") }
            }
            try engine.start()
            recorder = engine
            isRecording = true
            registerEscapeHotkey()
            recordingMenuItem.title = "Stop recording"
            statusItem.button?.title = "● WF"
        } catch {
            NSLog("SafeWhisper recording failed: \(error)")
            showError("Recording failed", error.localizedDescription)
            cleanupRecording()
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        if cancellationRequested {
            cancelRecording()
            return
        }
        guard let engine = recorder else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let recordingURL = currentRecordingURL
        audioFile = nil
        recorder = nil
        currentRecordingURL = nil
        isRecording = false
        cancellationRequested = false
        unregisterEscapeHotkey()
        recordingMenuItem.title = "Start recording"
        statusItem.button?.title = "WF"
        beginProcessingIndicator()
        guard let file = recordingURL else {
            stopProcessingIndicator()
            return
        }
        guard hasAudioFrames(file) else {
            targetApplication = nil
            try? FileManager.default.removeItem(at: file)
            stopProcessingIndicator()
            NSLog("SafeWhisper: ignoring empty recording")
            return
        }
        transcribeAndPaste(file, language: transcriptionLanguage)
    }

    private func hasAudioFrames(_ url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        return file.length > 0
    }

    private func cancelRecording() {
        guard isRecording else { return }
        cancellationRequested = true
        let recordingURL = currentRecordingURL
        recorder?.inputNode.removeTap(onBus: 0)
        recorder?.stop()
        audioFile = nil
        recorder = nil
        currentRecordingURL = nil
        targetApplication = nil
        isRecording = false
        cancellationRequested = false
        unregisterEscapeHotkey()
        recordingMenuItem.title = "Start recording"
        statusItem.button?.title = "WF"
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        NSLog("SafeWhisper recording cancelled with Escape")
    }

    private func beginProcessingIndicator() {
        processingTimer?.invalidate()
        processingFrame = 0
        let frames = ["◌ WF", "◔ WF", "◑ WF", "◕ WF"]
        statusItem.button?.title = frames[0]
        processingTimer = Timer.scheduledTimer(withTimeInterval: 0.16, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.processingFrame = (self.processingFrame + 1) % frames.count
            self.statusItem.button?.title = frames[self.processingFrame]
        }
    }

    private func stopProcessingIndicator() {
        processingTimer?.invalidate()
        processingTimer = nil
        processingFrame = 0
        statusItem.button?.title = isRecording ? "● WF" : "WF"
    }

    private func transcribeAndPaste(_ file: URL, language: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let data = try Data(contentsOf: file)
                let response = try UnixSocketClient(path: self?.socketPath ?? "").transcribe(audio: data, suffix: ".caf", language: language)
                guard response.ok, let text = response.text, !text.isEmpty else { throw FlowError.message(response.error ?? "empty transcript") }
                DispatchQueue.main.async {
                    self?.stopProcessingIndicator()
                    self?.paste(text)
                }
            } catch {
                NSLog("SafeWhisper transcription failed: \(error)")
                DispatchQueue.main.async {
                    self?.stopProcessingIndicator()
                    self?.showError("Transcription failed", error.localizedDescription)
                }
            }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func showError(_ title: String, _ message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.runModal()
        }
    }

    private func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            NSLog("SafeWhisper: failed to write transcript to pasteboard")
            return
        }

        let target = targetApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? NSWorkspace.shared.frontmostApplication
            : targetApplication
        let pasteAction = { [weak self] in
            guard let self else { return }
            let source = CGEventSource(stateID: .hidSystemState)
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
            vDown?.flags = .maskCommand
            vUp?.flags = .maskCommand
            vDown?.post(tap: .cghidEventTap)
            vUp?.post(tap: .cghidEventTap)
            self.targetApplication = nil
        }

        if let target, target.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            target.activate(options: [.activateIgnoringOtherApps])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: pasteAction)
        } else {
            pasteAction()
        }
    }

    private func cleanupRecording() {
        recorder?.inputNode.removeTap(onBus: 0)
        recorder?.stop()
        processingTimer?.invalidate()
        processingTimer = nil
        targetApplication = nil
        recorder = nil
        audioFile = nil
        currentRecordingURL = nil
        isRecording = false
        cancellationRequested = false
        unregisterEscapeHotkey()
        recordingMenuItem.title = "Start recording"
        statusItem.button?.title = "WF"
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

private enum FlowError: Error { case message(String) }
extension FlowError: LocalizedError {
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

private struct EngineResponse: Decodable {
    let ok: Bool
    let text: String?
    let error: String?
}

private struct UnixSocketClient {
    let path: String

    func transcribe(audio: Data, suffix: String, language: String) throws -> EngineResponse {
        var request: [String: Any] = [
            "type": "transcribe",
            "suffix": suffix,
            "audio_base64": audio.base64EncodedString()
        ]
        if language != "auto" {
            request["language"] = language
        }
        let payload = try JSONSerialization.data(withJSONObject: request)
        let connection = try UnixConnection(path: path)
        try connection.write(payload + Data([10]))
        let responseData = try connection.readLine()
        return try JSONDecoder().decode(EngineResponse.self, from: responseData)
    }
}

private final class UnixConnection {
    private let handle: FileHandle

    init(path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FlowError.message("socket() failed") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.prefix(buffer.count).enumerated() { buffer[index] = byte }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        guard connected == 0 else { close(fd); throw FlowError.message("engine socket unavailable") }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func write(_ data: Data) throws { try handle.write(contentsOf: data) }
    func readLine() throws -> Data {
        var result = Data()
        while let byte = try handle.read(upToCount: 1), !byte.isEmpty {
            if byte[0] == 10 { return result }
            result.append(byte[0])
        }
        return result
    }
}

let app = NSApplication.shared
let delegate = SafeWhisperApp()
app.delegate = delegate
app.run()
