import { describe, expect, it } from "vitest";
import {
  classifyTool,
  registerToolAnnotations,
  requiresApproval,
} from "./tool-tiers";

describe("classifyTool", () => {
  it("defaults an unknown tool/action to tier2 (approval)", () => {
    expect(classifyTool("mystery", { action: "explode" })).toBe("tier2");
    expect(classifyTool("mystery")).toBe("tier2");
  });

  it("treats read-verb actions as tier1", () => {
    expect(classifyTool("anything", { action: "list" })).toBe("tier1");
    expect(classifyTool("anything", { action: "get" })).toBe("tier1");
  });

  it("honors server-declared action kinds from tools/list annotations", () => {
    registerToolAnnotations([
      {
        name: "vault",
        annotations: {
          actions: {
            peek: { kind: "read" },
            burn: { kind: "destructive" },
            stir: { kind: "write" },
          },
        },
      },
    ]);

    expect(classifyTool("vault", { action: "peek" })).toBe("tier1");
    expect(classifyTool("vault", { action: "burn" })).toBe("tier3");
    expect(classifyTool("vault", { action: "stir" })).toBe("tier2");
  });

  it("requiresApproval covers tier2 and tier3", () => {
    expect(requiresApproval("mystery", { action: "explode" })).toBe(true);
    expect(requiresApproval("anything", { action: "list" })).toBe(false);
  });
});
