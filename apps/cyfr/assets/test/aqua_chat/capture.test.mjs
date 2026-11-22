// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The composer's capture: one still or one bounded clip becomes a finished
// file in that composer's own upload, as a pasted file does, and every
// exit stops the tracks. Only the engine's media, the canvas and the clock
// are stood in for; the engine itself is tests/desktop-proof/media/'s.

import assert from "node:assert/strict"
import {afterEach, beforeEach, mock, test} from "node:test"

import {CAPTURE_MS} from "../../js/capture.js"
import AquaChat from "../../js/hooks/aqua_chat.js"

let engine

class Recorder {
  constructor(stream, options) {
    if (engine.recorderFails) throw new Error("NotSupportedError")
    this.stream = stream
    this.options = options
    this.state = "inactive"
    engine.recorder = this
  }
  start() {
    this.state = "recording"
  }
  stop() {
    if (this.state === "inactive") return
    this.state = "inactive"
    this.ondataavailable({data: new Blob(["sound"])})
    this.onstop()
  }
}

beforeEach(() => {
  mock.timers.enable({apis: ["setTimeout"]})
  engine = {asked: [], tracks: [], refuses: false, recorderFails: false, frames: true, prompt: null}
  const getUserMedia = async (wants) => {
    engine.asked.push(wants)
    if (engine.prompt) await engine.prompt
    if (engine.refuses) throw new Error("NotAllowedError")
    const track = {live: true, stop() { this.live = false }}
    engine.tracks.push(track)
    return {getTracks: () => [track]}
  }
  Object.defineProperty(globalThis, "navigator", {value: {mediaDevices: {getUserMedia}}, configurable: true})
  globalThis.MediaRecorder = Recorder
  globalThis.window = new EventTarget()
  globalThis.document = {
    activeElement: null,
    createElement(tag) {
      if (tag === "video") {
        return {videoWidth: 640, videoHeight: 480, play: () => (engine.frames ? Promise.resolve() : new Promise(() => {}))}
      }
      return {
        getContext: () => ({drawImage: (...args) => (engine.drawn = args)}),
        toBlob(done, type) {
          done(new Blob(["frame"], {type}))
        }
      }
    }
  }
})

afterEach(() => {
  mock.timers.reset()
  for (const name of ["MediaRecorder", "window", "document"]) delete globalThis[name]
})

// The promises a capture waits on, run out.
async function settled() {
  for (let i = 0; i < 20; i++) await null
}

// The composer as LiveView mounts it: its textarea, its form and the
// form's own upload input.
function mount() {
  const attached = []
  const submitted = []
  const input = new EventTarget()
  input.addEventListener("track-uploads", (e) => attached.push(...e.detail.files))
  const el = Object.assign(new EventTarget(), {
    style: {},
    value: "",
    disabled: false,
    focus() {},
    closest: () => null,
    form: {querySelector: () => input, requestSubmit: () => submitted.push(true)}
  })
  const hook = Object.create(AquaChat)
  Object.assign(hook, {el, handleEvent() {}})
  hook.mounted()
  const asks = (kind) => el.dispatchEvent(new CustomEvent("cyfr:capture", {detail: {kind}}))
  return {el, hook, attached, submitted, asks}
}

const live = () => engine.tracks.filter((track) => track.live).length

test("a still is one PNG of the camera's frame in the composer's upload, its track stopped and nothing sent", async () => {
  const composer = mount()
  composer.asks("still")
  await settled()

  assert.deepEqual(engine.asked, [{video: true}])
  const [file] = composer.attached
  assert.equal(composer.attached.length, 1)
  assert.ok(file instanceof File)
  assert.match(file.name, /^photo-.+\.png$/)
  assert.equal(file.type, "image/png")
  assert.equal(await file.text(), "frame")
  assert.equal(live(), 0)
  assert.deepEqual(composer.submitted, [])
})

test("a clip is sound alone, ends by itself under ten seconds and is sent by nobody", async () => {
  assert.equal(CAPTURE_MS, 9800)
  const composer = mount()
  composer.asks("clip")
  await settled()
  assert.deepEqual(engine.asked, [{audio: true}])

  mock.timers.tick(CAPTURE_MS - 1)
  await settled()
  assert.deepEqual([composer.attached.length, live()], [0, 1])

  mock.timers.tick(1)
  await settled()
  const [file] = composer.attached
  assert.match(file.name, /^recording-.+\.webm$/)
  assert.equal(file.type, "audio/webm")
  assert.equal(await file.text(), "sound")
  assert.equal(live(), 0)
  assert.deepEqual(composer.submitted, [])
})

for (const [exit, leave] of [
  ["a cancel", (c) => c.asks("cancel")],
  ["the hook's end", (c) => c.hook.destroyed()],
  ["the page left", () => window.dispatchEvent(new Event("pagehide"))],
  ["a live navigation", () => window.dispatchEvent(new CustomEvent("phx:page-loading-start", {detail: {kind: "redirect"}}))],
  ["a live patch", () => window.dispatchEvent(new CustomEvent("phx:page-loading-start", {detail: {kind: "patch"}}))]
]) {
  test(`${exit} stops a recording's tracks at once and attaches nothing`, async () => {
    const composer = mount()
    composer.asks("clip")
    await settled()
    assert.equal(live(), 1)

    leave(composer)
    assert.equal(live(), 0)

    mock.timers.tick(CAPTURE_MS)
    await settled()
    assert.deepEqual(composer.attached, [])
  })
}

test("loading that leaves nothing does not end a recording", async () => {
  const composer = mount()
  composer.asks("clip")
  await settled()

  for (const kind of ["element", "initial"]) {
    window.dispatchEvent(new CustomEvent("phx:page-loading-start", {detail: {kind}}))
  }
  assert.equal(live(), 1)
})

test("a cancel while the engine still asks stops what it then gives", async () => {
  let answer
  engine.prompt = new Promise((done) => (answer = done))
  const composer = mount()
  composer.asks("clip")
  composer.asks("cancel")

  answer()
  await settled()
  assert.deepEqual([engine.tracks.length, live(), composer.attached.length], [1, 0, 0])
})

test("a refusal and a recorder that fails leave no track and no file, and the next capture works", async () => {
  const composer = mount()

  engine.refuses = true
  composer.asks("still")
  await settled()
  assert.deepEqual([engine.tracks.length, composer.attached.length], [0, 0])

  engine.refuses = false
  engine.recorderFails = true
  composer.asks("clip")
  await settled()
  assert.deepEqual([engine.tracks.length, live(), composer.attached.length], [1, 0, 0])

  composer.asks("still")
  await settled()
  assert.equal(composer.attached.length, 1)
})

test("a recorder's error stops the track and attaches nothing", async () => {
  const composer = mount()
  composer.asks("clip")
  await settled()

  engine.recorder.onerror(new Event("error"))
  await settled()
  assert.deepEqual([live(), composer.attached.length], [0, 0])
})

test("a camera that gives no frame is let go at the same bound", async () => {
  engine.frames = false
  const composer = mount()
  composer.asks("still")
  await settled()

  mock.timers.tick(CAPTURE_MS)
  await settled()
  assert.deepEqual([live(), composer.attached.length], [0, 0])
})

test("one capture at a time, and none for another kind, a disabled composer or one with no upload", async () => {
  const composer = mount()
  composer.asks("clip")
  composer.asks("still")
  await settled()
  assert.deepEqual(engine.asked, [{audio: true}])
  composer.asks("cancel")

  engine.asked = []
  composer.asks("screen")
  composer.el.disabled = true
  composer.asks("still")
  composer.el.disabled = false
  composer.el.form.querySelector = () => null
  composer.asks("still")
  await settled()
  assert.deepEqual(engine.asked, [])
})
