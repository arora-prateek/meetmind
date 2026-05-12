# MeetMind

A local-first meeting intelligence tool for macOS. Records your microphone, sends audio to a local backend for AI processing, and returns a transcript, summary, decisions, and action items — all stored on your device. No cloud storage. No API key setup for the end user.

---

## Architecture

```
MeetMind.app (Swift/SwiftUI)
        |
        | HTTP POST /process  (localhost:8080)
        v
Docker Container (Node.js/TypeScript)
        |
        | HTTPS
        v
Google Gemini API  (default, free tier)
Anthropic Claude API  (production, one .env change)
```

---

## Repository Structure

```
meetmind/
├── README.md
├── CLAUDE.md                   # Full project spec
├── docker-compose.yml
├── .env.example
├── app/                        # Swift macOS app
│   ├── MeetMind.xcodeproj
│   ├── project.yml             # xcodegen spec
│   └── MeetMind/
│       ├── App/
│       │   ├── MeetMindApp.swift
│       │   ├── AppState.swift
│       │   └── Config.swift    # Backend URL lives here
│       ├── Capture/
│       │   └── AudioRecorder.swift
│       ├── API/
│       │   └── BackendClient.swift
│       ├── Storage/
│       │   └── MeetingStore.swift
│       ├── Models/
│       │   └── Meeting.swift
│       └── Views/
│           ├── ContentView.swift
│           ├── RecordingView.swift
│           ├── MeetingListView.swift
│           └── MeetingDetailView.swift
└── server/                     # Node.js + TypeScript backend
    ├── Dockerfile
    ├── package.json
    ├── tsconfig.json
    └── src/
        ├── index.ts
        ├── routes/
        │   └── process.ts
        ├── ai/
        │   ├── client.ts       # Single entry point for all AI calls
        │   ├── providers/
        │   │   ├── gemini.ts
        │   │   └── claude.ts
        │   └── prompts.ts
        └── utils/
            └── logger.ts
```

---

## Prerequisites

- **macOS 13 Ventura or later**
- **Docker Desktop** — for running the backend
- **Xcode 15+** — for building the Swift app
- **xcodegen** — for generating the `.xcodeproj` from `project.yml`

```bash
brew install xcodegen
```

---

## Backend Setup

### 1. Configure environment variables

```bash
cp .env.example .env
```

Edit `.env` and add your API key:

```bash
# Default provider — free tier
AI_PROVIDER=gemini
GEMINI_API_KEY=your_key_here
GEMINI_MODEL=gemini-2.5-flash

# Production provider (optional)
ANTHROPIC_API_KEY=
CLAUDE_MODEL=claude-sonnet-4-6

PORT=8080
```

Get a free Gemini API key at [https://aistudio.google.com](https://aistudio.google.com).

### 2. Start the backend

```bash
docker compose up -d
```

### 3. Verify it's running

```bash
curl http://localhost:8080/health
# {"status":"ok","version":"0.1.0"}
```

---

## macOS App Setup

### 1. Generate the Xcode project

```bash
cd app
xcodegen generate
```

### 2. Configure the backend URL

Open `app/MeetMind/App/Config.swift` and set the backend URL:

```swift
enum Config {
    static let backendURL = "http://localhost:8080"
}
```

If running the backend on a different machine on the same network (e.g. your desktop while using the app on a laptop), change this to the host machine's local IP:

```swift
static let backendURL = "http://192.168.1.x:8080"
```

### 3. Build and run

Open `MeetMind.xcodeproj` in Xcode and run the app, or build from the command line:

```bash
xcodebuild -project MeetMind.xcodeproj \
           -scheme MeetMind \
           -configuration Release \
           -derivedDataPath build \
           CODE_SIGN_IDENTITY="" \
           CODE_SIGNING_REQUIRED=NO \
           CODE_SIGNING_ALLOWED=NO
```

### 4. Grant permissions

On first launch, macOS will prompt for:

- **Microphone** — required for recording
- **Accessibility** — required for detecting mute state in Teams

Both must be granted for full functionality. Grant them in **System Settings → Privacy & Security**.

---

## Using the App

1. Start the backend: `docker compose up -d`
2. Launch MeetMind
3. (Optional) Enter a meeting title
4. Press the record button — it turns red while active
5. The app auto-detects mute state from:
   - **System mic mute** (Core Audio)
   - **Zoom** (via osascript)
   - **Microsoft Teams** (via Accessibility API)
   - When muted in any of these, recording pauses automatically and the status shows the reason
6. Press stop — the app uploads the audio to the backend for processing
7. After processing, you are taken to the meeting detail view showing transcript, summary, decisions, and action items
8. All past meetings are accessible from the sidebar

---

## Switching AI Providers

To switch from Gemini to Claude, change one line in `.env`:

```bash
AI_PROVIDER=claude
ANTHROPIC_API_KEY=your_anthropic_key
```

Then restart the backend:

```bash
docker compose down && docker compose up -d
```

No code changes. No rebuild required.

---

## Backend API

### `POST /process`

Accepts `multipart/form-data`:

| Field | Type | Description |
|---|---|---|
| `audio` | file | WAV or M4A audio file |
| `meetingTitle` | string | Title of the meeting |
| `recordedAt` | string | ISO 8601 timestamp |

Returns `200` with:

```json
{
  "transcript": "string",
  "summary": "string",
  "decisions": ["string"],
  "actionItems": [
    {
      "description": "string",
      "owner": "string | null",
      "dueDate": "YYYY-MM-DD | null",
      "mentionedAt": "HH:MM:SS | null"
    }
  ]
}
```

### `GET /health`

Returns `{ "status": "ok", "version": "0.1.0" }`.

---

## Tech Stack

| Layer | Technology |
|---|---|
| macOS app | Swift 5.9+, SwiftUI |
| Audio capture | AVAudioEngine |
| Local storage | GRDB (SQLite) |
| Networking | URLSession |
| Backend | Node.js 20, TypeScript, Express |
| AI (default) | Google Gemini (`gemini-2.5-flash`) |
| AI (production) | Anthropic Claude (`claude-sonnet-4-6`) |
| Container | Docker, Docker Compose |

---

## Known Limitations (v0.1)

- **Microphone only** — system audio capture (e.g. remote participant audio) requires code signing and ScreenCaptureKit entitlement. Not included in v0.1.
- **Google Meet mute detection** — not supported. Meet runs in a browser and has no public API for detecting mute state without a browser extension.
- **No settings UI** — backend URL is a compile-time constant in `Config.swift`.
- **No auth** — designed for single-developer local use.

---

## Stopping the Backend

```bash
docker compose down
```
