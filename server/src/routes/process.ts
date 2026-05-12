import { Router, Request, Response } from "express"
import multer from "multer"
import { AIClient } from "../ai/client"
import { logger } from "../utils/logger"

const router = Router()
const upload = multer({ storage: multer.memoryStorage() })
const aiClient = new AIClient()

router.post("/", upload.single("audio"), async (req: Request, res: Response) => {
  const { meetingTitle, recordedAt } = req.body

  if (!req.file) {
    res.status(400).json({ error: "Audio file is required", code: "INVALID_INPUT" })
    return
  }

  if (!meetingTitle || !recordedAt) {
    res.status(400).json({ error: "meetingTitle and recordedAt are required", code: "INVALID_INPUT" })
    return
  }

  const audioBuffer = req.file.buffer
  const mimeType = req.file.mimetype || "audio/wav"

  logger.info(`Processing meeting: "${meetingTitle}" (${audioBuffer.length} bytes, ${mimeType})`)

  let audioBase64: string
  try {
    audioBase64 = audioBuffer.toString("base64")
  } catch (err) {
    logger.error("Failed to encode audio", err)
    res.status(500).json({ error: "Failed to encode audio", code: "PROCESSING_FAILED" })
    return
  }

  try {
    const result = await aiClient.process(audioBase64, mimeType)

    // Wipe audio from memory
    audioBuffer.fill(0)

    logger.info(`Meeting processed successfully: "${meetingTitle}"`)
    res.status(200).json(result)
  } catch (err) {
    logger.error("AI processing failed", err)
    res.status(500).json({ error: "AI processing failed", code: "AI_ERROR" })
  }
})

export default router
