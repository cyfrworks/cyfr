#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// A stand-in for Antigravity's ACP server, `agy acp`, run under
// cyfr-antigravity by brain_antigravity.py: it speaks the lines agy 1.5.16
// was probed writing, and keeps its sessions in its HOME, the kept folder,
// as agy does.
//
// - It refuses to start without the one argument a session takes, `acp`.
// - `initialize` answers agy's protocol 1, its version and capabilities:
//   load, resume, close and list of a session, and a place for one
//   process's instructions (`_meta.antigravity.systemPrompt.append`).
// - `session/new` answers the session with its models, modes and config
//   options (model, thought_level, mode; each model's efforts are the
//   available models named `<model>-<effort>`) and the account's tier in
//   its `_meta`, then starts each stdio server its `mcpServers` names (the
//   image's cyfr-stub in socket mode), speaks MCP to it as agy does
//   (`server/discover`, `initialize`, `tools/list`) and offers its tools as
//   `mcp_<server>_<tool>`. `session/resume` of a session the folder holds
//   does the same and replays nothing; of one it lacks it answers -32603
//   "Failed to read session <id>; retry, or load it with session/load".
//   `session/load` replays the session's user and agent chunks before its
//   answer, and answers -32002 "Session not found: <id>" for one it lacks.
//   With FAKE_RESUME_FAILS=1 every resume answers that -32603, so the
//   driver loads.
// - A prompt is a turn, by the words of its last text block: `hello` runs
//   its own `read_file` and replies naming the session, the request that
//   opened it in this process, its config, the
//   tools its servers offered, the prompt's text blocks, how many prompts
//   the session held before and the appended instructions; `read` calls
//   CYFR's `files` through its server after its permission question
//   (`session/request_permission`), the call's arguments without the
//   `toolSummary` agy adds, and replies with the answer; `slow` streams a
//   first part and waits for a second prompt, which steers the turn: the
//   earlier prompt answers `end_turn` at once, with no usage, or with the
//   counts so far while a call of a server's is open (as agy 1.5.16 was
//   measured answering, in both orders), and the turn replies naming the
//   steer. Each reply streams as agent message chunks,
//   then the prompt's answer with its usage. `session/cancel` answers the
//   open prompt `cancelled`.
// - Each session's files are agy's: `~/.gemini/antigravity-cli/brain/<id>/`,
//   `conversations/<id>.db` (here the fake's own JSON of the session) and
//   `annotations/<id>.pbtxt`, and each session is added to the index every
//   session shares, `conversation_summaries.db` and
//   `jetbox_summaries_proto.pb`.
// - It writes a canary to its stderr, to its folder (its session files and
//   what its own tool reads) and to its tier, and keeps a stand-in sign-in,
//   `~/.gemini/oauth_creds.json`, none of which the driver may pass on.
import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';

if (process.argv.slice(2).join(' ') !== 'acp') {
  process.stderr.write(`fake-acp: started with ${process.argv.slice(2).join(' ')}, not acp\n`);
  process.exit(2);
}

const home = process.env.HOME;
const gemini = path.join(home, '.gemini');
const cli = path.join(gemini, 'antigravity-cli');
for (const dir of ['brain', 'conversations', 'annotations']) fs.mkdirSync(path.join(cli, dir), { recursive: true });
const signin = path.join(gemini, 'oauth_creds.json');
if (!fs.existsSync(signin)) fs.writeFileSync(signin, '{"FAKE-SIGNIN-CANARY": "the sign-in a person made"}\n');
fs.writeFileSync(path.join(home, 'notes.md'), 'FAKE-FOLDER-CANARY the notes agy reads with its own tool\n');
process.stderr.write('FAKE-STDERR-CANARY Antigravity writes this to its stderr\n');
const resumeFails = process.env.FAKE_RESUME_FAILS === '1';

const CAPABILITIES = {
  loadSession: true, load_session: true,
  promptCapabilities: { image: true, audio: false, embeddedContext: true },
  sessionCapabilities: { resume: {}, close: {}, load: {}, list: {}, additionalDirectories: {} },
  session_capabilities: { resume: {}, close: {}, load: {}, list: {}, additionalDirectories: {} },
  auth: { logout: {} },
  _meta: { antigravity: { tier: true, systemPrompt: { append: true } } },
};
const MODELS = [['gemini-4-neon', 'Gemini 4 Neon'], ['gemini-3.8-flash', 'Gemini 3.8 Flash'], ['gpt-oss-120b-medium', 'GPT-OSS 120B (Medium)']];
const LEVELS = [['low', 'Low'], ['medium', 'Medium'], ['high', 'High'], ['xhigh', 'Extra']];
const MODES = [['default', 'Default'], ['accept-edits', 'Accept edits'], ['auto', 'Auto'], ['plan', 'Plan']];
const VARIANTS = ['gemini-4-neon-high', 'gemini-4-neon-xhigh', 'gemini-4-neon-medium', 'gemini-4-neon-low',
  'gemini-3.8-flash-high', 'gemini-3.8-flash-medium', 'gemini-3.8-flash-low', 'gpt-oss-120b-medium'];
const CHOICES = { model: MODELS, thought_level: LEVELS, mode: MODES };
const current = { model: 'gemini-4-neon', thought_level: 'high', mode: 'default' };

const out = (message) => process.stdout.write(JSON.stringify(message) + '\n');
const answer = (id, result) => out({ jsonrpc: '2.0', result, id });
const fail = (id, code, message) => out({ jsonrpc: '2.0', error: { code, message }, id });

// The session this process holds, and the instructions its session
// request appended.
let session = null;
let appended = '';
let openedBy = '';
const update = (u) => out({ jsonrpc: '2.0', method: 'session/update', params: { sessionId: session.id, update: u } });

// agy's own requests of the client, by string ids from "1".
let asked = 0;
const waiting = new Map();
function ask(method, params) {
  const id = String(++asked);
  out({ jsonrpc: '2.0', method, params, id });
  return new Promise((resolve) => waiting.set(id, resolve));
}

function options() {
  return Object.entries(CHOICES).map(([id, choices]) => ({
    id, name: { model: 'Model', thought_level: 'Thinking Level', mode: 'Mode' }[id], category: id, type: 'select',
    currentValue: current[id], options: choices.map(([value, name]) => ({ value, name })),
  }));
}

function sessionResult() {
  const variant = `${current.model}-${current.thought_level}`;
  return {
    sessionId: session.id,
    modes: { currentModeId: current.mode, availableModes: MODES.map(([id, name]) => ({ id, name, description: name })) },
    models: { availableModels: VARIANTS.map((modelId) => ({ modelId, name: modelId })), currentModelId: VARIANTS.includes(variant) ? variant : current.model },
    configOptions: options(),
    _meta: { antigravity: { tier: { name: 'FAKE-TIER-CANARY' } } },
  };
}

// ---- A session's files ----
const conversation = (id) => path.join(cli, 'conversations', `${id}.db`);
const holds = (id) => typeof id === 'string' && fs.existsSync(conversation(id));

function save() {
  fs.writeFileSync(conversation(session.id), JSON.stringify(session));
}

function made(id) {
  session = { id, history: [] };
  const logs = path.join(cli, 'brain', id, '.system_generated', 'logs');
  fs.mkdirSync(logs, { recursive: true });
  fs.writeFileSync(path.join(logs, 'transcript.jsonl'), '');
  fs.writeFileSync(path.join(cli, 'annotations', `${id}.pbtxt`), 'FAKE-FOLDER-CANARY an annotation of the session\n');
  for (const index of ['conversation_summaries.db', 'jetbox_summaries_proto.pb']) {
    fs.appendFileSync(path.join(cli, index), `${id} FAKE-FOLDER-CANARY the session's title and summary\n`);
  }
  save();
}

function heard(words, post) {
  session.history.push({ user: words, agent: '' });
  fs.appendFileSync(path.join(cli, 'brain', session.id, '.system_generated', 'logs', 'transcript.jsonl'),
    JSON.stringify({ user: words, post }) + '\n');
  save();
}

// ---- MCP servers, as agy starts the stdio servers a session names ----
const servers = new Map();

function startServer(entry) {
  const env = { ...process.env };
  for (const { name, value } of entry.env || []) env[name] = value;
  const child = spawn(entry.command, entry.args || [], { stdio: ['pipe', 'pipe', 'ignore'], env });
  const server = { child, tools: [], next: 1, waiting: new Map() };
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
  server.request('server/discover', {})
    .then(() => server.request('initialize', { protocolVersion: '2025-06-18', capabilities: { roots: { listChanged: true } }, clientInfo: { name: 'antigravity', version: '1.5.16' } }))
    .then(() => {
      send({ method: 'notifications/initialized' });
      return server.request('tools/list', {});
    })
    .then((listed) => {
      server.tools = listed.result?.tools || [];
      send({ method: 'notifications/roots/list_changed' });
    });
  servers.set(entry.name, server);
}

function stopServers() {
  for (const server of servers.values()) server.child.stdin.end();
  servers.clear();
}

const offered = () => [...servers.entries()].flatMap(([name, s]) => s.tools.map((t) => `mcp_${name}_${t.name}`));

// ---- A turn ----
let active = null;
let steered = null;
let callOpen = false;
const usage = (text) => ({ inputTokens: 12, outputTokens: text.length + 1, cachedReadTokens: 5, cachedWriteTokens: 2, thoughtTokens: 1, totalTokens: 20 + text.length });

function finish(result) {
  const id = active;
  active = null;
  if (id !== null) answer(id, result);
}

function reply(text) {
  const half = Math.ceil(text.length / 2);
  for (const piece of [text.slice(0, half), text.slice(half)]) {
    update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: piece } });
  }
  session.history[session.history.length - 1].agent += text;
  save();
  update({ sessionUpdate: 'usage_update', used: 20 + text.length, size: 1048576 });
  finish({ stopReason: 'end_turn', usage: usage(text) });
}

async function turn(words, params, earlier) {
  if (earlier === 0) {
    update({ sessionUpdate: 'available_commands_update', availableCommands: [{ name: 'goal', description: 'Run until the specified goal is completely finished.' }] });
    update({ sessionUpdate: 'usage_update', used: 0, size: 1048576 });
    update({ sessionUpdate: 'session_info_update', title: 'FAKE-FOLDER-CANARY a title' });
  }
  if (words.includes('hello')) {
    const where = path.join(home, 'notes.md');
    const call = { sessionUpdate: 'tool_call', toolCallId: `call_${crypto.randomInt(2 ** 47)}`, name: 'read_file', args: { Path: where }, status: 'in_progress',
      kind: 'read', title: 'File notes.md', locations: [{ path: where }], rawInput: { Path: where } };
    update(call);
    const read = fs.readFileSync(where, 'utf8');
    update({ ...call, sessionUpdate: 'tool_call_update', status: 'completed', rawOutput: read, content: [{ type: 'content', content: { type: 'text', text: read } }] });
    const blocks = params.prompt.filter((b) => b.type === 'text').length;
    reply(`Hello from the fake Antigravity: session ${session.id}, opened by ${openedBy}, model ${current.model}, effort ${current.thought_level}, mode ${current.mode}, `
      + `tools ${offered().join(',')}, blocks ${blocks}, earlier ${earlier}, instructions "${appended}".`);
  } else if (words.includes('read')) {
    const server = [...servers.entries()].find(([, s]) => s.tools.some((t) => t.name === 'files'));
    if (!server) return reply('No files tool was offered.');
    const [name, held] = server;
    const args = { action: 'read', path: 'notes.txt' };
    const call = { sessionUpdate: 'tool_call', toolCallId: `call_${crypto.randomInt(2 ** 47)}`, name: `mcp_${name}_files`, args: { ...args, toolSummary: 'Read notes' },
      status: 'in_progress', kind: 'other', title: `Run mcp_${name}_files`, rawInput: { ...args, toolSummary: 'Read notes' } };
    update(call);
    callOpen = true;
    update({ ...call, sessionUpdate: 'tool_call_update', status: 'pending' });
    const permission = await ask('session/request_permission', { sessionId: session.id, toolCall: { ...call, status: 'pending' },
      options: [{ optionId: 'allow', name: 'Allow', kind: 'allow_once' }, { optionId: 'deny', name: 'Deny', kind: 'reject_once' }] });
    if (permission.result?.outcome?.optionId !== 'allow') {
      callOpen = false;
      update({ ...call, sessionUpdate: 'tool_call_update', status: 'failed' });
      return reply('The call was not allowed.');
    }
    update({ ...call, sessionUpdate: 'tool_call_update', status: 'in_progress' });
    const called = await held.request('tools/call', { name: 'files', arguments: args });
    callOpen = false;
    update({ ...call, sessionUpdate: 'tool_call_update', status: 'completed' });
    const said = (called.result?.content || []).map((b) => b.text).join('');
    reply(called.result?.isError ? `CYFR refused: ${said}` : `The file says: ${said}`);
  } else if (words.includes('slow')) {
    update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'Starting' } });
    const steer = await Promise.race([new Promise((resolve) => { steered = resolve; }), new Promise((resolve) => setTimeout(() => resolve(null), 20000))]);
    steered = null;
    reply(steer === null ? ' No steer came.' : ` Read the steer: ${steer}`);
  } else {
    reply('ok');
  }
}

// ---- The client's lines ----
let turns = Promise.resolve();
readline.createInterface({ input: process.stdin }).on('line', (line) => {
  const message = JSON.parse(line);
  const p = message.params || {};
  if (message.method === undefined) {
    waiting.get(String(message.id))?.(message);
    waiting.delete(String(message.id));
    return;
  }
  const opened = (how) => {
    openedBy = how;
    appended = p._meta?.antigravity?.systemPrompt?.append ?? '';
    answer(message.id, sessionResult());
  };
  switch (message.method) {
    case 'initialize':
      return answer(message.id, { protocolVersion: 1, agentCapabilities: CAPABILITIES, agentInfo: { name: 'Antigravity ACP Server', version: '1.5.16' },
        authMethods: [{ id: 'oauth-personal', name: 'Log in with Google', description: 'Log in with your Google account' }] });
    case 'session/new':
      made(crypto.randomUUID());
      opened('new');
      return (p.mcpServers || []).forEach(startServer);
    case 'session/resume':
      if (resumeFails || !holds(p.sessionId)) return fail(message.id, -32603, `Failed to read session ${p.sessionId}; retry, or load it with session/load`);
      session = JSON.parse(fs.readFileSync(conversation(p.sessionId), 'utf8'));
      opened('resume');
      return (p.mcpServers || []).forEach(startServer);
    case 'session/load':
      if (!holds(p.sessionId)) return fail(message.id, -32002, `Session not found: ${p.sessionId}`);
      session = JSON.parse(fs.readFileSync(conversation(p.sessionId), 'utf8'));
      for (const { user, agent } of session.history) {
        update({ sessionUpdate: 'user_message_chunk', content: { type: 'text', text: user } });
        if (agent) update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: agent } });
      }
      opened('load');
      update({ sessionUpdate: 'session_info_update', title: 'FAKE-FOLDER-CANARY a title' });
      return (p.mcpServers || []).forEach(startServer);
    case 'session/set_config_option': {
      const choices = CHOICES[p.configId];
      if (!session || p.sessionId !== session.id || !choices?.some(([value]) => value === p.value)) return fail(message.id, -32602, 'Invalid params');
      current[p.configId] = p.value;
      return answer(message.id, { configOptions: options() });
    }
    case 'session/prompt': {
      if (!session || p.sessionId !== session.id) return fail(message.id, -32002, `Session not found: ${p.sessionId}`);
      const texts = (p.prompt || []).filter((b) => b.type === 'text').map((b) => b.text);
      const words = texts[texts.length - 1] ?? '';
      const earlier = session.history.length;
      heard(words, p._meta?.cyfr?.post);
      if (active !== null) {
        const before = active;
        active = message.id;
        answer(before, callOpen ? { stopReason: 'end_turn', usage: usage('') } : { stopReason: 'end_turn' });
        steered?.(words);
        return undefined;
      }
      active = message.id;
      turns = turns.then(() => turn(words, p, earlier));
      return undefined;
    }
    case 'session/cancel':
      return finish({ stopReason: 'cancelled' });
    case 'session/close':
      return answer(message.id, {});
    default:
      if (message.id !== undefined) return fail(message.id, -32601, `Method not found: ${message.method}`);
      return undefined;
  }
}).on('close', () => {
  stopServers();
  process.exit(0);
});
