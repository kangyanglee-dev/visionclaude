import { Router } from "express";
import express from "express";
import { glassesFrameStore, glassesFrameTtlMs, glassesFrameMaxWaitMs } from "../glasses-frame-store.js";

const JPEG_MAX_BYTES = 1024 * 1024;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function addFrameUpload(router: Router) {
  const uploadRates = new Map<string, { startedAt: number; count: number }>();

  router.post("/frame", express.raw({ type: "image/jpeg", limit: JPEG_MAX_BYTES }), (req, res) => {
    const now = Date.now();
    const ip = req.ip || req.socket.remoteAddress || "unknown";
    let rate = uploadRates.get(ip);
    if (!rate || now - rate.startedAt >= 1_000) {
      if (uploadRates.size >= 256 && !uploadRates.has(ip)) {
        for (const [key, value] of uploadRates) {
          if (now - value.startedAt >= 1_000) uploadRates.delete(key);
        }
        if (uploadRates.size >= 256) uploadRates.delete(uploadRates.keys().next().value!);
      }
      rate = { startedAt: now, count: 0 };
      uploadRates.set(ip, rate);
    }
    rate.count++;
    if (rate.count > 2) {
      res.status(429).json({ error: "Frame upload rate exceeded" });
      return;
    }

    if (!Buffer.isBuffer(req.body)) {
      res.status(415).json({ error: "Content-Type must be image/jpeg" });
      return;
    }
    if (req.body.length < 4 || req.body[0] !== 0xff || req.body[1] !== 0xd8 || req.body.at(-2) !== 0xff || req.body.at(-1) !== 0xd9) {
      res.status(400).json({ error: "Invalid JPEG frame" });
      return;
    }

    const streamId = req.header("X-Glasses-Stream-Id") || "";
    const sequence = Number(req.header("X-Frame-Sequence"));
    if (!UUID_PATTERN.test(streamId) || !Number.isSafeInteger(sequence) || sequence < 0) {
      res.status(400).json({ error: "Valid stream id and frame sequence headers are required" });
      return;
    }

    try {
      glassesFrameStore.accept(streamId, sequence, req.body);
      res.status(202).json({ accepted: true, sequence });
    } catch (error) {
      res.status(409).json({ error: error instanceof Error ? error.message : "Frame rejected" });
    }
  });

  return router;
}

export function createGlassesUploadRouter() {
  return addFrameUpload(Router());
}

export function createGlassesRouter() {
  const router = Router();

  router.get("/status", (_req, res) => {
    res.json(glassesFrameStore.status());
  });

  router.get("/frame", async (req, res) => {
    const after = Number(req.query.after);
    const waitMs = req.query.wait_ms === undefined ? glassesFrameMaxWaitMs : Number(req.query.wait_ms);
    if (!Number.isFinite(after) || !Number.isFinite(waitMs) || waitMs < 0 || waitMs > glassesFrameMaxWaitMs) {
      res.status(400).json({ error: `after and wait_ms (0-${glassesFrameMaxWaitMs}) are required` });
      return;
    }

    const frame = await glassesFrameStore.waitForFrameAfter(after, waitMs);
    if (!frame) {
      res.status(204).end();
      return;
    }
    res.setHeader("Content-Type", "image/jpeg");
    res.setHeader("Cache-Control", "no-store");
    res.setHeader("X-Glasses-Stream-Id", frame.streamId);
    res.setHeader("X-Frame-Sequence", String(frame.sequence));
    res.setHeader("X-Frame-Received-At", String(frame.receivedAt));
    res.setHeader("X-Frame-TTL-Ms", String(glassesFrameTtlMs));
    res.send(frame.jpeg);
  });

  return router;
}
