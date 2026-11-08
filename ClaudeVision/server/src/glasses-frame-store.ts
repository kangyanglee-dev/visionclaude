import { randomUUID } from "node:crypto";

export interface GlassesFrame {
  streamId: string;
  sequence: number;
  receivedAt: number;
  jpeg: Buffer;
}

const FRAME_TTL_MS = 3_000;
const MAX_WAIT_MS = 8_000;

class GlassesFrameStore {
  private latest: GlassesFrame | null = null;
  private waiters = new Set<() => void>();
  private streamId: string | null = null;
  private lastSequence = -1;
  private retiredStreamIds = new Set<string>();

  accept(streamId: string, sequence: number, jpeg: Buffer, receivedAt = Date.now()): void {
    if (this.retiredStreamIds.has(streamId)) throw new Error("Retired stream id cannot be reused");
    if (streamId !== this.streamId) {
      if (sequence !== 0) throw new Error("A new stream must start at sequence 0");
      if (this.streamId) {
        this.retiredStreamIds.add(this.streamId);
        if (this.retiredStreamIds.size > 64) {
          this.retiredStreamIds.delete(this.retiredStreamIds.values().next().value!);
        }
      }
      this.streamId = streamId;
      this.lastSequence = -1;
      this.latest = null;
    }
    if (!Number.isSafeInteger(sequence) || sequence < 0 || sequence <= this.lastSequence) {
      throw new Error("Frame sequence must increase within a stream");
    }

    this.lastSequence = sequence;
    this.latest = { streamId, sequence, receivedAt, jpeg };
    for (const wake of this.waiters) wake();
  }

  status(now = Date.now()) {
    const frame = this.latest;
    const ageMs = frame ? Math.max(0, now - frame.receivedAt) : null;
    const fresh = ageMs !== null && ageMs <= FRAME_TTL_MS;
    return {
      source: frame?.streamId === this.streamId && fresh ? "rayban" : null,
      streamId: fresh ? this.streamId : null,
      sequence: fresh ? frame?.sequence ?? null : null,
      receivedAt: fresh ? frame?.receivedAt ?? null : null,
      ageMs,
      fresh,
    };
  }

  async waitForFrameAfter(after: number, waitMs: number): Promise<GlassesFrame | null> {
    const deadline = Date.now() + Math.min(Math.max(waitMs, 0), MAX_WAIT_MS);
    while (true) {
      const frame = this.latest;
      if (frame && frame.receivedAt > after && Date.now() - frame.receivedAt <= FRAME_TTL_MS) {
        return frame;
      }
      const remaining = deadline - Date.now();
      if (remaining <= 0) return null;
      await new Promise<void>((resolve) => {
        let timer: ReturnType<typeof setTimeout>;
        const wake = () => {
          clearTimeout(timer);
          this.waiters.delete(wake);
          resolve();
        };
        timer = setTimeout(wake, remaining);
        this.waiters.add(wake);
      });
    }
  }
}

export const glassesFrameStore = new GlassesFrameStore();
export const createGlassesStreamId = () => randomUUID();
export const glassesFrameMaxWaitMs = MAX_WAIT_MS;
export const glassesFrameTtlMs = FRAME_TTL_MS;
