// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// A script run in a page, as the person's own input: its answer. One that
// ends in `; 1` is an act, which asks for no answer: what it does (a
// click, a navigation) can end the page it runs in, the app closing its
// window or a navigation replacing its frame, before the engine has
// returned its reply, which is then lost ("Render frame was disposed").
// That end is the act's outcome, which the step goes on to read, never a
// failure. Any other script asks for its answer, and fails when its page
// ends first.
const DISPOSED = "Render frame was disposed before the request completed"
export const js = (wc, code) => {
  const answer = wc.executeJavaScript(code, true)
  return /;\s*1\s*$/.test(code) ? answer.catch((e) => { if (e.message !== DISPOSED) throw e }) : answer
}
