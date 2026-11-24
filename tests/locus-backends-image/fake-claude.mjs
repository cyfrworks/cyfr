#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// A stand-in for Claude Code, run under its brain driver as the `claude`
// program's command by brain_claude_code.py: it speaks the stream-json
// shapes Claude Code 2.1.x was proved to speak (room #193; the control
// requests read from 2.1.318) and keeps its sessions in its HOME, the
// kept folder, as the harness does.
//
// - It refuses to start without the arguments every session takes
//   (`-p`, stream-json both ways, `--verbose`, partial messages,
//   `--permission-prompt-tool stdio`). Started with
//   `--resume` of a session its folder does not hold, it ends as 2.1.318
//   ended: a `result` of no turn naming the session on its stdout, the
//   same words on its stderr, and exit 1, before it reads a line.
// - `initialize` is answered with a model listing, and the system prompt it
//   carries is kept; `mcp_set_servers` starts each stdio server it names
//   (the image's `cyfr-stub`), lists its tools over MCP and answers
//   `added`.
// - The person's own MCP servers, those `$HOME/.claude.json` names under
//   `mcpServers`, are started at its start unless it was started with
//   `--strict-mcp-config`, as Claude Code 2.1.323 was measured to start
//   them. `mcp_status` names them with their source, `user`,
//   beside the driver's, `dynamic`; a server `mcp_set_servers` names
//   replaces one of theirs of the same name for the process's life; each
//   ask of an MCP tool names its server (`mcp_server`).
// - A user message is a turn: `system/init`, then by the words of its last
//   text block (a new session's history rides before it): `hello`
//   asks to run its own `Bash` and replies naming its flags and prompt;
//   `read` makes an `assistant` `tool_use` of `mcp__cyfr__files`, asks
//   `can_use_tool` and holds until the driver's `control_response`, calls
//   the stub with the allow's `updatedInput` and replies with what it
//   answered; `theirs` calls `echo_env` of each server of the person's own
//   it holds, for `THEIR_SERVER`, asked as that server's, and replies naming
//   the MCP tools its init listed and what each call answered; `modes` asks for its own `Write` and `Bash`
//   and replies with its whole command line and the driver's two whole
//   answers, as JSON. Each reply streams as `stream_event` text deltas, then
//   the whole `assistant` message, then `result` with usage.
// - What a turn writes names the user line it answers by that line's
//   `uuid` (`user_message_uuids` on its init, its messages and its
//   result), as 2.1.318 names a line written with one.
// - It writes a canary to its stderr and to its folder, which the driver
//   must never pass on, and a stand-in sign-in, `.claude/.credentials.json`.
// - Beside its own store it keeps each session's user lines as Claude Code
//   keeps its transcript, `.claude/projects/-fake/<session>.jsonl`, each
//   under the uuid it was written with, for the brain driver's `forget` and
//   its reading of what a transcript holds (brain_claude_code.py).
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
const BASE = ['-p', '--verbose', '--include-partial-messages'];
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
const config = path.join(home, '.claude');
const projects = path.join(config, 'projects', '-fake');
fs.mkdirSync(projects, { recursive: true });
if (!fs.existsSync(path.join(config, '.credentials.json'))) {
  fs.writeFileSync(path.join(config, '.credentials.json'), '{"FAKE-SIGNIN-CANARY":"the sign-in a person made"}\n');
}

const resume = flag('--resume');
const sessionId = resume || flag('--session-id') || crypto.randomUUID();
const transcriptFile = path.join(store, `${sessionId}.json`);
let transcript = [];
if (resume) {
  if (!fs.existsSync(transcriptFile)) {
    const said = `No conversation found with session ID: ${resume}`;
    const result = { type: 'result', subtype: 'error_during_execution', duration_ms: 0, duration_api_ms: 0, is_error: true,
      num_turns: 0, stop_reason: null, session_id: resume, total_cost_usd: 0, usage: { input_tokens: 0, output_tokens: 0 },
      modelUsage: {}, permission_denials: [], uuid: crypto.randomUUID(), errors: [said] };
    fs.writeSync(1, JSON.stringify(result) + '\n');
    process.stderr.write(`${said}\n`);
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

// The user line the turn under way answers, which its lines name.
let answering = null;
const NAMING = new Set(['system', 'assistant', 'result']);
const out = (event) => {
  const named = answering && NAMING.has(event.type) && !('user_message_uuids' in event)
    ? { ...event, user_message_uuids: [answering] }
    : event;
  process.stdout.write(JSON.stringify(named) + '\n');
};
let appended = '';
const asks = new Map();
// The driver's answers as their whole lines, by request id.
const wholes = new Map();
let asked = 0;

// ---- MCP servers: the driver's (`dynamic`) and the person's own ----
const servers = new Map();
const own = new Map();
let ownNames = [];

function startServer(name, config, into = servers) {
  return new Promise((resolve) => {
    const child = spawn(config.command, config.args || [], { stdio: ['pipe', 'pipe', 'ignore'], env: { ...process.env, ...(config.env || {}) } });
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
        into.set(name, server);
        resolve(server);
      });
  });
}

function stopServers(which = servers) {
  for (const server of which.values()) server.child.kill('SIGINT');
  which.clear();
}

// The person's own start with the process. `mcp_set_servers` and every
// turn but `theirs` go on without them, as Claude Code 2.1.323 was measured
// to answer a set and finish a turn beside a server of the person's that
// never answers. `theirs` waits for all of
// them, the fake's own simplification, which no case's server tests: the
// real program lists and calls the ones that started. A server the
// driver's set names replaces theirs of that name, as the records measured;
// stopping the replaced one once it has started is the
// fake's own housekeeping, not a measured exit.
const shadowed = new Set();
let ownListed = Promise.resolve();
if (!args.includes('--strict-mcp-config')) {
  let configured = {};
  try {
    configured = JSON.parse(fs.readFileSync(path.join(home, '.claude.json'), 'utf8')).mcpServers || {};
  } catch {}
  ownNames = Object.keys(configured).sort();
  ownListed = Promise.all(ownNames.map((name) => startServer(name, configured[name], own).then((server) => {
    if (server && shadowed.has(name)) {
      server.child.kill('SIGINT');
      own.delete(name);
    }
  })));
}

async function setServers(requestId, wanted) {
  const removed = [...servers.keys()];
  stopServers();
  for (const name of Object.keys(wanted)) {
    shadowed.add(name);
    own.get(name)?.child.kill('SIGINT');
    own.delete(name);
    ownNames = ownNames.filter((n) => n !== name);
  }
  const added = [];
  const errors = {};
  for (const [name, config] of Object.entries(wanted)) {
    (await startServer(name, config)) ? added.push(name) : (errors[name] = 'failed to start');
  }
  out({ type: 'control_response', response: { subtype: 'success', request_id: requestId, response: { added, removed, errors } } });
}

const toolsOf = (held) => [...held.entries()].flatMap(([name, s]) => s.tools.map((t) => `mcp__${name}__${t.name}`));
const mcpTools = () => [...toolsOf(own), ...toolsOf(servers)];
// The one server the driver set, CYFR's, by its name.
const dynamicName = () => [...servers.keys()][0];

// ---- A turn ----
function ask(tool, input, server) {
  const requestId = `ask-${++asked}`;
  const toolUseId = `toolu_fake_${asked}`;
  out({ type: 'control_request', request_id: requestId, request: { subtype: 'can_use_tool', tool_name: tool, input, tool_use_id: toolUseId, permission_suggestions: [], ...(server ? { mcp_server: server } : {}) } });
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
  // The main requests' own usage, and every model's since the last result,
  // a side request's among them, which holds the main requests' too, as
  // Claude Code 2.1.323 reports them.
  out({ type: 'result', subtype: 'success', is_error: false, num_turns: 1, result: text, session_id: sessionId, usage: { input_tokens: 12, output_tokens: text.length, cache_read_input_tokens: 5, cache_creation_input_tokens: 2 },
    model_usage_since_last_result: {
      [model]: { inputTokens: 12, outputTokens: text.length, cacheReadInputTokens: 5, cacheCreationInputTokens: 2, webSearchRequests: 0, costUSD: 0.01 },
      'fake-side': { inputTokens: 30, outputTokens: 4, cacheReadInputTokens: 0, cacheCreationInputTokens: 0, webSearchRequests: 0, costUSD: 0.001 },
    } });
}

async function turn(message) {
  const content = message.message.content;
  const texts = typeof content === 'string' ? [content] : content.filter((b) => b.type === 'text').map((b) => b.text);
  const text = texts.join('');
  // The words of the ask, its last text block: a new session's history
  // rides in a block before it, and is read but never acted on.
  const words = texts[texts.length - 1] ?? '';
  answering = message.uuid ?? null;
  transcript.push({ role: 'user', text });
  save();
  fs.appendFileSync(path.join(projects, `${sessionId}.jsonl`), JSON.stringify({ type: 'user', uuid: message.uuid, sessionId }) + '\n');
  out({ type: 'system', subtype: 'init', session_id: sessionId, model, tools: [...OWN_TOOLS, ...mcpTools()], mcp_servers: [...servers.keys()].map((name) => ({ name, status: 'connected' })), permissionMode: flag('--permission-mode') || 'default' });

  if (words.includes('hello')) {
    const { decision } = await ask('Bash', { command: 'cat canary.txt' });
    const ran = decision.behavior === 'allow' ? 'allowed' : 'refused';
    reply(`Hello from the fake harness: session ${sessionId}, model ${model}, effort ${flag('--effort') || 'unset'}, tools ${flag('--tools') ?? 'all'}, Bash ${ran}, prompt "${appended}".`);
  } else if (words.includes('read')) {
    const input = { action: 'read', path: 'notes.txt' };
    const cyfr = dynamicName();
    out({ type: 'assistant', message: { id: `msg_${crypto.randomUUID()}`, role: 'assistant', model, content: [{ type: 'text', text: 'Reading it.' }, { type: 'tool_use', id: `toolu_fake_${asked + 1}`, name: `mcp__${cyfr}__files`, input }], usage: { input_tokens: 5, output_tokens: 2 } }, parent_tool_use_id: null, session_id: sessionId });
    const { decision, toolUseId } = await ask(`mcp__${cyfr}__files`, input, { name: cyfr, source: 'dynamic' });
    let said;
    if (decision.behavior === 'allow') {
      const called = await servers.get(cyfr).request('tools/call', { name: 'files', arguments: decision.updatedInput, _meta: { 'claudecode/toolUseId': toolUseId } });
      const result = called.result;
      said = result.content.map((b) => b.text).join('');
      out({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: toolUseId, content: said, is_error: result.isError === true }] }, parent_tool_use_id: null, session_id: sessionId });
      said = result.isError ? `CYFR refused: ${said}` : `The file says: ${said}`;
    } else {
      said = `Denied: ${decision.message}`;
    }
    reply(said);
  } else if (words.includes('theirs')) {
    // The fake's own wait for every server of theirs (above).
    await ownListed;
    const ran = [];
    for (const name of ownNames) {
      const server = own.get(name);
      if (!server) continue;
      const tool = `mcp__${name}__echo_env`;
      const input = { name: 'THEIR_SERVER' };
      out({ type: 'assistant', message: { id: `msg_${crypto.randomUUID()}`, role: 'assistant', model, content: [{ type: 'tool_use', id: `toolu_fake_${asked + 1}`, name: tool, input }], usage: { input_tokens: 5, output_tokens: 2 } }, parent_tool_use_id: null, session_id: sessionId });
      const { decision, toolUseId } = await ask(tool, input, { name, source: 'user' });
      let answered = 'denied';
      if (decision.behavior === 'allow') {
        const called = await server.request('tools/call', { name: 'echo_env', arguments: decision.updatedInput });
        answered = `given ${JSON.stringify(decision.updatedInput)} answered ${JSON.parse(called.result.content[0].text).value}`;
        out({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: toolUseId, content: answered }] }, parent_tool_use_id: null, session_id: sessionId });
      }
      ran.push(`${tool} ${answered}`);
    }
    reply(`Tools: ${mcpTools().filter((t) => t.endsWith('__echo_env') || t.endsWith('__files')).sort().join(', ')}. ${ran.join('; ')}.`);
  } else if (words.includes('modes')) {
    const ids = [];
    for (const [tool, input] of [['Write', { file_path: 'made.txt', content: 'x' }], ['Bash', { command: 'touch made.txt' }]]) {
      await ask(tool, input);
      ids.push(`ask-${asked}`);
    }
    reply(JSON.stringify({ argv: args, answers: ids.map((id) => wholes.get(id)) }));
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
    } else if (request.subtype === 'mcp_status') {
      const listed = [...ownNames.map((name) => ({ name, status: own.has(name) ? 'connected' : 'pending', scope: 'user', source: 'user' })),
        ...[...servers.keys()].map((name) => ({ name, status: 'connected', scope: 'dynamic', source: 'dynamic' }))];
      out({ type: 'control_response', response: { subtype: 'success', request_id: message.request_id, response: { mcpServers: listed } } });
    } else if (request.subtype === 'mcp_set_servers') {
      setServers(message.request_id, request.servers || {});
    } else {
      out({ type: 'control_response', response: { subtype: 'error', request_id: message.request_id, error: `unsupported ${request.subtype}` } });
    }
  } else if (message.type === 'control_response') {
    const resolve = asks.get(message.response.request_id);
    asks.delete(message.response.request_id);
    wholes.set(message.response.request_id, message);
    resolve?.(message.response.response);
  } else if (message.type === 'user') {
    turns = turns.then(() => turn(message));
  }
}).on('close', () => turns.then(() => {
  stopServers();
  stopServers(own);
  process.exit(0);
}));
