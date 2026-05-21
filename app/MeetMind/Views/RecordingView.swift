import SwiftUI

struct RecordingView: View {
    var onComplete: (Meeting) -> Void

    @EnvironmentObject var store: MeetingStore
    @StateObject private var recorder = AudioRecorder()

    @State private var titleInput = ""
    @State private var status: RecordingStatus = .ready
    @State private var errorMessage: String?

    enum RecordingStatus {
        case ready, recording, processing
        var label: String {
            switch self {
            case .ready:      return "Ready"
            case .recording:  return "Recording..."
            case .processing: return "Processing..."
            }
        }
    }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Title input
            TextField("Meeting title (optional)", text: $titleInput)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 400)
                .disabled(recorder.isRecording || status == .processing)

            // Timer
            if recorder.isRecording {
                Text(formatDuration(recorder.elapsedSeconds))
                    .font(.system(size: 48, weight: .thin, design: .monospaced))
                    .foregroundColor(recorder.isPaused ? .orange : .red)
            }

            // Record / Stop button
            Button { handleButtonTap() } label: {
                Circle()
                    .fill(recordButtonColor)
                    .frame(width: 80, height: 80)
                    .overlay {
                        if status == .processing {
                            ProgressView().scaleEffect(1.5).tint(.white)
                        } else {
                            Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.white)
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(status == .processing)

            // Status — shows auto-pause reason when applicable
            HStack(spacing: 6) {
                if recorder.isPaused {
                    Image(systemName: "mic.slash.fill")
                        .foregroundColor(.orange)
                }
                Text(statusLabel)
                    .font(.headline)
                    .foregroundColor(recorder.isPaused ? .orange : .secondary)
            }

            // Error (only for recorder.stop() or file-move failures)
            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            Spacer()
        }
        .padding()
        .navigationTitle("New Recording")
    }

    private var recordButtonColor: Color {
        if status == .processing { return .gray }
        if recorder.isRecording  { return recorder.isPaused ? .orange : .red }
        return .gray
    }

    private var statusLabel: String {
        guard recorder.isRecording else { return status.label }
        if let reason = recorder.pauseReason {
            switch reason {
            case .systemMute: return "Paused — mic muted at system level"
            case .zoom:       return "Paused — muted in Zoom"
            case .teams:      return "Paused — muted in Teams"
            }
        }
        return status.label
    }

    private func handleButtonTap() {
        recorder.isRecording ? stopAndProcess() : startRecording()
    }

    private func startRecording() {
        errorMessage = nil
        status = .recording
        Task {
            do {
                try await recorder.start()
            } catch {
                await MainActor.run {
                    status = .ready
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func stopAndProcess() {
        let recordedAt = Date()
        let duration = recorder.elapsedSeconds
        let title = titleInput.trimmingCharacters(in: .whitespaces).isEmpty
            ? defaultTitle(for: recordedAt)
            : titleInput
        status = .processing   // brief — just while moving the file

        Task {
            do {
                let tempURL = try await recorder.stop()
                let meetingID = UUID()
                let ext = tempURL.pathExtension.isEmpty ? "m4a" : tempURL.pathExtension
                let destURL = MeetingStore.recordingsDirectory
                    .appendingPathComponent("\(meetingID.uuidString).\(ext)")
                try FileManager.default.moveItem(at: tempURL, to: destURL)

                let job = ProcessingJob(
                    id: meetingID, title: title,
                    audioFilePath: "\(meetingID.uuidString).\(ext)",
                    recordedAt: recordedAt, durationSeconds: duration,
                    status: .processing
                )
                await MainActor.run {
                    store.enqueue(job)
                    titleInput = ""
                    status = .ready   // user can record again immediately
                }
            } catch {
                await MainActor.run {
                    status = .ready
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func defaultTitle(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return "Meeting — \(fmt.string(from: date))"
    }

    private func formatDuration(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
