import { describe, expect, it } from "vitest";
import { applyToolSurface } from "../lib/tool-surface";

describe("applyToolSurface", () => {
  it("always attaches the policy — never a visible_tools list", () => {
    const out = applyToolSurface(
      { task: "t" },
      { "files.read": "auto", native_search: "auto" },
    ) as Record<string, unknown>;

    expect(out.tool_policy).toEqual({
      "files.read": "auto",
      native_search: "auto",
    });
    expect("visible_tools" in out).toBe(false);
  });

  it("defaults an absent policy to the empty (fail-closed) allowlist", () => {
    const out = applyToolSurface({ task: "t" }, null) as Record<
      string,
      unknown
    >;
    expect(out.tool_policy).toEqual({});
  });
});
