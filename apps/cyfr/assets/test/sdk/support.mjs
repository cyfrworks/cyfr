// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import {readFileSync} from "node:fs"
import {createServer} from "node:http"

// The vectors `Prima.TinctureWire`'s test reads too.
export const fixture = JSON.parse(
  readFileSync(new URL("../../../../../tests/fixtures/tincture_wire.json", import.meta.url), "utf8")
)

export const credentialOf = (header) => header.replace(/^Bearer /, "")

// A stand-in for the endpoint: records each request and answers it from
// `answer(request)`, a `{status, body}` (the body JSON-encoded unless a
// string), or a `{stream}` whose function writes a `text/event-stream`
// answer itself: `stream(res, request)`. A request whose connection closes
// is marked `closed`.
export async function stubServer(answer) {
  const requests = []

  const server = createServer((req, res) => {
    let raw = ""
    req.on("data", (chunk) => (raw += chunk))
    req.on("end", () => {
      const request = {
        method: req.method,
        url: req.url,
        headers: req.headers,
        body: JSON.parse(raw),
        closed: false
      }
      requests.push(request)
      res.on("close", () => (request.closed = true))
      const {status = 200, body, stream} = answer(request)

      if (stream) {
        res.writeHead(200, {"content-type": "text/event-stream; charset=utf-8"})
        stream(res, request)
      } else {
        res.writeHead(status, {"content-type": "application/json"})
        res.end(typeof body === "string" ? body : JSON.stringify(body))
      }
    })
  })

  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve))
  const {port} = server.address()

  return {
    base: `http://127.0.0.1:${port}/t/home/local/weather/`,
    requests,
    close: () => new Promise((resolve) => server.close(resolve))
  }
}

// A page's window: `parent` is the shell's window unless `framed` is false,
// and `location.pathname` the page's path.
export function frameWindow({framed = true, pathname = "/t/home/local/weather/index.html"} = {}) {
  const win = {location: {pathname}}
  win.parent = framed ? {name: "shell"} : win
  return win
}

// The next message a port receives.
export const nextMessage = (port) =>
  new Promise((resolve) => {
    port.onmessage = (event) => resolve(event.data)
  })

// Wait for a condition, in bounded steps.
export async function eventually(check, {tries = 50, stepMs = 10} = {}) {
  for (let i = 0; i < tries; i++) {
    if (check()) return
    await new Promise((resolve) => setTimeout(resolve, stepMs))
  }
  throw new Error("the condition never held")
}
