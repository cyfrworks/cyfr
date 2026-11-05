#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// A stand-in for Claude Code, run as the `claude` program's command by
// claude_code.py: it speaks the stream-json shapes Claude Code 2.1.x was
// proved to speak (room #193; the control requests read from 2.1.318) and
// keeps its sessions in its HOME, the kept folder, as the harness does.
//
// - It refuses to start without the arguments every session takes
//   (`-p`, stream-json both ways, `--verbose`, partial messages, the
//   echo of user messages, `--strict-mcp-config`,
//   `--permission-prompt-tool stdio`), and with
//   `--resume` of a session its folder does not hold.
// - `initialize` is answered with a model listing, and the system prompt it
//   carries is kept; `mcp_set_servers` starts each stdio server it names
//   (the image's `cyfr-stub`), lists its tools over MCP and answers
//   `added`.
// - A user message is a turn: `system/init`, its echo under its `uuid`
//   (`isReplay`), then by its words: `hello`
//   asks to run its own `Bash` and replies naming its flags and prompt;
//   `read` makes an `assistant` `tool_use` of `mcp__cyfr__files`, asks
//   `can_use_tool` and holds until the driver's `control_response`, calls
//   the stub with the allow's `updatedInput` and replies with what it
//   answered; `first message` replies with the session's first message,
//   from its folder. Each reply streams as `stream_event` text deltas, then
//   the whole `assistant` message, then `result` with usage.
// - It writes a canary to its stderr and to its folder, which the driver
//   must never pass on.
import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';

const args = process.argv.slice(2);
const flag = (name) => {
  const at = args.indexOf(name);
  return at >= 0 ? args[at + 1] : undefined;
};
const BASE = ['-p', '--verbose', '--include-partial-messages', '--replay-user-messages', '--strict-mcp-config'];
const PAIRS = [['--input-format', 'stream-json'], ['--output-format', 'stream-json'], ['--permission-prompt-tool', 'stdio']];
const missing = BASE.filter((a) => !args.includes(a)).concat(PAIRS.filter(([f, v]) => flag(f) !== v).map(([f]) => f));
if (missing.length) {
  process.stderr.write(`fake-claude: missing ${missing.join(' ')}\n`);
  process.exit(2);
}

const home = process.env.HOME;
const store = path.join(home, '.fake-claude');
fs.mkdirSync(store, { recursive: true });
process.stderr.write('FAKE-STDERR-CANARY the harness writes this to its stderr\n');
fs.writeFileSync(path.join(home, 'canary.txt'), 'FAKE-FOLDER-CANARY the harness keeps this in its folder\n');

const resume = flag('--resume');
const sessionId = resume || flag('--session-id') || crypto.randomUUID();
const transcriptFile = path.join(store, `${sessionId}.json`);
let transcript = [];
if (resume) {
  if (!fs.existsSync(transcriptFile)) {
    process.stderr.write(`fake-claude: no session ${resume} in this folder\n`);
    process.exit(1);
  }
  transcript = JSON.parse(fs.readFileSync(transcriptFile, 'utf8'));
}
const save = () => fs.writeFileSync(transcriptFile, JSON.stringify(transcript));
const model = flag('--model') || 'fake-default';
const partial = args.includes('--include-partial-messages');
const OWN_TOOLS = flag('--tools') === undefined ? ['Bash', 'Read', 'Edit'] : flag('--tools').split(',').filter(Boolean);
const MODELS = [
  { value: 'default', displayName: 'Default (recommended)', description: 'fake', supportsEffort: true, supportedEffortLevels: ['low', 'medium', 'high'] },
  { value: 'fake-opus', resolvedModel: 'claude-fake-opus-1', displayName: 'Fake Opus', description: 'fake', supportsEffort: true, supportedEffortLevels: ['low', 'medium', 'high', 'max'] },
  { value: 'fake-haiku', displayName: 'Fake Haiku', description: 'fake' },
];

const out = (event) => process.stdout.write(JSON.stringify(event) + '\n');
let appended = '';
const asks = new Map();
let asked = 0;

// ---- MCP servers set by the driver ----
const servers = new Map();

function startServer(name, config) {
  return new Promise((resolve) => {
    const child = spawn(config.command, config.args || [], { stdio: ['pipe', 'pipe', 'ignore'] });
    const server = { child, tools: [], next: 1, waiting: new Map() };
    child.on('error', () => resolve(null));
    readline.createInterface({ input: child.stdout }).on('line', (line) => {
      const message = JSON.parse(line);
      server.waiting.get(message.id)?.(message);
      server.waiting.delete(message.id);
    });
    server.request = (method, params) => new Promise((done) => {
      const id = server.next++;
      server.waiting.set(id, done);
      child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    });
    server.request('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'fake-claude' } })
      .then(() => {
        child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
        return server.request('tools/list', {});
      })
      .then((listed) => {
        server.tools = listed.result.tools;
        servers.set(name, server);
        resolve(server);
      });
  });
}

function stopServers() {
  for (const server of servers.values()) server.child.kill('SIGINT');
  servers.clear();
}

async function setServers(requestId, wanted) {
  const removed = [...servers.keys()];
  stopServers();
  const added = [];
  const errors = {};
  for (const [name, config] of Object.entries(wanted)) {
    (await startServer(name, config)) ? added.push(name) : (errors[name] = 'failed to start');
  }
  out({ type: 'control_response', response: { subtype: 'success', request_id: requestId, response: { added, removed, errors } } });
}

const mcpTools = () => [...servers.entries()].flatMap(([name, s]) => s.tools.map((t) => `mcp__${name}__${t.name}`));

// ---- A turn ----
function ask(tool, input) {
  const requestId = `ask-${++asked}`;
  const toolUseId = `toolu_fake_${asked}`;
  out({ type: 'control_request', request_id: requestId, request: { subtype: 'can_use_tool', tool_name: tool, input, tool_use_id: toolUseId, permission_suggestions: [] } });
  return new Promise((resolve) => asks.set(requestId, (decision) => resolve({ decision, toolUseId })));
}

function reply(text) {
  if (partial) {
    const half = Math.ceil(text.length / 2);
    for (const piece of [text.slice(0, half), text.slice(half)]) {
      out({ type: 'stream_event', event: { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: piece } }, parent_tool_use_id: null, session_id: sessionId });
    }
  }
  out({ type: 'assistant', message: { id: `msg_${crypto.randomUUID()}`, role: 'assistant', model, content: [{ type: 'text', text }], usage: { input_tokens: 7, output_tokens: 3 } }, parent_tool_use_id: null, session_id: sessionId });
  transcript.push({ role: 'assistant', text });
  save();
  out({ type: 'result', subtype: 'success', is_error: false, num_turns: 1, result: text, session_id: sessionId, usage: { input_tokens: 12, output_tokens: text.length, cache_read_input_tokens: 5, cache_creation_input_tokens: 2 } });
}

async function turn(message) {
  const content = message.message.content;
  const text = typeof content === 'string' ? content : content.filter((b) => b.type === 'text').map((b) => b.text).join('');
  transcript.push({ role: 'user', text });
  save();
  out({ type: 'system', subtype: 'init', session_id: sessionId, model, tools: [...OWN_TOOLS, ...mcpTools()], mcp_servers: [...servers.keys()].map((name) => ({ name, status: 'connected' })), permissionMode: flag('--permission-mode') || 'default' });
  // --replay-user-messages: the message, echoed under the uuid it came with.
  out({ type: 'user', message: message.message, parent_tool_use_id: null, session_id: sessionId, uuid: message.uuid, isReplay: true });

  if (text.includes('hello')) {
    const { decision } = await ask('Bash', { command: 'cat canary.txt' });
    const ran = decision.behavior === 'allow' ? 'allowed' : 'refused';
    reply(`Hello from the fake harness: session ${sessionId}, model ${model}, effort ${flag('--effort') || 'unset'}, tools ${flag('--tools') ?? 'all'}, Bash ${ran}, prompt "${appended}".`);
  } else if (text.includes('read')) {
    const input = { action: 'read', path: 'notes.txt' };
    out({ type: 'assistant', message: { id: `msg_${crypto.randomUUID()}`, role: 'assistant', model, content: [{ type: 'text', text: 'Reading it.' }, { type: 'tool_use', id: `toolu_fake_${asked + 1}`, name: 'mcp__cyfr__files', input }], usage: { input_tokens: 5, output_tokens: 2 } }, parent_tool_use_id: null, session_id: sessionId });
    const { decision, toolUseId } = await ask('mcp__cyfr__files', input);
    let said;
    if (decision.behavior === 'allow') {
      const called = await servers.get('cyfr').request('tools/call', { name: 'files', arguments: decision.updatedInput, _meta: { 'claudecode/toolUseId': toolUseId } });
      const result = called.result;
      said = result.content.map((b) => b.text).join('');
      out({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: toolUseId, content: said, is_error: result.isError === true }] }, parent_tool_use_id: null, session_id: sessionId });
      said = result.isError ? `CYFR refused: ${said}` : `The file says: ${said}`;
    } else {
      said = `Denied: ${decision.message}`;
    }
    reply(said);
  } else if (text.includes('first message')) {
    reply(`Your first message was: ${transcript[0].text}`);
  } else {
    reply('ok');
  }
}

// ---- The driver's lines ----
let turns = Promise.resolve();
readline.createInterface({ input: process.stdin }).on('line', (line) => {
  const message = JSON.parse(line);
  if (message.type === 'control_request') {
    const request = message.request;
    if (request.subtype === 'initialize') {
      appended = request.appendSystemPrompt || '';
      out({ type: 'control_response', response: { subtype: 'success', request_id: message.request_id, response: { commands: [], agents: [], output_style: 'default', available_output_styles: ['default'], models: MODELS, account: {}, claude_code_version: 'fake', session_state: 'idle' } } });
    } else if (request.subtype === 'mcp_set_servers') {
      setServers(message.request_id, request.servers || {});
    } else {
      out({ type: 'control_response', response: { subtype: 'error', request_id: message.request_id, error: `unsupported ${request.subtype}` } });
    }
  } else if (message.type === 'control_response') {
    const resolve = asks.get(message.response.request_id);
    asks.delete(message.response.request_id);
    resolve?.(message.response.response);
  } else if (message.type === 'user') {
    turns = turns.then(() => turn(message));
  }
}).on('close', () => turns.then(() => {
  stopServers();
  process.exit(0);
}));
