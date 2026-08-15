import { describe, expect, it } from "vitest";
import {
  parsePortaActions,
  stripPortaActionBlocks,
} from "./aqua-actions-parser";

function block(json: string): string {
  return "```aqua-actions\n" + json + "\n```";
}

describe("parsePortaActions", () => {
  it("parses a valid ui.request_approval intent", () => {
    const content =
      "Working on it.\n" +
      block(
        JSON.stringify([
          {
            kind: "ui.request_approval",
            title: "Delete file",
            summary: "Removes report.csv",
            risk: "high",
            action_description: "files.delete report.csv",
          },
        ]),
      );

    const { intents, drops, strippedContent } = parsePortaActions(content);

    expect(drops).toEqual([]);
    expect(intents).toHaveLength(1);
    expect(intents[0]).toMatchObject({
      kind: "ui.request_approval",
      risk: "high",
    });
    expect(strippedContent).toBe("Working on it.");
  });

  it("drops malformed JSON without throwing", () => {
    const { intents, drops } = parsePortaActions(block("{not json"));
    expect(intents).toEqual([]);
    expect(drops).toHaveLength(1);
    expect(drops[0]?.reason).toMatch(/JSON parse error/);
  });

  it("drops non-array bodies and unknown kinds", () => {
    const notArray = parsePortaActions(block('{"kind":"ui.overlay.close"}'));
    expect(notArray.intents).toEqual([]);
    expect(notArray.drops[0]?.reason).toMatch(/not a JSON array/);

    const unknown = parsePortaActions(block('[{"kind":"ui.self_destruct"}]'));
    expect(unknown.intents).toEqual([]);
    expect(unknown.drops).toHaveLength(1);
  });

  it("rejects a navigate outside the allowed paths", () => {
    const { intents, drops } = parsePortaActions(
      block('[{"kind":"ui.navigate","path":"/etc/passwd"}]'),
    );
    expect(intents).toEqual([]);
    expect(drops).toHaveLength(1);
  });
});

describe("stripPortaActionBlocks", () => {
  it("strips closed and mid-stream blocks for rendering", () => {
    expect(
      stripPortaActionBlocks("a\n```aqua-actions\n[]\n```\nb"),
    ).not.toMatch(/aqua-actions/);
    expect(stripPortaActionBlocks('a\n```aqua-actions\n[{"kind"')).not.toMatch(
      /aqua-actions/,
    );
  });
});
