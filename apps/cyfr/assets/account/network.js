// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// What the pages ask of the network: the directory's one dynamic answer
// (`/account/config.json`), its log reads and signed writes
// (`cyfr-directory/v2`, tests/fixtures/directory_wire.json), and the
// registry's handle reads and signed operations. Nothing here carries a
// cookie, a referrer or a secret: every write is self-authenticating.
//
// A request with no answer (the network failed, or the server answered
// 5xx) is `Unreachable`: it may have landed. The page that sent a write
// then sends the same bytes again, and the directory's `exists` is
// success; a registry claim is reconciled by reading its handle.

import {Refusal, isDirectoryUrl, isHome, isObject, jcs, refuse} from "./encoding.js"
import {walk} from "./identity.js"
import {ROUTES, handleAnswer, refusal} from "./registry.js"

const MAX_PAGES = 64

export class Unreachable extends Error {
  constructor() {
    super("unreachable")
  }
}

async function call(fetchFn, url, {method = "GET", body} = {}) {
  let response
  let text
  try {
    response = await fetchFn(url, {
      method,
      body,
      headers: body ? {"content-type": "application/json"} : {},
      credentials: "omit",
      cache: "no-store",
      referrerPolicy: "no-referrer"
    })
    text = await response.text()
  } catch (_error) {
    throw new Unreachable()
  }
  if (response.status >= 500) throw new Unreachable()
  let json
  try {
    json = JSON.parse(text)
  } catch (_error) {
    json = null
  }
  return {status: response.status, text, json}
}

/**
 * The directory's configuration: its URL, the registry it names, and the
 * policy a first claim accepts, or null for a registry that asks for none
 * (a CYFR serving its own).
 */
export async function readConfig(origin, fetchFn) {
  const {status, json} = await call(fetchFn, `${origin}/account/config.json`)
  const valid =
    status === 200 &&
    isObject(json) &&
    isDirectoryUrl(json.directory) &&
    isHome(json.registry) &&
    (json.policy === null || isPolicy(json.policy))
  if (!valid) refuse("bad_config")
  return {directory: json.directory, registry: json.registry, policy: json.policy}
}

function isPolicy(policy) {
  return (
    isObject(policy) &&
    typeof policy.version === "string" &&
    policy.version !== "" &&
    typeof policy.url === "string" &&
    /^https?:\/\//.test(policy.url)
  )
}

/**
 * The terms the policy's `url` serves, `{title, markdown}`: the registry
 * answers them as JSON (`{name, title, content_markdown}`) and this page
 * draws them. Any other answer is `bad_terms`.
 */
export async function readTerms(url, fetchFn) {
  const {status, json} = await call(fetchFn, url)
  const valid = status === 200 && isObject(json) && typeof json.title === "string" && json.title.trim() !== "" && typeof json.content_markdown === "string"
  if (!valid) refuse("bad_terms")
  return {title: json.title.trim(), markdown: json.content_markdown}
}

/** The directory at `url` (a directory URL), over `fetchFn`. */
export function directory(url, fetchFn) {
  const base = `${url}/directory/v1`

  async function write(path, entry) {
    const {status, json} = await call(fetchFn, `${base}${path}`, {method: "POST", body: jcs(entry)})
    if (status === 200 && isObject(json) && ["created", "exists", "accepted"].includes(json.result)) return json
    const {error, ...detail} = isObject(json) ? json : {}
    return refuse(typeof error === "string" ? error : "unexpected", detail)
  }

  return {
    url,

    /**
     * The account's log read from its genesis, page by page, and walked:
     * `{state, entries}`. Throws `gone` for a tombstoned account,
     * `not_found` for one the directory does not hold, and the walk's
     * refusal for a log that does not verify or does not reach its head.
     */
    async read(identifier) {
      const entries = []
      let after = -1
      for (let pages = 0; pages < MAX_PAGES; pages++) {
        const {status, json} = await call(fetchFn, `${base}/${identifier}?after=${after}`)
        if (status === 410) refuse("gone")
        if (status === 404) refuse("not_found")
        if (status !== 200 || !isObject(json) || json.identifier !== identifier || json.from !== after + 1 || !Array.isArray(json.entries)) refuse("invalid_page")
        entries.push(...json.entries)
        if (json.next === null) {
          const walked = await walk(entries)
          if (walked.error) refuse("unverified", walked.error)
          const {state} = walked
          if (state.identifier !== identifier || state.head !== json.head || state.seq + 1 !== json.length) refuse("invalid_page")
          return {state, entries}
        }
        if (json.next !== after + json.entries.length || json.entries.length === 0) refuse("invalid_page")
        after = json.next
      }
      return refuse("invalid_page")
    },

    /** Register a genesis: resolves to the directory's answer, `created` or `exists`. */
    register: (genesis) => write("/register", genesis),

    /** Append one entry: resolves to `accepted` or `exists`; throws `stale_head`, `duplicate_key` and the rest. */
    append: (identifier, entry) => write(`/${identifier}/append`, entry)
  }
}

/** The registry at `origin` (whose host is `host`), over `fetchFn`. */
export function registry(origin, fetchFn) {
  const host = new URL(origin).hostname

  return {
    host,

    /** Who holds `name`: `{answer}`, or `{error}` (`handle_not_found` for a free name). */
    async handle(name) {
      const {text} = await call(fetchFn, `${origin}/v1/handles/${encodeURIComponent(name)}`)
      return handleAnswer(text, name, host)
    },

    /** Send a signed operation's bytes: resolves to the registry's answer, or throws its refusal. */
    async send(operation, bytes) {
      const {status, text, json} = await call(fetchFn, `${origin}${ROUTES[operation]}`, {method: "POST", body: bytes})
      if (status >= 200 && status < 300) return json
      throw new Refusal(refusal(text))
    }
  }
}
