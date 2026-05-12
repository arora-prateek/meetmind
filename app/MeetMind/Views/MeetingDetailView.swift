import SwiftUI

struct MeetingDetailView: View {
    let meeting: Meeting
    var onBack: (() -> Void)? = nil
    @EnvironmentObject var store: MeetingStore
    @State private var transcriptExpanded = false
    @State private var showDeleteAudioConfirm = false
    @State private var audioFileDeleted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.title)
                        .font(.largeTitle.bold())
                    HStack(spacing: 8) {
                        Text(meeting.recordedAt, style: .date)
                        Text(meeting.recordedAt, style: .time)
                        if let dur = meeting.durationSeconds {
                            Text("·")
                            Text(formatDuration(dur))
                        }
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                }

                Divider()

                // Summary
                if let summary = meeting.summary, !summary.isEmpty {
                    SectionView(title: "Summary", icon: "doc.text") {
                        Text(summary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Decisions
                if !meeting.decisions.isEmpty {
                    SectionView(title: "Decisions", icon: "checkmark.seal") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(meeting.decisions, id: \.self) { decision in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("•")
                                    Text(decision)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }

                // Action Items
                if !meeting.actionItems.isEmpty {
                    SectionView(title: "Action Items", icon: "checklist") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(meeting.actionItems.enumerated()), id: \.offset) { _, item in
                                ActionItemRow(item: item)
                            }
                        }
                    }
                }

                // Recording artifact
                if let path = meeting.audioFilePath, !audioFileDeleted {
                    SectionView(title: "Recording", icon: "waveform") {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(path)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if let size = audioFileSize(path) {
                                    Text(size)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Button("Delete", role: .destructive) {
                                showDeleteAudioConfirm = true
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .confirmationDialog("Delete the audio file?", isPresented: $showDeleteAudioConfirm) {
                        Button("Delete Recording", role: .destructive) {
                            try? store.deleteAudio(for: meeting)
                            audioFileDeleted = true
                        }
                    }
                }

                // Transcript (collapsed by default)
                if let transcript = meeting.transcript, !transcript.isEmpty {
                    SectionView(
                        title: "Transcript",
                        icon: "text.quote",
                        accessory: AnyView(
                            Button(transcriptExpanded ? "Collapse" : "Expand") {
                                withAnimation { transcriptExpanded.toggle() }
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.accentColor)
                        )
                    ) {
                        if transcriptExpanded {
                            Text(transcript)
                                .font(.system(.body, design: .monospaced))
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(transcript)
                                .lineLimit(3)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle(meeting.title)
        .navigationSubtitle(meeting.recordedAt, style: .date)
        .toolbar {
            if let onBack {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onBack()
                    } label: {
                        Label("New Recording", systemImage: "plus")
                    }
                }
            }
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }

    private func audioFileSize(_ filename: String) -> String? {
        let url = MeetingStore.recordingsDirectory.appendingPathComponent(filename)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = attrs[.size] as? Int64 else { return nil }
        let mb = Double(bytes) / 1_048_576
        return mb >= 1 ? String(format: "%.1f MB", mb) : "\(bytes / 1024) KB"
    }
}

struct SectionView<Content: View>: View {
    let title: String
    let icon: String
    var accessory: AnyView? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.title3.bold())
                Spacer()
                accessory
            }
            content()
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }
}

struct ActionItemRow: View {
    let item: ActionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.description)
                .font(.body)
            HStack(spacing: 12) {
                if let owner = item.owner {
                    Label(owner, systemImage: "person")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let due = item.dueDate {
                    Label(due, systemImage: "calendar")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(6)
    }
}

extension View {
    func navigationSubtitle(_ date: Date, style: Text.DateStyle) -> some View {
        self.navigationSubtitle(Text(date, style: style))
    }
}
