// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// A bound a proof holds is measured from its cause (README.md): one call
// starts the clock, does the cause and looks for what follows, so a proof
// cannot wait for something else first and count from there.

const real = {now: Date.now, sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms))} // sleep-ok: the gap between two looks at an observable condition

/**
 * Do `cause` and ask `effect` until it answers: what it first answered,
 * how long after the cause that was seen (`took`, milliseconds) and
 * whether that is `ms` or less (`within`). A look that throws saw nothing,
 * and where nothing is ever seen the last one's reason is told (`last`).
 */
export async function fromCause(cause, effect, ms, clock = real) {
  const at = clock.now()
  await cause()
  let last = null
  for (;;) {
    const seen = await Promise.resolve().then(effect).catch((e) => {
      last = String(e?.message ?? e)
      return null
    })
    const took = clock.now() - at
    if (seen) return {seen, took, within: took <= ms}
    if (took >= ms) return {seen: null, took, within: false, last}
    await clock.sleep(200)
  }
}

/**
 * process_loss: cyfr killed by `kill`, with the app's `message` waited for
 * and the session's `refusal` looked for beside it, from the kill on:
 * the message and the refusal (fromCause).
 */
export async function processLoss({kill, message, refusal}, ms, clock = real) {
  const ended = fromCause(kill, refusal, ms, clock)
  return {message: await message(), ended: await ended}
}
