// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The Programs page's terminal (js/terminal/frame.js) with the vendored
// xterm.js and its fit and web-links addons, each the released file as
// published, its version in its folder's name and its licence beside it.
import {Terminal} from "../../vendor/xterm-6.0.0/xterm.mjs"
import {FitAddon} from "../../vendor/xterm-addon-fit-0.11.0/addon-fit.mjs"
import {WebLinksAddon} from "../../vendor/xterm-addon-web-links-0.12.0/addon-web-links.mjs"
import {TerminalHook} from "../terminal/frame.js"

export default TerminalHook({
  Terminal,
  FitAddon,
  WebLinksAddon,
  open: (...args) => window.open(...args),
  focused: () => document.hasFocus()
})
