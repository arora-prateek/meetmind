# MeetMind — v0.1 Spec

## What This Is

A local-first meeting intelligence tool for macOS. It records system audio and microphone,
sends audio to a local backend for processing, and returns a transcript, summary, and action
items — all stored on the user's device. No cloud storage. No API key setup for the user.

This spec covers v0.1: a single-developer test build running entirely on one machine via Docker.

---

## System Architecture

```
+---------------------------------------------+
|  macOS                                       |
|                                              |
|  +------------------+                        |
|  |  MeetMind.app    |  Swift + SwiftUI        |
|  |                  |                        |
|  |  - Record audio  |                        |
|  |  - Show meetings |                        |
|  |  - Show summary  |                        |
|  +--------+---------+                        |
|           | HTTP (localhost:8080)             |
|  +--------v---------+                        |
|  |  Docker Container|  Node.js + TypeScript  |
|  |                  |                        |
|  |  - Receive audio |                        |
|  |  - Call AI API   |                        |
|  |  - Return result |                        |
|  |  - Delete audio  |                        |
|  +--------+---------+                        |
|           | HTTPS                            |
+-----------+-------------------------------------+
            |
   Google Gemini API  <-- default (free tier)
   Anthropic Claude API  <-- production (one .env change)
```

The app always talks to `localhost:8080` by default. When installed on another device
on the same network, the user points the app to the host machine's local IP
(e.g. `192.168.1.x:8080`). This is a config constant in the app — not hardcoded deeper.

---

## Repository Structure

```
meetmind/
├── CLAUDE.md
├── docker-compose.yml          # Single command to start the backend
├── .env.example                # Template — all env vars with comments
├── app/                        # Swift macOS app
│   ├── MeetMind.xcodeproj
│   └── MeetMind/
│       ├── App/
│       │   ├── MeetMindApp.swift       # App entry point
│       │   └── AppState.swift          # Global observed state
│       ├── Capture/
│       │   └── AudioRecorder.swift     # ScreenCaptureKit recording
│       ├── API/
│       │   └── BackendClient.swift     # All HTTP calls to backend
│       ├── Storage/
│       │   └── MeetingStore.swift      # Local SQLite via GRDB
│       ├── Models/
│       │   └── Meeting.swift           # Meeting, Summary, ActionItem structs
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
        ├── index.ts            # Express server entry point
        ├── routes/
        │   └── process.ts      # POST /process endpoint
        ├── ai/
        │   ├── client.ts       # THE ONLY place AI is called — see AI Abstraction below
        │   ├── providers/
        │   │   ├── gemini.ts   # Gemini implementation (default, free tier)
        │   │   └── claude.ts   # Claude implementation (production)
        │   └── prompts.ts      # All prompt strings — nowhere else
        └── utils/
            └── logger.ts
```

---

## CRITICAL: AI Abstraction Rule

**Every AI call in the entire backend MUST go through `server/src/ai/client.ts`.**
Direct use of any AI SDK anywhere else is forbidden.
Swapping providers requires changing ONE value in `.env` — nothing else.

```typescript
// server/src/ai/client.ts

interface AIProvider {
  process(audioBase64: string, mimeType: string): Promise<MeetingResult>
}

interface MeetingResult {
  transcript: string
  summary: string
  decisions: string[]
  actionItems: ActionItem[]
}

interface ActionItem {
  description: string
  owner: string | null
  dueDate: string | null      // YYYY-MM-DD or null
  mentionedAt: string | null  // HH:MM:SS or null
}

class AIClient {
  private provider: AIProvider

  constructor() {
    const name = process.env.AI_PROVIDER ?? "gemini"
    if (name === "gemini") {
      this.provider = new GeminiProvider()
    } else if (name === "claude") {
      this.provider = new ClaudeProvider()
    } else {
      throw new Error(`Unknown AI provider: ${name}`)
    }
  }

  async process(audioBase64: string, mimeType: string): Promise<MeetingResult> {
    return this.provider.process(audioBase64, mimeType)
  }
}
```

Adding a new provider in future: create `server/src/ai/providers/openai.ts`,
add one `else if` in `AIClient`, change `.env`. Nothing else in the codebase changes.

---

## Environment Variables

```bash
# .env — never committed to version control

# ---- Active provider ----
# Change this one value to swap AI providers. Nothing else changes.
# "gemini" = free tier for development
# "claude" = production
AI_PROVIDER=gemini

# ---- Gemini (default — free tier) ----
# Get your free API key at https://aistudio.google.com
GEMINI_API_KEY=
GEMINI_MODEL=gemini-2.0-flash

# ---- Claude (production) ----
# Get your API key at https://console.anthropic.com
ANTHROPIC_API_KEY=
CLAUDE_MODEL=claude-sonnet-4-6

# ---- Server ----
PORT=8080
```

`.env.example` ships with the repo with empty values and the comments above.
The Swift app has no `.env` — backend URL lives in `Config.swift` as a single constant.

---

## Backend (`server/`)

### Stack
- Node.js 20 + TypeScript
- Express
- `@google/generative-ai` (Gemini SDK)
- `@anthropic-ai/sdk` (Claude SDK)
- Runs in Docker via `docker-compose.yml`

### `POST /process`

**Request:** `multipart/form-data`
- `audio` — audio file (WAV or M4A)
- `meetingTitle` — string
- `recordedAt` — ISO 8601 timestamp

**Processing (in order):**
1. Receive audio into memory — never write to disk
2. Base64 encode
3. Pass to `AIClient.process()` — single API call handles transcription + summarisation
4. Parse structured JSON response
5. Wipe audio from memory
6. Return `MeetingResult` as JSON

**Success response `200`:**
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

**Error response `4xx/5xx`:**
```json
{
  "error": "human readable message",
  "code": "INVALID_INPUT | AI_ERROR | PROCESSING_FAILED"
}
```

### `GET /health`
Returns `{ "status": "ok", "version": "0.1.0" }`.
Used by the Swift app on launch to verify the backend is reachable.

---

## Backend: Gemini Provider (`server/src/ai/providers/gemini.ts`)

Default provider. Free tier. Used for all development and testing.

Single responsibility: receive audio, return `MeetingResult`.

Uses `@google/generative-ai` SDK to send a single request containing:
- The audio file as an inline base64 part with correct mimeType
- `PROCESS_MEETING_PROMPT` from `prompts.ts`

Model and API key come from environment variables only — never hardcoded.

```typescript
import { GoogleGenerativeAI } from "@google/generative-ai"

class GeminiProvider implements AIProvider {
  private client: GoogleGenerativeAI

  constructor() {
    this.client = new GoogleGenerativeAI(process.env.GEMINI_API_KEY!)
  }

  async process(audioBase64: string, mimeType: string): Promise<MeetingResult> {
    const model = this.client.getGenerativeModel({
      model: process.env.GEMINI_MODEL ?? "gemini-2.0-flash"
    })

    const result = await model.generateContent([
      {
        inlineData: {
          mimeType,
          data: audioBase64
        }
      },
      PROCESS_MEETING_PROMPT
    ])

    const text = result.response.text()
    return JSON.parse(text) as MeetingResult
  }
}
```

---

## Backend: Claude Provider (`server/src/ai/providers/claude.ts`)

Production provider. Activated by setting `AI_PROVIDER=claude` in `.env`.

Single responsibility: receive audio, return `MeetingResult`.

Uses `@anthropic-ai/sdk` to send a single message containing:
- The audio file as a base64 document block
- `PROCESS_MEETING_PROMPT` from `prompts.ts` as the text block

Model and API key come from environment variables only — never hardcoded.

---

## Backend: Prompts (`server/src/ai/prompts.ts`)

All prompt strings are constants defined here. No prompt strings anywhere else in the codebase.
Both providers use the same `PROCESS_MEETING_PROMPT` — the output schema is identical.

`PROCESS_MEETING_PROMPT` must instruct the model to:
- Transcribe the full audio, preserving language as spoken (English / Hindi / Arabic / mixed)
- Identify distinct speakers as Speaker 1, Speaker 2, etc. where distinguishable
- Return a single valid JSON object matching the `MeetingResult` schema exactly
- Extract action items with owner name and due date where explicitly mentioned
- List key decisions made during the meeting
- Return ONLY raw JSON — no markdown fences, no preamble, no explanation

The prompt must include the full target JSON schema so the model knows the exact output shape.

---

## macOS App (`app/`)

### Stack
- Swift 5.9+
- SwiftUI
- ScreenCaptureKit (audio capture)
- GRDB (SQLite wrapper for Swift)
- URLSession (HTTP)
- Minimum deployment: macOS 13 Ventura

### `AudioRecorder.swift`
- ScreenCaptureKit captures system audio output + microphone simultaneously
- Screen Recording permission: macOS prompts the user automatically on first launch
- `start()` begins capture
- `stop()` ends capture and returns audio as `Data`
- Audio format: M4A preferred, WAV fallback
- No real-time processing — capture only, hand off to backend

### `BackendClient.swift`
All HTTP calls to the backend live here. No networking code anywhere else in the app.

```swift
class BackendClient {
  private let baseURL: String  // from Config.swift

  func checkHealth() async throws -> Bool
  func processMeeting(audio: Data, title: String, recordedAt: Date) async throws -> MeetingResult
}
```

`baseURL` defaults to `http://localhost:8080`.
To point at another machine: change the constant in `Config.swift` and rebuild.
A settings screen to expose this can be added in a future version.

### `MeetingStore.swift`
GRDB-backed SQLite database. All meeting data stored locally on the user's device.

```sql
CREATE TABLE meetings (
  id           TEXT PRIMARY KEY,   -- UUID string
  title        TEXT NOT NULL,
  recorded_at  TEXT NOT NULL,      -- ISO 8601
  duration_seconds INTEGER,
  transcript   TEXT,
  summary      TEXT,
  decisions    TEXT,               -- JSON array stored as string
  action_items TEXT,               -- JSON array stored as string
  created_at   TEXT NOT NULL       -- ISO 8601
);
```

### `Meeting.swift`
Plain Swift structs. `Codable` for JSON. `Identifiable` for SwiftUI lists.

```swift
struct Meeting: Identifiable, Codable {
  let id: UUID
  var title: String
  var recordedAt: Date
  var durationSeconds: Int?
  var transcript: String?
  var summary: String?
  var decisions: [String]
  var actionItems: [ActionItem]
}

struct ActionItem: Codable {
  var description: String
  var owner: String?
  var dueDate: String?
  var mentionedAt: String?
}
```

---

## UI Views

### `RecordingView`
- Large record button: red while recording, grey when idle
- Status text: "Ready" / "Recording..." / "Processing..." / "Done"
- Optional title input field — defaults to `"Meeting — {date}"` if left empty
- Live recording duration timer
- On stop: sends audio to backend, shows spinner, navigates to detail view on success
- On error: shows inline error message with retry option

### `MeetingListView`
- Chronological list of all past meetings
- Each row shows: title, date, duration
- Tap to open `MeetingDetailView`
- Empty state message if no meetings yet

### `MeetingDetailView`
- Title and date at top
- Summary section
- Decisions section (bulleted list)
- Action Items section — each item shows description, owner, due date
- Transcript section — collapsed by default, tap to expand
- All read-only in v0.1

---

## Data Flow

```
User taps Record
      |
AudioRecorder.start()
      |
User taps Stop
      |
AudioRecorder.stop() --> audio: Data
      |
BackendClient.processMeeting(audio, title, recordedAt)
      |  multipart POST /process
Server receives audio in memory
      |
AIClient.process(audioBase64, mimeType)
      |
GeminiProvider (or ClaudeProvider) --> single API call
      |
Parse MeetingResult JSON from response
      |
Wipe audio from memory
      |  JSON 200
BackendClient returns MeetingResult
      |
MeetingStore.save(meeting) --> local SQLite
      |
Navigate to MeetingDetailView
```

---

## Docker (`docker-compose.yml`)

```yaml
version: "3.9"
services:
  server:
    build: ./server
    ports:
      - "8080:8080"
    env_file:
      - .env
    restart: unless-stopped
```

Start: `docker compose up -d`
Stop: `docker compose down`

The Swift app checks `/health` on launch. If it fails, display:
> "Backend not reachable. Start it with: docker compose up -d"

No other backend state is assumed by the app.

---

## Switching from Gemini to Claude

One change in `.env`:

```bash
# Before (development)
AI_PROVIDER=gemini

# After (production)
AI_PROVIDER=claude
```

Restart Docker: `docker compose down && docker compose up -d`

Nothing else changes. No code changes. No rebuild required.

---

## v0.1 Scope

### In Scope
- Audio capture via ScreenCaptureKit (system audio + mic)
- Send audio to local Docker backend
- Gemini processes audio -> transcript + summary + decisions + action items
- Results stored locally in SQLite
- View meetings, summaries, action items in SwiftUI
- Basic error handling: backend unreachable, AI API error, empty response

### Out of Scope for v0.1
- Auth / accounts
- Speaker renaming
- Any integrations (Calendar, Jira, Notion, Gmail)
- Screen / video capture
- Search or query across meetings
- Settings UI
- Onboarding flow
- Distribution / packaging / code signing

---

## Build Order

Build and verify each step before moving to the next.
Do not start on UI before the backend pipeline is confirmed working end-to-end.

1. **Backend `POST /process`** — verify with curl, get valid MeetingResult JSON back from Gemini
2. **`AudioRecorder.swift`** — confirm ScreenCaptureKit captures audio and returns valid `Data`
3. **`BackendClient.swift`** — wire the app's audio output to the backend
4. **`MeetingStore.swift`** — confirm save and fetch round-trip in SQLite
5. **`RecordingView`** — record -> upload -> wait -> confirm result saved -> show detail
6. **`MeetingListView` + `MeetingDetailView`** — display stored meetings

---

## Manual Test Checklist

- [ ] `docker compose up -d` starts without errors
- [ ] `GET /health` returns `{ "status": "ok" }`
- [ ] App launch shows backend as reachable
- [ ] Screen Recording permission dialog appears on first record attempt
- [ ] 5-minute recording produces a non-empty transcript
- [ ] Summary and action items are present in the response
- [ ] Meeting appears in list after processing
- [ ] Meeting data persists after quitting and relaunching the app
- [ ] App shows a clear error when Docker is not running
- [ ] Switching AI_PROVIDER from gemini to claude and restarting Docker works without code changes
