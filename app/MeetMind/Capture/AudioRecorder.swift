import Foundation
import AppKit
import AVFoundation
import CoreAudio
import ApplicationServices

enum AudioRecorderError: Error, LocalizedError {
    case permissionDenied
    case captureFailed(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access is required. Go to System Settings → Privacy & Security → Microphone and enable MeetMind."
        case .captureFailed(let msg):
            return "Capture failed: \(msg)"
        case .exportFailed(let msg):
            return "Export failed: \(msg)"
        }
    }
}

enum PauseReason: Equatable {
    case systemMute
    case zoom
    case teams
}

@MainActor
class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var pauseReason: PauseReason?
    @Published var elapsedSeconds: Int = 0

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?
    private var timer: Timer?
    private var muteCheckTimer: Timer?

    private var monitoredDeviceID: AudioDeviceID = 0

    private var stopContinuation: CheckedContinuation<URL, Error>?

    // MARK: - Public API

    func start() async throws {
        guard !isRecording else { return }

        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw AudioRecorderError.permissionDenied }

        // Request accessibility permission — needed to detect Teams mute state.
        // Shows a one-time system prompt if not already granted.
        let axOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(axOptions)

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        tempFileURL = url

        let audioFile = try AVAudioFile(forWriting: url, settings: nativeFormat.settings)
        self.audioFile = audioFile

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard self?.isPaused != true else { return }
            try? audioFile.write(from: buffer)
        }

        try engine.start()
        self.audioEngine = engine

        isRecording = true
        isPaused = false
        pauseReason = nil
        elapsedSeconds = 0

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording, !self.isPaused else { return }
                self.elapsedSeconds += 1
            }
        }

        startMuteMonitoring()
    }

    func stop() async throws -> URL {
        guard isRecording else { throw AudioRecorderError.captureFailed("Not recording") }
        return try await withCheckedThrowingContinuation { continuation in
            stopContinuation = continuation
            Task { @MainActor in await self.finishRecording() }
        }
    }

    // MARK: - Mute monitoring

    private func startMuteMonitoring() {
        // Resolve the default input device once at start
        var deviceID = AudioDeviceID(0)
        var propSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var sysAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &sysAddr, 0, nil, &propSize, &deviceID)
        monitoredDeviceID = deviceID

        // Poll all three sources at 1-second intervals on the main actor
        muteCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkSystemMute()
                self?.checkZoomMute()
                self?.checkTeamsMute()
            }
        }
        // Run immediately so the UI reflects current state without waiting 1s
        checkSystemMute()
        checkZoomMute()
        checkTeamsMute()
    }

    private func stopMuteMonitoring() {
        muteCheckTimer?.invalidate()
        muteCheckTimer = nil
        monitoredDeviceID = 0
    }

    // MARK: - Core Audio (system-level mic mute)

    private func checkSystemMute() {
        guard monitoredDeviceID != 0 else { return }
        var mute: UInt32 = 0
        var propSize = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(monitoredDeviceID, &addr, 0, nil, &propSize, &mute) == noErr else { return }
        applyMuteState(mute == 1, reason: .systemMute)
    }

    // MARK: - Zoom (osascript)

    private func checkZoomMute() {
        let zoomRunning = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == "us.zoom.xos" }

        guard zoomRunning else {
            applyMuteState(false, reason: .zoom)
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", "tell application \"zoom.us\" to return isMuted"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = Pipe()
            try? task.run()
            task.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let muted = (output == "true")
            Task { @MainActor [weak self] in
                self?.applyMuteState(muted, reason: .zoom)
            }
        }
    }

    // MARK: - Teams (Accessibility API)

    private func checkTeamsMute() {
        guard AXIsProcessTrusted() else { return }

        let teamsIDs = ["com.microsoft.teams", "com.microsoft.teams2"]
        guard let teams = NSWorkspace.shared.runningApplications.first(where: {
            teamsIDs.contains($0.bundleIdentifier ?? "")
        }) else {
            applyMuteState(false, reason: .teams)
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let appElement = AXUIElementCreateApplication(teams.processIdentifier)
            let muted = Self.isMutedViaAccessibility(appElement)
            Task { @MainActor [weak self] in
                self?.applyMuteState(muted, reason: .teams)
            }
        }
    }

    /// Searches the accessibility tree for a button whose label indicates the user is currently muted.
    /// In Teams and most meeting apps, the mute button reads "Unmute" when the user is muted.
    /// Teams is Electron-based with a 30–50 level deep tree, so depth limit must be generous.
    private static func isMutedViaAccessibility(_ element: AXUIElement, depth: Int = 0) -> Bool {
        guard depth < 40 else { return false }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        if role == (kAXButtonRole as String) {
            var titleRef: CFTypeRef?
            var descRef: CFTypeRef?
            var helpRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
            AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef)
            AXUIElementCopyAttributeValue(element, kAXHelpAttribute as CFString, &helpRef)

            let title = (titleRef as? String ?? "").lowercased()
            let desc  = (descRef as? String ?? "").lowercased()
            let help  = (helpRef as? String ?? "").lowercased()
            let combined = title + " " + desc + " " + help

            // "Unmute" / "turn on mic" button is present → user is currently muted
            if combined.contains("unmute")
                || combined.contains("turn on mic")
                || combined.contains("unmute microphone")
                || combined.contains("mic is off")
                || combined.contains("microphone off")
                || combined.contains("audio off")
                || combined.contains("start audio") {
                return true
            }
        }

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return false }

        for child in children {
            if isMutedViaAccessibility(child, depth: depth + 1) { return true }
        }
        return false
    }

    // MARK: - Shared mute state applier

    private func applyMuteState(_ muted: Bool, reason: PauseReason) {
        if muted {
            // Only take over if not already paused by a different source
            if !isPaused {
                isPaused = true
                pauseReason = reason
            }
        } else {
            // Only resume if we were the one who paused it
            if isPaused, pauseReason == reason {
                isPaused = false
                pauseReason = nil
            }
        }
    }

    // MARK: - Finish

    private func finishRecording() async {
        stopMuteMonitoring()
        timer?.invalidate()
        timer = nil
        isRecording = false
        isPaused = false
        pauseReason = nil

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil

        guard let url = tempFileURL else {
            stopContinuation?.resume(throwing: AudioRecorderError.captureFailed("No temp file"))
            stopContinuation = nil
            return
        }
        tempFileURL = nil
        stopContinuation?.resume(returning: url)
        stopContinuation = nil
    }
}
