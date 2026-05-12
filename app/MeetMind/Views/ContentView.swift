import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var store = MeetingStore.shared
    @State private var selectedMeeting: Meeting?

    var body: some View {
        NavigationSplitView {
            MeetingListView(selectedMeeting: $selectedMeeting)
                .environmentObject(store)
        } detail: {
            if let meeting = selectedMeeting {
                MeetingDetailView(meeting: meeting, onBack: { selectedMeeting = nil })
                .environmentObject(store)
            } else {
                RecordingView(onComplete: { meeting in
                    selectedMeeting = meeting
                })
                .environmentObject(store)
            }
        }
        .overlay(alignment: .bottom) {
            if appState.backendReachable == false {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text("Backend not reachable. Start it with: ")
                        .foregroundColor(.white)
                    Text("docker compose up -d")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.yellow)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.black.opacity(0.85))
                .cornerRadius(8)
                .padding(.bottom, 12)
            }
        }
    }
}
