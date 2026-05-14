import Foundation

enum BackendError: Error, LocalizedError {
    case unreachable
    case invalidResponse
    case serverError(String, String)
    case decodingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .unreachable:
            return "Backend not reachable. Start it with: docker compose up -d"
        case .invalidResponse:
            return "Invalid response from server."
        case .serverError(let msg, _):
            return msg
        case .decodingFailed(let err):
            return "Failed to decode response: \(err.localizedDescription)"
        }
    }
}

class BackendClient {
    static let shared = BackendClient()

    private var baseURL: String {
        UserDefaults.standard.string(forKey: "backendURL") ?? "http://localhost:8080"
    }

    private init() {}

    func checkHealth() async throws -> Bool {
        guard let url = URL(string: "\(baseURL)/health") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            throw BackendError.unreachable
        }
    }

    func processMeeting(audio: Data, mimeType: String = "audio/wav", title: String, recordedAt: Date) async throws -> MeetingResult {
        guard let url = URL(string: "\(baseURL)/process") else {
            throw BackendError.unreachable
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let iso8601 = ISO8601DateFormatter()
        let recordedAtStr = iso8601.string(from: recordedAt)

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        func appendFile(_ name: String, _ filename: String, _ mime: String, _ data: Data) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
        }

        appendField("meetingTitle", title)
        appendField("recordedAt", recordedAtStr)
        appendFile("audio", "recording.wav", mimeType, audio)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw BackendError.unreachable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            if let errBody = try? JSONDecoder().decode([String: String].self, from: data) {
                throw BackendError.serverError(
                    errBody["error"] ?? "Server error",
                    errBody["code"] ?? "UNKNOWN"
                )
            }
            throw BackendError.invalidResponse
        }

        do {
            return try JSONDecoder().decode(MeetingResult.self, from: data)
        } catch {
            throw BackendError.decodingFailed(error)
        }
    }
}
