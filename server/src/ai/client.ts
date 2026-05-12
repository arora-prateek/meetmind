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
  process(audioBase64: string, mimeType: string): Promise<MeetingResult>
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

  async process(audioBase64: string, mimeType: string): Promise<MeetingResult> {
    return this.provider.process(audioBase64, mimeType)
  }
}
