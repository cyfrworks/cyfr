// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// A controller that signs as CYFR does, for the bridge's tests: control
// messages under the control key with a rising sequence, backend
// environments sealed to the owner and the bridge lifetime `hello` learned,
// and MCP requests under each owner's key. Every request can be given its own
// timestamp, nonce, sequence, boot or key, and every signed invoke is
// returned so it can be sent again unchanged.

import { randomBytes } from "node:crypto";
import * as auth from "../../apps/mcp-bridge/auth.mjs";

export const PROTOCOL_VERSION = "2026-07-28";

export class Controller {
  /**
   * @param {object} options
   * @param {string} options.base the bridge's base URL
   * @param {Buffer} options.root the 32-byte root key
   * @param {number} [options.generation] the control-plane generation signed with
   * @param {string} [options.cyfrBoot] this controller's lifetime id
   * @param {() => number} [options.now] the clock timestamps are taken from
   */
  constructor({ base, root, generation = 1, cyfrBoot = `boot_${randomBytes(8).toString("hex")}`, now = Date.now }) {
    this.base = base;
    this.root = root;
    this.generation = generation;
    this.cyfrBoot = cyfrBoot;
    this.now = now;
    this.seq = 0;
    this.boot = null;
  }

  /** Posts a control message; answers `{status, body, boot}`. */
  async control(message, { generation = this.generation, seq, boot, ts, key } = {}) {
    const body = JSON.stringify(message);
    const fields = {
      generation,
      seq: seq ?? ++this.seq,
      cyfr_boot: this.cyfrBoot,
      boot: boot ?? (message.type === "hello" ? "-" : this.boot),
      ts: ts ?? this.now(),
    };
    const header = auth.controlHeader(key ?? auth.controlKey(this.root), fields, body);
    return post(`${this.base}/control`, { "content-type": "application/json", "cyfr-bridge-auth": header }, body);
  }

  async hello(options) {
    const answer = await this.control({ type: "hello", g: options?.generation ?? this.generation, cyfr_boot: this.cyfrBoot }, options);
    if (answer.status === 200) this.boot = answer.body.boot;
    return answer;
  }

  reconcile(keep, options) {
    return this.control({ type: "reconcile", keep }, options);
  }

  /** Syncs an owner: `backends` are `[{name, command, env}]`, sealed here. */
  sync({ athanor, server, e, leaseMs = 30_000, backends, sealed }, options = {}) {
    const generation = options.generation ?? this.generation;
    const env = Object.fromEntries(backends.map((b) => [b.name, b.env || {}]));
    const seal =
      sealed ??
      auth.seal(
        auth.sealKey(this.root),
        { athanor, server, generation, epoch: e },
        options.boot ?? this.boot,
        Buffer.from(JSON.stringify(env)),
        randomBytes(12),
      );
    return this.control(
      {
        type: "sync",
        owner: { athanor, server },
        e,
        lease_ms: leaseMs,
        backends: backends.map((b) => ({ name: b.name, command: b.command, env_names: Object.keys(b.env || {}) })),
        sealed: seal,
      },
      options,
    );
  }

  renew(owners, leaseMs = 30_000, options) {
    return this.control({ type: "renew", owners, lease_ms: leaseMs }, options);
  }

  release(owners, options) {
    return this.control({ type: "release", owners }, options);
  }

  status(owners, options) {
    return this.control({ type: "status", owners }, options);
  }

  /**
   * Signs and posts one MCP request for `owner` (`{athanor, server, e}`).
   * Answers `{status, body, boot, request}`; `request` can be passed to
   * `resend`.
   */
  async invoke(owner, method, params = {}, options = {}) {
    const request = this.signInvoke(owner, method, params, options);
    return { ...(await post(request.url, request.headers, request.body)), request };
  }

  /** Signs one MCP request for `owner` as `invoke` does, without sending it. */
  signInvoke(owner, method, params = {}, { id = 1, generation = this.generation, boot, ts, nonce, key, notification = false } = {}) {
    const body = JSON.stringify({
      jsonrpc: "2.0",
      ...(notification ? {} : { id }),
      method,
      params: {
        ...params,
        _meta: {
          "io.modelcontextprotocol/protocolVersion": PROTOCOL_VERSION,
          "io.modelcontextprotocol/clientCapabilities": {},
        },
      },
    });
    const fields = {
      athanor: owner.athanor,
      server: owner.server,
      generation,
      epoch: owner.e,
      boot: boot ?? this.boot,
      ts: ts ?? this.now(),
      nonce: nonce ?? `n_${randomBytes(12).toString("hex")}`,
    };
    const signingKey = key ?? auth.ownerKey(this.root, fields);
    const headers = {
      "content-type": "application/json",
      "mcp-protocol-version": PROTOCOL_VERSION,
      "mcp-method": method,
      ...(typeof params.name === "string" ? { "mcp-name": params.name } : {}),
      "cyfr-bridge-auth": auth.invokeHeader(signingKey, fields, body),
    };
    return { url: `${this.base}/mcp`, headers, body };
  }

  /** Sends a request `invoke` returned again, byte for byte, to `base` (default: its own). */
  async resend(request, base) {
    const url = base ? `${base}/mcp` : request.url;
    return { ...(await post(url, request.headers, request.body)), request };
  }

  /** Calls a tool and answers its first text content parsed as JSON; fails on a refusal. */
  async tool(owner, name, args = {}) {
    const answer = await this.invoke(owner, "tools/call", { name, arguments: args });
    const result = answer.body?.result;
    if (answer.status !== 200 || !result || result.isError) {
      throw new Error(`${name}: ${answer.status} ${JSON.stringify(answer.body)}`);
    }
    return JSON.parse(result.content[0].text);
  }
}

async function post(url, headers, body) {
  const res = await fetch(url, { method: "POST", headers, body });
  const text = await res.text();
  let parsed = null;
  try {
    parsed = text ? JSON.parse(text) : null;
  } catch {
    parsed = text;
  }
  return { status: res.status, body: parsed, boot: res.headers.get("cyfr-bridge-boot") };
}
