import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import Foundation

final class SafeWhisperApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var recorder: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isRecording = false
    private var currentRecordingURL: URL?
    private var hotkeyModifiers: NSEvent.ModifierFlags = [.control, .option]
    private var hotkeyKeyCode: UInt16 = 49 // Space
    private var hotkeyMenuItem: NSMenuItem!
    private var isCapturingHotkey = false
    private var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".safewhisper/run/helper.sock").path
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        loadHotkey()
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
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        hotkeyMenuItem = NSMenuItem(title: "Set hotkey… (\(hotkeyDisplayName()))", action: #selector(beginHotkeyCapture), keyEquivalent: "")
        hotkeyMenuItem.target = self
        menu.addItem(hotkeyMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit SafeWhisper", action: #selector(quit), keyEquivalent: "q"))
        return menu
    }

    private func installHotkey() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            if self.isCapturingHotkey {
                self.captureHotkey(event)
                return
            }
            guard event.keyCode == self.hotkeyKeyCode,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == self.hotkeyModifiers
            else { return }
            self.toggleRecording()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.isCapturingHotkey {
                self.captureHotkey(event)
                return nil
            }
            guard event.keyCode == self.hotkeyKeyCode,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == self.hotkeyModifiers
            else { return event }
            self.toggleRecording()
            return nil
        }
    }

    private func loadHotkey() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "hotkeyKeyCode") != nil {
            hotkeyKeyCode = UInt16(defaults.integer(forKey: "hotkeyKeyCode"))
            hotkeyModifiers = NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: "hotkeyModifiers")))
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

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        guard !isRecording else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("safewhisper-\(UUID().uuidString).caf")
        do {
            audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
            currentRecordingURL = url
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                do { try self?.audioFile?.write(from: buffer) }
                catch { NSLog("SafeWhisper audio write failed: \(error)") }
            }
            try engine.start()
            recorder = engine
            isRecording = true
            statusItem.button?.title = "● WF"
        } catch {
            NSLog("SafeWhisper recording failed: \(error)")
            cleanupRecording()
        }
    }

    private func stopRecording() {
        guard isRecording, let engine = recorder else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let recordingURL = currentRecordingURL
        audioFile = nil
        recorder = nil
        currentRecordingURL = nil
        isRecording = false
        statusItem.button?.title = "WF"
        guard let file = recordingURL else { return }
        transcribeAndPaste(file)
    }

    private func transcribeAndPaste(_ file: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let data = try Data(contentsOf: file)
                let response = try UnixSocketClient(path: self?.socketPath ?? "").transcribe(audio: data, suffix: ".caf")
                guard response.ok, let text = response.text, !text.isEmpty else { throw FlowError.message(response.error ?? "empty transcript") }
                DispatchQueue.main.async { self?.paste(text) }
            } catch {
                NSLog("SafeWhisper transcription failed: \(error)")
            }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let source = CGEventSource(stateID: .hidSystemState)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
    }

    private func cleanupRecording() {
        recorder?.inputNode.removeTap(onBus: 0)
        recorder?.stop()
        recorder = nil
        audioFile = nil
        currentRecordingURL = nil
        isRecording = false
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

    func transcribe(audio: Data, suffix: String) throws -> EngineResponse {
        let request: [String: Any] = [
            "type": "transcribe",
            "suffix": suffix,
            "audio_base64": audio.base64EncodedString()
        ]
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
