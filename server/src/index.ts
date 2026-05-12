import express from "express"
import { logger } from "./utils/logger"
import processRouter from "./routes/process"

const app = express()
const PORT = parseInt(process.env.PORT ?? "8080", 10)

app.use(express.json())

app.get("/health", (_req, res) => {
  res.json({ status: "ok", version: "0.1.0" })
})

app.use("/process", processRouter)

app.listen(PORT, () => {
  logger.info(`MeetMind server running on port ${PORT}`)
  logger.info(`AI provider: ${process.env.AI_PROVIDER ?? "gemini"}`)
})
