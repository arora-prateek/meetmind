import SwiftUI

struct SettingsView: View {
    @AppStorage("backendURL") private var backendURL = "http://localhost:8080"
    @State private var testStatus: TestStatus = .idle

    enum TestStatus { case idle, testing, ok, failed(String) }

    var body: some View {
        Form {
            Section("Backend") {
                TextField("URL", text: $backendURL)
                    .onChange(of: backendURL) { _ in testStatus = .idle }

                HStack {
                    Button("Test Connection") { Task { await testConnection() } }
                    switch testStatus {
                    case .idle:    EmptyView()
                    case .testing: ProgressView()
                    case .ok:
                        Label("Reachable", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    case .failed(let msg):
                        Label(msg, systemImage: "xmark.circle.fill")
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .padding()
    }

    private func testConnection() async {
        testStatus = .testing
        do {
            let ok = try await BackendClient.shared.checkHealth()
            testStatus = ok ? .ok : .failed("Not reachable")
        } catch {
            testStatus = .failed("Not reachable")
        }
    }
}
