import { GoogleGenerativeAI } from "@google/generative-ai"
import { GoogleAIFileManager } from "@google/generative-ai/server"
import { AIProvider, MeetingResult, parseAIResponse } from "../client"
import { PROCESS_MEETING_PROMPT } from "../prompts"
import * as fs from "fs"
import * as os from "os"
import * as path from "path"

// Gemini inline data limit is ~20 MB of raw bytes; use Files API above this
const INLINE_BYTE_LIMIT = 20 * 1024 * 1024

export class GeminiProvider implements AIProvider {
  private client: GoogleGenerativeAI
  private fileManager: GoogleAIFileManager

  constructor() {
    const apiKey = process.env.GEMINI_API_KEY
    if (!apiKey) throw new Error("GEMINI_API_KEY is not set")
    this.client = new GoogleGenerativeAI(apiKey)
    // Large file uploads (e.g. 500MB+ WAVs) can take several minutes — set a 10-minute timeout
    this.fileManager = new GoogleAIFileManager(apiKey, { timeout: 10 * 60 * 1000 })
  }

  async process(audioBuffer: Buffer, mimeType: string): Promise<MeetingResult> {
    const model = this.client.getGenerativeModel({
      model: process.env.GEMINI_MODEL ?? "gemini-2.0-flash",
    })

    let uploadedFileName: string | undefined
    let audioPart: any

    if (audioBuffer.length > INLINE_BYTE_LIMIT) {
      const { part, fileName } = await this.uploadViaFilesApi(audioBuffer, mimeType)
      audioPart = part
      uploadedFileName = fileName
    } else {
      audioPart = { inlineData: { mimeType, data: audioBuffer.toString("base64") } }
    }

    try {
      const result = await model.generateContent([audioPart, PROCESS_MEETING_PROMPT])
      return parseAIResponse(result.response.text())
    } finally {
      if (uploadedFileName) {
        try { await this.fileManager.deleteFile(uploadedFileName) } catch {}
      }
    }
  }

  private async uploadViaFilesApi(
    audioBytes: Buffer,
    mimeType: string
  ): Promise<{ part: any; fileName: string }> {
    const ext = mimeType.includes("wav") ? ".wav" : ".m4a"
    const tmpPath = path.join(os.tmpdir(), `meetmind-${Date.now()}${ext}`)

    try {
      fs.writeFileSync(tmpPath, audioBytes)

      const upload = await this.fileManager.uploadFile(tmpPath, {
        mimeType,
        displayName: `meetmind-${Date.now()}`,
      })

      // Poll until the file is active (usually immediate for audio)
      let file = upload.file
      while (file.state === "PROCESSING") {
        await new Promise((r) => setTimeout(r, 2000))
        file = await this.fileManager.getFile(file.name)
      }

      if (file.state !== "ACTIVE") {
        throw new Error(`Gemini file upload failed with state: ${file.state}`)
      }

      return {
        part: { fileData: { mimeType: file.mimeType, fileUri: file.uri } },
        fileName: file.name,
      }
    } finally {
      try { fs.unlinkSync(tmpPath) } catch {}
    }
  }
}
