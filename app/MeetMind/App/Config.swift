import Foundation

enum Config {
    /// Base URL of the MeetMind backend.
    /// To point at another machine on the network, change this constant and rebuild.
    static let backendURL = "http://localhost:8080"

    // M4A transcoding — 16 kHz mono at 32 kbps is sufficient for speech recognition
    static let audioSampleRate = 16000
    static let audioBitRate    = 32000

    // HTTP timeouts (seconds)
    static let healthCheckTimeout: TimeInterval = 5
    static let processTimeout: TimeInterval     = 300
}
