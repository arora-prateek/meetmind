import Foundation
import GRDB

class MeetingStore: ObservableObject {
    static let shared = MeetingStore()

    @Published var meetings: [Meeting] = []
    @Published var processingJobs: [ProcessingJob] = []

    private var dbQueue: DatabaseQueue

    static var recordingsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MeetMind/recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("MeetMind", isDirectory: true)
        try! FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let dbPath = appDir.appendingPathComponent("meetings.sqlite").path

        dbQueue = try! DatabaseQueue(path: dbPath)
        try! migrate()
        try! loadAll()
    }

    // MARK: - Migration

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "meetings", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("recorded_at", .text).notNull()
                t.column("duration_seconds", .integer)
                t.column("transcript", .text)
                t.column("summary", .text)
                t.column("decisions", .text)
                t.column("action_items", .text)
                t.column("created_at", .text).notNull()
            }
        }
        migrator.registerMigration("v2") { db in
            try db.alter(table: "meetings") { t in
                t.add(column: "audio_file_path", .text)
            }
        }
        try migrator.migrate(dbQueue)
    }

    // MARK: - Job Queue

    func enqueue(_ job: ProcessingJob) {
        processingJobs.append(job)
        Task { await runJob(job) }
    }

    private func runJob(_ job: ProcessingJob) async {
        do {
            let url = MeetingStore.recordingsDirectory.appendingPathComponent(job.audioFilePath)
            let audio = try Data(contentsOf: url)
            let mimeType = self.mimeType(for: url)
            let result = try await BackendClient.shared.processMeeting(
                audio: audio, mimeType: mimeType, title: job.title, recordedAt: job.recordedAt)
            let meeting = Meeting(
                id: job.id, title: job.title, recordedAt: job.recordedAt,
                durationSeconds: job.durationSeconds,
                transcript: result.transcript, summary: result.summary,
                decisions: result.decisions, actionItems: result.actionItems,
                audioFilePath: job.audioFilePath
            )
            try save(meeting)
            await MainActor.run { processingJobs.removeAll { $0.id == job.id } }
        } catch {
            await MainActor.run {
                if let i = processingJobs.firstIndex(where: { $0.id == job.id }) {
                    processingJobs[i].status = .failed(error.localizedDescription)
                }
            }
        }
    }

    func retry(_ job: ProcessingJob) {
        if let i = processingJobs.firstIndex(where: { $0.id == job.id }) {
            processingJobs[i].status = .processing
        }
        Task { await runJob(job) }
    }

    func discardJob(_ job: ProcessingJob) {
        let url = MeetingStore.recordingsDirectory.appendingPathComponent(job.audioFilePath)
        try? FileManager.default.removeItem(at: url)
        processingJobs.removeAll { $0.id == job.id }
    }

    // MARK: - Public API

    func save(_ meeting: Meeting) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO meetings
                    (id, title, recorded_at, duration_seconds, transcript, summary, decisions, action_items, audio_file_path, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    meeting.id.uuidString,
                    meeting.title,
                    iso8601.string(from: meeting.recordedAt),
                    meeting.durationSeconds,
                    meeting.transcript,
                    meeting.summary,
                    encodeJSON(meeting.decisions),
                    encodeJSON(meeting.actionItems),
                    meeting.audioFilePath,
                    iso8601.string(from: meeting.createdAt)
                ]
            )
        }
        try loadAll()
    }

    func deleteAudio(for meeting: Meeting) throws {
        guard let path = meeting.audioFilePath else { return }
        let url = MeetingStore.recordingsDirectory.appendingPathComponent(path)
        try? FileManager.default.removeItem(at: url)
        var updated = meeting
        updated.audioFilePath = nil
        try save(updated)
    }

    func delete(_ meeting: Meeting) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [meeting.id.uuidString])
        }
        try loadAll()
    }

    // MARK: - Private helpers

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a":         return "audio/mp4"
        case "mp3":         return "audio/mpeg"
        case "aiff", "aif": return "audio/aiff"
        case "flac":        return "audio/flac"
        case "aac":         return "audio/aac"
        default:            return "audio/wav"
        }
    }

    private let iso8601 = ISO8601DateFormatter()

    private func loadAll() throws {
        let rows = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM meetings ORDER BY recorded_at DESC")
        }
        meetings = rows.compactMap { row in
            guard
                let idStr = row["id"] as? String,
                let id = UUID(uuidString: idStr),
                let title = row["title"] as? String,
                let recordedAtStr = row["recorded_at"] as? String,
                let recordedAt = iso8601.date(from: recordedAtStr),
                let createdAtStr = row["created_at"] as? String,
                let createdAt = iso8601.date(from: createdAtStr)
            else { return nil }

            _ = createdAt
            return Meeting(
                id: id,
                title: title,
                recordedAt: recordedAt,
                durationSeconds: row["duration_seconds"] as? Int,
                transcript: row["transcript"] as? String,
                summary: row["summary"] as? String,
                decisions: decodeJSON([String].self, from: row["decisions"] as? String) ?? [],
                actionItems: decodeJSON([ActionItem].self, from: row["action_items"] as? String) ?? [],
                audioFilePath: row["audio_file_path"] as? String
            )
        }
    }

    private func encodeJSON<T: Encodable>(_ value: T) -> String? {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from string: String?) -> T? {
        guard let str = string, let data = str.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
