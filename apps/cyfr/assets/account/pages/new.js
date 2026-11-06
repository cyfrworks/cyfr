// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// /account/new#name=&request=: an account made in this browser (plan §7).
//
// The order: the name is checked at the registry and the policy, when the
// registry names one, accepted by a checkbox; "Create your account" draws the recovery secret and signs
// the genesis with its key, and the code is shown; "I saved it" creates
// the passkey, signs its `add_key` with the recovery key, keeps the signed
// entries in localStorage (`attempts.js`) and submits in order: register,
// append, then the name (`policy.accept` when there is a policy, and
// `handle.claim`, signed fresh each time they are sent). Register and append resend the same bytes
// after a lost response, and the directory's `exists` is success. The
// name step reads the handle first, so a claim whose response was lost is
// reconciled: ours is done, another's asks for a new name, free signs a
// fresh claim. The recovery key stays in page memory until the name is
// reconciled; a resume in a new tab asks for the code to re-derive it.
// The account never depends on the name. A tab closed before "I saved it"
// made nothing.

import {Refusal, refuse} from "../encoding.js"
import {genesis, identifier as identifierOf, keyOf, next, signWith, userId, walk} from "../identity.js"
import {attempts} from "../attempts.js"
import {codeFor, drawRecovery, readCode} from "../recovery.js"
import {compose, isHandle, signWith as signRequest} from "../registry.js"
import {here} from "./common.js"
import {readSigned, sign} from "./sign.js"
import {$, attempt, copyCode, drawCode, only, say, words} from "../view.js"

const STEPS = ["register", "append", "name", "done"]

export class Creation {
  /** A creation at this page's directory. */
  static async open(env) {
    return new Creation(env, await here(env))
  }

  constructor(env, {config, directory, registry}) {
    this.env = env
    this.config = config
    this.directory = directory
    this.registry = registry
    this.attempts = attempts(env.storage, env.now)
    this.key = null
    this.attempt = null
  }

  /** Whether `name` can be claimed: resolves, or throws `name_invalid` or `name_taken`. */
  async check(name) {
    if (!isHandle(name)) refuse("name_invalid")
    const found = await this.registry.handle(name)
    if (found.answer) refuse("name_taken")
    if (found.error !== "handle_not_found") refuse(found.error)
  }

  /** Draw the recovery secret, sign the genesis with its key, and resolve to the code to show. */
  async begin(name) {
    const {secret, key} = await drawRecovery(this.env.random)
    const first = await signWith(genesis({directory: this.config.directory, recovery: [key.pubText], at: this.env.now(), signer: key.signer}), key)
    const identifier = await identifierOf(first)
    this.key = key
    this.attempt = {identifier, name, genesis: first, step: "passkey", created_at: this.env.now()}
    const code = await codeFor(identifier, secret)
    secret.fill(0)
    return code
  }

  /** "I saved it": create the passkey, sign its `add_key`, and keep the attempt. */
  async savedCode() {
    const {identifier, name, genesis: first} = this.attempt
    const {credentialId, pub} = await this.env.passkeys.create({userId: userId(identifier), name: `@${name}`, challenge: this.env.random(32)})
    const {state} = await walk([first])
    const entry = next(state, "add_key", {key: await keyOf({pub, credentialId})}, {at: this.env.now(), signer: this.key.signer})
    this.attempt = {...this.attempt, add_key: await signWith(entry, this.key), step: "register"}
    this.attempts.save(this.attempt)
  }

  /** Continue an attempt kept in this browser with the code the person typed. */
  async resume(kept, text) {
    const {identifier, key} = await readCode(text)
    if (identifier !== kept.identifier) refuse("other_code")
    this.key = key
    this.attempt = kept
  }

  /** A new name for an account whose name was taken meanwhile. */
  rename(name) {
    if (!isHandle(name)) refuse("name_invalid")
    this.attempt = {...this.attempt, name}
    this.attempts.save(this.attempt)
  }

  /** Submit from the step reached, saving each step as it completes; resolves once the name is the account's. */
  async submit() {
    while (this.attempt.step !== "done") {
      await this[this.attempt.step]()
      this.attempt = {...this.attempt, step: STEPS[STEPS.indexOf(this.attempt.step) + 1]}
      if (this.attempt.step === "done") this.attempts.remove(this.attempt.identifier)
      else this.attempts.save(this.attempt)
    }
    this.key = null
  }

  async register() {
    await this.directory.register(this.attempt.genesis)
  }

  async append() {
    await this.directory.append(this.attempt.identifier, this.attempt.add_key)
  }

  async name() {
    const {identifier, name} = this.attempt
    const found = await this.registry.handle(name)
    if (found.answer) {
      if (found.answer.identifier === identifier) return
      refuse("name_taken")
    }
    if (found.error !== "handle_not_found") refuse(found.error)
    if (this.config.policy) await this.send("policy.accept", {policy_version: this.config.policy.version})
    try {
      await this.send("handle.claim", {handle: name})
    } catch (error) {
      if (error instanceof Refusal && error.reason === "handle_taken") refuse("name_taken")
      throw error
    }
  }

  async send(operation, body) {
    const request = compose({
      registry: this.registry.host,
      operation,
      identifier: this.attempt.identifier,
      signer: this.key.signer,
      nonce: this.env.random(16),
      now: this.env.now(),
      body
    })
    return this.registry.send(operation, await signRequest(request, this.key))
  }
}

export async function run(doc, env) {
  const params = new URLSearchParams(env.location.hash.slice(1))
  let request = null
  let creation
  try {
    if (params.get("request")) request = readSigned(params.get("request"), env.now())
    if (request && request.purpose !== "sign_in") refuse("bad_link")
    creation = await Creation.open(env)
  } catch (error) {
    say(doc, "refused-text", words(error))
    only(doc, "refused")
    return
  }

  const nameInput = $(doc, "name")
  nameInput.value = params.get("name") ?? ""
  const {policy} = creation.config
  const accept = $(doc, "accept")
  if (policy) $(doc, "policy-link").href = policy.url
  else $(doc, "acceptance").hidden = true
  const create = $(doc, "create")
  const ready = () => (create.disabled = !((accept.checked || !policy) && nameInput.value.trim()))
  nameInput.addEventListener("input", ready)
  accept.addEventListener("change", ready)
  ready()

  const finish = () => {
    if (!request) return only(doc, "done")
    $(doc, "continue").textContent = `Continue to ${request.audience}`
    only(doc, "done-return")
  }

  const proceed = async () => {
    only(doc, "working")
    say(doc, "working-error", "")
    $(doc, "retry").hidden = true
    try {
      await creation.submit()
      finish()
    } catch (error) {
      if (error instanceof Refusal && error.reason === "name_taken") {
        $(doc, "rename-name").value = ""
        only(doc, "rename")
        return
      }
      say(doc, "working-error", words(error))
      $(doc, "retry").hidden = false
    }
  }

  const kept = creation.attempts.list()
  if (kept.length > 0) {
    $(doc, "resume-name").textContent = `@${kept[kept.length - 1].name}`
    only(doc, "resume")
  } else {
    only(doc, "choose")
  }

  const resume = $(doc, "resume-continue")
  resume.addEventListener("click", () =>
    attempt(doc, resume, "resume-error", async () => {
      await creation.resume(kept[kept.length - 1], $(doc, "resume-code").value)
      $(doc, "resume-code").value = ""
      await proceed()
    })
  )
  $(doc, "resume-new").addEventListener("click", () => only(doc, "choose"))

  create.addEventListener("click", () =>
    attempt(doc, create, "choose-error", async () => {
      const name = nameInput.value.trim().toLowerCase()
      await creation.check(name)
      const code = await creation.begin(name)
      drawCode(doc, $(doc, "code"), code)
      $(doc, "copy").onclick = () => copyCode($(doc, "copy"), code)
      only(doc, "show-code")
    })
  )
  $(doc, "print").addEventListener("click", () => env.print())
  const saved = $(doc, "saved")
  saved.addEventListener("click", () =>
    attempt(doc, saved, "code-error", async () => {
      await creation.savedCode()
      $(doc, "code").replaceChildren()
      await proceed()
    })
  )
  $(doc, "retry").addEventListener("click", proceed)

  const rename = $(doc, "rename-submit")
  rename.addEventListener("click", () =>
    attempt(doc, rename, "rename-error", async () => {
      const name = $(doc, "rename-name").value.trim().toLowerCase()
      await creation.check(name)
      creation.rename(name)
      await proceed()
    })
  )

  const go = $(doc, "continue")
  go.addEventListener("click", () =>
    attempt(doc, go, "return-error", async () => {
      if (env.now() >= request.expires_at) refuse("expired")
      env.navigate(await sign(request, env))
    })
  )
}
