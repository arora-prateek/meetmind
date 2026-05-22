import { GoogleGenerativeAI, GoogleGenerativeAIFetchError } from "@google/generative-ai"
import { GoogleAIFileManager } from "@google/generative-ai/server"
import { AIProvider, MeetingResult, parseAIResponse } from "../client"
import { PROCESS_MEETING_PROMPT } from "../prompts"
import { logger } from "../../utils/logger"
import * as fs from "fs"
import * as os from "os"
import * as path from "path"

const INLINE_BYTE_LIMIT = parseInt(process.env.GEMINI_INLINE_LIMIT_MB ?? "20", 10) * 1024 * 1024
const REQUEST_TIMEOUT_MS = parseInt(process.env.GEMINI_REQUEST_TIMEOUT_MS ?? "600000", 10)
const MAX_ATTEMPTS = 3
const RETRY_NETWORK_CODES = new Set(["ECONNRESET", "ETIMEDOUT", "ECONNREFUSED"])

function isRetryable(err: unknown): boolean {
  if (err instanceof SyntaxError) return true
  if (err instanceof GoogleGenerativeAIFetchError) return err.status === 503 || err.status === 429
  if (err instanceof Error && "code" in err) return RETRY_NETWORK_CODES.has((err as NodeJS.ErrnoException).code ?? "")
  return false
}

function errorLabel(err: unknown): string {
  if (err instanceof SyntaxError) return "SyntaxError — truncated JSON"
  if (err instanceof GoogleGenerativeAIFetchError) return `${err.status} ${err.statusText}`
  if (err instanceof Error) return err.message
  return String(err)
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms))
}

export class GeminiProvider implements AIProvider {
  private client: GoogleGenerativeAI
  private fileManager: GoogleAIFileManager

  constructor() {
    const apiKey = process.env.GEMINI_API_KEY
    if (!apiKey) throw new Error("GEMINI_API_KEY is not set")
    this.client = new GoogleGenerativeAI(apiKey)
    this.fileManager = new GoogleAIFileManager(apiKey, { timeout: REQUEST_TIMEOUT_MS })
  }

  async process(audioBuffer: Buffer, mimeType: string): Promise<MeetingResult> {
    const model = this.client.getGenerativeModel(
      { model: process.env.GEMINI_MODEL ?? "gemini-2.0-flash" },
      { timeout: REQUEST_TIMEOUT_MS }
    )

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
      for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
        try {
          const result = await model.generateContent({
            contents: [{ role: "user", parts: [audioPart, { text: PROCESS_MEETING_PROMPT }] }],
            ...(attempt > 0 && { generationConfig: { maxOutputTokens: 32768 } }),
          })
          return parseAIResponse(result.response.text())
        } catch (err) {
          if (!isRetryable(err) || attempt === MAX_ATTEMPTS - 1) throw err
          const delay = Math.min(1000 * 2 ** attempt, 30_000) + Math.random() * 1000
          logger.warn(`Gemini attempt ${attempt + 1} failed (${errorLabel(err)}). Retrying in ${(delay / 1000).toFixed(1)}s...`)
          await sleep(delay)
        }
      }
      throw new Error("Unreachable")
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
