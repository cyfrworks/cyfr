// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The CYFR app's engine as idle.sh's player: Electron, at the version the
// app's package pins, with one window on the page its last argument names,
// made as the app makes the box's screen's window (desktop/src/app.js,
// window): frameless, sandboxed, hidden until it is ready to show, then
// maximized, with no menu and nothing else of the app's. A window shown at
// once, before its first frame, ends the engine on its first frame under a
// headless labwc (a trap, exit 133); the app never shows one so.
const {app, BrowserWindow, Menu} = require("electron")

Menu.setApplicationMenu(null)
app.whenReady().then(() => {
  const w = new BrowserWindow({width: 1280, height: 860, show: false, frame: false,
    webPreferences: {sandbox: true, contextIsolation: true, nodeIntegration: false}})
  w.once("ready-to-show", () => {
    w.maximize()
    w.show()
  })
  w.loadURL(process.argv[process.argv.length - 1])
})
