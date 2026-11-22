// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The passkey road against a real CYFR that serves its own account pages
// (../README.md): the CYFR and its account service share one origin, so
// what keeps the account window to the ceremony is the path alone. The
// app runs with the passkey road on; the account window's authenticator
// holds the account's passkey, as this computer's platform would once the
// person has one here.

import {accountAndSetup, accountWindow, armWindow, connectApproved, passkeyFor, signOutOfPrism, signedInPrism,
  startSignIn, toSignIn, usePasskey} from "../account.js"
import {HOME, decided, inputs, js, literal, passkeys, row, run, waitFor} from "../lib.js"

// The refusal the app's policy gives both passkey calls in a document.
const policyRefuses = (answers) => /^NotAllowedError: .*'publickey-credentials-get' feature is not enabled/.test(answers[0]) &&
  /^NotAllowedError: .*'publickey-credentials-create' feature is not enabled/.test(answers[1])

async function passkeyPhase() {
  await accountAndSetup(inputs)
  const mine = [...passkeys.values()].filter((c) => c.rpId === new URL(HOME).hostname)
  await connectApproved()

  // same_origin_hop: the CYFR's sign-in hops to its own account pages,
  // which open in the app's account window; the content stays at the
  // sign-in page.
  let w = await toSignIn()
  let a = await startSignIn(w)
  const hop = {account: a.webContents.getURL().split("#")[0], content: w.webContents.getURL().split("#")[0]}
  row("same_origin_hop", hop.account === `${HOME}/account/sign` && hop.content === `${HOME}/login`,
    "the CYFR's sign-in opens its own account page, at its own origin, in the app's account window", hop)

  // same_origin_sign_in: the account's passkey signs in there and Prism
  // opens.
  await armWindow(a, mine)
  await usePasskey(a)
  w = await signedInPrism()
  row("same_origin_sign_in", !accountWindow() && mine.length === 1, "the account's passkey signs in at the CYFR's own account page, and Prism opens", {})

  // passkeys_policy: in Prism's page, at the same origin as the account
  // pages and with an authenticator holding a passkey for it, both
  // passkey calls are refused by the app's policy.
  await armWindow(w, [passkeyFor(new URL(HOME).hostname)])
  const calls = await js(w.webContents, `(async () => { const c = new Uint8Array(32)
    const bound = new Promise((done) => setTimeout(() => done("no answer"), 10000))
    const r = (p) => Promise.race([p.then(() => "allowed", (e) => e.name + ": " + e.message), bound])
    return [await r(navigator.credentials.get({publicKey: {challenge: c, rpId: location.hostname, timeout: 3000, userVerification: "discouraged"}})),
      await r(navigator.credentials.create({publicKey: {challenge: c, rp: {name: "proof", id: location.hostname},
        user: {id: c.slice(0, 16), name: "proof", displayName: "proof"}, pubKeyCredParams: [{type: "public-key", alg: -7}], timeout: 3000}}))] })()`)
  row("passkeys_policy", policyRefuses(calls),
    "in Prism's page, the account pages' own origin, both passkey calls are refused by the app's policy", {calls})

  // home_paths: from the account window, the CYFR's own pages, at the same
  // origin as the account page, are refused and end the ceremony.
  await signOutOfPrism(w)
  a = await startSignIn(await toSignIn())
  const account = {id: a.webContents.id}
  await js(a.webContents, `location.href = ${literal(HOME + "/")}; 1`)
  const refused = await decided(account, HOME + "/", false, "main's decision on the CYFR's page in the account window")
  const ended = await waitFor(() => !accountWindow(), "the ceremony ended")
  row("home_paths", refused && ended, "the account window refuses the CYFR's own page at the same origin, and the ceremony ends", {refused})
}

run("passkey-self", {passkey: passkeyPhase}, {accountRoad: true})
