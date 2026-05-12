import Foundation

struct Meeting: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var recordedAt: Date
    var durationSeconds: Int?
    var transcript: String?
    var summary: String?
    var decisions: [String]
    var actionItems: [ActionItem]
    var audioFilePath: String?
    var createdAt: Date

    init(id: UUID = UUID(), title: String, recordedAt: Date, durationSeconds: Int? = nil,
         transcript: String? = nil, summary: String? = nil,
         decisions: [String] = [], actionItems: [ActionItem] = [],
         audioFilePath: String? = nil) {
        self.id = id
        self.title = title
        self.recordedAt = recordedAt
        self.durationSeconds = durationSeconds
        self.transcript = transcript
        self.summary = summary
        self.decisions = decisions
        self.actionItems = actionItems
        self.audioFilePath = audioFilePath
        self.createdAt = Date()
    }
}

struct ActionItem: Codable, Hashable {
    var description: String
    var owner: String?
    var dueDate: String?
    var mentionedAt: String?
}

struct MeetingResult: Codable {
    let transcript: String
    let summary: String
    let decisions: [String]
    let actionItems: [ActionItem]
}

struct ProcessingJob: Identifiable {
    let id: UUID
    let title: String
    let audioFilePath: String   // relative filename, e.g. "<uuid>.wav"
    let recordedAt: Date
    let durationSeconds: Int
    var status: JobStatus

    enum JobStatus {
        case processing
        case failed(String)     // localizedDescription
    }
}
