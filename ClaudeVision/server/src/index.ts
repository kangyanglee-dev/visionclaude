import "dotenv/config";
import express from "express";
import cors from "cors";
import { MCPManager } from "./mcp-manager.js";
import { ClaudeClient } from "./claude-client.js";
import { ConversationStore } from "./conversation.js";
import { SkillLoader } from "./skill-loader.js";
import { gatewayAuth, rateLimiter, RequestQueue } from "./middleware.js";
import { showBanner, showServerInfo, c } from "./console-theme.js";
import { createChatRouter } from "./routes/chat.js";
import { createHealthRouter } from "./routes/health.js";
import { createConfigRouter } from "./routes/config.js";
import { createToolsRouter } from "./routes/tools.js";
import { createGlassesRouter, createGlassesUploadRouter } from "./routes/glasses.js";
import type { ServerConfig } from "./types.js";
import { isIP } from "net";

const PORT = parseInt(process.env.PORT || "18790", 10);
const GATEWAY_HOST = process.env.GATEWAY_HOST || "127.0.0.1";
const TRIAL_SAFE_MODE = process.env.VISIONCLAUDE_TRIAL_SAFE_MODE !== "0";

const canonicalIPv6Host = isIP(GATEWAY_HOST) === 6
  ? new URL(`http://[${GATEWAY_HOST}]/`).hostname.toLowerCase()
  : "";
const isWildcardHost = GATEWAY_HOST === "0.0.0.0"
  || canonicalIPv6Host === "[::]"
  || canonicalIPv6Host === "[::ffff:0.0.0.0]";

if (!isIP(GATEWAY_HOST) || isWildcardHost) {
  throw new Error("GATEWAY_HOST must be a specific IPv4 or IPv6 address; wildcard binds are disabled");
}

const DEFAULT_SYSTEM_PROMPT = `You are an OpenAI vision assistant seeing the world through the user's camera (iPhone or Meta Ray-Ban smart glasses) in real-time.

VISION ANALYSIS:
- You receive a live camera frame with each message. ALWAYS analyze the image carefully before responding.
- Describe what you ACTUALLY see — objects, people, text, screens, environments, colors, brands, labels.
- If you see text (signs, screens, labels, books), read it exactly.
- If you see a product, identify it specifically (brand, model, color).
- If you see a person, describe what they're doing, not who they are.
- If you see a scene/environment, describe the setting, lighting, and notable elements.
- NEVER guess or hallucinate. If you can't make something out clearly, say so.
- Be specific and accurate. "I see a silver MacBook Pro on a wooden desk" not "I see a laptop on a table."

RESPONSE STYLE:
- Keep responses concise (1-3 sentences for simple questions, more for detailed analysis).
- Speak naturally as if having a conversation — the user hears your response via text-to-speech.
- Don't use markdown, bullet points, or formatting — your response is spoken aloud.
- Don't say "In the image I can see..." — just describe directly, like a friend would.

TOOLS:
- This isolated trial has no tools. Explain what the user can do next, but do not claim to perform actions.`;

async function main() {
  // ── Show Banner ──
  showBanner();

  // ── Initialize MCP Manager ──
  const mcpManager = new MCPManager(TRIAL_SAFE_MODE);
  await mcpManager.initialize();

  // ── Initialize Skill Loader ──
  const skillLoader = new SkillLoader(undefined, TRIAL_SAFE_MODE);
  skillLoader.load();

  // ── Build system prompt with skills ──
  const systemPrompt = DEFAULT_SYSTEM_PROMPT + skillLoader.buildSystemPromptSection();

  // ── Server config ──
  const config: ServerConfig = {
    systemPrompt,
    model: process.env.OPENAI_MODEL || "gpt-4.1-mini",
    maxTokens: 4096,
  };

  // ── Initialize OpenAI-backed vision client ──
  const claudeClient = new ClaudeClient(mcpManager, config);

  // ── Conversation store ──
  const conversations = new ConversationStore();

  // ── Request queue (limits concurrent API calls) ──
  const requestQueue = new RequestQueue(2); // max 2 concurrent API calls

  // ── Express app ──
  const app = express();
  app.use(cors());

  // ── Security middleware ──
  app.use(gatewayAuth());
  // Camera uploads have a 1 MiB body cap and a bounded 2 req/sec limiter, so
  // they do not consume the general 30/min API quota.
  app.use("/glasses", createGlassesUploadRouter());
  app.use(rateLimiter(30));  // 30 requests per minute per IP
  app.use(express.json({ limit: "50mb" }));

  // ── Routes ──
  app.use("/chat", createChatRouter(claudeClient, conversations, requestQueue));
  app.use("/health", createHealthRouter(mcpManager, conversations, skillLoader));
  app.use("/config", createConfigRouter(claudeClient));
  app.use("/tools", createToolsRouter(mcpManager));
  app.use("/glasses", createGlassesRouter());

  // Skills endpoint
  app.get("/skills", (_req, res) => {
    res.json({
      skills: skillLoader.getSkillList(),
      count: skillLoader.count,
    });
  });

  // Skills reload endpoint
  app.post("/skills/reload", (_req, res) => {
    skillLoader.reload();
    // Update system prompt with new skills
    const newPrompt = DEFAULT_SYSTEM_PROMPT + skillLoader.buildSystemPromptSection();
    claudeClient.updateConfig({ systemPrompt: newPrompt });
    res.json({
      message: "Skills reloaded",
      skills: skillLoader.getSkillList(),
      count: skillLoader.count,
    });
  });

  // ── Start server ──
  const server = app.listen(PORT, GATEWAY_HOST, () => {
    const mcpServers = mcpManager.getServerNames();
    const toolCount = mcpManager.getToolsForClaude().length;
    showServerInfo(PORT, mcpServers.length, toolCount, skillLoader.count);
  });

  // ── Graceful shutdown ──
  const shutdown = async () => {
    console.log(c.orange("\n   ▸ Shutting down VisionClaude Gateway..."));
    conversations.destroy();
    await mcpManager.shutdown();
    server.close(() => {
      console.log(c.dim("   Gateway stopped.\n"));
      process.exit(0);
    });
  };

  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

main().catch((err) => {
  console.error(c.error("Fatal error:"), err);
  process.exit(1);
});
