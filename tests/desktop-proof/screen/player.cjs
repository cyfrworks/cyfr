// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The CYFR app's engine as idle.sh's player: Electron, at the version the
// app's package pins, with one window on the page its last argument names,
// as the app shows a page, with no menu and nothing of the app's own.
const {app, BrowserWindow, Menu} = require("electron")

Menu.setApplicationMenu(null)
app.whenReady().then(() => {
  const w = new BrowserWindow({width: 1280, height: 720})
  w.loadURL(process.argv[process.argv.length - 1])
})
