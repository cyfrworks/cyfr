import type { PortaContext } from "../state/porta-context-store";

/**
 * Stable text-intent protocol prelude appended to AQUA's system prompt.
 *
 * This prefix should rarely change so the Anthropic prompt cache prefix stays
 * hot across turns. The mutable <porta-context> tail is appended separately
 * via {@link buildPortaContextBlock} so it doesn't invalidate the cached
 * prefix on every turn.
 */
const TEXT_INTENT_PRELUDE = `

---

## Porta Shell Control

You are running inside Porta, a desktop assistant shell. When you want to
change the user's view, open an app, or copy something to the clipboard,
emit a fenced block at the end of your reply:

\`\`\`aqua-actions
[
  {"kind": "ui.tincture.open", "publisher": "local", "name": "weather-dashboard"}
]
\`\`\`

The block executes after your reply completes. Guidelines:

- Only use it when the user asked you to change the interface.
- One block per reply. Multiple actions may be listed in the same array.
- Do not explain the block in prose — the user will not see raw JSON.

Available action kinds:

- \`ui.navigate\` \`{"path": "/tinctures" | "/schedules" | "/components" | "/mcp-servers" | "/settings"}\`
- \`ui.overlay.open\` \`{"state"?: "peek" | "half" | "full"}\` — change overlay size
- \`ui.overlay.close\`
- \`ui.overlay.focus_input\`
- \`ui.tincture.open\` \`{"publisher": "...", "name": "..."}\` — launch an app
- \`ui.tincture.close\` \`{"name": "..."}\`
- \`ui.tincture.focus\` \`{"name": "..."}\`
- \`ui.schedules.focus\` \`{"id": "..."}\`
- \`ui.components.focus\` \`{"ref": "..."}\`
- \`ui.mcp.focus\` \`{"server": "..."}\`
- \`ui.copy_clipboard\` \`{"text": "..."}\`
- \`ui.request_approval\` \`{"title": "...", "summary": "...", "risk": "low"|"medium"|"high", "action_description": "..."}\` — ask the user to confirm something YOU are about to do. The decision arrives as a new user turn (\`[System: user approved ...]\` or \`[System: user declined ...]\`) — act accordingly. Use this before any action that publishes, deletes, sends externally, or costs money.
`;

export function buildSystemPrelude(): string {
  return TEXT_INTENT_PRELUDE;
}

/**
 * Mutable tail describing what the user is currently viewing. Kept compact so
 * it stays cheap to re-send on every turn and so the stable prelude above
 * remains the cacheable prefix.
 */
export function buildPortaContextBlock(ctx: PortaContext): string {
  const lines: string[] = [];
  lines.push(`route: ${ctx.route}`);
  lines.push(`overlay: ${ctx.overlayState}`);
  if (ctx.focusedApp) {
    const tag = ctx.focusedApp.shared ? "shared" : "private";
    lines.push(
      `focused_app: ${ctx.focusedApp.publisher}.${ctx.focusedApp.name} (${ctx.focusedApp.title}, ${tag})`,
    );
  } else {
    lines.push("focused_app: none");
  }
  if (ctx.viewingApp) lines.push(`viewing_app: ${ctx.viewingApp}`);
  lines.push(
    `open_apps: ${ctx.openedApps.length > 0 ? ctx.openedApps.join(", ") : "none"}`,
  );
  if (ctx.pendingSetupRef) lines.push(`pending_setup: ${ctx.pendingSetupRef}`);

  return `\n\n<porta-context>\n${lines.join("\n")}\n</porta-context>\n`;
}
