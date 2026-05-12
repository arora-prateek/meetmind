import { GoogleGenerativeAI } from "@google/generative-ai"
import { AIProvider, MeetingResult } from "../client"
import { PROCESS_MEETING_PROMPT } from "../prompts"

export class GeminiProvider implements AIProvider {
  private client: GoogleGenerativeAI

  constructor() {
    const apiKey = process.env.GEMINI_API_KEY
    if (!apiKey) throw new Error("GEMINI_API_KEY is not set")
    this.client = new GoogleGenerativeAI(apiKey)
  }

  async process(audioBase64: string, mimeType: string): Promise<MeetingResult> {
    const model = this.client.getGenerativeModel({
      model: process.env.GEMINI_MODEL ?? "gemini-2.0-flash",
    })

    const result = await model.generateContent([
      {
        inlineData: {
          mimeType,
          data: audioBase64,
        },
      },
      PROCESS_MEETING_PROMPT,
    ])

    let text = result.response.text().trim()
    // Strip markdown code fences if the model ignores instructions
    text = text.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "")
    return JSON.parse(text) as MeetingResult
  }
}
