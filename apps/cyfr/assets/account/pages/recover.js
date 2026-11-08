// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// /account/recover#: an account changed with its recovery code (plan §7).
// The code is read into the account's identifier and recovery key, the
// log is read, and the page offers: add a passkey, remove a key, add
// another recovery code, or replace everything. A new code is shown and
// saved before the entry naming it is submitted. Every entry is signed by
// the recovery key and kept until it lands: a lost response sends the
// same bytes again, and `exists` is success. The keys stay in page memory
// and are dropped when the page closes.

import {refuse} from "../encoding.js"
import {next, passkeyAdded, signWith, userId} from "../identity.js"
import {codeFor, drawRecovery, readCode} from "../recovery.js"
import {isHandle} from "../registry.js"
import {addedAt, appendOnce, here, keyLabel, shortCode} from "./common.js"
import {$, attempt, copyCode, drawCode, only, say, words} from "../view.js"

export class Recovery {
  /** The account a typed code recovers; throws `not_a_code`, `typo` or `code_replaced`. */
  static async open(env, place, text) {
    const {identifier, key} = await readCode(text)
    const read = await place.directory.read(identifier)
    if (!read.state.recovery.includes(key.pubText)) refuse("code_replaced")
    return new Recovery(env, place, identifier, key, read)
  }

  constructor(env, place, identifier, key, {state, entries}) {
    Object.assign(this, {env, place, identifier, key, state, entries, fresh: null, pending: null})
  }

  /** A new passkey for the account, labelled with its name, which must be this account's. */
  async addPasskey(name) {
    if (!isHandle(name)) refuse("name_invalid")
    const found = await this.place.registry.handle(name)
    if (found.answer?.identifier !== this.identifier) refuse("name_elsewhere")
    const {credentialId, pub, aaguid} = await this.env.passkeys.create({userId: userId(this.identifier), name: `@${name}`, challenge: this.env.random(32)})
    return this.submit(await this.sign("add_key", await passkeyAdded({pub, credentialId, aaguid})))
  }

  removeKey(kid) {
    return this.sign("remove_key", {kid}).then((entry) => this.submit(entry))
  }

  /** Draw a new code; it is shown and saved before `addCode` or `replace` names it. */
  async drawCode() {
    this.fresh = await drawRecovery(this.env.random)
    const code = await codeFor(this.identifier, this.fresh.secret)
    this.fresh.secret.fill(0)
    return code
  }

  async addCode() {
    return this.submit(await this.sign("add_recovery", {recovery: [...this.state.recovery, this.fresh.key.pubText]}))
  }

  /** Every key removed and the new code the only one: the account starts again from that code. */
  async replace() {
    return this.submit(await this.sign("recover", {keys: [], recovery: [this.fresh.key.pubText]}))
  }

  sign(kind, own) {
    return signWith(next(this.state, kind, own, {at: this.env.now(), signer: this.key.signer}), this.key)
  }

  /**
   * Append `entry`, then read the log again; with no entry, retry the one
   * still pending. An entry stays pending until a read shows it: after a
   * lost response, or a read that failed (`appendOnce`).
   */
  async submit(entry) {
    const retry = entry === undefined
    if (!retry) this.pending = entry
    const {kind} = this.pending
    const read = await appendOnce(this.place.directory, this.identifier, this.pending, retry)
    this.pending = null
    if (kind === "recover") this.key = this.fresh.key
    if (kind === "recover" || kind === "add_recovery") this.fresh = null
    Object.assign(this, read)
  }

  /** The account's keys as the page lists them. */
  keys() {
    const at = addedAt(this.entries)
    return this.state.keys.map((key) => ({kid: key.kid, kind: key.kind, code: shortCode(key.kid), added: at.get(key.kid)}))
  }
}

export async function run(doc, env) {
  let place
  try {
    place = await here(env)
  } catch (error) {
    say(doc, "refused-text", words(error))
    only(doc, "refused")
    return
  }
  only(doc, "enter")
  let recovery = null
  // What "I saved it" submits once a new code is shown.
  let afterSaved = null

  const draw = () => {
    const rows = recovery.keys().map((key) => {
      const row = doc.createElement("li")
      const label = doc.createElement("span")
      label.textContent = keyLabel(key)
      const remove = doc.createElement("button")
      remove.type = "button"
      remove.textContent = "Remove"
      remove.addEventListener("click", () => act(remove, () => recovery.removeKey(key.kid)))
      row.append(label, remove)
      return row
    })
    $(doc, "keys").replaceChildren(...rows)
    $(doc, "no-keys").hidden = rows.length > 0
    only(doc, "account")
  }

  const act = (button, action) =>
    attempt(doc, button, "account-error", async () => {
      $(doc, "retry").hidden = true
      try {
        await action()
      } catch (error) {
        $(doc, "retry").hidden = !recovery.pending
        throw error
      }
      draw()
    })

  const enter = $(doc, "enter-code")
  enter.addEventListener("click", () =>
    attempt(doc, enter, "enter-error", async () => {
      recovery = await Recovery.open(env, place, $(doc, "code-input").value)
      $(doc, "code-input").value = ""
      draw()
    })
  )

  const addPasskey = $(doc, "add-passkey")
  addPasskey.addEventListener("click", () => act(addPasskey, () => recovery.addPasskey($(doc, "passkey-name").value.trim().toLowerCase())))

  const showCode = async (then) => {
    const code = await recovery.drawCode()
    drawCode(doc, $(doc, "code"), code)
    $(doc, "copy").textContent = "Copy"
    $(doc, "copy").onclick = () => copyCode($(doc, "copy"), code)
    afterSaved = then
    only(doc, "show-code")
  }
  const addCode = $(doc, "add-code")
  addCode.addEventListener("click", () => attempt(doc, addCode, "account-error", () => showCode(() => recovery.addCode())))
  const replace = $(doc, "replace")
  replace.addEventListener("click", () => attempt(doc, replace, "account-error", () => showCode(() => recovery.replace())))
  $(doc, "print").addEventListener("click", () => env.print())
  const saved = $(doc, "saved")
  saved.addEventListener("click", () => {
    $(doc, "code").replaceChildren()
    draw()
    act(saved, afterSaved)
  })

  const retry = $(doc, "retry")
  retry.addEventListener("click", () => act(retry, () => recovery.submit()))
}
