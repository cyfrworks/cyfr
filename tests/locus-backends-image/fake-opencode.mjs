#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// A stand-in for OpenCode's ACP server, `opencode acp`, run under
// cyfr-opencode by brain_opencode.py: it speaks the lines OpenCode 2.4.1
// was probed writing, and keeps its sessions, with its sign-in, in one
// store of its own in its HOME, the kept folder, as OpenCode keeps them in
// its one database.
//
// - Run with `debug config --standalone` it prints its configuration
//   documents as OpenCode does, the person's own server `cyfr` under
//   `mcp.servers` in the home's, its secret value masked.
// - It refuses to start without the one argument a session takes, `acp`.
// - `initialize` answers OpenCode's protocol 1, its version and
//   capabilities (load, resume, close, delete and list of a session) and
//   its steering in its `_meta`.
// - `session/new` answers the session, an id of OpenCode's own form
//   (`ses_` and 26 letters and digits), with its config options: model,
//   effort (category thought_level) only while the model selected has
//   efforts, and mode; then it starts each stdio server its `mcpServers`
//   names (the image's cyfr-stub in socket mode) and lists its tools.
//   `session/resume` of a session the store holds answers the config
//   options alone and replays nothing; `session/load` replays the
//   session's user and agent chunks before its answer; each answers -32602
//   "Invalid params: session not found: <id>" for one the store lacks.
//   `session/delete` removes a session from the store and answers {},
//   whether it held it or not.
// - A prompt is a turn, by the words of its last text block: `hello` runs
//   its own `read` and replies naming the session, the request that opened
//   it in this process, its config, the tools its servers offered, the
//   prompt's text blocks whole, in order, as the session keeps them, and
//   how many prompts the session held before; `read` calls CYFR's `files` from
//   inside its own tool `execute`, as OpenCode calls every MCP tool, and
//   replies with the answer; `slow` streams a first part and waits for a
//   steer. A second prompt while one runs is refused -32603; the steer is
//   `_session/steering`, answered `injected` while a turn runs, its text
//   then read by the turn, and `promptRequired` when none runs. Each reply
//   streams as agent message chunks, then the prompt's answer with its
//   usage: no cache writes, its output without its thoughts. A retry notice
//   (`session_info_update`) comes before each reply. `session/cancel`
//   answers the open prompt `cancelled`.
// - It writes a canary to its stderr, to its folder (its store and what
//   its own tool reads) and to its stand-in sign-in, kept in its store,
//   none of which the driver may pass on.
import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';

if (process.argv.slice(2).join(' ') === 'debug config --standalone') {
  process.stdout.write(JSON.stringify([
    { type: 'document', path: `${process.env.HOME}/.config/opencode/opencode.json`,
      info: { mcp: { servers: { cyfr: { type: 'local', command: ['node', 'theirs.mjs'], environment: { TOKEN: '***' } } } } } },
    { type: 'directory', path: `${process.env.HOME}/.config/opencode` },
  ], null, 2) + '\n');
  process.exit(0);
}
if (process.argv.slice(2).join(' ') !== 'acp') {
  process.stderr.write(`fake-opencode: started with ${process.argv.slice(2).join(' ')}, not acp\n`);
  process.exit(2);
}

const home = process.env.HOME;
const data = path.join(home, '.local', 'share', 'opencode');
fs.mkdirSync(data, { recursive: true });
// The store: one JSON file of the sign-in and every session, by id.
const storeFile = path.join(data, 'opencode.db');
const SIGNIN = { provider: 'probe', key: 'FAKE-SIGNIN-CANARY the key a person connected' };
const readStore = () => (fs.existsSync(storeFile) ? JSON.parse(fs.readFileSync(storeFile, 'utf8')) : { signin: SIGNIN, sessions: {} });
const writeStore = (store) => fs.writeFileSync(storeFile, JSON.stringify(store));
if (!fs.existsSync(storeFile)) writeStore(readStore());
fs.writeFileSync(path.join(home, 'notes.md'), 'FAKE-FOLDER-CANARY the notes OpenCode reads with its own tool\n');
process.stderr.write('FAKE-STDERR-CANARY OpenCode writes this to its stderr\n');

const MODELS = [['opencode/big-pickle', 'opencode/Big Pickle'], ['probe/think', 'probe/Think'], ['probe/plain', 'probe/Plain']];
const EFFORTS = { 'probe/think': [['low', 'Low'], ['medium', 'Medium'], ['high', 'High'], ['default', 'Default']], 'probe/plain': [['default', 'Default']] };
const MODES = [['build', 'Build'], ['plan', 'Plan']];
const current = { model: 'opencode/big-pickle', effort: 'default', mode: 'build' };

const out = (message) => process.stdout.write(JSON.stringify(message) + '\n');
const answer = (id, result) => out({ jsonrpc: '2.0', id, result });
const fail = (id, code, message, data) => out({ jsonrpc: '2.0', id, error: { code, message, ...(data ? { data } : {}) } });
const notFound = (id, sessionId) => fail(id, -32602, `Invalid params: session not found: ${sessionId}`, { sessionId });

let session = null;
let openedBy = '';
const update = (u) => out({ jsonrpc: '2.0', method: 'session/update', params: { sessionId: session.id, update: u } });

function options() {
  const option = (id, name, category, choices) => ({ id, name, category, type: 'select', currentValue: current[id],
    options: choices.map(([value, label]) => ({ value, name: label })) });
  const list = [option('model', 'Model', 'model', MODELS)];
  if (EFFORTS[current.model]) list.push(option('effort', 'Effort', 'thought_level', EFFORTS[current.model]));
  list.push(option('mode', 'Session Mode', 'mode', MODES));
  return list;
}

function save() {
  const store = readStore();
  store.sessions[session.id] = session;
  writeStore(store);
}

// ---- MCP servers, started as OpenCode starts the stdio servers a session names ----
const servers = new Map();

function startServer(entry) {
  const env = { ...process.env };
  for (const { name, value } of entry.env || []) env[name] = value;
  const child = spawn(entry.command, entry.args || [], { stdio: ['pipe', 'pipe', 'ignore'], env });
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
  server.request('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'opencode', version: '2.4.1' } })
    .then(() => {
      send({ method: 'notifications/initialized' });
      return server.request('tools/list', {});
    })
    .then((listed) => { server.tools = listed.result?.tools || []; });
  servers.set(entry.name, server);
}

function stopServers() {
  for (const server of servers.values()) server.child.stdin.end();
  servers.clear();
}

const offered = () => [...servers.entries()].flatMap(([name, s]) => s.tools.map((t) => `tools.${name}.${t.name}`));

// ---- A turn ----
let active = null;
let steered = null;
// The message a turn's reply streams under, one id for each message.
let messageId = null;
const usage = (text) => ({ inputTokens: 12, outputTokens: text.length + 1, thoughtTokens: 3, cachedReadTokens: 5, totalTokens: 21 + text.length });

function finish(result) {
  const id = active;
  active = null;
  if (id !== null) answer(id, result);
}

function reply(text) {
  update({ sessionUpdate: 'session_info_update', _meta: { 'opencode/retry': { attempt: 2, error: { type: 'provider.transport', message: 'FAKE-FOLDER-CANARY a retry' } } } });
  update({ sessionUpdate: 'session_info_update', _meta: { 'opencode/retry': null } });
  const half = Math.ceil(text.length / 2);
  messageId ??= `msg_${crypto.randomBytes(12).toString('hex')}`;
  for (const piece of [text.slice(0, half), text.slice(half)]) {
    update({ sessionUpdate: 'agent_message_chunk', messageId, content: { type: 'text', text: piece } });
  }
  session.history[session.history.length - 1].agent += text;
  save();
  messageId = null;
  update({ sessionUpdate: 'usage_update', used: 20 + text.length, size: 200000, cost: { amount: 0, currency: 'USD' } });
  finish({ stopReason: 'end_turn', usage: usage(text), _meta: {} });
}

function toolCall(id, name, kind, rawInput) {
  update({ sessionUpdate: 'tool_call', toolCallId: id, name, title: name, kind, status: 'pending', locations: [], rawInput: {} });
  update({ sessionUpdate: 'tool_call_update', toolCallId: id, name, title: name, kind, status: 'in_progress', rawInput });
  return () => update({ sessionUpdate: 'tool_call_update', toolCallId: id, status: 'completed' });
}

async function turn(words, texts, earlier) {
  if (words.includes('hello')) {
    const end = toolCall(`call_${crypto.randomInt(2 ** 47)}`, 'read', 'read', { path: path.join(home, 'notes.md') });
    fs.readFileSync(path.join(home, 'notes.md'), 'utf8');
    end();
    reply(`Hello from the fake OpenCode: session ${session.id}, opened by ${openedBy}, model ${current.model}, effort ${current.effort}, mode ${current.mode}, `
      + `tools ${offered().join(',')}, earlier ${earlier}, texts ${JSON.stringify(session.history[session.history.length - 1].texts)}.`);
  } else if (words.includes('read')) {
    const server = [...servers.entries()].find(([, s]) => s.tools.some((t) => t.name === 'files'));
    if (!server) return reply('No files tool was offered.');
    const [name, held] = server;
    const end = toolCall(`call_${crypto.randomInt(2 ** 47)}`, 'execute', 'other', { code: `return await tools.${name}.files({action: 'read', path: 'notes.txt'})` });
    const called = await held.request('tools/call', { name: 'files', arguments: { action: 'read', path: 'notes.txt' } });
    end();
    const said = (called.result?.content || []).map((b) => b.text).join('');
    reply(called.result?.isError ? `CYFR refused: ${said}` : `The file says: ${said}`);
  } else if (words.includes('slow')) {
    messageId = `msg_${crypto.randomBytes(12).toString('hex')}`;
    update({ sessionUpdate: 'agent_message_chunk', messageId, content: { type: 'text', text: 'Starting' } });
    const steer = await Promise.race([new Promise((resolve) => { steered = resolve; }), new Promise((resolve) => setTimeout(() => resolve(null), 20000))]);
    steered = null;
    reply(steer === null ? ' No steer came.' : ` Read the steer: ${steer}`);
  } else {
    reply('ok');
  }
}

const textsOf = (prompt) => (prompt || []).filter((b) => b.type === 'text').map((b) => b.text);

// ---- The client's lines ----
let turns = Promise.resolve();
readline.createInterface({ input: process.stdin }).on('line', (line) => {
  const message = JSON.parse(line);
  const p = message.params || {};
  if (message.method === undefined) return undefined;
  const held = (id) => typeof id === 'string' && readStore().sessions[id] !== undefined;
  switch (message.method) {
    case 'initialize':
      return answer(message.id, { protocolVersion: 1, agentCapabilities: { loadSession: true, mcpCapabilities: { http: true, sse: false },
        promptCapabilities: { embeddedContext: true, image: true },
        sessionCapabilities: { additionalDirectories: {}, close: {}, delete: {}, fork: {}, list: {}, resume: {} }, _meta: { 'opencode/child-session-updates': true } },
      authMethods: [{ description: 'Run `opencode auth login` in the terminal', name: 'Login with opencode', id: 'opencode-login' }],
      _meta: { steering: { supported: true } }, agentInfo: { name: 'OpenCode', version: '2.4.1' } });
    case 'session/new':
      session = { id: `ses_${crypto.randomBytes(13).toString('hex')}`, history: [] };
      save();
      openedBy = 'new';
      answer(message.id, { sessionId: session.id, configOptions: options() });
      return (p.mcpServers || []).forEach(startServer);
    case 'session/resume':
      if (!held(p.sessionId)) return notFound(message.id, p.sessionId);
      session = readStore().sessions[p.sessionId];
      openedBy = 'resume';
      answer(message.id, { configOptions: options() });
      return (p.mcpServers || []).forEach(startServer);
    case 'session/load':
      if (!held(p.sessionId)) return notFound(message.id, p.sessionId);
      session = readStore().sessions[p.sessionId];
      for (const { user, agent } of session.history) {
        update({ sessionUpdate: 'user_message_chunk', content: { type: 'text', text: user } });
        if (agent) update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: agent } });
      }
      openedBy = 'load';
      answer(message.id, { configOptions: options() });
      return (p.mcpServers || []).forEach(startServer);
    case 'session/delete': {
      const store = readStore();
      delete store.sessions[p.sessionId];
      writeStore(store);
      return answer(message.id, {});
    }
    case 'session/set_config_option': {
      const choices = { model: MODELS, effort: EFFORTS[current.model] || [], mode: MODES }[p.configId];
      if (!session || p.sessionId !== session.id || !choices?.some(([value]) => value === p.value)) return fail(message.id, -32602, `Invalid params: ${p.configId} not found: ${p.value}`);
      current[p.configId] = p.value;
      if (p.configId === 'model') current.effort = 'default';
      return answer(message.id, { configOptions: options() });
    }
    case 'session/prompt': {
      if (!session || p.sessionId !== session.id) return notFound(message.id, p.sessionId);
      if (active !== null) return fail(message.id, -32603, `Internal error: Session already has an active ACP prompt: ${session.id}`, { service: 'session' });
      const texts = textsOf(p.prompt);
      const words = texts[texts.length - 1] ?? '';
      const earlier = session.history.length;
      session.history.push({ user: words, texts, agent: '' });
      save();
      active = message.id;
      turns = turns.then(() => turn(words, texts, earlier));
      return undefined;
    }
    case '_session/steering': {
      if (active === null || steered === null) return answer(message.id, { outcome: 'promptRequired', reason: 'noRunningTurn' });
      const texts = textsOf(p.prompt);
      session.history.push({ user: texts[texts.length - 1] ?? '', agent: '' });
      answer(message.id, { outcome: 'injected' });
      steered(texts[texts.length - 1] ?? '');
      return undefined;
    }
    case 'session/cancel':
      return finish({ stopReason: 'cancelled', _meta: {} });
    case 'session/close':
      return answer(message.id, {});
    default:
      if (message.id !== undefined) return fail(message.id, -32601, `"Method not found": ${message.method}`, { method: message.method });
      return undefined;
  }
}).on('close', () => {
  stopServers();
  process.exit(0);
});
