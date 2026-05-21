import Foundation

enum Config {
    /// Base URL of the MeetMind backend.
    /// To point at another machine on the network, change this constant and rebuild.
    static let backendURL = "http://localhost:8080"

    // M4A transcoding — 16 kHz mono at 32 kbps is sufficient for speech recognition
    static let audioSampleRate = 16_000   // Hz — 16 kHz
    static let audioBitRate    = 32_000   // bps — 32 kbps

    // HTTP timeouts (seconds)
    static let healthCheckTimeout: TimeInterval = 5      // 5 s
    static let processTimeout: TimeInterval     = 300    // 5 * 60 — 5 minutes
}
