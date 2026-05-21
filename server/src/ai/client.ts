import { GeminiProvider } from "./providers/gemini"
import { ClaudeProvider } from "./providers/claude"

export interface MeetingResult {
  transcript: string
  summary: string
  decisions: string[]
  actionItems: ActionItem[]
}

export interface ActionItem {
  description: string
  owner: string | null
  dueDate: string | null
  mentionedAt: string | null
}

export interface AIProvider {
  process(audioBuffer: Buffer, mimeType: string): Promise<MeetingResult>
}

export function parseAIResponse(raw: string): MeetingResult {
  // Strip markdown code fences the model sometimes adds despite instructions
  let text = raw.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "").trim()

  // Fast path — well-formed JSON
  try {
    return JSON.parse(text) as MeetingResult
  } catch (e) {
    if (!(e instanceof SyntaxError)) throw e
  }

  // Slow path — sanitize bare control characters inside string literals.
  // Scan character-by-character; track whether we're inside a JSON string
  // so structural whitespace outside strings is left untouched.
  const escapes: Record<string, string> = {
    "\n": "\\n", "\r": "\\r", "\t": "\\t", "\f": "\\f", "\b": "\\b",
  }
  let sanitized = ""
  let inString = false
  let i = 0
  while (i < text.length) {
    const ch = text[i]
    if (inString) {
      if (ch === "\\") {
        // Escaped character — copy both chars verbatim
        sanitized += ch + (text[i + 1] ?? "")
        i += 2
        continue
      }
      if (ch === '"') {
        inString = false
        sanitized += ch
      } else if (ch.charCodeAt(0) < 0x20) {
        sanitized += escapes[ch] ?? `\\u${ch.charCodeAt(0).toString(16).padStart(4, "0")}`
      } else {
        sanitized += ch
      }
    } else {
      if (ch === '"') inString = true
      sanitized += ch
    }
    i++
  }

  return JSON.parse(sanitized) as MeetingResult
}

export class AIClient {
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

  async process(audioBuffer: Buffer, mimeType: string): Promise<MeetingResult> {
    return this.provider.process(audioBuffer, mimeType)
  }
}
