// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// A stdio MCP server for Locus's backend tests: newline-delimited JSON-RPC
// on stdin and stdout. It answers `initialize` and `tools/list` (two tools,
// `echo` and `secret`) and calls these tools:
//
//   echo           its arguments, as JSON text
//   secret         the value of the variable `name` names, also written to
//                  stderr, so masking can be seen in both
//   crash          exits with status 3
//   child_request  sends its own `sampling/createMessage` under the call's
//                  id, then answers the call with what came back for it
//   flood          writes one line of `bytes` bytes (11 MiB by default)
//
// Every start writes `probe started` to stderr.

import { createInterface } from "node:readline";

const tools = [
  {
    name: "echo",
    description: "Answers its arguments",
    inputSchema: { type: "object" },
  },
  {
    name: "secret",
    description: "Answers the value of the variable `name` names",
    inputSchema: { type: "object", properties: { name: { type: "string" } }, required: ["name"] },
  },
];

// Calls waiting on the answer to the probe's own request, by the id it
// sent that request under.
const awaiting = new Map();

const write = (message) => process.stdout.write(JSON.stringify(message) + "\n");
const text = (id, value) => write({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: value }] } });

process.stderr.write("probe started\n");

function call(id, name, args) {
  switch (name) {
    case "echo":
      return text(id, JSON.stringify(args ?? {}));
    case "secret": {
      const value = process.env[args?.name] ?? "";
      process.stderr.write(`secret ${args?.name}=${value}\n`);
      return text(id, value);
    }
    case "crash":
      process.exit(3);
      return undefined;
    case "child_request":
      awaiting.set(id, id);
      return write({ jsonrpc: "2.0", id, method: "sampling/createMessage", params: { messages: [] } });
    case "flood": {
      const bytes = Number.isSafeInteger(args?.bytes) ? args.bytes : 11 * 1024 * 1024;
      return process.stdout.write("x".repeat(bytes) + "\n");
    }
    default:
      return write({ jsonrpc: "2.0", id, error: { code: -32602, message: `unknown tool: ${name}` } });
  }
}

createInterface({ input: process.stdin }).on("line", (line) => {
  if (!line.trim()) return;
  const message = JSON.parse(line);

  // The answer to the probe's own request: the call that sent it is
  // answered with what came back.
  if (message.method === undefined) {
    if (awaiting.has(message.id)) {
      awaiting.delete(message.id);
      text(message.id, JSON.stringify({ child_answer: message.error ?? message.result ?? null }));
    }
    return;
  }

  switch (message.method) {
    case "initialize":
      return write({
        jsonrpc: "2.0",
        id: message.id,
        result: {
          protocolVersion: message.params?.protocolVersion,
          capabilities: { tools: {} },
          serverInfo: { name: "probe", version: "1.0.0" },
        },
      });
    case "notifications/initialized":
      return undefined;
    case "tools/list":
      return write({ jsonrpc: "2.0", id: message.id, result: { tools } });
    case "tools/call":
      return call(message.id, message.params?.name, message.params?.arguments);
    default:
      if (message.id !== undefined) {
        write({ jsonrpc: "2.0", id: message.id, error: { code: -32601, message: "method not found" } });
      }
      return undefined;
  }
});

process.stdin.on("end", () => process.exit(0));
