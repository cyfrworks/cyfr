// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// A stdio MCP backend that reports what its process can see and do, for the
// real-image isolation test (tests/bridge-image). Every tool answers with a
// JSON object as text; an operation the kernel refuses is reported as
// `{ ok: false, code }`, never thrown.

import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const TOOLS = {
  whoami: "Identity, home, environment names, limits and file modes of this process.",
  read_path: "Read a file or list a directory: { path }.",
  read_environ: "Read /proc/<pid>/environ: { pid }.",
  signal: "Send a signal: { pid, sig }.",
  spawn_daemon: "Start a process in a new session that ignores SIGTERM; returns its pid.",
  echo_env: "The value of one environment variable: { name }; with { stderr: true } it is also written to stderr.",
  exit: "Exit with { code } after answering.",
};

function attempt(fn) {
  try {
    return { ok: true, ...(fn() || {}) };
  } catch (err) {
    return { ok: false, code: err.code || String(err) };
  }
}

function limits() {
  const wanted = {
    "Max open files": "nofile",
    "Max processes": "nproc",
    "Max core file size": "core",
    "Max file size": "fsize",
  };
  const out = {};
  for (const line of fs.readFileSync("/proc/self/limits", "utf8").split("\n")) {
    for (const [label, key] of Object.entries(wanted)) {
      if (line.startsWith(label)) {
        const [soft, hard] = line.slice(label.length).trim().split(/\s+/);
        out[key] = { soft, hard };
      }
    }
  }
  return out;
}

const handlers = {
  whoami() {
    const home = process.env.HOME;
    const marker = path.join(home, "secret.txt");
    fs.writeFileSync(marker, "probe secret\n");
    return {
      uid: process.getuid(),
      gid: process.getgid(),
      groups: process.getgroups(),
      pid: process.pid,
      home,
      home_mode: (fs.statSync(home).mode & 0o7777).toString(8),
      marker,
      marker_mode: (fs.statSync(marker).mode & 0o7777).toString(8),
      tmpdir: process.env.TMPDIR,
      cwd: process.cwd(),
      env_names: Object.keys(process.env).sort(),
      limits: limits(),
    };
  },
  read_path({ path: target }) {
    return attempt(() => {
      if (fs.statSync(target).isDirectory()) fs.readdirSync(target);
      else fs.readFileSync(target);
    });
  },
  read_environ({ pid }) {
    return attempt(() => {
      fs.readFileSync(`/proc/${pid}/environ`);
    });
  },
  signal({ pid, sig }) {
    return attempt(() => {
      process.kill(pid, sig);
    });
  },
  spawn_daemon() {
    // `detached` puts the child in a session of its own; the ignored SIGTERM
    // survives the exec into sleep.
    const child = spawn("/bin/sh", ["-c", "trap '' TERM; exec sleep 1000000"], {
      detached: true,
      stdio: "ignore",
    });
    child.unref();
    return { pid: child.pid };
  },
  echo_env({ name, stderr }) {
    const value = process.env[name] ?? null;
    if (stderr) process.stderr.write(`${name}=${value}\n`);
    return { value };
  },
  exit({ code }) {
    setTimeout(() => process.exit(code), 50);
    return { exiting: code };
  },
};

function send(message) {
  process.stdout.write(JSON.stringify(message) + "\n");
}

let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  let newline;
  while ((newline = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, newline).trim();
    buffer = buffer.slice(newline + 1);
    if (!line) continue;
    const msg = JSON.parse(line);
    if (msg.id == null) continue;
    if (msg.method === "initialize") {
      send({
        jsonrpc: "2.0",
        id: msg.id,
        result: { protocolVersion: "2025-03-26", capabilities: { tools: {} }, serverInfo: { name: "probe", version: "0.0.0" } },
      });
    } else if (msg.method === "tools/list") {
      send({
        jsonrpc: "2.0",
        id: msg.id,
        result: {
          tools: Object.entries(TOOLS).map(([name, description]) => ({ name, description, inputSchema: { type: "object" } })),
        },
      });
    } else if (msg.method === "tools/call" && handlers[msg.params?.name]) {
      let text;
      try {
        text = JSON.stringify(handlers[msg.params.name](msg.params.arguments || {}));
      } catch (err) {
        text = JSON.stringify({ ok: false, code: err.code || String(err) });
      }
      send({ jsonrpc: "2.0", id: msg.id, result: { content: [{ type: "text", text }] } });
    } else {
      send({ jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: "unknown method" } });
    }
  }
});
