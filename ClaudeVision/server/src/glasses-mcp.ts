import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import dotenv from "dotenv";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

// When launched from Codex or Claude Code, cwd is not guaranteed to be the
// Gateway directory. Load only the private Gateway .env next to this package.
const envPath = resolve(dirname(fileURLToPath(import.meta.url)), "..", ".env");
dotenv.config({ path: envPath });

const gatewayKey = process.env.GATEWAY_API_KEY;
const gatewayHost = process.env.GATEWAY_HOST || "127.0.0.1";
const gatewayPort = Number(process.env.PORT || 18790);
if (!gatewayKey) throw new Error("GATEWAY_API_KEY is missing from the Gateway .env");
if (!Number.isInteger(gatewayPort) || gatewayPort < 1 || gatewayPort > 65535) {
  throw new Error("Gateway PORT is invalid");
}

const urlHost = gatewayHost.includes(":") && !gatewayHost.startsWith("[") ? `[${gatewayHost}]` : gatewayHost;
const gatewayUrl = `http://${urlHost}:${gatewayPort}`;
const requestTimeoutMs = 9_000;

async function gatewayFetch(path: string, init?: RequestInit): Promise<Response> {
  return fetch(new URL(path, gatewayUrl), {
    ...init,
    redirect: "error",
    signal: AbortSignal.timeout(requestTimeoutMs),
    headers: { "X-Gateway-Key": gatewayKey!, ...init?.headers },
  });
}

const server = new McpServer({ name: "meta-glasses", version: "1.0.0" });

server.registerTool(
  "glasses_status",
  {
    description: "Check whether a fresh frame is arriving from the connected Meta Ray-Ban camera.",
    inputSchema: {},
  },
  async () => {
    const response = await gatewayFetch("/glasses/status");
    if (!response.ok) throw new Error(`Glasses gateway returned HTTP ${response.status}`);
    const status = await response.json();
    return { content: [{ type: "text", text: JSON.stringify(status) }] };
  }
);

server.registerTool(
  "get_glasses_frame",
  {
    description: "Wait for and return the next fresh JPEG frame from the connected Meta Ray-Ban glasses camera. Waits up to 8 seconds; does not return a stale cached frame.",
    inputSchema: {
      wait_ms: z.number().int().min(0).max(8_000).optional().describe("Maximum wait for a new frame, default 8000 ms"),
    },
  },
  async ({ wait_ms }) => {
    const invokedAt = Date.now();
    const wait = wait_ms ?? 8_000;
    const query = new URLSearchParams({ after: String(invokedAt), wait_ms: String(wait) });
    const response = await gatewayFetch(`/glasses/frame?${query}`);
    if (response.status === 204) {
      return { content: [{ type: "text", text: "No fresh glasses frame arrived before the timeout. Check that the glasses stream is Connected and try again." }], isError: true };
    }
    if (!response.ok) throw new Error(`Glasses gateway returned HTTP ${response.status}`);
    if (response.headers.get("content-type") !== "image/jpeg") throw new Error("Gateway returned an unexpected frame type");

    const jpeg = Buffer.from(await response.arrayBuffer());
    if (jpeg.length < 4 || jpeg[0] !== 0xff || jpeg[1] !== 0xd8 || jpeg.at(-2) !== 0xff || jpeg.at(-1) !== 0xd9) {
      throw new Error("Gateway returned an invalid JPEG frame");
    }
    const receivedAt = Number(response.headers.get("x-frame-received-at"));
    if (!Number.isFinite(receivedAt) || receivedAt <= invokedAt || Date.now() - receivedAt > 3_000) {
      throw new Error("Gateway frame is stale; request a fresh frame again");
    }
    const metadata = {
      source: "rayban",
      streamId: response.headers.get("x-glasses-stream-id"),
      sequence: Number(response.headers.get("x-frame-sequence")),
      capturedAt: new Date(receivedAt).toISOString(),
      ageMs: Date.now() - receivedAt,
    };
    return {
      content: [
        { type: "text", text: JSON.stringify(metadata) },
        { type: "image", data: jpeg.toString("base64"), mimeType: "image/jpeg" },
      ],
    };
  }
);

const transport = new StdioServerTransport();
await server.connect(transport);
