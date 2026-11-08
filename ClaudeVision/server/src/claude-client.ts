import type { MCPManager } from "./mcp-manager.js";
import type {
  MessageParam,
  ServerConfig,
  ToolCallResult,
} from "./types.js";

const OPENAI_CHAT_COMPLETIONS_URL = "https://api.openai.com/v1/chat/completions";

type OpenAIContentPart =
  | { type: "text"; text: string }
  | { type: "image_url"; image_url: { url: string } };

type OpenAIMessage = {
  role: "system" | "user" | "assistant";
  content: string | OpenAIContentPart[];
};

function toOpenAIMessage(message: MessageParam): OpenAIMessage {
  if (typeof message.content === "string") {
    return { role: message.role, content: message.content };
  }

  const content: OpenAIContentPart[] = [];
  for (const block of message.content) {
    if (block.type === "text") {
      content.push({ type: "text", text: block.text });
    } else if (block.type === "image") {
      if (block.source.type === "base64") {
        content.push({
          type: "image_url",
          image_url: {
            url: `data:${block.source.media_type};base64,${block.source.data}`,
          },
        });
      }
    }
  }

  return { role: message.role, content };
}

export class ClaudeClient {
  private config: ServerConfig;

  constructor(_mcpManager: MCPManager, config: ServerConfig) {
    this.config = config;
  }

  updateConfig(updates: Partial<ServerConfig>): void {
    Object.assign(this.config, updates);
  }

  getConfig(): ServerConfig {
    return { ...this.config };
  }

  async chat(
    history: MessageParam[],
    text: string,
    images?: string[]
  ): Promise<{ responseText: string; toolCalls: ToolCallResult[] }> {
    const apiKey = process.env.OPENAI_API_KEY;
    if (!apiKey) {
      throw new Error("OPENAI_API_KEY is not configured");
    }

    const userContent: OpenAIContentPart[] = [];
    for (const base64 of images ?? []) {
      userContent.push({
        type: "image_url",
        image_url: { url: `data:image/jpeg;base64,${base64}` },
      });
    }
    if (text) userContent.push({ type: "text", text });

    const messages: OpenAIMessage[] = [
      { role: "system", content: this.config.systemPrompt },
      ...history.map(toOpenAIMessage),
      { role: "user", content: userContent },
    ];

    // The isolated trial intentionally does not expose MCP tools to the model.
    const response = await fetch(OPENAI_CHAT_COMPLETIONS_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: this.config.model,
        messages,
        max_tokens: this.config.maxTokens,
      }),
    });

    if (!response.ok) {
      const detail = await response.text();
      throw new Error(`OpenAI API request failed (${response.status}): ${detail}`);
    }

    const payload = (await response.json()) as {
      choices?: Array<{ message?: { content?: string | null } }>;
    };
    const responseText = payload.choices?.[0]?.message?.content;
    if (typeof responseText !== "string") {
      throw new Error("OpenAI API response did not contain assistant text");
    }

    return { responseText, toolCalls: [] };
  }
}
