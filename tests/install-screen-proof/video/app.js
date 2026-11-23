// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
const label = document.getElementById("label")
const video = document.querySelector("video")
let began = false
addEventListener("click", async () => {
  if (began) return
  began = true
  const c = document.createElement("canvas"); c.width = 640; c.height = 360
  const g = c.getContext("2d"); let n = 0
  setInterval(() => { g.fillStyle = n++ % 2 ? "red" : "blue"; g.fillRect(0, 0, 640, 360) }, 100)
  const a = new AudioContext(), o = a.createOscillator(), d = a.createMediaStreamDestination()
  o.connect(d); o.start(); await a.resume()
  video.srcObject = new MediaStream([...c.captureStream(10).getTracks(), ...d.stream.getTracks()])
  await video.play()
  let last = -1
  setInterval(() => {
    label.textContent = video.currentTime > last ? "Playing" : "Stopped"
    last = video.currentTime
  }, 1000)
})
// The page has drawn its Play: a canvas version that does not say so within
// 10 s of its trial is never shown (Prism.CanvasValidation).
cyfr.ready()
