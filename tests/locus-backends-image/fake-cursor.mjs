#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// A stand-in for Cursor's agent, `agent acp`, run under cyfr-cursor by
// brain_cursor.py: it speaks the lines Cursor 2026.11.22-e9042b2 was
// probed writing, and keeps each session as a folder of its own in its
// HOME, the kept folder, `.cursor/acp-sessions/<id>/`, as Cursor does.
//
// - Run with `mcp list` it prints its servers as Cursor does, one
//   `<name>: <status>` a line, the person's own server `cyfr` among them,
//   and counts each listing in `.cursor/listings`.
// - It refuses to start without `acp` as its last argument.
// - `initialize` answers protocol 1, a load of a session and a list of
//   them, and names no version and no resume.
// - `session/new` answers a UUID session with its config options, mode
//   (agent, plan, ask) and model, each model a value with its parameters,
//   and starts each stdio server its `mcpServers` names (the image's
//   cyfr-stub in socket mode), which lists its tools only at the session's
//   first prompt. `session/load` replays the session's user and agent
//   chunks before its answer, and answers -32602 "Invalid params" with
//   `Session "<id>" not found` in its data for a session it lacks.
//   Neither `session/close` nor `session/delete` is answered but as a
//   method not found.
// - A prompt is a turn, by the words of its last text block: `hello` runs
//   its own `read` and replies naming the session, the request that opened
//   it in this process, its model and mode, the tools its servers listed,
//   the prompt's text blocks whole and how many prompts the session held
//   before; `read` calls CYFR's `files` as Cursor calls a server's tool,
//   announced with no input, then shown with its server, tool and
//   arguments, asked with session/request_permission; `fail` writes the
//   chunk Cursor wrote on a dead network, alone; `slow` streams a first
//   part and waits. A prompt while one runs cancels it. No answer carries
//   usage. `session/cancel` answers the open prompt `cancelled`.
// - Its input closing does not end it, as Cursor's does not.
// - It writes a canary to its stderr, to its folder and to its stand-in
//   sign-in, `.config/cursor/auth.json`, none of which the driver may pass
//   on.
import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';

const home = process.env.HOME;
const config = path.join(home, '.cursor');
fs.mkdirSync(config, { recursive: true });
const args = process.argv.slice(2);
if (args.join(' ').endsWith('mcp list')) {
  fs.appendFileSync(path.join(config, 'listings'), 'list\n');
  process.stdout.write('cyfr: ready\nnotes: not loaded (needs approval)\n');
  process.exit(0);
}
if (args[args.length - 1] !== 'acp') {
  process.stderr.write(`fake-cursor: started with ${args.join(' ')}, not acp\n`);
  process.exit(2);
}

const sessions = path.join(config, 'acp-sessions');
fs.mkdirSync(sessions, { recursive: true });
fs.mkdirSync(path.join(home, '.config', 'cursor'), { recursive: true });
fs.writeFileSync(path.join(home, '.config', 'cursor', 'auth.json'), JSON.stringify({ accessToken: 'FAKE-SIGNIN-CANARY the access token' }));
fs.writeFileSync(path.join(home, 'notes.md'), 'FAKE-FOLDER-CANARY the notes Cursor reads with its own tool\n');
process.stderr.write('FAKE-STDERR-CANARY Cursor writes this to its stderr\n');

const MODELS = [['default[]', 'Auto'], ['claude-opus-5-5[context=300k,effort=medium,fast=false]', 'claude-opus-5-5']];
const MODES = [['agent', 'Agent'], ['plan', 'Plan'], ['ask', 'Ask']];
const current = { model: 'default[]', mode: 'agent' };

const out = (message) => process.stdout.write(JSON.stringify(message) + '\n');
const answer = (id, result) => out({ jsonrpc: '2.0', id, result });
const fail = (id, code, message, data) => out({ jsonrpc: '2.0', id, error: { code, message, ...(data ? { data } : {}) } });

let session = null;
let openedBy = '';
const update = (u) => out({ jsonrpc: '2.0', method: 'session/update', params: { sessionId: session.id, update: u } });
const folder = (id) => path.join(sessions, id);
const held = (id) => typeof id === 'string' && /^[0-9a-f-]{36}$/.test(id) && fs.existsSync(path.join(folder(id), 'store.db'));
const save = () => {
  fs.mkdirSync(folder(session.id), { recursive: true });
  fs.writeFileSync(path.join(folder(session.id), 'store.db'), JSON.stringify(session));
  fs.writeFileSync(path.join(folder(session.id), 'meta.json'), JSON.stringify({ schemaVersion: 1, cwd: home, title: 'FAKE-FOLDER-CANARY a title' }));
};
const options = () => [
  { id: 'mode', name: 'Mode', category: 'mode', type: 'select', currentValue: current.mode, options: MODES.map(([value, name]) => ({ value, name })) },
  { id: 'model', name: 'Model', category: 'model', type: 'select', currentValue: current.model, options: MODELS.map(([value, name]) => ({ value, name })) },
];

// ---- MCP servers, started with the session, listed at its first prompt ----
const servers = new Map();
let listed = false;

function startServer(entry) {
  const child = spawn(entry.command, entry.args || [], { stdio: ['pipe', 'pipe', 'ignore'], env: process.env });
  const server = { child, tools: [], next: 0, waiting: new Map() };
  child.on('error', () => {});
  readline.createInterface({ input: child.stdout }).on('line', (line) => {
    const message = JSON.parse(line);
    server.waiting.get(message.id)?.(message);
    server.waiting.delete(message.id);
  });
  const send = (message) => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...message }) + '\n');
  server.request = (method, params) => new Promise((done) => {
    const id = server.next++;
    server.waiting.set(id, done);
    send({ id, method, params });
  });
  server.ready = server.request('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'cursor', version: '1' } })
    .then(() => send({ method: 'notifications/initialized' }));
  servers.set(entry.name, server);
}

async function listTools() {
  if (listed) return;
  listed = true;
  for (const server of servers.values()) {
    await server.ready;
    server.tools = (await server.request('tools/list', {})).result?.tools || [];
  }
}

const offered = () => [...servers.entries()].flatMap(([name, s]) => s.tools.map((t) => `${name}:${t.name}`));

// ---- A turn ----
let active = null;
let cancelled = null;

function finish(stopReason) {
  const id = active;
  active = null;
  if (id !== null) answer(id, { stopReason });
}

function reply(text) {
  const half = Math.ceil(text.length / 2);
  for (const piece of [text.slice(0, half), text.slice(half)]) {
    update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: piece } });
  }
  session.history[session.history.length - 1].agent += text;
  save();
  finish('end_turn');
}

async function turn(words, texts, earlier) {
  await listTools();
  if (words.includes('hello')) {
    update({ sessionUpdate: 'tool_call', toolCallId: 'call-read\nfc_0', title: 'Read File', kind: 'read', status: 'pending', rawInput: {} });
    fs.readFileSync(path.join(home, 'notes.md'), 'utf8');
    update({ sessionUpdate: 'tool_call_update', toolCallId: 'call-read\nfc_0', status: 'completed', rawOutput: { success: true } });
    reply(`Hello from the fake Cursor: session ${session.id}, opened by ${openedBy}, model ${current.model}, mode ${current.mode}, `
      + `tools ${offered().join(',')}, earlier ${earlier}, texts ${JSON.stringify(texts)}.`);
  } else if (words.includes('read')) {
    const found = [...servers.entries()].find(([, s]) => s.tools.some((t) => t.name === 'files'));
    if (!found) return reply('No files tool was offered.');
    const [name, server] = found;
    const id = `call-${crypto.randomUUID()}\nfc_1`;
    const args = { action: 'read', path: 'notes.txt' };
    update({ sessionUpdate: 'tool_call', toolCallId: id, title: 'MCP: tool', kind: 'other', status: 'pending', rawInput: {} });
    update({ sessionUpdate: 'tool_call_update', toolCallId: id, title: `${name}: files`, rawInput: { providerIdentifier: name, toolName: 'files', args } });
    update({ sessionUpdate: 'tool_call_update', toolCallId: id, status: 'in_progress' });
    out({ jsonrpc: '2.0', id: 0, method: 'session/request_permission', params: { sessionId: session.id,
      toolCall: { toolCallId: id, title: `${name}-files: files`, kind: 'other', status: 'pending' },
      options: [{ optionId: 'allow-once', name: 'Allow once', kind: 'allow_once' }, { optionId: 'allow-always', name: 'Allow always', kind: 'allow_always' },
        { optionId: 'reject-once', name: 'Reject', kind: 'reject_once' }] } });
    const called = await server.request('tools/call', { name: 'files', arguments: args });
    update({ sessionUpdate: 'tool_call_update', toolCallId: id, status: 'completed', rawOutput: { success: true } });
    const said = (called.result?.content || []).map((b) => b.text).join('');
    reply(called.result?.isError ? `CYFR refused: ${said}` : `The file says: ${said}`);
  } else if (words.includes('fail')) {
    update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: '\n\nError: RetriableError: [unavailable] getaddrinfo EAI_AGAIN agentn.global.api5.cursor.sh' } });
    finish('end_turn');
  } else if (words.includes('slow')) {
    update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'Starting' } });
    const stop = await Promise.race([new Promise((resolve) => { cancelled = resolve; }), new Promise((resolve) => setTimeout(() => resolve(null), 3000))]);
    cancelled = null;
    if (stop === null) reply(' and done.');
  } else {
    reply('ok');
  }
  return undefined;
}

const textsOf = (prompt) => (prompt || []).filter((b) => b.type === 'text').map((b) => b.text);

// ---- The client's lines ----
let turns = Promise.resolve();
readline.createInterface({ input: process.stdin }).on('line', (line) => {
  const message = JSON.parse(line);
  const p = message.params || {};
  if (message.method === undefined) return undefined;
  switch (message.method) {
    case 'initialize':
      return answer(message.id, { protocolVersion: 1, agentCapabilities: { loadSession: true, mcpCapabilities: { http: true, sse: true },
        promptCapabilities: { audio: false, embeddedContext: false, image: true }, sessionCapabilities: { list: {} } },
      authMethods: [{ id: 'cursor_login', name: 'Cursor Login', description: "Run 'agent login' first if not logged in." }] });
    case 'session/new':
      session = { id: crypto.randomUUID(), history: [] };
      save();
      openedBy = 'new';
      (p.mcpServers || []).forEach(startServer);
      return answer(message.id, { sessionId: session.id, modes: { currentModeId: current.mode, availableModes: [] }, configOptions: options(),
        models: { currentModelId: current.model, availableModels: [] } });
    case 'session/load':
      if (!held(p.sessionId)) return fail(message.id, -32602, 'Invalid params', { message: `Session "${p.sessionId}" not found` });
      session = JSON.parse(fs.readFileSync(path.join(folder(p.sessionId), 'store.db'), 'utf8'));
      openedBy = 'load';
      (p.mcpServers || []).forEach(startServer);
      for (const { user, agent } of session.history) {
        update({ sessionUpdate: 'user_message_chunk', content: { type: 'text', text: user } });
        if (agent) update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: agent } });
      }
      return answer(message.id, { modes: { currentModeId: current.mode, availableModes: [] }, configOptions: options(),
        models: { currentModelId: current.model, availableModels: [] } });
    case 'session/set_config_option': {
      const choices = { model: MODELS, mode: MODES }[p.configId];
      if (!session || p.sessionId !== session.id || !choices?.some(([value]) => value === p.value)) return fail(message.id, -32602, 'Invalid params');
      current[p.configId] = p.value;
      return answer(message.id, { configOptions: options() });
    }
    case 'session/prompt': {
      if (!session || p.sessionId !== session.id) return fail(message.id, -32603, 'Internal error', { details: `Session ${p.sessionId} not found` });
      if (active !== null) {
        // A prompt while one runs cancels it, as Cursor's handlePrompt does.
        cancelled?.('cancel');
        finish('cancelled');
      }
      const texts = textsOf(p.prompt);
      const words = texts[texts.length - 1] ?? '';
      const earlier = session.history.length;
      session.history.push({ user: words, agent: '' });
      save();
      active = message.id;
      turns = turns.then(() => turn(words, texts, earlier));
      return undefined;
    }
    case 'session/cancel':
      cancelled?.('cancel');
      return finish('cancelled');
    default:
      if (message.id !== undefined) return fail(message.id, -32601, `"Method not found": ${message.method}`, { method: message.method });
      return undefined;
  }
});
// Cursor's agent does not end when its input does: the driver's stop ends it.
