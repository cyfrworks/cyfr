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
// `answer(request)`, a `{status, body}`, the body JSON-encoded unless a
// string.
export async function stubServer(answer) {
  const requests = []

  const server = createServer((req, res) => {
    let raw = ""
    req.on("data", (chunk) => (raw += chunk))
    req.on("end", () => {
      const request = {method: req.method, url: req.url, headers: req.headers, body: JSON.parse(raw)}
      requests.push(request)
      const {status = 200, body} = answer(request)
      res.writeHead(status, {"content-type": "application/json"})
      res.end(typeof body === "string" ? body : JSON.stringify(body))
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

// A stand-in for the endpoint's stream connection: `socketFn`, as
// createClient takes it, and every socket it made, in order. A socket
// records what the frame sends on it (`sent`, each message parsed) and
// answers each with `answer(message, socket)`, a list of the endpoint's
// messages, each its own message event after it. It opens after the call
// that made it, as a WebSocket does, unless `opens` is false, when the test
// opens it (`open()`); `say(message)` sends the frame a message (a string
// as it is), and `drop()` closes it from the endpoint's side. `sent()` is
// every message every socket carried.
export function stubSockets({answer = () => [], opens = true} = {}) {
  const sockets = []
  const socketFn = (url) => {
    const socket = {
      url,
      sent: [],
      readyState: 0,
      send(data) {
        if (socket.readyState === 0) throw new Error("a WebSocket sends nothing before it opens")
        if (socket.readyState !== 1) return
        const message = JSON.parse(data)
        socket.sent.push(message)
        for (const reply of answer(message, socket)) setTimeout(() => socket.say(reply), 0)
      },
      open() {
        socket.readyState = 1
        socket.onopen({type: "open"})
      },
      say(message) {
        if (socket.readyState === 1) socket.onmessage({data: typeof message === "string" ? message : JSON.stringify(message)})
      },
      drop(code = 1006) {
        if (socket.readyState === 3) return
        socket.readyState = 3
        socket.onclose({code})
      }
    }
    sockets.push(socket)
    if (opens) setTimeout(() => socket.readyState === 0 && socket.open(), 0)
    return socket
  }
  return {socketFn, sockets, sent: () => sockets.flatMap((socket) => socket.sent)}
}

// A page's window: `parent` is the shell's window unless `framed` is false,
// and `location.pathname` the page's path.
export function frameWindow({framed = true, pathname = "/t/@home/local/weather/index.html"} = {}) {
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
