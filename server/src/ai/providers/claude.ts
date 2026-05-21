import Anthropic from "@anthropic-ai/sdk"
import { AIProvider, MeetingResult, parseAIResponse } from "../client"
import { PROCESS_MEETING_PROMPT } from "../prompts"

export class ClaudeProvider implements AIProvider {
  private client: Anthropic

  constructor() {
    const apiKey = process.env.ANTHROPIC_API_KEY
    if (!apiKey) throw new Error("ANTHROPIC_API_KEY is not set")
    this.client = new Anthropic({ apiKey })
  }

  async process(audioBuffer: Buffer, mimeType: string): Promise<MeetingResult> {
    const audioBase64 = audioBuffer.toString("base64")
    const response = await this.client.messages.create({
      model: process.env.CLAUDE_MODEL ?? "claude-sonnet-4-6",
      max_tokens: parseInt(process.env.CLAUDE_MAX_TOKENS ?? "4096", 10),
      messages: [
        {
          role: "user",
          content: [
            {
              type: "document",
              source: {
                type: "base64",
                media_type: mimeType as "audio/wav" | "audio/mpeg" | "audio/mp4" | "audio/ogg",
                data: audioBase64,
              },
            } as unknown as Anthropic.TextBlockParam,
            {
              type: "text",
              text: PROCESS_MEETING_PROMPT,
            },
          ],
        },
      ],
    })

    const textBlock = response.content.find((b) => b.type === "text")
    if (!textBlock || textBlock.type !== "text") {
      throw new Error("No text response from Claude")
    }

    return parseAIResponse(textBlock.text)
  }
}
