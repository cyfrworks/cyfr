// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// What a grant proof may write of the page's socket and of its record:
// every value the proof knows to be secret is replaced by a fixed marker
// before anything is written. The proof passes the session cookie it was
// given and, for its frames, the tokens the page holds when it writes them
// (its CSRF meta tag, a form's hidden `_csrf_token` value, and each view's
// `data-phx-session`, `data-phx-static` and `data-csrf` values). Whatever
// the proof passes, the value of a `session`, `static`, `_csrf_token`,
// `token`, `plan_token` or `proof` key goes, and so does the value of a
// `data-phx-session`, `data-phx-static` or `data-csrf` attribute a reply
// renders, quoted plainly or escaped inside a frame's JSON. A frame is kept
// to 600 characters, so it may end inside a value: a named value is
// replaced to its closing quote or to the frame's end, and a known value's
// first four or more characters, when the frame ends with them, go too. No
// key or attribute in a frame names a form's CSRF value (a reply sends it
// as a piece of its own, and the form's own event sends it url-encoded),
// so it goes only as a value the page still holds.

export const MARKER = "[secret]";

const SECRET_KEYS = ["session", "static", "_csrf_token", "token", "plan_token", "proof"];
const KEYED = new RegExp(`((?:\\\\)?"(?:${SECRET_KEYS.join("|")})(?:\\\\)?"\\s*:\\s*(?:\\\\)?")(?:[^"\\\\]|\\\\(?!"))*`, "g");
const SECRET_ATTRIBUTES = ["data-phx-session", "data-phx-static", "data-csrf"];
const ATTRIBUTE = new RegExp(`((?:${SECRET_ATTRIBUTES.join("|")})=(?:\\\\)?")(?:[^"\\\\]|\\\\(?!"))*`, "g");
// The shortest part of a known value, at a frame's end, that is replaced.
const TAIL = 4;

// One frame's text with each known secret, and each secret-named key's or
// attribute's value, replaced by the marker.
export function redact(text, secrets) {
  let out = String(text);
  for (const secret of secrets) {
    if (!secret) continue;
    out = out.split(secret).join(MARKER);
    for (let n = secret.length - 1; n >= TAIL; n--) {
      if (out.endsWith(secret.slice(0, n))) {
        out = out.slice(0, -n) + MARKER;
        break;
      }
    }
  }
  return out.replace(KEYED, `$1${MARKER}`).replace(ATTRIBUTE, `$1${MARKER}`);
}

// The tokens a page holds as its frames are written, each a value a reply
// may have carried. A page that cannot answer within five seconds gives
// none, and the frames keep only what the rules by name replace.
export async function pageTokens(page) {
  const read = page.evaluate(() =>
    [...document.querySelectorAll(
      "meta[name='csrf-token'], input[name='_csrf_token'], [data-phx-session], [data-phx-static], [data-csrf]",
    )].flatMap((el) => ["content", "value", "data-phx-session", "data-phx-static", "data-csrf"]
      .map((name) => el.getAttribute(name))));
  const late = new Promise((resolve) => setTimeout(() => resolve([]), 5_000).unref());
  const values = await Promise.race([read, late]).catch(() => []);
  return values.filter((v) => typeof v === "string" && v.length >= 8);
}

// The frames as a failed run writes them.
export function redactFrames(frames, secrets) {
  return frames.map((frame) => ({ ...frame, data: redact(frame.data, secrets) }));
}

// The proof's record as any run writes it: a step's answer may carry what
// the frames do (a preview's `proof`), so the record passes the same rule.
export function recordText(value, secrets) {
  return redact(JSON.stringify(value, null, 2), secrets);
}
