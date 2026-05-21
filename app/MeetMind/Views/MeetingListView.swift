import SwiftUI

struct MeetingListView: View {
    @EnvironmentObject var store: MeetingStore
    @Binding var selectedMeeting: Meeting?

    @State private var sortOrder: SortOrder = .timeDescending
    @State private var searchText = ""
    @State private var renamingMeeting: Meeting? = nil
    @State private var renameText = ""

    enum SortOrder: String, CaseIterable {
        case timeDescending = "Newest First"
        case timeAscending  = "Oldest First"
        case nameAscending  = "Name A–Z"
        case nameDescending = "Name Z–A"
    }

    private func commitRename(_ meeting: Meeting) {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        renamingMeeting = nil
        guard !trimmed.isEmpty else { return }
        var updated = meeting
        updated.title = trimmed
        try? store.save(updated)
    }

    private func deleteMeeting(_ meeting: Meeting) {
        if let path = meeting.audioFilePath {
            let url = MeetingStore.recordingsDirectory.appendingPathComponent(path)
            try? FileManager.default.removeItem(at: url)
        }
        try? store.delete(meeting)
        if selectedMeeting == meeting { selectedMeeting = nil }
    }

    private var displayedMeetings: [Meeting] {
        let q = searchText.lowercased()
        let filtered = q.isEmpty ? store.meetings : store.meetings.filter {
            $0.title.lowercased().contains(q) ||
            ($0.transcript?.lowercased().contains(q) ?? false)
        }
        switch sortOrder {
        case .timeDescending: return filtered.sorted { $0.recordedAt > $1.recordedAt }
        case .timeAscending:  return filtered.sorted { $0.recordedAt < $1.recordedAt }
        case .nameAscending:  return filtered.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        case .nameDescending: return filtered.sorted { $0.title.localizedCompare($1.title) == .orderedDescending }
        }
    }

    var body: some View {
        Group {
            if displayedMeetings.isEmpty && store.processingJobs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "waveform.circle")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    if !searchText.isEmpty {
                        Text("No results for '\(searchText)'")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    } else {
                        Text("No meetings yet")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Start a new recording to get your first transcript.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedMeeting) {
                    ForEach(store.processingJobs) { job in
                        JobRow(job: job,
                               onRetry: { store.retry(job) },
                               onDiscard: { store.discardJob(job) })
                    }
                    ForEach(displayedMeetings) { meeting in
                        MeetingRow(meeting: meeting, searchQuery: searchText)
                            .tag(meeting)
                            .contextMenu {
                                Button {
                                    renamingMeeting = meeting
                                    renameText = meeting.title
                                } label: {
                                    Label("Rename…", systemImage: "pencil")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    deleteMeeting(meeting)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                    .onDelete { offsets in
                        offsets.map { displayedMeetings[$0] }.forEach { deleteMeeting($0) }
                    }
                }
            }
        }
        .sheet(item: $renamingMeeting) { m in
            VStack(alignment: .leading, spacing: 20) {
                Text("Rename Meeting").font(.headline)
                TextField("Meeting title", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRename(m) }
                HStack {
                    Spacer()
                    Button("Cancel") { renamingMeeting = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") { commitRename(m) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 340)
        }
        .searchable(text: $searchText, placement: .sidebar)
        .navigationTitle("Meetings")
        .toolbar {
            ToolbarItem {
                Menu {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Button {
                            sortOrder = order
                        } label: {
                            if sortOrder == order {
                                Label(order.rawValue, systemImage: "checkmark")
                            } else {
                                Text(order.rawValue)
                            }
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
            ToolbarItem {
                Button {
                    selectedMeeting = nil
                } label: {
                    Label("New Recording", systemImage: "plus")
                }
            }
        }
    }
}

struct JobRow: View {
    let job: ProcessingJob
    var onRetry: () -> Void
    var onDiscard: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title).font(.headline).lineLimit(1)
                switch job.status {
                case .processing:
                    Text("Processing…").font(.caption).foregroundColor(.secondary)
                case .failed(let msg):
                    Text(msg).font(.caption).foregroundColor(.red).lineLimit(2)
                }
            }
            Spacer()
            switch job.status {
            case .processing:
                ProgressView()
            case .failed:
                HStack(spacing: 8) {
                    Button("Retry") { onRetry() }.buttonStyle(.borderedProminent)
                    Button("Discard") { onDiscard() }.buttonStyle(.bordered)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

struct MeetingRow: View {
    let meeting: Meeting
    var searchQuery: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(highlighted(meeting.title, query: searchQuery))
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(meeting.recordedAt, style: .date)
                Text(meeting.recordedAt, style: .time)
                if let dur = meeting.durationSeconds {
                    Text("·")
                    Text(formatDuration(dur))
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }

    private func highlighted(_ text: String, query: String) -> AttributedString {
        var result = AttributedString(text)
        guard !query.isEmpty else { return result }
        let lower = text.lowercased()
        let q = query.lowercased()
        var start = lower.startIndex
        while let range = lower.range(of: q, range: start..<lower.endIndex) {
            let offset = lower.distance(from: lower.startIndex, to: range.lowerBound)
            let length = lower.distance(from: range.lowerBound, to: range.upperBound)
            let attrStart = result.index(result.startIndex, offsetByCharacters: offset)
            let attrEnd   = result.index(attrStart, offsetByCharacters: length)
            result[attrStart..<attrEnd].backgroundColor = .yellow
            start = range.upperBound
        }
        return result
    }
}
