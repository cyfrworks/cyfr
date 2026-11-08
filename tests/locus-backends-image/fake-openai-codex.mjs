#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// A stand-in for Codex's app-server, run as the `openai-codex` program's
// command by openai_codex.py: it speaks the JSON-RPC lines Codex 0.167.0's `app-server`
// was driven to write (seed/components/catalysts/local/openai-codex/0.1.1/README.md,
// "Verified against 0.167.0") and keeps its threads in its HOME, the kept
// folder, under ~/.codex as Codex does.
//
// - It refuses to start without the one argument a session takes,
//   `app-server`, and answers nothing before `initialize`.
// - `account/read` answers a ChatGPT account while ~/.codex/auth.json is
//   in its folder, which its first start writes as a sign-in would, and
//   `account: null` once a turn has removed it.
// - `model/list` answers a listing; `thread/start` keeps the thread with
//   its dynamic tools, policy and developer instructions in the folder;
//   `thread/resume` reads it back, and refuses a thread the folder does
//   not hold.
// - `turn/start` is a turn, by the message's words: `hello` runs its own
//   command (a `commandExecution` item), asks to apply a patch
//   (`item/fileChange/requestApproval`) and replies naming the turn's
//   model and effort, the thread's tools, policy and instructions, and the
//   approval's decision; `read` calls CYFR's `files` tool
//   (`item/tool/call`), holds until the driver answers, and replies with
//   the answer; `first message` replies with the thread's first message;
//   `sign out` removes the sign-in. Each reply streams as
//   `item/agentMessage/delta`s, then the completed `agentMessage`, the
//   thread's token usage sent again unchanged (as a rate-limit update sends
//   it) and then grown by the reply's, and `turn/completed`.
// - It writes a canary to its stderr and to its folder, which the driver
//   must never pass on.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';

if (process.argv.slice(2).join(' ') !== 'app-server') {
  process.stderr.write(`fake-openai-codex: started with ${process.argv.slice(2).join(' ')}, not app-server\n`);
  process.exit(2);
}

const home = path.join(process.env.HOME, '.codex');
const threads = path.join(home, 'fake-threads');
const auth = path.join(home, 'auth.json');
fs.mkdirSync(threads, { recursive: true });
if (!fs.existsSync(path.join(home, 'fake-first-start'))) {
  fs.writeFileSync(path.join(home, 'fake-first-start'), '');
  fs.writeFileSync(auth, '{"FAKE-FOLDER-CANARY": "the sign-in Codex keeps in its folder"}\n');
}
process.stderr.write('FAKE-STDERR-CANARY Codex writes this to its stderr\n');

const MODELS = [
  { id: 'fake-sol', model: 'fake-sol', displayName: 'Fake Sol', description: 'fake', hidden: false, isDefault: true,
    supportedReasoningEfforts: [{ reasoningEffort: 'low', description: '' }, { reasoningEffort: 'high', description: '' }],
    defaultReasoningEffort: 'low', inputModalities: ['text', 'image'] },
  { id: 'fake-mini', model: 'fake-mini', displayName: 'Fake Mini', description: 'fake', hidden: false, isDefault: false,
    supportedReasoningEfforts: [{ reasoningEffort: 'medium', description: '' }, { reasoningEffort: 'xhigh', description: '' }],
    defaultReasoningEffort: 'medium', inputModalities: ['text'] },
];

const out = (message) => process.stdout.write(JSON.stringify(message) + '\n');
const now = () => Date.now();
let initialized = false;
let nextRequest = 0;
const waiting = new Map();
let thread = null;

const threadFile = (id) => path.join(threads, `${id}.json`);
const save = () => fs.writeFileSync(threadFile(thread.id), JSON.stringify(thread));

// A request of the fake's to the driver, answered by a line with its id.
function request(method, params) {
  const id = nextRequest++;
  out({ method, id, params });
  return new Promise((resolve) => waiting.set(id, resolve));
}

function notify(method, params) {
  out({ method, params, emittedAtMs: now() });
}

function reply(turnId, text) {
  const itemId = `msg_${crypto.randomUUID()}`;
  const base = { threadId: thread.id, turnId };
  notify('item/started', { ...base, item: { type: 'agentMessage', id: itemId, text: '', phase: null } });
  const half = Math.ceil(text.length / 2);
  for (const piece of [text.slice(0, half), text.slice(half)]) {
    notify('item/agentMessage/delta', { ...base, itemId, delta: piece });
  }
  notify('item/completed', { ...base, item: { type: 'agentMessage', id: itemId, text, phase: null } });
  thread.history.push({ role: 'assistant', text });
  // The thread's total grows by each model call's usage, and is sent again
  // unchanged first, as a rate-limit update sends it.
  const last = { totalTokens: 12 + text.length, inputTokens: 12, cachedInputTokens: 5, cacheWriteInputTokens: 2, outputTokens: text.length, reasoningOutputTokens: 0 };
  const snapshot = () => notify('thread/tokenUsage/updated', { ...base, tokenUsage: { total: { ...thread.total }, last, modelContextWindow: 272000 } });
  snapshot();
  for (const key of Object.keys(last)) thread.total[key] += last[key];
  save();
  snapshot();
  notify('turn/completed', { threadId: thread.id, turn: { id: turnId, items: [], status: 'completed', error: null } });
}

async function turn(turnId, params) {
  const text = params.input.filter((i) => i.type === 'text').map((i) => i.text).join('');
  thread.history.push({ role: 'user', text });
  save();
  notify('turn/started', { threadId: thread.id, turn: { id: turnId, items: [], status: 'inProgress', error: null } });
  const base = { threadId: thread.id, turnId };
  if (text.includes('hello')) {
    const command = { type: 'commandExecution', id: 'call_own_1', command: "/bin/bash -lc 'cat ~/.codex/auth.json'", cwd: process.env.HOME, status: 'inProgress', commandActions: [] };
    notify('item/started', { ...base, item: command });
    notify('item/completed', { ...base, item: { ...command, status: 'completed', aggregatedOutput: 'FAKE-FOLDER-CANARY', exitCode: 0 } });
    const patch = await request('item/fileChange/requestApproval', { ...base, itemId: 'call_own_2', reason: 'write FAKE-FOLDER-CANARY' });
    const tools = thread.dynamicTools.map((t) => t.name).join(',');
    reply(turnId, `Hello from the fake Codex: thread ${thread.id}, model ${params.model || 'fake-sol'}, effort ${params.effort || 'unset'}, `
      + `tools ${tools}, policy ${thread.approvalPolicy}/${thread.sandbox}, patch ${patch.result?.decision}, instructions "${thread.developerInstructions}".`);
  } else if (text.includes('read')) {
    const itemId = `msg_${crypto.randomUUID()}`;
    notify('item/completed', { ...base, item: { type: 'agentMessage', id: itemId, text: 'Reading it.', phase: null } });
    const callId = `call_${crypto.randomUUID().slice(0, 8)}`;
    const args = { action: 'read', path: 'notes.txt' };
    notify('item/started', { ...base, item: { type: 'dynamicToolCall', id: callId, namespace: null, tool: 'files', arguments: args, status: 'inProgress' } });
    const answered = await request('item/tool/call', { ...base, callId, namespace: null, tool: 'files', arguments: args });
    const said = answered.result.contentItems.map((i) => i.text).join('');
    reply(turnId, answered.result.success ? `The file says: ${said}` : `CYFR refused: ${said}`);
  } else if (text.includes('first message')) {
    reply(turnId, `Your first message was: ${thread.history[0].text}`);
  } else if (text.includes('sign out')) {
    fs.rmSync(auth, { force: true });
    reply(turnId, 'Signed out.');
  } else {
    reply(turnId, 'ok');
  }
}

let turns = Promise.resolve();
readline.createInterface({ input: process.stdin }).on('line', (line) => {
  const message = JSON.parse(line);
  const ok = (result) => out({ id: message.id, result });
  const fail = (text) => out({ error: { code: -32600, message: text }, id: message.id });
  if (message.method === undefined) {
    waiting.get(message.id)?.(message);
    waiting.delete(message.id);
    return;
  }
  if (message.method === 'initialize') {
    initialized = message.params?.capabilities?.experimentalApi === true;
    return ok({ userAgent: 'fake-openai-codex/0.167.0', codexHome: home, platformFamily: 'unix', platformOs: 'linux' });
  }
  if (!initialized) return fail('initialize with experimentalApi first');
  switch (message.method) {
    case 'initialized':
      return undefined;
    case 'account/read':
      return ok(fs.existsSync(auth)
        ? { account: { type: 'chatgpt', email: null, planType: 'plus' }, requiresOpenaiAuth: true }
        : { account: null, requiresOpenaiAuth: true });
    case 'model/list':
      return ok({ data: MODELS, nextCursor: null });
    case 'thread/start': {
      const p = message.params;
      thread = { id: crypto.randomUUID(), dynamicTools: p.dynamicTools || [], approvalPolicy: p.approvalPolicy, sandbox: p.sandbox,
        developerInstructions: p.developerInstructions || '', history: [],
        total: { totalTokens: 0, inputTokens: 0, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0 } };
      save();
      ok({ thread: { id: thread.id, status: { type: 'idle' }, turns: [] }, model: 'fake-sol', approvalPolicy: p.approvalPolicy });
      return notify('thread/started', { thread: { id: thread.id } });
    }
    case 'thread/resume': {
      const file = threadFile(message.params.threadId);
      if (!fs.existsSync(file)) return fail(`no rollout found for thread id ${message.params.threadId}`);
      thread = JSON.parse(fs.readFileSync(file, 'utf8'));
      thread.approvalPolicy = message.params.approvalPolicy;
      thread.sandbox = message.params.sandbox;
      if (message.params.developerInstructions !== undefined) thread.developerInstructions = message.params.developerInstructions;
      save();
      return ok({ thread: { id: thread.id, status: { type: 'idle' }, turns: [] }, model: 'fake-sol' });
    }
    case 'turn/start': {
      if (!thread || message.params.threadId !== thread.id) return fail('thread not found');
      const turnId = crypto.randomUUID();
      ok({ turn: { id: turnId, items: [], itemsView: 'notLoaded', status: 'inProgress', error: null } });
      turns = turns.then(() => turn(turnId, message.params));
      return undefined;
    }
    default:
      return fail(`fake-openai-codex does not answer ${message.method}`);
  }
}).on('close', () => turns.then(() => process.exit(0)));
