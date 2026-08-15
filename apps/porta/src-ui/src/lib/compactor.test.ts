import { describe, expect, it } from "vitest";
import { compact } from "./compactor";

function msg(role: string, content: string) {
  return { role, content };
}

describe("compact", () => {
  it("passes non-arrays through unchanged", () => {
    expect(compact(null)).toBe(null);
    expect(compact("nope")).toBe("nope");
  });

  it("passes an under-budget conversation through unchanged", () => {
    const messages = [msg("user", "hi"), msg("assistant", "hello")];
    expect(compact(messages)).toBe(messages);
  });

  it("preserves the most recent 20 messages when over budget", () => {
    // 200 messages × ~4k chars ≈ 800k chars — well over the 320k budget.
    const big = "x".repeat(4_000);
    const messages = Array.from({ length: 200 }, (_, i) =>
      msg("user", `${i}:${big}`),
    );

    const out = compact(messages) as { role: string; content: string }[];

    expect(out.length).toBeLessThan(messages.length);
    // The last 20 originals survive verbatim at the tail of the output.
    const tail = out.slice(-20).map((m) => m.content);
    const expected = messages.slice(-20).map((m) => m.content);
    expect(tail).toEqual(expected);
  });
});
