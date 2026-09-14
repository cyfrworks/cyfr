// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// MCP child fixture with modes for peer requests, id collisions and process failures.

const mode = process.argv[2] || "well-behaved";

// `exit-at-start` ends before reading anything.
if (mode === "exit-at-start") process.exit(4);

// `never-ready` reads its input and answers nothing.

// `stderr-env` writes its PROBE_OWN value to stderr as it starts.
if (mode === "stderr-env") process.stderr.write(`starting with ${process.env.PROBE_OWN}\n`);

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + "\n");
}

let buffer = "";

process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;

  let idx;
  while ((idx = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, idx).trim();
    buffer = buffer.slice(idx + 1);
    if (!line) continue;

    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      continue;
    }

    if (mode === "never-ready") continue;

    if (msg.method === "initialize") {
      // A peer's OWN request, with an id counter that — like the bridge's —
      // starts at 1. Sent HERE, after initialize arrived and before it is
      // answered, so it is guaranteed to land while the bridge's own id 1
      // is pending. (Emitting it at startup instead raced ahead of that
      // and the bridge simply dropped it — a test that could not fail.)
      if (mode === "rogue-request") {
        send({ jsonrpc: "2.0", id: 1, method: "roots/list" });
      }

      send({
        jsonrpc: "2.0",
        id: msg.id,
        result: {
          protocolVersion: "2025-03-26",
          capabilities: {},
          serverInfo: { name: "fake-child", version: "0.0.0" },
        },
      });
      continue;
    }

    if (msg.method === "tools/list") {
      // Send a peer request matching the pending tools/list id to test bidirectional id isolation.
      if (mode === "rogue-request") {
        send({ jsonrpc: "2.0", id: 2, method: "roots/list" });
      }

      send({
        jsonrpc: "2.0",
        id: msg.id,
        result: { tools: [{ name: "ping", description: "pong", inputSchema: { type: "object" } }] },
      });

      // Exit after the handshake so the next write exercises asynchronous EPIPE handling.
      if (mode === "die-after-handshake") {
        setTimeout(() => process.exit(0), 20);
      }
      continue;
    }

    if (msg.method === "tools/call") {
      // `die-on-call` crashes instead of answering.
      if (mode === "die-on-call") process.exit(3);

      // `error-env` refuses the call with an error quoting its PROBE_OWN value.
      if (mode === "error-env") {
        send({ jsonrpc: "2.0", id: msg.id, error: { code: -32000, message: `refused with ${process.env.PROBE_OWN}` } });
        continue;
      }

      // `env-probe` reports what this child can see of its environment —
      // the bridge's secrets must not be in it, its own `env` block must.
      // `echo-env` answers with the environment variable its argument names.
      if (mode === "echo-env" || mode === "stderr-env") {
        const name = msg.params?.arguments?.name;
        send({
          jsonrpc: "2.0",
          id: msg.id,
          result: { content: [{ type: "text", text: JSON.stringify({ value: process.env[name] ?? null }) }] },
        });
        continue;
      }

      const text =
        mode === "env-probe"
          ? JSON.stringify({
              keyring: process.env.CYFR_CRYPTO_KEYRING ?? null,
              dsn: process.env.CYFR_DATABASE_URL ?? null,
              // Every application variable, as a class: none may reach a child.
              cyfr: Object.keys(process.env).filter((k) => k.startsWith("CYFR_")),
              own: process.env.PROBE_OWN ?? null,
              path: Boolean(process.env.PATH),
            })
          : "pong";

      // Echo the id back as a STRING. Legal, and emitted by more than one
      // stdio server; a strict Map lookup dropped it and hung the call.
      send({
        jsonrpc: "2.0",
        id: String(msg.id),
        result: { content: [{ type: "text", text }] },
      });
      continue;
    }

    if (msg.id != null) {
      send({ jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: "unknown" } });
    }
  }
});
