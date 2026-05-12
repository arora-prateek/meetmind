import Foundation
import SwiftUI

@MainActor
class AppState: ObservableObject {
    @Published var backendReachable: Bool? = nil

    func checkBackend() async {
        do {
            backendReachable = try await BackendClient.shared.checkHealth()
        } catch {
            backendReachable = false
        }
    }
}
