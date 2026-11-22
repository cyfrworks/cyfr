// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// One still from this computer's camera or one clip from its microphone,
// as a finished file: a PNG, or WebM sound of at most CAPTURE_MS. Nothing
// streams anywhere and nothing is transcribed. Whether the page may have
// the device is the browser's or the app's to decide, at each capture.

// A clip ends under ten seconds: the recorder runs on a little past the
// timer (10.02 s was measured for 10 s). The timer is the page's, so a page
// that stalls can still run a clip over. A camera that gives no frame is
// let go at the same bound.
export const CAPTURE_MS = 9800

const WANTS = {still: {video: true}, clip: {audio: true}}

/**
 * Capture `kind`, "still" or "clip": the File, or null for another kind, a
 * refusal, a failure or a `signal` aborted meanwhile. The tracks are
 * stopped on every exit, and as soon as `signal` aborts.
 */
export async function capture(kind, signal) {
  const devices = navigator.mediaDevices
  if (!Object.hasOwn(WANTS, kind) || !devices) return null

  let stream
  let timer
  let end
  const ended = new Promise((resolve) => (end = () => resolve(null)))
  const release = () => {
    clearTimeout(timer)
    stream?.getTracks().forEach((track) => track.stop())
  }
  signal.addEventListener("abort", () => {
    release()
    end()
  })

  try {
    stream = await devices.getUserMedia(WANTS[kind])
    if (signal.aborted) return null
    timer = setTimeout(end, CAPTURE_MS)
    const file = await (kind === "still" ? Promise.race([still(stream), ended]) : clip(stream, ended))
    return signal.aborted ? null : file
  } catch {
    return null
  } finally {
    release()
  }
}

const stamp = () => new Date().toISOString().replace(/[:.]/g, "-")

async function still(stream) {
  const video = document.createElement("video")
  video.muted = true
  video.srcObject = stream
  await video.play()
  const canvas = document.createElement("canvas")
  canvas.width = video.videoWidth
  canvas.height = video.videoHeight
  canvas.getContext("2d").drawImage(video, 0, 0)
  const png = await new Promise((resolve) => canvas.toBlob(resolve, "image/png"))
  return png && new File([png], `photo-${stamp()}.png`, {type: "image/png"})
}

function clip(stream, ended) {
  return new Promise((resolve, reject) => {
    const recorder = new MediaRecorder(stream, {mimeType: "audio/webm"})
    const parts = []
    recorder.ondataavailable = (e) => parts.push(e.data)
    recorder.onerror = reject
    recorder.onstop = () => resolve(new File(parts, `recording-${stamp()}.webm`, {type: "audio/webm"}))
    recorder.start()
    ended.then(() => recorder.state !== "inactive" && recorder.stop())
  })
}
